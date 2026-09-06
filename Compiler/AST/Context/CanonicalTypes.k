/// --- The Kairo Project ------------------ AST/Context/CanonicalTypes.k --- ///
///
///   \brief THE canonical type store. One per build, owned by
///          GlobalDisambigTable. Hands out uniqued, fully-desugared Type nodes
///          so that `a->canonical == b->canonical` is type identity.
///
///   \detail
///     Base.k states the invariant this class exists to make true:
///
///         canonical always points to the fully-desugared, UNQUALIFIED type.
///         Type identity is (a->canonical == b->canonical) && (a->quals ==
///         b->quals).
///
///     That is a claim about POINTERS, and pointers are only comparable inside
///     one uniquing domain. Kairo has one ASTContext per fid, so a per-fid
///     store would make the invariant false the moment two TUs both write
///     `i32` -- which is every pair of TUs. Monomorphization and the
///     instantiation cache key on canonical identity, so the failure would
///     surface as silently duplicated instantiations rather than as an error.
///     Hence: ONE store, global, mutex-guarded.
///
///   \par Quals are excluded from every key
///     `const Foo` and `Foo` share a canonical and differ only in `quals`.
///     Base.k spells out why: a canonical that sometimes retains qualifiers
///     silently forks duplicate instantiations. Callers pass ALREADY-CANONICAL
///     components; this class never inspects a qualifier.
///
///   \par Arena
///     Its own, not any ASTContext's. release_from(Parsing) resets a fid's
///     ast_alloc, and a canonical shared with every importer of that fid
///     cannot die with the file that first mentioned it.
///
///   \par Threading
///     P/N/T are per-TU parallel (RESOLUTION.md hard invariant #4), so two
///     threads WILL ask for `*i32` at once. Every mutating entry point takes
///     the write lock. The lock is uncontended in the common case because a
///     TU asks for each distinct type shape once, not once per use.
///
///   Layer: AST/Context. Imports AST only -- never Sema (cycle rule, mirrors
///   SymbolTable and NameLookup).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Memory::ArenaAllocator::*;
import AST::Node::Base::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::ASTSupport::*;

/// \brief 64-bit mixer (splitmix64 finalizer). Used to fold component pointers
///        into a bucket key. Only ever a HINT: every bucket hit is confirmed by
///        a structural compare, so a collision costs a comparison, never a
///        wrong answer.
fn canon_mix(x: u64) -> u64 {
    var z = x + 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

fn canon_hash_ptr(h: u64, p: *void) -> u64 {
    return canon_mix(h ^ reinterpret_cast::<u64>(p));
}

fn canon_hash_u64(h: u64, v: u64) -> u64 {
    return canon_mix(h ^ v);
}

///
/// \class CanonicalTypeStore
/// \brief Uniquing tables + the arena the canonical nodes live in.
///
class CanonicalTypeStore {
    /// Canonical nodes outlive every fid, so they get their own arena rather
    /// than any ASTContext's. 256 KiB start: a large build interns a few
    /// thousand distinct type shapes, not hundreds of thousands.
    priv var _arena: ArenaAllocator = ArenaAllocator(256 * 1024);

    /// One lock for the whole store. Finer granularity is possible (per-kind
    /// tables) but pointless until a profile shows contention: each TU asks for
    /// each distinct shape ONCE and reads its own `canonical` slots after.
    priv var _mu: std::SharedMutex;

    /// Indexed by BuiltinKind; COUNT slots, filled eagerly in init().
    priv var _builtins: vec::<*Type>;

    /// bucket hash -> candidate nodes. One table for every uniqued kind: the
    /// hash already folds in the TypeKind, so cross-kind collisions are as rare
    /// as same-kind ones and are rejected by the same structural compare.
    priv var _table: libcxx::unordered_map::<u64, vec::<*Type>>;

    /// Pointer width in bits, for usize/isize. Set by init(); 64 until then.
    priv var _ptr_bits: usize = 64;

    priv var _ready: bool = false;

    fn CanonicalTypeStore(self) {
        self._table.reserve(256);
    }

    /// \brief Build the builtin singletons. Idempotent and lock-guarded: the
    ///        driver may call it once, or every SemaContext may call it
    ///        defensively, and the result is the same.
    ///
    /// \param ptr_bits target pointer width, for usize/isize. Everything else
    ///        has a width fixed by its name.
    fn init(self, ptr_bits: usize) {
        var lock = std::LockGuard(self._mu);
        if self._ready { return; }
        self._ptr_bits = ptr_bits;

        var n = static_cast::<usize>(BuiltinKind::COUNT);
        for var i: usize = 0; i < n; ++i {
            var b  = static_cast::<BuiltinKind>(static_cast::<u8>(i));
            var bt = self._alloc::<BuiltinType>();
            bt->kind       = TypeKind::BuiltinType;
            bt->range      = SourceRange::invalid();
            bt->builtin    = b;
            bt->type_flags = Type::TypeFlags::None;
            bt->init_annotations(&(self._arena));
            bt->init_spans(&(self._arena));

            var bits = builtin_fixed_bits(b);
            if (b == BuiltinKind::USize) || (b == BuiltinKind::ISize) {
                bits = self._ptr_bits;
            }
            bt->size_bits  = bits;
            bt->align_bits = bits;

            // A builtin is its own canonical. Uniform self-canonicality is what
            // lets every identity test read `->canonical` without a special
            // case for primitives.
            var ty = static_cast::<*Type>(bt);
            ty->canonical = ty;
            self._builtins.push_back(ty);
        }
        self._ready = true;
    }

    fn is_ready(self) -> bool { return self._ready; }

    // === Public factories ====================================================
    //
    // CONTRACT for every one of these: components passed in are ALREADY
    // canonical. Passing a syntax node yields a canonical that is not canonical
    // and quietly breaks identity, so TypeResolution resolves bottom-up and
    // never calls these with a raw parse node.

    fn builtin(self, b: BuiltinKind) -> *Type {
        var i = static_cast::<usize>(b);
        if i >= self._builtins.size() { return &null; }
        return self._builtins[i];
    }

    /// The canonical nominal type for \p decl instantiated at \p args.
    /// \p decl MUST be the canonical redecl link (the definition where one
    /// exists) -- passing a forward declaration forks the entity in two.
    fn record(self, decl: *Decl, args: *vec::<*Type>) -> *Type {
        if decl == &null { return &null; }

        var h = canon_hash_u64(0, static_cast::<u64>(static_cast::<u8>(TypeKind::RecordType)));
        h = canon_hash_ptr(h, reinterpret_cast::<*void>(decl));
        var n: usize = 0;
        if args != &null { n = args->size(); }
        h = canon_hash_u64(h, static_cast::<u64>(n));
        for var i: usize = 0; i < n; ++i {
            h = canon_hash_ptr(h, reinterpret_cast::<*void>((*args)[i]));
        }

        var lock = std::LockGuard(self._mu);
        var hit = self._probe_record(h, decl, args, n);
        if hit != &null { return hit; }

        var rt = self._alloc::<RecordType>();
        rt->kind  = TypeKind::RecordType;
        rt->range = SourceRange::invalid();
        rt->decl  = decl;
        rt->init_annotations(&(self._arena));
        rt->init_spans(&(self._arena));

        if n > 0 {
            var buf = self._alloc_array::<*Type>(n);
            for var i: usize = 0; i < n; ++i { buf[i] = (*args)[i]; }
            rt->args.from_raw(buf, n);
        } else {
            rt->args.from_raw(static_cast::<*(*Type)>(&null), 0);
        }

        var ty = static_cast::<*Type>(rt);
        ty->canonical = ty;
        // A generic instance is exactly as dependent as its arguments.
        for var i: usize = 0; i < n; ++i {
            self._absorb_flags(ty, (*args)[i]);
        }
        self._insert(h, ty);
        return ty;
    }

    fn pointer(self, pointee: *Type) -> *Type {
        return self._unary(TypeKind::PointerType, pointee);
    }

    fn nullable(self, inner: *Type) -> *Type {
        return self._unary(TypeKind::NullableType, inner);
    }

    fn vector(self, element: *Type) -> *Type {
        return self._unary(TypeKind::VectorType, element);
    }

    fn set_of(self, element: *Type) -> *Type {
        return self._unary(TypeKind::SetType, element);
    }

    fn cxx_lref(self, referee: *Type) -> *Type {
        return self._unary(TypeKind::CXXLValueRefType, referee);
    }

    fn cxx_rref(self, referee: *Type) -> *Type {
        return self._unary(TypeKind::CXXRValueRefType, referee);
    }

    fn map_of(self, key: *Type, value: *Type) -> *Type {
        if (key == &null) || (value == &null) { return &null; }
        var h = canon_hash_u64(0, static_cast::<u64>(static_cast::<u8>(TypeKind::MapType)));
        h = canon_hash_ptr(h, reinterpret_cast::<*void>(key));
        h = canon_hash_ptr(h, reinterpret_cast::<*void>(value));

        var lock = std::LockGuard(self._mu);
        var hit = self._probe_map(h, key, value);
        if hit != &null { return hit; }

        var mt = self._alloc::<MapType>();
        mt->kind  = TypeKind::MapType;
        mt->range = SourceRange::invalid();
        mt->key   = key;
        mt->value = value;
        mt->init_annotations(&(self._arena));
        mt->init_spans(&(self._arena));

        var ty = static_cast::<*Type>(mt);
        ty->canonical = ty;
        self._absorb_flags(ty, key);
        self._absorb_flags(ty, value);
        self._insert(h, ty);
        return ty;
    }

    fn tuple(self, elements: *vec::<*Type>) -> *Type {
        if elements == &null { return &null; }
        var n = elements->size();

        var h = canon_hash_u64(0, static_cast::<u64>(static_cast::<u8>(TypeKind::TupleType)));
        h = canon_hash_u64(h, static_cast::<u64>(n));
        for var i: usize = 0; i < n; ++i {
            h = canon_hash_ptr(h, reinterpret_cast::<*void>((*elements)[i]));
        }

        var lock = std::LockGuard(self._mu);
        var hit = self._probe_tuple(h, elements, n);
        if hit != &null { return hit; }

        var tt = self._alloc::<TupleType>();
        tt->kind  = TypeKind::TupleType;
        tt->range = SourceRange::invalid();
        tt->init_annotations(&(self._arena));
        tt->init_spans(&(self._arena));

        var buf = self._alloc_array::<*Type>(n);
        for var i: usize = 0; i < n; ++i { buf[i] = (*elements)[i]; }
        tt->elements.from_raw(buf, n);

        var ty = static_cast::<*Type>(tt);
        ty->canonical = ty;
        for var i: usize = 0; i < n; ++i { self._absorb_flags(ty, (*elements)[i]); }
        self._insert(h, ty);
        return ty;
    }

    /// Fixed array with a KNOWN extent. `[T; N]` where N is not yet a constant
    /// has no canonical -- TypeResolution marks that node instantiation-
    /// dependent and leaves it for the evaluator rather than inventing an
    /// identity that would collide `[T; N]` with `[T; M]`.
    fn array(self, element: *Type, extent: u64) -> *Type {
        if element == &null { return &null; }
        var h = canon_hash_u64(0, static_cast::<u64>(static_cast::<u8>(TypeKind::FixedArrayType)));
        h = canon_hash_ptr(h, reinterpret_cast::<*void>(element));
        h = canon_hash_u64(h, extent);

        var lock = std::LockGuard(self._mu);
        var hit = self._probe_array(h, element, extent);
        if hit != &null { return hit; }

        var at = self._alloc::<FixedArrayType>();
        at->kind          = TypeKind::FixedArrayType;
        at->range         = SourceRange::invalid();
        at->element       = element;
        at->size_expr     = &null;      // canonical form carries the VALUE, not the expr.
        at->is_incomplete = false;
        at->init_annotations(&(self._arena));
        at->init_spans(&(self._arena));
        // The extent is the identity, and a canonical FixedArrayType has no
        // size_expr to read it back from; stash it in size_bits so layout and
        // dumps can recover it without re-evaluating anything.
        at->size_bits = static_cast::<usize>(extent);

        var ty = static_cast::<*Type>(at);
        ty->canonical = ty;
        self._absorb_flags(ty, element);
        self._insert(h, ty);
        return ty;
    }

    fn func(self, params: *vec::<*Type>, ret: *Type) -> *Type {
        var n: usize = 0;
        if params != &null { n = params->size(); }

        var h = canon_hash_u64(0, static_cast::<u64>(static_cast::<u8>(TypeKind::FunctionPointerType)));
        h = canon_hash_ptr(h, reinterpret_cast::<*void>(ret));
        h = canon_hash_u64(h, static_cast::<u64>(n));
        for var i: usize = 0; i < n; ++i {
            h = canon_hash_ptr(h, reinterpret_cast::<*void>((*params)[i]));
        }

        var lock = std::LockGuard(self._mu);
        var hit = self._probe_func(h, params, n, ret);
        if hit != &null { return hit; }

        var ft = self._alloc::<FunctionPointerType>();
        ft->kind            = TypeKind::FunctionPointerType;
        ft->range           = SourceRange::invalid();
        ft->return_type     = ret;
        ft->is_unprototyped = false;
        ft->init_annotations(&(self._arena));
        ft->init_spans(&(self._arena));

        if n > 0 {
            var buf = self._alloc_array::<*Type>(n);
            for var i: usize = 0; i < n; ++i { buf[i] = (*params)[i]; }
            ft->params.from_raw(buf, n);
        } else {
            ft->params.from_raw(static_cast::<*(*Type)>(&null), 0);
        }

        var ty = static_cast::<*Type>(ft);
        ty->canonical  = ty;
        ty->size_bits  = self._ptr_bits;
        ty->align_bits = self._ptr_bits;
        if ret != &null { self._absorb_flags(ty, ret); }
        for var i: usize = 0; i < n; ++i { self._absorb_flags(ty, (*params)[i]); }
        self._insert(h, ty);
        return ty;
    }

    /// The canonical stand-in for a generic parameter. Uniqued on
    /// (owner decl, index) rather than on the name: two params named `T` in two
    /// different templates are different entities, and one param referred to by
    /// twenty spellings is one entity.
    fn generic_param(self, owner: *Decl, index: u32, is_pack: bool) -> *Type {
        if owner == &null { return &null; }
        var h = canon_hash_u64(0, static_cast::<u64>(static_cast::<u8>(TypeKind::GenericParamType)));
        h = canon_hash_ptr(h, reinterpret_cast::<*void>(owner));
        h = canon_hash_u64(h, static_cast::<u64>(index));

        var lock = std::LockGuard(self._mu);
        var hit = self._probe_gparam(h, owner, index);
        if hit != &null { return hit; }

        var gp = self._alloc::<GenericParamType>();
        gp->kind        = TypeKind::GenericParamType;
        gp->range       = SourceRange::invalid();
        gp->param_name  = &null;    // canonical form has no spelling; owner+index IS the identity.
        gp->param_index = index;
        gp->is_pack     = is_pack;
        gp->owner       = owner;
        gp->init_annotations(&(self._arena));
        gp->init_spans(&(self._arena));

        var flags = static_cast::<u8>(Type::TypeFlags::IsDependent)
                  | static_cast::<u8>(Type::TypeFlags::IsInstantiationDependent);
        if is_pack {
            flags = flags | static_cast::<u8>(Type::TypeFlags::ContainsUnexpandedPack);
        }
        gp->type_flags = static_cast::<Type::TypeFlags>(flags);

        var ty = static_cast::<*Type>(gp);
        ty->canonical = ty;
        self._insert(h, ty);
        return ty;
    }

    /// An opaque C++ type, keyed by its spelling imm. Genuinely a black box:
    /// two FFI headers naming `std::FILE` denote the same thing, and Kairo has
    /// nothing else to compare.
    fn opaque(self, name_imm: u32) -> *Type {
        var h = canon_hash_u64(0, static_cast::<u64>(static_cast::<u8>(TypeKind::OpaqueFFIType)));
        h = canon_hash_u64(h, static_cast::<u64>(name_imm));

        var lock = std::LockGuard(self._mu);
        var hit = self._probe_opaque(h, name_imm);
        if hit != &null { return hit; }

        var ot = self._alloc::<OpaqueFFIType>();
        ot->kind  = TypeKind::OpaqueFFIType;
        ot->range = SourceRange::invalid();
        ot->name  = name_imm;
        ot->init_annotations(&(self._arena));
        ot->init_spans(&(self._arena));

        var ty = static_cast::<*Type>(ot);
        ty->canonical = ty;
        self._insert(h, ty);
        return ty;
    }

    // === Identity =============================================================

    /// The identity test Base.k defines, as a function. Quals EXCLUDED by
    /// construction: they never entered a key, so two canonicals are equal iff
    /// the entities are. Callers that care about qualifiers compare `quals`
    /// themselves, which is the other half of the invariant.
    static fn identical(a: *Type, b: *Type) -> bool {
        if (a == &null) || (b == &null) { return false; }
        var ca = a->canonical;
        var cb = b->canonical;
        if (ca == &null) || (cb == &null) { return false; }
        return ca == cb;
    }

    // === Internals ============================================================

    priv fn <T> _alloc(self) -> *T {
        var mem: *void = self._arena.alloc(sizeof(T), alignof(T));
        libcxx::memset(mem, 0, sizeof(T));
        return static_cast::<*T>(mem);
    }

    priv fn <T> _alloc_array(self, n: usize) -> *T {
        if n == 0 { return &null; }
        var mem: *void = self._arena.alloc(sizeof(T) * n, alignof(T));
        libcxx::memset(mem, 0, sizeof(T) * n);
        return static_cast::<*T>(mem);
    }

    priv fn _insert(self, h: u64, ty: *Type) {
        self._table[h].push_back(ty);
    }

    priv fn _bucket(self, h: u64) -> *vec::<*Type> {
        var it = self._table.find(h);
        if it == self._table.end() { return &null; }
        return &(it->second);
    }

    /// Dependence propagates UP: a composite is dependent iff a component is.
    /// Mirrors propagate_flags in Types.k, but reads through `canonical` since
    /// that is what a component is here.
    priv fn _absorb_flags(self, parent: *Type, child: *Type) {
        if child == &null { return; }
        parent->type_flags = static_cast::<Type::TypeFlags>(
            static_cast::<u8>(parent->type_flags) | static_cast::<u8>(child->type_flags)
        );
    }

    /// Shared body for the one-component kinds. Each has exactly one child
    /// slot at a different field name, so the probe and the fill switch on
    /// kind; everything else is identical.
    priv fn _unary(self, k: TypeKind, child: *Type) -> *Type {
        if child == &null { return &null; }
        var h = canon_hash_u64(0, static_cast::<u64>(static_cast::<u8>(k)));
        h = canon_hash_ptr(h, reinterpret_cast::<*void>(child));

        var lock = std::LockGuard(self._mu);
        var b = self._bucket(h);
        if b != &null {
            for var i: usize = 0; i < b->size(); ++i {
                var c = (*b)[i];
                if c->kind != k { continue; }
                if self._unary_child(c) == child { return c; }
            }
        }

        var ty: *Type = &null;
        switch k {
            case TypeKind::PointerType {
                var n = self._alloc::<PointerType>();
                n->pointee = child;
                n->length  = 0;
                ty = static_cast::<*Type>(n);
                ty->size_bits  = self._ptr_bits;
                ty->align_bits = self._ptr_bits;
            }
            case TypeKind::NullableType {
                var n = self._alloc::<NullableType>();
                n->inner = child;
                ty = static_cast::<*Type>(n);
            }
            case TypeKind::VectorType {
                var n = self._alloc::<VectorType>();
                n->element = child;
                ty = static_cast::<*Type>(n);
            }
            case TypeKind::SetType {
                var n = self._alloc::<SetType>();
                n->element = child;
                ty = static_cast::<*Type>(n);
            }
            case TypeKind::CXXLValueRefType {
                var n = self._alloc::<CXXLValueRefType>();
                n->referee = child;
                ty = static_cast::<*Type>(n);
            }
            case TypeKind::CXXRValueRefType {
                var n = self._alloc::<CXXRValueRefType>();
                n->referee = child;
                ty = static_cast::<*Type>(n);
            }
            default { return &null; }
        }

        ty->kind  = k;
        ty->range = SourceRange::invalid();
        ty->init_annotations(&(self._arena));
        ty->init_spans(&(self._arena));
        ty->canonical = ty;
        self._absorb_flags(ty, child);
        self._insert(h, ty);
        return ty;
    }

    /// The single child of a one-component canonical, or null for other kinds.
    priv fn _unary_child(self, t: *Type) -> *Type {
        if t == &null { return &null; }
        switch t->kind {
            case TypeKind::PointerType      { return cast::<PointerType>(t)->pointee;      }
            case TypeKind::NullableType     { return cast::<NullableType>(t)->inner;       }
            case TypeKind::VectorType       { return cast::<VectorType>(t)->element;       }
            case TypeKind::SetType          { return cast::<SetType>(t)->element;          }
            case TypeKind::CXXLValueRefType { return cast::<CXXLValueRefType>(t)->referee; }
            case TypeKind::CXXRValueRefType { return cast::<CXXRValueRefType>(t)->referee; }
            default                         { return &null;                                }
        }
    }

    // --- probes (called under the write lock) --------------------------------

    priv fn _probe_record(self, h: u64, decl: *Decl, args: *vec::<*Type>, n: usize) -> *Type {
        var b = self._bucket(h);
        if b == &null { return &null; }
        for var i: usize = 0; i < b->size(); ++i {
            var c = (*b)[i];
            if c->kind != TypeKind::RecordType { continue; }
            var r = cast::<RecordType>(c);
            if r->decl != decl { continue; }
            if r->args.size() != n { continue; }
            var same = true;
            for var j: usize = 0; j < n; ++j {
                if r->args[j] != (*args)[j] { same = false; break; }
            }
            if same { return c; }
        }
        return &null;
    }

    priv fn _probe_map(self, h: u64, key: *Type, value: *Type) -> *Type {
        var b = self._bucket(h);
        if b == &null { return &null; }
        for var i: usize = 0; i < b->size(); ++i {
            var c = (*b)[i];
            if c->kind != TypeKind::MapType { continue; }
            var m = cast::<MapType>(c);
            if (m->key == key) && (m->value == value) { return c; }
        }
        return &null;
    }

    priv fn _probe_tuple(self, h: u64, elems: *vec::<*Type>, n: usize) -> *Type {
        var b = self._bucket(h);
        if b == &null { return &null; }
        for var i: usize = 0; i < b->size(); ++i {
            var c = (*b)[i];
            if c->kind != TypeKind::TupleType { continue; }
            var t = cast::<TupleType>(c);
            if t->elements.size() != n { continue; }
            var same = true;
            for var j: usize = 0; j < n; ++j {
                if t->elements[j] != (*elems)[j] { same = false; break; }
            }
            if same { return c; }
        }
        return &null;
    }

    priv fn _probe_array(self, h: u64, element: *Type, extent: u64) -> *Type {
        var b = self._bucket(h);
        if b == &null { return &null; }
        for var i: usize = 0; i < b->size(); ++i {
            var c = (*b)[i];
            if c->kind != TypeKind::FixedArrayType { continue; }
            var a = cast::<FixedArrayType>(c);
            if a->element != element { continue; }
            if static_cast::<u64>(a->size_bits) == extent { return c; }
        }
        return &null;
    }

    priv fn _probe_func(self, h: u64, params: *vec::<*Type>, n: usize, ret: *Type) -> *Type {
        var b = self._bucket(h);
        if b == &null { return &null; }
        for var i: usize = 0; i < b->size(); ++i {
            var c = (*b)[i];
            if c->kind != TypeKind::FunctionPointerType { continue; }
            var f = cast::<FunctionPointerType>(c);
            if f->return_type != ret { continue; }
            if f->params.size() != n { continue; }
            var same = true;
            for var j: usize = 0; j < n; ++j {
                if f->params[j] != (*params)[j] { same = false; break; }
            }
            if same { return c; }
        }
        return &null;
    }

    priv fn _probe_gparam(self, h: u64, owner: *Decl, index: u32) -> *Type {
        var b = self._bucket(h);
        if b == &null { return &null; }
        for var i: usize = 0; i < b->size(); ++i {
            var c = (*b)[i];
            if c->kind != TypeKind::GenericParamType { continue; }
            var g = cast::<GenericParamType>(c);
            if (g->owner == owner) && (g->param_index == index) { return c; }
        }
        return &null;
    }

    priv fn _probe_opaque(self, h: u64, name_imm: u32) -> *Type {
        var b = self._bucket(h);
        if b == &null { return &null; }
        for var i: usize = 0; i < b->size(); ++i {
            var c = (*b)[i];
            if c->kind != TypeKind::OpaqueFFIType { continue; }
            if cast::<OpaqueFFIType>(c)->name == name_imm { return c; }
        }
        return &null;
    }

    // --- stats (dumps only) ---------------------------------------------------

    fn interned_count(self) -> usize {
        var n = self._builtins.size();
        for var it = self._table.begin(); it != self._table.end(); ++it {
            n += it->second.size();
        }
        return n;
    }
}