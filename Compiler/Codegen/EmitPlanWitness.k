/// --- The Kairo Project -------------------- Codegen/EmitPlanWitness.k --- ///
///
///   EmitPlan, part: witnesses. The witness pieces an interface-bound call
///   needs (Compiler/Spec/Witnesses.md#emission): the primary, the rows for
///   each conforming type, their bounds and signatures, and what each depends
///   on.
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
ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "llvm/ADT/StringMap.h"
ffi "c++" import "vector"

import AST::Context::InstantiationRegistry::{
    ConformanceRow,
    InstanceEntry,
}
import AST::DeclFacts
import AST::LangItems::{
    LowerTargets,
    WellKnownType,
}
import AST::Node::Base::{
    Decl,
    Type,
}
import AST::Node::CanonicalNodes::{
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Expressions::ConstraintExpr
import AST::Node::Types::NullableType
import AST::ParamMode::ParamMode
import Codegen::Emit::EmitWitness::{
    EmitWitness,
    WitnessPiece,
}
import Codegen::Emit::Spell::Speller
import Codegen::EmitPlan::{
    EmitPlan,
    PlanMode,
    PlanNeed,
}
import Codegen::EmitPlanAdmit
import Codegen::EmitPlanEarly
import Codegen::EmitPlanLayout
import Codegen::EmitPlanRoots

extend EmitPlan {
    /// # Witnesses (Compiler/Spec/Witnesses.md#emission)

    /// `iface`'s primary and concept, created on first touch. Its deps are the
    /// by-value records its forwarders' signatures name (an inline definition
    /// lays them out); a concept conjoins its bases' concepts, so their
    /// primaries come first.
    fn _witness_primary(self, iface_in: unsafe *Decl) -> usize {
        var unsafe *iface = Speller::rep(
            DeclFacts::decl_pattern(Speller::rep(iface_in)),
        )

        for var i: usize = 0; i < self._witnesses.size(); ++i {
            if self._witnesses[i].iface == iface && self._witnesses[i].row == &null {
                return i
            }
        }

        var fresh = WitnessPiece()
        fresh.iface = iface
        fresh.key   = self._spell.witness_name(iface)
        self._witnesses.push_back(fresh)
        var k = self._witnesses.size() - 1

        // Every requirement it derives is its own member (InterfaceComposition),
        // and its concept conjoins no base's: no base primary is needed first.
        var ms = EmitWitness(self._cg, unsafe &self._spell).members(
            cast<Declarations::InterfaceDecl>(iface),
        )

        for var i: usize = 0; i < ms.size(); ++i {
            var unsafe *m = ms[i]
            if m == &null || m->is_poisoned() {
                continue
            }

            self._witness_sig(k, m)
        }

        return k
    }

    /// `row`'s specialization, when the primary does not serve it (§7b.4):
    /// after the primary, the conformer complete, and every extension scope
    /// it forwards to defined.
    fn _witness_row(self, row: unsafe *ConformanceRow) {
        if row == &null || row->iface_decl == &null {
            return
        }

        // The rows its associated types' bounds rest on come with it, whether
        // or not this row needs a specialization of its own: a body reaching
        // `T::Item::Inner` spells `Holder_witness<Purse>` (ConformanceRow::
        // assoc_rows). So do the rows its witnesses' extension bounds rest
        // on (ConformanceRow::bound_rows). Once each: a row may name itself
        // through a bound.
        var seen = false
        for var i: usize = 0; i < self._assoc_seen.size(); ++i {
            if self._assoc_seen[i] == row {
                seen = true
            }
        }

        if !seen {
            self._assoc_seen.push_back(row)
            for var i: usize = 0; i < row->assoc_rows.size(); ++i {
                self._witness_row(row->assoc_rows[i])
            }

            for var i: usize = 0; i < row->bound_rows.size(); ++i {
                self._witness_row(row->bound_rows[i])
            }
        }

        // The conformer complete, whichever witness serves the row: the
        // primary's members are `requires`-guarded on `&A::alloc` and the like,
        // which an incomplete A fails, so a concept on a type this TU only
        // names as a generic argument (`alloc_bytes<System>`) would be false
        // and the call rejected. A specialization's _witness_dep below makes it
        // complete too, but a row the primary serves never reaches that. A
        // generic row's conformer is dependent: its template is handled there.
        if !EmitWitness::is_generic_row(row) {
            self._admit_type(row->conformer, PlanNeed::Complete)
        }

        var unsafe *iface = Speller::rep(row->iface_decl)
        self._witness_primary(iface)
        var ew = EmitWitness(self._cg, unsafe &self._spell)
        // A generic declared row's partial specialization is this row's witness
        // already (§7b.3): admitting it, never a full one beside it, keeps one
        // definition per conformance. Only when it is emitted at all -- were the
        // primary to serve the generic row but not this one, the full one is
        // still the only witness this row has.
        var unsafe *g = row->covered_by
        if g != &null && ew.needs_specialization(g) {
            self._witness_row(g)
            return
        }

        if !ew.needs_specialization(row) {
            return
        }

        // Keyed with usize / isize folded: where
        // the target spells usize as u64's C++ type, `Hash_witness<usize>` and
        // `Hash_witness<u64>` are one C++ class, and a second definition is a
        // clang redefinition. The first row in wins; two conformances of one C++
        // type must agree (base/hash.k's do: both hash the 64-bit value).
        self._spell.fold_sizes = true
        var key = self._spell.witness_name(iface) + self._spell.witness_args(
            self._spell._type(row->conformer),
            row->iface,
        )

        self._spell.fold_sizes = false
        for var i: usize = 0; i < self._witnesses.size(); ++i {
            if self._witnesses[i].row == row
                || self._witnesses[i].row != &null && self._witnesses[i].key == key {
                return
            }
        }

        var fresh = WitnessPiece()
        fresh.iface = iface
        fresh.row   = row
        fresh.key   = key.copy()
        fresh.after.push_back(iface)
        self._witnesses.push_back(fresh)
        var k = self._witnesses.size() - 1

        self._witness_dep(k, row->conformer)
        if EmitWitness::is_generic_row(row) && isa<RecordType>(row->conformer) {
            // A partial specialization names the conformer's template, which
            // _witness_dep leaves alone as dependent: the primary must be
            // declared, and is defined first, as a full specialization's is.
            var unsafe *cd = self.layout_decl(
                cast<RecordType>(row->conformer)->decl,
            )

            if cd != &null && !DeclFacts::decl_is_imported(cd) {
                var unsafe *o = self._outermost_type(cd)
                self._admit(o, PlanNeed::Complete)
                var have = false
                for var i: usize = 0; i < self._witnesses[k].deps.size(); ++i {
                    if self._witnesses[k].deps[i] == o {
                        have = true
                    }
                }

                if !have {
                    self._witnesses[k].deps.push_back(o)
                }
            }
        }

        var ms = ew.members(cast<Declarations::InterfaceDecl>(iface))
        for var i: usize = 0; i < ms.size(); ++i {
            var unsafe *m = ms[i]
            if m == &null || m->is_poisoned() {
                continue
            }

            self._witness_sig(k, m)
        }

        for var i: usize = 0; i < row->witnesses.size(); ++i {
            var unsafe *w = row->witnesses[i]
            if w == &null {
                continue
            }

            // An associated type's witness is an alias (or the requirement, for
            // a default): what the specialization needs is the TYPE, complete,
            // since its inline members return it by value.
            if isa<Declarations::TypeAliasDecl>(w) {
                if i < row->assoc_types.size() && row->assoc_types[i] != &null {
                    self._witness_dep(k, row->assoc_types[i])
                }

                continue
            }

            // A constructor slot is forwarded to by nothing: the bounded body
            // constructs `T(args)` itself, wherever the conformer is complete.
            if i < ms.size() && ms[i] != &null && DeclFacts::decl_is_ctor_requirement(ms[i]) {
                continue
            }

            // A native operation (the requirement itself as the witness, e.g. a
            // builtin's `==`) forwards to no decl: nothing to admit.
            if DeclFacts::decl_is_requirement(w) {
                continue
            }

            var unsafe *x = DeclFacts::decl_extension_of(w)
            if x != &null {
                self._witness_scope(k, x)
                continue
            }

            self._admit_use(w) // an own member: its owner complete.
        }
    }

    /// `std::hash<K>` for a Kairo record K that conforms to Hash: `e` is that
    /// imported instance, which a C++ container keyed by K names as its default
    /// hasher (`unordered_map<K, V, std::hash<K>, ...>`, as the registry spells
    /// it). The primary is disabled for a type C++ knows nothing of, so this TU
    /// specializes it (WitnessPiece::std_hash) over the row's witness, pulled
    /// in here: the TU that declares the conformance is not the one that keys
    /// the map. A record that conforms structurally has no recorded row, and a
    /// nested one cannot be declared ahead of the records that hold the map;
    /// both are left to C++'s own error, as a C++ type without a hash is.
    fn _std_hash(self, prim: unsafe *Decl, e: unsafe *InstanceEntry) {
        if e->args.size() != 1 || isa<Declarations::FunctionDecl>(prim) {
            return
        }

        var sp = DeclFacts::decl_cxx_spelling(prim)
        if !LowerTargets::is_cxx_std_hash(sp) {
            return
        }

        var unsafe *k = e->args[0]
        if k == &null || k->is_dependent() {
            return
        }

        var unsafe *kc = canon_unqual(
            if (k->canonical != &null) => (k->canonical) else => k,
        )

        if !isa<RecordType>(kc) {
            return
        }

        var unsafe *kd = Speller::rep(cast<RecordType>(kc)->decl)
        if kd == &null || DeclFacts::decl_is_imported(kd) {
            return
        }

        var unsafe *pd = Speller::rep(DeclFacts::decl_pattern(kd))
        if self._outermost_type(pd) != pd {
            return
        }

        var *gs = self._cg->tu->global_scope
        if gs == &null {
            return
        }

        var unsafe *hd = gs->well_known()->get(WellKnownType::Hash)
        if hd == &null {
            return
        }

        var rows = cxx::std::vector<unsafe *ConformanceRow>()
        self._cg->instances->rows_of(kc, unsafe &rows)
        var row: unsafe *ConformanceRow = &null
        for var i: usize = 0; i < rows.size(); ++i {
            if rows[i]->ok
                && rows[i]->iface_decl != &null
                && Speller::rep(rows[i]->iface_decl) == Speller::rep(hd) {
                row = rows[i]
                break
            }
        }

        if row == &null {
            return
        }

        if self._mode != PlanMode::Preamble && self._hidden(kd) {
            return
        }

        self._witness_row(row)
        // Keyed with usize / isize folded, as a row's specialization is: one
        // C++ class per C++ type.
        self._spell.fold_sizes = true
        var key = LowerTargets::cxx_std_hash() + "<" + self._spell._type(
            row->conformer,
        ) + ">"
        self._spell.fold_sizes = false
        for var i: usize = 0; i < self._witnesses.size(); ++i {
            if self._witnesses[i].std_hash && self._witnesses[i].key == key {
                return
            }
        }

        var unsafe *iface = Speller::rep(row->iface_decl)
        var        fresh  = WitnessPiece()
        fresh.iface    = iface
        fresh.row      = row
        fresh.key      = key.copy()
        fresh.std_hash = true
        fresh.after.push_back(iface)
        self._witnesses.push_back(fresh)
        self._witness_dep(self._witnesses.size() - 1, row->conformer)
    }

    /// The rows `d` DECLARES (`class X impl I`, `extend X impl I`), where `d`
    /// is emitted: there both X and I are complete -- `d` defines or extends
    /// X and names I -- and a C++ host instantiating a bounded template with X
    /// finds the specialization in the header that defines X, though no Kairo
    /// instance ever paired them (§7b.6). A header leaves out a row whose X or
    /// I it does not carry: the host cannot name either.
    fn _witness_declared(self, d: unsafe *Decl) {
        var rows = cxx::std::vector<unsafe *ConformanceRow>()
        self._cg->instances->declared_rows(d, unsafe &rows)
        for var i: usize = 0; i < rows.size(); ++i {
            var unsafe *row = rows[i]
            if self._mode != PlanMode::Preamble {
                if self._hidden(row->iface_decl) {
                    continue
                }

                if isa<RecordType>(row->conformer)
                    && self._hidden(cast<RecordType>(row->conformer)->decl) {
                    continue
                }
            }

            self._witness_row(row)
        }
    }

    /// The primaries of every interface `f`'s bounds name: its template head
    /// carries their concepts (Speller::requires_clause), so its declaration
    /// needs them, not only its body. A primary record's head carries none
    /// (Speller::defers_bounds), but its member bodies still call through
    /// `I_witness<A>`, and they are written where the record is defined: in
    /// its own TU, a header has the primaries too (base/alloc.hh's
    /// AllocatorScope<A impl ScopedFullAllocator> named a witness no header
    /// declared).
    fn _witness_bounds(self, f: unsafe *Decl) {
        if f == &null {
            return
        }

        // Not in the escaping probe: its answer is what ordinary codegen puts
        // in an anonymous namespace, which no header concerns.
        var own_deferred = self._mode != PlanMode::Preamble
            && (!self._escaping_probe)
            && Speller::defers_bounds(f)
            && Speller::fid_of(f) == self._home
            && Speller::template_params(f).size() > 0
        if (!own_deferred) && (self._spell.requires_clause(f).size() == 0) {
            return
        }

        var        cs = cxx::std::vector<unsafe *ConstraintExpr>()
        var unsafe *x = DeclFacts::decl_extension_of(f)
        if x != &null {
            Speller::impl_bounds(DeclFacts::decl_requires_clause(x), unsafe &cs)
        }

        Speller::impl_bounds(DeclFacts::decl_requires_clause(f), unsafe &cs)
        for var i: usize = 0; i < cs.size(); ++i {
            var unsafe *c = cs[i]
            if c->rhs == &null
                || c->rhs->canonical == &null
                || !isa<RecordType>(canon_unqual(c->rhs->canonical)) {
                continue
            }

            var unsafe *d = cast<RecordType>(canon_unqual(c->rhs->canonical))->decl
            if isa<Declarations::InterfaceDecl>(
                Speller::rep(DeclFacts::decl_pattern(Speller::rep(d))),
            ) {
                self._admit(d, PlanNeed::Complete)
            }
        }
    }

    /// Requirement `f`'s by-value records, as a forwarder's are.
    fn _witness_sig(self, k: usize, f: unsafe *Declarations::FunctionDecl) {
        self._witness_dep(k, f->return_type)
        if f->panic_result != &null {
            self._witness_dep(k, f->panic_result)
        }

        for var j: usize = 0; j < f->params.size(); ++j {
            var unsafe *p = f->params[j]
            if p == &null || p->is_self {
                continue
            }

            // A parameter passed by reference (`@inout h: Hasher`) needs its
            // type declared where the concept and the witness name it.
            if p->mode != ParamMode::Value {
                self._admit_type(p->type_, PlanNeed::Fwd)
                continue
            }

            self._witness_dep(k, p->type_)
        }
    }

    /// A by-value record `t` is a Complete dependency of witness `k`. An
    /// interface (the requirement's own `Self`) is spelled as Self, never laid
    /// out; an imported record is the header's. `T?` is its record to C++
    /// (NullableTypeLowering), held by value.
    fn _witness_dep(self, k: usize, t: unsafe *Type) {
        if t == &null || t->canonical == &null {
            return
        }

        var unsafe *c = canon_unqual(t->canonical)
        if isa<NullableType>(c) {
            self._admit_type(t, PlanNeed::Complete)
            self._witness_dep(k, self._nullable_record(c))
            return
        }

        if !isa<RecordType>(c) {
            self._admit_type(t, PlanNeed::Complete)
            return
        }

        var unsafe *d = self.layout_decl(cast<RecordType>(c)->decl)
        if d == &null || DeclFacts::decl_is_imported(d) || isa<Declarations::InterfaceDecl>(d) {
            return
        }

        if c->is_dependent() {
            // A requirement's signature names a generic record at its own
            // parameters: `Self::Item?` is `Null<Self::Item>`, and a generic
            // interface's panic result names its parameters (Compiler/Spec/Panic.md).
            // A specialization's inline forwarder spells it at the row's
            // associated types, which C++ instantiates where the forwarder is
            // defined whenever they are concrete -- a partial
            // specialization's too (`Item = i64` over `Widen<I>`). So the
            // template is defined first; the row's associated types are deps
            // of their own. Nothing waits on a specialization, so the edge
            // closes no cycle. The primary stays a template over Self: only
            // the panic record is needed ahead of it.
            var unsafe *en = dyn_cast<Declarations::EnumDecl>(
                Speller::rep(cast<RecordType>(c)->decl),
            )

            if self._witnesses[k].row == &null && (en == &null || !en->adt_explicit_tags) {
                return
            }

            self._admit(d, PlanNeed::Complete)
            var unsafe *po  = self._outermost_type(d)
            var        seen = false
            for var i: usize = 0; i < self._witnesses[k].deps.size(); ++i {
                if self._witnesses[k].deps[i] == po {
                    seen = true
                }
            }

            if !seen {
                self._witnesses[k].deps.push_back(po)
            }

            var unsafe *r = cast<RecordType>(c)
            for var i: usize = 0; i < r->args.size(); ++i {
                self._witness_dep(k, r->args[i])
            }

            return
        }

        self._admit_type(t, PlanNeed::Complete)
        var unsafe *o = self._outermost_type(d)
        for var i: usize = 0; i < self._witnesses[k].deps.size(); ++i {
            if self._witnesses[k].deps[i] == o {
                return
            }
        }

        self._witnesses[k].deps.push_back(o)
    }

    fn _witness_scope(self, k: usize, x: unsafe *Declarations::ExtensionDecl) {
        var s = self._scope_for(x, true)
        for var i: usize = 0; i < self._witnesses[k].scopes.size(); ++i {
            if self._witnesses[k].scopes[i] == s {
                return
            }
        }

        self._witnesses[k].scopes.push_back(s)
    }
}
