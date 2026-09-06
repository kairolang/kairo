/// --- The Kairo Project ------------------ Sema/Resolve/MemberLookup.k --- ///
///
///   \brief Member lookup over a CANONICAL type: own table, folded
///          extensions, then the inheritance DAG. The component RESOLUTION.md
///          §2b describes; ChainBinding and (later) inference stand on it.
///
///   \detail
///     RESOLUTION.md §2b, locked:
///
///       MERGE, not hide. A derived member named `foo` does not hide base
///       `foo` overloads; it joins them. The whole DAG is walked (dedup
///       across virtual bases), every matching cell is UNIONED, and the
///       result is handed to overload resolution.
///
///     This class implements exactly that union and nothing more. It does
///     NOT select overloads, check access, resolve virtual dispatch, or
///     diagnose ambiguity -- each has its own home. It returns the candidate
///     set; the caller judges it.
///
///   \par Extensions
///     `extend Foo { }` members live in the ExtensionDecl's OWN table (parser
///     rule). Folding them into Foo's lookup is sema's job and this is where
///     it happens: an index from canonical type -> extensions targeting it,
///     built once per run over every parsed TU (sema runs in import-DAG
///     order, so an imported file's extensions are parsed and T-resolved by
///     the time the importer looks).
///
///     Extensions on non-record types (`extend i32 { }`, `extend *T { }`) are
///     keyed by the target's canonical POINTER. Extensions on records are
///     keyed by the record's DECL, so `extend <T> Vec<T>` matches every
///     Vec<X>: at NAME-lookup level a partial-specialization extension
///     contributes its members to all instances; which instance's body runs
///     is dispatch, decided later.
///
///   \par needs_using (§2b)
///     Not recorded yet: the `needs_using` slot on the type decls does not
///     exist. When it does, the place to write it is _walk_record, at the
///     point a base cell is unioned in without the derived type overriding
///     it. One writer, this one.
///
///   Phase: LOWER (component; PRE: T complete -- base types must be canonical)
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
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::SymbolTable::*;
import AST::Context::GlobalDisambigTable::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::Declarations::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;

class MemberLookup {
    pub var sc: *SemaContext;

    /// record decl (canonical link) -> extensions targeting it.
    priv var _ext_by_decl: libcxx::unordered_map::<u64, vec::<*ExtensionDecl>>;
    /// canonical non-record type -> extensions targeting it.
    priv var _ext_by_type: libcxx::unordered_map::<u64, vec::<*ExtensionDecl>>;
    priv var _indexed: bool = false;

    fn MemberLookup(self) {
        self.sc = &null;
    }

    fn MemberLookup(self, sc: *SemaContext) {
        self.sc = sc;
    }

    // === Extension index ======================================================

    /// Build the extension index over every TU the build knows. Cheap: one
    /// pass over top-level decls per fid, no expression walking. Idempotent.
    fn index_extensions(self) {
        if self._indexed { return; }
        self._indexed = true;
        if self.sc->g == &null { return; }

        var fids = self.sc->g->all_fids();
        for var i: usize = 0; i < fids.size(); ++i {
            var ctx = self.sc->g->get_context(fids[i]);
            if ctx == &null { continue; }
            var tu = reinterpret_cast::<*TranslationUnit>(ctx->tu);
            if tu == &null { continue; }
            self._index_dc(static_cast::<*DeclContext>(tu));
        }
    }

    priv fn _index_dc(self, dc: *DeclContext) {
        if dc == &null { return; }
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var d = *(dc->dc_decls.get(i));
            if d == &null { continue; }
            self._index_decl(d);
        }
    }

    priv fn _index_decl(self, d: *Decl) {
        if isa::<ExtensionDecl>(d) {
            var e = cast::<ExtensionDecl>(d);
            if (e->target == &null) || (e->target->canonical == &null) { return; }   // dependent or errored target.
            var c = e->target->canonical;
            if isa::<RecordType>(c) {
                var key = reinterpret_cast::<u64>(cast::<RecordType>(c)->decl);
                self._ext_by_decl[key].push_back(e);
            } else {
                self._ext_by_type[reinterpret_cast::<u64>(c)].push_back(e);
            }
            return;
        }
        // Extensions may sit inside modules and visibility groups.
        if isa::<ModuleDecl>(d) {
            self._index_dc(static_cast::<*DeclContext>(cast::<ModuleDecl>(d)));
            return;
        }
        if isa::<VisibilityGroupDecl>(d) {
            var g = cast::<VisibilityGroupDecl>(d);
            for var i: usize = 0; i < g->members.size(); ++i { self._index_decl(g->members[i]); }
            return;
        }
        if isa::<EvalBlockDecl>(d) {
            var b = cast::<EvalBlockDecl>(d);
            for var i: usize = 0; i < b->body.size(); ++i { self._index_decl(b->body[i]); }
            return;
        }
    }

    fn extensions_of_decl(self, d: *Decl) -> *vec::<*ExtensionDecl> {
        var it = self._ext_by_decl.find(reinterpret_cast::<u64>(d));
        if it == self._ext_by_decl.end() { return &null; }
        return &(it->second);
    }

    fn extensions_of_type(self, c: *Type) -> *vec::<*ExtensionDecl> {
        var it = self._ext_by_type.find(reinterpret_cast::<u64>(c));
        if it == self._ext_by_type.end() { return &null; }
        return &(it->second);
    }

    // === The lookup ===========================================================

    /// Every decl named \p name reachable from canonical type \p c: own
    /// members, extension members, base members (transitively, deduped).
    /// Appends to \p out in walk order: own first, extensions, then bases
    /// breadth-first -- the order overload resolution and diagnostics want.
    /// \return true if anything was found.
    fn lookup(self, c: *Type, name: DeclName, out: *vec::<*Decl>) -> bool {
        if c == &null { return false; }
        var before = out->size();

        if isa::<RecordType>(c) {
            var seen = set::<u64>();
            self._walk_record(cast::<RecordType>(c)->decl, name, out, &seen);
        } else {
            var exts = self.extensions_of_type(c);
            if exts != &null { self._append_from_extensions(exts, name, out); }
        }
        return out->size() > before;
    }

    // === Single-scope lookup, correct across TUs ==============================

    /// Look one identifier up in ONE scope, whichever TU that scope lives in.
    ///
    /// A DeclContext's table is keyed by ITS OWN TU's imms (hard invariant
    /// #2), so probing a foreign scope with this TU's imm index is not a miss
    /// -- it is a silent WRONG answer whenever the two interners happen to
    /// agree on an index. `spelling` is the escape hatch: for a foreign scope
    /// the name is re-interned into that TU's imm space and probed there.
    fn in_scope(self, dc: *DeclContext, name: DeclName, spelling: string) -> *OverloadCell {
        if dc == &null { return &null; }
        var tu = NameLookup::tu_of(dc);
        if (tu == &null) || (tu == self.sc->tu) { return dc->lookup_symbol(name); }
        var imms = self.sc->ctx->tcm->get_imm_table_for_fid(tu->fid);
        if imms == &null { return &null; }
        return SymbolTable::lookup_foreign(dc->dc_symbols, imms, spelling);
    }

    /// Own table -> extensions -> bases. `seen` dedups the DAG so a virtual
    /// base reached twice contributes once.
    priv fn _walk_record(self, d: *Decl, name: DeclName, out: *vec::<*Decl>, seen: *set::<u64>) {
        if d == &null { return; }
        var key = reinterpret_cast::<u64>(d);
        if seen->contains(key) { return; }
        seen->insert(key);

        // 1. own table.
        var dc = NameLookup::context_of(d);
        if dc != &null {
            var cell = dc->lookup_symbol(name);
            if cell != &null { self._append_cell(cell, out); }
        }

        // 2. extensions on this exact decl.
        var exts = self.extensions_of_decl(d);
        if exts != &null { self._append_from_extensions(exts, name, out); }

        // 3. bases and implemented interfaces (default bodies join the set).
        if isa::<ClassDecl>(d) {
            var cd = cast::<ClassDecl>(d);
            for var i: usize = 0; i < cd->derives_list.size(); ++i {
                self._walk_edge(cd->derives_list.get(i), name, out, seen);
            }
            for var i: usize = 0; i < cd->implements.size(); ++i {
                self._walk_edge(cd->implements.get(i), name, out, seen);
            }
            return;
        }
        if isa::<StructDecl>(d) {
            var sd = cast::<StructDecl>(d);
            for var i: usize = 0; i < sd->implements.size(); ++i {
                self._walk_edge(sd->implements.get(i), name, out, seen);
            }
            return;
        }
        if isa::<InterfaceDecl>(d) {
            var id = cast::<InterfaceDecl>(d);
            for var i: usize = 0; i < id->derives_list.size(); ++i {
                self._walk_edge(id->derives_list.get(i), name, out, seen);
            }
            return;
        }
        // UnionDecl / EnumDecl: no bases.
    }

    priv fn _walk_edge(self, e: *InheritEdge, name: DeclName, out: *vec::<*Decl>, seen: *set::<u64>) {
        if (e == &null) || (e->base == &null) { return; }
        var c = e->base->canonical;
        if c == &null { return; }                 // dependent base: M2's problem.
        if !isa::<RecordType>(c) { return; }      // ConformanceChecking diagnoses.
        self._walk_record(cast::<RecordType>(c)->decl, name, out, seen);
    }

    priv fn _append_from_extensions(self, exts: *vec::<*ExtensionDecl>, name: DeclName, out: *vec::<*Decl>) {
        for var i: usize = 0; i < exts->size(); ++i {
            var e = (*exts)[i];
            var dc = static_cast::<*DeclContext>(e);
            var cell = dc->lookup_symbol(name);
            if cell != &null { self._append_cell(cell, out); }
        }
    }

    /// Append every decl of a cell, skipping duplicates by identity (a decl
    /// reached through two paths is one candidate).
    priv fn _append_cell(self, cell: *OverloadCell, out: *vec::<*Decl>) {
        for var i: usize = 0; i < cell->size(); ++i {
            var d = cell->get(i);
            if d == &null { continue; }
            var dup = false;
            for var j: usize = 0; j < out->size(); ++j {
                if (*out)[j] == d { dup = true; break; }
            }
            if !dup { out->push_back(d); }
        }
    }
}