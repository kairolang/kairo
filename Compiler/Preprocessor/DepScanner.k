/// --- The Kairo Project -------------------- Preprocessor/DepScanner.k --- ///
///
///   Single-threaded single file DAG builder.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Token::TokenCacheManager::*;
import Token::TokenText::*;
import Resolution::ImportProbe::*;
import Location::SourceManager::*;
import Resolution::ModulePath::*;
import Preprocessor::TokenSource::*;
import Preprocessor::StreamCursor::*;

// FIXME: on a big project root with many files, DepScanner makes a lot of
//        temporary allocations (178k with 280k files) which adds up to a
//        significant portion of the runtime (848ms of 2.5s total).
//
// This is mostly due to the map/set usage in DepGraph and the temporary
//     vectors/strings in scan_import. We should optimize this by using more
//     efficient data structures (e.g. flat_hash_map) and by reusing memory
//     where possible (e.g. string interning for module paths).

struct DepEdge {
    var from_fid:        u32;
    var to_fid:          u32;
    var to_module_path:  ModulePath;
}

class DepGraph {
    pub var deps:      map::<u32, set::<u32>>;   ///< fid -> fids it depends on
    pub var rdeps:     map::<u32, set::<u32>>;   ///< fid -> fids that depend on it
    pub var in_degree: map::<u32, i32>;          ///< fid -> number of unprocessed deps
    pub var mod_paths: map::<u32, ModulePath>;   ///< fid -> its module path
    pub var all_fids:  set::<u32>;               ///< every fid in the graph

    fn add_node(self, fid: u32, path: ModulePath) {
        if !self.all_fids.contains(fid) {
            self.all_fids.insert(fid);
            self.deps[fid]      = set::<u32>();
            self.rdeps[fid]     = set::<u32>();
            self.in_degree[fid] = 0;
            self.mod_paths[fid] = path;
        }
    }

    fn add_edge(self, from: u32, to: u32) {
        if !(self.deps[from].contains(to)) {
            (self.deps[from]).insert(to);
            (self.rdeps[to]).insert(from);
            (self.in_degree[from]) += 1;
        }
    }

    fn roots(self) -> vec::<u32> {
        var result = vec::<u32>();
        for fid in self.all_fids {
            if self.in_degree[fid] == 0 {
                result.push_back(fid);
            }
        }
        return result;
    }
}

class DepScanner {
    priv var _sm:          obs::<SourceManager>;
    priv var _tcm:         obs::<TokenCacheManager>;
    priv var _resolver:    obs::<ImportResolver>;
    priv var _sym_table:   obs::<PreprocessorSymbolTable>;
    priv var _visiting:    set::<u32>;   ///< cycle detection

    fn DepScanner(
        self,
        sm:        *SourceManager,
        tcm:       *TokenCacheManager,
        resolver:  *ImportResolver,
        sym_table: *PreprocessorSymbolTable
    ) {
        self._sm        = sm;
        self._tcm       = tcm;
        self._resolver  = resolver;
        self._sym_table = sym_table;
    }

    /// \brief entry point - builds the full dep graph rooted at entry_fid
    fn build_graph(self, entry_fid: u32, entry_path: ModulePath) -> DepGraph {
        var graph = DepGraph();
        self.visit(entry_fid, entry_path, &graph);
        return graph;
    }

    priv fn visit(self, fid: u32, mod_path: ModulePath, graph: *DepGraph) {
        if graph->all_fids.contains(fid) { return; }
        if self._visiting.contains(fid)  { return; } // cycle

        graph->add_node(fid, mod_path);
        self._visiting.insert(fid);
        finally { self._visiting.erase(fid); }

        var stream = self._tcm->open_scan_stream(fid);
        if stream.lexer == &null { return; }
        finally { self._tcm->close_scan_stream(&stream); }

        var src = TokenSource(stream.lexer);
        var cur = StreamCursor(&src, &null); // scan-only: silent

        while !src.at_eof() {
            var k = src.peek(0).kind;
            if k == TokenKind::TkEof { break; }

            if k == TokenKind::KwFfi {
                self._skip_ffi_stream(&src);
                continue;
            }

            // visibility prefix: DAG cares only about `<vis> import`
            if (k == TokenKind::KwPub) || (k == TokenKind::KwPriv) || (k == TokenKind::KwProt) {
                if src.peek(1).kind == TokenKind::KwImport {
                    src.next(); // drop vis keyword
                    self._scan_one_import(&cur, fid, graph);
                    continue;
                }
                src.next();
                continue;
            }

            if k == TokenKind::KwImport {
                self._scan_one_import(&cur, fid, graph);
                continue;
            }

            src.next(); // everything else: skip
        }
    }

    priv fn _skip_ffi_stream(self, src: *TokenSource) {
        src->next();                                   // ffi
        if src->peek(0).kind == TokenKind::LitString { src->next(); } // "lang"

        var k = src->peek(0).kind;
        if k == TokenKind::KwImport {
            // ffi "lang" import "hdr" ; no fid dep, drop to terminator
            while !src->at_eof() {
                var t = src->next();
                if t.kind == TokenKind::OpSemicolon { break; }
                if t.kind == TokenKind::TkNewLine   { break; } // VERIFY: is `;` mandatory
                                                            // on ffi imports? if yes,
                                                            // delete this line
            }
            return;
        }
        if k == TokenKind::OpLBrace {
            var depth: i32 = 0;
            while !src->at_eof() {
                var t = src->next();
                if t.kind == TokenKind::OpLBrace { depth += 1; }
                if t.kind == TokenKind::OpRBrace {
                    depth -= 1;
                    if depth == 0 { return; }
                }
            }
            return;
        }
        // ffi "lang" <single decl> nothing here creates a dep; let the walk skip it
    }

    /// drives the shared grammar, resolves, recurses, adds the edge.
    priv fn _scan_one_import(self, cur: *StreamCursor, from_fid: u32, graph: *DepGraph) {
        var spec = cur->parse_import_spec();
        if !spec.ok { return; }

        // trailing `;`
        if cur->ig_kind() == TokenKind::OpSemicolon { cur->ig_bump(); }

        var segs = vec::<string>();
        for var i: usize = 0; i < spec.segments.size(); ++i {
            segs.push_back(TokenText::spelling(spec.segments[i], self._tcm));
        }
        if segs.size() == 0 { return; }

        // which segments name the FILE?
        //   wildcard / braced / bang-on-last: base is all-but-nothing / all-but-last
        //   plain path: try full, then drop last (it may be a symbol, not a module)
        var dep = DepResult();

        if spec.is_wildcard || (spec.items.size() > 0) {
            dep = self.resolve_segments(segs, spec.is_module);
        } else if spec.last_seg_is_macro {
            segs.pop_back();                       // last seg is the macro name
            if segs.size() == 0 { return; }
            dep = self.resolve_segments(segs, spec.is_module);
        } else {
            dep = self.resolve_segments(segs, spec.is_module);
            if dep.fid == 0 && segs.size() > 1 {
                segs.pop_back();                   // last seg was a symbol
                dep = self.resolve_segments(segs, spec.is_module);
            }
        }

        if dep.fid == 0 { return; }   // unresolved: silent here; the PP walk errors

        self.visit(dep.fid, dep.mod_path, graph);
        graph->add_edge(from_fid, dep.fid);
    }

    struct DepResult {
        var fid:      u32;
        var mod_path: ModulePath;
    }

    priv fn resolve_segments(self, segments: vec::<string>, is_module: bool) -> DepResult {
        var result = DepResult();
        result.fid = 0;

        if segments.size() == 0 { return result; }

        var resolved: std::Expected::<Path, ResolveError>;
        if is_module {
            resolved = self._resolver->resolve_module_dir(segments);
        } else {
            resolved = self._resolver->resolve_module(segments);
        }

        if !resolved.check() {
            if resolved.err() == ResolveError::AmbiguousModule {
                var retry = self._resolver->resolve_module(segments);
                if retry.check() {
                    var fid = self._sm->load_file(*retry);
                    if fid != 0 {
                        result.fid = fid;
                        result.mod_path = self.segments_to_module_path(segments);
                    }
                }
            }
            return result;
        }

        var fid = self._sm->load_file(*resolved);
        if fid != 0 {
            result.fid      = fid;
            result.mod_path = self.segments_to_module_path(segments);
        }

        return result;
    }

    priv fn segments_to_module_path(self, segments: vec::<string>) -> ModulePath {
        var path = ModulePath();
        for seg in segments {
            var ident = IdentifierToken();
            ident.name  = self._sym_table->intern(seg);
            ident.token = &null;
            path.segments.push_back(ident);
        }
        return path;
    }
}