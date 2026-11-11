/// --- The Kairo Project ----------------------- AST/Serialize/TypeIO.k --- ///
///
///   The Type family: one `io_` function per written type class, the family
///   header every type shares, and the two entry points the archive's hooks
///   call (type_alloc, type_io).
///
///   Only SYNTAX types are in a parsed tree. The canonical classes
///   (QualifiedType, BuiltinType, RecordType, AssocType) and
///   SubstGenericParamType are build-wide objects Sema interns and shares
///   between files; a tree that reaches one is not a parsed tree, and the
///   writer says so instead of writing a pointer into another file.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "cstring"
ffi "c++" import "Native/Types.hh"

import AST::ASTSupport::FrozenList
import AST::Kind::TypeKind::TypeKind
import AST::Mixin::TypeQual::{
    AddressSpace,
    ExtQuals,
    QualSpan,
    TypeQualFlags,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::PrimaryExpressions::NamedIdentExpr
import AST::Node::Types
import AST::ParamMode::ParamMode
import AST::Serialize::Archive::ASTArchive
import AST::Serialize::NodeCommon::io_annotations
import Location::SourceRange::SourceRange
import Token::TokenKind::TokenKind

fn <T: type> new_type(ar: unsafe *ASTArchive) -> unsafe *Type {
    return unsafe (ar->ctx->alloc<T>() as unsafe *Type)
}

/// Reads a type's kind and allocates an object of its class, with the
/// mixin storage every factory sets up (qualifier spans, annotations).
pub fn type_alloc(ar: unsafe *ASTArchive) -> unsafe *Type {
    var kind = TypeKind::RecoveryType
    ar->en<TypeKind>(&kind)
    var cls = kind
    if kind == TypeKind::RecoveryType {
        ar->en<TypeKind>(&cls)
    }

    var t: unsafe *Type = &null
    match cls {
        case TypeKind::ChainType {
            t = new_type<Types::ChainType>(ar)
        } case TypeKind::GenericParamType {
            t = new_type<Types::GenericParamType>(ar)
        } case TypeKind::TypeOfType {
            t = new_type<Types::TypeOfType>(ar)
        } case TypeKind::VariadicPackType {
            t = new_type<Types::VariadicPackType>(ar)
        } case TypeKind::PackExpansionType {
            t = new_type<Types::PackExpansionType>(ar)
        } case TypeKind::PointerType {
            t = new_type<Types::PointerType>(ar)
        } case TypeKind::NullableType {
            t = new_type<Types::NullableType>(ar)
        } case TypeKind::TupleType {
            t = new_type<Types::TupleType>(ar)
        } case TypeKind::FixedArrayType {
            t = new_type<Types::FixedArrayType>(ar)
        } case TypeKind::VectorType {
            t = new_type<Types::VectorType>(ar)
        } case TypeKind::MapType {
            t = new_type<Types::MapType>(ar)
        } case TypeKind::SetType {
            t = new_type<Types::SetType>(ar)
        } case TypeKind::SelfType {
            t = new_type<Types::SelfType>(ar)
        } case TypeKind::FunctionPointerType {
            t = new_type<Types::FunctionPointerType>(ar)
        } case TypeKind::InferredType {
            t = new_type<Types::InferredType>(ar)
        } case TypeKind::CXXLValueRefType {
            t = new_type<Types::CXXLValueRefType>(ar)
        } case TypeKind::CXXRValueRefType {
            t = new_type<Types::CXXRValueRefType>(ar)
        } case TypeKind::OpaqueFFIType {
            t = new_type<Types::OpaqueFFIType>(ar)
        } case TypeKind::TypeExpr {
            t = new_type<Types::TypeExpr>(ar)
        } default {
            return &null
        }
    }

    t->kind = kind
    if kind == TypeKind::RecoveryType {
        t->recovery_kind = cls
    }

    t->spans.set_allocator(unsafe &ar->ctx->ast_alloc, 2)
    t->init_annotations(unsafe &ar->ctx->ast_alloc)
    return t
}

/// The fields of the Type base and its TypeQual mixin.
fn io_type_base(ar: unsafe *ASTArchive, t: unsafe *Type) {
    if !ar->reading {
        ar->en<TypeKind>(&t->kind)
        if t->kind == TypeKind::RecoveryType {
            ar->en<TypeKind>(&t->recovery_kind)
        }
    }

    ar->range(&t->range)
    // The parser writes type_flags (a generic parameter is dependent from
    // the moment it is parsed); T only adds to them.
    ar->num8(&t->type_flags.bits)
    ar->num16(&t->flags.bits)
    ar->flag(&t->poisoned)

    var has_ext = t->ext != &null
    ar->flag(&has_ext)
    io_annotations<Type>(ar, t)

    if has_ext {
        if ar->reading {
            t->ext = ar->ctx->alloc<ExtQuals>()
        }

        ar->en<AddressSpace>(&t->ext->address_space)
        ar->range(&t->ext->address_space_range)
    }

    var n = ar->len_(t->spans.size())
    for var i: usize = 0; i < n; ++i {
        var s = QualSpan(0 as u16, SourceRange::invalid())
        if !ar->reading {
            s = *t->spans.get(i)
        }

        ar->num16(&s.qual_flag)
        ar->range(&s.range)
        if ar->reading {
            t->spans.push(s)
        }
    }

    eval if defined!(DEBUG) {
        ar->sema_zero(t->size_bits as u64, "Type::size_bits")
        ar->sema_zero(t->align_bits as u64, "Type::align_bits")
        ar->sema_null<Type>(t->canonical, "Type::canonical")
        if t->kind != TypeKind::RecoveryType {
            ar->sema_is(t->recovery_kind == TypeKind::RecoveryType, "Type::recovery_kind")
        }
    }
}

fn io_generic_arg(ar: unsafe *ASTArchive, a: unsafe *Types::ChainType::GenericArg) {
    ar->expr<NamedIdentExpr>(&a->name)
    ar->range(&a->name_range)
    ar->type_<Type>(&a->ty)
}

/// A generic argument list (`<A, B: C>`): shared with NamedIdentExpr and
/// ChainExpr steps, which carry the same list.
pub fn io_generic_args(ar: unsafe *ASTArchive, @inout l: FrozenList<Types::ChainType::GenericArg>) {
    var n = ar->list<Types::ChainType::GenericArg>(&l)
    for var i: usize = 0; i < n; ++i {
        io_generic_arg(ar, l.get(i))
    }
}

fn io_chain_type(ar: unsafe *ASTArchive, n: unsafe *Types::ChainType) {
    var count = ar->list<Types::ChainType::ChainSegment>(&n->segments)
    for var i: usize = 0; i < count; ++i {
        var unsafe *s = n->segments.get(i)
        ar->expr<NamedIdentExpr>(&s->name)
        io_generic_args(ar, &s->generic_args)
        ar->range(&s->range)
        ar->en<Types::ChainType::SegmentSeparator>(&s->sep)
        ar->en<Types::ChainType::SegmentKind>(&s->seg_kind)
        eval if defined!(DEBUG) {
            ar->sema_null<Type>(s->resolved_type, "ChainSegment::resolved_type")
            ar->sema_null<Decl>(s->resolved_decl, "ChainSegment::resolved_decl")
        }
    }
}

fn io_generic_param_type(ar: unsafe *ASTArchive, n: unsafe *Types::GenericParamType) {
    ar->decl<Decl>(&n->owner)
    ar->expr<NamedIdentExpr>(&n->param_name)
    ar->num32(&n->param_index)
    ar->flag(&n->is_pack)
}

fn io_type_of_type(ar: unsafe *ASTArchive, n: unsafe *Types::TypeOfType) {
    ar->expr<Expr>(&n->expr)
    eval if defined!(DEBUG) {
        ar->sema_is(n->resolved == &null, "TypeOfType::resolved")
    }
}

fn io_variadic_pack_type(ar: unsafe *ASTArchive, n: unsafe *Types::VariadicPackType) {
    ar->type_<Types::GenericParamType>(&n->param)
}

fn io_pack_expansion_type(ar: unsafe *ASTArchive, n: unsafe *Types::PackExpansionType) {
    ar->type_<Type>(&n->pattern)
}

fn io_pointer_type(ar: unsafe *ASTArchive, n: unsafe *Types::PointerType) {
    ar->type_<Type>(&n->pointee)
    ar->flag(&n->is_unsafe)
    eval if defined!(DEBUG) {
        ar->sema_zero(n->length as u64, "PointerType::length")
    }
}

fn io_nullable_type(ar: unsafe *ASTArchive, n: unsafe *Types::NullableType) {
    ar->type_<Type>(&n->inner)
    eval if defined!(DEBUG) {
        ar->sema_null<Type>(n->lowered, "NullableType::lowered")
        ar->sema_is(n->seen_rank == u64::MAX, "NullableType::seen_rank")
    }
}

fn io_tuple_type(ar: unsafe *ASTArchive, n: unsafe *Types::TupleType) {
    ar->type_list<Type>(&n->elements)
}

fn io_fixed_array_type(ar: unsafe *ASTArchive, n: unsafe *Types::FixedArrayType) {
    ar->type_<Type>(&n->element)
    ar->expr<Expr>(&n->size_expr)
    ar->flag(&n->is_incomplete)
    eval if defined!(DEBUG) {
        ar->sema_null<Type>(n->extent_param, "FixedArrayType::extent_param")
    }
}

fn io_vector_type(ar: unsafe *ASTArchive, n: unsafe *Types::VectorType) {
    ar->type_<Type>(&n->element)
}

fn io_map_type(ar: unsafe *ASTArchive, n: unsafe *Types::MapType) {
    ar->type_<Type>(&n->key)
    ar->type_<Type>(&n->value)
}

fn io_set_type(ar: unsafe *ASTArchive, n: unsafe *Types::SetType) {
    ar->type_<Type>(&n->element)
}

fn io_function_pointer_type(ar: unsafe *ASTArchive, n: unsafe *Types::FunctionPointerType) {
    ar->type_list<Type>(&n->params)
    ar->type_<Type>(&n->return_type)
    ar->flag(&n->is_unprototyped)
    ar->flag(&n->is_raw)
    ar->num8(&n->call_conv)

    var m = ar->list<ParamMode>(&n->modes)
    for var i: usize = 0; i < m; ++i {
        ar->en<ParamMode>(&n->modes.items[i])
    }

    ar->type_list<Type>(&n->panic_set)
    eval if defined!(DEBUG) {
        ar->sema_false(n->canon_panics, "FunctionPointerType::canon_panics")
        ar->sema_null<Type>(n->panic_result, "FunctionPointerType::panic_result")
    }
}

fn io_inferred_type(ar: unsafe *ASTArchive, n: unsafe *Types::InferredType) {
    ar->num32(&n->infer_id)
}

fn io_cxx_lvalue_ref_type(ar: unsafe *ASTArchive, n: unsafe *Types::CXXLValueRefType) {
    ar->type_<Type>(&n->referee)
}

fn io_cxx_rvalue_ref_type(ar: unsafe *ASTArchive, n: unsafe *Types::CXXRValueRefType) {
    ar->type_<Type>(&n->referee)
}

/// `name` is a hash of the spelling (not an imm index: OpaqueFFIType says
/// why), so it is a plain number; the spelling's bytes are copied into the
/// tree's arena, NUL-terminated as text() expects.
fn io_opaque_ffi_type(ar: unsafe *ASTArchive, n: unsafe *Types::OpaqueFFIType) {
    ar->num32(&n->name)
    var sp: string
    if !ar->reading && n->sp != &null {
        sp = string(unsafe ((n->sp as unsafe *const u8) as *const u8), n->sp_len as usize)
    }

    var has = n->sp != &null
    ar->flag(&has)
    if has {
        ar->str(&sp)
        if ar->reading {
            var unsafe *mem = ar->ctx->alloc_array<u8>(sp.size() + 1)
            cxx::std::memcpy(
                unsafe (mem as unsafe *void),
                unsafe (sp.raw() as unsafe *const void),
                sp.size(),
            )

            mem[sp.size()] = 0
            n->sp     = unsafe (mem as kairo::std::ConstPtr<u8>)
            n->sp_len = sp.size() as u32
        }
    }
}

fn io_type_expr(ar: unsafe *ASTArchive, n: unsafe *Types::TypeExpr) {
    ar->expr<Expr>(&n->expr)
    eval if defined!(DEBUG) {
        // The value form is the canonical store's; a written `[T; N]` or
        // `Buf<4>` has only `expr`.
        ar->sema_false(n->is_value, "TypeExpr::is_value")
        ar->sema_false(n->vneg, "TypeExpr::vneg")
        ar->sema_zero(n->vmag, "TypeExpr::vmag")
        ar->sema_is(n->vop == Types::ValueOp::Literal, "TypeExpr::vop")
        ar->sema_is(n->vtok == TokenKind::TkUnknown, "TypeExpr::vtok")
        ar->sema_null<Decl>(n->vdecl, "TypeExpr::vdecl")
        ar->sema_null<Type>(n->vty, "TypeExpr::vty")
        ar->sema_zero(n->vops.size() as u64, "TypeExpr::vops")
        ar->sema_is(n->vbytes == &null, "TypeExpr::vbytes")
    }
}

/// Writes or reads one type node: the family header, then its class.
pub fn type_io(ar: unsafe *ASTArchive, t: unsafe *Type) {
    io_type_base(ar, t)

    var cls = t->kind
    if cls == TypeKind::RecoveryType {
        cls = t->recovery_kind
    }

    match cls {
        case TypeKind::ChainType {
            io_chain_type(ar, unsafe (t as unsafe *Types::ChainType))
        } case TypeKind::GenericParamType {
            io_generic_param_type(ar, unsafe (t as unsafe *Types::GenericParamType))
        } case TypeKind::TypeOfType {
            io_type_of_type(ar, unsafe (t as unsafe *Types::TypeOfType))
        } case TypeKind::VariadicPackType {
            io_variadic_pack_type(ar, unsafe (t as unsafe *Types::VariadicPackType))
        } case TypeKind::PackExpansionType {
            io_pack_expansion_type(ar, unsafe (t as unsafe *Types::PackExpansionType))
        } case TypeKind::PointerType {
            io_pointer_type(ar, unsafe (t as unsafe *Types::PointerType))
        } case TypeKind::NullableType {
            io_nullable_type(ar, unsafe (t as unsafe *Types::NullableType))
        } case TypeKind::TupleType {
            io_tuple_type(ar, unsafe (t as unsafe *Types::TupleType))
        } case TypeKind::FixedArrayType {
            io_fixed_array_type(ar, unsafe (t as unsafe *Types::FixedArrayType))
        } case TypeKind::VectorType {
            io_vector_type(ar, unsafe (t as unsafe *Types::VectorType))
        } case TypeKind::MapType {
            io_map_type(ar, unsafe (t as unsafe *Types::MapType))
        } case TypeKind::SetType {
            io_set_type(ar, unsafe (t as unsafe *Types::SetType))
        } case TypeKind::SelfType {
            // no fields of its own
        } case TypeKind::FunctionPointerType {
            io_function_pointer_type(ar, unsafe (t as unsafe *Types::FunctionPointerType))
        } case TypeKind::InferredType {
            io_inferred_type(ar, unsafe (t as unsafe *Types::InferredType))
        } case TypeKind::CXXLValueRefType {
            io_cxx_lvalue_ref_type(ar, unsafe (t as unsafe *Types::CXXLValueRefType))
        } case TypeKind::CXXRValueRefType {
            io_cxx_rvalue_ref_type(ar, unsafe (t as unsafe *Types::CXXRValueRefType))
        } case TypeKind::OpaqueFFIType {
            io_opaque_ffi_type(ar, unsafe (t as unsafe *Types::OpaqueFFIType))
        } case TypeKind::TypeExpr {
            io_type_expr(ar, unsafe (t as unsafe *Types::TypeExpr))
        } default {
            ar->fail("a canonical type is reachable from a parsed tree")
        }
    }
}
