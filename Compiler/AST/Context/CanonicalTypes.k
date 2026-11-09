/// --- The Kairo Project ----------------- AST/Context/CanonicalTypes.k --- ///
///
///   \brief THE canonical type store. One per build, owned by
///          GlobalDisambigTable. Hands out uniqued, fully-desugared Type nodes
///          so that `a->canonical == b->canonical` is type identity.
///
///   \detail
///     Base.k states the invariant this class exists to make true:
///
///         canonical always points to the fully-desugared type, qualifiers
///         included. Type identity is (a->canonical == b->canonical).
///
///     That is a claim about POINTERS, and pointers are only comparable inside
///     one uniquing domain. Kairo has one ASTContext per fid, so a per-fid
///     store would make the invariant false the moment two TUs both write
///     `i32` -- which is every pair of TUs. Monomorphization and the
///     instantiation cache key on canonical identity, so the failure would
///     surface as silently duplicated instantiations rather than as an error.
///     Hence: ONE store, global, mutex-guarded.
///
///   \par Qualifiers ARE in the key
///     `const Foo` and `Foo` are two canonicals: qualified(CONST, Foo) and
///     Foo. The wrapper is one interned node per (quals, inner) pair, and it
///     is the ONLY place a qualifier lives on a canonical: `inner` is never
///     itself a QualifiedType (qualified() folds), and no other kind carries
///     a cv bit. `const T&` is cxx_lref(qualified(CONST, T)); the old
///     `is_const` on CXXLValueRefType is gone. Without this `pair<const K, T>`
///     imported as `pair<K, T>`, `g(const int*)` and `g(int*)` were one
///     overload, and `W<const int>` was `W<int>`.
///     FunctionPointerType::modes is in the key too: `fn(@inout i32)` and
///     `fn(i32)` are two canonicals (AST/ParamMode.k).
///
///     "Same type ignoring qualifiers" is canon_unqual(a) == canon_unqual(b)
///     (CanonicalNodes.k); that question is asked by shape queries and by
///     signature identity at parameter top level, and nowhere else.
///
///     PointerType::is_unsafe is NOT a qualifier here. `unsafe *T` chooses the
///     pointer's representation; it says nothing about the pointee. It stays
///     a field on the pointer and in the pointer's key.
///
///   \par Arena
///     Its own, not any ASTContext's. release_from(Parsing) resets a fid's
///     ast_alloc, and a canonical shared with every importer of that fid
///     cannot die with the file that first mentioned it.
///
///   \par Threading
///     P/N/T are per-TU parallel (Compiler/Spec/Pipeline.md hard invariant #4),
///         so two
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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "atomic"
ffi "c++" import "Native/KThread.hh" // sema_mint_rank
ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"
ffi "c++" import "cstring"

import AST::DeclFacts::{
    PackSetOrder,
    decl_dedup_pack_args,
    decl_in_generic_owner,
    decl_is_imported,
    decl_pack_set_at,
}
import AST::Kind::TypeKind::TypeKind
import AST::Node::Base::{
    Decl,
    Type,
}
import AST::Node::CanonicalNodes::{
    AssocType,    BuiltinKind,  BuiltinType, QUAL_CONST, QUAL_VOLATILE, QualifiedType, RecordType,
    builtin_info, canon_unqual,
}
import AST::Node::Casting::{
    cast,
    isa,
}
import AST::Node::Types::{
    CXXLValueRefType, CXXRValueRefType, FixedArrayType, FunctionPointerType, GenericParamType,
    MapType,          NullableType,     OpaqueFFIType,  PointerType,         SetType,
    TypeExpr,         ValueOp,          VectorType,
}
import AST::ParamMode::ParamMode
import Location::SourceRange::SourceRange
import Memory::ArenaAllocator::ArenaAllocator
import Support::FlagSet::FlagSet
import Token::TokenKind::TokenKind

/// \brief 64-bit mixer (splitmix64 finalizer). Used to fold component pointers
///        into a bucket key. Only ever a HINT: every bucket hit is confirmed by
///        a structural compare, so a collision costs a comparison, never a
///        wrong answer.
pub fn canon_mix(x: u64) -> u64 {
    var z = x + 0x9E3779B97F4A7C15
    z = (z ^ z >> 30) * 0xBF58476D1CE4E5B9
    z = (z ^ z >> 27) * 0x94D049BB133111EB
    return z ^ z >> 31
}

pub fn canon_hash_ptr(h: u64, p: unsafe *void) -> u64 {
    return canon_mix(h ^ (p as usize as u64))
}

pub fn canon_hash_u64(h: u64, v: u64) -> u64 {
    return canon_mix(h ^ v)
}

///
/// \class CanonicalTypeStore
/// \brief Uniquing tables + the arena the canonical nodes live in.
///
pub class CanonicalTypeStore {
    /// How a lang item orders an expanded enum pack (DeclFacts::PackSetOrder;
    /// the Panic item's type-id order). Set once by the driver, before Sema.
    pub var pack_order: unsafe *PackSetOrder = &null

    /// Canonical nodes outlive every fid, so they get their own arena rather
    /// than any ASTContext's. 256 KiB start: a large build interns a few
    /// thousand distinct type shapes, not hundreds of thousands.
    priv var _arena: ArenaAllocator = ArenaAllocator(256 * 1024)
    /// _arena is shared() under this leaf lock, not `_mu`: every node carries
    /// ArenaLists (annotations, qualifier spans) bound to it, whose writers
    /// need not hold `_mu` (ArenaAllocator).
    priv var _arena_mu: kairo::std::Mutex

    /// One lock for the whole store. Finer granularity is possible (per-kind
    /// tables) but pointless until a profile shows contention: each TU asks for
    /// each distinct shape ONCE and reads its own `canonical` slots after.
    priv var _mu:        kairo::std::SharedMutex
    priv var _nullptr_t: unsafe *Type            = &null ///< see nullptr_t()

    /// Indexed by BuiltinKind; COUNT slots, filled eagerly in init().
    priv var _builtins: cxx::std::vector<unsafe *Type>

    /// bucket hash -> candidate nodes. One table for every uniqued kind: the
    /// hash already folds in the TypeKind, so cross-kind collisions are as rare
    /// as same-kind ones and are rejected by the same structural compare.
    /// Keyed by canon hash >> 1 (_key): the mix reaches every u64, including
    /// DenseMap's reserved ~0 / ~0-1. Buckets compare structurally, so the
    /// folded collision costs a comparison, never correctness. Bucket
    /// pointers from _bucket are used only before the _insert that follows.
    priv var _table: llvm::DenseMap<u64, cxx::std::vector<unsafe *Type>>

    /// Interned `T?`s with no record yet (lowered still null). Every TU's
    /// NullableTypeLowering asks for the unlowered ones, and nullables()
    /// walks the whole table to find them: 322 walks of a table that only
    /// grows were half a second of the serial self-build. At 0 there is
    /// nothing to find, and the walk is skipped (has_unlowered_nullables).
    priv var _unlowered_nullables: usize = 0

    /// Pointer width in bits, for usize/isize. Set by init(); 64 until then.
    priv var _ptr_bits: usize = 64

    /// sizeof(wchar_t) in bits, for c_wchar's layout. Set by init().
    priv var _wchar_bits: usize = 32

    /// sizeof / alignof(long double) in bits, for f80's layout. Set by init().
    priv var _ld_bits:  usize = 128
    priv var _ld_align: usize = 128

    priv var _ready: bool = false

    fn CanonicalTypeStore(self) {
        self._arena.shared(unsafe &self._arena_mu)
        self._table.reserve(256)
    }

    /// \brief Build the builtin singletons. Idempotent and lock-guarded: the
    ///        driver may call it once, or every SemaContext may call it
    ///        defensively, and the result is the same.
    ///
    /// \param ptr_bits target pointer width, for usize/isize. Everything else
    ///        has a width fixed by its name.
    /// \param int64_is_long whether the target's int64_t is `long` rather
    ///        than `long long` (LLP64, Darwin, every 32-bit target). Spells
    ///        i64/u64.
    /// \param ld_bits, ld_align sizeof / alignof(long double) in bits on the
    ///        target. f80's STORAGE: 80 value bits occupy 96 on i386 and 128
    ///        on x86_64, and the row's `bits` column is the value width.
    ///        0 means unfilled and keeps the x86_64 128/128.
    /// \param wchar_bits sizeof(wchar_t) in bits, for c_wchar (32, or 16 on
    ///        Windows). 0 means unfilled and keeps 32.
    ///
    /// \details the i64/u64 spellings are written into BuiltinTable itself,
    ///          not onto the nodes: every emitter reads builtin_info()->cxx,
    ///          and the table is as build-wide as this store. First caller
    ///          wins here, so the table is written exactly once.
    pub fn init(self,
                ptr_bits:      usize,
                int64_is_long: bool,
                ld_bits:       usize,
                ld_align:      usize,
                wchar_bits:    usize) {
        var lock = kairo::std::LockGuard(self._mu)
        if self._ready {
            return
        }

        self._ptr_bits = ptr_bits
        if wchar_bits != 0 {
            self._wchar_bits = wchar_bits
        }

        if ld_bits != 0 && ld_align != 0 {
            self._ld_bits  = ld_bits
            self._ld_align = ld_align
        }

        builtin_info(BuiltinKind::I64)->cxx = if int64_is_long => ("signed long")
                                              else => "signed long long"
        builtin_info(BuiltinKind::U64)->cxx = if int64_is_long => ("unsigned long")
                                              else => "unsigned long long"

        var n = (BuiltinKind::COUNT as u8 as usize)
        for var i: usize = 0; i < n; ++i {
            var        b   = ((i as u8) as BuiltinKind)
            var unsafe *bt = self._alloc<BuiltinType>()
            bt->kind       = TypeKind::BuiltinType
            bt->range      = SourceRange::invalid()
            bt->builtin    = b
            bt->type_flags = FlagSet<Type::TypeFlags, u8>()
            bt->init_annotations(unsafe &self._arena)
            bt->init_spans(unsafe &self._arena)

            var bits = builtin_info(b)->bits
            if b == BuiltinKind::USize || b == BuiltinKind::ISize {
                bits = self._ptr_bits
            }

            if b == BuiltinKind::CWChar {
                bits = self._wchar_bits
            }

            bt->size_bits  = bits
            bt->align_bits = bits

            // The one row whose storage is not its value width. Where f80 is
            // gated off this is never reached by a resolved type, so the
            // target's non-x87 long double size does no harm here.
            if b == BuiltinKind::F80 {
                bt->size_bits  = self._ld_bits
                bt->align_bits = self._ld_align
            }

            // A builtin is its own canonical. Uniform self-canonicality is what
            // lets every identity test read `->canonical` without a special
            // case for primitives.
            var unsafe *ty = unsafe (bt as unsafe *Type)
            ty->canonical = ty
            self._builtins.push_back(ty)
        }

        self._ready = true
    }

    fn is_ready(self) -> bool {
        return self._ready
    }

    /// # Public factories
    ///
    /// CONTRACT for every one of these: components passed in are ALREADY
    /// canonical. Passing a syntax node yields a canonical that is not canonical
    /// and quietly breaks identity, so TypeResolution resolves bottom-up and
    /// never calls these with a raw parse node.

    pub fn builtin(self, b: BuiltinKind) -> unsafe *Type {
        var i = (b as u8 as usize)
        if i >= self._builtins.size() {
            return &null
        }

        return self._builtins[i]
    }

    /// The canonical nominal type for \p decl instantiated at \p args.
    /// \p decl MUST be the canonical redecl link (the definition where one
    /// exists) -- passing a forward declaration forks the entity in two.
    pub fn record(self,
                  decl:    unsafe *Decl,
                  args_in: unsafe *cxx::std::vector<unsafe *Type>) -> unsafe *Type {
        return self.record_in(decl, args_in, &null)
    }

    /// \p decl, a record nested in a generic one, seen through the
    /// enclosing record \p outer (`L<i32>::P`; RecordType::outer). Null
    /// \p outer is record(): the plain type, flagged InGenericOwner when
    /// \p decl's owners are generic (it then names their current
    /// instantiation).
    pub fn record_in(self,
                     decl:    unsafe *Decl,
                     args_in: unsafe *cxx::std::vector<unsafe *Type>,
                     outer:   unsafe *Type) -> unsafe *Type {
        if decl == &null {
            return &null
        }

        // An enum's expanded pack is a set (decl_dedup_pack_args), so its
        // duplicates are gone before the type has an identity.
        var unsafe *args   = args_in
        var        deduped = cxx::std::vector<unsafe *Type>()
        if args_in != &null && args_in->size() > 1 && decl_pack_set_at(decl) != usize::MAX {
            for var i: usize = 0; i < args_in->size(); ++i {
                deduped.push_back((*args_in)[i])
            }

            decl_dedup_pack_args(decl, unsafe &deduped, self.pack_order)
            args = unsafe &deduped // fewer, or reordered (PackSetOrder).
        }

        var h = canon_hash_u64(0, (TypeKind::RecordType as u8))
        h = canon_hash_ptr(h, unsafe (decl as unsafe *void))
        var n: usize = 0
        if args != &null {
            n = args->size()
        }

        h = canon_hash_u64(h, n as u64)
        for var i: usize = 0; i < n; ++i {
            h = canon_hash_ptr(h, unsafe ((*args)[i] as unsafe *void))
        }

        if outer != &null {
            h = canon_hash_ptr(h, unsafe (outer as unsafe *void))
        }

        var        lock = kairo::std::LockGuard(self._mu)
        var unsafe *hit = self._probe_record(h, decl, args, n, outer)
        if hit != &null {
            return hit
        }

        var unsafe *rt = self._alloc<RecordType>()
        rt->kind  = TypeKind::RecordType
        rt->range = SourceRange::invalid()
        rt->decl  = decl
        rt->outer = outer
        rt->init_annotations(unsafe &self._arena)
        rt->init_spans(unsafe &self._arena)

        if n > 0 {
            var unsafe **buf = self._alloc_array<unsafe *Type>(n)
            for var i: usize = 0; i < n; ++i {
                buf[i] = (*args)[i]
            }

            rt->args.from_raw(buf, n)
        } else {
            rt->args.from_raw(unsafe (&null as unsafe *(unsafe *Type)), 0)
        }

        var unsafe *ty = unsafe (rt as unsafe *Type)
        ty->canonical = ty
        // A generic instance is exactly as dependent as its arguments.
        for var i: usize = 0; i < n; ++i {
            self._absorb_flags(ty, (*args)[i])
        }

        // An imported template over a member type of a generic Kairo owner
        // (`vector<Op>` in `L<T>`'s body, Op being L<T>::Op) is as dependent
        // as `vector<T>`: clang has no spelling for Op until the owner's
        // parameters are bound, so a registry instance made now could never
        // be filled and its `size_type` would stay an unmapped <ffi type>.
        // Substitution forms the instance over the bound owner.
        if decl_is_imported(decl) {
            for var i: usize = 0; i < n; ++i {
                if (*args)[i]->in_generic_owner() {
                    ty->type_flags.set(Type::TypeFlags::IsDependent)
                    ty->type_flags.set(Type::TypeFlags::IsInstantiationDependent)
                }
            }
        }

        // ...and a member type as its enclosing instance; one named as its
        // owner's current instantiation carries the owner's parameters
        // implicitly.
        if outer != &null {
            self._absorb_flags(ty, outer)
        } else if decl_in_generic_owner(decl) {
            ty->type_flags.set(Type::TypeFlags::InGenericOwner)
        }

        self._insert(h, ty)
        return ty
    }

    /// The cv-qualified form of \p inner. \p quals is a QUAL_* bitset. Zero
    /// returns \p inner unchanged; an already-qualified \p inner folds, so
    /// qualified(CONST, qualified(VOLATILE, T)) is ONE node carrying both
    /// bits and a QualifiedType never wraps a QualifiedType. Layout is the
    /// inner's: a qualifier changes what may be done with the object, not
    /// its bytes.
    pub fn qualified(self, inner: unsafe *Type, quals: u8) -> unsafe *Type {
        if inner == &null {
            return &null
        }

        if quals == 0 {
            return inner
        }

        var unsafe *base = inner
        var        q     = quals
        if isa<QualifiedType>(inner) {
            q    = q | cast<QualifiedType>(inner)->quals
            base = cast<QualifiedType>(inner)->inner
        }

        if (q & ~(QUAL_CONST | QUAL_VOLATILE)) != 0 {
            kairo::std::ice_fail("CanonicalTypeStore::qualified: bit outside const/volatile")
        }

        var h = canon_hash_u64(0, (TypeKind::QualifiedType as u8))
        h = canon_hash_ptr(h, unsafe (base as unsafe *void))
        h = canon_hash_u64(h, q)

        var        lock = kairo::std::LockGuard(self._mu)
        var unsafe *hit = self._probe_qualified(h, base, q)
        if hit != &null {
            return hit
        }

        var unsafe *qt = self._alloc<QualifiedType>()
        qt->kind  = TypeKind::QualifiedType
        qt->range = SourceRange::invalid()
        qt->inner = base
        qt->quals = q
        qt->init_annotations(unsafe &self._arena)
        qt->init_spans(unsafe &self._arena)
        // The mixin bits mirror the key so anything that reads `flags` off a
        // canonical (a printer) sees the same answer. Nothing keys on them.
        if (q & QUAL_CONST) != 0 {
            qt->add_const()
        }

        if (q & QUAL_VOLATILE) != 0 {
            qt->add_volatile()
        }

        var unsafe *ty = unsafe (qt as unsafe *Type)
        ty->canonical  = ty
        ty->size_bits  = base->size_bits
        ty->align_bits = base->align_bits
        self._absorb_flags(ty, base)
        self._insert(h, ty)
        return ty
    }

    /// `*T` and `unsafe *T` are two entities, not one type with a flag: the
    /// conversion lattice will not cross between them, so safety is part of
    /// the uniquing key.
    pub fn pointer(self, pointee: unsafe *Type, is_unsafe: bool = false) -> unsafe *Type {
        return self._unary(TypeKind::PointerType, pointee, is_unsafe)
    }

    pub fn nullable(self, inner: unsafe *Type) -> unsafe *Type {
        return self._unary(TypeKind::NullableType, inner)
    }

    // No vector()/set_of()/map_of()/tuple(): `[T]`, `{T}`, `{K: V}` and
    // `(A, B)` canonicalize to the Vector/HashSet/HashMap lang RECORDS
    // (TypeResolve::_lang_record) and the TupleN record (SemaContext::
    // tuple_record), and a second way to build a structural canonical would
    // fork the identity of the same written type. The VectorType/SetType/
    // MapType/TupleType arms below stay: those kinds still exist as SYNTAX
    // nodes and pass through qualified() and the dedup probes.

    /// `const T&` is cxx_lref(qualified(CONST, T)): the reference has no
    /// qualifiers of its own, the referee carries them, and the referee is
    /// the whole key.
    pub fn cxx_lref(self, referee: unsafe *Type) -> unsafe *Type {
        return self._unary(TypeKind::CXXLValueRefType, referee)
    }

    pub fn cxx_rref(self, referee: unsafe *Type) -> unsafe *Type {
        return self._unary(TypeKind::CXXRValueRefType, referee)
    }

    /// Fixed array with a KNOWN extent. `[T; N]` where N is not yet a constant
    /// has no canonical -- TypeResolution marks that node instantiation-
    /// dependent and leaves it for the evaluator rather than inventing an
    /// identity that would collide `[T; N]` with `[T; M]`.
    pub fn array(self, element: unsafe *Type, extent: u64) -> unsafe *Type {
        if element == &null {
            return &null
        }

        var h = canon_hash_u64(0, (TypeKind::FixedArrayType as u8))
        h = canon_hash_ptr(h, unsafe (element as unsafe *void))
        h = canon_hash_u64(h, extent)

        var        lock = kairo::std::LockGuard(self._mu)
        var unsafe *hit = self._probe_array(h, element, extent)
        if hit != &null {
            return hit
        }

        var unsafe *at = self._alloc<FixedArrayType>()
        at->kind          = TypeKind::FixedArrayType
        at->range         = SourceRange::invalid()
        at->element       = element
        at->size_expr     = &null // canonical form carries the VALUE, not the expr.
        at->is_incomplete = false
        at->extent_param  = &null
        at->init_annotations(unsafe &self._arena)
        at->init_spans(unsafe &self._arena)
        // The extent is the identity, and a canonical FixedArrayType has no
        // size_expr to read it back from; stash it in size_bits so layout and
        // dumps can recover it without re-evaluating anything.
        at->size_bits = (extent as usize)

        var unsafe *ty = unsafe (at as unsafe *Type)
        ty->canonical = ty
        self._absorb_flags(ty, element)
        self._insert(h, ty)
        return ty
    }

    /// C's array of unknown bound, `T[]`, as a foreign header has it (a
    /// Kairo file's `[T;]` is the Slice lang item instead). Its own
    /// identity, apart from `[T; 0]`: both have no elements to lay out, but
    /// they are different C++ types, and a template argument spelled from
    /// the canonical has to say which -- `unique_ptr<int[]>` is the array
    /// specialization, `unique_ptr<int[0]>` is not a valid one.
    pub fn incomplete_array(self, element: unsafe *Type) -> unsafe *Type {
        if element == &null {
            return &null
        }

        var h = canon_hash_u64(0, (TypeKind::FixedArrayType as u8))
        h = canon_hash_ptr(h, unsafe (element as unsafe *void))
        h = canon_hash_u64(h, 0x696e636f6d706c74) // a salt no extent shares the bucket by.

        var        lock = kairo::std::LockGuard(self._mu)
        var unsafe *b   = self._bucket(h)
        if b != &null {
            for var i: usize = 0; i < b->size(); ++i {
                var unsafe *c = (*b)[i]
                if c->kind != TypeKind::FixedArrayType {
                    continue
                }

                var unsafe *a = cast<FixedArrayType>(c)
                if a->element == element && a->is_incomplete {
                    return c
                }
            }
        }

        var unsafe *at = self._alloc<FixedArrayType>()
        at->kind          = TypeKind::FixedArrayType
        at->range         = SourceRange::invalid()
        at->element       = element
        at->size_expr     = &null
        at->is_incomplete = true
        at->extent_param  = &null
        at->init_annotations(unsafe &self._arena)
        at->init_spans(unsafe &self._arena)
        at->size_bits = 0

        var unsafe *ty = unsafe (at as unsafe *Type)
        ty->canonical = ty
        self._absorb_flags(ty, element)
        self._insert(h, ty)
        return ty
    }

    /// `[T; N]` for a generic VALUE parameter N (\p param, its canonical
    /// GenericParamType): dependent, keyed on (element, param), substituted
    /// to array() per instance (Compiler/Spec/Eval.md#generic-value-parameters).
    pub fn array_of_param(self, element: unsafe *Type, param: unsafe *Type) -> unsafe *Type {
        if element == &null || param == &null {
            return &null
        }

        var h = canon_hash_u64(0, (TypeKind::FixedArrayType as u8))
        h = canon_hash_ptr(h, unsafe (element as unsafe *void))
        h = canon_hash_ptr(h, unsafe (param as unsafe *void))

        var        lock = kairo::std::LockGuard(self._mu)
        var unsafe *b   = self._bucket(h)
        if b != &null {
            for var i: usize = 0; i < b->size(); ++i {
                var unsafe *c = (*b)[i]
                if c->kind != TypeKind::FixedArrayType {
                    continue
                }

                var unsafe *a = cast<FixedArrayType>(c)
                if a->element == element && a->extent_param == param {
                    return c
                }
            }
        }

        var unsafe *at = self._alloc<FixedArrayType>()
        at->kind          = TypeKind::FixedArrayType
        at->range         = SourceRange::invalid()
        at->element       = element
        at->size_expr     = &null
        at->is_incomplete = false
        at->extent_param  = param
        at->init_annotations(unsafe &self._arena)
        at->init_spans(unsafe &self._arena)
        at->size_bits = 0

        var unsafe *ty = unsafe (at as unsafe *Type)
        ty->canonical = ty
        self._absorb_flags(ty, element)
        self._absorb_flags(ty, param)
        self._insert(h, ty)
        return ty
    }

    /// A generic VALUE argument (`4` of `Buf<4>`): a canonical TypeExpr
    /// holding the exact integer, keyed on it, never dependent. The slot's
    /// declared type is the parameter's, so the value alone is the identity
    /// (Compiler/Spec/Eval.md#generic-value-parameters).
    pub fn value_arg(self, neg: bool, mag: u64) -> unsafe *Type {
        var h = canon_hash_u64(0, (TypeKind::TypeExpr as u8))
        h = canon_hash_u64(h, if (neg) => (1 as u64) else => (0))
        h = canon_hash_u64(h, mag)

        var        lock = kairo::std::LockGuard(self._mu)
        var unsafe *b   = self._bucket(h)
        if b != &null {
            for var i: usize = 0; i < b->size(); ++i {
                var unsafe *c = (*b)[i]
                if c->kind != TypeKind::TypeExpr {
                    continue
                }

                var unsafe *v = cast<TypeExpr>(c)
                if v->is_exact() && v->vneg == neg && v->vmag == mag {
                    return c
                }
            }
        }

        var unsafe *te = self._alloc<TypeExpr>()
        te->kind     = TypeKind::TypeExpr
        te->range    = SourceRange::invalid()
        te->expr     = &null
        te->is_value = true
        te->vneg     = neg
        te->vmag     = mag
        te->vop      = ValueOp::Literal
        te->vtok     = TokenKind::TkUnknown
        te->vdecl    = &null
        te->vty      = &null
        te->vbytes   = &null
        te->vops.from_raw(unsafe (&null as unsafe *(unsafe *Type)), 0)
        te->type_flags = FlagSet<Type::TypeFlags, u8>()
        te->init_annotations(unsafe &self._arena)
        te->init_spans(unsafe &self._arena)

        var unsafe *ty = unsafe (te as unsafe *Type)
        ty->canonical = ty
        self._insert(h, ty)
        return ty
    }

    /// A value Sema keeps for C++ to compute (Compiler/Spec/Eval.md#value-nodes): an array extent
    /// or generic value argument over value parameters, eval names and
    /// eval calls that does not fold (ValueOp). Keyed on the node's own
    /// fields and its operands' canonicals, which are interned themselves,
    /// so two nodes are the same type exactly when they are the same
    /// expression. Dependent when an operand is (a value parameter).
    pub fn value_expr(self,
                      vk:   ValueOp,
                      tok:  TokenKind,
                      decl: unsafe *Decl,
                      ops:  unsafe *cxx::std::vector<unsafe *Type>,
                      ty:   unsafe *Type) -> unsafe *Type {
        var n: usize = 0
        if ops != &null {
            n = ops->size()
        }

        var h = canon_hash_u64(0, (TypeKind::TypeExpr as u8))
        h = canon_hash_u64(h, 0x5645)                        // apart from value_arg's keys.
        h = canon_hash_u64(h, (vk as u8))
        h = canon_hash_u64(h, (tok as u32))
        h = canon_hash_ptr(h, unsafe (decl as unsafe *void))
        h = canon_hash_ptr(h, unsafe (ty as unsafe *void))
        h = canon_hash_u64(h, n as u64)
        for var i: usize = 0; i < n; ++i {
            h = canon_hash_ptr(h, unsafe ((*ops)[i] as unsafe *void))
        }

        var        lock = kairo::std::LockGuard(self._mu)
        var unsafe *b   = self._bucket(h)
        if b != &null {
            for var i: usize = 0; i < b->size(); ++i {
                var unsafe *c = (*b)[i]
                if c->kind != TypeKind::TypeExpr {
                    continue
                }

                var unsafe *v = cast<TypeExpr>(c)
                if !v->is_value
                    || v->vop != vk
                    || v->vtok != tok
                    || v->vdecl != decl
                    || v->vty != ty {
                    continue
                }

                if v->vops.size() != n {
                    continue
                }

                var same = true
                for var k: usize = 0; k < n; ++k {
                    if v->vops[k] != (*ops)[k] {
                        same = false
                        break
                    }
                }

                if same {
                    return c
                }
            }
        }

        var unsafe *te = self._alloc<TypeExpr>()
        te->kind     = TypeKind::TypeExpr
        te->range    = SourceRange::invalid()
        te->expr     = &null
        te->is_value = true
        te->vneg     = false
        te->vmag     = (0)
        te->vop      = vk
        te->vtok     = tok
        te->vdecl    = decl
        te->vty      = ty
        te->vbytes   = &null
        if n > 0 {
            var unsafe **buf = self._alloc_array<unsafe *Type>(n)
            for var i: usize = 0; i < n; ++i {
                buf[i] = (*ops)[i]
            }

            te->vops.from_raw(buf, n)
        } else {
            te->vops.from_raw(unsafe (&null as unsafe *(unsafe *Type)), 0)
        }

        te->type_flags = FlagSet<Type::TypeFlags, u8>()
        te->init_annotations(unsafe &self._arena)
        te->init_spans(unsafe &self._arena)

        var unsafe *t = unsafe (te as unsafe *Type)
        t->canonical = t
        for var i: usize = 0; i < n; ++i {
            self._absorb_flags(t, (*ops)[i])
        }

        if ty != &null {
            self._absorb_flags(t, ty)
        }

        self._insert(h, t)
        return t
    }

    /// A string literal in a computed value (ValueOp::Str, Compiler/Spec/Eval.md#eval-classes):
    /// keyed on its decoded bytes, so two literals with the same bytes are
    /// one node wherever they are written; \p ty is the string record.
    pub fn value_str(self, const bytes: cxx::std::vector<u8>, ty: unsafe *Type) -> unsafe *Type {
        var n = bytes.size()
        var h = canon_hash_u64(0, (TypeKind::TypeExpr as u8))
        h = canon_hash_u64(h, 0x5354)   // apart from value_arg's and value_expr's keys.
        h = canon_hash_u64(h, n as u64)
        for var i: usize = 0; i < n; ++i {
            h = canon_hash_u64(h, (bytes)[i])
        }

        h = canon_hash_ptr(h, unsafe (ty as unsafe *void))

        var        lock = kairo::std::LockGuard(self._mu)
        var unsafe *b   = self._bucket(h)
        if b != &null {
            for var i: usize = 0; i < b->size(); ++i {
                var unsafe *c = (*b)[i]
                if c->kind != TypeKind::TypeExpr {
                    continue
                }

                var unsafe *v = cast<TypeExpr>(c)
                if !v->is_value || v->vop != ValueOp::Str || v->vty != ty || v->vmag != (n as u64) {
                    continue
                }

                var same = true
                for var k: usize = 0; k < n; ++k {
                    if v->vbytes[k] != (bytes)[k] {
                        same = false
                        break
                    }
                }

                if same {
                    return c
                }
            }
        }

        var unsafe *te = self._alloc<TypeExpr>()
        te->kind     = TypeKind::TypeExpr
        te->range    = SourceRange::invalid()
        te->expr     = &null
        te->is_value = true
        te->vneg     = false
        te->vmag     = (n as u64)
        te->vop      = ValueOp::Str
        te->vtok     = TokenKind::TkUnknown
        te->vdecl    = &null
        te->vty      = ty
        var unsafe *buf = self._alloc_array<u8>(n + 1)
        for var i: usize = 0; i < n; ++i {
            buf[i] = (bytes)[i]
        }

        buf[n]     = (0)
        te->vbytes = unsafe (buf as kairo::std::ConstPtr<u8>)
        te->vops.from_raw(unsafe (&null as unsafe *(unsafe *Type)), 0)
        te->type_flags = FlagSet<Type::TypeFlags, u8>()
        te->init_annotations(unsafe &self._arena)
        te->init_spans(unsafe &self._arena)

        var unsafe *t = unsafe (te as unsafe *Type)
        t->canonical = t
        if ty != &null {
            self._absorb_flags(t, ty)
        }

        self._insert(h, t)
        return t
    }

    /// \p modes is parallel to \p params, or null for all-Value (every
    /// caller that has no modes to offer -- an imported C++ function type,
    /// which spells reference kinds as types, not modes -- passes null).
    /// Modes are in the key: `fn(@inout i32)` and `fn(i32)` are two
    /// entities, because a closure's type IS this canonical and the mode
    /// must survive `apply(f: fn(i32) -> i32)`.
    ///
    /// So is the panic effect (Compiler/Spec/Panic.md#declared-sets): \p panics, and \p pset, the
    /// canonical set (null or empty for a bare `panic` with no set known).
    /// `fn() panic(E) -> i32` and `fn() -> i32` are two types, converted by
    /// subset (Conversion's fn rung); a call through a value of one adds
    /// its set. The caller passes the set CANONICAL (EffectPropagation's
    /// canonical_set: each type once, in the one order): the store only
    /// compares it element by element, it cannot spell types to sort them.
    ///
    /// And so is \p raw: `unsafe fn(A) -> R` is the plain function pointer
    /// `R(*)(A)`, one word, which a capturing closure cannot be; `fn(A) ->
    /// R` is the `__kairo_fn` value, three words, which holds either. Two
    /// canonicals, because the C++ spelling (an ABI) differs; a raw one
    /// widens to the value implicitly, never back (Conversion's fn rung).
    pub fn func(self,
                params: unsafe *cxx::std::vector<unsafe *Type>,
                modes:  unsafe *cxx::std::vector<ParamMode>,
                ret:    unsafe *Type,
                panics: bool = false,
                pset:   unsafe *cxx::std::vector<unsafe *Type> = &null,
                raw:    bool = false,
                cc:     u8 = 0) -> unsafe *Type {
        var n: usize = 0
        if params != &null {
            n = params->size()
        }

        if modes != &null && modes->size() != n {
            kairo::std::ice_fail("CanonicalTypeStore::func: modes not parallel to params")
        }

        var ns: usize = 0
        if pset != &null && panics {
            ns = pset->size()
        }

        var h = canon_hash_u64(0, (TypeKind::FunctionPointerType as u8))
        h = canon_hash_ptr(h, unsafe (ret as unsafe *void))
        h = canon_hash_u64(h, n as u64)
        for var i: usize = 0; i < n; ++i {
            h = canon_hash_ptr(h, unsafe ((*params)[i] as unsafe *void))
            h = canon_hash_u64(h, (self._mode_at(modes, i) as u8))
        }

        h = canon_hash_u64(h, if (panics) => (1 as u64) else => (0))
        for var i: usize = 0; i < ns; ++i {
            h = canon_hash_ptr(h, unsafe ((*pset)[i] as unsafe *void))
        }

        h = canon_hash_u64(h, if (raw) => (1 as u64) else => (0))
        h = canon_hash_u64(h, cc)

        var        lock = kairo::std::LockGuard(self._mu)
        var unsafe *hit = self._probe_func(h, params, modes, n, ret, panics, pset, ns, raw, cc)
        if hit != &null {
            return hit
        }

        var unsafe *ft = self._alloc<FunctionPointerType>()
        ft->kind            = TypeKind::FunctionPointerType
        ft->range           = SourceRange::invalid()
        ft->return_type     = ret
        ft->is_unprototyped = false
        ft->is_raw          = raw
        ft->call_conv       = cc
        ft->init_annotations(unsafe &self._arena)
        ft->init_spans(unsafe &self._arena)

        if n > 0 {
            var unsafe **buf = self._alloc_array<unsafe *Type>(n)
            var unsafe *mb   = self._alloc_array<ParamMode>(n)
            for var i: usize = 0; i < n; ++i {
                buf[i] = (*params)[i]
                mb[i]  = self._mode_at(modes, i)
            }

            ft->params.from_raw(buf, n)
            ft->modes.from_raw(mb, n)
        } else {
            ft->params.from_raw(unsafe (&null as unsafe *(unsafe *Type)), 0)
            ft->modes.from_raw(&null, 0)
        }

        ft->canon_panics = panics
        if ns > 0 {
            var unsafe **sb = self._alloc_array<unsafe *Type>(ns)
            for var i: usize = 0; i < ns; ++i {
                sb[i] = (*pset)[i]
            }

            ft->panic_set.from_raw(sb, ns)
        } else {
            ft->panic_set.from_raw(unsafe (&null as unsafe *(unsafe *Type)), 0)
        }

        var unsafe *ty = unsafe (ft as unsafe *Type)
        ty->canonical = ty
        // The value is `__kairo_fn`'s three pointers (__f, __o, __t); the
        // raw one is the function pointer alone.
        ty->size_bits  = if (raw) => (self._ptr_bits) else => self._ptr_bits * 3
        ty->align_bits = self._ptr_bits
        if ret != &null {
            self._absorb_flags(ty, ret)
        }

        for var i: usize = 0; i < n; ++i {
            self._absorb_flags(ty, (*params)[i])
        }

        self._insert(h, ty)
        return ty
    }

    priv fn _mode_at(self, modes: unsafe *cxx::std::vector<ParamMode>, i: usize) -> ParamMode {
        if modes == &null {
            return ParamMode::Value
        }

        return (*modes)[i]
    }

    /// The canonical stand-in for a generic parameter. Uniqued on
    /// (owner decl, index) rather than on the name: two params named `T` in two
    /// different templates are different entities, and one param referred to by
    /// twenty spellings is one entity.
    pub fn generic_param(self, owner: unsafe *Decl, index: u32, is_pack: bool) -> unsafe *Type {
        if owner == &null {
            return &null
        }

        var h = canon_hash_u64(0, (TypeKind::GenericParamType as u8))
        h = canon_hash_ptr(h, unsafe (owner as unsafe *void))
        h = canon_hash_u64(h, index)

        var        lock = kairo::std::LockGuard(self._mu)
        var unsafe *hit = self._probe_gparam(h, owner, index)
        if hit != &null {
            return hit
        }

        var unsafe *gp = self._alloc<GenericParamType>()
        gp->kind        = TypeKind::GenericParamType
        gp->range       = SourceRange::invalid()
        gp->param_name  = &null // canonical form has no spelling; owner+index IS the identity.
        gp->param_index = index
        gp->is_pack     = is_pack
        gp->owner       = owner
        gp->init_annotations(unsafe &self._arena)
        gp->init_spans(unsafe &self._arena)

        gp->type_flags = FlagSet<Type::TypeFlags, u8>()
        gp->type_flags.set(Type::TypeFlags::IsDependent)
        gp->type_flags.set(Type::TypeFlags::IsInstantiationDependent)
        if is_pack {
            gp->type_flags.set(Type::TypeFlags::ContainsUnexpandedPack)
        }

        var unsafe *ty = unsafe (gp as unsafe *Type)
        ty->canonical = ty
        self._insert(h, ty)
        return ty
    }

    /// An associated type of \p base through interface instance \p iface
    /// (AssocType). Dependent by construction, whatever \p base is: even
    /// `record(Graph)`, a non-dependent record, stands for every conformer
    /// while it is the interface's Self.
    pub fn assoc(self,
                 base:  unsafe *Type,
                 iface: unsafe *Type,
                 assoc: unsafe *Decl,
                 args:  unsafe *cxx::std::vector<unsafe *Type> = &null) -> unsafe *Type {
        if base == &null || iface == &null || assoc == &null {
            return &null
        }

        var n: usize = 0
        if args != &null {
            n = args->size()
        }

        var h = canon_hash_u64(0, (TypeKind::AssocType as u8))
        h = canon_hash_ptr(h, unsafe (base as unsafe *void))
        h = canon_hash_ptr(h, unsafe (iface as unsafe *void))
        h = canon_hash_ptr(h, unsafe (assoc as unsafe *void))
        h = canon_hash_u64(h, n as u64)
        for var i: usize = 0; i < n; ++i {
            h = canon_hash_ptr(h, unsafe ((*args)[i] as unsafe *void))
        }

        var        lock = kairo::std::LockGuard(self._mu)
        var unsafe *b   = self._bucket(h)
        if b != &null {
            for var i: usize = 0; i < b->size(); ++i {
                var unsafe *c = (*b)[i]
                if c->kind != TypeKind::AssocType {
                    continue
                }

                var unsafe *a = cast<AssocType>(c)
                if a->base != base
                    || a->iface != iface
                    || a->assoc != assoc
                    || a->args.size() != n {
                    continue
                }

                var same = true
                for var k: usize = 0; k < n; ++k {
                    if a->args[k] != (*args)[k] {
                        same = false
                        break
                    }
                }

                if same {
                    return c
                }
            }
        }

        var unsafe *at = self._alloc<AssocType>()
        at->kind  = TypeKind::AssocType
        at->range = SourceRange::invalid()
        at->base  = base
        at->iface = iface
        at->assoc = assoc
        if n > 0 {
            var unsafe **buf = self._alloc_array<unsafe *Type>(n)
            for var i: usize = 0; i < n; ++i {
                buf[i] = (*args)[i]
            }

            at->args.from_raw(buf, n)
        } else {
            at->args.from_raw(unsafe (&null as unsafe *(unsafe *Type)), 0)
        }

        at->bounds.from_raw(unsafe (&null as unsafe *(unsafe *Type)), 0)
        at->bounds_state = 0
        at->init_annotations(unsafe &self._arena)
        at->init_spans(unsafe &self._arena)

        var unsafe *ty = unsafe (at as unsafe *Type)
        ty->canonical = ty
        self._absorb_flags(ty, base)
        self._absorb_flags(ty, iface)
        for var i: usize = 0; i < n; ++i {
            self._absorb_flags(ty, (*args)[i])
        }

        ty->type_flags.set(Type::TypeFlags::IsDependent)
        ty->type_flags.set(Type::TypeFlags::IsInstantiationDependent)
        self._insert(h, ty)
        return ty
    }

    /// Fill \p a's bound cache (AssocType::bounds) with \p bs. The store
    /// owns the storage; Substitution::bound_ifaces computes the list.
    pub fn set_assoc_bounds(self, a: unsafe *AssocType, const bs: cxx::std::vector<unsafe *Type>) {
        if a == &null {
            return
        }

        var lock = kairo::std::LockGuard(self._mu)
        // Readers take the list without the lock once the state reads 2
        // (Substitution::bound_ifaces): set once, never rewritten. Two TUs
        // that computed it side by side computed the same list.
        if a->bounds_state == 2 {
            return
        }

        var n = bs.size()
        if n > 0 {
            var unsafe **buf = self._alloc_array<unsafe *Type>(n)
            for var i: usize = 0; i < n; ++i {
                buf[i] = (bs)[i]
            }

            a->bounds.from_raw(buf, n)
        } else {
            a->bounds.from_raw(unsafe (&null as unsafe *(unsafe *Type)), 0)
        }

        cxx::std::atomic_thread_fence(cxx::std::memory_order_release)
        a->bounds_state = 2
    }

    /// An opaque C++ type, keyed by its spelling. Genuinely a black box:
    /// two FFI headers naming `std::FILE` denote the same thing, and Kairo has
    /// nothing else to compare.
    pub fn opaque(self, const spelling: string) -> unsafe *Type {
        var h = canon_hash_u64(0, (TypeKind::OpaqueFFIType as u8))
        var n = spelling.size()
        for var i: usize = 0; i < n; ++i {
            h = canon_hash_u64(h, (spelling[i]))
        }

        var        lock = kairo::std::LockGuard(self._mu)
        var unsafe *hit = self._probe_opaque(h, spelling)
        if hit != &null {
            return hit
        }

        var unsafe *ot = self._alloc<OpaqueFFIType>()
        ot->kind  = TypeKind::OpaqueFFIType
        ot->range = SourceRange::invalid()
        ot->name  = (h as u32)
        var unsafe *buf = self._alloc_array<u8>(n + 1)
        for var i: usize = 0; i < n; ++i {
            buf[i] = (spelling[i])
        }

        buf[n]     = (0)
        ot->sp     = unsafe (buf as kairo::std::ConstPtr<u8>)
        ot->sp_len = (n as u32)
        ot->init_annotations(unsafe &self._arena)
        ot->init_spans(unsafe &self._arena)

        var unsafe *ty = unsafe (ot as unsafe *Type)
        ty->canonical = ty
        self._insert(h, ty)
        return ty
    }

    /// # Identity

    /// The identity test Base.k defines, as a function. Qualifiers INCLUDED:
    /// they are in the key, so `const i32` and `i32` are not identical here.
    static fn identical(a: *Type?, b: *Type?) -> bool {
        if a == &null || b == &null {
            return false
        }

        var unsafe *ca = a->canonical
        var unsafe *cb = b->canonical
        if ca == &null || cb == &null {
            return false
        }

        return ca == cb
    }

    /// Identity with the TOP-LEVEL qualifiers of both sides ignored. What a
    /// shape query and parameter-level signature identity want; nothing else.
    static fn identical_unqualified(a: *Type?, b: *Type?) -> bool {
        if a == &null || b == &null {
            return false
        }

        var unsafe *ca = canon_unqual(a->canonical)
        var unsafe *cb = canon_unqual(b->canonical)
        if ca == &null || cb == &null {
            return false
        }

        return ca == cb
    }

    /// # Internals

    priv fn <T> _alloc(self) -> unsafe *T {
        var mem: unsafe *void = self._arena.alloc(sizeof(T), alignof(T))
        cxx::std::memset(mem, 0, sizeof(T))
        return unsafe (mem as unsafe *T)
    }

    priv fn <T> _alloc_array(self, n: usize) -> unsafe *T {
        if n == 0 {
            return &null
        }

        var mem: unsafe *void = self._arena.alloc(sizeof(T) * n, alignof(T))
        cxx::std::memset(mem, 0, sizeof(T) * n)
        return unsafe (mem as unsafe *T)
    }

    priv fn _insert(self, h: u64, ty: unsafe *Type) {
        self._table[CanonicalTypeStore::_key(h)].push_back(ty)
    }

    priv fn _bucket(self, h: u64) -> unsafe *cxx::std::vector<unsafe *Type> {
        var it = self._table.find(CanonicalTypeStore::_key(h))
        if it == self._table.end() {
            return &null
        }

        return unsafe &it->second
    }

    priv static inline fn _key(h: u64) -> u64 {
        return h >> 1
    }

    /// Dependence propagates UP: a composite is dependent iff a component is.
    /// Mirrors propagate_flags in Types.k, but reads through `canonical` since
    /// that is what a component is here.
    priv fn _absorb_flags(self, parent: unsafe *Type, child: unsafe *Type) {
        if child == &null {
            return
        }

        parent->type_flags.add_all(child->type_flags)
    }

    /// Shared body for the one-component kinds. Each has exactly one child
    /// slot at a different field name, so the probe and the fill switch on
    /// kind; everything else is identical.
    /// \param is_unsafe PointerType's key bit. Every other kind passes false,
    ///        which folds a constant into the hash and leaves their keys
    ///        unchanged relative to each other.
    priv fn _unary(self,
                   k:         TypeKind,
                   child:     unsafe *Type,
                   is_unsafe: bool = false) -> unsafe *Type {
        if child == &null {
            return &null
        }

        var h = canon_hash_u64(0, (k as u8))
        h = canon_hash_ptr(h, unsafe (child as unsafe *void))
        h = canon_hash_u64(h, if (is_unsafe) => (1 as u64) else => (0))

        var        lock = kairo::std::LockGuard(self._mu)
        var unsafe *b   = self._bucket(h)
        if b != &null {
            for var i: usize = 0; i < b->size(); ++i {
                var unsafe *c = (*b)[i]
                if c->kind != k {
                    continue
                }

                if self._unary_child(c) != child {
                    continue
                }

                // Two pointers to the same pointee are still two types when
                // they disagree on safety; the hash separates them, this is
                // what keeps a bucket collision from merging them anyway.
                if k == TypeKind::PointerType {
                    if cast<PointerType>(c)->is_unsafe != is_unsafe {
                        continue
                    }
                }

                if k == TypeKind::NullableType {
                    Self::_seen(cast<NullableType>(c))
                }

                return c
            }
        }

        var ty: unsafe *Type = &null
        match k {
            case TypeKind::PointerType {
                var unsafe *n = self._alloc<PointerType>()
                n->pointee     = child
                n->length      = 0
                n->is_unsafe   = is_unsafe
                ty             = unsafe (n as unsafe *Type)
                ty->size_bits  = self._ptr_bits
                ty->align_bits = self._ptr_bits
            } case TypeKind::NullableType {
                var unsafe *n = self._alloc<NullableType>()
                n->inner     = child
                n->lowered   = &null
                n->seen_rank = u64::MAX // _alloc zero-fills; no initializer runs.
                Self::_seen(n)
                ty = unsafe (n as unsafe *Type)
                self._unlowered_nullables += 1
            } case TypeKind::VectorType {
                var unsafe *n = self._alloc<VectorType>()
                n->element = child
                ty         = unsafe (n as unsafe *Type)
            } case TypeKind::SetType {
                var unsafe *n = self._alloc<SetType>()
                n->element = child
                ty         = unsafe (n as unsafe *Type)
            } case TypeKind::CXXLValueRefType {
                var unsafe *n = self._alloc<CXXLValueRefType>()
                n->referee = child
                ty         = unsafe (n as unsafe *Type)
            } case TypeKind::CXXRValueRefType {
                var unsafe *n = self._alloc<CXXRValueRefType>()
                n->referee = child
                ty         = unsafe (n as unsafe *Type)
            } default {
                return &null
            }
        }

        ty->kind  = k
        ty->range = SourceRange::invalid()
        ty->init_annotations(unsafe &self._arena)
        ty->init_spans(unsafe &self._arena)
        ty->canonical = ty
        self._absorb_flags(ty, child)
        self._insert(h, ty)
        return ty
    }

    /// The single child of a one-component canonical, or null for other kinds.
    /// NullableType::seen_rank: the calling thread's group, or 0 outside
    /// any group's Sema. Under the write lock.
    priv static fn _seen(n: unsafe *NullableType) {
        var r = *kairo::sema_mint_rank()
        if r == u64::MAX {
            r = 0
        }

        if r < n->seen_rank {
            n->seen_rank = r
        }
    }

    priv fn _unary_child(self, t: unsafe *Type) -> unsafe *Type {
        if t == &null {
            return &null
        }

        match t->kind {
            case TypeKind::PointerType {
                return cast<PointerType>(t)->pointee
            } case TypeKind::NullableType {
                return cast<NullableType>(t)->inner
            } case TypeKind::VectorType {
                return cast<VectorType>(t)->element
            } case TypeKind::SetType {
                return cast<SetType>(t)->element
            } case TypeKind::CXXLValueRefType {
                return cast<CXXLValueRefType>(t)->referee
            } case TypeKind::CXXRValueRefType {
                return cast<CXXRValueRefType>(t)->referee
            } default {
                return &null
            }
        }
    }

    /// ## probes (called under the write lock)

    priv fn _probe_qualified(self, h: u64, inner: unsafe *Type, quals: u8) -> unsafe *Type {
        var unsafe *b = self._bucket(h)
        if b == &null {
            return &null
        }

        for var i: usize = 0; i < b->size(); ++i {
            var unsafe *c = (*b)[i]
            if c->kind != TypeKind::QualifiedType {
                continue
            }

            var unsafe *q = cast<QualifiedType>(c)
            if q->inner == inner && q->quals == quals {
                return c
            }
        }

        return &null
    }

    priv fn _probe_record(self,
                          h:     u64,
                          decl:  unsafe *Decl,
                          args:  unsafe *cxx::std::vector<unsafe *Type>,
                          n:     usize,
                          outer: unsafe *Type) -> unsafe *Type {
        var unsafe *b = self._bucket(h)
        if b == &null {
            return &null
        }

        for var i: usize = 0; i < b->size(); ++i {
            var unsafe *c = (*b)[i]
            if c->kind != TypeKind::RecordType {
                continue
            }

            var unsafe *r = cast<RecordType>(c)
            if r->decl != decl {
                continue
            }

            if r->outer != outer {
                continue
            }

            if r->args.size() != n {
                continue
            }

            var same = true
            for var j: usize = 0; j < n; ++j {
                if r->args[j] != (*args)[j] {
                    same = false
                    break
                }
            }

            if same {
                return c
            }
        }

        return &null
    }

    priv fn _probe_map(self, h: u64, key: unsafe *Type, value: unsafe *Type) -> unsafe *Type {
        var unsafe *b = self._bucket(h)
        if b == &null {
            return &null
        }

        for var i: usize = 0; i < b->size(); ++i {
            var unsafe *c = (*b)[i]
            if c->kind != TypeKind::MapType {
                continue
            }

            var unsafe *m = cast<MapType>(c)
            if m->key == key && m->value == value {
                return c
            }
        }

        return &null
    }

    priv fn _probe_array(self, h: u64, element: unsafe *Type, extent: u64) -> unsafe *Type {
        var unsafe *b = self._bucket(h)
        if b == &null {
            return &null
        }

        for var i: usize = 0; i < b->size(); ++i {
            var unsafe *c = (*b)[i]
            if c->kind != TypeKind::FixedArrayType {
                continue
            }

            var unsafe *a = cast<FixedArrayType>(c)
            if a->element != element {
                continue
            }

            if a->extent_param != &null || a->is_incomplete {
                continue
            }

            if (a->size_bits as u64) == extent {
                return c
            }
        }

        return &null
    }

    /// \p t's twin with \p raw set: the same signature and effect, the
    /// other spelling. \p t itself when it is not a canonical `fn` type or
    /// already is that kind.
    pub fn fn_with_raw(self, t: unsafe *Type, raw: bool) -> unsafe *Type {
        if t == &null || t->kind != TypeKind::FunctionPointerType {
            return t
        }

        var unsafe *f = cast<FunctionPointerType>(t)
        // A convention's type is always raw: it has no `fn` value twin.
        if f->is_unprototyped || f->is_raw == raw || f->call_conv != 0 {
            return t
        }

        var ps = cxx::std::vector<unsafe *Type>()
        var ms = cxx::std::vector<ParamMode>()
        for var i: usize = 0; i < f->params.size(); ++i {
            ps.push_back(f->params[i])
            ms.push_back(f->modes[i])
        }

        var pset = cxx::std::vector<unsafe *Type>()
        for var i: usize = 0; i < f->panic_set.size(); ++i {
            pset.push_back(f->panic_set[i])
        }

        return self.func(
            unsafe &ps,
            unsafe &ms,
            f->return_type,
            f->canon_panics,
            unsafe &pset,
            raw,
            f->call_conv,
        )
    }

    priv fn _probe_func(self,
                        h:      u64,
                        params: unsafe *cxx::std::vector<unsafe *Type>,
                        modes:  unsafe *cxx::std::vector<ParamMode>,
                        n:      usize,
                        ret:    unsafe *Type,
                        panics: bool,
                        pset:   unsafe *cxx::std::vector<unsafe *Type>,
                        ns:     usize,
                        raw:    bool,
                        cc:     u8) -> unsafe *Type {
        var unsafe *b = self._bucket(h)
        if b == &null {
            return &null
        }

        for var i: usize = 0; i < b->size(); ++i {
            var unsafe *c = (*b)[i]
            if c->kind != TypeKind::FunctionPointerType {
                continue
            }

            var unsafe *f = cast<FunctionPointerType>(c)
            if f->return_type != ret {
                continue
            }

            if f->params.size() != n {
                continue
            }

            if f->canon_panics != panics {
                continue
            }

            if f->is_raw != raw {
                continue
            }

            if f->call_conv != cc {
                continue
            }

            if f->panic_set.size() != ns {
                continue
            }

            var same = true
            for var j: usize = 0; j < n; ++j {
                if f->params[j] != (*params)[j] {
                    same = false
                    break
                }

                if f->modes[j] != self._mode_at(modes, j) {
                    same = false
                    break
                }
            }

            for var j: usize = 0; same && j < ns; ++j {
                if f->panic_set[j] != (*pset)[j] {
                    same = false
                }
            }

            if same {
                return c
            }
        }

        return &null
    }

    priv fn _probe_gparam(self, h: u64, owner: unsafe *Decl, index: u32) -> unsafe *Type {
        var unsafe *b = self._bucket(h)
        if b == &null {
            return &null
        }

        for var i: usize = 0; i < b->size(); ++i {
            var unsafe *c = (*b)[i]
            if c->kind != TypeKind::GenericParamType {
                continue
            }

            var unsafe *g = cast<GenericParamType>(c)
            if g->owner == owner && g->param_index == index {
                return c
            }
        }

        return &null
    }

    /// C++'s `std::nullptr_t`, the one opaque `&null` takes when passed to C++.
    /// An opaque is keyed by its spelling (never a per-file imm), so a
    /// header's `nullptr_t` and the one a call deduces are one type.
    pub fn nullptr_t(self) -> unsafe *Type {
        {
            var lock = kairo::std::LockGuard(self._mu)
            if self._nullptr_t != &null {
                return self._nullptr_t
            }
        }

        var unsafe *t   = self.opaque("std::nullptr_t")
        var        lock = kairo::std::LockGuard(self._mu)
        if self._nullptr_t == &null {
            self._nullptr_t = t
        }

        return self._nullptr_t
    }

    priv fn _probe_opaque(self, h: u64, const spelling: string) -> unsafe *Type {
        var unsafe *b = self._bucket(h)
        if b == &null {
            return &null
        }

        for var i: usize = 0; i < b->size(); ++i {
            var unsafe *c = (*b)[i]
            if c->kind != TypeKind::OpaqueFFIType {
                continue
            }

            if cast<OpaqueFFIType>(c)->text() == spelling {
                return c
            }
        }

        return &null
    }

    /// ## nullable lowering (writer: NullableTypeLowering)

    /// Every canonical `T?` interned so far, by any TU. A snapshot: the
    /// caller lowers each after the lock is released, since minting the
    /// record re-enters this table.
    pub fn nullables(self) -> cxx::std::vector<unsafe *NullableType> {
        var out  = cxx::std::vector<unsafe *NullableType>()
        var lock = kairo::std::LockGuard(self._mu)
        for var it = self._table.begin(); it != self._table.end(); ++it {
            for var i: usize = 0; i < it->second.size(); ++i {
                var unsafe *c = it->second[i]
                if c->kind == TypeKind::NullableType {
                    out.push_back(cast<NullableType>(c))
                }
            }
        }

        return out
    }

    /// Record \p r as what \p n is to C++, once. TUs lower in parallel and
    /// all reach the same interned record, so a second writer is a no-op,
    /// never a different answer.
    pub fn set_nullable_lowered(self, n: unsafe *NullableType, r: unsafe *Type) {
        if n == &null || r == &null {
            return
        }

        var lock = kairo::std::LockGuard(self._mu)
        if n->lowered == &null {
            n->lowered = r
            if self._unlowered_nullables > 0 {
                self._unlowered_nullables -= 1
            }
        }
    }

    /// Whether some interned `T?` still has no record. False means
    /// nullables() would hand back only types the caller skips.
    pub fn has_unlowered_nullables(self) -> bool {
        var lock = kairo::std::LockGuard(self._mu)
        return self._unlowered_nullables > 0
    }

    /// ## stats (dumps only)

    fn interned_count(self) -> usize {
        var n = self._builtins.size()
        for var it = self._table.begin(); it != self._table.end(); ++it {
            n += it->second.size()
        }

        return n
    }
}
