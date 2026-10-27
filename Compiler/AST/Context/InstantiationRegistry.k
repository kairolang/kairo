/// --- The Kairo Project ------------- AST/Context/InstantiationRegistry.k --- ///
///
///   \brief THE instantiation registry: (primary, canonical args) -> the decl
///          that IS that instance. One per build, beside the canonical type
///          store, for the same reason: RecordType::decl is a pointer identity
///          and pointers only compare inside one domain.
///
///   \detail
///     RESOLUTION.md hard invariant #12. A CONCRETE `Foo<i32>` has exactly one
///     decl behind it for the whole build:
///
///       - an EXPLICIT full specialization the user wrote
///         (`class <> Foo<i32> { ... }`), registered by T once its spec_args
///         are canonical; or
///       - an IMPLICIT instantiation node, created HERE on first mention: the
///         primary's DeclKind, `spec_kind = Instantiated`,
///         `instantiated_from = primary`, empty body, own (empty) table. M2
///         fills it. The partial specialization its args select, if any, is
///         chosen here at mint (_select) and kept on the entry (`pattern`,
///         `pattern_args`); `instantiated_from` stays the primary. Until M2
///         name lookup walks that body: the partial, else the primary
///         (MemberLookup::_walk_record, SemaContext::body_of).
///
///     Dependent uses (`Foo<T>`, `Self` in a generic body) never come here:
///     their RecordType::decl is the primary -- a pattern -- and that is what
///     "deferred" means (#5). Partial specializations never back a RecordType
///     at all; they are patterns, kept per primary for the selection at mint.
///
///     The node is created at NAMING time, not at instantiation time, for the
///     same reason Clang does it: the type needs a decl to point at the moment
///     it exists, and retargeting RecordType::decl later would break the
///     pointer identity everything after T keys on.
///
///   \par Arena / threading
///     Own arena: an implicit node first named by fid A is referenced by every
///     importer of A and must outlive A's ast_alloc reset. Mutex-guarded: T is
///     parallel across independent import subtrees and two subtrees WILL name
///     `Vec<i32>` at once.
///
///   Layer: AST/Context. Imports AST only, never Sema (cycle rule).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/DenseMap.h";
ffi "c++" import "llvm/Support/Allocator.h";
import Memory::ArenaAllocator::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::CanonicalTypes::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::DeclFacts::*;
import AST::Kind::DeclKind::*;
import AST::Kind::TypeKind::*;
import Location::SourceRange::*;

/// \class ConformanceRow
/// \brief `(conformer, interface)` and, for each of the interface's OWN
///        requirements, the decl that implements it (RESOLUTION.md §2b, "The
///        conformance table"). Sema records the decls and nothing else;
///        EmitWitness decides from their spellings whether the row needs a
///        specialization (CODEGEN.md §7b.4).
///
///   Kept here, beside the instances, for the reason the registry is one
///   per build: a row TU A found is the row every TU holding the same
///   instance needs, and it is keyed on canonical pointers, which compare
///   only inside one domain.
class ConformanceRow {
    pub var conformer: *Type = &null;    ///< canonical, unqualified: `Metric`, `i32`.
    pub var iface:     *Type = &null;    ///< the canonical interface instance (a RecordType).
    pub var iface_decl: *Decl = &null;   ///< its InterfaceDecl's representative.
    /// The `impl` that declared it (`class X impl I`, `extend X impl I`), or
    /// null for a STRUCTURAL row found at a use.
    pub var declared:  *Decl = &null;
    /// Parallel to `iface_decl`'s methods: the implementing decl, or null
    /// where the conformer has none (then `ok` is false).
    pub var witnesses: vec::<*Decl>;
    /// Parallel to `witnesses`: the requirement each implements (the
    /// interface's composed list), for the checks that hold a witness to its
    /// requirement (PanicEffectChecking: its panic set within the
    /// requirement's).
    pub var reqs:      vec::<*Decl>;
    /// A witness that is a GENERIC extension's member is called with the
    /// extension's arguments, as the conformer binds them (`extend <E>
    /// Wrap<E>` met by `Wrap<i32>`: E := i32): flat, `ext_arg_count[i]` of
    /// them per witness, in witness order, zero for any other.
    pub var ext_args:      vec::<*Type>;
    pub var ext_arg_count: vec::<usize>;
    /// Parallel to `witnesses`: the interface instance requirement i came
    /// through, at THIS row's arguments (`interface <T> F derives
    /// Container<T>` met as `F<i32>`: Container<i32>). The composed list
    /// keeps a source in the composing interface's own parameters, which
    /// codegen cannot substitute; a specialization spells the requirement
    /// through this instance instead.
    pub var sources:   vec::<*Type>;
    /// A concrete row that a GENERIC declared row (`extend <E> Wrap<E> impl
    /// I`, conformer over its own parameters) covers -- same witnesses, its
    /// conformer and interface at this row's arguments -- or null. EmitPlan
    /// admits that row's partial specialization in place of a full one.
    pub var covered_by: *ConformanceRow = &null;
    pub var ok:        bool  = false;
    fn ConformanceRow(self) { }

    /// Witness \p i's extension arguments, appended to \p out.
    fn ext_args_of(self, i: usize, out: *vec::<*Type>) {
        var at: usize = 0;
        for var k: usize = 0; (k < i) && (k < self.ext_arg_count.size()); ++k { at += self.ext_arg_count[k]; }
        if i >= self.ext_arg_count.size() { return; }
        for var k: usize = 0; k < self.ext_arg_count[i]; ++k { out->push_back(self.ext_args[at + k]); }
    }
}

/// \class InstanceEntry
/// \brief One concrete instance of a generic type. Both halves of "an
///        instantiation" hang here: the CHECKING-side decl (what RecordType
///        points at, what M2 fills) and the EMIT-side fact (the explicit
///        instantiation directive EmitPlan writes, once, in `home_fid`).
class InstanceEntry {
    pub var primary:           *Decl = &null;   ///< the primary's representative.
    pub var args:              vec::<*Type>;    ///< canonical, parameter order, packs flat.
    pub var decl:              *Decl = &null;   ///< THE instance: explicit spec (representative) or implicit node.
    pub var is_explicit:       bool  = false;   ///< `decl` is user-written.
    pub var home_fid:          u32   = 0;       ///< TU that first named it; EmitPlan's home.
    pub var emitted:           bool  = false;   ///< explicit instantiation directive written.
    /// One per `P impl I` bound of the primary, in bound order, then the
    /// rows of each bound interface's `derives` closure: every witness
    /// specialization this instance's body can name (CODEGEN.md §7b.6).
    /// Written once, by ConformanceChecking at the instantiation site
    /// (set_rows); `rows_done` says it ran, so an instance with no bound
    /// and one not yet checked are told apart.
    pub var rows:              vec::<*ConformanceRow>;
    pub var rows_done:         bool  = false;
    /// The partial specialization whose BODY an implicit instance takes, or
    /// null for the primary's. `decl`'s `instantiated_from` stays the
    /// primary either way: every reader of that link asks "which template
    /// is this an instance of" (deduction compares it, is_lang and the
    /// tuple tests key on it), and only the table walks want the body --
    /// they ask Sema's body_of, which reads this.
    pub var pattern:           *Decl = &null;
    /// Parallel to `pattern`'s generic params: each one's binding for
    /// `args`. `Store<*i32>` against `<P> Store<*P>` is [i32], where `args`
    /// is [*i32]: args are in the PRIMARY's parameter space, so nothing
    /// positional may bind a partial's parameters from them.
    pub var pattern_args:      vec::<*Type>;
    /// Two partials both match and neither is more specialized: `pattern`
    /// stays null and these name the first two for Sema's diagnostic,
    /// reported once (`ambiguity_reported`) at a naming site.
    pub var ambiguous_a:       *Decl = &null;
    pub var ambiguous_b:       *Decl = &null;
    pub var ambiguity_reported: bool = false;
    /// A generic ADT's instance: the layout Sema's niche engine predicts C++
    /// picks (0 unknown, 1 tagged, 2 niche-filled) and its size in bytes (0
    /// unknown). One writer, EnumLayoutQuery::sweep; InterfaceEmitter pins
    /// both with static_asserts beside the instantiation.
    pub var adt_shape:         u8  = 0;
    pub var adt_size:          u64 = 0;
    /// An ADT instance whose pack elements are tagged by type id (the Panic
    /// lang item, PANIC.md §1.3): each element's id, and the 64-bit hash of
    /// its C++ spelling that keys its `__kairo_tid` specialization's guard,
    /// in element order. Empty for every other instance. One writer,
    /// EnumLayoutQuery::sweep; InterfaceEmitter writes the specializations.
    pub var type_ids:          vec::<u32>;
    pub var type_keys:         vec::<u64>;
    /// Each element's Kairo name (`ConfigError`, `i64`), the one the C++
    /// view's `what()` prints (PANIC.md §4.6): its specialization carries it.
    pub var type_names:        vec::<string>;
    /// Where its payloads start (the union's alignment), 0 unknown.
    pub var payload_offset:    u64 = 0;
    /// Where such an instance's set was first formed, and in which TU: the
    /// one place its register-cliff remark (PANIC.md §1.1a) is reported.
    /// One writer, the first former (PanicSets::note_formed).
    pub var formed_at:         SourceRange = SourceRange::invalid();
    pub var formed_fid:        u32 = u32(-1);
    fn InstanceEntry(self) { }
}

class InstantiationRegistry {
    /// The same PackSetOrder the CanonicalTypeStore holds (one set order for
    /// a type's identity and its entry). Set once by the driver.
    pub var pack_order: *PackSetOrder = &null;
    priv var _arena: ArenaAllocator = ArenaAllocator(256 * 1024);
    priv var _mu:    std::SharedMutex;
    /// bucket hash -> entries. Every hit is confirmed by a structural compare.
    /// Keys are _hash's, which keeps clear of DenseMap's reserved values.
    /// Its order means nothing -- hashes of pointers, filled from parallel T
    /// -- and collect() says so: ordering is the output boundary's job.
    priv var _table: llvm::DenseMap::<u64, vec::<*InstanceEntry>>;
    /// primary -> its partial specializations, in registration order. The
    /// lists live in _partials_arena: partials_of() hands one out, and a
    /// DenseMap rehash would move it.
    priv var _partials: llvm::DenseMap::<u64, *vec::<*Decl>>;
    priv var _partials_arena: llvm::SpecificBumpPtrAllocator::<vec::<*Decl>>;
    /// implicit node -> the entry it was minted for. An implicit node's own
    /// `spec_args` stay EMPTY (they are the user-written `<...>` of an
    /// explicit spec, and every printer reads them that way), so this is how
    /// a holder of the node alone gets back its args.
    priv var _by_node: llvm::DenseMap::<u64, *InstanceEntry>;
    /// The conformance table: hash of (conformer, interface) -> rows. Same
    /// arena and lock as the instances; rows are immutable once added.
    priv var _rows: llvm::DenseMap::<u64, vec::<*ConformanceRow>>;
    /// DECLARED rows (`class X impl I`, `extend X impl I`), keyed by the
    /// declaring decl's address: the rows EmitPlan admits where that decl is
    /// emitted, with no Kairo instance to reach them (CODEGEN.md §7b.6). A
    /// row here is also in `_rows` -- the same identity a use finds -- since
    /// `ConformanceRow::declared` is first-writer and a use may build the
    /// row before the declaration is checked.
    priv var _declared: llvm::DenseMap::<u64, vec::<*ConformanceRow>>;

    fn InstantiationRegistry(self) {
        self._table.reserve(128);
    }

    // === Lookup / create ======================================================

    /// The entry for (primary, args), or null if none was ever named.
    fn find(self, primary: *Decl, args_in: *vec::<*Type>) -> *InstanceEntry {
        var dd = vec::<*Type>();
        var args = self._set_args(primary, args_in, &dd);
        var rlock = std::SharedLock(self._mu);
        return self._probe(self._hash(primary, args), primary, args);
    }

    /// The entry an IMPLICIT node was minted for, or null (an explicit spec,
    /// or not a registry node at all).
    fn entry_of(self, node: *Decl) -> *InstanceEntry {
        var rlock = std::SharedLock(self._mu);
        var it = self._by_node.find(reinterpret_cast::<u64>(node));
        if it == self._by_node.end() { return &null; }
        return it->second;
    }

    /// Get-or-create. On create, mints the implicit instantiation node.
    /// \p ctx is the PRIMARY's context (NameLookup::ctx_of(primary)) -- the
    /// node's names are the primary's names, interned in the primary's TU.
    /// PRE: every arg canonical and non-dependent. Callers that cannot
    /// promise that (T on a dependent use) must not call this.
    fn instance_for(self, primary: *Decl, args_in: *vec::<*Type>, fid: u32,
                    ctx: *ASTContext) -> *InstanceEntry {
        if (primary == &null) || (args_in == &null) || (ctx == &null) { return &null; }
        var dd = vec::<*Type>();
        var args = self._set_args(primary, args_in, &dd);
        var h = self._hash(primary, args);

        var lock = std::LockGuard(self._mu);
        var hit = self._probe(h, primary, args);
        if hit != &null { return hit; }

        var node = self._new_instance(primary, ctx);
        if node == &null { return &null; }
        var e = self._new_entry(primary, args, node, false, fid);
        self._table[h].push_back(e);
        self._by_node[reinterpret_cast::<u64>(node)] = e;
        self._select_into(e);
        return e;
    }

    /// Record a user-written EXPLICIT full specialization. Returns the entry
    /// for its args, which the caller inspects:
    ///   entry->decl == spec          fresh; nothing else to do.
    ///   entry->is_explicit, != spec  a second explicit spec for the same
    ///                                args: a redecl chain (fwd + def) or a
    ///                                redefinition -- T links and judges.
    ///   !entry->is_explicit          an implicit node already exists: some
    ///                                use named these args before the spec
    ///                                was seen. T diagnoses.
    fn register_explicit(self, primary: *Decl, args_in: *vec::<*Type>, spec: *Decl,
                         fid: u32) -> *InstanceEntry {
        if (primary == &null) || (args_in == &null) || (spec == &null) { return &null; }
        var dd = vec::<*Type>();
        var args = self._set_args(primary, args_in, &dd);
        var h = self._hash(primary, args);

        var lock = std::LockGuard(self._mu);
        var hit = self._probe(h, primary, args);
        if hit != &null { return hit; }

        var e = self._new_entry(primary, args, spec, true, fid);
        self._table[h].push_back(e);
        return e;
    }

    /// After T links a fwd-declared spec to its definition the representative
    /// changes; the entry must point at it BEFORE any RecordType is minted.
    fn retarget(self, e: *InstanceEntry, rep: *Decl) {
        if (e == &null) || (rep == &null) { return; }
        var lock = std::LockGuard(self._mu);
        e->decl = rep;
    }

    // === Partial specializations ===============================================

    /// \p spec is a REPRESENTATIVE: its parameters' GenericParamType owner
    /// is that decl, and matching binds by owner identity. Entries already
    /// minted for \p primary are re-selected: T registers a TU's specs before
    /// it resolves anything else in it, so a re-selection here only ever
    /// moves an instance no body has been typed against yet.
    fn register_partial(self, primary: *Decl, spec: *Decl) {
        if (primary == &null) || (spec == &null) { return; }
        var lock = std::LockGuard(self._mu);
        var slot = &(self._partials[reinterpret_cast::<u64>(primary)]);
        if (*slot) == &null {
            var v = self._partials_arena.Allocate(1);
            libcxx::construct_at(v);
            (*slot) = v;
        }
        (*slot)->push_back(spec);
        for var it = self._table.begin(); it != self._table.end(); ++it {
            for var i: usize = 0; i < it->second.size(); ++i {
                var e = it->second[i];
                if (e->primary == primary) && (!e->is_explicit) { self._select_into(e); }
            }
        }
    }

    fn partials_of(self, primary: *Decl) -> *vec::<*Decl> {
        var rlock = std::SharedLock(self._mu);
        var it = self._partials.find(reinterpret_cast::<u64>(primary));
        if it == self._partials.end() { return &null; }
        return it->second;
    }

    /// Every user-written specialization of \p primary, partial and
    /// explicit, appended to \p out: partials in registration order, then
    /// the explicit ones in NO defined order (hash order, as collect()).
    /// EmitPlan declares them wherever it declares the primary -- a TU that
    /// sees `Store` but not `Store<bool>` would instantiate the primary for
    /// it, an ODR violation no linker reports.
    fn specs_of(self, primary: *Decl, out: *vec::<*Decl>) {
        if (primary == &null) || (out == &null) { return; }
        var rlock = std::SharedLock(self._mu);
        var it = self._partials.find(reinterpret_cast::<u64>(primary));
        if it != self._partials.end() {
            for var i: usize = 0; i < it->second->size(); ++i { out->push_back((*(it->second))[i]); }
        }
        for var t = self._table.begin(); t != self._table.end(); ++t {
            for var i: usize = 0; i < t->second.size(); ++i {
                var e = t->second[i];
                if (e->primary == primary) && e->is_explicit { out->push_back(e->decl); }
            }
        }
    }

    /// The partial specialization of \p primary that \p args select, with
    /// its parameters' bindings in \p out_args; null for the primary (none
    /// matched, or an ambiguity -- the instance path reports that one).
    /// For a DEPENDENT use (`Store<*P>` as an extension's receiver, a
    /// partial's own Self), which has no entry to cache on: the args'
    /// parameters are opaque here, so `*P` selects `<Q> Store<*Q>` with
    /// Q := P, and a bare `T` selects nothing.
    fn select_partial(self, primary: *Decl, args: *vec::<*Type>, out_args: *vec::<*Type>) -> *Decl {
        if (primary == &null) || (args == &null) { return &null; }
        var rlock = std::SharedLock(self._mu);
        var a: *Decl = &null; var b: *Decl = &null;
        return self._select(primary, args, out_args, &a, &b);
    }

    // --- matching (under the lock; pure: reads canonical types only) ---------

    /// C++ partial-specialization selection, simplified: every partial whose
    /// pattern matches \p args, then the one strictly more specialized than
    /// each other match ([temp.class.order]); two with no order between them
    /// are ambiguous, reported through \p amb_a / \p amb_b. An IMPORTED
    /// primary's instances are clang's to fill, partial included
    /// (ForeignInstantiate), so it never selects here.
    priv fn _select(self, primary: *Decl, args: *vec::<*Type>, out_args: *vec::<*Type>,
                    amb_a: *(*Decl), amb_b: *(*Decl)) -> *Decl {
        if decl_is_imported(primary) { return &null; }
        var it = self._partials.find(reinterpret_cast::<u64>(primary));
        if it == self._partials.end() { return &null; }
        var ps = it->second;
        var hits  = vec::<*Decl>();
        for var i: usize = 0; i < ps->size(); ++i {
            var binds = vec::<*Type>();
            if self._matches((*ps)[i], args, &binds) { hits.push_back((*ps)[i]); }
        }
        if hits.size() == 0 { return &null; }
        var best: *Decl = &null;
        for var i: usize = 0; i < hits.size(); ++i {
            var wins = true;
            for var j: usize = 0; j < hits.size(); ++j {
                if i == j { continue; }
                if !self._more_specialized(hits[i], hits[j]) { wins = false; break; }
            }
            if wins { best = hits[i]; break; }
        }
        if best == &null {
            (*amb_a) = hits[0];
            (*amb_b) = hits[1];
            return &null;
        }
        if out_args != &null {
            out_args->clear();
            self._matches(best, args, out_args);
        }
        return best;
    }

    /// Under the write lock. Idempotent: a re-selection (register_partial)
    /// overwrites every field it owns.
    priv fn _select_into(self, e: *InstanceEntry) {
        e->pattern = &null;
        e->pattern_args.clear();
        e->ambiguous_a = &null;
        e->ambiguous_b = &null;
        var a: *Decl = &null; var b: *Decl = &null;
        e->pattern = self._select(e->primary, &(e->args), &(e->pattern_args), &a, &b);
        e->ambiguous_a = a;
        e->ambiguous_b = b;
    }

    /// \p spec's pattern against \p args; \p binds gets one type per
    /// generic param of \p spec, all of them bound or the match fails (a
    /// parameter the pattern never names cannot be deduced, which C++
    /// rejects at the declaration).
    priv fn _matches(self, spec: *Decl, args: *vec::<*Type>, binds: *vec::<*Type>) -> bool {
        var pat = decl_spec_args(spec);
        if pat.size() != args->size() { return false; }
        var gps = decl_generic_params(spec);
        binds->clear();
        for var i: usize = 0; i < gps.size(); ++i { binds->push_back(&null); }
        for var i: usize = 0; i < pat.size(); ++i {
            var p = pat[i];
            if (p == &null) || (p->canonical == &null) { return false; }
            if !self._match(p->canonical, (*args)[i], spec, binds) { return false; }
        }
        for var i: usize = 0; i < binds->size(); ++i { if (*binds)[i] == &null { return false; } }
        return true;
    }

    /// \p a is strictly more specialized than \p b: b's pattern matches a's
    /// (a's parameters standing as opaque types) and not the reverse.
    priv fn _more_specialized(self, a: *Decl, b: *Decl) -> bool {
        return self._covers(b, a) && (!self._covers(a, b));
    }

    priv fn _covers(self, general: *Decl, special: *Decl) -> bool {
        var sp = decl_spec_args(special);
        var args = vec::<*Type>();
        for var i: usize = 0; i < sp.size(); ++i {
            if (sp[i] == &null) || (sp[i]->canonical == &null) { return false; }
            args.push_back(sp[i]->canonical);
        }
        var binds = vec::<*Type>();
        return self._matches(general, &args, &binds);
    }

    /// Exact structural match, never a conversion: a partial is chosen by
    /// what the argument IS. Canonicals are hash-consed, so a pattern with
    /// no parameter in it matches by identity. A qualifier must match
    /// exactly -- `const P` against `const volatile i32` (C++ would bind
    /// P := volatile i32) needs the type store to build the remainder,
    /// which this layer does not hold, so it is a non-match, never a wrong
    /// binding. A pack parameter never matches: pack patterns are not
    /// selected yet.
    priv fn _match(self, p: *Type, a: *Type, spec: *Decl, binds: *vec::<*Type>) -> bool {
        if (p == &null) || (a == &null) { return false; }
        // Identity settles a concrete pattern only: a dependent one matched
        // against itself (a partial's own Self) must still bind its params.
        if (p == a) && (!p->is_dependent()) { return true; }
        if isa::<GenericParamType>(p) {
            var g = cast::<GenericParamType>(p);
            if (g->owner == spec) && (!g->is_pack) && (static_cast::<usize>(g->param_index) < binds->size()) {
                var idx = static_cast::<usize>(g->param_index);
                if (*binds)[idx] == &null { (*binds)[idx] = a; return true; }
                return (*binds)[idx] == a;
            }
            return p == a;   // another template's parameter: only itself.
        }
        if !p->is_dependent() { return false; }   // concrete and not identical.
        if p->kind != a->kind { return false; }
        switch p->kind {
            case TypeKind::PointerType {
                var pp = cast::<PointerType>(p); var ap = cast::<PointerType>(a);
                if pp->is_unsafe != ap->is_unsafe { return false; }
                return self._match(pp->pointee, ap->pointee, spec, binds);
            } case TypeKind::QualifiedType {
                var pq = cast::<QualifiedType>(p); var aq = cast::<QualifiedType>(a);
                if pq->quals != aq->quals { return false; }
                return self._match(pq->inner, aq->inner, spec, binds);
            } case TypeKind::NullableType {
                return self._match(cast::<NullableType>(p)->inner, cast::<NullableType>(a)->inner, spec, binds);
            } case TypeKind::FixedArrayType {
                if p->size_bits != a->size_bits { return false; }
                return self._match(cast::<FixedArrayType>(p)->element, cast::<FixedArrayType>(a)->element, spec, binds);
            } case TypeKind::FunctionPointerType {
                var pf = cast::<FunctionPointerType>(p); var af = cast::<FunctionPointerType>(a);
                if pf->params.size() != af->params.size() { return false; }
                for var i: usize = 0; i < pf->params.size(); ++i {
                    if pf->modes[i] != af->modes[i] { return false; }
                    if !self._match(pf->params[i], af->params[i], spec, binds) { return false; }
                }
                if (pf->return_type == &null) || (af->return_type == &null) { return pf->return_type == af->return_type; }
                return self._match(pf->return_type, af->return_type, spec, binds);
            } case TypeKind::RecordType {
                // `Box<P>` against `Box<i32>`: the same template (an instance
                // node and an explicit spec both lead back to the primary),
                // then argument by argument.
                var pr = cast::<RecordType>(p); var ar = cast::<RecordType>(a);
                if decl_pattern(pr->decl) != decl_pattern(ar->decl) { return false; }
                if pr->args.size() != ar->args.size() { return false; }
                for var i: usize = 0; i < pr->args.size(); ++i {
                    if !self._match(pr->args[i], ar->args[i], spec, binds) { return false; }
                }
                return true;
            } default { return false; }
        }
    }

    // === Conformance rows ======================================================

    /// The row for (\p conformer, \p iface), or null if none was recorded.
    fn row_find(self, conformer: *Type, iface: *Type) -> *ConformanceRow {
        var rlock = std::SharedLock(self._mu);
        return self._row_probe(conformer, iface);
    }

    /// Record \p r (built by the caller, outside the lock) unless a row for
    /// its key already exists; either way returns THE row for the key, so
    /// two TUs that both built one agree on a single identity.
    fn row_add(self, r: *ConformanceRow) -> *ConformanceRow {
        if r == &null { return &null; }
        var lock = std::LockGuard(self._mu);
        var hit = self._row_probe(r->conformer, r->iface);
        if hit != &null { return hit; }
        var mem: *void = self._arena.alloc(sizeof(ConformanceRow), alignof(ConformanceRow));
        var row = self._placement::<ConformanceRow>(mem);
        row->conformer  = r->conformer;
        row->iface      = r->iface;
        row->iface_decl = r->iface_decl;
        row->declared   = r->declared;
        row->covered_by = r->covered_by;
        row->ok         = r->ok;
        for var i: usize = 0; i < r->witnesses.size(); ++i { row->witnesses.push_back(r->witnesses[i]); }
        for var i: usize = 0; i < r->reqs.size(); ++i { row->reqs.push_back(r->reqs[i]); }
        for var i: usize = 0; i < r->ext_args.size(); ++i { row->ext_args.push_back(r->ext_args[i]); }
        for var i: usize = 0; i < r->ext_arg_count.size(); ++i { row->ext_arg_count.push_back(r->ext_arg_count[i]); }
        for var i: usize = 0; i < r->sources.size(); ++i { row->sources.push_back(r->sources[i]); }
        self._rows[self._row_hash(r->conformer, r->iface)].push_back(row);
        return row;
    }

    /// Record \p row as declared by \p by. Once per pair: a decl's TU
    /// checks it once, but a re-run must not double the list.
    fn declare_row(self, by: *Decl, row: *ConformanceRow) {
        if (by == &null) || (row == &null) { return; }
        var lock = std::LockGuard(self._mu);
        var l = &(self._declared[reinterpret_cast::<u64>(by)]);
        for var i: usize = 0; i < l->size(); ++i { if (*l)[i] == row { return; } }
        l->push_back(row);
    }

    /// The rows \p by declared, in declaration order, appended to \p out.
    fn declared_rows(self, by: *Decl, out: *vec::<*ConformanceRow>) {
        if (by == &null) || (out == &null) { return; }
        var rlock = std::SharedLock(self._mu);
        var it = self._declared.find(reinterpret_cast::<u64>(by));
        if it == self._declared.end() { return; }
        for var i: usize = 0; i < it->second.size(); ++i { out->push_back(it->second[i]); }
    }

    /// Write \p e's rows, once: the first TU to check the instance wins, and
    /// every later one computed the same list from the same table.
    fn set_rows(self, e: *InstanceEntry, rows: *vec::<*ConformanceRow>) {
        if (e == &null) || (rows == &null) { return; }
        var lock = std::LockGuard(self._mu);
        if e->rows_done { return; }
        for var i: usize = 0; i < rows->size(); ++i { e->rows.push_back((*rows)[i]); }
        e->rows_done = true;
    }

    // === Enumeration (M1 / EmitPlan) ===========================================

    /// Every entry, in NO defined order (hash order of pointer hashes,
    /// filled from parallel T). A caller that emits from this sorts by its
    /// own stable key -- EmitPlan by mangled name -- before writing anything.
    fn collect(self, out: ref!(vec::<*InstanceEntry>)) {
        var rlock = std::SharedLock(self._mu);
        for var it = self._table.begin(); it != self._table.end(); ++it {
            for var i: usize = 0; i < it->second.size(); ++i { out.push_back(it->second[i]); }
        }
    }

    fn size(self) -> usize {
        var n: usize = 0;
        for var it = self._table.begin(); it != self._table.end(); ++it { n += it->second.size(); }
        return n;
    }

    // === Internals ==============================================================

    priv fn _hash(self, primary: *Decl, args: *vec::<*Type>) -> u64 {
        var h = canon_hash_ptr(0, reinterpret_cast::<*void>(primary));
        var n: usize = 0;
        if args != &null { n = args->size(); }
        h = canon_hash_u64(h, static_cast::<u64>(n));
        for var i: usize = 0; i < n; ++i {
            h = canon_hash_ptr(h, reinterpret_cast::<*void>((*args)[i]));
        }
        // Top bit cleared: the mix reaches every u64, including the ~0 / ~0-1
        // DenseMap reserves for empty / tombstone (assert in debug, silent
        // corruption in release). The bucket compares args, so the extra
        // collision this folds in costs one comparison, never correctness.
        return h >> 1;
    }

    priv fn _row_hash(self, conformer: *Type, iface: *Type) -> u64 {
        var h = canon_hash_ptr(0, reinterpret_cast::<*void>(conformer));
        h = canon_hash_ptr(h, reinterpret_cast::<*void>(iface));
        return h >> 1;   // clear of DenseMap's reserved keys, as _hash.
    }

    /// Under the lock (either mode).
    priv fn _row_probe(self, conformer: *Type, iface: *Type) -> *ConformanceRow {
        var it = self._rows.find(self._row_hash(conformer, iface));
        if it == self._rows.end() { return &null; }
        for var i: usize = 0; i < it->second.size(); ++i {
            var r = it->second[i];
            if (r->conformer == conformer) && (r->iface == iface) { return r; }
        }
        return &null;
    }

    /// \p args with an expanded enum pack's duplicates gone
    /// (decl_dedup_pack_args), in \p scratch when anything was dropped.
    priv fn _set_args(self, primary: *Decl, args: *vec::<*Type>, scratch: *vec::<*Type>) -> *vec::<*Type> {
        if (args == &null) || (decl_pack_set_at(primary) == usize(-1)) { return args; }
        for var i: usize = 0; i < args->size(); ++i { scratch->push_back((*args)[i]); }
        decl_dedup_pack_args(primary, scratch, self.pack_order);
        return scratch;   // fewer, or reordered (PackSetOrder).

    }

    /// Under the lock (either mode).
    priv fn _probe(self, h: u64, primary: *Decl, args: *vec::<*Type>) -> *InstanceEntry {
        var it = self._table.find(h);
        if it == self._table.end() { return &null; }
        var b = &(it->second);
        var n = args->size();
        for var i: usize = 0; i < b->size(); ++i {
            var e = (*b)[i];
            if e->primary != primary { continue; }
            if e->args.size() != n { continue; }
            var same = true;
            for var j: usize = 0; j < n; ++j {
                if e->args[j] != (*args)[j] { same = false; break; }
            }
            if same { return e; }
        }
        return &null;
    }

    priv fn _new_entry(self, primary: *Decl, args: *vec::<*Type>, decl: *Decl,
                       is_explicit: bool, fid: u32) -> *InstanceEntry {
        var mem: *void = self._arena.alloc(sizeof(InstanceEntry), alignof(InstanceEntry));
        var e = self._placement::<InstanceEntry>(mem);
        e->primary     = primary;
        e->decl        = decl;
        e->is_explicit = is_explicit;
        e->home_fid    = fid;
        for var i: usize = 0; i < args->size(); ++i { e->args.push_back((*args)[i]); }
        return e;
    }

    // INLINE(placement)
    inline "c++" {
        template <typename T>
        T *_placement(void *mem) { return ::new (mem) T(); }
    }

    priv fn <T> _alloc(self) -> *T {
        var mem: *void = self._arena.alloc(sizeof(T), alignof(T));
        libcxx::memset(mem, 0, sizeof(T));
        return static_cast::<*T>(mem);
    }

    /// Everything a shell has in common, whatever its kind. The node's names
    /// are the PRIMARY's tokens: same TU, same imm space, so ctx_of() and every
    /// renderer land in the right interner.
    priv fn <T> _shell(self, n: *T, p: *T, kind: DeclKind, dck: DeclContextKind, ctx: *ASTContext) {
        n->kind  = kind;
        n->range = p->range;
        n->name  = p->name;
        n->init_annotations(&(self._arena));
        n->init_dc(dck, ctx, reinterpret_cast::<*DeclContext>(p->semantic_dc), static_cast::<*Decl>(n));
        n->dc_decls.set_allocator(&(self._arena));   // NOT the fid's ast_alloc (see file header).
        n->init_redecl();
        n->is_this_definition = true;                // a definition-in-waiting; M2 fills it.
        n->is_implicit        = true;
        n->lexical_dc         = p->semantic_dc;
        n->semantic_dc        = p->semantic_dc;
        n->generic_params.from_raw(static_cast::<*(*GenericParamDecl)>(&null), 0);
        n->spec_args.from_raw(static_cast::<*(*Type)>(&null), 0);
        n->requires_clause    = &null;
        n->spec_kind          = SpecKind::Instantiated;
        n->instantiated_from  = static_cast::<*Decl>(p);
        n->instantiated       = false;
    }

    /// The implicit node: the primary's DeclKind, empty body. Only the kinds
    /// that carry generic params exist here; an Interface instance is a
    /// conformance target, not a body, but it still needs an identity.
    priv fn _new_instance(self, primary: *Decl, ctx: *ASTContext) -> *Decl {
        if isa::<ClassDecl>(primary) {
            var p = cast::<ClassDecl>(primary);
            var n = self._alloc::<ClassDecl>();
            self._shell::<ClassDecl>(n, p, DeclKind::ClassDecl, DeclContextKind::Class, ctx);
            n->fields.from_raw(static_cast::<*(*FieldDecl)>(&null), 0);
            n->methods.from_raw(static_cast::<*(*FunctionDecl)>(&null), 0);
            n->derives_list.from_raw(static_cast::<*InheritEdge>(&null), 0);
            n->implements.from_raw(static_cast::<*InheritEdge>(&null), 0);
            n->is_final    = p->is_final;
            n->is_abstract = p->is_abstract;
            return static_cast::<*Decl>(n);
        }
        if isa::<StructDecl>(primary) {
            var p = cast::<StructDecl>(primary);
            var n = self._alloc::<StructDecl>();
            self._shell::<StructDecl>(n, p, DeclKind::StructDecl, DeclContextKind::Struct, ctx);
            n->fields.from_raw(static_cast::<*(*FieldDecl)>(&null), 0);
            n->methods.from_raw(static_cast::<*(*FunctionDecl)>(&null), 0);
            n->implements.from_raw(static_cast::<*InheritEdge>(&null), 0);
            return static_cast::<*Decl>(n);
        }
        if isa::<UnionDecl>(primary) {
            var p = cast::<UnionDecl>(primary);
            var n = self._alloc::<UnionDecl>();
            self._shell::<UnionDecl>(n, p, DeclKind::UnionDecl, DeclContextKind::Union, ctx);
            n->fields.from_raw(static_cast::<*(*FieldDecl)>(&null), 0);
            n->methods.from_raw(static_cast::<*(*FunctionDecl)>(&null), 0);
            n->is_anonymous = p->is_anonymous;
            return static_cast::<*Decl>(n);
        }
        if isa::<EnumDecl>(primary) {
            var p = cast::<EnumDecl>(primary);
            var n = self._alloc::<EnumDecl>();
            self._shell::<EnumDecl>(n, p, DeclKind::EnumDecl, DeclContextKind::Enum, ctx);
            n->variants.from_raw(static_cast::<*(*EnumVariantDecl)>(&null), 0);
            n->underlying = p->underlying;
            n->is_adt     = p->is_adt;
            n->is_open    = p->is_open;
            return static_cast::<*Decl>(n);
        }
        if isa::<InterfaceDecl>(primary) {
            var p = cast::<InterfaceDecl>(primary);
            var n = self._alloc::<InterfaceDecl>();
            self._shell::<InterfaceDecl>(n, p, DeclKind::InterfaceDecl, DeclContextKind::Interface, ctx);
            n->methods.from_raw(static_cast::<*(*FunctionDecl)>(&null), 0);
            n->derives_list.from_raw(static_cast::<*InheritEdge>(&null), 0);
            return static_cast::<*Decl>(n);
        }
        // A FUNCTION instance is the primary itself. The shell nodes above
        // exist so a member lookup on `Vec<i32>` has a table to walk; a
        // function instance has no table and nothing looks a name up inside
        // one, so minting an empty FunctionDecl would only create a second
        // identity for the same entity. EmitPlan/M1 read the entry's args to
        // write the explicit instantiation and never the node's body.
        if isa::<FunctionDecl>(primary) { return primary; }
        return &null;
    }
}