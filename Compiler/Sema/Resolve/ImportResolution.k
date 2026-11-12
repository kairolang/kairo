/// --- The Kairo Project -------------- Sema/Resolve/ImportResolution.k --- ///
///
///   \brief Phase I. Build this TU's import_overlay from its ImportDecls, so
///          every name visible in the TU is findable in a local table or the
///          overlay. After I the TU is SELF-CONTAINED: later phases only
///          READ other TUs; the only cross-TU writes go to the locked canonical
///          store and instantiation registry (Compiler/Spec/Imports.md#import-resolution).
///
///   One error, one home (hard invariant #3):
///     - import EXISTENCE (selective miss)  -> here (R015).
///     - import AMBIGUITY (>=2 non-fn same key) -> here (R016), unless
///       every colliding entity came from a header: then N / T at the
///       use, as C++ does (Compiler/Spec/Interop.md#ffi-imports).
///     - import ACCESS ("exists but priv/prot") -> N(b), reading the
///       visibility fact THIS pass records on the overlay entry. Not here.
///
///   Cross-TU discipline: source tables are keyed by the SOURCE TU's imms;
///   this pass spells each imported name and re-interns it BOTH ways once
///   (SymbolTable::lookup_foreign for the source probe, sc->imm_table for the
///   overlay key). The hot unqualified path stays integer-keyed.
///
///   Phase: I. Imports SemaContext, never Sema.k (cycle rule).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "vector"
ffi "c++" import "string"

import AST::Context::DeclContext::DeclContext
import AST::Context::ImportOverlay::{
    ImportOverlay,
    ImportUseLog,
    OverlayEntry,
    OverlayTarget,
    OverlayTargetKind,
    OverlayVisibility,
}
import AST::Context::SymbolTable::{
    DeclNameKind,
    OverloadCell,
    SymbolTable,
}
import AST::Context::TranslationUnit::TranslationUnit
import AST::DeclFacts::{
    decl_ffi_hides_tag,
    decl_is_ffi,
    decl_is_ffi_tag,
    decl_is_ffi_typedef_of,
    decl_name_tok,
    decl_set_ffi_tag_target,
}
import AST::LangItems::{
    cxx_root_name,
    cxx_std_name,
}
import AST::Mixin::Annotation::VisibilityKind
import AST::Node::Base::Decl
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    ClassDecl, EnumDecl,     FunctionDecl, ImportDecl, MacroDecl, ModuleDecl, StructDecl,
    TypeAliasDecl, UnionDecl, VariableDecl,
}
import AST::VisibilityFacts::{
    default_visibility_of,
    reexports_to,
}
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Lexer::Immediate::ImmediateTable
import Location::SourceRange::SourceRange
import Sema::Resolve::MemberLookup::MemberLookup
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Token::Token::Token
import Token::TokenKind::TokenKind
import std::c_char

pub class ImportResolution {
    priv var sc: *SemaContext
    /// The decls already in run()'s `cxx_std` list, by address (never a
    /// reserved key). _collect_cxx_std probed the list linearly for every
    /// header of every ffi import's closure, and the list grows by one
    /// `namespace std` reopening per header: quadratic in the closure.
    priv var _cxx_std_seen: llvm::DenseSet<u64>
    /// Header fids _collect_cxx_std already read this run. Every ffi import's
    /// closure repeats most headers, and a second read of one adds nothing:
    /// its `std` openings are all in _cxx_std_seen and its probe is logged.
    priv var _cxx_std_fids: llvm::DenseSet<u64>
    /// This TU's overlay key for a source table's identifier, by
    /// (src fid << 32 | src imm): every ffi import re-folds most of the same
    /// headers, and re-interning each name was a hash, a byte compare and
    /// the table's lock per row. Filled at the first _add of a row, so
    /// nothing is interned that the fold would not have interned.
    priv var _key_memo: llvm::DenseMap<u64, u32>
    /// The _key_memo slot of the row _fold_all_cells is folding; u64::MAX
    /// outside one (every other _add interns its spelling as before).
    priv var _cur_src: u64 = u64::MAX
    /// Overlay entries whose merged cell is stale. _add rebuilt it on every
    /// target added (linear in the entry, so quadratic per name); nothing
    /// reads it before the overlay is frozen, or through _reexported_cell,
    /// and both flush first (_flush_merged).
    priv var _merge_set:  llvm::DenseSet<u64>
    priv var _merge_list: cxx::std::vector<unsafe *OverlayEntry>

    pub fn ImportResolution(self, sc: *SemaContext) {
        self.sc = sc
    }

    /// Entry point. Allocate the overlay, fold every import into it, freeze.
    fn run(self) -> bool {
        self.sc->require_phase(SemaPhase::Parsed)
        var unsafe *tu = self.sc->tu
        if tu == &null {
            return true
        }

        var unsafe *overlay = self.sc->ctx->alloc_init_pp_cleanup<ImportOverlay>()
        tu->import_overlay = overlay
        if self.sc->opts.log_import_uses {
            overlay->uses = self.sc->ctx->alloc_init_pp_cleanup<ImportUseLog>()
        }

        // Every top-level `std` opening reachable through this TU's ffi
        // closure, accumulated across imports and bound ONCE as `cxx::std`
        // below. Collected here rather than in _resolve_ffi because `cxx` is
        // one name for the whole TU, not one per import.
        var cxx_std = cxx::std::vector<unsafe *Decl>()
        self._cxx_std_seen.clear()
        self._cxx_std_fids.clear()
        var ffi_orig: unsafe *ImportDecl = &null

        for var i: usize = 0; i < tu->imports.size(); ++i {
            var unsafe **slot = tu->imports.at(i) // *(*Decl)
            if slot == &null {
                continue
            }

            var unsafe *id = dyn_cast<ImportDecl>(*slot)
            if id == &null {
                continue
            }

            if id->has_ffi_linkage() && id->resolved_fid != 0 && ffi_orig == &null {
                ffi_orig = id
            }

            self._resolve_one(id, overlay, &cxx_std)
        }

        if cxx_std.size() > 0 && ffi_orig != &null {
            self._bind_cxx(overlay, &cxx_std, ffi_orig)
        }

        if ffi_orig != &null {
            self._bind_ffi_forwards(tu)
        }

        self._flush_merged()
        overlay->freeze()
        return true
    }

    /// One round of the re-export fixpoint of an import cycle. Phase I
    /// folds a wildcard source's re-exports from the source's overlay, which
    /// DAG order guarantees complete -- except on a cycle, where the TUs run
    /// I in lockstep (CompilerInstance::_sema_group) and the one that goes
    /// first folds from an overlay not built yet. A mutual `pub import`
    /// pair then never saw each other's transitive re-exports. The driver
    /// calls this on every TU of the cycle until no overlay grows; each
    /// round adds only targets the overlay does not already hold.
    /// \returns true when this TU's overlay grew.
    pub fn refold_reexports(self) -> bool {
        var unsafe *tu = self.sc->tu
        if tu == &null || tu->import_overlay == &null {
            return false
        }

        var unsafe *overlay = tu->import_overlay
        var        before   = overlay->target_count()
        // A TU whose I ran: the driver's lockstep calls this for every TU
        // of the cycle after the group's I, and again when it resumes the
        // group on the driver, past I, where a round finds nothing new.
        eval if defined!(DEBUG) {
            if (self.sc->phase as u8) < (SemaPhase::ImportsResolved as u8) {
                kairo::std::ice_fail(r"ImportResolution::refold_reexports before phase I")
            }
        }

        overlay->begin_refold()
        for var i: usize = 0; i < tu->imports.size(); ++i {
            var unsafe **slot = tu->imports.at(i)
            if slot == &null {
                continue
            }

            var unsafe *id = dyn_cast<ImportDecl>(*slot)
            if id == &null || id->has_ffi_linkage() || !id->is_wildcard {
                continue
            }

            if id->file_seg_count == 0 {
                continue
            }

            if !((id->file_seg_count as usize) >= id->path_segments.size()) { // a symbol path, not a module.
                continue
            }

            var unsafe *src_tu = self._source_tu(id->resolved_fid)
            if src_tu == &null {
                continue
            }

            self._fold_reexports(id, overlay, src_tu, id->resolved_fid)
        }

        self._flush_merged()
        overlay->end_refold()
        return overlay->target_count() > before
    }

    priv fn _resolve_one(self,
                         id:             unsafe *ImportDecl,
                         overlay:        unsafe *ImportOverlay,
                         @inout cxx_std: cxx::std::vector<unsafe *Decl>) {
        // ffi: clang parsed the header set and Sema/Foreign indexed it into
        // one Kairo TU per header BEFORE sema; the driver stamped the closure
        // (the header and everything it transitively includes) onto the node.
        // resolved_fid 0: the spelling never resolved, and the set's own
        // diagnostics already said so.
        if id->has_ffi_linkage() {
            if id->resolved_fid == 0 {
                return
            }

            self._resolve_ffi(id, overlay, &cxx_std)
            return
        }

        // native: fid -> source TU
        var fid = id->resolved_fid
        // Unresolved; PP already errored. Not `fid == 0`: that is the first
        // input, and a module it imports may import it back.
        if id->file_seg_count == 0 {
            return
        }

        var unsafe *src_tu = self._source_tu(fid)
        if src_tu == &null {
            return
        }

        var unsafe *src_syms = src_tu->symbols()
        if src_syms == &null {
            return
        }

        var unsafe *src_imms = self.sc->ctx->tcm->get_imm_table_for_fid(fid)
        if src_imms == &null {
            return
        }

        // `import foo::mac!`: a macro, which the preprocessor resolved and
        // bound (FileImportIndex::record, R011E on a miss). Macros are not
        // in the source's symbol table, so walking the path here reported
        // the import's own macro as "not declared in module" (R015E, P1006).
        // Nothing to fold: the expansion is already in the token stream.
        if id->last_seg_is_macro {
            return
        }

        // A symbol path (`import foo::MyClass`): the leading file_seg_count
        // segments named the FILE; the rest is a path INSIDE it.
        if id->file_seg_count > 0 && (id->file_seg_count as usize) < id->path_segments.size() {
            self._fold_symbol_path(id, overlay, src_tu, src_syms, src_imms, fid)
            return
        }

        if id->is_wildcard {
            self._fold_wildcard(id, overlay, src_syms, fid)
            // Re-export: the source's own pub/prot imports are part of its
            // surface (Compiler/Spec/Pipeline.md#sema-pass-order, two walls). DAG order guarantees the
            // source overlay is complete, and transitively closed, by now.
            //
            // Only for a WILDCARD: a selective import names exactly what it
            // takes, and a PLAIN import reaches re-exports through `foo::name`
            // -- which needs no fold, because foo's ModuleDecl shares foo's
            // TABLE while its re-exported names live in foo's OVERLAY, so the
            // step consults that overlay directly
            // (MemberLookup::reexport_lookup).
            self._fold_reexports(id, overlay, src_tu, fid)
            return
        }

        if id->has_items {
            self._fold_selective(id, overlay, src_syms, src_imms, fid, src_tu)
            return
        }

        self._fold_plain(id, overlay, src_tu, fid)
    }

    /// Fold every target the SOURCE TU re-exports (its own pub/prot imports)
    /// under the same spelling. Carries each target's existing kind, vis,
    /// cell/decl and src_fid: what is re-exported is the original thing, not
    /// a copy of it. A target whose origin import is private is never folded
    /// (wall 1), nor one whose origin is a `prot import` when this TU is not
    /// in the source's module (P944, VisibilityFacts::reexports_to).
    priv fn _fold_reexports(self,
                            id:      unsafe *ImportDecl,
                            overlay: unsafe *ImportOverlay,
                            src_tu:  unsafe *TranslationUnit,
                            fid:     u32) {
        var unsafe *src_overlay = src_tu->import_overlay
        if src_overlay == &null {
            return
        }

        var unsafe *src_ctx = self.sc->g->get_context(fid)
        if src_ctx == &null {
            return
        }

        var unsafe *src_imms = src_ctx->get_imm_table()
        if src_imms == &null {
            return
        }

        var rows = cxx::std::vector<ImportOverlay::Row>()
        src_overlay->collect_rows(&rows)
        for var r: usize = 0; r < rows.size(); ++r {
            var unsafe *e = rows[r].entry
            if e == &null {
                continue
            }

            var spelling = src_imms->get_ident(rows[r].key)
            if spelling.size() == 0 {
                continue
            }

            for var i: usize = 0; i < e->targets.size(); ++i {
                var        t  = e->targets[i]
                var unsafe *o = dyn_cast<ImportDecl>(t.origin)
                if o == &null {
                    continue
                }

                if !reexports_to(o, src_tu, self.sc->tu) {
                    continue
                }

                // In THIS overlay the target arrived through `id`, so `id`
                // is its origin: whether this TU hands it on is `id`'s
                // pub/prot, not that of the edge it crossed in the source.
                // Keeping the source's origin let every target that ever
                // crossed a `pub import` (all of builtin's surface, through
                // each TU's prelude) count as surface of every TU after it:
                // wall 1 broke transitively, and each overlay entry gained
                // one duplicate per import path, so a TU deep in a large
                // DAG spent minutes here rebuilding entries thousands of
                // targets long.
                t.origin = id
                self._add(overlay, spelling, t)
            }
        }
    }

    priv fn _fold_plain(self,
                        id:      unsafe *ImportDecl,
                        overlay: unsafe *ImportOverlay,
                        src_tu:  unsafe *TranslationUnit,
                        fid:     u32) {
        // The bound name is the alias (`as m`) or the last path segment. It
        // references the source module handle; `m::foo` resolves later through
        // the trie walk (decl->dc_symbols per segment), no unfold pass.
        var handle_spelling = self._handle_name(id)
        if handle_spelling.size() == 0 {
            return
        }

        // The handle binds the source file's synthetic module node (a real
        // ModuleDecl sharing the source TU's dc_symbols). `m::foo` resolves
        // later through the trie walk (context_of(module) -> dc_symbols per
        // segment), no unfold pass. A null module_self means an anonymous root
        // file, which has no importable handle nothing to bind.
        var unsafe *mod = src_tu->module_self
        if mod == &null {
            return
        }

        var t = OverlayTarget{}
        t.kind   = OverlayTargetKind::ModuleHandle
        t.decl   = mod                             // real *Decl (ModuleDecl), no reinterpret.
        t.origin = id
        // `vis` is the ACCESS fact N reads, not the edge's pub/prot. A file
        // you imported is a scope you may name; whether the edge re-exports
        // it is a separate question, answered from `origin` in the re-export
        // fold. Recording the edge here made every plain `import foo` report
        // "'foo' is imported but is declared private in its module".
        t.vis     = OverlayVisibility::Public
        t.src_fid = fid

        self._add(overlay, handle_spelling, t)
    }

    /// Compiler/Spec/Imports.md#import-resolution. Walk `path_segments[file_seg_count ..]` inside the
    /// already-resolved source file and fold the cell the last segment names.
    ///
    /// Aliases are NOT expanded here: expansion is T's job and T has not run
    /// for this TU, so an alias as an INTERMEDIATE segment is an error.
    priv fn _fold_symbol_path(self,
                              id:       unsafe *ImportDecl,
                              overlay:  unsafe *ImportOverlay,
                              src_tu:   unsafe *TranslationUnit,
                              src_syms: unsafe *SymbolTable,
                              src_imms: unsafe *ImmediateTable,
                              fid:      u32) {
        var start = (id->file_seg_count as usize)
        if start == 0 {
            return
        }

        if start > id->path_segments.size() {
            return
        }

        var prev_name = self.sc->ctx->get_spelling(id->path_segments[start - 1])
        var first                          = true
        var last_name                      = prev_name
        var cell:     unsafe *OverloadCell = &null

        for var i: usize = start; i < id->path_segments.size(); ++i {
            var tok  = id->path_segments[i]
            var name = self.sc->ctx->get_spelling(tok)
            cell = self._walk_segment(
                cell,
                prev_name,
                first,
                src_syms,
                src_imms,
                name,
                tok.range,
                src_tu,
            )

            if cell == &null {
                return
            }

            prev_name = name
            last_name = name
            first     = false
        }

        var visible = last_name
        if id->has_alias {
            visible = self.sc->ctx->get_spelling(id->alias)
        }

        if visible.size() == 0 {
            return
        }

        self._fold_cell(id, overlay, visible, cell, fid)
    }

    /// One segment of a symbol path inside an already-resolved source file.
    ///
    ///   prev == null   -> `name` is looked up in the file's top-level table
    ///   prev != null   -> `name` is looked up in the scope prev's first decl
    ///                     owns, through its redecl canonical
    ///
    /// Returns null after reporting. R015E is the sole home for every miss
    /// on this path (Compiler/Spec/Imports.md#import-resolution).
    priv fn _walk_segment(self,
                          prev:            unsafe *OverloadCell,
                          const prev_name: string,
                          prev_is_module:  bool,
                          src_syms:        unsafe *SymbolTable,
                          src_imms:        unsafe *ImmediateTable,
                          const name:      string,
                          at:              SourceRange,
                          src_tu:          unsafe *TranslationUnit) -> unsafe *OverloadCell {
        var        disp  = if (prev_is_module) => (f"module '{prev_name}'") else => f"'{prev_name}'"
        var unsafe *syms = src_syms

        if prev != &null {
            var unsafe *d = prev->get(0)
            if d == &null {
                return &null
            }

            if isa<TypeAliasDecl>(d) {
                // FIXME(diag-table)
                self.sc->diag->report(
                    DiagID::R015E,
                    at.start,
                    f"cannot import through a type alias '{prev_name}'",
                ).first(at)->emit()
                return &null
            }

            var unsafe *dc = NameLookup::context_of(NameLookup::representative(d))
            if dc == &null {
                // FIXME(diag-table)
                self.sc->diag->report(
                    DiagID::R015E,
                    at.start,
                    f"{disp} is not a scope; '{name}' cannot be imported through it",
                ).first(at)->emit()
                return &null
            }

            syms = dc->dc_symbols
        }

        var unsafe *cell = SymbolTable::lookup_foreign(syms, src_imms, name)
        if cell == &null && prev == &null {
            // Top level of the source FILE: its pub/prot imports are part of
            // its surface (two walls). They live in its overlay, not its
            // table. DAG order guarantees the overlay is complete.
            cell = self._reexported_cell(src_tu, src_imms, name)
        }

        if cell == &null {
            // `import lib::getter` where lib has `macro getter!`: a macro is
            // imported by its `!` spelling (`import lib::getter!`), and the
            // bare one names a declaration. Said here, where the miss is
            // already established: a file may declare both `fn getter` and
            // `macro getter!`, and then the bare import is the function's.
            var b = self.sc->diag->report(
                DiagID::R015E,
                at.start,
                f"'{name}' is not declared in {disp}",
            )

            b.first(at)
            if prev == &null && self._declares_macro(src_tu, name) {
                b.note(f"'{name}!' is a macro there; a macro is imported with its '!'")
                b.insert(at.end, "!", f"import the macro '{name}!'")
            }

            b.emit()
            return &null
        }

        return cell
    }

    /// \p src_tu defines a macro spelled \p name (`macro name! ...`), at
    /// any visibility: the hint only names the spelling, and a private
    /// one is then the preprocessor's R011E.
    priv fn _declares_macro(self, src_tu: unsafe *TranslationUnit, const name: string) -> bool {
        if src_tu == &null || src_tu->ctx == &null {
            return false
        }

        for var i: usize = 0; i < src_tu->macros.size(); ++i {
            var unsafe *md = dyn_cast<MacroDecl>(*src_tu->macros.get(i))
            if md != &null && src_tu->ctx->get_spelling(md->name) == name {
                return true
            }
        }

        return false
    }

    priv fn _reexported_cell(self,
                             src_tu:     unsafe *TranslationUnit,
                             src_imms:   unsafe *ImmediateTable,
                             const name: string) -> unsafe *OverloadCell {
        if src_tu == &null || src_tu->import_overlay == &null {
            return &null
        }

        // Not a race (P850): src_tu is an import, whose group finished all of
        // its Sema before this group's front was queued (_sema_parallel's
        // maxdep), or this group's own cycle member, run on this thread.
        self._flush_merged() // the source may be the overlay being built.
        var key = src_imms->find_ident(name) // probe only; never intern.
        if key == u32::MAX {
            return &null
        }

        var unsafe *entry = src_tu->import_overlay->entry(key)
        if entry == &null {
            return &null
        }

        for var i: usize = 0; i < entry->targets.size(); ++i {
            var unsafe *o = dyn_cast<ImportDecl>(entry->targets[i].origin)
            if o != &null && reexports_to(o, src_tu, self.sc->tu) {
                return unsafe &entry->merged
            }
        }

        return &null // private edge, or prot outside its module: not surface.
    }

    priv fn _fold_selective(self,
                            id:       unsafe *ImportDecl,
                            overlay:  unsafe *ImportOverlay,
                            src_syms: unsafe *SymbolTable,
                            src_imms: unsafe *ImmediateTable,
                            fid:      u32,
                            src_tu:   unsafe *TranslationUnit) {
        for var j: usize = 0; j < id->items.size(); ++j {
            var it = id->items[j]
            if it.is_wildcard {
                self._fold_all_cells(id, overlay, src_syms, fid, false)
                continue
            }

            // `import foo::{mac!, f}`: the macro item is the preprocessor's
            // (see the `import foo::mac!` case in _resolve_one).
            if it.sub_path.size() == 0 || it.is_macro {
                continue
            }

            var orig_tok    = it.sub_path[it.sub_path.size() - 1]
            var visible_tok = orig_tok
            if it.has_alias {
                visible_tok = it.alias
            }

            var visible = self.sc->ctx->get_spelling(visible_tok)

            // A multi-segment item (`import foo::{x::Y}`) walks exactly the
            // same way a symbol-path import does; a single-segment item is
            // that walk with one step.
            var prev_name                      = self._module_display_name(id)
            var first                          = true
            var cell:     unsafe *OverloadCell = &null
            for var s: usize = 0; s < it.sub_path.size(); ++s {
                var tok = it.sub_path[s]
                var nm  = self.sc->ctx->get_spelling(tok)
                cell = self._walk_segment(
                    cell,
                    prev_name,
                    first,
                    src_syms,
                    src_imms,
                    nm,
                    tok.range,
                    src_tu,
                )

                if cell == &null {
                    break
                }

                prev_name = nm
                first     = false
            }

            if cell == &null {
                continue
            }

            self._fold_cell(id, overlay, visible, cell, fid)
        }
    }

    priv fn _fold_wildcard(self,
                           id:       unsafe *ImportDecl,
                           overlay:  unsafe *ImportOverlay,
                           src_syms: unsafe *SymbolTable,
                           fid:      u32) {
        self._fold_all_cells(id, overlay, src_syms, fid, false)
    }

    /// \param skip_std true ONLY from the bare-ffi fold, where `std` is now
    ///        reached through `cxx::std` instead. It is a parameter rather
    ///        than a check inside the loop because this function has three
    ///        callers: the bare ffi fold, `import foo::*`, and a `*` item in a
    ///        selective import. Skipping the name unconditionally would also
    ///        skip it for `import kairo::std::*`.
    priv fn _fold_all_cells(self,
                            id:       unsafe *ImportDecl,
                            overlay:  unsafe *ImportOverlay,
                            src_syms: unsafe *SymbolTable,
                            fid:      u32,
                            skip_std: bool) {
        var rows = cxx::std::vector<SymbolTable::Entry>()
        src_syms->collect_entries(&rows)
        for var r: usize = 0; r < rows.size(); ++r {
            var e = rows[r]
            // Only plain-identifier names enter the overlay under a string key;
            // operators/ctors are keyed structurally and are not folded here.
            if e.name.kind != DeclNameKind::Identifier {
                continue
            }

            if e.cell == &null {
                continue
            }

            var spelling = e.name.describe(self.sc->g->get_context(fid))
            if spelling.size() == 0 {
                continue
            }

            if skip_std && spelling == cxx_std_name() {
                continue
            }

            // A hidden C/C++ tag's internal key (`struct timezone`,
            // DeclImport::_bind_named): no source spells it, so it has no
            // business in an importer's overlay.
            // Scanned in place: a std::string copy per row was the cost.
            var unsafe *sp     = unsafe (spelling.raw() as kairo::std::ConstPtr<u8>)
            var        spaced = false
            for var k: usize = 0; k < spelling.size(); ++k {
                if sp[k] == (' ' as u8) {
                    spaced = true
                    break
                }
            }

            if spaced {
                continue
            }

            self._cur_src = ((fid as u64) << 32) | (e.name.payload as u64)
            self._fold_cell(id, overlay, spelling, e.cell, fid)
            self._cur_src = u64::MAX
        }
    }

    priv fn _fold_cell(self,
                       id:            unsafe *ImportDecl,
                       overlay:       unsafe *ImportOverlay,
                       const visible: string,
                       cell:          unsafe *OverloadCell,
                       fid:           u32) {
        var t = OverlayTarget{}
        t.origin  = id
        t.src_fid = fid
        t.vis     = self._cell_vis(cell)

        if self._is_function_cell(cell) {
            t.kind = OverlayTargetKind::FunctionSet
            t.cell = cell
        } else if cell->size() > 1 && self._is_ffi_cell(cell) {
            // A header cell holding more than one entity: two inline
            // namespaces declaring one name, or a tag a set saw unhidden.
            // Each is its own target, so hiding and the ambiguity count see
            // all of them instead of only the first.
            self._fold_ffi_cell(overlay, visible, cell, t)
            return
        } else {
            t.decl = cell->get(0)
            // A module named through a symbol path is still a module handle,
            // not an entity: two files reopening it are one namespace, so it
            // must not count toward the ambiguity tally (Compiler/Spec/Imports.md#overlays-and-visibility).
            t.kind = if (isa<ModuleDecl>(t.decl)) => (OverlayTargetKind::ModuleHandle)
                     else => OverlayTargetKind::Type
        }

        self._add(overlay, visible, t)
    }

    /// One target per distinct entity of a mixed header cell; its functions
    /// (if any) as one function set in a cell of their own.
    priv fn _fold_ffi_cell(self,
                           overlay:       unsafe *ImportOverlay,
                           const visible: string,
                           cell:          unsafe *OverloadCell,
                           proto:         OverlayTarget) {
        var fns: unsafe *OverloadCell = &null
        var seen                      = cxx::std::vector<unsafe *Decl>()
        for var i: usize = 0; i < cell->size(); ++i {
            var unsafe *d = cell->get(i)
            if d == &null {
                continue
            }

            if isa<FunctionDecl>(d) {
                if fns == &null {
                    fns = self.sc->ctx->alloc_init_cleanup<OverloadCell>()
                }

                fns->append(d)
                continue
            }

            // Never the answer to a name; M1 pairs it with its primary.
            if NameLookup::is_specialization(d) {
                continue
            }

            var unsafe *r  = NameLookup::representative(d)
            var        dup = false
            for var j: usize = 0; j < seen.size(); ++j {
                if seen[j] == r {
                    dup = true
                    break
                }
            }

            if dup {
                continue
            }

            seen.push_back(r)
            var t = proto
            t.decl = d
            t.kind = if (isa<ModuleDecl>(d)) => (OverlayTargetKind::ModuleHandle)
                     else => OverlayTargetKind::Type
            self._add(overlay, visible, t)
        }

        if fns != &null {
            var t = proto
            t.kind = OverlayTargetKind::FunctionSet
            t.cell = fns
            self._add(overlay, visible, t)
        }
    }

    priv fn _is_ffi_cell(self, cell: unsafe *OverloadCell) -> bool {
        for var i: usize = 0; i < cell->size(); ++i {
            if !decl_is_ffi(cell->get(i)) {
                return false
            }
        }

        return true
    }

    /// Compiler/Spec/Interop.md#ffi-imports. `ffi import "h" as z`: ONE key, one ModuleHandle per
    /// header in the closure. non_function_count skips ModuleHandle, so N
    /// headers under one alias are one scope spread over N tables -- the
    /// reopened-module shape ChainBinding's multi-scope Module anchor already
    /// searches (§4.3). Bare `ffi import "h"`: every name of every header in
    /// the closure, unqualified, as the `#include` it stands for would.
    priv fn _resolve_ffi(self,
                         id:             unsafe *ImportDecl,
                         overlay:        unsafe *ImportOverlay,
                         @inout cxx_std: cxx::std::vector<unsafe *Decl>) {
        var alias: string = ""
        if id->has_alias {
            alias = self.sc->ctx->get_spelling(id->alias)
        }

        for var i: usize = 0; i < id->ffi_closure_fids.size(); ++i {
            var        fid     = id->ffi_closure_fids[i]
            var unsafe *src_tu = self._source_tu(fid)
            if src_tu == &null {
                continue
            }

            // `std` for the `cxx` overlay, collected for BOTH shapes and
            // BEFORE the aliased branch returns: an aliased ffi import still
            // puts C++'s std in this TU's closure, and `cxx::std` is not a
            // per-import name.
            self._collect_cxx_std(src_tu, fid, &cxx_std)

            if id->has_alias {
                if alias.size() == 0 || src_tu->module_self == &null {
                    continue
                }

                var t = OverlayTarget{}
                t.kind    = OverlayTargetKind::ModuleHandle
                t.decl    = src_tu->module_self
                t.origin  = id
                t.vis     = OverlayVisibility::Public       // a scope you named; see _fold_plain.
                t.src_fid = fid
                self._add(overlay, alias, t)
                continue
            }

            var unsafe *syms = src_tu->symbols()
            if syms == &null {
                continue
            }

            // skip_std: bare `std` no longer comes from a header. Everything
            // else folds as the `#include` it stands for would, so `boost::`,
            // `absl::` and friends are untouched -- `cxx` is one alias for one
            // name, not a general prefix.
            self._fold_all_cells(id, overlay, syms, fid, true)
        }
    }

    /// Compiler/Spec/Interop.md#ffi-imports. A bodiless top-level `ffi "c" struct timezone` (or
    /// `class`, `union`) in a TU with ffi imports names the header's TAG:
    /// the one bound under the internal key a hidden tag gets (`struct
    /// timezone`, DeclImport::_bind_named), else a visible tag of that name.
    /// It is how source names a tag an ordinary name hides. No such tag in
    /// the closure leaves the declaration what it always was, a Kairo
    /// forward declaration.
    priv fn _bind_ffi_forwards(self, tu: unsafe *TranslationUnit) {
        var unsafe *syms = tu->symbols()
        if syms == &null {
            return
        }

        var rows = cxx::std::vector<SymbolTable::Entry>()
        syms->collect_entries(&rows)
        for var r: usize = 0; r < rows.size(); ++r {
            var e = rows[r]
            if e.name.kind != DeclNameKind::Identifier || e.cell == &null {
                continue
            }

            for var i: usize = 0; i < e.cell->size(); ++i {
                var unsafe *d = e.cell->get(i)
                if !self._is_ffi_forward(d) {
                    continue
                }

                var nm = self.sc->ctx->get_spelling(decl_name_tok(d))
                if nm.size() == 0 {
                    continue
                }

                var unsafe *tag = self._find_header_tag(tu, nm)
                if tag != &null {
                    decl_set_ffi_tag_target(d, tag)
                }
            }
        }
    }

    priv fn _is_ffi_forward(self, d: unsafe *Decl) -> bool {
        if d == &null {
            return false
        }

        if isa<ClassDecl>(d) {
            var unsafe *c = cast<ClassDecl>(d)
            return c->has_ffi_linkage()
                && !c->is_imported()
                && !c->is_this_definition
                && c->generic_params.size() == 0
        }

        if isa<StructDecl>(d) {
            var unsafe *s = cast<StructDecl>(d)
            return s->has_ffi_linkage()
                && !s->is_imported()
                && !s->is_this_definition
                && s->generic_params.size() == 0
        }

        if isa<UnionDecl>(d) {
            var unsafe *u = cast<UnionDecl>(d)
            return u->has_ffi_linkage()
                && !u->is_imported()
                && !u->is_this_definition
                && u->generic_params.size() == 0
        }

        return false
    }

    /// The imported tag named \p nm in any closure header of \p tu's ffi
    /// imports: a hidden one first (its internal key), then a visible one.
    priv fn _find_header_tag(self, tu: unsafe *TranslationUnit, const nm: string) -> unsafe *Decl {
        var hidden_keys = cxx::std::vector<string>()
        hidden_keys.push_back("struct " + nm)
        hidden_keys.push_back("class " + nm)
        hidden_keys.push_back("union " + nm)
        for var pass: usize = 0; pass < 2; ++pass {
            for var i: usize = 0; i < tu->imports.size(); ++i {
                var unsafe **slot = tu->imports.at(i)
                if slot == &null {
                    continue
                }

                var unsafe *id = dyn_cast<ImportDecl>(*slot)
                if id == &null || !id->has_ffi_linkage() || id->resolved_fid == 0 {
                    continue
                }

                for var f: usize = 0; f < id->ffi_closure_fids.size(); ++f {
                    var        fid  = id->ffi_closure_fids[f]
                    var unsafe *src = self._source_tu(fid)
                    if src == &null {
                        continue
                    }

                    var unsafe *hsyms = src->symbols()
                    var unsafe *imms  = self.sc->ctx->tcm->get_imm_table_for_fid(fid)
                    if hsyms == &null || imms == &null {
                        continue
                    }

                    if pass == 0 {
                        for var k: usize = 0; k < hidden_keys.size(); ++k {
                            var unsafe *c = SymbolTable::lookup_foreign(hsyms, imms, hidden_keys[k])
                            if c != &null && c->size() > 0 && decl_is_ffi_tag(c->get(0)) {
                                return c->get(0)
                            }
                        }

                        continue
                    }

                    var unsafe *c = SymbolTable::lookup_foreign(hsyms, imms, nm)
                    if c == &null {
                        continue
                    }

                    for var j: usize = 0; j < c->size(); ++j {
                        var unsafe *d = c->get(j)
                        if decl_is_ffi_tag(d) && !isa<EnumDecl>(d) {
                            return d
                        }
                    }
                }
            }
        }

        return &null
    }

    /// Append every top-level `std` ModuleDecl of one closure header. Probed
    /// by SPELLING through the header TU's own imm table, like every other
    /// cross-TU read (hard invariant #2).
    priv fn _collect_cxx_std(self,
                             src_tu:     unsafe *TranslationUnit,
                             fid:        u32,
                             @inout out: cxx::std::vector<unsafe *Decl>) {
        if !self._cxx_std_fids.insert(fid as u64).second {
            return
        }

        var unsafe *syms = src_tu->symbols()
        if syms == &null {
            return
        }

        var unsafe *imms = self.sc->ctx->tcm->get_imm_table_for_fid(fid)
        if imms == &null {
            return
        }

        var unsafe *cell = SymbolTable::lookup_foreign(syms, imms, cxx_std_name())
        if cell == &null {
            return
        }

        for var i: usize = 0; i < cell->size(); ++i {
            var unsafe *d = cell->get(i)
            if d == &null {
                continue
            }

            if !isa<ModuleDecl>(d) { // a C++ namespace; anything
                continue
            }

            // else under that name is
            // not a scope to step into.
            // The list keeps first-seen order (what _bind_cxx binds); the
            // set only answers "already in it".
            if self._cxx_std_seen.insert(d as usize as u64).second {
                out.push_back(d)
            }
        }
    }

    /// Compiler/Spec/Interop.md#ffi-imports. Bind `cxx`, whose ONE member `std` is C++'s `std`.
    ///
    /// A TRANSPARENT alias: it binds a name and nothing else. The decls it
    /// reaches are the header TUs' own, they keep their own DC chains and
    /// their own paths, and codegen spells them `::std::…` exactly as it did
    /// when bare `std` reached them. It exists for one reason -- bare `std`
    /// is Kairo's (`import std` binds `kairo::std`) or nothing, never C++'s.
    ///
    /// No new lookup arm. `cxx::std::cout` walks the path that already
    /// exists: `cxx` is a Module anchor (module_scopes on a ring of one
    /// yields its own scope), `std` under it is an all-module cell -- §4.3's
    /// multi-scope rule -- and `cout` searches every reopening. A TU with no
    /// ffi import never gets here, so `cxx::std` is an ordinary miss there.
    ///
    /// This is the one SymbolTable built outside ASTParse::_build_symbols. It
    /// holds foreign decls by REFERENCE, never copies, and is frozen before
    /// anything can read it -- the same shape OverlayEntry::merged already
    /// has, so hard invariant #2 stands.
    priv fn _bind_cxx(self,
                      overlay:         unsafe *ImportOverlay,
                      @inout std_mods: cxx::std::vector<unsafe *Decl>,
                      origin:          unsafe *ImportDecl) {
        var at = origin->range

        // Both halves of a synthesized token belong to THIS file: the imm in
        // this TU's imm space, the range in this file, because TokenText
        // resolves the interner FROM the range's fid.
        var tok = Token()
        tok.kind  = TokenKind::LitIdentifier
        tok.range = at
        tok.imm   = self.sc->imm_table()->intern_ident_copy(cxx_root_name())

        var unsafe *tbl = self.sc->ctx->alloc_init_cleanup<SymbolTable>(self.sc->ctx)
        var        skey = self.sc->imm_table()->intern_ident_copy(cxx_std_name())
        for var i: usize = 0; i < std_mods.size(); ++i {
            tbl->append_ident(skey, std_mods[i])
        }

        tbl->freeze()

        var unsafe *tu_dc = unsafe (self.sc->tu as unsafe *DeclContext)
        var unsafe *md    = ModuleDecl::create(self.sc->ctx, at, tok, tu_dc)
        md->set_symbols(tbl)

        self.sc->tu->cxx_module = md

        var t = OverlayTarget{}
        t.kind    = OverlayTargetKind::ModuleHandle
        t.decl    = md
        t.origin  = origin
        t.vis     = OverlayVisibility::Public
        t.src_fid = self.sc->ctx->fid
        self._add(overlay, cxx_root_name(), t)
    }

    /// An imported C++ variable already held under this key. The import
    /// registry keys decls by USR across header sets, so a variable two
    /// closures both reach (glibc's `extern FILE *stdout` under <cstdio> and
    /// <string>) arrives as the SAME VariableDecl twice, not as two decls.
    /// non_function_count dedups by pointer so it is no ambiguity, but the
    /// merged cell would list it twice, and a variable has no redeclaration
    /// ring to collapse that on: ExprTyper reads two candidates as an
    /// overload set and never promotes it (EmitIR: unpromoted overload set).
    priv fn _is_same_ffi_var(self, entry: unsafe *OverlayEntry, t: OverlayTarget) -> bool {
        if t.kind != OverlayTargetKind::Type || t.decl == &null {
            return false
        }

        if !isa<VariableDecl>(t.decl) || !decl_is_ffi(t.decl) {
            return false
        }

        for var i: usize = 0; i < entry->targets.size(); ++i {
            var o = entry->targets[i]
            if o.kind != OverlayTargetKind::Type || o.decl == &null {
                continue
            }

            if o.decl == t.decl {
                return true
            }

            if !isa<VariableDecl>(o.decl) || !decl_is_ffi(o.decl) {
                continue
            }

            // Distinct decls of one entity (no shared registry): same USR.
            var u = cast<VariableDecl>(t.decl)->usr
            if u.size() > 0 && u == cast<VariableDecl>(o.decl)->usr {
                return true
            }
        }

        return false
    }

    /// Intern the visible name into THIS TU's imm space (overlay key), add the
    /// target, rebuild the merged candidate cell, and diagnose a fresh
    /// non-function collision exactly once (R016; a header-only collision
    /// is marked lazy instead, Compiler/Spec/Interop.md#ffi-imports).
    priv fn _add(self, overlay: unsafe *ImportOverlay, const visible: string, t: OverlayTarget) {
        var key: u32 = 0
        if self._cur_src == u64::MAX {
            key = self.sc->imm_table()->intern_ident_copy(visible)
        } else {
            var it = self._key_memo.find(self._cur_src)
            if it != self._key_memo.end() {
                key = it->second
            } else {
                key = self.sc->imm_table()->intern_ident_copy(visible)
                self._key_memo[self._cur_src] = key
            }
        }

        var unsafe *entry = overlay->entry_for(key)
        // A fixpoint round re-folds what an earlier round already folded.
        if overlay->is_refolding() {
            for var i: usize = 0; i < entry->targets.size(); ++i {
                var o = entry->targets[i]
                if o.kind == t.kind && o.cell == t.cell && o.decl == t.decl {
                    return
                }
            }
        }

        // One C++ variable reached through two header closures folds once;
        // see _is_same_ffi_var.
        if self._is_same_ffi_var(entry, t) {
            return
        }

        // Shadowing a PRELUDE module handle. Two ModuleHandle targets under
        // one key UNION into a multi-scope module -- non_function_count
        // exempts ModuleHandle so reopened namespaces and ffi closures work
        // (§4.3) -- and is_ambiguous() therefore never fires. Left alone, a
        // user's own `import std` (or a root they named `std`) would silently
        // MERGE their namespace with `kairo::std` instead of shadowing it,
        // and nothing anywhere would say so.
        //
        // So: a real import evicts a prelude handle of the same name, and a
        // prelude handle never lands on a name a real import already bound.
        // Narrow on purpose -- handles only. builtin's wildcard folds Type
        // and FunctionSet targets, and a user import colliding with one of
        // those is still the R016E it is today.
        if self._is_prelude_handle(t) {
            for var i: usize = 0; i < entry->targets.size(); ++i {
                if !self._is_prelude_handle(entry->targets[i]) {
                    return
                }
            }
        } else {
            self._drop_prelude_handles(entry)
        }

        entry->add_target(t)

        // C++ tag hiding across headers: a tag one header declares and an
        // ordinary name another declares (glibc: `struct timezone` in
        // <sys/time.h>, `timezone` in <time.h>) meet here, not in any one
        // header's table.
        self._apply_hiding(entry)

        // Rebuild the merged view: union every function-set target's decls, and
        // include a single non-function target's decl. (On ambiguity the merged
        // cell still holds something so lookup never crashes; the error below
        // is the authoritative signal.)
        self._mark_merged(entry)

        if !entry->is_ambiguous() {
            entry->lazy = false
            return
        }

        // Every colliding entity from a header: C++ only objects where the
        // name is used, and a header set routinely declares names nobody
        // uses. N / T report it at the use (MemberLookup::report_lazy_ambiguity).
        if self._collision_is_ffi_only(entry) {
            entry->lazy = true
            return
        }

        entry->lazy = false

        // A Kairo import takes part: the import itself is the mistake.
        if entry->reported {
            return
        }

        // Blame an import the user WROTE. The builtin prelude is synthesized
        // at 1:1; a user `ImmBigInt` colliding with builtin's was reported
        // there, on a line that names nothing.
        var unsafe *d = self._blame_import(entry, t)
        if d != &null {
            entry->reported = true
            // Contained, not a hard stop: every use of the name is poisoned
            // where it is looked up (MemberLookup::report_use_ambiguity), so
            // nothing downstream binds a guess. Stopping the TU instead left
            // every signature in it unresolved -- `ctx->alloc<T>()` in each
            // importer of ASTContext failed over an unrelated `ImmBigInt`.
            self.sc->contained_errors += 1
            var b = self.sc->diag->report(
                DiagID::R016E,
                d->range.start,
                f"ambiguous import: '{visible}' names more than one non-function symbol",
            )

            b.first(d->range)
            var seen = cxx::std::vector<unsafe *Decl>()
            for var i: usize = 0; i < entry->targets.size(); ++i {
                var o = entry->targets[i]
                if o.kind != OverlayTargetKind::Type || o.hidden || o.decl == &null {
                    continue
                }

                var dup = false
                for var j: usize = 0; j < seen.size(); ++j {
                    if seen[j] == o.decl {
                        dup = true
                        break
                    }
                }

                if dup {
                    continue
                }

                seen.push_back(o.decl)
                var what = MemberLookup::kind_word(o.decl)
                b.note(
                    DiagCode(DiagID::R016N),
                    o.decl->range.start,
                    f"'{visible}' could be the {what} declared here",
                )->child_first(o.decl->range)
            }

            b.emit()
        }
    }

    /// The ImportDecl an eager R016E is reported at: \p t's own unless that
    /// is the synthesized prelude import, then the first written import
    /// among the entry's targets. Null when neither exists.
    priv fn _blame_import(self,
                          entry: unsafe *OverlayEntry,
                          t:     OverlayTarget) -> unsafe *ImportDecl {
        var unsafe *d = dyn_cast<ImportDecl>(t.origin)
        if d != &null && !d->is_prelude {
            return d
        }

        for var i: usize = 0; i < entry->targets.size(); ++i {
            var unsafe *o = dyn_cast<ImportDecl>(entry->targets[i].origin)
            if o != &null && !o->is_prelude {
                return o
            }
        }

        return d
    }

    /// Mark every Type target C++ would hide: an imported tag beside an
    /// imported ordinary name (another Type target, or an imported function
    /// set), and a `typedef struct X X` beside its own tag (one entity).
    /// Recomputed from scratch on every add; targets only ever accumulate.
    priv fn _apply_hiding(self, entry: unsafe *OverlayEntry) {
        var n = entry->targets.size()
        for var i: usize = 0; i < n; ++i {
            var *ti = &entry->targets[i]
            ti->hidden = false
            if ti->kind != OverlayTargetKind::Type {
                continue
            }

            var unsafe *d = ti->decl
            if d == &null || !decl_is_ffi(d) {
                continue
            }

            // Every Type target of one decl gets one answer: the pairs below
            // skip targets of that same decl, so each sees the same others.
            // An entry reached through N header closures holds N of them;
            // copy the first one's flag instead of redoing its row.
            var copied = false
            for var k: usize = 0; k < i; ++k {
                var *tk = &entry->targets[k]
                if tk->kind == OverlayTargetKind::Type && tk->decl == d {
                    ti->hidden = tk->hidden
                    copied     = true
                    break
                }
            }

            if copied {
                continue
            }

            for var j: usize = 0; j < n; ++j {
                if i == j {
                    continue
                }

                var *o = &entry->targets[j] // no copy per pair: this loop is quadratic in the entry
                if o->kind == OverlayTargetKind::FunctionSet {
                    if decl_is_ffi_tag(d)
                        && o->cell != &null
                        && o->cell->size() > 0
                        && decl_is_ffi(o->cell->get(0)) {
                        ti->hidden = true
                        break
                    }

                    continue
                }

                if o->kind != OverlayTargetKind::Type {
                    continue
                }

                if o->decl == &null || o->decl == d {
                    continue
                }

                if decl_is_ffi_tag(d) && decl_ffi_hides_tag(o->decl, d) {
                    ti->hidden = true
                    break
                }

                if decl_is_ffi_tag(o->decl) && decl_is_ffi_typedef_of(d, o->decl) {
                    ti->hidden = true
                    break
                }
            }
        }
    }

    /// True when every entity in an ambiguous entry's collision came from
    /// a header, or from the builtin prelude beside at least one header
    /// entity. The prelude is part of every TU, so a header that merely
    /// declares a builtin's name (zlib's `typedef unsigned char Byte`) is no
    /// import the user wrote wrong: reported eagerly, it killed the whole
    /// header over a name nothing used (P817). Docs (c-cpp-calling, R016E)
    /// put a foreign collision at the use, so it goes there.
    priv fn _collision_is_ffi_only(self, entry: unsafe *OverlayEntry) -> bool {
        var any_ffi = false
        var any_prelude = false
        for var i: usize = 0; i < entry->targets.size(); ++i {
            var t = entry->targets[i]
            if t.kind != OverlayTargetKind::Type {
                continue
            }

            if t.hidden || t.decl == &null {
                continue
            }

            if decl_is_ffi(t.decl) {
                any_ffi = true
                continue
            }

            var unsafe *o = dyn_cast<ImportDecl>(t.origin)
            if o == &null || (!o->is_prelude) {
                return false
            }

            any_prelude = true
        }

        return any_ffi || (!any_prelude)
    }

    /// A module handle bound by an injected prelude import, as opposed to one
    /// the TU actually wrote.
    priv fn _is_prelude_handle(self, t: OverlayTarget) -> bool {
        if t.kind != OverlayTargetKind::ModuleHandle {
            return false
        }

        var unsafe *o = dyn_cast<ImportDecl>(t.origin)
        if o == &null {
            return false
        }

        return o->is_prelude
    }

    priv fn _drop_prelude_handles(self, entry: unsafe *OverlayEntry) {
        // Look before copying: almost no entry holds a prelude handle, and
        // copying every target into a fresh vector per _add was the cost.
        var any = false
        for var i: usize = 0; i < entry->targets.size(); ++i {
            var *t = &entry->targets[i]
            if t->kind == OverlayTargetKind::ModuleHandle && self._is_prelude_handle(*t) {
                any = true
                break
            }
        }

        if !any {
            return
        }

        var keep = cxx::std::vector<OverlayTarget>()
        for var i: usize = 0; i < entry->targets.size(); ++i {
            if self._is_prelude_handle(entry->targets[i]) {
                continue
            }

            keep.push_back(entry->targets[i])
        }

        entry->targets = keep
    }

    priv fn _mark_merged(self, entry: unsafe *OverlayEntry) {
        if self._merge_set.insert(entry as usize as u64).second {
            self._merge_list.push_back(entry)
        }
    }

    /// Rebuild every entry _mark_merged collected. The cells it reads are
    /// the source tables', which nothing appends to while I runs, so the
    /// result is the one a rebuild after each add left behind.
    priv fn _flush_merged(self) {
        for var i: usize = 0; i < self._merge_list.size(); ++i {
            self._rebuild_merged(self._merge_list[i])
        }

        self._merge_list.clear()
        self._merge_set.clear()
    }

    priv fn _rebuild_merged(self, entry: unsafe *OverlayEntry) {
        // Reset and refill. Rebuild in place by constructing a fresh cell and
        // re-appending each target's decls.
        entry->merged = OverloadCell()
        for var i: usize = 0; i < entry->targets.size(); ++i {
            var t = entry->targets[i]
            if t.hidden {
                continue
            }

            if t.kind == OverlayTargetKind::FunctionSet {
                if t.cell == &null {
                    continue
                }

                for var k: usize = 0; k < t.cell->size(); ++k {
                    var unsafe *d = t.cell->get(k)
                    if d != &null {
                        entry->merged.append(d)
                    }
                }
            } else if t.kind == OverlayTargetKind::Type
                || t.kind == OverlayTargetKind::ModuleHandle {
                // A module handle is a real ModuleDecl (a Kairo file's, or a
                // C++ header's under an ffi alias): a legitimate lookup answer,
                // a name denoting a scope.
                if t.decl != &null {
                    entry->merged.append(t.decl)
                }
            }
        }
    }

    priv fn _source_tu(self, fid: u32) -> unsafe *TranslationUnit {
        var unsafe *ctx = self.sc->g->get_context(fid)
        if ctx == &null {
            return &null
        }

        return ctx->tu
    }

    /// The FILE the import resolved to, spelled for a diagnostic: the last
    /// segment the PP consumed to reach it.
    priv fn _module_display_name(self, id: unsafe *ImportDecl) -> string {
        var n = (id->file_seg_count as usize)
        if n == 0 || n > id->path_segments.size() {
            n = id->path_segments.size()
        }

        if n == 0 {
            return "the imported module"
        }

        return self.sc->ctx->get_spelling(id->path_segments[n - 1])
    }

    /// The name a plain/aliased import binds: alias if present, else last seg.
    priv fn _handle_name(self, id: unsafe *ImportDecl) -> string {
        if id->has_alias {
            return self.sc->ctx->get_spelling(id->alias)
        }

        if id->path_segments.size() == 0 {
            return ""
        }

        return self.sc->ctx->get_spelling(id->path_segments[id->path_segments.size() - 1])
    }

    /// A cell is a function set iff every decl in it is a FunctionDecl. A mixed
    /// or non-function cell is treated as a (non-unionable) type target.
    priv fn _is_function_cell(self, cell: unsafe *OverloadCell) -> bool {
        if cell == &null || cell->size() == 0 {
            return false
        }

        for var i: usize = 0; i < cell->size(); ++i {
            if !isa<FunctionDecl>(cell->get(i)) {
                return false
            }
        }

        return true
    }

    /// Carried visibility for a folded decl: the DECL's own visibility (the
    /// fact N reads to emit "exists but priv/prot"). A decl that writes none
    /// is what its file's default makes it (AST/VisibilityFacts.k: `priv`,
    /// `prot` in a module, Public under the old rule and for builtin and
    /// std), and a header's entities carry no Kairo visibility at all,
    /// which is Public. Falling back to the import edge's own
    /// visibility instead -- private unless written `pub import` -- made
    /// every unannotated function or class reached through a plain
    /// `import m::*` R047E at its first use in an expression (the same
    /// mistake §2.3 records for module handles); whether the edge re-exports
    /// is answered from `origin` (§4.4), never from this fact.
    priv fn _cell_vis(self, cell: unsafe *OverloadCell) -> OverlayVisibility {
        var unsafe *d = cell->get(0)
        if d != &null {
            if d->is_private() {
                return OverlayVisibility::Private
            }

            if d->is_protected() {
                return OverlayVisibility::Protected
            }

            if d->visibility == VisibilityKind::None {
                var dv = default_visibility_of(d)
                if dv == VisibilityKind::Private {
                    return OverlayVisibility::Private
                }

                if dv == VisibilityKind::Protected {
                    return OverlayVisibility::Protected
                }
            }
        }

        return OverlayVisibility::Public
    }
}
