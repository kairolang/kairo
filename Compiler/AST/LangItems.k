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
    Nullable,   ///< T? lowering target: Nullable<T> (NullableTypeLowering).
    NullT,      ///< `null`'s type: null_t, whose constant C++ spells `null`.
    Panic,      ///< fn () panic -> T result type: `enum <T, ...E> Panic` (PANIC.md §1.1).

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

    RangeFrom,  ///< `a..` / `..` as a subscript index: RangeFrom<T>{ begin }.
    RangeTo,    ///< `..b` / `..=b` as a subscript index: RangeTo<T>{ end, inclusive }.

    UnwrapFailed, ///< `unwrap!(x)` on null: `fn unwrap_failed(msg, len) -> !` (CoalesceLowering).
    NicheOf,    ///< `__builtin_niche_of<T>()`: EnumLayoutLowering answers each call with niche_of(T).
    TypeIdOf,   ///< `__builtin_type_id<T>()`: T's panic type id (PANIC.md §1.3), answered like NicheOf.
    PanicSiteOf, ///< `__builtin_panic_site()`: the call's panic site id (PANIC.md §1.4), registered in the TU's site table.

    COUNT,      ///< keep last.
}

/// The lang item's NAME as the builtin root declares it: the ONE spelling.
/// `NameResolution::_bind_lang` looks this up, and every diagnostic that
/// names a missing item quotes it, so the two cannot drift -- a message
/// naming an item the tree does not declare is worse than no message.
fn to_string(k: WellKnownType) -> string {
    switch k {
        case WellKnownType::Future     { return "Future";     }
        case WellKnownType::Range      { return "Range";      }
        case WellKnownType::Yield      { return "Yield";      }
        case WellKnownType::Ordering   { return "Ordering";   }
        case WellKnownType::Nullable   { return "Nullable";   }
        case WellKnownType::NullT      { return "null_t";     }
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
        case WellKnownType::RangeFrom  { return "RangeFrom";  }
        case WellKnownType::RangeTo    { return "RangeTo";    }
        case WellKnownType::UnwrapFailed { return "unwrap_failed"; }
        case WellKnownType::NicheOf    { return "__builtin_niche_of"; }
        case WellKnownType::TypeIdOf   { return "__builtin_type_id"; }
        case WellKnownType::PanicSiteOf { return "__builtin_panic_site"; }
        case WellKnownType::COUNT      { return "<count>";    }
    }
    return "<unknown>";
}

/// The module roots the driver names, which no source file declares. The
/// builtin root is the prelude every TU imports and where the lang items
/// are bound from; std is NAMED `kairo::std` (its identity, and the C++
/// namespace it emits into, clear of C++'s own `std`) and SPELLED `std` in
/// source; `cxx` is the module ImportResolution mints over a bare ffi
/// import's headers, so C++'s `std` is reached as `cxx::std`. The resource
/// directory's `builtin/` and `std/` subdirectories share these words by
/// design but are layout, not names: the driver spells those itself.
fn builtin_root_name() -> string { return "builtin"; }
fn std_root_name() -> string     { return "kairo::std"; }
fn std_root_spelling() -> string { return "std"; }
fn cxx_root_name() -> string     { return "cxx"; }

/// Tuples exist up to this arity. Not a lang item: `(A, B)` is the record
/// `Tuple2<A, B>` that TupleRecords MINTS on first use (one per arity per
/// build, no source file behind it), and a written tuple wider than this
/// is rejected at the type (TypeParse, S055E). --cmax-tuple-arity may only
/// lower the cap: the arity is a u32 in every node that carries one, and
/// 128 is where a C++ struct of that many members stops being a type a
/// backend wants to see.
eval fn TUPLE_MAX_ARITY() -> usize { return 128; }

/// The ONE spelling of a tuple record and its members, read by TupleRecords
/// when it mints the pattern and by every message or test note that names
/// one. Nothing else writes `Tuple2`, `T0` or `_0` as a literal: the names
/// are a C++-facing ABI (`Tuple2<int, double>` with `._0`), and changing
/// them is a change here, not a sweep.
fn tuple_record_name(arity: usize) -> string { return f"Tuple{arity}"; }
fn tuple_param_name(i: usize)      -> string { return f"T{i}"; }
fn tuple_field_name(i: usize)      -> string { return f"_{i}"; }

/// \class LangMembers
/// \brief Members of lang items that the compiler finds BY NAME in the
///        item's own scope (Lib/builtin), then uses as declarations: a
///        lowering reads a Range's `begin` field or calls a Yield's `next`.
///        Not LowerTargets: those are names the compiler INVENTS; these are
///        declared in Kairo source, and CXXSpell spells the decl it finds.
///        One spelling each, as the tuple names above: a rename in
///        Lib/builtin is a change here, not a sweep. `data` and `len` repeat
///        across string and Slice on purpose -- two declarations that
///        happen to share a spelling, so two rows. FmtBuf's `put_*` family
///        is fmt_put_name, below.
class LangMembers {
    /// Range<T>, RangeFrom<T>, RangeTo<T> fields (base/range.k): IterLowering
    /// reads them, RangeLowering initializes them by designator.
    static fn range_begin() -> string     { return "begin"; }
    static fn range_end() -> string       { return "end"; }
    static fn range_inclusive() -> string { return "inclusive"; }
    /// Slice<T> fields (containers/slice.k): IterLowering walks a slice by them.
    static fn slice_data() -> string { return "data"; }
    static fn slice_len() -> string  { return "len"; }
    /// string fields (string.k): MatchLowering compares a string head's
    /// bytes, LiteralTyping sizes an f-string's buffer.
    static fn string_data() -> string { return "data"; }
    static fn string_len() -> string  { return "len"; }
    /// Yield<T> methods (coro/generator.k): the generator protocol IterLowering drives.
    static fn yield_next() -> string    { return "next"; }
    static fn yield_current() -> string { return "current"; }
    /// FmtBuf methods (fmt/fmt_buf.k) every f-string lowers onto.
    static fn fmtbuf_text() -> string   { return "text"; }
    static fn fmtbuf_finish() -> string { return "finish"; }
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
/// \brief The compiler's spelling of Lib/builtin/fmt/fmt_buf.k's FormatKind: what X
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

/// \enum FormatAlign  -- fmt_buf.k's FormatAlign, same name-matching rule.
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

/// FormatSeg::flags bits and the "no precision" value, as fmt_buf.k defines
/// them. Two copies on purpose: the AST layer cannot read Lib/builtin, and
/// the runtime cannot read the compiler.
eval fn FMT_SIGN_PLUS() -> u8  { return 1;  }
eval fn FMT_ALT()       -> u8  { return 2;  }
eval fn FMT_ZERO()      -> u8  { return 4;  }
eval fn FMT_UPPER()     -> u8  { return 8;  }
eval fn FMT_DEBUG()     -> u8  { return 16; }

/// The spec word FStringLowering hands every put_* call; Lib/builtin/fmt/fmt_buf.k
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

/// \p v as 16 lowercase hex digits: the stable suffix of a minted name
/// keyed by a hash (LowerTargets::type_id_guard, panic_site_record).
fn hex64(v: u64) -> string {
    var digits = "0123456789abcdef";
    var out = "";
    for var i: i32 = 15; i >= 0; --i {
        out += digits[usize((v >> u64(i * 4)) & u64(15))];
    }
    return out;
}

/// \p v as 8 lowercase hex digits (a panic type id in a message).
fn hex32(v: u32) -> string {
    var digits = "0123456789abcdef";
    var out = "";
    for var i: i32 = 7; i >= 0; --i {
        out += digits[usize((v >> u32(i * 4)) & u32(15))];
    }
    return out;
}

/// \class LangAttrs
/// \brief The `@name` attributes the compiler gives a meaning. Neither a
///        lang item (nothing declares them) nor a lower target (the user
///        writes them): the one spelling the parser stamps from and every
///        diagnostic quotes, so a message cannot name an attribute the
///        parser does not read.
class LangAttrs {
    /// `@copy fn T(self, other: Self)`: FunctionDecl::transfer (Parser).
    static fn transfer_copy() -> string { return "copy"; }
    /// `@move fn T(self, other: Self)`: FunctionDecl::transfer (Parser).
    static fn transfer_move() -> string { return "move"; }
    /// `@open enum E`: a plain enum that may hold any value of its
    /// underlying type, clang's `enum_extensibility(open)`. EnumDecl::is_open
    /// (Parser); no niche, `as` unchecked.
    static fn open_enum() -> string { return "open"; }
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
    /// `fn op await`.
    static fn op_await()    -> string { return "__kairo_await"; }
    /// `fn op spawn`.
    static fn op_spawn()    -> string { return "__kairo_spawn"; }
    /// `fn op thread`.
    static fn op_thread()   -> string { return "__kairo_thread"; }
    /// `fn op panic (const self) -> string` -- an error's message (PANIC.md
    /// §1.5); the C++ view's `what()` calls it (P7).
    static fn op_panic()    -> string { return "__kairo_op_panic"; }
    /// An extension operator's receiver in its C++ definition. The static
    /// member takes `X&` (so its forwarder, the C++ operator, has the
    /// class-typed parameter [over.oper]/7 wants), and the body's first
    /// statement binds `self` to its address, so the body is emitted exactly
    /// as any other extension member's.
    static fn ext_self() -> string { return "__kairo_self"; }
    /// An extension member's receiver as its C++ body sees it: the
    /// parameter of a non-operator member (InterfaceEmitter declares it,
    /// EmitIR defines it), the local an operator's body binds from
    /// ext_self, and every `self` and `[self]` capture EmitIR writes in
    /// that body. Not `__kairo_`-prefixed: it is Kairo's own keyword, which
    /// C++ does not reserve, so a body's `self` is spelled as written.
    static fn ext_receiver_name() -> string { return "self"; }
    /// The \p k-th parameter of an extension operator's namespace-scope C++
    /// `operator<sym>` forwarder (InterfaceEmitter::_forwarder), receiver
    /// included, a postfix `++`/`--` dummy last.
    static fn forwarder_arg(k: usize) -> string { return f"__kairo_a{k}"; }

    // --- Witnesses (writer: EmitWitness) -------------------------------------------------

    /// `<Interface>` + suffix: `Drawable_witness`, and the concept `Drawable_c`.
    static fn witness_suffix() -> string { return "_witness"; }
    static fn concept_suffix() -> string { return "_c"; }
    /// The primary's and the concept's Self parameter: where a requirement's
    /// bare `Self` is spelled inside the witness (CODEGEN.md §7b.3).
    static fn witness_self() -> string { return "__kairo_Self"; }
    /// The concept's requires-parameters: requirement \p i's receiver, and
    /// the \p k-th argument across all requirements.
    static fn witness_recv(i: usize) -> string { return f"__kairo_r{i}"; }
    static fn witness_arg(k: usize) -> string  { return f"__kairo_a{k}"; }
    /// A postfix `++`/`--` member's `int` dummy, forwarded as is.
    static fn witness_postfix() -> string { return "__kairo_pf"; }
    /// A witness member's receiver parameter, and the receiver its body and
    /// its requires-gate call through (`self->m(...)`). Kairo's keyword, as
    /// ext_receiver_name.
    static fn witness_receiver_name() -> string { return "self"; }
    /// The include guard around a witness definition in a header: every
    /// header that reaches one writes it, as a tuple record's. \p key is the
    /// witness and its Self, already an identifier (CXXSpell::_path_ident).
    static fn witness_guard(key: string) -> string { return "__KAIRO_W_" + key; }
    /// The guard around an interface's concept in a header (tier 0, apart
    /// from the primary's tier-1 definition, so a guard of its own).
    static fn concept_guard(key: string) -> string { return "__KAIRO_WC_" + key; }

    // --- Array prvalues (writer: InterfaceEmitter; reader: EmitIR) --------------------

    /// `template <class T, decltype(sizeof(0)) N> using __kairo_array = T[N];`
    /// An alias, so it is never instantiated: `__kairo_array<int, 3>` IS
    /// `int[3]`, given a name a functional cast can use.
    static fn array_alias() -> string { return "__kairo_array"; }

    // --- eval for / eval generators (writer: EmitIR; helpers: InterfaceEmitter) ---
    /// `template <class T, T... I> struct __kairo_iseq {}`: the index pack an
    /// `eval for` expands over (`__make_integer_seq<__kairo_iseq, ...>`).
    static fn eval_iseq() -> string { return "__kairo_iseq"; }
    /// The include guard around those helpers in a header.
    static fn eval_helpers_guard() -> string { return "__KAIRO_EVAL_HELPERS"; }
    /// The constexpr growable buffer an eval generator returns (`push`, `p`,
    /// `n`): transient compile-time allocation, freed before it escapes.
    static fn eval_buf() -> string { return "__kairo_eval_buf"; }
    /// `__kairo_eval_arr<T, N>`: an eval generator's values, copied out of
    /// its buffer into a literal type a `static constexpr` can hold.
    static fn eval_arr() -> string { return "__kairo_eval_arr"; }
    /// The members of those two EmitIR reads or calls: the buffer's storage,
    /// count and push (a generator's `yield`), the array's values. Plain
    /// names, as fn_value_own: members of a reserved type cannot collide.
    static fn eval_buf_data() -> string   { return "p"; }
    static fn eval_buf_count() -> string  { return "n"; }
    static fn eval_buf_push() -> string   { return "push"; }
    static fn eval_arr_values() -> string { return "v"; }
    /// An eval generator's buffer local, which `yield` pushes into.
    static fn eval_yield_buf() -> string { return "__kairo_y"; }
    /// One `eval for`'s pack and per-copy index.
    /// `d` is the nesting depth: an inner expansion's template parameters
    /// may not shadow an outer one's.
    static fn eval_for_pack(d: u32) -> string { return f"__kairo_K{d}"; }
    static fn eval_for_index(d: u32) -> string { return f"__kairo_I{d}"; }
    /// The per-copy constant of an `eval for` that binds no name.
    static fn eval_for_unused() -> string { return "__kairo_ef_unused"; }
    /// A `return` out of an `eval for` copy: the flag and the value slot the
    /// code after the expansion checks.
    static fn eval_for_ret_flag() -> string { return "__kairo_efr"; }
    static fn eval_for_ret_val() -> string { return "__kairo_efv"; }
    /// An eval generator iterable's count and values, `k` counting them in
    /// the function.
    static fn eval_for_gen_n(k: usize) -> string { return f"__kairo_egn{k}"; }
    static fn eval_for_gen(k: usize) -> string { return f"__kairo_eg{k}"; }
    /// `template <unsigned char... C> inline constexpr unsigned char
    /// __kairo_estr[] = {C..., 0};`: a string literal's bytes where C++
    /// reads them at compile time (EVAL.md 2a). `"..."` is `const char[]`
    /// and the builtin string holds `const unsigned char*`, so the run-time
    /// spelling needs a `reinterpret_cast`, which is not a constant
    /// expression. Keyed on the bytes, so one literal is one object in every
    /// TU and header that spells it (an eval string's `data` is the same
    /// address everywhere, and a header body naming it is no ODR hazard),
    /// and no array has to be hoisted ahead of the body that names it.
    static fn eval_str() -> string { return "__kairo_estr"; }
    /// The most bytes a compile-time literal spells as `__kairo_estr<...>`
    /// (EVAL.md §11, USER: a size switch). One template argument per byte is
    /// fine for names and messages; a multi-kilobyte literal (an
    /// `embed_str!` result, a table) would be a template with thousands of
    /// arguments and a mangled name to match. Above it the literal is one
    /// named array, eval_str_hashed.
    static fn eval_str_inline_max() -> usize { return 256; }
    /// `inline constexpr unsigned char __kairo_estrh_<len>_<hash>[len + 1]`:
    /// a long compile-time literal's bytes, named for its content (FNV-1a
    /// over the bytes, eval_str_hash) and length, so the same literal is
    /// the same `inline` entity in every TU and header that writes it (no
    /// ODR hazard, one object after linking) and two different ones never
    /// share a name short of a 64-bit collision at equal length. At global
    /// scope, so `::` reaches it from any namespace.
    static fn eval_str_hashed(hash: u64, len: usize) -> string {
        return f"__kairo_estrh_{len}_" + hex64(hash);
    }
    /// A header's guard around one eval_str_hashed definition: two Kairo
    /// headers in one C++ TU may both carry it.
    static fn eval_str_hashed_guard(hash: u64, len: usize) -> string {
        return f"__KAIRO_ESTRH_{len}_" + hex64(hash);
    }
    /// FNV-1a, 64 bits, over \p n bytes at \p p: eval_str_hashed's key.
    static fn eval_str_hash(p: std::ConstPtr::<u8>, n: usize) -> u64 {
        var h: u64 = u64(0xcbf29ce484222325);
        for var i: usize = 0; i < n; ++i {
            h = h ^ static_cast::<u64>(p[i]);
            h = h * u64(0x100000001b3);
        }
        return h;
    }

    // --- Extension scopes (writer: InterfaceEmitter; reader: CXXSpell) -----------------

    /// `struct N::__kairo_ext_<X>`: every extension member of X declared in
    /// namespace N is a static member of it (RESOLUTION.md §2b).
    static fn ext_scope_prefix() -> string { return "__kairo_ext_"; }

    /// An extension operator's static-member name. A static member cannot be
    /// named `operator+`, so it gets a mnemonic, and a namespace-scope
    /// `operator+` forwarder (InterfaceEmitter) gives C++ callers the
    /// operator. \p sym is OperatorFacts' symbol, with `l`/`r` kept on
    /// `++`/`--` (an unmarked one is prefix). The operators with a name
    /// above (`in`, `^^`, `await`, `spawn`, `thread`) keep it and never
    /// reach here. "" for a symbol with no row; the caller ICEs.
    static fn ext_op(sym: string) -> string {
        var p = "__kairo_op_";
        if sym == "+"   { return p + "plus"; }
        if sym == "-"   { return p + "minus"; }
        if sym == "*"   { return p + "mul"; }
        if sym == "/"   { return p + "div"; }
        if sym == "%"   { return p + "mod"; }
        if sym == "=="  { return p + "eq"; }
        if sym == "!="  { return p + "ne"; }
        if sym == "<"   { return p + "lt"; }
        if sym == "<="  { return p + "le"; }
        if sym == ">"   { return p + "gt"; }
        if sym == ">="  { return p + "ge"; }
        if sym == "<=>" { return p + "cmp"; }
        if sym == "&"   { return p + "band"; }
        if sym == "|"   { return p + "bor"; }
        if sym == "^"   { return p + "bxor"; }
        if sym == "~"   { return p + "bnot"; }
        if sym == "<<"  { return p + "shl"; }
        if sym == ">>"  { return p + "shr"; }
        if sym == "+="  { return p + "plus_eq"; }
        if sym == "-="  { return p + "minus_eq"; }
        if sym == "*="  { return p + "mul_eq"; }
        if sym == "/="  { return p + "div_eq"; }
        if sym == "%="  { return p + "mod_eq"; }
        if sym == "&="  { return p + "band_eq"; }
        if sym == "|="  { return p + "bor_eq"; }
        if sym == "^="  { return p + "bxor_eq"; }
        if sym == "<<=" { return p + "shl_eq"; }
        if sym == ">>=" { return p + "shr_eq"; }
        if sym == "l++" { return p + "preinc"; }
        if sym == "r++" { return p + "postinc"; }
        if sym == "l--" { return p + "predec"; }
        if sym == "r--" { return p + "postdec"; }
        if sym == "!"   { return p + "not"; }
        return "";
    }

    /// A witness member's name for an `op []` requirement. A witness member
    /// is static, as an extension member is, but `op []` is member-only
    /// (OperatorSignatureCheck), so ext_op has no row for it: only the
    /// witness ever needs this name, and no forwarder goes with it.
    static fn witness_subscript() -> string { return "__kairo_op_index"; }

    /// A witness member's name for an `op as` requirement (an interpolation
    /// or a cast through a bound, MONO.md G11). Like `op []` it has no
    /// extension row. One name per interface: two `op as` requirements of
    /// one interface differ only in their return type, which C++ cannot
    /// overload on (ticketed).
    static fn witness_conversion() -> string { return "__kairo_op_as"; }

    /// `static constexpr unsigned __kairo_spec = k;` in the primary (0) and
    /// each partial specialization (1 + its registration index) of a
    /// template that has a `requires`-selected partial, and the
    /// `static_assert(X<A>::__kairo_spec == k)` beside an instance's explicit
    /// instantiation: Sema predicted k, C++ selected the body (MONO.md G12).
    static fn spec_tag() -> string { return "__kairo_spec"; }

    // --- Materialized temporaries (writer: InterfaceEmitter; reader: EmitIR) ----------

    /// `template <class T> auto* __kairo_tmp(T&& t)`: the address of a
    /// prvalue's materialized temporary, valid to the end of the
    /// full-expression. ExtensionLowering's `materialize` `&` spells it.
    static fn tmp_addr() -> string { return "__kairo_tmp"; }

    /// The checked downcast's pointer, the parameter of the lambda EmitIR
    /// wraps `dynamic_cast` in to map its null onto the null nullable
    /// (EmitIR::_checked_downcast). Local to that lambda.
    static fn checked_downcast_value() -> string { return "__kairo_dc"; }

    /// The reserved identifier prefix. CxxNameCheck rejects user identifiers
    /// that start with it.
    static fn reserved_prefix() -> string { return "__kairo_"; }

    /// The include guard around a tuple record's definition (writer:
    /// InterfaceEmitter). A tuple record is minted from no file, so no
    /// header owns it: every TU and header that reaches `Tuple2` defines
    /// it, and a C++ TU that includes two such headers sees it twice.
    static fn tuple_guard(arity: usize) -> string { return f"__KAIRO_TUPLE_{arity}"; }
    /// The include guard around the preamble helpers (`__kairo_array`,
    /// `__kairo_tmp`, `__kairo_vt`, construct/destroy) in a header (writer:
    /// InterfaceEmitter): one C++ TU may include several Kairo headers.
    static fn lower_helpers_guard() -> string { return "__KAIRO_LOWER_HELPERS"; }

    // --- Default arguments (writer: CallLowering) -------------------------------

    /// `__kairo_default_<fn>_<param>`: the nullary function a parameter's
    /// default becomes. CallLowering appends `_<k>` when the function's name
    /// cell holds more than one entity, k being the entity's 1-based position
    /// in the cell, which is source order and so the same in every TU.
    static fn default_thunk(fn_name: string, param: string) -> string {
        return "__kairo_default_" + fn_name + "_" + param;
    }

    // --- `where` dispatch (writer: WhereDispatchLowering) ----------------------

    /// `__kairo_where_<fn>_<k>`: the body of the k-th member, in source
    /// order, of a `where` dispatch group of `fn`; the group's dispatcher
    /// keeps the public name and calls these. Two groups of one name have
    /// different signatures, so their candidates are C++ overloads of each
    /// other, never a collision.
    static fn where_candidate(fn_name: string, k: usize) -> string {
        return "__kairo_where_" + fn_name + f"_{k}";
    }

    // --- Field initializers (writer: FieldInitLowering) -------------------------

    /// `__kairo_init_<field>`: the member function a field's initializer
    /// becomes, called by the field's C++ default member initializer. A
    /// field name is unique in its record, so this name is too.
    static fn field_init_thunk(field: string) -> string {
        return "__kairo_init_" + field;
    }

    /// `__kairo_init<i>_<field>`: element \p i of an array field's list
    /// literal (FieldFold::Elems). A digit follows `init`, where the one
    /// above has `_`, so no field's name makes the two collide.
    static fn field_init_elem_thunk(field: string, i: usize) -> string {
        return f"__kairo_init{i}_" + field;
    }

    // --- finally (writer: FinallyLowering) -----------------------------------------

    /// `__kairo_FinK` is the record a `finally` becomes, `__kairo_finK` the
    /// local of it, `k` counting finallys in the TU; the owner field holds
    /// the enclosing `self`.
    static fn finally_record(k: usize) -> string { return f"__kairo_Fin{k}"; }
    static fn finally_local(k: usize)  -> string { return f"__kairo_fin{k}"; }
    static fn finally_owner()          -> string { return "__kairo_owner"; }

    // --- match (writer: MatchLowering) -----------------------------------------
    /// Labels are function-scoped in C++; `n` is the match's number within its function.
    static fn match_scrutinee(n: usize) -> string          { return f"__kairo_m{n}_s"; }
    static fn match_column(n: usize, c: usize) -> string   { return f"__kairo_m{n}_s{c}"; }
    static fn match_arm(n: usize, k: usize) -> string      { return f"__kairo_m{n}_a{k}"; }
    static fn match_node(n: usize, k: usize) -> string     { return f"__kairo_m{n}_t{k}"; }
    static fn match_guard(n: usize, k: usize) -> string    { return f"__kairo_m{n}_g{k}"; }
    static fn match_slot(n: usize, i: usize) -> string     { return f"__kairo_m{n}_p{i}"; }
    static fn match_end(n: usize) -> string                { return f"__kairo_m{n}_end"; }
    static fn match_fail(n: usize) -> string               { return f"__kairo_m{n}_fail"; }
    static fn match_arm_index(n: usize) -> string          { return f"__kairo_m{n}_arm"; }
    static fn match_cont(n: usize) -> string               { return f"__kairo_m{n}_k"; }

    // --- labeled loops (writer: LabelLowering) -------------------------------------
    /// `k` counts labeled loops in the function: a label name can repeat.
    static fn loop_break(k: usize, label: string) -> string    { return f"__kairo_brk{k}_" + label; }
    static fn loop_continue(k: usize, label: string) -> string { return f"__kairo_cont{k}_" + label; }

    // --- ADT enums (writer: EnumLayoutLowering) ---------------------------------
    static fn adt_tag_field() -> string              { return "__kairo_tag"; }
    static fn adt_tag_type() -> string               { return "__kairo_Tag"; }
    static fn adt_payload_field(v: string) -> string { return "__kairo_" + v; }
    static fn adt_payload_type(v: string) -> string  { return "__kairo_" + v + "_t"; }
    static fn adt_variant_tag() -> string            { return "__kairo_vt"; }
    static fn adt_destroy() -> string                { return "__kairo_destroy"; }
    static fn adt_construct_from() -> string         { return "__kairo_construct_from"; }
    static fn adt_trivial_dtor() -> string           { return "__kairo_trivial_dtor"; }
    static fn adt_trivial_copy() -> string           { return "__kairo_trivial_copy"; }
    static fn adt_destructible() -> string           { return "__kairo_destructible"; }
    static fn adt_copyable() -> string               { return "__kairo_copyable"; }
    static fn adt_movable() -> string                { return "__kairo_movable"; }
    /// A pack-expanded variant (PANIC.md §1.2): its payload member is a
    /// `__kairo_pu<P<E>...>`, the preamble's recursive union holding one
    /// payload per element, read through `.template __kairo_get<K>()`; its
    /// payload struct is a template over the element, `__kairo_pe`. The
    /// union's own two members are its head and the rest.
    static fn adt_pack_union() -> string             { return "__kairo_pu"; }
    static fn adt_pack_get() -> string               { return "__kairo_get"; }
    static fn adt_pack_elem() -> string              { return "__kairo_pe"; }
    static fn adt_pack_head() -> string              { return "__kairo_h"; }
    static fn adt_pack_rest() -> string              { return "__kairo_r"; }
    static fn adt_pack_guard() -> string             { return "__KAIRO_PACK_UNION"; }
    /// The Nullable lang item's C++ members and `null_t`'s constant (writer:
    /// EnumLayoutLowering names the roles, InterfaceEmitter spells them).
    /// Not `__kairo_`-prefixed: a C++ host calls them.
    static fn nullable_is_null() -> string           { return "is_null"; }
    static fn nullable_value() -> string             { return "__value"; }
    static fn null_constant() -> string              { return "null"; }
    /// The parameter of Nullable's `null_t` constructor (EnumLayoutLowering
    /// mints the ParamDecl). Unprefixed like the members above: a C++ host
    /// sees it in the declaration.
    static fn nullable_null_param() -> string        { return "n"; }
    /// The niche machinery (EnumLayoutLowering decides, InterfaceEmitter
    /// writes). `__kairo_niche<T>` is the preamble trait answering a type's
    /// niche in C++: `count` invalid bit patterns, the i-th built by
    /// `pattern(i)` and recognized by `test(v, i)`. An ADT record carries
    /// its own answer as `__kairo_niche_count`, a `(__kairo_np, i)`
    /// constructor and `__kairo_niche_test`; the trait reads those.
    /// `__kairo_which()` is the variant held, in whichever layout C++ chose
    /// for a generic ADT's instance.
    static fn niche_trait() -> string                { return "__kairo_niche"; }
    static fn niche_trait_count() -> string          { return "count"; }
    static fn niche_trait_pattern() -> string        { return "pattern"; }
    static fn niche_trait_test() -> string           { return "test"; }
    static fn niche_ctor_tag() -> string             { return "__kairo_np"; }
    static fn niche_count() -> string                { return "__kairo_niche_count"; }
    static fn niche_test() -> string                 { return "__kairo_niche_test"; }
    static fn adt_which() -> string                  { return "__kairo_which"; }
    /// The u32 slot a lang item's layout may ask for between the tag and the
    /// payload union (EnumDecl::adt_site_field; PANIC.md §1.4's call site).
    static fn adt_site_field() -> string             { return "__kairo_site"; }
    /// The Panic lang item's layout (PANIC.md §1.1a; writer
    /// EnumLayoutLowering's knobs, InterfaceEmitter spells them). The union
    /// is `alignas(__kairo_payload_offset)`, the max of 8 and every payload's
    /// alignment, which is also where every payload starts: the "trait"
    /// §4.6 reads instead of a hardcoded 8. An element's tag is its type id,
    /// `__kairo_type_id<E>`, read off the per-type specialization of the
    /// incomplete trait `__kairo_tid<E>` (an element with none is a compile
    /// error, never a silent 0), each guarded by `__KAIRO_TID_<key>` so a
    /// kcc include chain writes it once. `__kairo_nv<T>` is T, or an empty
    /// struct for `void`: `Panic<void, E...>`'s Ok payload.
    static fn adt_payload_offset() -> string         { return "__kairo_payload_offset"; }
    static fn type_id_trait() -> string              { return "__kairo_tid"; }
    static fn type_id() -> string                    { return "__kairo_type_id"; }
    static fn type_id_guard(key: u64) -> string      { return "__KAIRO_TID_" + hex64(key); }
    static fn void_unit() -> string                  { return "__kairo_nv"; }
    static fn unit_type() -> string                  { return "__kairo_unit"; }
    static fn void_unit_trait() -> string            { return "__kairo_nv_s"; }
    /// `max(floor, alignof(P)...)`, the initializer of __kairo_payload_offset.
    static fn max_align() -> string                  { return "__kairo_max_align"; }
    static fn panic_helpers_guard() -> string        { return "__KAIRO_PANIC_HELPERS"; }
    /// PanicLowering's C++ (PANIC.md §4.3, §4.4; writers InterfaceEmitter's
    /// _panic_helpers and EmitIR's PanicOpExpr). `__kairo_fwd<R, A>(s)`
    /// widens the panic result `s` into R: the bytes as they are when the
    /// two layouts agree, else one case per element (`__kairo_fwd_k`), each
    /// built into R's element by `__kairo_pidx<X>` (X's position in R's
    /// set). A = true forwards Ok too. `__kairo_raw<T>` is raw storage for
    /// a T built later: a union over `__kairo_rbox<T>` (which brings its
    /// own placement `new`, so no <new>), read once by `__kairo_take()`,
    /// which moves the value out and destroys the box.
    static fn panic_fwd() -> string                  { return "__kairo_fwd"; }
    static fn panic_fwd_step() -> string             { return "__kairo_fwd_k"; }
    static fn panic_elem_index() -> string           { return "__kairo_pidx"; }
    /// A panic set naming a type parameter (a generic body, PANIC.md P10) is
    /// ordered by C++ at each instance: `__kairo_pset<P, T, E...>` is
    /// `P<T, E'...>` with E' the elements deduplicated and sorted by type id,
    /// the canonical order Sema forms every concrete set in (§1.3), so a
    /// template's result and a concrete caller's are one type. Built by
    /// insertion over a type list (`__kairo_ptl`): `__kairo_pins` places one
    /// element (`__kairo_pins_at` by its id against the list's head),
    /// `__kairo_pcons` prepends, `__kairo_psort` folds the elements in,
    /// `__kairo_papply` makes the record.
    static fn panic_set_alias() -> string            { return "__kairo_pset"; }
    static fn panic_set_list() -> string             { return "__kairo_ptl"; }
    static fn panic_set_insert() -> string           { return "__kairo_pins"; }
    static fn panic_set_insert_at() -> string        { return "__kairo_pins_at"; }
    static fn panic_set_cons() -> string             { return "__kairo_pcons"; }
    static fn panic_set_sort() -> string             { return "__kairo_psort"; }
    static fn panic_set_apply() -> string            { return "__kairo_papply"; }
    static fn raw_slot() -> string                   { return "__kairo_raw"; }
    static fn raw_slot_guard() -> string             { return "__KAIRO_RAW_SLOT"; }
    static fn raw_box() -> string                    { return "__kairo_rbox"; }
    static fn raw_box_member() -> string             { return "__kairo_b"; }
    static fn raw_box_value() -> string              { return "__kairo_v"; }
    static fn raw_take() -> string                   { return "__kairo_take"; }
    /// A `fn` value whose set widens (EmitIR::_fn_effect_value): its call's
    /// result as the wider panic result, and the wrapper's captured value
    /// and parameter names.
    static fn panic_call_as() -> string              { return "__kairo_pcall"; }
    static fn panic_wrapped() -> string              { return "__kairo_w"; }
    static fn panic_wrap_arg(i: usize) -> string     { return f"__kairo_a{i}"; }
    /// The per-TU panic site table (PANIC.md §1.4): one record per site, a
    /// `__kairo_panic_site` named `__kairo_ps_<key>` (key: the 64-bit hash
    /// of the site's path and offset), in the linker-collected section.
    /// Mach-O names a section `segment,section` in at most 16 bytes, hence
    /// its own spelling.
    static fn panic_site_type() -> string            { return "__kairo_panic_site"; }
    static fn panic_site_guard() -> string           { return "__KAIRO_PANIC_SITE_T"; }
    static fn panic_site_record(key: u64) -> string  { return "__kairo_ps_" + hex64(key); }
    static fn panic_sites_section() -> string        { return "__kairo_panic_sites"; }
    static fn panic_sites_section_macho() -> string  { return "__DATA,__kairo_psite"; }
    /// The table's bounds, which the linker defines: `__start_<section>` /
    /// `__stop_<section>` on ELF (declared weak, so a program with no site
    /// still links), `section$start$__DATA$__kairo_psite` on Mach-O.
    static fn panic_sites_start() -> string          { return "__start_" + LowerTargets::panic_sites_section(); }
    static fn panic_sites_stop() -> string           { return "__stop_" + LowerTargets::panic_sites_section(); }
    static fn panic_sites_start_macho() -> string    { return "section$start$__DATA$__kairo_psite"; }
    static fn panic_sites_stop_macho() -> string     { return "section$end$__DATA$__kairo_psite"; }
    static fn panic_sites_begin_sym() -> string      { return "__kairo_psites_begin"; }
    static fn panic_sites_end_sym() -> string        { return "__kairo_psites_end"; }
    /// The C++ view of a panic result (PANIC.md §4.6), for C++ code calling
    /// Kairo: free templates in `::builtin`, beside `::builtin::null`. Each
    /// public name is the documented API (c-cpp-exceptions.mdx); the
    /// `__kairo_` ones are its machinery. `__kairo_tid<E>::name` is E's
    /// Kairo name, what `what()` prints; `__kairo_pmsg<E>::get(e)` is an
    /// `extend`'s `op panic` (a type's own is the member `__kairo_op_panic`).
    static fn panic_api_ns() -> string               { return "builtin"; }
    static fn panic_api_guard() -> string            { return "__KAIRO_PANIC_API"; }
    static fn panic_api_ok() -> string               { return "ok"; }
    static fn panic_api_value() -> string            { return "value"; }
    static fn panic_api_is() -> string               { return "is"; }
    static fn panic_api_error() -> string            { return "error"; }
    static fn panic_api_site() -> string             { return "site"; }
    static fn panic_api_source_site() -> string      { return "source_site"; }
    static fn panic_api_type_id() -> string          { return "type_id"; }
    static fn panic_api_set() -> string              { return "panic_set"; }
    static fn panic_api_types() -> string            { return "panic_types"; }
    static fn panic_api_error_type() -> string       { return "panic_error"; }
    static fn panic_api_error_base() -> string       { return "panic_error_base"; }
    static fn panic_api_value_or_throw() -> string   { return "value_or_throw"; }
    static fn panic_api_impl() -> string             { return "__kairo_papi"; }
    static fn panic_api_throw() -> string            { return "__kairo_pthrow"; }
    static fn panic_api_text() -> string             { return "__kairo_what"; }
    static fn panic_api_build() -> string            { return "__kairo_build"; }
    static fn panic_api_drop() -> string             { return "__kairo_drop"; }
    static fn type_id_name() -> string               { return "name"; }
    static fn panic_msg_trait() -> string            { return "__kairo_pmsg"; }
    static fn panic_msg_get() -> string              { return "get"; }
    /// A prefix-tagged ADT's union member holding only the tag, and its type
    /// (EnumDecl::adt_tag_member): the tag is read through it.
    static fn adt_tag_member() -> string             { return "__kairo_t"; }
    static fn adt_tag_only_type() -> string          { return "__kairo_t_t"; }
    static fn niche_guard() -> string                { return "__KAIRO_NICHE_HELPERS"; }
    static fn construct_at() -> string               { return "__kairo_construct_at"; }
    static fn destroy_at() -> string                 { return "__kairo_destroy_at"; }

    // --- fn values and closures (writers: InterfaceEmitter, CXXSpell, EmitIR) ---
    /// `template <class S> class __kairo_fn`: a Kairo `fn(A) -> R` value,
    /// specialized on `R(A...)`. It holds either a plain function pointer
    /// or a heap-allocated lambda (a capturing closure), copies and frees
    /// the lambda, and converts back to `R(*)(A...)` for a C callee
    /// (CODEGEN.md §6, Closures). `own` adopts a `new`ed lambda. The guard
    /// is the header's.
    static fn fn_value() -> string        { return "__kairo_fn"; }
    static fn fn_value_own() -> string    { return "own"; }
    static fn fn_value_guard() -> string  { return "__KAIRO_FN_HELPERS"; }

    // --- const fields in a constructor (writers: InterfaceEmitter, EmitIR) ------
    /// The preamble helpers: `__kairo_slot<T>`, a value S_pre fills that does
    /// not exist until its first assignment, and `__kairo_lref<T>`, `T&` for
    /// any parameter spelling (reference collapsing). Their header guard.
    static fn ctor_slot() -> string       { return "__kairo_slot"; }
    static fn lref() -> string            { return "__kairo_lref"; }
    static fn ctor_slot_guard() -> string { return "__KAIRO_CTOR_SLOT_HELPERS"; }
    /// `__kairo_slot<T>`'s members EmitIR uses: whether S_pre built the
    /// value, a first assignment, a later one, a read, the hand-off to the
    /// field's initializer (InterfaceEmitter::_ctor_slot_helpers).
    static fn ctor_slot_set() -> string  { return "set"; }
    static fn ctor_slot_init() -> string { return "init"; }
    static fn ctor_slot_put() -> string  { return "put"; }
    static fn ctor_slot_get() -> string  { return "get"; }
    static fn ctor_slot_take() -> string { return "take"; }
    /// An array slot's element-by-element build: `init_at(k, e)` constructs
    /// element k (CtorInitCheck allows each once), and the slot counts as
    /// built once all N are.
    static fn ctor_slot_init_at() -> string { return "init_at"; }
    /// The compiler builtin that makes an index pack (`__make_integer_seq<
    /// Q, usize, N>` is `Q<usize, 0, ..., N-1>`): an array slot builds its
    /// elements from one with no <utility>.
    static fn make_index_seq() -> string { return "__make_integer_seq"; }
    /// Per split constructor k of a record (FunctionDecl::ci_index): its slot
    /// record, its pre-function, and the slot record's parameter name in
    /// both. A local carried across is slot `__kairo_l<i>_<name>`, i its
    /// position in ci_slots (two S_pre scopes may reuse a name).
    static fn ctor_slots(k: u32) -> string { return f"__kairo_ci{k}"; }
    static fn ctor_pre(k: u32) -> string   { return f"__kairo_ctor_pre{k}"; }
    static fn ctor_slot_arg() -> string    { return "__kairo_s"; }
    static fn ctor_local_slot(i: usize, name: string) -> string { return f"__kairo_l{i}_" + name; }

    // --- Exported records (writer: TypeExport) ----------------------------------

    /// The \p i-th field of the clang stand-in TypeExport builds for a Kairo
    /// record in phase A's AST. The stand-in carries layout only, and phase B
    /// compiles against the real record, so the fields need no real names.
    static fn export_field(i: usize) -> string { return f"__kairo_f{i}"; }
}