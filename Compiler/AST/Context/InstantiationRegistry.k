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
///         fills it, and may repoint `instantiated_from` at a partial
///         specialization it selected. Until then name lookup walks the
///         pattern (MemberLookup::_walk_record).
///
///     Dependent uses (`Foo<T>`, `Self` in a generic body) never come here:
///     their RecordType::decl is the primary -- a pattern -- and that is what
///     "deferred" means (#5). Partial specializations never back a RecordType
///     at all; they are patterns, kept per primary for M2's selection.
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
import AST::Kind::DeclKind::*;

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
    fn InstanceEntry(self) { }
}

class InstantiationRegistry {
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
    fn find(self, primary: *Decl, args: *vec::<*Type>) -> *InstanceEntry {
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
    fn instance_for(self, primary: *Decl, args: *vec::<*Type>, fid: u32,
                    ctx: *ASTContext) -> *InstanceEntry {
        if (primary == &null) || (args == &null) || (ctx == &null) { return &null; }
        var h = self._hash(primary, args);

        var lock = std::LockGuard(self._mu);
        var hit = self._probe(h, primary, args);
        if hit != &null { return hit; }

        var node = self._new_instance(primary, ctx);
        if node == &null { return &null; }
        var e = self._new_entry(primary, args, node, false, fid);
        self._table[h].push_back(e);
        self._by_node[reinterpret_cast::<u64>(node)] = e;
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
    fn register_explicit(self, primary: *Decl, args: *vec::<*Type>, spec: *Decl,
                         fid: u32) -> *InstanceEntry {
        if (primary == &null) || (args == &null) || (spec == &null) { return &null; }
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
    }

    fn partials_of(self, primary: *Decl) -> *vec::<*Decl> {
        var rlock = std::SharedLock(self._mu);
        var it = self._partials.find(reinterpret_cast::<u64>(primary));
        if it == self._partials.end() { return &null; }
        return it->second;
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
        row->ok         = r->ok;
        for var i: usize = 0; i < r->witnesses.size(); ++i { row->witnesses.push_back(r->witnesses[i]); }
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