/// --- The Kairo Project ------------------- AST/Node/CanonicalNodes.k --- ///
///
///   \brief The two type nodes the PARSER never produces: BuiltinType and
///          RecordType. Both exist only as canonical forms, created solely by
///          CanonicalTypeStore.
///
///   \detail
///     Every other TypeKind is a piece of SYNTAX -- `*T`, `[T]`, `Foo::Bar<U>`
///     -- and the parser builds it from tokens. These two are not syntax:
///
///       BuiltinType  `i32` lexes as the keyword token AtI32, not as an
///                    identifier, so it is in no symbol table and resolves by
///                    token kind rather than by lookup. It is a universal
///                    entity (Clang's IntTy model): one singleton per kind per
///                    build, owned by the store, referenced by every TU.
///
///       RecordType   the canonical form of a nominal type USE. `Foo` and
///                    `ns::Foo` and an imported `Foo` are three different
///                    ChainType nodes naming ONE entity; they all canonicalize
///                    to the same RecordType(canonical decl, canonical args).
///                    Without it a ChainType's canonical could only point at
///                    another ChainType, and type identity would degrade to
///                    "whichever spelling was resolved first".
///
///   \par Lifetime
///     Allocated from CanonicalTypeStore's own arena, NOT from any
///     ASTContext::ast_alloc. That is load-bearing: release_from(Parsing)
///     resets a fid's ast_alloc, and a canonical shared with every importer
///     cannot die with the file that first mentioned it.
///
///   \par Not parseable
///     Neither has a create_error(): a recovery node stands for a failed
///     PARSE, and nothing parses into these. TypeResolution signals failure by
///     leaving `canonical` null and poisoning the syntax node instead.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Node::Base::*;
import AST::ASTSupport::*;
import Token::TokenKind::*;

/// \enum BuiltinKind
/// \brief The primitive value types. One singleton Type node per entry.
///
///        Ordering is arbitrary and is NOT an ABI: the store indexes an array
///        by it, nothing else depends on the numbers. `f8` is absent because
///        the lexer has no token for it (see TYPE_TOK_TBL in TypeParse.k);
///        adding one is a lexer change first, not a change here.
enum BuiltinKind derives u8 {
    Void = 0,
    Bool,

    I8, I16, I32, I64, I128, I256, I512,
    U8, U16, U32, U64, U128, U256, U512,

    /// Pointer-width integers. Their size is TARGET-dependent, so unlike the
    /// fixed-width entries above their size_bits is filled from the target
    /// triple at store construction, not from the name.
    USize, ISize,

    F16, F32, F64, F80, F128, F256,

    COUNT,   ///< keep last.
}

/// \brief Map a type-position token kind to its builtin, or COUNT when the
///        token does not name one.
///
/// \details This is the WHOLE of builtin "lookup". `i32` is not a name: it
///          never enters a SymbolTable, never rides the import overlay, and is
///          never shadowable. TypeResolution asks this question of a
///          ChainType's first segment before it asks the symbol tables
///          anything, which is also why `var i32 = 3` cannot break `var x: i32`.
fn builtin_for_token(k: TokenKind) -> BuiltinKind {
    switch k {
        case TokenKind::AtVoid  { return BuiltinKind::Void;  }
        case TokenKind::AtBool  { return BuiltinKind::Bool;  }

        case TokenKind::AtI8    { return BuiltinKind::I8;    }
        case TokenKind::AtI16   { return BuiltinKind::I16;   }
        case TokenKind::AtI32   { return BuiltinKind::I32;   }
        case TokenKind::AtI64   { return BuiltinKind::I64;   }
        case TokenKind::AtI128  { return BuiltinKind::I128;  }
        case TokenKind::AtI256  { return BuiltinKind::I256;  }
        case TokenKind::AtI512  { return BuiltinKind::I512;  }

        case TokenKind::AtU8    { return BuiltinKind::U8;    }
        case TokenKind::AtU16   { return BuiltinKind::U16;   }
        case TokenKind::AtU32   { return BuiltinKind::U32;   }
        case TokenKind::AtU64   { return BuiltinKind::U64;   }
        case TokenKind::AtU128  { return BuiltinKind::U128;  }
        case TokenKind::AtU256  { return BuiltinKind::U256;  }
        case TokenKind::AtU512  { return BuiltinKind::U512;  }

        case TokenKind::AtUsize { return BuiltinKind::USize; }
        case TokenKind::AtIsize { return BuiltinKind::ISize; }

        case TokenKind::AtF16   { return BuiltinKind::F16;   }
        case TokenKind::AtF32   { return BuiltinKind::F32;   }
        case TokenKind::AtF64   { return BuiltinKind::F64;   }
        case TokenKind::AtF80   { return BuiltinKind::F80;   }
        case TokenKind::AtF128  { return BuiltinKind::F128;  }
        case TokenKind::AtF256  { return BuiltinKind::F256;  }

        default { return BuiltinKind::COUNT; }
    }
}

/// \brief Source spelling of a builtin, for diagnostics and dumps.
fn builtin_spelling(b: BuiltinKind) -> string {
    switch b {
        case BuiltinKind::Void  { return "void";  }
        case BuiltinKind::Bool  { return "bool";  }
        case BuiltinKind::I8    { return "i8";    }
        case BuiltinKind::I16   { return "i16";   }
        case BuiltinKind::I32   { return "i32";   }
        case BuiltinKind::I64   { return "i64";   }
        case BuiltinKind::I128  { return "i128";  }
        case BuiltinKind::I256  { return "i256";  }
        case BuiltinKind::I512  { return "i512";  }
        case BuiltinKind::U8    { return "u8";    }
        case BuiltinKind::U16   { return "u16";   }
        case BuiltinKind::U32   { return "u32";   }
        case BuiltinKind::U64   { return "u64";   }
        case BuiltinKind::U128  { return "u128";  }
        case BuiltinKind::U256  { return "u256";  }
        case BuiltinKind::U512  { return "u512";  }
        case BuiltinKind::USize { return "usize"; }
        case BuiltinKind::ISize { return "isize"; }
        case BuiltinKind::F16   { return "f16";   }
        case BuiltinKind::F32   { return "f32";   }
        case BuiltinKind::F64   { return "f64";   }
        case BuiltinKind::F80   { return "f80";   }
        case BuiltinKind::F128  { return "f128";  }
        case BuiltinKind::F256  { return "f256";  }
        default                 { return "<builtin?>"; }
    }
}

/// \brief Width in bits, or 0 for the two target-dependent entries (the store
///        fills those from the target triple).
fn builtin_fixed_bits(b: BuiltinKind) -> usize {
    switch b {
        case BuiltinKind::Void  { return 0;   }
        case BuiltinKind::Bool  { return 8;   }
        case BuiltinKind::I8    { return 8;   }
        case BuiltinKind::I16   { return 16;  }
        case BuiltinKind::I32   { return 32;  }
        case BuiltinKind::I64   { return 64;  }
        case BuiltinKind::I128  { return 128; }
        case BuiltinKind::I256  { return 256; }
        case BuiltinKind::I512  { return 512; }
        case BuiltinKind::U8    { return 8;   }
        case BuiltinKind::U16   { return 16;  }
        case BuiltinKind::U32   { return 32;  }
        case BuiltinKind::U64   { return 64;  }
        case BuiltinKind::U128  { return 128; }
        case BuiltinKind::U256  { return 256; }
        case BuiltinKind::U512  { return 512; }
        case BuiltinKind::F16   { return 16;  }
        case BuiltinKind::F32   { return 32;  }
        case BuiltinKind::F64   { return 64;  }
        case BuiltinKind::F80   { return 80;  }
        case BuiltinKind::F128  { return 128; }
        case BuiltinKind::F256  { return 256; }
        default                 { return 0;   }   // USize / ISize: target-dependent.
    }
}

fn builtin_is_integer(b: BuiltinKind) -> bool {
    var v = static_cast::<u8>(b);
    return ((v >= static_cast::<u8>(BuiltinKind::I8))
         && (v <= static_cast::<u8>(BuiltinKind::U512)))
        || (b == BuiltinKind::USize) || (b == BuiltinKind::ISize);
}

fn builtin_is_signed(b: BuiltinKind) -> bool {
    var v = static_cast::<u8>(b);
    return ((v >= static_cast::<u8>(BuiltinKind::I8))
         && (v <= static_cast::<u8>(BuiltinKind::I512)))
        || (b == BuiltinKind::ISize);
}

fn builtin_is_float(b: BuiltinKind) -> bool {
    var v = static_cast::<u8>(b);
    return (v >= static_cast::<u8>(BuiltinKind::F16))
        && (v <= static_cast::<u8>(BuiltinKind::F256));
}

///
///  BuiltinType
///  i32 | bool | f64 | void | usize ...
///
///  A singleton. `canonical` points at ITSELF: a builtin is already fully
///  desugared, and self-canonicality is what lets the identity test
///  (a->canonical == b->canonical) work uniformly without a builtin special
///  case at every comparison site.
///
class BuiltinType derives Type {
    pub var builtin: BuiltinKind = BuiltinKind::Void;

    /* OVERRIDE */ static fn classof(ptr: *Type) -> bool {
        return ptr->kind == TypeKind::BuiltinType;
    }

    /* OVERRIDE */ static fn type_kind() -> TypeKind {
        return TypeKind::BuiltinType;
    }

    fn spelling(self) -> string { return builtin_spelling(self.builtin); }
}

///
///  RecordType
///  The canonical form of a nominal type use: Foo | Foo<i32> | ns::Inner
///
///  `decl` is the CANONICAL link of the entity's redecl chain (the definition
///  once N(a) retargeted it), never whichever forward declaration a particular
///  spelling happened to bind. That is what collapses `class Foo;` and
///  `class Foo { }` to one type.
///
///  `args` holds CANONICAL generic arguments, empty for a non-generic type.
///  Uniquing is on (decl, args...), so Vec<i32> and Vec<u8> are distinct
///  entities while two spellings of Vec<i32> are one.
///
class RecordType derives Type {
    pub var decl: *Decl = &null;          ///< canonical Class/Struct/Union/Interface/EnumDecl.
    pub var args: FrozenList::<*Type>;    ///< canonical generic args; empty if non-generic.

    /* OVERRIDE */ static fn classof(ptr: *Type) -> bool {
        return ptr->kind == TypeKind::RecordType;
    }

    /* OVERRIDE */ static fn type_kind() -> TypeKind {
        return TypeKind::RecordType;
    }

    fn is_generic_instance(self) -> bool { return self.args.size() > 0; }
}