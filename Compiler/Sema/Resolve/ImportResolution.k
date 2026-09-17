/// --- The Kairo Project ------------------- Sema/ImportResolution.k --- ///
///
///   \brief Phase I. Build this TU's import_overlay from its ImportDecls, so
///          every name visible in the TU is findable in a local table or the
///          overlay. After I the TU is SELF-CONTAINED: no later phase touches
///          another TU until M2 (RESOLUTION.md §2 "I ImportResolution").
///
///   One error, one home (hard invariant #3):
///     - import EXISTENCE (selective miss)  -> here (R015).
///     - import AMBIGUITY (>=2 non-fn same key) -> here (R016).
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
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sema::SemaContext::*;
import Sema::Resolve::NameLookup::*;
import AST::Context::TranslationUnit::*;
import AST::Context::DeclContext::*;
import AST::Context::SymbolTable::*;
import AST::Context::ImportOverlay::*;
import AST::Context::GlobalDisambigTable::*;
import AST::Node::Base::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import Token::Token::*;
import Token::TokenKind::*;
import Token::TokenText::*;
import Location::SourceRange::*;
import Diagnostic::Registry::*;

class ImportResolution {
    priv var sc: obs::<SemaContext>;

    fn ImportResolution(self, sc: *SemaContext) {
        self.sc = sc;
    }

    /// Entry point. Allocate the overlay, fold every import into it, freeze.
    fn run(self) -> bool {
        self.sc->require_phase(SemaPhase::Parsed);
        var tu = self.sc->tu;
        if tu == &null { return true; }

        var overlay = self.sc->ctx->alloc_init_pp_cleanup::<ImportOverlay>();
        tu->import_overlay = overlay;

        // Every top-level `std` opening reachable through this TU's ffi
        // closure, accumulated across imports and bound ONCE as `cxx::std`
        // below. Collected here rather than in _resolve_ffi because `cxx` is
        // one name for the whole TU, not one per import.
        var cxx_std  = vec::<*Decl>();
        var ffi_orig: *Decl = &null;

        for var i: usize = 0; i < tu->imports.size(); ++i {
            var slot = tu->imports[i];        // *(*Decl): ArenaList::op[] yields *T
            if slot == &null { continue; }
            var id = dyn_cast::<ImportDecl>(*slot);
            if id == &null { continue; }
            if id->has_ffi_linkage() && (id->resolved_fid != 0) && (ffi_orig == &null) {
                ffi_orig = static_cast::<*Decl>(id);
            }
            self._resolve_one(id, overlay, cxx_std);
        }

        if (cxx_std.size() > 0) && (ffi_orig != &null) {
            self._bind_cxx(overlay, cxx_std, ffi_orig);
        }

        overlay->freeze();
        return true;
    }

    priv fn _resolve_one(self, id: *ImportDecl, overlay: *ImportOverlay,
                         cxx_std: ref!(vec::<*Decl>)) {
        // ffi: clang parsed the header set and Sema/Foreign indexed it into
        // one Kairo TU per header BEFORE sema; the driver stamped the closure
        // (the header and everything it transitively includes) onto the node.
        // resolved_fid 0: the spelling never resolved, and the set's own
        // diagnostics already said so.
        if id->has_ffi_linkage() {
            if id->resolved_fid == 0 { return; }
            self._resolve_ffi(id, overlay, cxx_std);
            return;
        }

        // native: fid -> source TU
        var fid = id->resolved_fid;
        if fid == 0 { return; }                 // unresolved; PP already errored.
        var src_tu = self._source_tu(fid);
        if src_tu == &null { return; }
        var src_syms = src_tu->symbols();
        if src_syms == &null { return; }
        var src_imms = self.sc->ctx->tcm->get_imm_table_for_fid(fid);
        if src_imms == &null { return; }

        // A symbol path (`import foo::MyClass`): the leading file_seg_count
        // segments named the FILE; the rest is a path INSIDE it.
        if (id->file_seg_count > 0)
        && (static_cast::<usize>(id->file_seg_count) < id->path_segments.size()) {
            self._fold_symbol_path(id, overlay, src_tu, src_syms, src_imms, fid);
            return;
        }

        if id->is_wildcard {
            self._fold_wildcard(id, overlay, src_syms, fid);
            // Re-export: the source's own pub/prot imports are part of its
            // surface (RESOLUTION.md §2, two walls). DAG order guarantees the
            // source overlay is complete, and transitively closed, by now.
            //
            // Only for a WILDCARD: a selective import names exactly what it
            // takes, and a PLAIN import reaches re-exports through `foo::name`
            // -- which needs no fold, because foo's ModuleDecl shares foo's
            // TABLE while its re-exported names live in foo's OVERLAY, so the
            // step consults that overlay directly
            // (MemberLookup::reexport_lookup).
            self._fold_reexports(id, overlay, src_tu, fid);
            return;
        }
        if id->has_items {
            self._fold_selective(id, overlay, src_syms, src_imms, fid, src_tu);
            return;
        }
        self._fold_plain(id, overlay, src_tu, fid);
    }

    /// Fold every target the SOURCE TU re-exports (its own pub/prot imports)
    /// under the same spelling. Carries each target's existing kind, vis,
    /// cell/decl and src_fid: what is re-exported is the original thing, not
    /// a copy of it. A target whose origin import is private is never folded
    /// (wall 1).
    priv fn _fold_reexports(self, id: *ImportDecl, overlay: *ImportOverlay,
                            src_tu: *TranslationUnit, fid: u32) {
        var src_overlay = src_tu->import_overlay;
        if src_overlay == &null { return; }
        var src_ctx = self.sc->g->get_context(fid);
        if src_ctx == &null { return; }
        var src_imms = src_ctx->get_imm_table();
        if src_imms == &null { return; }

        var rows = vec::<ImportOverlay::Row>();
        src_overlay->collect_rows(rows);
        for var r: usize = 0; r < rows.size(); ++r {
            var e = rows[r].entry;
            if e == &null { continue; }
            var spelling = src_imms->get_ident(rows[r].key);
            if spelling.size() == 0 { continue; }
            for var i: usize = 0; i < e->targets.size(); ++i {
                var t = e->targets[i];
                var o = dyn_cast::<ImportDecl>(t.origin);
                if o == &null { continue; }
                if !(o->is_public() || o->is_protected()) { continue; }
                self._add(overlay, spelling, t);
            }
        }
    }

    priv fn _fold_plain(self, id: *ImportDecl, overlay: *ImportOverlay,
                        src_tu: *TranslationUnit, fid: u32) {
        // The bound name is the alias (`as m`) or the last path segment. It
        // references the source module handle; `m::foo` resolves later through
        // the trie walk (decl->dc_symbols per segment), no unfold pass.
        var handle_spelling = self._handle_name(id);
        if handle_spelling.size() == 0 { return; }

        // The handle binds the source file's synthetic module node (a real
        // ModuleDecl sharing the source TU's dc_symbols). `m::foo` resolves
        // later through the trie walk (context_of(module) -> dc_symbols per
        // segment), no unfold pass. A null module_self means an anonymous root
        // file, which has no importable handle nothing to bind.
        var mod = src_tu->module_self;
        if mod == &null { return; }

        var t = OverlayTarget{};
        t.kind    = OverlayTargetKind::ModuleHandle;
        t.decl    = mod;                            // real *Decl (ModuleDecl), no reinterpret.
        t.origin  = static_cast::<*Decl>(id);       // ImportDecl derives Decl (valid upcast).
        // `vis` is the ACCESS fact N reads, not the edge's pub/prot. A file
        // you imported is a scope you may name; whether the edge re-exports
        // it is a separate question, answered from `origin` in the re-export
        // fold. Recording the edge here made every plain `import foo` report
        // "'foo' is imported but is declared private in its module".
        t.vis     = OverlayVisibility::Public;
        t.src_fid = fid;

        self._add(overlay, handle_spelling, t);
    }

    /// IMPORTS.md §4.1. Walk `path_segments[file_seg_count ..]` inside the
    /// already-resolved source file and fold the cell the last segment names.
    ///
    /// Aliases are NOT expanded here: expansion is T's job and T has not run
    /// for this TU, so an alias as an INTERMEDIATE segment is an error.
    priv fn _fold_symbol_path(self, id: *ImportDecl, overlay: *ImportOverlay,
                              src_tu: *TranslationUnit, src_syms: *SymbolTable,
                              src_imms: *ImmediateTable, fid: u32) {
        var start = static_cast::<usize>(id->file_seg_count);
        if start == 0 { return; }
        if start > id->path_segments.size() { return; }

        var prev_name = self.sc->ctx->get_spelling(id->path_segments[start - 1]);
        var first     = true;
        var last_name = prev_name;
        var cell: *OverloadCell = &null;

        for var i: usize = start; i < id->path_segments.size(); ++i {
            var tok  = id->path_segments[i];
            var name = self.sc->ctx->get_spelling(tok);
            cell = self._walk_segment(cell, prev_name, first, src_syms, src_imms,
                                      name, tok.range, src_tu);
            if cell == &null { return; }
            prev_name = name;
            last_name = name;
            first     = false;
        }

        var visible = last_name;
        if id->has_alias { visible = self.sc->ctx->get_spelling(id->alias); }
        if visible.size() == 0 { return; }
        self._fold_cell(id, overlay, visible, cell, fid);
    }

    /// One segment of a symbol path inside an already-resolved source file.
    ///
    ///   prev == null   -> `name` is looked up in the file's top-level table
    ///   prev != null   -> `name` is looked up in the scope prev's first decl
    ///                     owns, through its redecl canonical
    ///
    /// Returns null after reporting. R015E is the sole home for every miss
    /// on this path (IMPORTS.md §4.1).
    priv fn _walk_segment(self, prev: *OverloadCell, prev_name: string,
                          prev_is_module: bool, src_syms: *SymbolTable,
                          src_imms: *ImmediateTable, name: string,
                          at: SourceRange, src_tu: *TranslationUnit) -> *OverloadCell {
        var disp = (f"module '{prev_name}\x27") if (prev_is_module) else (f"'{prev_name}\x27");
        var syms = src_syms;

        if prev != &null {
            var d = prev->get(0);
            if d == &null { return &null; }
            if isa::<TypeAliasDecl>(d) {
                // FIXME(diag-table)
                self.sc->diag->report(DiagID::R015E, at.start,
                    f"cannot import through a type alias '{prev_name}\x27"
                ).first(at).emit();
                return &null;
            }
            var dc = NameLookup::context_of(NameLookup::representative(d));
            if dc == &null {
                // FIXME(diag-table)
                self.sc->diag->report(DiagID::R015E, at.start,
                    f"{disp} is not a scope; '{name}' cannot be imported through it"
                ).first(at).emit();
                return &null;
            }
            syms = dc->dc_symbols;
        }

        var cell = SymbolTable::lookup_foreign(syms, src_imms, name);
        if (cell == &null) && (prev == &null) {
            // Top level of the source FILE: its pub/prot imports are part of
            // its surface (two walls). They live in its overlay, not its
            // table. DAG order guarantees the overlay is complete.
            cell = self._reexported_cell(src_tu, src_imms, name);
        }
        if cell == &null {
            // FIXME(diag-table)
            self.sc->diag->report(DiagID::R015E, at.start,
                f"'{name}' is not declared in {disp}"
            ).first(at).emit();
            return &null;
        }
        return cell;
    }

    priv fn _reexported_cell(self, src_tu: *TranslationUnit, src_imms: *ImmediateTable,
                             name: string) -> *OverloadCell {
        if (src_tu == &null) || (src_tu->import_overlay == &null) { return &null; }
        var key = src_imms->find_ident(name);          // probe only; never intern.
        if key == u32(-1) { return &null; }
        var entry = src_tu->import_overlay->entry(key);
        if entry == &null { return &null; }
        for var i: usize = 0; i < entry->targets.size(); ++i {
            var o = dyn_cast::<ImportDecl>(entry->targets[i].origin);
            if (o != &null) && (o->is_public() || o->is_protected()) { return &(entry->merged); }
        }
        return &null;   // private edge: not surface (wall 1).
    }

    priv fn _fold_selective(self, id: *ImportDecl, overlay: *ImportOverlay,
                            src_syms: *SymbolTable, src_imms: *ImmediateTable,
                            fid: u32, src_tu: *TranslationUnit) {
        for var j: usize = 0; j < id->items.size(); ++j {
            var it = id->items[j];
            if it.is_wildcard {
                self._fold_all_cells(id, overlay, src_syms, fid, false);
                continue;
            }
            if it.sub_path.size() == 0 { continue; }

            var orig_tok    = it.sub_path[it.sub_path.size() - 1];
            var visible_tok = orig_tok;
            if it.has_alias { visible_tok = it.alias; }
            var visible     = self.sc->ctx->get_spelling(visible_tok);

            // A multi-segment item (`import foo::{x::Y}`) walks exactly the
            // same way a symbol-path import does; a single-segment item is
            // that walk with one step.
            var prev_name = self._module_display_name(id);
            var first     = true;
            var cell: *OverloadCell = &null;
            for var s: usize = 0; s < it.sub_path.size(); ++s {
                var tok = it.sub_path[s];
                var nm  = self.sc->ctx->get_spelling(tok);
                cell = self._walk_segment(cell, prev_name, first, src_syms, src_imms,
                                          nm, tok.range, src_tu);
                if cell == &null { break; }
                prev_name = nm;
                first     = false;
            }
            if cell == &null { continue; }
            self._fold_cell(id, overlay, visible, cell, fid);
        }
    }

    priv fn _fold_wildcard(self, id: *ImportDecl, overlay: *ImportOverlay,
                           src_syms: *SymbolTable, fid: u32) {
        self._fold_all_cells(id, overlay, src_syms, fid, false);
    }

    /// \param skip_std true ONLY from the bare-ffi fold, where `std` is now
    ///        reached through `cxx::std` instead. It is a parameter rather
    ///        than a check inside the loop because this function has three
    ///        callers: the bare ffi fold, `import foo::*`, and a `*` item in a
    ///        selective import. Skipping the name unconditionally would also
    ///        skip it for `import kairo::std::*`.
    priv fn _fold_all_cells(self, id: *ImportDecl, overlay: *ImportOverlay,
                            src_syms: *SymbolTable, fid: u32, skip_std: bool) {
        var rows = vec::<SymbolTable::Entry>();
        src_syms->collect_entries(rows);
        for var r: usize = 0; r < rows.size(); ++r {
            var e = rows[r];
            // Only plain-identifier names enter the overlay under a string key;
            // operators/ctors are keyed structurally and are not folded here.
            if e.name.kind != DeclNameKind::Identifier { continue; }
            if e.cell == &null { continue; }
            var spelling = e.name.describe(self.sc->g->get_context(fid));
            if spelling.size() == 0 { continue; }
            if skip_std && (spelling == "std") { continue; }
            self._fold_cell(id, overlay, spelling, e.cell, fid);
        }
    }

    priv fn _fold_cell(self, id: *ImportDecl, overlay: *ImportOverlay,
                       visible: string, cell: *OverloadCell, fid: u32) {
        var t = OverlayTarget{};
        t.origin  = static_cast::<*Decl>(id);
        t.src_fid = fid;
        t.vis     = self._cell_vis(id, cell);

        if self._is_function_cell(cell) {
            t.kind = OverlayTargetKind::FunctionSet;
            t.cell = cell;
        } else {
            t.decl = cell->get(0);
            // A module named through a symbol path is still a module handle,
            // not an entity: two files reopening it are one namespace, so it
            // must not count toward the ambiguity tally (IMPORTS.md §4.3).
            t.kind = (OverlayTargetKind::ModuleHandle) if (isa::<ModuleDecl>(t.decl))
                     else (OverlayTargetKind::Type);
        }
        self._add(overlay, visible, t);
    }

    /// IMPORTS.md §5. `ffi import "h" as z`: ONE key, one ModuleHandle per
    /// header in the closure. non_function_count skips ModuleHandle, so N
    /// headers under one alias are one scope spread over N tables -- the
    /// reopened-module shape ChainBinding's multi-scope Module anchor already
    /// searches (§4.3). Bare `ffi import "h"`: every name of every header in
    /// the closure, unqualified, as the `#include` it stands for would.
    priv fn _resolve_ffi(self, id: *ImportDecl, overlay: *ImportOverlay,
                         cxx_std: ref!(vec::<*Decl>)) {
        var alias: string = "";
        if id->has_alias { alias = self.sc->ctx->get_spelling(id->alias); }
        for var i: usize = 0; i < id->ffi_closure_fids.size(); ++i {
            var fid = id->ffi_closure_fids[i];
            var src_tu = self._source_tu(fid);
            if src_tu == &null { continue; }

            // `std` for the `cxx` overlay, collected for BOTH shapes and
            // BEFORE the aliased branch returns: an aliased ffi import still
            // puts C++'s std in this TU's closure, and `cxx::std` is not a
            // per-import name.
            self._collect_cxx_std(src_tu, fid, cxx_std);

            if id->has_alias {
                if (alias.size() == 0) || (src_tu->module_self == &null) { continue; }
                var t = OverlayTarget{};
                t.kind    = OverlayTargetKind::ModuleHandle;
                t.decl    = src_tu->module_self;
                t.origin  = static_cast::<*Decl>(id);
                t.vis     = OverlayVisibility::Public;   // a scope you named; see _fold_plain.
                t.src_fid = fid;
                self._add(overlay, alias, t);
                continue;
            }
            var syms = src_tu->symbols();
            if syms == &null { continue; }
            // skip_std: bare `std` no longer comes from a header. Everything
            // else folds as the `#include` it stands for would, so `boost::`,
            // `absl::` and friends are untouched -- `cxx` is one alias for one
            // name, not a general prefix.
            self._fold_all_cells(id, overlay, syms, fid, true);
        }
    }

    /// Append every top-level `std` ModuleDecl of one closure header. Probed
    /// by SPELLING through the header TU's own imm table, like every other
    /// cross-TU read (hard invariant #2).
    priv fn _collect_cxx_std(self, src_tu: *TranslationUnit, fid: u32,
                             out: ref!(vec::<*Decl>)) {
        var syms = src_tu->symbols();
        if syms == &null { return; }
        var imms = self.sc->ctx->tcm->get_imm_table_for_fid(fid);
        if imms == &null { return; }
        var cell = SymbolTable::lookup_foreign(syms, imms, "std");
        if cell == &null { return; }
        for var i: usize = 0; i < cell->size(); ++i {
            var d = cell->get(i);
            if d == &null { continue; }
            if !isa::<ModuleDecl>(d) { continue; }   // a C++ namespace; anything
                                                      // else under that name is
                                                      // not a scope to step into.
            var dup = false;
            for var j: usize = 0; j < out.size(); ++j {
                if out[j] == d { dup = true; break; }
            }
            if !dup { out.push_back(d); }
        }
    }

    /// IMPORTS.md §5. Bind `cxx`, whose ONE member `std` is C++'s `std`.
    ///
    /// A TRANSPARENT alias: it binds a name and nothing else. The decls it
    /// reaches are the header TUs' own, they keep their own DC chains and
    /// their own paths, and codegen spells them `::std::…` exactly as it did
    /// when bare `std` reached them. It exists for one reason -- bare `std`
    /// now means Kairo's (`kairo::std`).
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
    priv fn _bind_cxx(self, overlay: *ImportOverlay, std_mods: ref!(vec::<*Decl>),
                      origin: *Decl) {
        var at = origin->range;

        // Both halves of a synthesized token belong to THIS file: the imm in
        // this TU's imm space, the range in this file, because TokenText
        // resolves the interner FROM the range's fid.
        var tok   = Token{};
        tok.kind  = TokenKind::LitIdentifier;
        tok.range = at;
        tok.imm   = self.sc->imm_table()->intern_ident_copy("cxx");

        var tbl  = self.sc->ctx->alloc_init_cleanup::<SymbolTable>();
        var skey = self.sc->imm_table()->intern_ident_copy("std");
        for var i: usize = 0; i < std_mods.size(); ++i {
            tbl->append_ident(skey, std_mods[i]);
        }
        tbl->freeze();

        var tu_dc = static_cast::<*DeclContext>(self.sc->tu);
        var md    = ModuleDecl::create(self.sc->ctx, at, tok, tu_dc);
        md->set_symbols(tbl);

        self.sc->tu->cxx_module = static_cast::<*Decl>(md);

        var t = OverlayTarget{};
        t.kind    = OverlayTargetKind::ModuleHandle;
        t.decl    = static_cast::<*Decl>(md);
        t.origin  = origin;
        t.vis     = OverlayVisibility::Public;
        t.src_fid = self.sc->ctx->fid;
        self._add(overlay, "cxx", t);
    }

    /// Intern the visible name into THIS TU's imm space (overlay key), add the
    /// target, rebuild the merged candidate cell, and diagnose a fresh
    /// non-function collision exactly once (R016, sole home).
    priv fn _add(self, overlay: *ImportOverlay, visible: string, t: OverlayTarget) {
        var key = self.sc->imm_table()->intern_ident_copy(visible);
        var entry = overlay->entry_for(key);

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
                if !self._is_prelude_handle(entry->targets[i]) { return; }
            }
        } else {
            self._drop_prelude_handles(entry);
        }

        var was_ambiguous = entry->is_ambiguous();

        entry->add_target(t);

        // Rebuild the merged view: union every function-set target's decls, and
        // include a single non-function target's decl. (On ambiguity the merged
        // cell still holds something so lookup never crashes; the error below
        // is the authoritative signal.)
        self._rebuild_merged(entry);

        if (!was_ambiguous) && entry->is_ambiguous() {
            // First time this key tipped into >=2 non-function targets.
            var d = dyn_cast::<ImportDecl>(t.origin);
            if d != &null {
                self.sc->diag->report(DiagID::R016E, d->range.start,
                    f"ambiguous import: '{visible}' names more than one non-function symbol"
                ).first(d->range).emit();
            }
        }
    }

    /// A module handle bound by an injected prelude import, as opposed to one
    /// the TU actually wrote.
    priv fn _is_prelude_handle(self, t: OverlayTarget) -> bool {
        if t.kind != OverlayTargetKind::ModuleHandle { return false; }
        var o = dyn_cast::<ImportDecl>(t.origin);
        if o == &null { return false; }
        return o->is_prelude;
    }

    priv fn _drop_prelude_handles(self, entry: *OverlayEntry) {
        var keep = vec::<OverlayTarget>();
        var any  = false;
        for var i: usize = 0; i < entry->targets.size(); ++i {
            if self._is_prelude_handle(entry->targets[i]) { any = true; continue; }
            keep.push_back(entry->targets[i]);
        }
        if !any { return; }
        entry->targets = keep;
    }

    priv fn _rebuild_merged(self, entry: *OverlayEntry) {
        // Reset and refill. Rebuild in place by constructing a fresh cell and
        // re-appending each target's decls.
        entry->merged = OverloadCell{};
        for var i: usize = 0; i < entry->targets.size(); ++i {
            var t = entry->targets[i];
            if t.kind == OverlayTargetKind::FunctionSet {
                if t.cell == &null { continue; }
                for var k: usize = 0; k < t.cell->size(); ++k {
                    var d = t.cell->get(k);
                    if d != &null { entry->merged.append(d); }
                }
            } else if (t.kind == OverlayTargetKind::Type)
                   || (t.kind == OverlayTargetKind::ModuleHandle) {
                // A module handle is a real ModuleDecl (a Kairo file's, or a
                // C++ header's under an ffi alias): a legitimate lookup answer,
                // a name denoting a scope.
                if t.decl != &null { entry->merged.append(t.decl); }
            }
        }
    }

    priv fn _source_tu(self, fid: u32) -> *TranslationUnit {
        var ctx = self.sc->g->get_context(fid);
        if ctx == &null { return &null; }
        return reinterpret_cast::<*TranslationUnit>(ctx->tu);
    }

    /// The FILE the import resolved to, spelled for a diagnostic: the last
    /// segment the PP consumed to reach it.
    priv fn _module_display_name(self, id: *ImportDecl) -> string {
        var n = static_cast::<usize>(id->file_seg_count);
        if (n == 0) || (n > id->path_segments.size()) { n = id->path_segments.size(); }
        if n == 0 { return "the imported module"; }
        return self.sc->ctx->get_spelling(id->path_segments[n - 1]);
    }

    /// The name a plain/aliased import binds: alias if present, else last seg.
    priv fn _handle_name(self, id: *ImportDecl) -> string {
        if id->has_alias { return self.sc->ctx->get_spelling(id->alias); }
        if id->path_segments.size() == 0 { return ""; }
        return self.sc->ctx->get_spelling(id->path_segments[id->path_segments.size() - 1]);
    }

    /// A cell is a function set iff every decl in it is a FunctionDecl. A mixed
    /// or non-function cell is treated as a (non-unionable) type target.
    priv fn _is_function_cell(self, cell: *OverloadCell) -> bool {
        if (cell == &null) || (cell->size() == 0) { return false; }
        for var i: usize = 0; i < cell->size(); ++i {
            if !isa::<FunctionDecl>(cell->get(i)) { return false; }
        }
        return true;
    }

    /// Edge visibility: the import statement's own pub/prot/priv.
    priv fn _edge_vis(self, id: *ImportDecl) -> OverlayVisibility {
        if id->is_public()    { return OverlayVisibility::Public;    }
        if id->is_protected() { return OverlayVisibility::Protected; }
        return OverlayVisibility::Private;
    }

    /// Carried visibility for a folded decl: the DECL's own visibility (the
    /// fact N reads to emit "exists but priv/prot"). Falls back to the edge
    /// visibility when the decl carries none.
    priv fn _cell_vis(self, id: *ImportDecl, cell: *OverloadCell) -> OverlayVisibility {
        var d = cell->get(0);
        if d != &null {
            if d->is_private()   { return OverlayVisibility::Private;   }
            if d->is_protected() { return OverlayVisibility::Protected; }
            if d->is_public()    { return OverlayVisibility::Public;    }
        }
        return self._edge_vis(id);
    }
}
