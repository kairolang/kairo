/// --- The Kairo Project -------------------- Preprocessor/DepScanner.k --- ///
///
///   Builds the import DAG from the entry file, on one thread.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "map"
ffi "c++" import "set"
ffi "c++" import "vector"

import AST::LangItems::LangAttrs
import AST::Node::Declarations::ImportKind
import Location::SourceManager::{
    FileID,
    SourceManager,
}
import Preprocessor::PreprocessorSymbolTable::PreprocessorSymbolTable
import Preprocessor::StreamCursor::StreamCursor
import Preprocessor::TokenSource::TokenSource
import Resolution::ImportProbe::{
    ImportResolver,
    ModuleResolution,
}
import Resolution::ModulePath::ModulePath
import Resolution::SearchRoot::module_dir_at_or_above
import Support::FileIO::Path::Path
import Support::TimeReport::TimeRegion
import Token::IdentifierToken::IdentifierToken
import Token::TokenCacheManager::TokenCacheManager
import Token::TokenKind::TokenKind
import Token::TokenText::TokenText

// FIXME: on a big project root with many files, DepScanner makes a lot of
//        temporary allocations (178k with 280k files) which adds up to a
//        significant portion of the runtime (848ms of 2.5s total).
//
// This is mostly due to the map/set usage in DepGraph and the temporary
//     vectors/strings in scan_import. We should optimize this by using more
//     efficient data structures (e.g. flat_hash_map) and by reusing memory
//     where possible (e.g. string interning for module paths).

pub struct DepEdge {
    var from_fid:       u32
    var to_fid:         u32
    var to_module_path: ModulePath
}

pub class DepGraph {
    pub var deps:                cxx::std::map<u32, cxx::std::set<u32>> ///< fid -> fids it depends on
    pub var rdeps:               cxx::std::map<u32, cxx::std::set<u32>> ///< fid -> fids that depend on it
    pub var in_degree:           cxx::std::map<u32, i32> ///< fid -> number of unprocessed deps
    pub var mod_paths:           cxx::std::map<u32, ModulePath> ///< fid -> its module path
    pub var all_fids:            cxx::std::set<u32> ///< every fid in the graph
    pub var depth_exceeded_path: string                                 = "" ///< "" = under budget; else first file that hit --cmax-import-depth
    /// Every import cycle the scan met, one per edge that closes one: the
    /// files on it in import order, each importing the next and the last
    /// importing the first (a self-import is one file). The edge from the
    /// last back to the first is NOT in deps -- see _scan_one_import.
    pub var cycles: cxx::std::vector<cxx::std::vector<u32>>
    /// Files that write `@create` / `@destroy`. The sugar lowers to
    /// alloc.k's create / destroy with no import written, so the
    /// preprocessor adds alloc.k to the graph for each of them -- the scan
    /// is the one place every token of every file is seen before the walk.
    pub var alloc_sugar: cxx::std::set<u32>
    /// Files that name `f256` / `f512` (the type keyword, or a literal with
    /// the suffix), one set each. Their classes (num/f256_t.k, f512_t.k)
    /// and the engine under them are four large builtin files, so the root
    /// does not re-export them: the preprocessor adds them to the graph
    /// only for a program that has one of these (P723), as alloc.k for
    /// `@create`.
    pub var f256_users: cxx::std::set<u32>
    pub var f512_users: cxx::std::set<u32>
    /// Files that name `f128`: num/f128_ext.k (f128's methods, whose sqrt
    /// and fma run the same engine) is added for them the same way.
    pub var f128_users: cxx::std::set<u32>

    fn add_node(self, fid: u32, const path: ModulePath) {
        if !self.all_fids.contains(fid) {
            self.all_fids.insert(fid)
            self.deps[fid]      = cxx::std::set<u32>()
            self.rdeps[fid]     = cxx::std::set<u32>()
            self.in_degree[fid] = 0
            self.mod_paths[fid] = path
        }
    }

    fn add_edge(self, from: u32, to: u32) {
        if !self.deps[from].contains(to) {
            self.deps[from].insert(to)
            self.rdeps[to].insert(from)
            self.in_degree[from] += 1
        }
    }

    fn roots(self) -> cxx::std::vector<u32> {
        var result = cxx::std::vector<u32>()
        for fid in self.all_fids {
            if self.in_degree[fid] == 0 {
                result.push_back(fid)
            }
        }

        return result
    }
}

pub class DepScanner {
    priv var _sm:        *SourceManager
    priv var _tcm:       unsafe *TokenCacheManager
    priv var _resolver:  *ImportResolver
    priv var _sym_table: unsafe *PreprocessorSymbolTable
    priv var _visiting:  llvm::DenseSet<u64> ///< cycle detection; membership only, so hash order is fine (`fid as u64`: clear of the reserved keys)
    priv var _stack:     cxx::std::vector<u32> ///< _visiting in visit order: a cycle's files, read back off it
    priv var _max_depth: i32                             = 512 ///< --cmax-import-depth; 0 = unlimited
    /// What an earlier preprocess() of the batch scanned. A fid in it is
    /// followed through its recorded edges, never rescanned: a walked file's
    /// rescan resolved its imports to itself -- a self-edge, which no wave
    /// clears, so nothing that imports it was ever walked.
    priv var _known: unsafe *DepGraph = &null

    fn DepScanner(self,
                  sm:               *SourceManager,
                  tcm:              unsafe *TokenCacheManager,
                  resolver:         *ImportResolver,
                  sym_table:        unsafe *PreprocessorSymbolTable,
                  max_import_depth: i32 = 512) {
        self._sm        = sm
        self._tcm       = tcm
        self._resolver  = resolver
        self._sym_table = sym_table
        self._max_depth = max_import_depth
    }

    fn set_known(self, known: unsafe *DepGraph) {
        self._known = known
    }

    /// \brief entry point - builds the full dep graph rooted at entry_fid
    fn build_graph(self, entry_fid: u32, const entry_path: ModulePath) -> DepGraph {
        var _t = TimeRegion("DepScan")

        var graph = DepGraph()
        self.visit(entry_fid, entry_path, &graph, 0)
        return graph
    }

    /// \brief folds an out-of-band dependency (--force-include) into the
    ///        graph as if every TU implicitly imported it, at global scope.
    ///        Its own import chain gets a fresh depth budget (depth 0) it
    ///        does not inherit whatever depth the requesting TU is at.
    fn add_root_dependency(self, fid: u32, graph: *DepGraph) {
        self.visit(fid, ModulePath(), graph, 0)
    }

    /// \brief folds a MODULE (named, not a file path) into the graph as a root.
    ///
    /// \details The prelude's path. One difference from add_root_dependency and
    ///          it is the whole reason this exists: the module's CANONICAL path
    ///          comes back from the resolver, so its files carry their root's
    ///          leading segment. add_root_dependency passes an EMPTY
    ///          ModulePath, which is right for --force-include (a bare file
    ///          folded in at global scope) and wrong for a module -- the
    ///          lang-item fill keys on the qualified path, and an empty one
    ///          would make `builtin::Vector` unaddressable.
    ///
    /// \returns the module's fid, or 0 when it does not resolve. Silent on a
    ///          miss, as everything else in the scanner is: the PP walk
    ///          re-resolves and owns the diagnostic.
    fn add_module_dependency(self, segments: cxx::std::vector<string>, graph: *DepGraph) -> u32 {
        var dep = self.resolve_segments(segments, false, Path(), Path(), false)
        if dep.fid == u32::MAX {
            return 0
        }

        self.visit(dep.fid, dep.mod_path, graph, 0)
        return dep.fid
    }

    priv fn visit(self, fid: u32, const mod_path: ModulePath, graph: *DepGraph, depth: u32) {
        if graph->all_fids.contains(fid) {
            return
        }

        if self._visiting.contains(fid as u64) { // cycle (_scan_one_import drops its edge)
            return
        }

        if self._max_depth > 0 && (depth as i32) > self._max_depth {
            if graph->depth_exceeded_path.empty() {
                graph->depth_exceeded_path = self._sm->get_filename(fid)
            }

            return
        }

        if self._known != &null && self._known->all_fids.contains(fid) {
            graph->add_node(fid, self._known->mod_paths[fid])
            for dep in self._known->deps[fid] {
                self.visit(dep, self._known->mod_paths[dep], graph, depth + 1)
                graph->add_edge(fid, dep)
            }

            return
        }

        graph->add_node(fid, mod_path)
        self._visiting.insert(fid as u64)
        self._stack.push_back(fid)
        finally {
            self._visiting.erase(fid as u64)
            self._stack.pop_back()
        }

        var stream = self._tcm->open_scan_stream(fid)
        if stream.lexer == &null {
            return
        }

        finally {
            self._tcm->close_scan_stream(&stream)
        }

        var src = TokenSource(stream.lexer)
        var cur = StreamCursor(&src, &null) // scan-only: silent

        while !src.at_eof() {
            var k = src.peek(0).kind
            if k == TokenKind::TkEof {
                break
            }

            if k == TokenKind::KwFfi {
                self._skip_ffi_stream(&src)
                continue
            }

            // visibility prefix: DAG cares only about `<vis> import`
            if k == TokenKind::KwPub || k == TokenKind::KwPriv || k == TokenKind::KwProt {
                if src.peek(1).kind == TokenKind::KwImport {
                    src.next() // drop vis keyword
                    self._scan_one_import(&cur, fid, graph, depth)
                    continue
                }

                src.next()
                continue
            }

            if k == TokenKind::KwImport {
                self._scan_one_import(&cur, fid, graph, depth)
                continue
            }

            // `@create` / `@destroy`: spelled as ExprParse matches them. A
            // macro that expands to one is not seen here (the scan does not
            // expand); such a file needs the import written.
            if k == TokenKind::OpAt && src.peek(1).kind == TokenKind::LitIdentifier {
                var an = TokenText::spelling(src.peek(1), self._tcm)
                if an == LangAttrs::create() || an == LangAttrs::destroy() {
                    graph->alloc_sugar.insert(fid)
                }
            }

            // `f128` / `f256` / `f512`: the keyword, or a literal's suffix
            // (`1.5f256`). A hex literal whose last digits spell one
            // (`0xf256`) is a false positive, which only costs the load.
            // Like the sugar, a macro that expands to one is not seen.
            if k == TokenKind::AtF256 {
                graph->f256_users.insert(fid)
            } else if k == TokenKind::AtF512 {
                graph->f512_users.insert(fid)
            } else if k == TokenKind::AtF128 {
                graph->f128_users.insert(fid)
            } else if k == TokenKind::LitFloat || k == TokenKind::LitInt {
                var w = DepScanner::_wide_float_suffix(TokenText::spelling(src.peek(0), self._tcm))
                if w == 256 {
                    graph->f256_users.insert(fid)
                } else if w == 512 {
                    graph->f512_users.insert(fid)
                } else if w == 128 {
                    graph->f128_users.insert(fid)
                }
            }

            src.next() // everything else: skip
        }

        // PERF: this loop runs to EOF, so every file is FULLY tokenized here
        // and fully tokenized again by the walk   two complete lexes of the
        // same bytes, confirmed by DepScan.Lex and Walk.Lex reporting
        // identical call counts under --time-passes. The scan's tokens are
        // then discarded (open_scan_stream deliberately never touches _slots).
        //
        // Two ways out, neither taken here because both are decisions, not
        // cleanups:
        //   1. Stop at the first token that cannot begin an import. Costs
        //      nothing, but only legal if the grammar pins imports to the file
        //      prologue   which it currently does not, since PPWalker handles
        //      `import` anywhere in its main loop.
        //   2. Keep the scan's TokenBuffer + ImmediateTable and have the walk
        //      read from it instead of re-lexing. Needs the walk's macro
        //      expansion to write into a separate output buffer rather than
        //      assuming it owns the input stream.
    }

    /// 128, 256 or 512 when \p sp ends in `f128` / `f256` / `f512` (either
    /// case of the `f`), else 0.
    priv static fn _wide_float_suffix(const sp: string) -> u32 {
        var n = sp.size()
        if n < 5 {
            return 0
        }

        var f = sp[n - 4]
        if f != ('f' as u8) && f != ('F' as u8) {
            return 0
        }

        var a = sp[n - 3]
        var b = sp[n - 2]
        var c = sp[n - 1]
        if a == ('2' as u8) && b == ('5' as u8) && c == ('6' as u8) {
            return 256
        }

        if a == ('5' as u8) && b == ('1' as u8) && c == ('2' as u8) {
            return 512
        }

        if a == ('1' as u8) && b == ('2' as u8) && c == ('8' as u8) {
            return 128
        }

        return 0
    }

    priv fn _skip_ffi_stream(self, src: *TokenSource) {
        src->next() // ffi
        if src->peek(0).kind == TokenKind::LitString { // "lang"
            src->next()
        }

        var k = src->peek(0).kind
        if k == TokenKind::KwImport {
            // ffi "lang" import "hdr" ; no fid dep, drop to terminator
            while !src->at_eof() {
                var t = src->next()
                if t.kind == TokenKind::OpSemicolon {
                    break
                }

                if t.kind == TokenKind::TkNewLine { // VERIFY: is `;` mandatory
                    break
                }

                // on ffi imports? if yes,
                // delete this line
            }

            return
        }

        if k == TokenKind::OpLBrace {
            var depth: i32 = 0
            while !src->at_eof() {
                var t = src->next()
                if t.kind == TokenKind::OpLBrace {
                    depth += 1
                }

                if t.kind == TokenKind::OpRBrace {
                    depth -= 1
                    if depth == 0 {
                        return
                    }
                }
            }

            return
        }

        // ffi "lang" <single decl> nothing here creates a dep; let the walk skip it
    }

    /// drives the shared grammar, resolves, recurses, adds the edge.
    priv fn _scan_one_import(self,
                             cur:      *StreamCursor,
                             from_fid: u32,
                             graph:    *DepGraph,
                             depth:    u32) {
        var spec = cur->parse_import_spec()
        if !spec.ok {
            return
        }

        // trailing `;`
        if cur->ig_kind() == TokenKind::OpSemicolon {
            cur->ig_bump()
        }

        var segs = cxx::std::vector<string>()
        for var i: usize = 0; i < spec.segments.size(); ++i {
            segs.push_back(TokenText::spelling(spec.segments[i], self._tcm))
        }

        if segs.size() == 0 {
            return
        }

        // which segments name the FILE?
        //   wildcard / braced / bang-on-last: base is all-but-nothing / all-but-last
        //   plain path: try full, then drop last (it may be a symbol, not a module)
        var dep = Self::DepResult()

        // Resolution is keyed on the IMPORTING file's directory and on the
        // form's one place, so the graph reaches the same files the PP walk
        // will (FileImportIndex::_resolve applies the identical rule, the
        // plain form's migration fallback included, through the same
        // resolver entry points).
        var from_dir = self._sm->get_file_dir(from_fid)
        var has_dir  = from_dir.full_path().size() > 0

        if spec.last_seg_is_macro && !(spec.is_wildcard || spec.items.size() > 0) {
            segs.pop_back() // last seg is the macro name
            if segs.size() == 0 {
                return
            }
        }

        // A plain path may end in a symbol, not a module: try the full
        // path, then without its last segment.
        var may_drop = !spec.is_wildcard && spec.items.size() == 0 && !spec.last_seg_is_macro

        if spec.kind == ImportKind::Native {
            dep = self._resolve_place(segs, may_drop, false, from_dir, from_dir, has_dir)
            if dep.fid == u32::MAX && has_dir {
                dep = self._resolve_place(segs, may_drop, true, from_dir, from_dir, has_dir)
            }
        } else if has_dir {
            var anchor = from_dir
            if spec.kind == ImportKind::ModuleRelative {
                var mdir = module_dir_at_or_above(from_dir.full_path())
                if mdir.empty() { // the PP walk reports it
                    return
                }

                anchor = Path(mdir)
            }

            dep = self._resolve_place(segs, may_drop, true, anchor, from_dir, has_dir)
        }

        if dep.fid == u32::MAX { // unresolved: silent here; the PP walk errors
            return
        }

        // A BACK edge -- the target is still on the scan's stack, so this
        // import closes a cycle (`a` imports `b` imports `a`, or a file that
        // imports itself) -- is recorded and left out of the graph. A cycle
        // is an error (modules.mdx, Circular Dependencies), which the
        // preprocessor reports from `cycles`. The edge stays out so the
        // waves still walk every file: with it, each file on the cycle waits
        // on another, none is ever walked, and the cycle used to vanish
        // from the build with exit 0 -- no error, and no file to point one at.
        if self._visiting.contains(dep.fid as u64) {
            var cyc = cxx::std::vector<u32>()
            var on  = false
            for var i: usize = 0; i < self._stack.size(); ++i {
                if self._stack[i] == dep.fid {
                    on = true
                }

                if on {
                    cyc.push_back(self._stack[i])
                }
            }

            graph->cycles.push_back(cyc)
            return
        }

        self.visit(dep.fid, dep.mod_path, graph, depth + 1)
        graph->add_edge(from_fid, dep.fid)
    }

    struct DepResult {
        /// u32(-1) when unresolved. Not 0: that is the first file loaded,
        /// an input a later input may import (`kairo foo.k main.k`).
        var fid:      u32
        var mod_path: ModulePath
    }

    /// \details `mod_path` is the resolution's CANONICAL identity (segments
    ///          from the owning search root), never the written spelling.
    ///          This path becomes the file's ASTContext::module_base and, from
    ///          there, its C++ namespace path - so it must be a property of
    ///          where the file lives, not of whoever imported it first.
    ///          Ambiguity is not diagnosed here (no DiagEngine in the scanner);
    ///          the PP walk re-resolves and owns that error.
    priv fn _resolve_place(self,
                           segments:       cxx::std::vector<string>,
                           may_drop:       bool,
                           in_dir:         bool,
                           const dir:      Path,
                           const from_dir: Path,
                           has_from:       bool) -> Self::DepResult {
        var dep = self.resolve_segments(segments, in_dir, dir, from_dir, has_from)
        if dep.fid == u32::MAX && may_drop && segments.size() > 1 {
            var shorter = segments
            shorter.pop_back() // last seg was a symbol
            dep = self.resolve_segments(shorter, in_dir, dir, from_dir, has_from)
        }

        return dep
    }

    priv fn resolve_segments(self,
                             segments:       cxx::std::vector<string>,
                             in_dir:         bool,
                             const dir:      Path,
                             const from_dir: Path,
                             has_from:       bool) -> Self::DepResult {
        var result = Self::DepResult()
        result.fid = u32::MAX

        if segments.size() == 0 {
            return result
        }

        var rr: ModuleResolution
        if in_dir {
            rr = self._resolver->resolve_module_in(segments, dir)
        } else {
            rr = self._resolver->resolve_module_rel(segments, from_dir, has_from)
        }

        if !rr.found {
            return result
        }

        var fid = self._sm->load_file(rr.path)
        if fid != (u32::MAX as FileID) {
            result.fid      = fid
            result.mod_path = self.segments_to_module_path(rr.canonical)
        }

        return result
    }

    priv fn segments_to_module_path(self, segments: cxx::std::vector<string>) -> ModulePath {
        var path = ModulePath()
        for *seg in segments {
            var ident = IdentifierToken()
            ident.name  = self._sym_table->intern(*seg)
            ident.token = &null
            path.segments.push_back(ident)
        }

        return path
    }
}
