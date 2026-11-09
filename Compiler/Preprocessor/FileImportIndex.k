/// --- The Kairo Project --------------- Preprocessor/FileImportIndex.k --- ///
///
///   FileImportIndex: one file's resolved imports, built in the PP walk.
///
///   The ImportDecl nodes are the authority (they live in the TU for klib);
///   this index is a lookup accelerator over them, plus the resolution results
///   (source fids / scopes) the macro resolver needs.
///
///   A single-item macro import (`import Foo::mac!`) and the braced form
///   (`import Foo::{mac!}`) both register `mac` (or its alias) in `named`, so a
///   bare `mac!` resolves after either.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "vector"

import AST::Node::Declarations::{
    ImportDecl,
    ImportKind,
}
import Diagnostic::Code::DiagCode
import Diagnostic::Engine::DiagEngine
import Diagnostic::Registry::DiagID
import Location::SourceManager::{
    FileID,
    SourceManager,
}
import Location::SourceRange::SourceRange
import Preprocessor::MacroTable::{
    MacroEntry,
    MacroTable,
}
import Preprocessor::PreprocessorSymbolTable::{
    PreprocessorSymbolTable,
    SymbolID,
}
import Resolution::ImportProbe::{
    ImportResolver,
    ModuleResolution,
}
import Resolution::ModulePath::ModulePath
import Resolution::SearchRoot::module_dir_at_or_above
import Support::FileIO::Path::Path
import Token::IdentifierToken::IdentifierToken
import Token::Token::Token
import Token::TokenCacheManager::TokenCacheManager
import Token::TokenText::TokenText

pub class FileImportIndex {
    /// alias-name -> resolved macro entry (bare-name macro imports). Both
    /// maps are keyed `sym as u64` (a u32 key would reserve two SymbolIDs as
    /// DenseMap's empty/tombstone) and are only probed, never iterated.
    pub var named: llvm::DenseMap<u64, unsafe *MacroEntry>

    /// resolved source scopes for wildcard imports (`import Foo::*`)
    pub var wildcards: cxx::std::vector<ModulePath>

    /// module aliases for QUALIFIED invocation (`import Foo` -> Foo::mac!,
    /// `import Foo as f` -> f::mac!)
    pub var module_aliases: llvm::DenseMap<u64, ModulePath>

    priv var _sym:  *PreprocessorSymbolTable
    priv var _sm:   *SourceManager
    priv var _tcm:  unsafe *TokenCacheManager
    priv var _res:  *ImportResolver
    priv var _tbl:  *MacroTable
    priv var _diag: *DiagEngine
    priv var _fid:  u32

    /// This file's own directory: where `import self::x` looks, and the
    /// plain form's migration fallback (see _resolve).
    priv var _dir:     Path
    priv var _has_dir: bool = false

    fn FileImportIndex(self,
                       sym:  *PreprocessorSymbolTable,
                       sm:   *SourceManager,
                       tcm:  unsafe *TokenCacheManager,
                       res:  *ImportResolver,
                       tbl:  *MacroTable,
                       diag: *DiagEngine,
                       fid:  u32) {
        self._sym  = sym
        self._sm   = sm
        self._tcm  = tcm
        self._res  = res
        self._tbl  = tbl
        self._diag = diag
        self._fid  = fid

        self._dir     = sm->get_file_dir(fid)
        self._has_dir = self._dir.full_path().size() > 0
    }

    priv fn _spell(self, t: Token) -> string {
        return TokenText::spelling(t, self._tcm)
    }

    /// resolves an ImportDecl and records its macro-relevant surface.
    /// ffi imports are never passed here (walk skips them).
    /// Returns the resolved source-module fid (0 = unresolved), and stamps it
    /// onto `id->resolved_fid` as the one writer of that fact. The caller
    /// (Preprocessor::_handle_import) turns a non-zero return into a TU import
    /// edge; a zero return contributes no edge.
    fn record(self, id: unsafe *ImportDecl) -> u32 {
        /// ## base path segments -> strings
        var segs = cxx::std::vector<string>()
        for var i: usize = 0; i < id->path_segments.size(); ++i {
            segs.push_back(self._spell(id->path_segments[i]))
        }

        if segs.size() == 0 {
            return 0
        }

        /// ## selective / wildcard / bare split
        if id->is_wildcard {
            var rr = self._resolve(segs, id)
            if rr.found {
                self.wildcards.push_back(rr.source_scope)
                id->resolved_fid   = rr.target_fid
                id->file_seg_count = (rr.seg_count as u32)
                return rr.target_fid
            } else {
                self._unresolved(id, segs)
                return 0
            }
        }

        if id->has_items {
            var rr = self._resolve(segs, id)
            if !rr.found {
                self._unresolved(id, segs)
                return 0
            }

            // always record the module alias too (Foo::{...} still allows Foo::x)
            self.module_aliases[self._sym->intern(segs[segs.size() - 1]) as u64] = rr.full_scope
            id->resolved_fid                                                     = rr.target_fid
            id->file_seg_count = (rr.seg_count as u32)

            for var i: usize = 0; i < id->items.size(); ++i {
                var it = id->items[i]
                if it.is_wildcard {
                    self.wildcards.push_back(rr.source_scope)
                    continue
                }

                if !it.is_macro { // non-macro items are the AST's concern
                    continue
                }

                // item scope = source_scope + all-but-last sub_path segment
                var item_scope = rr.source_scope
                for var s: usize = 0; it.sub_path.size() > 0 && s + 1 < it.sub_path.size(); ++s {
                    var seg_id = IdentifierToken()
                    seg_id.name  = self._sym->intern(self._spell(it.sub_path[s]))
                    seg_id.token = &null
                    item_scope.segments.push_back(seg_id)
                }

                var last     = it.sub_path[it.sub_path.size() - 1]
                var name_sym = self._sym->intern(self._spell(last))
                var alias_sym = if (it.has_alias) => (self._sym->intern(self._spell(it.alias)))
                                else => name_sym

                self._record_named(item_scope, name_sym, alias_sym, it.range)
            }

            return rr.target_fid
        }

        /// ## bare path
        if id->last_seg_is_macro {
            // `import Foo::mac!` resolve Foo (all but last), macro = last seg.
            // THE fix: register the bare name uniformly with the braced form.
            var base = cxx::std::vector<string>()
            for var i: usize = 0; i + 1 < segs.size(); ++i {
                base.push_back(segs[i])
            }

            var rr = self._resolve(base, id)
            if !rr.found {
                self._unresolved(id, segs)
                return 0
            }

            var name_sym = self._sym->intern(segs[segs.size() - 1])
            var alias_sym = if (id->has_alias) => (self._sym->intern(self._spell(id->alias)))
                            else => name_sym
            self._record_named(rr.source_scope, name_sym, alias_sym, id->range)
            id->resolved_fid   = rr.target_fid
            id->file_seg_count = (rr.seg_count as u32)
            return rr.target_fid
        }

        // plain `import Foo` / `import Foo::Bar` / `import Foo as m`
        var rr = self._resolve(segs, id)
        if !rr.found {
            self._unresolved(id, segs)
            return 0
        }

        var alias_key = if (id->has_alias) => (self._sym->intern(self._spell(id->alias)))
                        else => self._sym->intern(segs[segs.size() - 1])
        self.module_aliases[alias_key as u64] = rr.full_scope
        id->resolved_fid                      = rr.target_fid
        id->file_seg_count                    = (rr.seg_count as u32)
        return rr.target_fid
    }

    /// # named macro import: resolve eagerly, enforce visibility

    priv fn _record_named(self,
                          const scope: ModulePath,
                          name:        SymbolID,
                          alias:       SymbolID,
                          loc:         SourceRange) {
        var unsafe *entry = self._tbl->find(scope, name, self._fid)
        if entry == &null {
            // could be unresolved OR a visibility violation find() returns
            // null for both. Distinguish for a good message:
            var unsafe *raw = self._tbl->find_ignoring_visibility(scope, name)
            if raw != &null {
                self._diag->report(
                    DiagCode(DiagID::R011E),
                    loc.start,
                    f"macro '{self._sym_name(name)}!' is not visible here (it is declared "
                    "private or protected in its module)",
                ).first(loc)->emit()
            } else {
                self._diag->report(
                    DiagCode(DiagID::R011E),
                    loc.start,
                    f"cannot resolve imported macro '{self._sym_name(name)}!'",
                ).first(loc)->emit()
            }

            return
        }

        self.named[alias as u64] = entry
    }

    priv fn _sym_name(self, id: SymbolID) -> string {
        var unsafe *p = self._sym->resolve(id)
        return if (p == &null) => ("<unknown>") else => *p
    }

    /// # resolution glue over ImportResolver

    struct ResolveOut {
        var found:        bool       = false
        var source_scope: ModulePath         ///< scope to look up the imported symbol in
        var full_scope:   ModulePath         ///< module alias target (source + resolved prefix)
        var target_fid:   u32        = 0     ///< source-module fid (the file the import points at)
        var seg_count:    usize      = 0     ///< leading segments consumed to reach that file
    }

    /// greedy longest-prefix resolution behavior ported from
    /// ImportProcessor::resolve_module_greedy (that logic was correct).
    ///
    /// Path semantics live in ImportResolver: each import form looks in one
    /// place -- the search roots (plain), this file's directory (`self::`)
    /// or this file's module root (`module::`). The scopes handed back are
    /// built on the resolution's CANONICAL segments, not on the segments
    /// the import spelled, so a module's identity (and therefore its C++
    /// namespace path) is the same in every file that imports it, however
    /// it was anchored.
    priv fn _resolve(self,
                     const segs: cxx::std::vector<string>,
                     id:         unsafe *ImportDecl) -> Self::ResolveOut {
        var out = Self::ResolveOut()
        if segs.size() == 0 {
            return out
        }

        // The one place this form looks.
        var in_dir = id->import_kind != ImportKind::Native
        var anchor = self._dir
        if id->import_kind == ImportKind::ModuleRelative {
            var mdir = if (self._has_dir) => (module_dir_at_or_above(self._dir.full_path()))
                       else => ""
            if mdir.empty() {
                self._no_module_root(id, segs)
                return out
            }

            anchor = Path(mdir)
        } else if in_dir && !self._has_dir {
            return out // no file, no directory: _unresolved reports it
        }

        out = self._resolve_greedy(segs, id, in_dir, anchor)

        // Migration (Compiler/Spec/Imports.md#migration): the plain form
        // used to look beside the importing file first. A path only that
        // directory holds still resolves -- to the file it always meant --
        // and is reported with the `self::` that says so. Tried only once
        // every root has missed every prefix, so a root answer is never
        // overridden by the old rule.
        if !out.found && id->import_kind == ImportKind::Native && self._has_dir {
            out = self._resolve_greedy(segs, id, true, self._dir)
            if out.found {
                self._legacy_sibling(id, segs, out.seg_count)
            }
        }

        self._drain_collisions()
        return out
    }

    /// The longest prefix of \p segs that names a module, in the search
    /// roots or (\p in_dir) in \p dir alone.
    priv fn _resolve_greedy(self,
                            segs:      cxx::std::vector<string>,
                            id:        unsafe *ImportDecl,
                            in_dir:    bool,
                            const dir: Path) -> Self::ResolveOut {
        var out     = Self::ResolveOut()
        var at      = id->range
        var try_len = segs.size()
        while try_len > 0 {
            var try_segs = cxx::std::vector<string>()
            for var i: usize = 0; i < try_len; ++i {
                try_segs.push_back(segs[i])
            }

            var rr: ModuleResolution
            if in_dir {
                rr = self._res->resolve_module_in(try_segs, dir)
            } else {
                rr = self._res->resolve_module_rel(try_segs, self._dir, self._has_dir)
            }

            if rr.found {
                if rr.ambiguous && rr.cross_root {
                    // Two unnamed search dirs hold one path. Qualifying
                    // cannot help: an unnamed dir has no name to write. One
                    // file has to go, or be pinned into a library of its own.
                    self._diag->report(
                        DiagCode(DiagID::R017E),
                        at.start,
                        f"ambiguous import '{self._join(try_segs)}': it matches both '{rr.path.full_path()}' and '{rr.other_path.full_path()}', in two search directories; a search directory adds nothing to a module path, so no spelling tells them apart: remove or rename one, or pin one as a library with a module.k",
                    ).first(at)->emit()
                }

                if rr.file_dir {
                    // `foo.k` and `foo/module.k` in the one place this form
                    // looks. Each would be module `foo`; the file answers so
                    // the import does not cascade into "not found".
                    self._diag->report(
                        DiagCode(DiagID::R005E),
                        at.start,
                        f"ambiguous module '{self._join(try_segs)}': both '{rr.path.full_path()}' and '{rr.dir_path.full_path()}' are that module; rename or remove one",
                    ).first(at)->emit()
                }

                // u32(-1) is the miss. 0 is a file: the first input, which a
                // later input may import (`kairo foo.k main.k`).
                var fid = self._sm->load_file(rr.path)
                if fid != (u32::MAX as FileID) {
                    // canonical ++ whatever the import spelled past the file:
                    // for a root-relative import this is exactly the old
                    // `segs`, so nothing changes for existing code.
                    var src = rr.canonical
                    for var i: usize = try_len; i < segs.size(); ++i {
                        src.push_back(segs[i])
                    }

                    out.found        = true
                    out.source_scope = self._segs_to_path(src)
                    out.full_scope   = self._segs_to_path(rr.canonical)
                    out.target_fid   = fid
                    out.seg_count    = try_len
                    return out
                }
            }

            try_len -= 1
        }

        return out
    }

    /// A plain import only the importing file's directory answered.
    priv fn _legacy_sibling(self,
                            id:        unsafe *ImportDecl,
                            segs:      cxx::std::vector<string>,
                            seg_count: usize) {
        var file = cxx::std::vector<string>()
        for var i: usize = 0; i < seg_count && i < segs.size(); ++i {
            file.push_back(segs[i])
        }

        var first = id->path_segments[0].range
        // An error since the fixtures migrated to `self::`. The import still
        // resolves (to the file the author meant) so one stale line does not
        // cascade into unresolved-name errors; removing the fallback is the
        // two `_resolve_greedy`/`_resolve_place` calls passing self._dir.
        var b = self._diag->report(
            DiagCode(DiagID::R068E),
            first.start,
            f"'{self._join(file)}' is not in any library or search directory; it is the file beside this one, which a plain import no longer reaches: write 'self::{self._join(segs)}'",
        )

        b.first(id->range)
        b.insert(first.start, "self::", "import it from this file\x27s directory")
        b.emit()
    }

    /// `import module::x` in a file with no module.k at or above it.
    priv fn _no_module_root(self, id: unsafe *ImportDecl, segs: cxx::std::vector<string>) {
        var b = self._diag->report(
            DiagCode(DiagID::R069E),
            id->range.start,
            f"cannot import 'module::{self._join(segs)}': this file is in no module",
        )

        b.first(id->range)
        b.note(
            DiagCode(DiagID::R069N),
            id->range.start,
            "'module::' starts at the module root: the nearest directory, at or above this file, that holds a module.k; there is none (an empty module.k is enough), or write 'self::' for a path beside this file",
        )

        b.emit()
    }

    /// Report module-name collisions discovered by the resolver's directory
    /// sweep. Two files claiming one module identity is the same fault as an
    /// ambiguous import, one layer down, so it is found in the same pass; the
    /// resolver sweeps each directory once, so each collision is reported once
    /// no matter how many imports walk through it.
    priv fn _drain_collisions(self) {
        var found = self._res->take_collisions()
        for var i: usize = 0; i < found.size(); ++i {
            var c = found[i]
            if c.case_only {
                self._diag->report(
                    DiagCode(DiagID::P002E),
                    f"'{c.a}' and '{c.b}' in '{c.dir}' differ only by case: they are two "
                    "modules on Linux and one file on default macOS/Windows; rename one",
                ).emit()
            } else {
                self._diag->report(
                    DiagCode(DiagID::R018E),
                    f"'{c.a}' and '{c.b}' in '{c.dir}' both name module '{c.ident}' "
                    "('-' in a module filename means '_'); rename one",
                ).emit()
            }
        }

        // Two files one module path names, and a pinned directory claiming
        // a library's name, found by a resolution (decision E). Fatal for
        // the same reason as a duplicate root: the two would share one C++
        // namespace and one object path.
        for var msg: string in self._res->take_late_collisions() {
            self._diag->report(DiagCode(DiagID::R018E), msg).emit()
        }
    }

    priv fn _segs_to_path(self, const segs: cxx::std::vector<string>) -> ModulePath {
        var p = ModulePath()
        for var i: usize = 0; i < segs.size(); ++i {
            var id = IdentifierToken()
            id.name  = self._sym->intern(segs[i])
            id.token = &null
            p.segments.push_back(id)
        }

        return p
    }

    priv fn _join(self, const segs: cxx::std::vector<string>) -> string {
        var s = ""
        for var i: usize = 0; i < segs.size(); ++i {
            if i > 0 {
                s += "::"
            }

            s += segs[i]
        }

        return s
    }

    priv fn _unresolved(self, id: unsafe *ImportDecl, segs: cxx::std::vector<string>) {
        // `import module::x` with no module root already said why.
        if id->import_kind == ImportKind::ModuleRelative && !self._has_module_root() {
            return
        }

        var shown = self._join(segs)
        if id->import_kind == ImportKind::SelfRelative {
            shown = "self::" + shown
        }

        if id->import_kind == ImportKind::ModuleRelative {
            shown = "module::" + shown
        }

        self._diag->report(
            DiagCode(DiagID::R011E),
            id->range.start,
            f"failed to resolve import path '{shown}'",
        ).first(id->range)->emit()
    }

    priv fn _has_module_root(self) -> bool {
        return self._has_dir && !module_dir_at_or_above(self._dir.full_path()).empty()
    }
}
