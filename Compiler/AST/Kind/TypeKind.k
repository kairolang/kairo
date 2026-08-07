/// --- The Kairo Project -------------------------- AST/Kind/TypeKind.k --- ///
///
///   <short description>
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
///
///   TypeKind
///
///   Ranges:
///     [0]        Error sentinel
///     [1 .. 2]   Named / resolved types
///     [3 .. 4]   Pointer / optional types
///     [5 .. 9]   Collection types
///     [10]       Callable type
///     [11 .. 12] Compiler-inserted types
///
/// ------------------------------------------------------------------------ ///

enum TypeKind derives u8 {
    /// -----------------------------------------------------------------------
    ///  Sentinel
    /// -----------------------------------------------------------------------

    /// Parser / sema error sentinel.
    RecoveryType = 0,

    /// -----------------------------------------------------------------------
    ///  Named / resolved types  [1 .. 2]
    /// -----------------------------------------------------------------------
    ChainType,

    /// T inside fn foo<T>(x: T) unresolved generic param
    /// distinct from ChainType which is a resolved named type
    GenericParamType,

    /// Post-substitution wrapper for instantiation diagnostics.
    SubstGenericParamType,

    /// typeof in type position: var x: typeof(foo()) = bar()
    /// distinct from TypeOfExpr which is an expression
    TypeOfType,

    /// Variadic pack type: ...T
    /// used in variadic generic signatures
    VariadicPackType,

    /// Pack expansion type: T... (unexpanded pack in type position)
    /// used in variadic generic signatures and variadic tuple types
    PackExpansionType,

    /// -----------------------------------------------------------------------
    ///  Pointer / optional types  [3 .. 4]
    /// -----------------------------------------------------------------------

    /// Fat pointer type:
    /// Node: PointerType pointee TypeRef.
    PointerType,
    
    /// Nullable (optional) type:  T?
    /// Lowered to std::Optional<T> by sema unless --explicit-aliasing.
    /// Node: NullableType inner TypeRef.
    NullableType,

    /// -----------------------------------------------------------------------
    ///  Collection types  [5 .. 9]
    /// -----------------------------------------------------------------------

    /// Tuple type:  (i32, str, f64)
    /// Node: TupleType element TypeRef array.
    TupleType,

    /// Fixed-size array type:  [i32; 6]
    /// Node: FixedArrayType element TypeRef + size Expr*.
    FixedArrayType,

    /// Growable vector type:  [i32]
    /// Node: VectorType element TypeRef.
    VectorType,

    /// Map type:  {str: i32}
    /// Node: MapType key TypeRef + value TypeRef.
    MapType,

    /// Set type:  {i32}
    /// Node: SetType element TypeRef.
    SetType,

    /// Self type inside class/interface bodies
    /// refers to the implementing type
    SelfType, // const can be attached here

    /// -----------------------------------------------------------------------
    ///  Callable type  [10]
    /// -----------------------------------------------------------------------

    /// Function pointer type:  fn(i32, str) -> bool (explicit capture control is a part of the expression syntax, not the type syntax)
    /// Node: FunctionPointerType param TypeRef array + return TypeRef.
    FunctionPointerType,

    /// -----------------------------------------------------------------------
    ///  Compiler-inserted types  [11 .. 12]
    /// -----------------------------------------------------------------------

    /// Type inference placeholder:  _ or omitted annotation
    /// Sema assigns a concrete type by solving constraints.
    /// Each InferType node carries a unique infer_id for the solver.
    /// Node: InferredType
    InferredType,

    // T& from C++ headers
    CXXLValueRefType,

    // T&& from C++ headers
    CXXRValueRefType,

    // opaque type from ffi "c++" sema treats as black box
    OpaqueFFIType,

    // Expression in the Type position like vec<i32, 12> where 12 is a const expression
    TypeExpr,

    /// -----------------------------------------------------------------------
    ///  Marker
    /// -----------------------------------------------------------------------
    TypeKindCount,
}

fn to_string(t: TypeKind) -> string {
    switch t {
        case TypeKind::RecoveryType { return "RecoveryType"; }
        case TypeKind::ChainType { return "ChainType"; }
        case TypeKind::GenericParamType { return "GenericParamType"; }
        case TypeKind::SubstGenericParamType { return "SubstGenericParamType"; }
        case TypeKind::TypeOfType { return "TypeOfType"; }
        case TypeKind::VariadicPackType { return "VariadicPackType"; }
        case TypeKind::PackExpansionType { return "PackExpansionType"; }
        case TypeKind::PointerType { return "PointerType"; }
        case TypeKind::NullableType { return "NullableType"; }
        case TypeKind::TupleType { return "TupleType"; }
        case TypeKind::FixedArrayType { return "FixedArrayType"; }
        case TypeKind::VectorType { return "VectorType"; }
        case TypeKind::MapType { return "MapType"; }
        case TypeKind::SetType { return "SetType"; }
        case TypeKind::SelfType { return "SelfType"; }
        case TypeKind::FunctionPointerType { return "FunctionPointerType"; }
        case TypeKind::InferredType { return "InferredType"; }
        case TypeKind::CXXLValueRefType { return "CXXLValueRefType"; }
        case TypeKind::CXXRValueRefType { return "CXXRValueRefType"; }
        case TypeKind::OpaqueFFIType { return "OpaqueFFIType"; }
        case TypeKind::TypeExpr { return "TypeExpr"; }
    }

    return "UnknownTypeKind";
}