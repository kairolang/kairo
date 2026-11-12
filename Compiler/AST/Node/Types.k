/// --- The Kairo Project ----------------------------- AST/Node/Types.k --- ///
///
///   The syntactic type AST nodes: pointers, nullable, tuple, array, function
///   pointer, generic parameter, chain and the other non-canonical types.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
//  TypeKind::RecoveryType                                                   ///
//  TypeKind::ChainType                                                      ///
//  TypeKind::GenericParamType                                               ///
//  TypeKind::SubstGenericParamType                                          ///
//  TypeKind::TypeOfType                                                     ///
//  TypeKind::VariadicPackType                                               ///
//  TypeKind::PackExpansionType                                              ///
//  TypeKind::PointerType                                                    ///
//  TypeKind::NullableType                                                   ///
//  TypeKind::TupleType                                                      ///
//  TypeKind::FixedArrayType                                                 ///
//  TypeKind::VectorType                                                     ///
//  TypeKind::MapType                                                        ///
//  TypeKind::SetType                                                        ///
//  TypeKind::SelfType                                                       ///
//  TypeKind::FunctionPointerType                                            ///
//  TypeKind::InferredType                                                   ///
//  TypeKind::CXXLValueRefType                                               ///
//  TypeKind::CXXRValueRefType                                               ///
//  TypeKind::OpaqueFFIType                                                  ///
//  TypeKind::TypeExpr                                                       ///

ffi "c++" import "Native/Types.hh"

import AST::ASTSupport::{
    FrozenList,
    create_empty_frozen_list,
}
import AST::Context::ASTContext::ASTContext
import AST::Kind::TypeKind::TypeKind
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::PrimaryExpressions::NamedIdentExpr
import AST::ParamMode::ParamMode
import Location::SourceRange::SourceRange
import Support::FlagSet::FlagSet
import Token::TokenKind::TokenKind

///
///  Helper propagate type_flags from children into a parent node.
///  Call this after setting all child type pointers on a newly created node.
///
pub fn propagate_flags(parent: unsafe *Type, child: unsafe *Type) {
    parent->type_flags.add_all(child->type_flags)
}

///
///  GenericParamType
///  T inside fn foo<T>(x: T) unresolved generic parameter.
///  Always dependent. Sema substitutes at instantiation.
///
pub class GenericParamType derives Type {
    /// The GenericParamDecl this refers to. Null on parser-built nodes
    /// (`...T` in _parse_variadic_type, where the binding is not yet known);
    /// ALWAYS set on canonical nodes from CanonicalTypeStore, which unique on
    /// (owner, param_index). *Decl: the owner is any generic decl kind.
    pub var owner:       unsafe *Decl           = &null
    pub var param_name:  unsafe *NamedIdentExpr ///< The declared param name, e.g. T.
    pub var param_index: u32 ///< Index in the generic param list.
    pub var is_pack:     bool ///< True if this is a variadic pack param ...T.


    pub static fn create(ctx:         *ASTContext,
                         range:       SourceRange,
                         param_name:  unsafe *NamedIdentExpr,
                         param_index: u32,
                         is_pack:     bool) -> unsafe *GenericParamType {
        var unsafe *node = ctx->alloc<GenericParamType>()
        node->kind  = TypeKind::GenericParamType
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        node->param_name  = param_name
        node->param_index = param_index
        node->is_pack     = is_pack
        /// always dependent
        node->type_flags = FlagSet<Type::TypeFlags, u8>()
        node->type_flags.set(Type::TypeFlags::IsDependent)
        node->type_flags.set(Type::TypeFlags::IsInstantiationDependent)
        if is_pack {
            node->type_flags.set(Type::TypeFlags::ContainsUnexpandedPack)
        }

        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *GenericParamType {
        var unsafe *node = ctx->alloc<GenericParamType>()
        node->kind          = TypeKind::RecoveryType
        node->recovery_kind = TypeKind::GenericParamType
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Type) -> bool {
        return ptr->kind == TypeKind::GenericParamType
    }

    /* OVERRIDE */
    static fn type_kind() -> TypeKind {
        return TypeKind::GenericParamType
    }
}

///
///  SubstGenericParamType
///  Post-substitution wrapper: records that this type resulted from
///  substituting a concrete type for a generic param. Sema wraps the
///  replacement so diagnostics can report which param was substituted.
///  Canonical points to the replacement type directly.
///
pub class SubstGenericParamType derives Type {
    pub var original:    *GenericParamType ///< The param that was substituted.
    pub var replacement: unsafe *Type      ///< The concrete type substituted in.

    static fn create(ctx:         *ASTContext,
                     range:       SourceRange,
                     original:    *GenericParamType,
                     replacement: unsafe *Type) -> unsafe *SubstGenericParamType {
        var unsafe *node = ctx->alloc<SubstGenericParamType>()
        node->kind  = TypeKind::SubstGenericParamType
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        node->original    = original
        node->replacement = replacement
        node->canonical = if (replacement->canonical != &null) => (replacement->canonical)
                          else => replacement
        propagate_flags(node, replacement)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *SubstGenericParamType {
        var unsafe *node = ctx->alloc<SubstGenericParamType>()
        node->kind          = TypeKind::RecoveryType
        node->recovery_kind = TypeKind::SubstGenericParamType
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Type) -> bool {
        return ptr->kind == TypeKind::SubstGenericParamType
    }

    /* OVERRIDE */
    static fn type_kind() -> TypeKind {
        return TypeKind::SubstGenericParamType
    }
}

///
///  TypeOfType
///  typeof(foo()) in type position.
///  Sema evaluates expr and sets canonical to the resolved type.
///
pub class TypeOfType derives Type {
    pub var expr:     unsafe *Expr         ///< The expression whose type is queried.
    pub var resolved: *Type?       = &null ///< Set by sema after expr type is known.

    pub static fn create(ctx:   *ASTContext,
                         range: SourceRange,
                         expr:  unsafe *Expr) -> unsafe *TypeOfType {
        var unsafe *node = ctx->alloc<TypeOfType>()
        node->kind  = TypeKind::TypeOfType
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        node->expr     = expr
        node->resolved = &null
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *TypeOfType {
        var unsafe *node = ctx->alloc<TypeOfType>()
        node->kind          = TypeKind::RecoveryType
        node->recovery_kind = TypeKind::TypeOfType
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Type) -> bool {
        return ptr->kind == TypeKind::TypeOfType
    }

    /* OVERRIDE */
    static fn type_kind() -> TypeKind {
        return TypeKind::TypeOfType
    }
}

///
///  VariadicPackType
///  ...T at declaration site the bare pack parameter in a generic signature.
///  Always sets IsDependent and ContainsUnexpandedPack.
///  This is the declaration-site node; PackExpansionType is the use-site node.
///
pub class VariadicPackType derives Type {
    pub var param: unsafe *GenericParamType ///< The pack param this refers to.

    pub static fn create(ctx:   *ASTContext,
                         range: SourceRange,
                         param: unsafe *GenericParamType) -> unsafe *VariadicPackType {
        var unsafe *node = ctx->alloc<VariadicPackType>()
        node->kind  = TypeKind::VariadicPackType
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        node->param      = param
        node->type_flags = FlagSet<Type::TypeFlags, u8>()
        node->type_flags.set(Type::TypeFlags::IsDependent)
        node->type_flags.set(Type::TypeFlags::IsInstantiationDependent)
        node->type_flags.set(Type::TypeFlags::ContainsUnexpandedPack)
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *VariadicPackType {
        var unsafe *node = ctx->alloc<VariadicPackType>()
        node->kind          = TypeKind::RecoveryType
        node->recovery_kind = TypeKind::VariadicPackType
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Type) -> bool {
        return ptr->kind == TypeKind::VariadicPackType
    }

    /* OVERRIDE */
    static fn type_kind() -> TypeKind {
        return TypeKind::VariadicPackType
    }
}

///
///  PackExpansionType
///  pattern... use-site expansion of a pack in type position.
///  e.g. std::vector<Ts>... where pattern is std::vector<Ts>.
///  Clears ContainsUnexpandedPack on itself (expansion consumed it)
///  but remains IsDependent since result still varies per instantiation.
///
pub class PackExpansionType derives Type {
    pub var pattern: unsafe *Type ///< The type pattern being expanded.

    pub static fn create(ctx:     *ASTContext,
                         range:   SourceRange,
                         pattern: unsafe *Type) -> unsafe *PackExpansionType {
        var unsafe *node = ctx->alloc<PackExpansionType>()
        node->kind  = TypeKind::PackExpansionType
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        node->pattern = pattern
        /// propagate flags from pattern then clear unexpanded pack
        /// this node IS the expansion, pack is no longer unexpanded here
        propagate_flags(node, pattern)
        node->type_flags.clear(Type::TypeFlags::ContainsUnexpandedPack)
        /// still dependent
        node->type_flags.set(Type::TypeFlags::IsDependent)
        node->type_flags.set(Type::TypeFlags::IsInstantiationDependent)
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *PackExpansionType {
        var unsafe *node = ctx->alloc<PackExpansionType>()
        node->kind          = TypeKind::RecoveryType
        node->recovery_kind = TypeKind::PackExpansionType
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Type) -> bool {
        return ptr->kind == TypeKind::PackExpansionType
    }

    /* OVERRIDE */
    static fn type_kind() -> TypeKind {
        return TypeKind::PackExpansionType
    }
}

///
///  PointerType
///  *T fat pointer. length set by sema if size is statically known.
///
pub class PointerType derives Type {
    pub var pointee: unsafe *Type
    pub var length:  usize        = 0 ///< Statically known length. 0 = unknown.

    /// `unsafe *T` is a DIFFERENT TYPE from `*T`, not the same type wearing a
    /// qualifier: the conversion lattice refuses to cross between them and the
    /// `as unsafe *` ladder exists precisely to cross it deliberately. That
    /// makes safety part of the canonical identity, so it lives in a field the
    /// store can key on -- the IsUnsafe bit in `flags` stays too, but only the
    /// printer reads it.
    pub var is_unsafe: bool = false

    pub static fn create(ctx:       *ASTContext,
                         range:     SourceRange,
                         pointee:   unsafe *Type,
                         is_unsafe: bool = false) -> unsafe *PointerType {
        var unsafe *node = ctx->alloc<PointerType>()
        node->kind  = TypeKind::PointerType
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        node->pointee   = pointee
        node->length    = 0
        node->is_unsafe = is_unsafe
        propagate_flags(node, pointee)
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *PointerType {
        var unsafe *node = ctx->alloc<PointerType>()
        node->kind          = TypeKind::RecoveryType
        node->recovery_kind = TypeKind::PointerType
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Type) -> bool {
        return ptr->kind == TypeKind::PointerType
    }

    /* OVERRIDE */
    static fn type_kind() -> TypeKind {
        return TypeKind::PointerType
    }
}

///
///  NullableType
///  T? lowered to std::Optional<T> by sema.
///
pub class NullableType derives Type {
    pub var inner: unsafe *Type
    /// On a canonical: the `::builtin::Nullable<inner>` record this `T?` IS
    /// to C++, or null before NullableTypeLowering. Every pass up to that
    /// one asks the NullableType (Compiler/Spec/Nullables.md#the-canonical-type-and-its-record); codegen spells and plans
    /// the record instead. A slot rather than a rewrite: canonicals are
    /// build-wide and interned, and `Box<i32?>`'s instance key holds this
    /// node. Written once, through CanonicalTypes::set_nullable_lowered.
    pub var lowered: unsafe *Type = &null
    /// On a canonical: the earliest import group (its rank in the
    /// one-thread order, InstantiationRegistry's sema_mint_rank) that
    /// interned it; 0 before Sema. NullableTypeLowering lowers every `T?`
    /// interned so far, build-wide, so a TU lowers only the ones a
    /// one-thread run would have interned by then: TUs later in the order
    /// intern theirs on other threads, ahead of it.
    pub var seen_rank: u64 = u64::MAX

    pub static fn create(ctx:   *ASTContext,
                         range: SourceRange,
                         inner: unsafe *Type) -> unsafe *NullableType {
        var unsafe *node = ctx->alloc<NullableType>()
        node->kind  = TypeKind::NullableType
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        node->inner = inner
        propagate_flags(node, inner)
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *NullableType {
        var unsafe *node = ctx->alloc<NullableType>()
        node->kind          = TypeKind::RecoveryType
        node->recovery_kind = TypeKind::NullableType
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Type) -> bool {
        return ptr->kind == TypeKind::NullableType
    }

    /* OVERRIDE */
    static fn type_kind() -> TypeKind {
        return TypeKind::NullableType
    }
}

///
///  TupleType
///  (i32, str, f64)
///
pub class TupleType derives Type {
    pub var elements: FrozenList<unsafe *Type>

    pub static fn create(ctx: *ASTContext, range: SourceRange) -> unsafe *TupleType {
        var unsafe *node = ctx->alloc<TupleType>()
        node->kind  = TypeKind::TupleType
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)

        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *TupleType {
        var unsafe *node = ctx->alloc<TupleType>()
        node->kind          = TypeKind::RecoveryType
        node->recovery_kind = TypeKind::TupleType
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Type) -> bool {
        return ptr->kind == TypeKind::TupleType
    }

    /* OVERRIDE */
    static fn type_kind() -> TypeKind {
        return TypeKind::TupleType
    }
}

///
///  FixedArrayType
///  [i32; 6] fixed size. [i32;] incomplete (FFI/C interop only),
///  indicated by is_incomplete = true and size_expr = null.
///
pub class FixedArrayType derives Type {
    pub var element:       unsafe *Type
    pub var size_expr:     unsafe *Expr ///< Null if is_incomplete.
    pub var is_incomplete: bool         ///< True for C-style int buf[].
    /// CANONICAL only: the generic value parameter the extent is (`[i32; N]`
    /// in `class <eval N: usize>`), a GenericParamType; null when the
    /// extent is the value in size_bits. Substituted per instance (Compiler/Spec/Eval.md#generic-value-parameters).
    pub var extent_param: unsafe *Type

    pub static fn create(ctx:       *ASTContext,
                         range:     SourceRange,
                         element:   unsafe *Type,
                         size_expr: unsafe *Expr) -> unsafe *FixedArrayType {
        var unsafe *node = ctx->alloc<FixedArrayType>()
        node->kind  = TypeKind::FixedArrayType
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        node->element       = element
        node->size_expr     = size_expr
        node->is_incomplete = false
        node->extent_param  = &null
        propagate_flags(node, element)
        return node
    }

    pub static fn create_incomplete(ctx:     *ASTContext,
                                    range:   SourceRange,
                                    element: unsafe *Type) -> unsafe *FixedArrayType {
        var unsafe *node = ctx->alloc<FixedArrayType>()
        node->kind  = TypeKind::FixedArrayType
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        node->element       = element
        node->size_expr     = &null
        node->is_incomplete = true
        node->extent_param  = &null
        propagate_flags(node, element)
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *FixedArrayType {
        var unsafe *node = ctx->alloc<FixedArrayType>()
        node->kind          = TypeKind::RecoveryType
        node->recovery_kind = TypeKind::FixedArrayType
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Type) -> bool {
        return ptr->kind == TypeKind::FixedArrayType
    }

    /* OVERRIDE */
    static fn type_kind() -> TypeKind {
        return TypeKind::FixedArrayType
    }
}

///
///  VectorType
///  [i32] growable. Lowered to std::vector<T> or equivalent.
///
pub class VectorType derives Type {
    pub var element: unsafe *Type

    pub static fn create(ctx:     *ASTContext,
                         range:   SourceRange,
                         element: unsafe *Type) -> unsafe *VectorType {
        var unsafe *node = ctx->alloc<VectorType>()
        node->kind  = TypeKind::VectorType
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        node->element = element
        propagate_flags(node, element)
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *VectorType {
        var unsafe *node = ctx->alloc<VectorType>()
        node->kind          = TypeKind::RecoveryType
        node->recovery_kind = TypeKind::VectorType
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Type) -> bool {
        return ptr->kind == TypeKind::VectorType
    }

    /* OVERRIDE */
    static fn type_kind() -> TypeKind {
        return TypeKind::VectorType
    }
}

///
///  MapType
///  {str: i32}
///
pub class MapType derives Type {
    pub var key:   unsafe *Type
    pub var value: unsafe *Type

    pub static fn create(ctx:   *ASTContext,
                         range: SourceRange,
                         key:   unsafe *Type,
                         value: unsafe *Type) -> unsafe *MapType {
        var unsafe *node = ctx->alloc<MapType>()
        node->kind  = TypeKind::MapType
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        node->key   = key
        node->value = value
        propagate_flags(node, key)
        propagate_flags(node, value)
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *MapType {
        var unsafe *node = ctx->alloc<MapType>()
        node->kind          = TypeKind::RecoveryType
        node->recovery_kind = TypeKind::MapType
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Type) -> bool {
        return ptr->kind == TypeKind::MapType
    }

    /* OVERRIDE */
    static fn type_kind() -> TypeKind {
        return TypeKind::MapType
    }
}

///
///  SetType
///  {i32}
///
pub class SetType derives Type {
    pub var element: unsafe *Type

    pub static fn create(ctx:     *ASTContext,
                         range:   SourceRange,
                         element: unsafe *Type) -> unsafe *SetType {
        var unsafe *node = ctx->alloc<SetType>()
        node->kind  = TypeKind::SetType
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        node->element = element
        propagate_flags(node, element)
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *SetType {
        var unsafe *node = ctx->alloc<SetType>()
        node->kind          = TypeKind::RecoveryType
        node->recovery_kind = TypeKind::SetType
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Type) -> bool {
        return ptr->kind == TypeKind::SetType
    }

    /* OVERRIDE */
    static fn type_kind() -> TypeKind {
        return TypeKind::SetType
    }
}

///
///  SelfType
///  Self inside class/interface bodies. Sema resolves to the implementing type.
///  Canonical set by sema to the enclosing type.
///
pub class SelfType derives Type {
    pub static fn create(ctx: unsafe *ASTContext, range: SourceRange) -> unsafe *SelfType {
        var unsafe *node = ctx->alloc<SelfType>()
        node->kind  = TypeKind::SelfType
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        /// SelfType is instantiation-dependent inside generic types
        node->type_flags = FlagSet<Type::TypeFlags, u8>()
        node->type_flags.set(Type::TypeFlags::IsInstantiationDependent)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *SelfType {
        var unsafe *node = ctx->alloc<SelfType>()
        node->kind          = TypeKind::RecoveryType
        node->recovery_kind = TypeKind::SelfType
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Type) -> bool {
        return ptr->kind == TypeKind::SelfType
    }

    /* OVERRIDE */
    static fn type_kind() -> TypeKind {
        return TypeKind::SelfType
    }
}

///
///  FunctionPointerType
///  fn(i32, str) -> bool | fn(@inout i32, @move Foo) -> void
///  is_unprototyped = true for C headers with no param info: int foo()
///
pub class FunctionPointerType derives Type {
    pub var params:          FrozenList<unsafe *Type>
    pub var return_type:     unsafe *Type
    pub var is_unprototyped: bool                     ///< True for C-style no-proto fn imports.
    /// `unsafe fn(A) -> R`: the plain function pointer `R(*)(A)`, which no
    /// capturing closure can be, instead of the `fn` value (`__kairo_fn`)
    /// that holds either. In the canonical key (CanonicalTypeStore::func).
    /// Imported C/C++ function pointers are raw (TypeImport), and so are the
    /// `fn` parameters and result of an `ffi "c"` function (TypeResolve).
    pub var is_raw: bool
    /// `fn(A) @preserve_most -> R`: the calling convention, as
    /// FunctionDecl::call_conv (0 the default). In the canonical key, and a
    /// type with one is always raw: a closure cannot carry a convention, so
    /// only a named function can be its value.
    pub var call_conv: u8
    /// Per-parameter passing mode, PARALLEL to `params` (same count, same
    /// order). In the canonical key: `fn(@inout i32)` and `fn(i32)` are two
    /// canonicals (CanonicalTypeStore::func). Populated by whoever populates
    /// `params` -- the parser via from_buf (even when empty), the store via
    /// from_raw. A count mismatch is an ICE in TypeResolution.
    pub var modes: FrozenList<ParamMode>
    /// `fn(i32) panic(E1, E2) -> T`: the declared set, as written (Compiler/Spec/Panic.md
    /// §2.2). Empty for a bare `panic` qualifier and for no `panic` at all.
    /// Each element resolves like a parameter type, and a poisoned one
    /// poisons this node. On a CANONICAL node it is the canonical set
    /// (each type once, in the one order), and part of the key with
    /// `canon_panics`: two `fn` types that differ in their sets are two
    /// types, converted by subset (Conversion).
    pub var panic_set: FrozenList<unsafe *Type>
    /// A CANONICAL fn type panics (with `panic_set`, which a bare `panic`
    /// leaves empty). A syntax node says so with its `panic` qualifier
    /// (is_panic()) instead; this field is the store's.
    pub var canon_panics: bool = false
    /// On a CANONICAL node that panics with a set: what a value of this
    /// type returns in C++, `Panic<R, E...>` (Compiler/Spec/Panic.md#paniclowering), so the value
    /// is `__kairo_fn<Panic<R, E...>(A...)>`. Formed once, by the first
    /// PanicLowering to meet the type (types are shared by every TU, and
    /// the form is canonical, so every TU forms the same one). Null
    /// otherwise; CXXSpell spells `return_type` then.
    pub var panic_result: unsafe *Type = &null

    pub static fn create(ctx:         *ASTContext,
                         range:       SourceRange,
                         return_type: unsafe *Type) -> unsafe *FunctionPointerType {
        var unsafe *node = ctx->alloc<FunctionPointerType>()
        node->kind  = TypeKind::FunctionPointerType
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        node->return_type     = return_type
        node->is_unprototyped = false
        node->is_raw          = false
        node->call_conv       = 0
        if return_type != &null {
            propagate_flags(node, return_type)
        }

        return node
    }

    static fn create_unprototyped(ctx:   *ASTContext,
                                  range: SourceRange) -> unsafe *FunctionPointerType {
        var unsafe *node = ctx->alloc<FunctionPointerType>()
        node->kind  = TypeKind::FunctionPointerType
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        node->is_unprototyped = true
        node->is_raw          = false
        node->call_conv       = 0
        return node
    }

    pub static fn create_error(ctx:   *ASTContext,
                               range: SourceRange) -> unsafe *FunctionPointerType {
        var unsafe *node = ctx->alloc<FunctionPointerType>()
        node->kind          = TypeKind::RecoveryType
        node->recovery_kind = TypeKind::FunctionPointerType
        node->range         = range
        node->is_raw        = false
        node->call_conv     = 0
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Type) -> bool {
        return ptr->kind == TypeKind::FunctionPointerType
    }

    /* OVERRIDE */
    static fn type_kind() -> TypeKind {
        return TypeKind::FunctionPointerType
    }
}

///
///  InferredType
///  _ or omitted annotation. Sema assigns concrete type by solving constraints.
///  Each node carries a unique infer_id for the constraint solver.
///
pub class InferredType derives Type {
    pub var infer_id: u32 ///< Unique ID assigned by parser/sema for solver tracking.

    pub static fn create(ctx:      *ASTContext,
                         range:    SourceRange,
                         infer_id: u32) -> unsafe *InferredType {
        var unsafe *node = ctx->alloc<InferredType>()
        node->kind  = TypeKind::InferredType
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        node->infer_id = infer_id
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *InferredType {
        var unsafe *node = ctx->alloc<InferredType>()
        node->kind          = TypeKind::RecoveryType
        node->recovery_kind = TypeKind::InferredType
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Type) -> bool {
        return ptr->kind == TypeKind::InferredType
    }

    /* OVERRIDE */
    static fn type_kind() -> TypeKind {
        return TypeKind::InferredType
    }
}

///
///  CXXLValueRefType
///  T& imported from C++ headers. Sema treats as a reference, not a pointer.
///  const T& is a reference whose referee is const T; the const is on the
///  referee's canonical, never here.
///
pub class CXXLValueRefType derives Type {
    pub var referee: unsafe *Type
    /// Written `ffi::ref<T>` / `ffi::mref<T>` in Kairo source (P872), not
    /// imported: the printer spells it back, FfiRefReturnCheck judges where.
    pub var ffi_spelled: bool = false

    pub static fn create(ctx:     *ASTContext,
                         range:   SourceRange,
                         referee: unsafe *Type) -> unsafe *CXXLValueRefType {
        var unsafe *node = ctx->alloc<CXXLValueRefType>()
        node->kind  = TypeKind::CXXLValueRefType
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        node->referee = referee
        propagate_flags(node, referee)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *CXXLValueRefType {
        var unsafe *node = ctx->alloc<CXXLValueRefType>()
        node->kind          = TypeKind::RecoveryType
        node->recovery_kind = TypeKind::CXXLValueRefType
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Type) -> bool {
        return ptr->kind == TypeKind::CXXLValueRefType
    }

    /* OVERRIDE */
    static fn type_kind() -> TypeKind {
        return TypeKind::CXXLValueRefType
    }
}

///
///  CXXRValueRefType
///  T&& imported from C++ headers.
///
pub class CXXRValueRefType derives Type {
    pub var referee: unsafe *Type
    /// Written `ffi::ref<T>` / `ffi::mref<T>` in Kairo source (P872), not
    /// imported: the printer spells it back, FfiRefReturnCheck judges where.
    pub var ffi_spelled: bool = false

    pub static fn create(ctx:     *ASTContext,
                         range:   SourceRange,
                         referee: unsafe *Type) -> unsafe *CXXRValueRefType {
        var unsafe *node = ctx->alloc<CXXRValueRefType>()
        node->kind  = TypeKind::CXXRValueRefType
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        node->referee = referee
        propagate_flags(node, referee)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *CXXRValueRefType {
        var unsafe *node = ctx->alloc<CXXRValueRefType>()
        node->kind          = TypeKind::RecoveryType
        node->recovery_kind = TypeKind::CXXRValueRefType
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Type) -> bool {
        return ptr->kind == TypeKind::CXXRValueRefType
    }

    /* OVERRIDE */
    static fn type_kind() -> TypeKind {
        return TypeKind::CXXRValueRefType
    }
}

///
///  OpaqueFFIType
///  Opaque type from ffi "c++" sema treats as a black box.
///  name is the original C++ type spelling for diagnostics and codegen.
///
pub class OpaqueFFIType derives Type {
    /// Low 32 bits of the spelling's hash: an identity aid only. NOT an imm
    /// index: imm tables are per file, so an imported spelling interned in
    /// one file's table and read back through another's names a different
    /// identifier. The spelling itself is sp / sp_len, read by text().
    pub var name:   u32
    pub var sp:     kairo::std::ConstPtr<u8> = &null ///< the C++ spelling's bytes, NUL-terminated, owned by the canonical store's arena
    pub var sp_len: u32                      = 0

    /// The original C++ spelling, e.g. "std::FILE", independent of any file.
    pub fn text(self) -> string {
        var s = ""
        for var i: usize = 0; i < (self.sp_len as usize); ++i {
            s.push_back(self.sp[i])
        }

        return s
    }

    static fn create(ctx: *ASTContext, range: SourceRange, name: u32) -> unsafe *OpaqueFFIType {
        var unsafe *node = ctx->alloc<OpaqueFFIType>()
        node->kind  = TypeKind::OpaqueFFIType
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        node->name = name
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *OpaqueFFIType {
        var unsafe *node = ctx->alloc<OpaqueFFIType>()
        node->kind          = TypeKind::RecoveryType
        node->recovery_kind = TypeKind::OpaqueFFIType
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Type) -> bool {
        return ptr->kind == TypeKind::OpaqueFFIType
    }

    /* OVERRIDE */
    static fn type_kind() -> TypeKind {
        return TypeKind::OpaqueFFIType
    }
}

/// What a canonical value node (TypeExpr, is_value) is (Compiler/Spec/Eval.md#value-nodes, 3).
/// Literal is an exact integer (vneg / vmag); every other kind is an
/// expression Sema keeps for C++ to compute: an array extent or generic
/// value argument that does not fold, interned so that type identity is
/// structural equality of the expression (`[i32; f(3)]` is `[i32; f(3)]`
/// and not `[i32; 3]`, as C++ treats a dependent expression before
/// instantiation).
pub enum ValueOp derives u8 {
    Literal = 0,
    Decl,   ///< vdecl: an eval constant whose initializer does not fold, or an `eval for` binding.
    Call,   ///< vdecl: the eval fn; vops: the arguments.
    Unary,  ///< vtok: `-` or `~`; vops[0].
    Binary, ///< vtok: the operator; vops[0], vops[1].
    Cast,   ///< vty: the integer target; vops[0].
    /// A string literal (Compiler/Spec/Eval.md#eval-classes, §11): vbytes / vmag its decoded bytes
    /// and their count, vty the string lang record. Identity is the bytes.
    /// Only an argument of a Call: a string is no length or integer.
    Str,
}

pub class TypeExpr derives Type {
    pub var expr: unsafe *Expr
    /// CANONICAL only (CanonicalTypeStore::value_arg / value_expr): a
    /// generic VALUE argument or a computed array extent. A Literal is the
    /// exact integer, `4` of `Buf<4>` (Compiler/Spec/Eval.md#generic-value-parameters); any other ValueOp is an
    /// interned expression over value parameters (GenericParamType
    /// operands), eval names and eval calls (Compiler/Spec/Eval.md#value-nodes). The syntax node
    /// has `expr` and is_value false.
    pub var is_value: bool
    pub var vneg:     bool
    pub var vmag:     u64
    pub var vop:      ValueOp                  = ValueOp::Literal
    pub var vtok:     TokenKind                = TokenKind::TkUnknown
    pub var vdecl:    unsafe *Decl             = &null
    pub var vty:      unsafe *Type             = &null
    pub var vops:     FrozenList<unsafe *Type>
    /// ValueOp::Str only: the bytes (vmag of them), owned by the store.
    pub var vbytes: kairo::std::ConstPtr<u8> = &null

    /// A canonical exact integer (value_arg), the only value Sema itself
    /// reads.
    pub fn is_exact(self) -> bool {
        return self.is_value && self.vop == ValueOp::Literal
    }

    pub static fn create(ctx:   unsafe *ASTContext,
                         range: SourceRange,
                         expr:  unsafe *Expr) -> unsafe *TypeExpr {
        var unsafe *node = ctx->alloc<TypeExpr>()
        node->kind  = TypeKind::TypeExpr
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        node->expr     = expr
        node->is_value = false
        node->vneg     = false
        node->vmag     = (0)
        node->vop      = ValueOp::Literal
        node->vtok     = TokenKind::TkUnknown
        node->vdecl    = &null
        node->vty      = &null
        node->vops     = create_empty_frozen_list<unsafe *Type>()
        node->vbytes   = &null
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *TypeExpr {
        var unsafe *node = ctx->alloc<TypeExpr>()
        node->kind          = TypeKind::RecoveryType
        node->recovery_kind = TypeKind::TypeExpr
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Type) -> bool {
        return ptr->kind == TypeKind::TypeExpr
    }

    /* OVERRIDE */
    static fn type_kind() -> TypeKind {
        return TypeKind::TypeExpr
    }
}

///
///  ChainType
///  i32 | Foo | Foo::Bar | ::std::String | Foo<i32>::slice::Underlying
///
///  Unified type path node. Replaces NamedType, DependentNameType, and
///  GenericInstanceType. A single unqualified name like `i32` is a one-segment
///  chain   use is_simple() to fast-path that case in sema.
///
///  examples:
///    var foo: Foo::ISomething              2 segments, no generics
///    var foo: Foo<i32>::slice              2 segments, first has generic args
///    var bar: Foo<i32>::slice::Underlying   3 segments
///    var str: std::bad::string             3 segments
///    var x:   ::GlobalType                 1 segment, sep = ColonColon
///    var y:   i32                          1 segment, is_simple() = true
///
pub class ChainType derives Type {
    /// \enum SegmentSeparator
    /// \brief the operator prefixing a segment in the type path.
    pub enum SegmentSeparator derives u8 {
        None = 0,   ///< first segment in the chain.
        ColonColon, ///< `::` scope resolution.
    }

    /// \enum SegmentKind
    /// \brief cached categorization of the segment's type node.
    pub enum SegmentKind derives u8 {
        Named = 0,  ///< simple identifier (`string`, `Underlying`).
        GenericApp, ///< generic instantiation (`Foo<i32>`, `Map<K, V>`).
        Dependent,  ///< dependent type requiring deferred resolution after
        ///  template instantiation.
    }

    /// \struct GenericArg
    /// \brief a single argument in a generic argument list, optionally named.
    ///
    /// positional: `Vec<i32>`       -> name = null, type = i32
    /// named:      `Map<Key: str>`  -> name = "Key", type = str
    pub struct GenericArg {
        pub var name:       unsafe *NamedIdentExpr ///< set by sema for positional args.
        pub var name_range: SourceRange ///< range of the name token, invalid if positional.
        pub var ty:         unsafe *Type ///< the type argument.
    }

    /// \struct ChainSegment
    /// \brief a single component in the type path.
    pub struct ChainSegment {
        pub var name:          unsafe *NamedIdentExpr ///< the identifier for this segment.
        pub var generic_args:  FrozenList<GenericArg> ///< generic arguments, empty if non-generic.
        pub var resolved_type: unsafe *Type           ///< resolved type after sema, null before.
        pub var resolved_decl: unsafe *Decl           ///< resolved declaration (TypeAlias, Class,
        ///  Enum, etc.).
        pub var range:    SourceRange      ///< range covering the separator and segment.
        pub var sep:      SegmentSeparator ///< operator used to reach this segment.
        pub var seg_kind: SegmentKind      ///< semantic role of this segment.
    }

    pub var segments: FrozenList<Self::ChainSegment>

    /// \brief allocates a new ChainType from a temporary vector of segments.
    pub static fn create(ctx: unsafe *ASTContext, range: SourceRange) -> unsafe *ChainType {
        var unsafe *node = ctx->alloc<ChainType>()
        node->kind  = TypeKind::ChainType
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        return node
    }

    /// \brief creates a ChainType node tagged as a RecoveryType for error
    ///        resilience.
    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *ChainType {
        var unsafe *node = ctx->alloc<ChainType>()
        node->kind          = TypeKind::RecoveryType
        node->recovery_kind = TypeKind::ChainType
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_spans(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Type) -> bool {
        return ptr->kind == TypeKind::ChainType
    }

    /* OVERRIDE */
    static fn type_kind() -> TypeKind {
        return TypeKind::ChainType
    }

    fn get_segments(self) -> FrozenList<Self::ChainSegment> {
        return self.segments
    }

    fn size(self) -> usize {
        return self.segments.size()
    }

    fn last(self) -> unsafe *Self::ChainSegment {
        if self.segments.is_empty() {
            return &null
        }

        return self.segments.get(self.segments.size() - 1)
    }

    fn first(self) -> unsafe *Self::ChainSegment {
        if self.segments.is_empty() {
            return &null
        }

        return self.segments.get(0)
    }

    /// \brief returns true if the chain starts with a leading `::`.
    fn accesses_global_scope(self) -> bool {
        if self.segments.is_empty() {
            return false
        }

        return self.segments[0].sep == Self::SegmentSeparator::ColonColon
    }

    /// \brief returns true if any segment carries generic arguments.
    pub fn has_generic_args(self) -> bool {
        return self.segments.any(
            fn(x: unsafe *Self::ChainSegment) -> bool {
                return !x->generic_args.is_empty()
            },
        )
    }

    /// \brief returns true if any segment is marked dependent.
    fn has_dependent_segments(self) -> bool {
        return self.segments.any(
            fn(x: unsafe *Self::ChainSegment) -> bool {
                return x->seg_kind == Self::SegmentKind::Dependent
            },
        )
    }

    /// \brief returns true if this is a single unqualified name with no
    ///        generics (e.g., just `i32` or `Foo`). fast path for sema.
    pub fn is_simple(self) -> bool {
        return self.segments.size() == 1
            && self.segments[0].sep == Self::SegmentSeparator::None
            && self.segments[0].generic_args.is_empty()
    }

    /// \brief returns true if this is a single name with generic args
    ///        (e.g., `Vec<i32>`). replaces GenericInstanceType check.
    fn is_generic_instance(self) -> bool {
        return self.segments.size() == 1
            && self.segments[0].sep == Self::SegmentSeparator::None
            && !self.segments[0].generic_args.is_empty()
    }

    /// \brief returns the identifier of the final segment.
    ///        this is the actual type name in most resolution paths.
    pub fn trailing_name(self) -> unsafe *NamedIdentExpr {
        var unsafe *seg = self.last()
        if seg == &null {
            return &null
        }

        return seg->name
    }
}
