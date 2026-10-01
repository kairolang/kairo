/// --- The Kairo Project ----------------------------- AST/LangItems.k --- ///
///
///   \brief Names the compiler knows that are not in the user's source.
///          Two kinds, one bucket test:
///
///            could a user declare it in Kairo?
///              yes -> a LANG ITEM: a real decl in the builtins module,
///                     found by lookup, spelled by CXXSpell like any decl.
///              no  -> a LOWER TARGET: a fragment of the C++ name of
///                     something the USER declared (`__kairo_contains` is
///                     the member name of their `op in`), invented here.
///
///   \par Lang items
///     Ordinary decls that arrive through ordinary imports and sit in
///     ordinary tables; sema needs a direct handle for desugaring. Their
///     names are NEVER special-cased in lookup. The primitive value types
///     are not here: `i32` lexes as a keyword token and is a BuiltinType
///     singleton resolved by token kind (CanonicalNodes.k).
///
///     Runtime types and functions a lowering needs (`Optional<T>` for `T?`,
///     `pow` for `^^` on primitives, the panic entry points) are lang items
///     too: declared in builtins, ffi-backed where the body is C++, and the
///     C++ spelling is DERIVED from the declaration. No lowering carries a
///     `::kairo::rt::...` string.
///
///   \par Lower targets
///     Not user-writable: the `__kairo_` prefix is reserved (CxxNameCheck
///     rejects it in user identifiers). One writer per entry, named.
///
///   Layer: AST leaf. Imports Base and CanonicalNodes only; imported by Sema and Codegen.
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
import AST::Node::CanonicalNodes::*;

/// \enum WellKnownType
/// \brief The lang items. One row per decl a lowering needs a handle to.
enum WellKnownType derives u8 {
    Future = 0, ///< spawn foo() desugar type: Future<T>.
    Range,      ///< 1..2 | 1..=2 desugar type: Range(a, b, t/f).
    Yield,      ///< yield T desugar target: Yield<T>.
    Ordering,   ///< <=> builtin value type: Ordering::Less | Equal | Greater.
    Null,       ///< T? desugar type: Null<T>.
    Panic,      ///< fn () panic -> T desugar type: Panic<T>.

    String,   ///< ""     library type: string.
    Vector,   ///< [T]    library type: vector.
    Slice,    ///< [T;]   library type: slice.
    Array,    ///< [T; N] library type: array.
    HashMap,  ///< {K: V} library type: hashmap.
    HashSet,  ///< {T}    library type: hashset.

    BigInt,   ///< 3.0e+100 library type: BigInt.
    BigFloat, ///< 1.2e+100 library type: BigFloat.

    PanicRaise, ///< PanicLowering: raise entry point.
    PanicCatch, ///< PanicLowering: catch entry point.
    AssertFail, ///< PanicLowering: `assert` failure entry point.

    Pow,        ///< `^^` on primitives: `fn <B, E> pow(base: B, exp: E) -> B`.

    FmtBuf,     ///< f-string: the builder every f-string lowers onto.
    Byte,       ///< `byte`'s C++ spelling: `enum class Byte : unsigned char`.

    COUNT,      ///< keep last.
}

/// The lang item's NAME as the builtin root declares it. Diagnostics quote
/// this, so it must match the spelling `NameResolution::fill_lang_items` looks
/// up -- a message naming an item the tree does not declare is worse than no
/// message.
fn to_string(k: WellKnownType) -> string {
    switch k {
        case WellKnownType::Future     { return "Future";     }
        case WellKnownType::Range      { return "Range";      }
        case WellKnownType::Yield      { return "Yield";      }
        case WellKnownType::Ordering   { return "Ordering";   }
        case WellKnownType::Null       { return "Null";       }
        case WellKnownType::Panic      { return "Panic";      }
        case WellKnownType::String     { return "string";     }
        case WellKnownType::Vector     { return "Vector";     }
        case WellKnownType::Slice      { return "Slice";      }
        case WellKnownType::Array      { return "Array";      }
        case WellKnownType::HashMap    { return "HashMap";    }
        case WellKnownType::HashSet    { return "HashSet";    }
        case WellKnownType::BigInt     { return "BigInt";     }
        case WellKnownType::BigFloat   { return "BigFloat";   }
        case WellKnownType::PanicRaise { return "PanicRaise"; }
        case WellKnownType::PanicCatch { return "PanicCatch"; }
        case WellKnownType::AssertFail { return "AssertFail"; }
        case WellKnownType::Pow        { return "pow"; }
        case WellKnownType::FmtBuf     { return "FmtBuf";     }
        case WellKnownType::Byte       { return "Byte";       }
        case WellKnownType::COUNT      { return "<count>";    }
    }
    return "<unknown>";
}

/// \class WellKnownDecls
/// \brief WellKnownType -> canonical *Decl. ONE per build, owned by
///        GlobalDisambigTable and filled once from the builtins fid (lang
///        items are bound by fid + path, never by unqualified name). Read
///        by sema through sc->well_known and by codegen through the
///        CodegenContext. A missing entry is an error only at USE, diagnosed
///        by the pass that needs it.
class WellKnownDecls {
    priv var _decls: vec::<*Decl>;   ///< indexed by WellKnownType; COUNT slots.

    fn WellKnownDecls(self) {
        for var i: usize = 0; i < static_cast::<usize>(WellKnownType::COUNT); ++i {
            self._decls.push_back(&null);
        }
    }

    fn _set(self, k: WellKnownType, d: *Decl) {
        self._decls[static_cast::<usize>(k)] = d;
    }

    /// Canonical decl for the lang item, or null if not (yet) resolved.
    fn get(self, k: WellKnownType) -> *Decl {
        return self._decls[static_cast::<usize>(k)];
    }

    fn has(self, k: WellKnownType) -> bool {
        return self._decls[static_cast::<usize>(k)] != &null;
    }
}

/// \enum FormatKind
/// \brief The compiler's spelling of Lib/builtin/fmt.k's FormatKind: what X
///        records per f-string hole and FStringLowering mints as a variant
///        USE. The rows are matched to the enum's variants by NAME through
///        the lang item, never by value, so the numbering here is not an
///        ABI -- but keep the two lists identical anyway.
enum FormatKind derives u8 {
    None = 0,   ///< a trailing text segment; no argument.
    Bool, Char, Byte,
    I8, I16, I32, I64, I128, I256, I512,
    U8, U16, U32, U64, U128, U256, U512,
    ISize, USize,
    F8E4M3, F8E5M2, F16, BF16, F32, F64, F80, F128, F256, F512,
    String,     ///< a `string` value, converted or written.
    Ptr,        ///< an address as usize: `<aux> @ 0x…`, or `&null` when 0.
    COUNT,
}

fn to_string(k: FormatKind) -> string {
    switch k {
        case FormatKind::None   { return "None";   }
        case FormatKind::Bool   { return "Bool";   }
        case FormatKind::Char   { return "Char";   }
        case FormatKind::Byte   { return "Byte";   }
        case FormatKind::I8     { return "I8";     }
        case FormatKind::I16    { return "I16";    }
        case FormatKind::I32    { return "I32";    }
        case FormatKind::I64    { return "I64";    }
        case FormatKind::I128   { return "I128";   }
        case FormatKind::I256   { return "I256";   }
        case FormatKind::I512   { return "I512";   }
        case FormatKind::U8     { return "U8";     }
        case FormatKind::U16    { return "U16";    }
        case FormatKind::U32    { return "U32";    }
        case FormatKind::U64    { return "U64";    }
        case FormatKind::U128   { return "U128";   }
        case FormatKind::U256   { return "U256";   }
        case FormatKind::U512   { return "U512";   }
        case FormatKind::ISize  { return "ISize";  }
        case FormatKind::USize  { return "USize";  }
        case FormatKind::F8E4M3 { return "F8E4M3"; }
        case FormatKind::F8E5M2 { return "F8E5M2"; }
        case FormatKind::F16    { return "F16";    }
        case FormatKind::BF16   { return "BF16";   }
        case FormatKind::F32    { return "F32";    }
        case FormatKind::F64    { return "F64";    }
        case FormatKind::F80    { return "F80";    }
        case FormatKind::F128   { return "F128";   }
        case FormatKind::F256   { return "F256";   }
        case FormatKind::F512   { return "F512";   }
        case FormatKind::String { return "String"; }
        case FormatKind::Ptr    { return "Ptr";    }
        case FormatKind::COUNT  { return "<count>"; }
    }
    return "<unknown>";
}

/// The primitive's FormatKind row, or COUNT for a kind that is not a value
/// (Void, Never). Every value builtin has a row.
fn format_kind_of(b: BuiltinKind) -> FormatKind {
    switch b {
        case BuiltinKind::Bool   { return FormatKind::Bool;   }
        case BuiltinKind::Char   { return FormatKind::Char;   }
        case BuiltinKind::Byte   { return FormatKind::Byte;   }
        case BuiltinKind::I8     { return FormatKind::I8;     }
        case BuiltinKind::I16    { return FormatKind::I16;    }
        case BuiltinKind::I32    { return FormatKind::I32;    }
        case BuiltinKind::I64    { return FormatKind::I64;    }
        case BuiltinKind::I128   { return FormatKind::I128;   }
        case BuiltinKind::I256   { return FormatKind::I256;   }
        case BuiltinKind::I512   { return FormatKind::I512;   }
        case BuiltinKind::U8     { return FormatKind::U8;     }
        case BuiltinKind::U16    { return FormatKind::U16;    }
        case BuiltinKind::U32    { return FormatKind::U32;    }
        case BuiltinKind::U64    { return FormatKind::U64;    }
        case BuiltinKind::U128   { return FormatKind::U128;   }
        case BuiltinKind::U256   { return FormatKind::U256;   }
        case BuiltinKind::U512   { return FormatKind::U512;   }
        case BuiltinKind::ISize  { return FormatKind::ISize;  }
        case BuiltinKind::USize  { return FormatKind::USize;  }
        case BuiltinKind::F8E4M3 { return FormatKind::F8E4M3; }
        case BuiltinKind::F8E5M2 { return FormatKind::F8E5M2; }
        case BuiltinKind::F16    { return FormatKind::F16;    }
        case BuiltinKind::BF16   { return FormatKind::BF16;   }
        case BuiltinKind::F32    { return FormatKind::F32;    }
        case BuiltinKind::F64    { return FormatKind::F64;    }
        case BuiltinKind::F80    { return FormatKind::F80;    }
        case BuiltinKind::F128   { return FormatKind::F128;   }
        case BuiltinKind::F256   { return FormatKind::F256;   }
        case BuiltinKind::F512   { return FormatKind::F512;   }
        default                  { return FormatKind::COUNT;  }
    }
}

/// \enum FormatAlign  -- fmt.k's FormatAlign, same name-matching rule.
enum FormatAlign derives u8 { Default = 0, Left, Right, Center }

fn to_string(a: FormatAlign) -> string {
    switch a {
        case FormatAlign::Default { return "Default"; }
        case FormatAlign::Left   { return "Left";   }
        case FormatAlign::Right  { return "Right";  }
        case FormatAlign::Center { return "Center"; }
    }
    return "<unknown>";
}

/// FormatSeg::flags bits and the "no precision" value, as fmt.k defines
/// them. Two copies on purpose: the AST layer cannot read Lib/builtin, and
/// the runtime cannot read the compiler.
eval fn FMT_SIGN_PLUS() -> u8  { return 1;  }
eval fn FMT_ALT()       -> u8  { return 2;  }
eval fn FMT_ZERO()      -> u8  { return 4;  }
eval fn FMT_UPPER()     -> u8  { return 8;  }
eval fn FMT_DEBUG()     -> u8  { return 16; }

/// The spec word FStringLowering hands every put_* call; Lib/builtin/fmt.k
/// unpacks it bit for bit. All-defaults is 0.
///   bits  0..15 width (0 = none)     bits 16..31 precision + 1 (0 = none)
///   bits 32..52 fill codepoint (0 = ' ')   bits 53..54 align (FormatAlign)
///   bits 55..56 base (0 = 10, 1 = 16, 2 = 8, 3 = 2)   bits 57..61 FMT_* flags
fn fmt_pack_spec(width: u64, prec1: u64, fill: u64, align: u64, base: u64, flags: u64) -> u64 {
    return width | (prec1 << 16) | (fill << 32) | (align << 53) | (base << 55) | (flags << 57);
}

/// The FmtBuf method for a hole of this kind. `i32` is a keyword token, so
/// the methods carry a prefix.
fn fmt_put_name(k: FormatKind) -> string {
    if k == FormatKind::String { return "put_str"; }
    if k == FormatKind::Ptr    { return "put_ptr"; }
    if k == FormatKind::None   { return ""; }
    var s = to_string(k);
    var lower = "";
    for var i: usize = 0; i < s.size(); ++i {
        var c = s[i];
        if (c >= 'A') && (c <= 'Z') { c = c + 32; }
        lower += c;
    }
    return "put_" + lower;
}

/// \class LowerTargets
/// \brief The invented C++ name fragments. Nothing else in the compiler
///        carries a copy of any string here.
class LowerTargets {
    // --- Operators C++ cannot spell (writer: CXXSpell::operator_name) -----------

    /// `fn op in (self, x: T) -> bool` -- containment.
    static fn op_contains() -> string { return "__kairo_contains"; }
    /// `fn op in (self) -> yield T` -- iteration; IterLowering's output calls it.
    static fn op_iter()     -> string { return "__kairo_iter"; }
    /// `fn op ^^` -- exponentiation; not overloadable in C++.
    static fn op_pow()      -> string { return "__kairo_pow"; }
    /// `fn op .*` -- member-pointer access; not overloadable in C++.
    static fn op_dotstar()  -> string { return "__kairo_dotstar"; }
    /// `fn op await`.
    static fn op_await()    -> string { return "__kairo_await"; }
    /// `fn op spawn`.
    static fn op_spawn()    -> string { return "__kairo_spawn"; }
    /// `fn op thread`.
    static fn op_thread()   -> string { return "__kairo_thread"; }
    /// An extension operator's receiver in its C++ definition. The operator
    /// takes `X&` ([over.oper]/7 wants a class-typed parameter), and the
    /// body's first statement binds `self` to its address, so the body is
    /// emitted exactly as any other extension member's.
    static fn ext_self() -> string { return "__kairo_self"; }

    // --- Witnesses (writer: EmitWitness) -------------------------------------------------

    /// `<Interface>` + suffix: `Drawable_witness`, and the concept `Drawable_c`.
    static fn witness_suffix() -> string { return "_witness"; }
    static fn concept_suffix() -> string { return "_c"; }

    // --- Array prvalues (writer: InterfaceEmitter; reader: EmitIR) --------------------

    /// `template <class T, decltype(sizeof(0)) N> using __kairo_array = T[N];`
    /// An alias, so it is never instantiated: `__kairo_array<int, 3>` IS
    /// `int[3]`, given a name a functional cast can use.
    static fn array_alias() -> string { return "__kairo_array"; }

    // --- Materialized temporaries (writer: InterfaceEmitter; reader: EmitIR) ----------

    /// `template <class T> auto* __kairo_tmp(T&& t)`: the address of a
    /// prvalue's materialized temporary, valid to the end of the
    /// full-expression. ExtensionLowering's `materialize` `&` spells it.
    static fn tmp_addr() -> string { return "__kairo_tmp"; }

    /// The reserved identifier prefix. CxxNameCheck rejects user identifiers
    /// that start with it.
    static fn reserved_prefix() -> string { return "__kairo_"; }

    // --- Default arguments (writer: CallLowering) -------------------------------

    /// `__kairo_default_<fn>_<param>`: the nullary function a parameter's
    /// default becomes. CallLowering appends `_<k>` when the function's name
    /// cell holds more than one entity, k being the entity's 1-based position
    /// in the cell, which is source order and so the same in every TU.
    static fn default_thunk(fn_name: string, param: string) -> string {
        return "__kairo_default_" + fn_name + "_" + param;
    }
}