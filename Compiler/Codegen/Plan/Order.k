/// --- The Kairo Project ------------------------- Codegen/Plan/Order.k --- ///
///
///   EmitPlan, part: ordering. The emission order of the working set: a
///   stable topological sort on Complete edges, the needs each entry has of
///   the others, and the specializations kept after their primary.
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

import AST::DeclFacts
import AST::Kind::DeclKind::DeclKind
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
import AST::Node::Types::TypeExpr
import Codegen::Interface::Witness::{
    EmitWitness,
    WitnessPiece,
}
import Codegen::Plan::Early
import Codegen::Plan::EmitPlan::{
    EmitPlan,
    LayoutSpine,
    NeedRow,
    PlanEntry,
    PlanMode,
    PlanNeed,
    PlanTier,
}
import Codegen::Plan::Homes
import Codegen::Plan::Layout
import Codegen::Spell::Spell::Speller

extend EmitPlan {
    /// # Ordering

    fn _order(self) {
        self._early()
        // Tier 0: forward declarations. Namespace-scope types only; a nested
        // type cannot be forward-declared outside its owner.
        var t0: cxx::std::vector<PlanEntry>
        for var i: usize = 0; i < self._set.size(); ++i {
            var unsafe *d = self._set[i]
            if !self._is_type_decl(d) {
                continue
            }

            t0.push_back(self._entry(d, PlanNeed::Fwd, PlanTier::FwdDecls))
        }

        // The closure is done: _scopes no longer grows, so entries may point in.
        for var i: usize = 0; i < self._scopes.size(); ++i {
            var e = self._entry(
                self._scopes[i].anchor,
                PlanNeed::Fwd,
                PlanTier::FwdDecls,
            )

            e.scope = unsafe &self._scopes[i]
            t0.push_back(e)
        }

        // A witness primary is declared up front, so a specialization or a
        // body can name it in any order tier 1 settles on.
        for var i: usize = 0; i < self._witnesses.size(); ++i {
            if self._witnesses[i].row != &null {
                continue
            }

            var e = self._entry(
                self._witnesses[i].iface,
                PlanNeed::Fwd,
                PlanTier::FwdDecls,
            )

            e.witness = unsafe &self._witnesses[i]
            e.own     = true // written wherever it is needed; one text everywhere (§7b.6).
            t0.push_back(e)
        }

        self._sort(&t0)
        self._specs_after_primary(&t0)
        // Three runs: every forward declaration whose head names no concept,
        // then the concepts (a requires-parameter needs its type declared, not
        // complete; a base's concept first), then the bounded records' forward
        // declarations, whose heads name them (Compiler/Spec/Witnesses.md#the-concept).
        var bounded = cxx::std::vector<PlanEntry>()
        for var i: usize = 0; i < t0.size(); ++i {
            var *e = &t0[i]
            if e->witness == &null
                && e->scope == &null
                && self._spell.requires_clause(e->decl).size() > 0 {
                bounded.push_back(t0[i])
                continue
            }

            self.entries.push_back(t0[i])
        }

        var cs = cxx::std::vector<PlanEntry>()
        for var i: usize = 0; i < self._witnesses.size(); ++i {
            if self._witnesses[i].row != &null {
                continue
            }

            var e = self._entry(
                self._witnesses[i].iface,
                PlanNeed::Fwd,
                PlanTier::FwdDecls,
            )

            e.witness    = unsafe &self._witnesses[i]
            e.is_concept = true
            e.own        = true
            cs.push_back(e)
        }

        self._sort(&cs)
        self._toposort(&cs)
        for var i: usize = 0; i < cs.size(); ++i {
            self.entries.push_back(cs[i])
        }

        for var i: usize = 0; i < bounded.size(); ++i {
            self.entries.push_back(bounded[i])
        }

        // Last, the std::hash adapters' classes (WitnessPiece::std_hash): each
        // names its K, now declared, and every record definition below may
        // instantiate it through a container's hasher.
        for var i: usize = 0; i < self._witnesses.size(); ++i {
            if !self._witnesses[i].std_hash {
                continue
            }

            var e = self._entry(
                self._witnesses[i].iface,
                PlanNeed::Fwd,
                PlanTier::FwdDecls,
            )

            e.witness = unsafe &self._witnesses[i]
            e.own     = true
            self.entries.push_back(e)
        }

        // Tier 1: definitions, toposorted on Complete edges.
        var t1: cxx::std::vector<PlanEntry>
        for var i: usize = 0; i < self._set.size(); ++i {
            var unsafe *d = self._set[i]
            if !self._is_type_decl(d) {
                continue
            }

            if self._need[i] != PlanNeed::Complete {
                continue
            }

            t1.push_back(
                self._entry(d, PlanNeed::Complete, PlanTier::Definitions),
            )
        }

        // Every scope a preamble touches is defined (its members' out-of-line
        // definitions and every call need the class); a header defines the ones
        // its roots reach and only declares the rest.
        for var i: usize = 0; i < self._scopes.size(); ++i {
            if self._mode != PlanMode::Preamble && !self._scopes[i].reachable {
                continue
            }

            var e = self._entry(
                self._scopes[i].anchor,
                PlanNeed::Complete,
                PlanTier::Definitions,
            )

            e.scope = unsafe &self._scopes[i]
            t1.push_back(e)
        }

        for var i: usize = 0; i < self._witnesses.size(); ++i {
            var e = self._entry(
                self._witnesses[i].iface,
                PlanNeed::Complete,
                PlanTier::Definitions,
            )

            e.witness = unsafe &self._witnesses[i]
            e.own     = true
            t1.push_back(e)
        }

        // The early items (Compiler/Spec/Eval.md#value-nodes), each where its edges put it: after the
        // records its definition needs complete, before the records whose
        // types evaluate it.
        for var i: usize = 0; i < self.early.size(); ++i {
            var e = self._entry(
                self.early[i],
                PlanNeed::Complete,
                PlanTier::Definitions,
            )

            e.eval_item = self.early[i]
            t1.push_back(e)
        }

        self._sort(&t1)
        self._toposort(&t1)
        for var i: usize = 0; i < t1.size(); ++i {
            self.entries.push_back(t1[i])
        }

        // Tier 2: functions and globals. Extension members are declared by
        // their scope's definition and never listed here.
        var t2: cxx::std::vector<PlanEntry>
        for var i: usize = 0; i < self._set.size(); ++i {
            var unsafe *d = self._set[i]
            if d->kind != DeclKind::FunctionDecl && d->kind != DeclKind::VariableDecl {
                continue
            }

            t2.push_back(self._entry(d, PlanNeed::Fwd, PlanTier::Functions))
        }

        self._sort(&t2)
        self._specs_after_primary(&t2)
        for var i: usize = 0; i < t2.size(); ++i {
            self.entries.push_back(t2[i])
        }

        // Tier 3: instantiations. Home = the entry's home_fid; in header mode
        // only instances homed inside this file's own root are listed, as
        // `extern`, because the header ships with that root's objects.
        var t3: cxx::std::vector<PlanEntry>
        for var i: usize = 0; i < self._insts.size(); ++i {
            var unsafe *ie   = self._insts[i]
            var unsafe *prim = Speller::rep(ie->primary)
            // An explicit specialization is the instance's definition; an
            // explicit instantiation after it would have no effect
            // ([temp.explicit]/4) and draws clang's warning.
            if isa<Declarations::FunctionDecl>(prim)
                && Speller::fn_spec_for(
                    prim,
                    unsafe &ie->args,
                    self._cg->instances,
                ) != &null {
                continue
            }

            var e = self._entry(
                prim,
                PlanNeed::Complete,
                PlanTier::Instantiations,
            )

            // The codegen home (assign_homes), graph-independent; home_fid
            // when the driver set none.
            var hf = EmitPlan::home_of(ie)
            e.inst    = ie
            e.is_home = hf == self._home
            if self._mode == PlanMode::Header {
                if !self._same_root(hf, self._home) {
                    continue
                }

                e.is_home = false
            }

            // Tie-break on the instance's home, so two TUs list one
            // instance in the same relative order.
            e.fid = hf
            e.own = e.fid == self._home // own was computed from the primary's fid, before the override.
            t3.push_back(e)
        }

        self._sort(&t3)
        // Two Kairo instances can be one C++ entity: `usize` is its own type to
        // Kairo, but on Linux size_t IS `unsigned long`, so `Box<usize>` beside
        // `Box<u64>` (or `Panic<i32, usize>` beside `Panic<i32, u64>`) would be
        // `template struct Box<unsigned long>;` twice, clang's "duplicate
        // explicit instantiation". Key each instance by its arguments
        // spelled with usize / isize folded to what the target says they are
        // (Speller::size_fold), and list one per key: the home
        // one when either is, since a definition after an `extern template`
        // is fine and the reverse is not.
        var keys   = cxx::std::vector<string>()
        var folded = cxx::std::vector<u8>()
        var drop   = cxx::std::vector<u8>()
        for var i: usize = 0; i < t3.size(); ++i {
            // An instance over a value C++ computes writes no line at all
            // (InterfaceEmitter::_instantiation); nothing to collide.
            var computed = false
            var *ia      = &t3[i].inst->args
            for var k: usize = 0; k < ia->size(); ++k {
                var unsafe *v = dyn_cast<TypeExpr>((*ia)[k])
                if v != &null && v->is_value && !v->is_exact() {
                    computed = true
                    break
                }
            }

            if computed {
                keys.push_back("")
                folded.push_back(0)
                drop.push_back(0)
                continue
            }

            self._spell.fold_sizes   = true
            self._spell.sizes_folded = 0
            keys.push_back(self._spell.args_str(t3[i].inst->args))
            folded.push_back((self._spell.sizes_folded > 0) as u8)
            self._spell.fold_sizes = false
            drop.push_back(0)
        }

        // A pair with a folded side is checked as above. Two instances one
        // C++ entity with no folded side (`*T` and
        // `unsafe *T` spell alike) share a home (assign_homes), so both are
        // home or neither: two homes write the instantiation twice
        // (CL001E), so the second goes; two `extern template`s are legal and
        // stay as they were.
        for var i: usize = 0; i < t3.size(); ++i {
            if drop[i] != 0 {
                continue
            }

            if folded[i] == 0 && !t3[i].is_home {
                continue
            }

            for var j: usize = 0; j < t3.size(); ++j {
                if j == i || drop[j] != 0 || t3[j].decl != t3[i].decl || keys[j] != keys[i] {
                    continue
                }

                if folded[i] == 0 && folded[j] == 0 && !t3[j].is_home {
                    continue
                }

                var keep_i = t3[i].is_home && !t3[j].is_home
                    || t3[i].is_home == t3[j].is_home && i < j
                if keep_i {
                    drop[j] = 1
                    continue
                }

                drop[i] = 1
                break
            }
        }

        for var i: usize = 0; i < t3.size(); ++i {
            if drop[i] == 0 {
                self.entries.push_back(t3[i])
            }
        }
    }

    fn _same_root(self, a: u32, b: u32) -> bool {
        var unsafe *sm  = self._cg->ctx->sm
        var unsafe *res = self._cg->ctx->resolver
        if sm == &null || res == &null {
            return a == b
        }

        return res->root_for_dir(sm->get_file_dir(a)) == res->root_for_dir(
            sm->get_file_dir(b),
        )
    }

    fn _same_ns_vec(self,
                    const a: cxx::std::vector<string>,
                    const b: cxx::std::vector<string>) -> bool {
        if a.size() != b.size() {
            return false
        }

        for var i: usize = 0; i < a.size(); ++i {
            if (a)[i] != (b)[i] {
                return false
            }
        }

        return true
    }

    fn _entry(self, d: unsafe *Decl, need: PlanNeed, tier: PlanTier) -> PlanEntry {
        var e = PlanEntry()
        e.decl = d
        e.need = need
        e.tier = tier
        e.fid  = Speller::fid_of(d)
        e.off  = self._off_of(d)
        e.own  = e.fid == self._home
        // A tuple record (TupleRecords) is minted from no file and sits in no
        // module's header: it is OWN everywhere, so a header defines it (under
        // InterfaceEmitter's guard) instead of including the builtin root's,
        // which never declares it.
        var unsafe *ts = dyn_cast<Declarations::StructDecl>(d)
        if ts != &null && ts->tuple_arity > 0 {
            e.own = true
        }

        return e
    }

    /// (file rank, offset) ascending. Insertion sort: tens of entries, stable.
    fn _sort(self, @inout v: cxx::std::vector<PlanEntry>) {
        for var i: usize = 1; i < v.size(); ++i {
            var j = i
            while j > 0 {
                var *a   = &(v)[j - 1]
                var *b   = &(v)[j]
                var swap = false
                // By the file's rank (set_file_ranks), not its fid: the
                // order is then the same in every graph that holds the TU.
                var ra = self._rank_of(a->fid)
                var rb = self._rank_of(b->fid)
                if ra > rb {
                    swap = true
                } else if ra == rb && a->off > b->off {
                    swap = true
                }

                if !swap {
                    break
                }

                var tmp = (v)[j - 1]
                (v)[j - 1] = (v)[j]
                (v)[j]     = tmp
                j -= 1
            }
        }
    }

    /// Stable topological sort on Complete edges. Nothing takeable means a
    /// by-value cycle sema should have rejected (TypeCycleCheck): assert.
    ///
    /// Each round takes the LOWEST-index entry none of whose untaken entries it
    /// needs. The edges are asked once each (n^2 _entry_needs calls, each a walk
    /// of a record's fields and methods) into a matrix, and a per-entry count of
    /// untaken needs replaces the rescan: asking them per round was n^3 calls,
    /// the single biggest cost of codegen's serial pre-pass on a large graph.
    /// Same picks in the same order as the rescanning form.
    fn _toposort(self, @inout v: cxx::std::vector<PlanEntry>) {
        var n = v.size()
        if n < 2 {
            return
        }

        var out:   cxx::std::vector<PlanEntry>
        var taken: cxx::std::vector<u8>
        // needs[i * n + j]: entry i must follow entry j. pending[i]: how many
        // untaken j entry i still needs.
        var needs:   cxx::std::vector<u8>
        var pending: cxx::std::vector<usize>
        needs.resize(n * n, 0 as u8)
        for var i: usize = 0; i < n; ++i {
            taken.push_back(0)
            var c: usize = 0
            for var j: usize = 0; j < n; ++j {
                if j == i {
                    continue
                }

                if self._entry_needs(unsafe &(v)[i], unsafe &(v)[j]) {
                    needs[i * n + j] = (1)
                    c += 1
                }
            }

            pending.push_back(c)
        }

        for var round: usize = 0; round < n; ++round {
            var picked = usize::MAX
            for var i: usize = 0; i < n; ++i {
                if taken[i] == 0 && pending[i] == 0 {
                    picked = i
                    break
                }
            }

            if picked == usize::MAX {
                // A cycle through an early item (Compiler/Spec/Eval.md#value-nodes) is EvalUsageChecking's
                // to report; one of records alone, TypeCycleCheck's.
                for var i: usize = 0; i < n; ++i {
                    if taken[i] == 0 && (v)[i].eval_item != &null {
                        self._ice(
                            (v)[i].decl->range,
                            "EmitPlan: no order defines the eval items a declaration's type computes from ahead of it; EvalUsageChecking::_check_order should have reported the cycle",
                        )
                    }
                }
            }

            eval if defined!(DEBUG) {
                if !(picked != usize::MAX) {
                    kairo::std::ice_fail(
                        r"EmitPlan: Complete-edge cycle in tier 1; TypeCycleCheck should have rejected this in sema",
                    )
                }
            }

            taken[picked] = 1
            out.push_back((v)[picked])
            for var i: usize = 0; i < n; ++i {
                if taken[i] == 0 && needs[i * n + picked] != (0 as u8) {
                    pending[i] -= 1
                }
            }
        }

        for var i: usize = 0; i < n; ++i {
            (v)[i] = out[i]
        }
    }

    /// True when entry `who` must follow entry `dep`. A scope follows its
    /// deps; nothing waits on a scope (a friend line needs only tier 0).
    fn _entry_needs(self, who: unsafe *PlanEntry, dep: unsafe *PlanEntry) -> bool {
        if who->eval_item != &null || dep->eval_item != &null {
            if who->witness != &null
                || who->scope != &null
                || dep->witness != &null
                || dep->scope != &null {
                return false
            }

            return self._eo_has(who->decl, dep->decl)
        }

        if who->witness != &null {
            var unsafe *w = who->witness
            if dep->witness != &null {
                // A std::hash adapter's operator calls its row's specialization.
                if w->std_hash && !dep->witness->std_hash && dep->witness->row == w->row {
                    return true
                }

                if dep->witness->row != &null {
                    return self._row_needs_row(w, dep->witness)
                }

                for var i: usize = 0; i < w->after.size(); ++i {
                    if w->after[i] == dep->witness->iface {
                        return true
                    }
                }

                return false
            }

            if dep->scope != &null {
                for var i: usize = 0; i < w->scopes.size(); ++i {
                    var unsafe *sp = unsafe &self._scopes[w->scopes[i]]
                    if sp == dep->scope {
                        return true
                    }
                }

                return false
            }

            for var i: usize = 0; i < w->deps.size(); ++i {
                if w->deps[i] == dep->decl {
                    return true
                }
            }

            return false
        }

        if dep->witness != &null {
            return false
        }

        if dep->scope != &null {
            return false
        }

        if who->scope != &null {
            for var i: usize = 0; i < who->scope->deps.size(); ++i {
                if who->scope->deps[i] == dep->decl {
                    return true
                }
            }

            return false
        }

        // A specialization's definition follows its primary's: a partial
        // whose pattern instantiates the primary (`Store<Store<P>*>`) needs it
        // defined, and keeping the pair in order costs nothing otherwise.
        if Speller::is_record_spec(who->decl)
            && Speller::rep(DeclFacts::decl_instantiated_from(who->decl)) == dep->decl {
            return true
        }

        return self._needs_complete(who->decl, dep->decl)
    }

    /// True when specialization `who` must follow specialization `dep`. A
    /// full specialization's inline forwarders call an extension's members
    /// at the conformer's arguments, and C++ checks that call's bounds where
    /// the forwarder is written: `Iterator_witness<Skip<Gen<i32>>>::next`
    /// needs `Gen<i32>` to meet Iterator there, so the specialization that
    /// makes it conform comes first. That one is the full specialization of
    /// a type among the conformer's arguments, or a partial one over such a
    /// type's template. A generic row waits on no row and an argument is a
    /// smaller type than the record naming it, so the edges close no cycle.
    fn _row_needs_row(self, who: unsafe *WitnessPiece, dep: unsafe *WitnessPiece) -> bool {
        if who->row == &null || who->std_hash || dep->std_hash {
            return false
        }

        if EmitWitness::is_generic_row(who->row) {
            return false
        }

        return self._type_names_arg(
            who->row->conformer,
            dep->row->conformer,
            EmitWitness::is_generic_row(dep->row),
            0,
        )
    }

    /// True when `part` is a generic argument of record `whole`, at any
    /// depth; with `by_template`, when an argument is an instance of
    /// `part`'s template (`Gen<i32>` for a generic row's `Gen<T>`).
    fn _type_names_arg(self,
                       whole:       unsafe *Type,
                       part:        unsafe *Type,
                       by_template: bool,
                       depth:       u32) -> bool {
        if whole == &null || part == &null || depth > 32 {
            return false
        }

        var unsafe *r = dyn_cast<RecordType>(canon_unqual(whole))
        if r == &null {
            return false
        }

        var unsafe *pr = dyn_cast<RecordType>(canon_unqual(part))
        for var i: usize = 0; i < r->args.size(); ++i {
            var unsafe *a = r->args[i]
            if a == &null {
                continue
            }

            var unsafe *c = canon_unqual(a)
            if c == part {
                return true
            }

            var unsafe *ar = dyn_cast<RecordType>(c)
            if by_template
                && ar != &null
                && pr != &null
                && self._template_of(ar->decl) == self._template_of(pr->decl) {
                return true
            }

            if self._type_names_arg(a, part, by_template, depth + 1) {
                return true
            }
        }

        return false
    }

    /// The template a record decl is an instance of, or the decl itself.
    fn _template_of(self, d: unsafe *Decl) -> unsafe *Decl {
        return Speller::rep(DeclFacts::decl_pattern(Speller::rep(d)))
    }

    /// Tier 0 is (fid, offset) order, which puts a specialization written
    /// above its primary, or in a file sorting before the primary's, ahead of
    /// the primary's declaration: C++ rejects a specialization of an
    /// undeclared template. Each such entry moves to just after its primary;
    /// everything else keeps its place.
    fn _specs_after_primary(self, @inout v: cxx::std::vector<PlanEntry>) {
        var moved        = true
        var guard: usize = 0
        while moved && guard < v.size() + 1 {
            moved = false
            guard += 1
            for var i: usize = 0; i < v.size(); ++i {
                var unsafe *d = (v)[i].decl
                if (v)[i].scope != &null
                    || (v)[i].witness != &null
                    || !Speller::is_record_spec(d) && !Speller::is_fn_spec(d) {
                    continue
                }

                var unsafe *prim = Speller::rep(
                    DeclFacts::decl_instantiated_from(d),
                )

                var at = usize::MAX
                for var j: usize = i + 1; j < v.size(); ++j {
                    if (v)[j].scope == &null && (v)[j].witness == &null && (v)[j].decl == prim {
                        at = j
                        break
                    }
                }

                if at == usize::MAX {
                    continue
                }

                var e = (v)[i]
                for var j: usize = i; j < at; ++j {
                    (v)[j] = (v)[j + 1]
                }

                (v)[at] = e
                moved   = true
                break
            }
        }
    }

    /// True when `who`'s definition requires `dep`'s definition first. An
    /// ADT's definition is its layout record's (adt_record); LayoutSpine sees
    /// through its anonymous union and payload structs.
    fn _needs_complete(self, who: unsafe *Decl, dep: unsafe *Decl) -> bool {
        if who == &null || dep == &null {
            return false
        }

        // Asked for every pair of tier-1 entries: the answer for one
        // `who` is two sets built by one walk (_need_row), so a pair is a lookup.
        var *r = &self._need_rows[self._need_row(who)]
        if r->direct.contains(dep as usize as u64) {
            return true
        }

        return r->layout.contains(self.layout_decl(dep) as usize as u64)
    }

    /// What `who`'s definition needs complete before it, for every dep at once:
    /// - direct: a value parameter of class type (`<eval C: Config>`, Compiler/Spec/Eval.md
    ///   7e) -- C++ needs the class complete wherever the template is declared
    ///   -- and every class whose value-parameter template `who` names at all,
    ///   through a pointer too (its forward declaration follows the class),
    ///   or whose nested type it names.
    /// - layout: what `who` holds by value (LayoutSpine): its bases, fields
    ///   and C++ default arguments, an ADT's payloads.
    /// A record nested in `who` is defined INSIDE its body (`struct Entry` in
    /// a class), so what it needs orders `who` exactly as `who`'s own fields
    /// do; an Entry reached only through a template argument (`vector<Entry>`)
    /// or not at all would otherwise leave the outer record ahead of a field
    /// type it needs complete. Its row is folded in.
    fn _need_row(self, who: unsafe *Decl) -> usize {
        var key = (who as usize as u64)
        var hit = self._need_memo.find(key)
        if hit != self._need_memo.end() {
            return hit->second as usize
        }

        var row = NeedRow()
        var gps = DeclFacts::decl_generic_params(who)
        for var i: usize = 0; i < gps.size(); ++i {
            var unsafe *gp = gps[i]
            if gp == &null
                || !gp->is_const_param
                || gp->value_type == &null
                || gp->value_type->canonical == &null {
                continue
            }

            var unsafe *c = canon_unqual(gp->value_type->canonical)
            if !isa<RecordType>(c) {
                continue
            }

            row.direct.insert(
                Speller::rep(cast<RecordType>(c)->decl) as usize as u64,
            )
        }

        {
            var vr  = self._vp_row(who)
            var *vn = &self._vp_rows[vr]
            for var it = vn->vp.begin(); it != vn->vp.end(); ++it {
                row.direct.insert(*it)
            }

            for var it = vn->nest.begin(); it != vn->nest.end(); ++it {
                row.direct.insert(*it)
            }
        }

        var unsafe *rec = self.adt_record(who)
        var unsafe *ndc = Speller::dc_of(rec)
        if ndc != &null {
            for var i: usize = 0; i < ndc->dc_decls.size(); ++i {
                var unsafe *nd = *ndc->dc_decls.get(i)
                if nd == &null || !self._is_type_decl(nd) {
                    continue
                }

                if isa<Declarations::UnionDecl>(nd)
                    && cast<Declarations::UnionDecl>(nd)->is_anonymous {
                    continue
                }

                var unsafe *nr = Speller::rep(nd)
                if nr == who {
                    continue
                }

                var ni  = self._need_row(nr)   // may grow _need_rows: index, not pointer.
                var *nn = &self._need_rows[ni]
                for var it = nn->direct.begin(); it != nn->direct.end(); ++it {
                    row.direct.insert(*it)
                }

                for var it = nn->layout.begin(); it != nn->layout.end(); ++it {
                    row.layout.insert(*it)
                }
            }
        }

        var probe = LayoutSpine(&self, who)
        probe.collect = unsafe &row.layout
        match rec->kind {
            case DeclKind::ClassDecl {
                var unsafe *n = cast<Declarations::ClassDecl>(rec)
                probe.bases(&n->derives_list)
                probe.fields(unsafe &n->fields)
                probe.defaults(&n->methods)
            } case DeclKind::StructDecl {
                var unsafe *sn = cast<Declarations::StructDecl>(rec)
                probe.fields(unsafe &sn->fields)
                probe.defaults(&sn->methods)
            } case DeclKind::UnionDecl {
                probe.fields(unsafe &cast<Declarations::UnionDecl>(rec)->fields)
            } case DeclKind::EnumDecl {
                var unsafe *n = cast<Declarations::EnumDecl>(rec)
                for var i: usize = 0; i < n->variants.size(); ++i {
                    var unsafe *vr = *n->variants.get(i)
                    if vr != &null {
                        probe.fields(unsafe &vr->payload)
                    }
                }
            } default { }
        }

        var at = self._need_rows.size()
        self._need_rows.push_back(row)
        self._need_memo.try_emplace(key, at as u64)
        return at
    }
}
