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
import Sema::Foreign::ForeignInstantiate::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::SymbolTable::*;
import AST::Context::GlobalDisambigTable::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::Declarations::*;
import AST::DeclFacts::*;
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
    /// This TU's spelling of the name the current lookup() is walking. See
    /// in_scope: a foreign scope's table cannot be probed with our imm.
    priv var _cur_spelling: string = "";

    // No _ext_by_shape index: `extend <T> [T]` now targets
    // record(Vector, [T]), so it keys on the Vector primary through
    // _ext_by_decl like any other generic extension on a record.

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
            if (e->target == &null) || (e->target->canonical == &null) { return; }   // errored, or a TU whose T has not run.
            var c = canon_unqual(e->target->canonical);
            if isa::<RecordType>(c) {
                // Keyed by DECL: `extend <T> Vec<T>` contributes to every
                // Vec<X> at name level. RecordType::decl for a dependent
                // target is the primary (#12), which is the key we want.
                var key = reinterpret_cast::<u64>(cast::<RecordType>(c)->decl);
                self._ext_by_decl[key].push_back(e);
            } else {
                // `extend i32 { }`, `extend [u8] { }`: one exact canonical.
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
    /// \return true if anything was found. A const vector has vector's
    /// members; which of them may be called on a const object is
    /// ConstChecking's.
    fn lookup(self, c_in: *Type, name: DeclName, out: *vec::<*Decl>) -> bool {
        var c = canon_unqual(c_in);
        if c == &null { return false; }
        var before = out->size();

        // Spelled once per lookup, not once per scope: the walk can cross into
        // several TUs (a base class in one file, an extension in another) and
        // each of their tables is keyed by its own imms.
        self._cur_spelling = self._spell(name);

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
        // Only IDENTIFIER payloads are per-TU. Operator and ctor keys are
        // built from TokenKinds, which are stable across the build.
        if name.kind != DeclNameKind::Identifier { return dc->lookup_symbol(name); }
        if spelling.size() == 0 { return dc->lookup_symbol(name); }
        var tu = NameLookup::tu_of(dc);
        if (tu == &null) || (tu == self.sc->tu) { return dc->lookup_symbol(name); }
        var imms = self.sc->ctx->tcm->get_imm_table_for_fid(tu->fid);
        if imms == &null { return &null; }
        return SymbolTable::lookup_foreign(dc->dc_symbols, imms, spelling);
    }

    /// This TU's spelling of an identifier DeclName, for re-interning into a
    /// foreign scope's imm space. Empty for a non-identifier key, which needs
    /// no translation.
    priv fn _spell(self, name: DeclName) -> string {
        if name.kind != DeclNameKind::Identifier { return ""; }
        var imms = self.sc->ctx->get_imm_table();
        if imms == &null { return ""; }
        return imms->get_ident(name.payload);
    }

    /// The names a module RE-EXPORTS, for a `mod::name` step that missed in
    /// the module's own table.
    ///
    /// A file's `pub import bar` is part of its surface (RESOLUTION.md §2,
    /// two walls), but a re-exported name lives in the source TU's OVERLAY,
    /// not in its symbol table -- and a plain `import foo` in a third file
    /// binds foo's ModuleDecl, whose shared table is exactly that symbol
    /// table. So `foo::f` has to ask foo's overlay, which is what this does.
    ///
    /// Returns null unless some target under that key came in through a
    /// pub/prot import; a PRIVATE import edge in the source is never surface
    /// (wall 1).
    fn reexport_lookup(self, scope: *DeclContext, spelling: string) -> *OverloadCell {
        if scope == &null { return &null; }
        var tu = NameLookup::tu_of(scope);
        if tu == &null { return &null; }
        if tu->import_overlay == &null { return &null; }

        var imms = self.sc->ctx->tcm->get_imm_table_for_fid(tu->fid);
        if imms == &null { return &null; }
        var key = imms->find_ident(spelling);          // probe only; never intern.
        if key == u32(-1) { return &null; }

        var entry = tu->import_overlay->entry(key);
        if entry == &null { return &null; }
        var surface = false;
        for var i: usize = 0; i < entry->targets.size(); ++i {
            var o = dyn_cast::<ImportDecl>(entry->targets[i].origin);
            if o == &null { continue; }
            if o->is_public() || o->is_protected() { surface = true; break; }
        }
        if !surface { return &null; }
        return tu->import_overlay->lookup_ident(key);
    }

    /// Own table -> extensions -> bases. `seen` dedups the DAG so a virtual
    /// base reached twice contributes once.
    priv fn _walk_record(self, d: *Decl, name: DeclName, out: *vec::<*Decl>, seen: *set::<u64>) {
        if d == &null { return; }
        var key = reinterpret_cast::<u64>(d);
        if seen->contains(key) { return; }
        seen->insert(key);

        // 0. An instance of an IMPORTED template has an empty table until
        //    clang fills it. Fill BEFORE step 1 reads that table -- at 2b the
        //    first lookup through a fresh instance would miss every member it
        //    was about to get. A failed fill leaves it unfilled, and 2b walks
        //    the pattern exactly as before fills existed.
        MemberLookup::ensure_filled(self.sc, d);

        // 1. own table.
        var dc = NameLookup::context_of(d);
        if dc != &null {
            var cell = self.in_scope(dc, name, self._cur_spelling);
            if cell != &null { self._append_cell(cell, out); }
        }

        // 2. extensions on this exact decl, and on the PRIMARY this decl is
        //    an instance of: `extend <T> Vec<T>` contributes to `Vec<i32>`
        //    whether that instance is implicit or a user-written spec (#12).
        var exts = self.extensions_of_decl(d);
        if exts != &null { self._append_from_extensions(exts, name, out); }
        var pat = decl_instantiated_from(d);
        if (pat != &null) && (pat != d) {
            var pexts = self.extensions_of_decl(pat);
            if pexts != &null { self._append_from_extensions(pexts, name, out); }
            // 2b. An implicit instantiation nobody has filled (M2, or clang
            //     via step 0) has an empty table and an empty base list. The
            //     names it WILL have are the pattern's: walk that instead
            //     (seen dedups).
            if MemberLookup::unfilled(d) { self._walk_record(pat, name, out, seen); return; }
        }

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

    /// An instance whose table is still empty. `instantiated` is the one
    /// answer for both fillers: M2 sets it for a Kairo pattern,
    /// ForeignInstantiate for an imported one. It must not be short-circuited
    /// by filled_by_clang (which is true for the instance's whole life): a
    /// filled foreign instance walking its pattern would see the pattern's
    /// dependent spellings -- `size_type` unresolved -- instead of clang's.
    /// Public because TypeResolve asks the same question of a `::` head.
    static fn unfilled(d: *Decl) -> bool {
        return decl_is_instance(d) && (!decl_instantiated(d));
    }

    /// THE fill trigger: if \p d is an unfilled shell of an imported
    /// template, have clang fill it now. Both readers of a shell's table
    /// call this before reading it -- member lookup (`c.size`) and
    /// TypeResolve's `::` step (`traits<alloc>::size_type`) -- so neither
    /// can miss a member the other would have filled in. A failed fill is
    /// sticky and leaves \p d unfilled; callers fall back exactly as they
    /// did before fills existed. True when \p d's own table is readable.
    static fn ensure_filled(sc: *SemaContext, d: *Decl) -> bool {
        if !MemberLookup::unfilled(d) { return true; }
        if !MemberLookup::filled_by_clang(d) { return false; }   // M2's, not clang's.
        if (sc == &null) || (sc->foreign == &null) { return false; }
        return sc->foreign->fill(d, sc->diag);
    }

    /// True when \p d is an instance whose primary came from a C++ header --
    /// before AND after it is filled. Such an instance is clang's: M2 must
    /// SKIP it, and its members come from ForeignInstantiate::fill (clang's
    /// own instantiation, imported), not from substituting into the pattern.
    /// Public because M2 is the other reader.
    static fn filled_by_clang(d: *Decl) -> bool {
        return decl_is_instance(d) && decl_is_imported(decl_instantiated_from(d));
    }

    static fn primary_is_imported(p: *Decl) -> bool {
        return decl_is_imported(p);
    }

    // === ADL ==================================================================

    /// The scopes argument-dependent lookup searches for a value of type \p t:
    /// every module enclosing the record's declaration, innermost first, up to
    /// (excluding) its TU, then the same for each generic argument. Pointers,
    /// references and nullables peel to what they refer to: C++ associates
    /// `T*` and `T&` with T's namespaces, and `op <<` on `std::ostream&` is
    /// the case this exists for. A C++ namespace imported by Sema/Foreign is
    /// a ModuleDecl, so `std` lands here exactly as a Kairo `module` does.
    ///
    /// Appends only scopes not already in \p out, so callers accumulate over
    /// every operand / argument into one list.
    fn associated_scopes(self, t: *Type, out: *vec::<*DeclContext>) {
        var c = self._peel(t);
        if (c == &null) || (!isa::<RecordType>(c)) { return; }
        var rt = cast::<RecordType>(c);
        self._enclosing_modules(rt->decl, out);
        for var i: usize = 0; i < rt->args.size(); ++i { self.associated_scopes(rt->args[i], out); }
    }

    /// The FILE scope a value's record type was declared in, for OPERATOR
    /// lookup only. _enclosing_modules stops at the TU on purpose: every free
    /// function in the declaring file would otherwise be an ADL candidate
    /// wherever the type is used. An operator is the one thing a file declares
    /// FOR its types, and without this a free `op *` beside a file-scope type
    /// is unreachable from every file, its own included.
    fn declaring_scope(self, t: *Type, out: *vec::<*DeclContext>) {
        var c = self._peel(t);
        if (c == &null) || (!isa::<RecordType>(c)) { return; }
        var d = cast::<RecordType>(c)->decl;
        if d == &null { return; }
        if d->semantic_dc == &null {
            var p = decl_instantiated_from(d);
            if p != &null { d = p; }
        }
        var tu = NameLookup::tu_of(reinterpret_cast::<*DeclContext>(d->semantic_dc));
        if tu == &null { return; }
        var dc = static_cast::<*DeclContext>(tu);
        if !self._has_dc(out, dc) { out->push_back(dc); }
    }

    /// Functions named \p name in each of \p scopes, minus anything already in
    /// \p skip (member lookup's answer) or \p out: the ADL half of an operator
    /// or unqualified-call candidate set. A decl reached two ways is one
    /// candidate, the same identity rule as _append_cell.
    fn adl_candidates(self, scopes: *vec::<*DeclContext>, name: DeclName, spelling: string,
                      skip: *vec::<*Decl>, out: *vec::<*Decl>) {
        for var s: usize = 0; s < scopes->size(); ++s {
            var cell = self.in_scope((*scopes)[s], name, spelling);
            if cell == &null { continue; }
            for var i: usize = 0; i < cell->size(); ++i {
                var d = cell->get(i);
                if (d == &null) || (!isa::<FunctionDecl>(d)) { continue; }
                if self._has(skip, d) || self._has(out, d) { continue; }
                out->push_back(d);
            }
        }
    }

    /// A C++ reference names its referee, and a qualifier names the same
    /// object: neither has members of its own. Loops, so `const T&`
    /// (cxx_lref(qualified(CONST, T))) peels to T in one call. Separate
    /// from _peel because the member step must NOT peel pointers or
    /// nullables -- those belong to the separator (`.` vs `->`, `?.`).
    fn peel_ref(self, t: *Type) -> *Type {
        var c = t;
        while c != &null {
            if isa::<CXXLValueRefType>(c) { c = cast::<CXXLValueRefType>(c)->referee; continue; }
            if isa::<CXXRValueRefType>(c) { c = cast::<CXXRValueRefType>(c)->referee; continue; }
            if isa::<QualifiedType>(c)    { c = cast::<QualifiedType>(c)->inner;      continue; }
            break;
        }
        return c;
    }

    priv fn _peel(self, t: *Type) -> *Type {
        var c = t;
        while c != &null {
            if isa::<PointerType>(c)  { c = cast::<PointerType>(c)->pointee; continue; }
            if isa::<NullableType>(c) { c = cast::<NullableType>(c)->inner;  continue; }
            var r = self.peel_ref(c);
            if r != c { c = r; continue; }
            break;
        }
        return c;
    }

    /// Stops AT the TU: a Kairo file's top level is its own module_self, so
    /// adding it would make every free function in the declaring file an ADL
    /// candidate everywhere the type is used. Consequence for C++: a type in
    /// the global namespace associates no scope, so a global `operator<<` for
    /// it is not found this way.
    priv fn _enclosing_modules(self, d: *Decl, out: *vec::<*DeclContext>) {
        if d == &null { return; }
        var src = d;
        // An implicit instance may not carry a semantic_dc of its own; its
        // primary's is the answer either way.
        if src->semantic_dc == &null {
            var p = decl_instantiated_from(d);
            if p != &null { src = p; }
        }
        var dc = reinterpret_cast::<*DeclContext>(src->semantic_dc);
        while dc != &null {
            if dc->dc_kind == DeclContextKind::TranslationUnit { return; }
            if (dc->dc_kind == DeclContextKind::Module) && (!self._has_dc(out, dc)) { out->push_back(dc); }
            dc = dc->parent_context();
        }
    }

    priv fn _has(self, v: *vec::<*Decl>, d: *Decl) -> bool {
        if v == &null { return false; }
        for var i: usize = 0; i < v->size(); ++i { if (*v)[i] == d { return true; } }
        return false;
    }

    priv fn _has_dc(self, v: *vec::<*DeclContext>, dc: *DeclContext) -> bool {
        for var i: usize = 0; i < v->size(); ++i { if (*v)[i] == dc { return true; } }
        return false;
    }

    priv fn _walk_edge(self, e: *InheritEdge, name: DeclName, out: *vec::<*Decl>, seen: *set::<u64>) {
        if (e == &null) || (e->base == &null) { return; }
        var c = canon_unqual(e->base->canonical);
        if c == &null { return; }                 // dependent base: M2's problem.
        if !isa::<RecordType>(c) { return; }      // ConformanceChecking diagnoses.
        self._walk_record(cast::<RecordType>(c)->decl, name, out, seen);
    }

    priv fn _append_from_extensions(self, exts: *vec::<*ExtensionDecl>, name: DeclName, out: *vec::<*Decl>) {
        for var i: usize = 0; i < exts->size(); ++i {
            var e = (*exts)[i];
            var dc = static_cast::<*DeclContext>(e);
            var cell = self.in_scope(dc, name, self._cur_spelling);
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