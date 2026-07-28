/// --- The Kairo Project --------------- Preprocessor/FileImportIndex.k --- ///
///
///   Per-fid resolved-import index, built from ImportDecl nodes during the
///   PP walk. The nodes are the authority (they live in the TU for klib);
///   this index is a lookup accelerator over them, plus the resolution
///   results (source fids / scopes) the macro resolver needs.
///
///   THE imp::mac! fix: a single-item macro import (`import Foo::mac!`) and
///   the braced form (`import Foo::{mac!}`) both register `mac` (or its
///   alias) in `named`. The old code recorded only a module alias for the
///   single-item form, so bare `mac!` missed. Uniform handling here closes it.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Node::Declarations::*;
import AST::Context::ASTContext::*;
import Resolution::ImportProbe::*;
import Resolution::ModulePath::*;
import Support::FileIO::Path::*;
import Location::SourceManager::*;
import Preprocessor::MacroTable::*;
import Preprocessor::PreprocessorSymbolTable::*;
import Diagnostic::Engine::*;
import Diagnostic::Registry::*;
import Token::TokenText::*;

class FileImportIndex {
    /// alias-name -> resolved macro entry (bare-name macro imports)
    pub var named: map::<SymbolID, obs::<MacroEntry>>;

    /// resolved source scopes for wildcard imports (`import Foo::*`)
    pub var wildcards: vec::<ModulePath>;

    /// module aliases for QUALIFIED invocation (`import Foo` -> Foo::mac!,
    /// `import Foo as f` -> f::mac!)
    pub var module_aliases: map::<SymbolID, ModulePath>;

    priv var _sym:  obs::<PreprocessorSymbolTable>;
    priv var _sm:   obs::<SourceManager>;
    priv var _tcm:  obs::<TokenCacheManager>;
    priv var _res:  obs::<ImportResolver>;
    priv var _tbl:  obs::<MacroTable>;
    priv var _diag: obs::<DiagEngine>;
    priv var _fid:  u32;

    /// This file's own directory: the FIRST place an unqualified import path
    /// is looked for (see ImportResolver::resolve_module_rel).
    priv var _dir:      Path;
    priv var _has_dir:  bool = false;

    fn FileImportIndex(self, sym: *PreprocessorSymbolTable, sm: *SourceManager,
                       tcm: *TokenCacheManager, res: *ImportResolver,
                       tbl: *MacroTable, diag: *DiagEngine, fid: u32) {
        self._sym  = sym;
        self._sm   = sm;
        self._tcm  = tcm;
        self._res  = res;
        self._tbl  = tbl;
        self._diag = diag;
        self._fid  = fid;

        self._dir     = sm->get_file_dir(fid);
        self._has_dir = self._dir.full_path().size() > 0;
    }

    priv fn _spell(self, t: Token) -> string {
        return TokenText::spelling(t, self._tcm);
    }

    /// resolves an ImportDecl and records its macro-relevant surface.
    /// ffi imports are never passed here (walk skips them).
    /// Returns the resolved source-module fid (0 = unresolved), and stamps it
    /// onto `id->resolved_fid` as the one writer of that fact. The caller
    /// (Preprocessor::_handle_import) turns a non-zero return into a TU import
    /// edge; a zero return contributes no edge.
    fn record(self, id: *ImportDecl) -> u32 {
        // --- base path segments -> strings ---------------------------------
        var segs = vec::<string>();
        for var i: usize = 0; i < id->path_segments.size(); ++i {
            segs.push_back(self._spell(id->path_segments[i]));
        }
        if segs.size() == 0 { return 0; }

        // --- selective / wildcard / bare split ----------------------------
        if id->is_wildcard {
            var rr = self._resolve(segs, id->import_kind == ImportKind::ModuleOnly, id->range);
            if rr.found { self.wildcards.push_back(rr.source_scope); id->resolved_fid = rr.target_fid; return rr.target_fid; }
            else        { self._unresolved(id, segs); return 0; }
        }

        if id->has_items {
            var rr = self._resolve(segs, id->import_kind == ImportKind::ModuleOnly, id->range);
            if !rr.found { self._unresolved(id, segs); return 0; }
            // always record the module alias too (Foo::{...} still allows Foo::x)
            self.module_aliases[self._sym->intern(segs[segs.size() - 1])] = rr.full_scope;
            id->resolved_fid = rr.target_fid;

            for var i: usize = 0; i < id->items.size(); ++i {
                var it =id->items[i];
                if it.is_wildcard { self.wildcards.push_back(rr.source_scope); continue; }
                if !it.is_macro   { continue; } // non-macro items are the AST's concern

                // item scope = source_scope + all-but-last sub_path segment
                var item_scope = rr.source_scope;
                for var s: usize = 0; (it.sub_path.size() > 0) && (s + 1 < it.sub_path.size()); ++s {
                    var seg_id = IdentifierToken();
                    seg_id.name  = self._sym->intern(self._spell(it.sub_path[s]));
                    seg_id.token = &null;
                    item_scope.segments.push_back(seg_id);
                }
                var last = it.sub_path[it.sub_path.size() - 1];
                var name_sym  = self._sym->intern(self._spell(last));
                var alias_sym = (self._sym->intern(self._spell(it.alias))) if (it.has_alias) else (name_sym);

                self._record_named(item_scope, name_sym, alias_sym, it.range);
            }
            return rr.target_fid;
        }

        // --- bare path ----------------------------------------------------
        if id->last_seg_is_macro {
            // `import Foo::mac!` resolve Foo (all but last), macro = last seg.
            // THE fix: register the bare name uniformly with the braced form.
            var base = vec::<string>();
            for var i: usize = 0; i + 1 < segs.size(); ++i { base.push_back(segs[i]); }

            var rr = self._resolve(base, id->import_kind == ImportKind::ModuleOnly, id->range);
            if !rr.found { self._unresolved(id, segs); return 0; }

            var name_sym  = self._sym->intern(segs[segs.size() - 1]);
            var alias_sym = (self._sym->intern(self._spell(id->alias))) if (id->has_alias) else (name_sym);
            self._record_named(rr.source_scope, name_sym, alias_sym, id->range);
            id->resolved_fid = rr.target_fid;
            return rr.target_fid;
        }

        // plain `import Foo` / `import Foo::Bar` / `import Foo as m`
        var rr = self._resolve(segs, id->import_kind == ImportKind::ModuleOnly, id->range);
        if !rr.found { self._unresolved(id, segs); return 0; }

        var alias_key = (self._sym->intern(self._spell(id->alias)))
            if (id->has_alias)
            else (self._sym->intern(segs[segs.size() - 1]));
        self.module_aliases[alias_key] = rr.full_scope;
        id->resolved_fid = rr.target_fid;
        return rr.target_fid;
    }

    // --- named macro import: resolve eagerly, enforce visibility ----------

    priv fn _record_named(self, scope: ModulePath, name: SymbolID,
                          alias: SymbolID, loc: SourceRange) {
        var entry = self._tbl->find(scope, name, self._fid);
        if entry == &null {
            // could be unresolved OR a visibility violation find() returns
            // null for both. Distinguish for a good message:
            var raw = self._tbl->find_ignoring_visibility(scope, name);
            if raw != &null {
                self._diag->report(DiagCode(DiagID::R011E), loc.start,
                    f"macro '{self._sym_name(name)}!' is not visible here (it is declared "
                    "private or protected in its module)"
                ).first(loc).emit();
            } else {
                self._diag->report(DiagCode(DiagID::R011E), loc.start,
                    f"cannot resolve imported macro '{self._sym_name(name)}!\x27"
                ).first(loc).emit();
            }
            return;
        }
        self.named[alias] = entry;
    }

    priv fn _sym_name(self, id: SymbolID) -> string {
        var p = self._sym->resolve(id);
        return ("<unknown>") if (p == &null) else (*p);
    }

    // --- resolution glue over ImportResolver ------------------------------

    struct ResolveOut {
        var found:        bool = false;
        var source_scope: ModulePath;  ///< scope to look up the imported symbol in
        var full_scope:   ModulePath;  ///< module alias target (source + resolved prefix)
        var target_fid:   u32 = 0;     ///< source-module fid (the file the import points at)
    }

    /// greedy longest-prefix resolution behavior ported from
    /// ImportProcessor::resolve_module_greedy (that logic was correct).
    ///
    /// Path semantics live in ImportResolver::resolve_module_rel: this file's
    /// own directory is probed before the search roots, and a name matching
    /// both is a hard error (R017E) rather than a silent winner. The scopes
    /// handed back are built on the resolution's CANONICAL segments, not on
    /// the segments the import spelled, so a module's identity (and therefore
    /// its C++ namespace path) is the same in every file that imports it.
    priv fn _resolve(self, segs: vec::<string>, is_module: bool, at: SourceRange) -> ResolveOut {
        var out = ResolveOut();
        if segs.size() == 0 { return out; }

        var try_len = segs.size();
        while try_len > 0 {
            var try_segs = vec::<string>();
            for var i: usize = 0; i < try_len; ++i { try_segs.push_back(segs[i]); }

            var rr = self._res->resolve_module_rel(try_segs, is_module,
                                                   self._dir, self._has_dir);

            // `import module Foo` with no Foo/module.k: fall back to a plain
            // module resolution, matching the old AmbiguousModule retry.
            if (!rr.found) && is_module {
                rr = self._res->resolve_module_rel(try_segs, false,
                                                   self._dir, self._has_dir);
                if rr.found {
                    self._diag->report(DiagCode(DiagID::R005W),
                        f"ambiguous module '{self._join(try_segs)}': a file and a directory both exist; the file is used"
                    ).emit();
                }
            }

            if rr.found {
                if rr.ambiguous {
                    // Sibling and root both matched. Erroring here is what
                    // keeps sibling-first from becoming Python 2's implicit
                    // relative import, where adding a file at the root
                    // silently changes what an import three levels down means.
                    self._diag->report(DiagCode(DiagID::R017E), at.start,
                        f"ambiguous import '{self._join(try_segs)}': it matches both '{rr.path.full_path()}' and '{rr.other_path.full_path()}'; qualify the path to say which one you mean"
                    ).first(at).emit();
                }

                var fid = self._sm->load_file(rr.path);
                if fid != 0 {
                    // canonical ++ whatever the import spelled past the file:
                    // for a root-relative import this is exactly the old
                    // `segs`, so nothing changes for existing code.
                    var src = rr.canonical;
                    for var i: usize = try_len; i < segs.size(); ++i { src.push_back(segs[i]); }

                    out.found        = true;
                    out.source_scope = self._segs_to_path(src);
                    out.full_scope   = self._segs_to_path(rr.canonical);
                    out.target_fid   = fid;
                    self._drain_collisions();
                    return out;
                }
            }
            try_len -= 1;
        }
        self._drain_collisions();
        return out;
    }

    /// Report module-name collisions discovered by the resolver's directory
    /// sweep. Two files claiming one module identity is the same fault as an
    /// ambiguous import, one layer down, so it is found in the same pass; the
    /// resolver sweeps each directory once, so each collision is reported once
    /// no matter how many imports walk through it.
    priv fn _drain_collisions(self) {
        var found = self._res->take_collisions();
        for var i: usize = 0; i < found.size(); ++i {
            var c = found[i];
            if c.case_only {
                self._diag->report(DiagCode(DiagID::P002E),
                    f"'{c.a}' and '{c.b}' in '{c.dir}' differ only by case: they are two "
                    "modules on Linux and one file on default macOS/Windows; rename one"
                ).emit();
            } else {
                self._diag->report(DiagCode(DiagID::R018E),
                    f"'{c.a}' and '{c.b}' in '{c.dir}' both name module '{c.ident}' "
                    "('-' in a module filename means '_'); rename one"
                ).emit();
            }
        }
    }

    priv fn _segs_to_path(self, segs: vec::<string>) -> ModulePath {
        var p = ModulePath();
        for var i: usize = 0; i < segs.size(); ++i {
            var id = IdentifierToken();
            id.name  = self._sym->intern(segs[i]);
            id.token = &null;
            p.segments.push_back(id);
        }
        return p;
    }

    priv fn _join(self, segs: vec::<string>) -> string {
        var s = "";
        for var i: usize = 0; i < segs.size(); ++i {
            if i > 0 { s += "::"; }
            s += segs[i];
        }
        return s;
    }

    priv fn _unresolved(self, id: *ImportDecl, segs: vec::<string>) {
        self._diag->report(DiagCode(DiagID::R011E), id->range.start,
            f"failed to resolve import path '{self._join(segs)}\x27"
        ).first(id->range).emit();
    }
}