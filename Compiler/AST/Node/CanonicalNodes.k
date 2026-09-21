/// --- The Kairo Project ------------------- AST/Node/CanonicalNodes.k --- ///
///
///   \brief The two type nodes the PARSER never produces: BuiltinType and
///          RecordType. Both exist only as canonical forms, created solely by
///          CanonicalTypeStore.
///
///   \detail
///     Every other TypeKind is a piece of SYNTAX, `*T`, `[T]`, `Foo::Bar<U>`
///     \and the parser builds it from tokens. These two are not syntax:
///
///     BuiltinType    `i32` lexes as the keyword token AtI32, not as an
///                    identifier, so it is in no symbol table and resolves by
///                    token kind rather than by lookup. It is a universal
///                    entity (Clang's IntTy model): one singleton per kind per
///                    build, owned by the store, referenced by every TU.
///
///     RecordType     the canonical form of a nominal type USE. `Foo` and
///                    `ns::Foo` and an imported `Foo` are three different
///                    ChainType nodes naming ONE entity; they all canonicalize
///                    to the same RecordType(canonical decl, canonical args).
///                    Without it a ChainType's canonical could only point at
///                    another ChainType, and type identity would degrade to
///                    "whichever spelling was resolved first".
///
///     QualifiedType  the canonical form of a cv-qualified type. A written
///                    `const` is a TypeQual flag on the SYNTAX node; the
///                    canonical it resolves to is qualified(CONST, inner),
///                    one interned node per (quals, inner). Identity keeps
///                    it: `W<const i32>` and `W<i32>` are two instances,
///                    `g(*const i32)` and `g(*i32)` two overloads. The
///                    top-level cv of a VALUE is stripped by whoever reads
///                    the value (Conversion, the inferred-slot writers,
///                    signature identity), never by the store.
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
import AST::Node::Casting::*;
import Token::TokenKind::*;

/// \enum BuiltinKind
/// \brief The primitive value types. One singleton Type node per entry, owned
///        by CanonicalTypeStore and shared build-wide.
///
/// \detail
///   Ordering is arbitrary and is NOT an ABI: the store indexes an array by
///   it, nothing else depends on the numbers. Insert anywhere, keep COUNT
///   last.
///
///   These are not names. A builtin never enters a SymbolTable, never rides
///   the import overlay, and can never be shadowed, `i32` lexes as the
///   keyword token AtI32 and TypeResolution asks `builtin_for_token()` before
///   it asks any table anything. That is why `var i32 = 3` cannot break
///   `var x: i32`, and why none of these have a `WellKnownType` row.
///
/// \par WIDTH IS NOT IDENTITY
///   Three widths now carry more than one entry, and this is the invariant
///   most likely to be violated by accident:
///
///     8 bits   `F8E4M3`, `F8E5M2`, `I8`, `U8`, `Byte`
///     16 bits  `F16`, `BF16`, `I16`, `U16`
///     32 bits  `F32`, `I32`, `U32`, `Char`
///
///   builtin_info()->bits answers "how wide", never "which type". A float
///   comparison keyed on width alone silently conflates F16 with BF16 and
///   F8E4M3 with F8E5M2, neither pair is interconvertible without
///   rounding, and neither is the other's canonical. Ask
///   builtin_info()->fp instead. Same for Byte vs U8 and Char vs U32:
///   same width, distinct types, distinct rules.
///
/// \par Codegen is not uniform, and the enum does not hide it
///   Four different lowering strategies appear below. The type-level view is
///   uniform, every entry is a BuiltinType singleton with real size_bits
///   and itself as canonical, but the emitted C++ is not, and the
///   difference is documented per entry rather than inferred from the name:
///
///     native      a C++/LLVM type exists; emit it and stop.
///     legalized   LLVM has the type and splits it; free multi-word codegen.
///     libcall     LLVM has the type and calls compiler-rt; correct, slow.
///     corelib     LLVM has NO type; kairo::rt struct, arithmetic in f32/f64.
///
enum BuiltinKind derives u8 {
    /// The empty type. Not a value type: no storage, no literals, legal only
    /// as a return type and as the pointee of an untyped pointer.
    Void = 0,

    /// The type of an expression that does not produce a value because
    /// control never reaches its end: a `-> !` call, `return`, `break`.
    /// Not spellable in type position, `-> !` is recorded on the
    /// declaration as is_noreturn and mapped here, so `builtin_for_token()`
    /// has no row for it. Convertible TO everything (a diverging arm joins
    /// with any other arm) and FROM nothing.
    Never,

    /// One byte in memory, not one bit, addressability. Valid values are
    /// exactly {0, 1}; bool->integer is ALWAYS zext, never sext. `true` and
    /// `false` are keyword tokens lexed to literal nodes, not shadowable
    /// identifiers, so there is no library enum and no underlying type to
    /// configure. Match exhaustiveness knows it has exactly two inhabitants.
    Bool,

    /// # Integers
    ///
    /// I8..I64 / U8..U64 are native: one register, one instruction.
    ///
    /// I128..I512 / U128..U512 are LEGALIZED. LLVM supports arbitrary-width
    /// integers, so codegen emits `iN` and legalization breaks it into
    /// multi-word carry chains using the target's native width, SIMD where
    /// profitable, all for free, on every architecture. No corelib code
    /// exists for these and none is needed. The cost is instruction count,
    /// not calls: roughly 2-4x at 128 bits, 8-16x at 256, 20-40x at 512
    /// versus i64. Document that in the language docs; it is real, and it is
    /// still faster than any heap-limb bignum an ecosystem crate would give.

    I8, I16, I32, I64, I128, I256, I512,
    U8, U16, U32, U64, U128, U256, U512,

    /// Pointer-width integers. Their size is TARGET-dependent, so unlike the
    /// fixed-width entries above their `size_bits` is filled from the target
    /// triple at store construction, not from the name.` builtin_info()->bits`
    /// returns 0 for these two on purpose, 0 means "ask the store".
    USize, ISize,

    /// # 8-bit floats
    ///
    /// OCP 8-bit Floating Point Specification. Two formats, and the split is
    /// not arbitrary: `E4M3` spends its bits on precision (weights and
    /// activations), `E5M2` spends them on range and mirrors F16's exponent
    /// field exactly, which makes `F16`<->`E5M2` conversion a shift rather than a
    /// renormalization (gradients). Neither dominates; both ship.
    ///
    /// NO IR TYPE EXISTS. Verified against this tree: llvm/IR/Type.h's TypeID
    /// enum runs Half, BFloat, Float, Double, X86_FP80, FP128, PPC_FP128 and
    /// stops. There is no Float8*TyID. So:
    ///
    ///   *storage*    `kairo::rt::f8e4m3` / `f8e5m2`, a struct wrapping u8.
    ///   *arithmetic* promote to `f32`, compute, narrow back. See
    ///                builtin_arith_promote().
    ///   *folding*    APFloat HAS the semantics even though IR does not
    ///                (`semFloat8E4M3FN`, `semFloat8E5M2`). The constant
    ///                evaluator uses them directly, so eval-time arithmetic
    ///                needs no bit-twiddling of ours.
    ///
    /// The runtime header and APFloat MUST agree on all 256 bit patterns in
    /// both directions. They are two implementations of one format, and a
    /// disagreement is a miscompile that appears only when a value crosses
    /// between compile time and run time. Test it exhaustively; 512 cases.
    //
    /// NOT INCLUDED, deliberately:
    ///   *Float8E4M3*    the true-IEEE `E4M3` with infinities, max finite 240.
    ///                   Nothing ships it. `F8E4M3` below binds to the FN form.
    ///   *FNUZ variants* AMD `MI300` (bias 8 / 16) and `Graphcore` (bias 11).
    ///                   Each is one vendor's ABI. A Kairo program spelling
    ///                   `f8e4m3` must denote the same format on every target
    ///                   it compiles for; these belong behind FFI, not here.
    ///   *Float8E8M0FNU* 8 exponent bits, no sign, no mantissa. A scale factor
    ///                   for `MXFP4/MXFP8` blocks, not a value type: it has no
    ///                   arithmetic and CANNOT REPRESENT ZERO, which would
    ///                   break zero-initialization outright. APFloat
    ///                   special-cases it out of `hasZero()` for the same
    ///                   reason.

    /// `f8e4m3`. OCP E4M3 in its FINITE-ONLY form: 1 sign / 4 exponent /
    /// 3 mantissa, bias 7, max finite 448, no infinities, NaN is the
    /// all-ones significand alone. Binds to APFloat's `semFloat8E4M3FN`
    /// NOT `semFloat8E4M3`, which is the IEEE variant with infinities and a
    /// max finite of 240. The names differ by two characters and the
    /// results differ from every ML toolchain in existence.
    F8E4M3,

    /// `f8e5m2`. OCP E5M2: 1/5/2, bias 15, IEEE-shaped, infinities and
    /// NaN both present. Exponent field is identical to F16's.
    /// APFloat: semFloat8E5M2.
    F8E5M2,

    /// # 16-bit floats
    //
    /// Two DIFFERENT formats at one width. Both are native IR types in this
    /// tree (`HalfTyID`, `BFloatTyID`); neither converts to the other without
    /// rounding; neither is the other's canonical.

    /// `f16`. IEEE 754 binary16: 1/5/10, bias 15. A FULL ARITHMETIC TYPE,
    /// not storage-only, `T + T` must mean addition for every T a generic
    /// accepts, and a storage-only float poisons that. Emit LLVM `half` and
    /// let legalization promote to f32 on targets without native ALU
    /// support (pre-Sapphire-Rapids x86, pre-ARMv8.2). Same policy already
    /// accepted for F128's libcalls: correctness at the type level, cost
    /// disclosed in the docs. C++: `_Float16`.
    F16,

    /// `bf16`. bfloat16: 1/8/7, bias 127, f32's exponent range with the
    /// mantissa truncated, so f32->bf16 is a truncation and bf16->f32 is
    /// exact. Native hardware on AVX512-BF16 and ARM BF16; native IR type
    /// (BFloatTyID). The one new float here that costs nothing.
    /// C++: __bf16. APFloat: semBFloat.
    ///
    /// Breaks the f<width> naming scheme on purpose. `bf16` is what every
    /// ML toolchain, every paper and every hardware manual calls it;
    /// a scheme-pure invention would be unrecognizable for no gain.
    BF16,

    /// # 32/64-bit floats

    /// `f32`. IEEE binary32. C++: float. APFloat: semIEEEsingle.
    F32,

    /// `f64`. IEEE binary64. The DEFAULT for float literals.
    /// C++: double. APFloat: semIEEEdouble.
    F64,

    /// `f80`. x87 80-bit extended: 1/15/64 with an EXPLICIT integer bit,
    /// which no IEEE interchange format has, it is not "binary80" and
    /// calling it that will eventually mislead someone writing codegen.
    ///
    /// X86 ONLY. There is no x86_fp80 on ARM, RISC-V or anything else, and
    /// on those targets C's `long double` is just double. TypeResolution
    /// emits a HARD ERROR naming the target triple when this is spelled for
    /// a non-x86 target, rather than silently widening to F128 or narrowing
    /// to F64, a quiet precision change is worse than a failed build.
    ///
    /// Retained despite being the one non-portable entry because the
    /// compiler's own Immediate::FloatData stores literal values in it.
    /// C++: long double (x86 only). APFloat: semX87DoubleExtended.
    F80,

    /// `f128`. IEEE binary128 (quadruple): 1/15/112. LLVM has the type
    /// (FP128TyID) but NO mainstream CPU has the instructions, so every
    /// operation lowers to a compiler-rt `LIBCALL`, `__addtf3`, `__multf3`,
    /// `__divtf3`. Roughly 10-50x f64 depending on the operation. Correct
    /// everywhere, fast nowhere.
    ///
    /// Do not confuse with `PPC_FP128TyID`, LLVM's OTHER 128-bit float: a
    /// double-double pair, structurally what F256 is below at half the limb
    /// count. Kairo's `f128` is always `FP128TyID`; a PowerPC `long double`
    /// arriving through FFI is a different type and the FFI mapping table
    /// must say so.
    /// C++: `__float128`. `APFloat: semIEEEquad`.
    F128,

    /// # Extended-width floats
    //
    /// LLVM HAS NO TYPE AT THESE WIDTHS. Unlike the integers above, there is
    /// nothing to legalize and nothing to call: these are the only entries in
    /// this enum that need Kairo implementation code. corelib soft-float,
    /// four and eight f64 limbs, Dekker arithmetic for add/mul and
    /// Newton-Raphson for div and sqrt. Not IEEE anything, the limb
    /// representation has no single exponent field, so builtin_float_format
    /// reports SoftDouble4 / SoftDouble8 rather than a binaryN.

    /// `f256`. Four `f64` limbs. C++: `kairo::rt::f256`.
    F256,

    /// `f512`. Eight `f64` limbs. C++: `kairo::rt::f512`.
    F512,

    /// # Non-numeric scalars

    /// `byte`. A raw octet. Same width as U8 and NOT THE SAME TYPE: bitwise
    /// operators only, arithmetic is a diagnostic. This is the distinction
    /// C++ never made, char, unsigned char and uint8_t are one type there,
    /// so "storage" and "small number" are indistinguishable to the type
    /// system. Here they are not. C++: `std::byte`.
    Byte,

    /// `char`. A decoded Unicode scalar value, 4 bytes. Same width as U32
    /// and NOT THE SAME TYPE. Strings are UTF-8 backed by u8; `char` appears
    /// when a single codepoint is wanted, s[i] yields one, `for ch in s`
    /// yields them. A [char; N] is 4x the UTF-8 size, bought for O(1)
    /// codepoint indexing. C++: `char32_t`.
    Char,

    COUNT,   ///< keep last.
}

inline "c++" { // PORT(trivial) stage0 does not have a way to reprenst a constexpr variable.
    constexpr u8 TOTAL_BUILTINS_COUNT = static_cast<u8>(BuiltinKind::COUNT);
}

/// \enum FloatImpl
/// \brief How a float type's operations are implemented. ORTHOGONAL to bit
///        layout: f16 is IEEE-shaped and Native, f128 is IEEE-shaped and
///        Libcall. Callers that want to know "will this be fast" ask this;
///        callers that want to know "what does a bit pattern mean" ask
///        FloatLayout's fields.
enum FloatImpl derives u8 {
    None,       ///< not a float.
    Native,     ///< an LLVM IR type exists; emit it and stop.
    Libcall,    ///< IR type exists, every op lowers to compiler-rt. f128 only.
    Corelib,    ///< no IR type at all; kairo::rt struct, arithmetic in f32/f64.
}

/// \enum FloatSem
/// \brief APFloat semantics selector.
///
/// \detail
///   The one part of a float's identity that MUST be a tag. It names an
///   external object and cannot be reconstructed from field widths:
///   semFloat8E4M3FN and semFloat8E4M3 have identical exponent and mantissa
///   widths and differ only on whether infinities exist. Anything derivable
///   from the layout lives in FloatLayout's numeric fields instead, so that
///   adding a format does not mean adding a switch arm somewhere.
///
///   SoftDouble4/8 are not APFloat semantics. They are limb representations
///   with no single exponent field; the constant evaluator has no APFloat to
///   hand for them and must route through corelib.
enum FloatSem derives u8 {
    None = 0,

    Float8E4M3FN,        ///< semFloat8E4M3FN. NOT semFloat8E4M3.
    Float8E5M2,          ///< semFloat8E5M2.
    IEEEHalf,            ///< semIEEEhalf.
    BFloat,              ///< semBFloat.
    IEEESingle,          ///< semIEEEsingle.
    IEEEDouble,          ///< semIEEEdouble.
    X87DoubleExtended,   ///< semX87DoubleExtended.
    IEEEQuad,            ///< semIEEEquad.

    SoftDouble4,         ///< four f64 limbs. No APFloat equivalent.
    SoftDouble8,         ///< eight f64 limbs. No APFloat equivalent.
}

/// \struct FloatLayout
/// \brief The shape of a float, in fields rather than in a name.
///
/// \detail
///   Exists so that conversion rank, exactness and diagnostics are COMPUTED
///   rather than table-matched pair by pair. See float_widens_exactly().
///
///   exp/mant/bias are 0 for the SoftDouble limb formats, which have no single
///   exponent field. `exp == 0` on a row whose sem is not None means "ask
///   corelib"; every consumer must treat it as unknown rather than as zero.
struct FloatLayout {
    var sem:   FloatSem;
    var fimpl: FloatImpl;

    var exp:  u8;  ///< exponent bits; 0 for limb formats and non-floats.
    var mant: u8;  ///< STORED mantissa bits, excluding any implicit bit.
    var bias: i16; ///< i16, not u8: FNUZ biases arriving through FFI do not fit.

    var has_inf:          bool; ///< false for E4M3FN, whose all-ones exponent is NaN.
    var explicit_int_bit: bool; ///< x87 only. Not an IEEE interchange format.
}

eval fn float_layout_none() -> FloatLayout {
    return FloatLayout(FloatSem::None, FloatImpl::None, 0, 0, 0, false, false);
}

/// \brief True when every value of \p from is exactly representable in \p to.
///
/// \detail
///   Width is NOT the answer and the 16-bit pair is the proof: bf16 -> f16
///   loses range, f16 -> bf16 loses precision, both are 16 bits, neither is
///   exact. Comparing the two fields separately gets all of these right with
///   no pair table:
///
///     `bf16` -> `f32`    `true`    (8/23 covers 8/7)
///     `bf16` -> `f16`    `false`   (5 exponent bits cannot hold 8)
///     `f16`  -> `bf16`   `false`   (7 mantissa bits cannot hold 10)
///     `f16`  -> `f32`    `true`
///
///   Limb formats return false rather than comparing against a zeroed field.
///   Conservative refusal is the correct failure mode here; anything that
///   needs a real answer for f256/f512 goes through corelib anyway.
fn float_widens_exactly(from: *FloatLayout, to: *FloatLayout) -> bool {
    if (from->sem == FloatSem::None) || (to->sem == FloatSem::None) { return false; }
    if (from->exp == 0) || (to->exp == 0) { return false; }
    if (from->has_inf && (!to->has_inf))  { return false; }
    return (to->exp >= from->exp) && (to->mant >= from->mant);
}

/// Category bits for BuiltinInfo::flags. The predicates below read these
/// instead of comparing enum values, which is what makes BuiltinKind's
/// ordering genuinely arbitrary the way its doc comment claims.
eval fn BF_INTEGER()      -> u8 { return 1;  }
eval fn BF_SIGNED()       -> u8 { return 2;  }
eval fn BF_FLOAT()        -> u8 { return 4;  }
eval fn BF_TARGET_WIDTH() -> u8 { return 8;  }  ///< bits == 0; store fills from the triple.
eval fn BF_X86_ONLY()     -> u8 { return 16; }  ///< TypeResolution hard-errors on other targets.

/// \struct BuiltinInfo
/// \brief One row per BuiltinKind.
///
/// \detail
///   `kind` is redundant with the row index and is present ONLY so
///   verify_builtin_table() can catch a misordered insert. That check is the
///   entire justification for this being a table instead of a switch: a
///   switch cannot be wrong about which arm it is in, a table can, so the
///   table has to prove itself at eval time or it is strictly worse.
///
///   Per-entry semantics stay on BuiltinKind's doc comments. A row holds data;
///   it does not hold the reasoning, and nothing here should be read as
///   replacing it.
class BuiltinInfo {
    pub var kind:     BuiltinKind;
    pub var tk:       TokenKind;    ///< TokenKind::COUNT for the rows with no type-position token.
    pub var spelling: string;       ///< source spelling, for diagnostics and dumps.
    pub var cxx:      string;       ///< C++ emission. "" is a codegen bug, never valid.
    pub var bits:     usize;        ///< 0 for Void/Never and for the target-width pair.
    pub var flags:    u8;
    pub var fp:       FloatLayout;

    fn BuiltinInfo(self, kind: BuiltinKind, tk: TokenKind, spelling: string, cxx: string, bits: usize, flags: u8, fp: FloatLayout) {
        self.kind     = kind;
        self.tk       = tk;
        self.spelling = spelling;
        self.cxx      = cxx;
        self.bits     = bits;
        self.flags    = flags;
        self.fp       = fp;
    }

    fn is_integer(self)  -> bool { return (self.flags & BF_INTEGER())  != 0; }
    fn is_signed(self)   -> bool { return (self.flags & BF_SIGNED())   != 0; }
    fn is_float(self)    -> bool { return (self.flags & BF_FLOAT())    != 0; }
    fn is_x86_only(self) -> bool { return (self.flags & BF_X86_ONLY()) != 0; }
}

// if i had stage1: PORT(non-trivial)
// extend BuiltinInfo {
//     fn is_integer(self)  -> bool { return (self.flags & BF_INTEGER())  != 0; }
//     fn is_signed(self)   -> bool { return (self.flags & BF_SIGNED())   != 0; }
//     fn is_float(self)    -> bool { return (self.flags & BF_FLOAT())    != 0; }
//     fn is_x86_only(self) -> bool { return (self.flags & BF_X86_ONLY()) != 0; }
// }

/// \var BuiltinTable
/// \brief Static description of every builtin, indexed by BuiltinKind. One row
///        per enumerator, TOTAL_BUILTINS_COUNT rows, order matches the enum.
///
/// \detail
///   The table is the single source of truth for the four facts a builtin
///   carries: the keyword token it lexes as, the Kairo spelling, the C++ type
///   EmitPlan writes, and the width/flags/float layout TypeResolution checks.
///   Adding a builtin is one row here plus one enumerator; nothing else keys
///   off the ordering.
///
/// \par Rows that do not mean what the columns suggest
///      `Never` lists `"void"` as its C++ type and `TokenKind::OpExclaim` as its
///      token. A noreturn function still has a C++ return type; divergence rides
///      on `[[noreturn]]`, which EmitPlan attaches from is_noreturn. `!` is not
///      spellable in type position, so nothing resolves through that token.
///
///      `USize`/`ISize` carry bits == 0 with BF_TARGET_WIDTH. Zero means "ask the
///      store", which fills the real width from the target triple. Never read
///      the literal 0 as a width.
///
///      `F256`/`F512` carry exp/mant/bias == 0. A limb representation has no
///      single exponent field; those columns are not meaningful for them.
///
///      `F80` is BF_X86_ONLY. On a non-x86 target `long double` is `double`, so
///      TypeResolution rejects f80 there rather than letting the row silently
///      mean something else.
///
/// \par Float layout carries the identity, not the width
///      F8E4M3 differs from semFloat8E4M3 only in has_inf == false, and that
///      field is what float_widens_exactly() reads to refuse f16 -> f8e4m3.
///      Width alone conflates F16 with BF16 and the two f8 formats; read
///      FloatLayout.
///
/// \par Codegen strategy per row
///     *native*     `_Float16`, `__bf16`, `float`, `double`, `long double`.
///     *legalized*  `_BitInt(N)`: C23, adopted by Clang for C++ as an
///                  extension; lowered to LLVM iN, legalization emits the
///                  carry chains.
///     *libcall*    `__float128`: LLVM has the type, calls compiler-rt.
///     *corelib*    `::kairo::rt::*`: no LLVM type, arithmetic in f32/f64.
///
/// \par Non-numeric scalars
///      `Byte` maps to `::std::byte`, a scoped enum in C++: bitwise ops only,
///      arithmetic ill-formed, so the C++ side enforces Byte's rule for free.
///      `Char` maps to `char32_t`, distinct from U32 despite equal width.
inline "c++" { // PORT(trivial): reason for this inline c++, stage0 does not have any way to reprenst an initlizer list, and here we reuire it.
    static BuiltinInfo BuiltinTable[TOTAL_BUILTINS_COUNT] = {
        BuiltinInfo(BuiltinKind::Void,   TokenKind::AtVoid,    "void",    "void",                  0,   0,                        float_layout_none()),
        BuiltinInfo(BuiltinKind::Never,  TokenKind::OpExclaim, "!",       "void",                  0,   0,                        float_layout_none()),
        BuiltinInfo(BuiltinKind::Bool,   TokenKind::AtBool,    "bool",    "bool",                  8,   0,                        float_layout_none()),
        BuiltinInfo(BuiltinKind::I8,     TokenKind::AtI8,      "i8",      "signed char",           8,   BF_INTEGER()|BF_SIGNED(), float_layout_none()),
        BuiltinInfo(BuiltinKind::I16,    TokenKind::AtI16,     "i16",     "signed short",          16,  BF_INTEGER()|BF_SIGNED(), float_layout_none()),
        BuiltinInfo(BuiltinKind::I32,    TokenKind::AtI32,     "i32",     "signed int",            32,  BF_INTEGER()|BF_SIGNED(), float_layout_none()),
        BuiltinInfo(BuiltinKind::I64,    TokenKind::AtI64,     "i64",     "signed long",           64,  BF_INTEGER()|BF_SIGNED(), float_layout_none()),
        BuiltinInfo(BuiltinKind::I128,   TokenKind::AtI128,    "i128",    "__int128",              128, BF_INTEGER()|BF_SIGNED(), float_layout_none()),
        BuiltinInfo(BuiltinKind::I256,   TokenKind::AtI256,    "i256",    "_BitInt(256)",          256, BF_INTEGER()|BF_SIGNED(), float_layout_none()),
        BuiltinInfo(BuiltinKind::I512,   TokenKind::AtI512,    "i512",    "_BitInt(512)",          512, BF_INTEGER()|BF_SIGNED(), float_layout_none()),
        BuiltinInfo(BuiltinKind::U8,     TokenKind::AtU8,      "u8",      "unsigned char",         8,   BF_INTEGER(),             float_layout_none()),
        BuiltinInfo(BuiltinKind::U16,    TokenKind::AtU16,     "u16",     "unsigned short",        16,  BF_INTEGER(),             float_layout_none()),
        BuiltinInfo(BuiltinKind::U32,    TokenKind::AtU32,     "u32",     "unsigned int",          32,  BF_INTEGER(),             float_layout_none()),
        BuiltinInfo(BuiltinKind::U64,    TokenKind::AtU64,     "u64",     "unsigned long",         64,  BF_INTEGER(),             float_layout_none()),
        BuiltinInfo(BuiltinKind::U128,   TokenKind::AtU128,    "u128",    "unsigned __int128",     128, BF_INTEGER(),             float_layout_none()),
        BuiltinInfo(BuiltinKind::U256,   TokenKind::AtU256,    "u256",    "unsigned _BitInt(256)", 256, BF_INTEGER(),             float_layout_none()),
        BuiltinInfo(BuiltinKind::U512,   TokenKind::AtU512,    "u512",    "unsigned _BitInt(512)", 512, BF_INTEGER(),             float_layout_none()),
        BuiltinInfo(BuiltinKind::USize,  TokenKind::AtUsize,   "usize",   "decltype(sizeof(0))",                                             0,   BF_INTEGER()|BF_TARGET_WIDTH(),             float_layout_none()),
        BuiltinInfo(BuiltinKind::ISize,  TokenKind::AtIsize,   "isize",   "decltype(static_cast<int*>(nullptr)-static_cast<int*>(nullptr))", 0,   BF_INTEGER()|BF_SIGNED()|BF_TARGET_WIDTH(), float_layout_none()),
        BuiltinInfo(BuiltinKind::F8E4M3, TokenKind::AtF8E4M3,  "f8e4m3",  "::kairo::rt::f8e4m3",   8,   BF_FLOAT(),               FloatLayout(FloatSem::Float8E4M3FN,      FloatImpl::Corelib, 4,  3,   7,     false, false)),
        BuiltinInfo(BuiltinKind::F8E5M2, TokenKind::AtF8E5M2,  "f8e5m2",  "::kairo::rt::f8e5m2",   8,   BF_FLOAT(),               FloatLayout(FloatSem::Float8E5M2,        FloatImpl::Corelib, 5,  2,   15,    true,  false)),
        BuiltinInfo(BuiltinKind::F16,    TokenKind::AtF16,     "f16",     "_Float16",              16,  BF_FLOAT(),               FloatLayout(FloatSem::IEEEHalf,          FloatImpl::Native,  5,  10,  15,    true,  false)),
        BuiltinInfo(BuiltinKind::BF16,   TokenKind::AtBf16,    "bf16",    "__bf16",                16,  BF_FLOAT(),               FloatLayout(FloatSem::BFloat,            FloatImpl::Native,  8,  7,   127,   true,  false)),
        BuiltinInfo(BuiltinKind::F32,    TokenKind::AtF32,     "f32",     "float",                 32,  BF_FLOAT(),               FloatLayout(FloatSem::IEEESingle,        FloatImpl::Native,  8,  23,  127,   true,  false)),
        BuiltinInfo(BuiltinKind::F64,    TokenKind::AtF64,     "f64",     "double",                64,  BF_FLOAT(),               FloatLayout(FloatSem::IEEEDouble,        FloatImpl::Native,  11, 52,  1023,  true,  false)),
        BuiltinInfo(BuiltinKind::F80,    TokenKind::AtF80,     "f80",     "long double",           80,  BF_FLOAT()|BF_X86_ONLY(), FloatLayout(FloatSem::X87DoubleExtended, FloatImpl::Native,  15, 64,  16383, true,  true)),
        BuiltinInfo(BuiltinKind::F128,   TokenKind::AtF128,    "f128",    "__float128",            128, BF_FLOAT(),               FloatLayout(FloatSem::IEEEQuad,          FloatImpl::Libcall, 15, 112, 16383, true,  false)),
        BuiltinInfo(BuiltinKind::F256,   TokenKind::AtF256,    "f256",    "::kairo::rt::f256",     256, BF_FLOAT(),               FloatLayout(FloatSem::SoftDouble4,       FloatImpl::Corelib, 0,  0,   0,     true,  false)),
        BuiltinInfo(BuiltinKind::F512,   TokenKind::AtF512,    "f512",    "::kairo::rt::f512",     512, BF_FLOAT(),               FloatLayout(FloatSem::SoftDouble8,       FloatImpl::Corelib, 0,  0,   0,     true,  false)),
        BuiltinInfo(BuiltinKind::Byte,   TokenKind::AtByte,    "byte",    "::std::byte",           8,   0,                        float_layout_none()),
        BuiltinInfo(BuiltinKind::Char,   TokenKind::AtChar,    "char",    "char32_t",              32,  0,                        float_layout_none()),
    };
}

/// \brief THE builtin accessor. Every per-builtin fact (spelling, C++
///        emission, width, category, float layout) is a field or predicate
///        on the returned row; there are deliberately no per-field wrappers.
///
/// \detail `bits` answers "how wide", never "which type": three widths carry
///         more than one entry (see BuiltinKind's WIDTH IS NOT IDENTITY note),
///         so read `fp` when the question is about a format. `bits == 0` on a
///         BF_TARGET_WIDTH row means "ask the store", never a width.
fn builtin_info(b: BuiltinKind) -> *BuiltinInfo {
    return &BuiltinTable[static_cast::<u8>(b)];
}

/// \brief Map a type-position token kind to its builtin, or COUNT when the
///        token does not name one.
///
/// \details This is the WHOLE of builtin "lookup". `i32` is not a name: it
///          never enters a SymbolTable, never rides the import overlay, and is
///          never shadowable. TypeResolution asks this question of a
///          ChainType's first segment before it asks the symbol tables
///          anything, which is also why `var i32 = 3` cannot break `var x: i32`.
///
///          Deliberately NOT a scan of BuiltinTable. This runs on every
///          type-position token in every parse; a switch is a jump table and a
///          scan is 30 comparisons. verify_builtin_table() round-trips every
///          row through it, so the two cannot drift apart.
fn builtin_for_token(k: TokenKind) -> BuiltinKind {
    switch k {
        case TokenKind::AtVoid    { return BuiltinKind::Void;   }
        case TokenKind::OpExclaim { return BuiltinKind::Never;  }
        case TokenKind::AtBool    { return BuiltinKind::Bool;   }
        case TokenKind::AtByte    { return BuiltinKind::Byte;   }
        case TokenKind::AtChar    { return BuiltinKind::Char;   }

        case TokenKind::AtI8      { return BuiltinKind::I8;     }
        case TokenKind::AtI16     { return BuiltinKind::I16;    }
        case TokenKind::AtI32     { return BuiltinKind::I32;    }
        case TokenKind::AtI64     { return BuiltinKind::I64;    }
        case TokenKind::AtI128    { return BuiltinKind::I128;   }
        case TokenKind::AtI256    { return BuiltinKind::I256;   }
        case TokenKind::AtI512    { return BuiltinKind::I512;   }

        case TokenKind::AtU8      { return BuiltinKind::U8;     }
        case TokenKind::AtU16     { return BuiltinKind::U16;    }
        case TokenKind::AtU32     { return BuiltinKind::U32;    }
        case TokenKind::AtU64     { return BuiltinKind::U64;    }
        case TokenKind::AtU128    { return BuiltinKind::U128;   }
        case TokenKind::AtU256    { return BuiltinKind::U256;   }
        case TokenKind::AtU512    { return BuiltinKind::U512;   }

        case TokenKind::AtUsize   { return BuiltinKind::USize;  }
        case TokenKind::AtIsize   { return BuiltinKind::ISize;  }

        case TokenKind::AtBf16    { return BuiltinKind::BF16;   }
        case TokenKind::AtF16     { return BuiltinKind::F16;    }
        case TokenKind::AtF32     { return BuiltinKind::F32;    }
        case TokenKind::AtF64     { return BuiltinKind::F64;    }
        case TokenKind::AtF80     { return BuiltinKind::F80;    }
        case TokenKind::AtF128    { return BuiltinKind::F128;   }
        case TokenKind::AtF256    { return BuiltinKind::F256;   }
        case TokenKind::AtF512    { return BuiltinKind::F512;   }
        case TokenKind::AtF8E4M3  { return BuiltinKind::F8E4M3; }
        case TokenKind::AtF8E5M2  { return BuiltinKind::F8E5M2; }

        default                   { return BuiltinKind::COUNT; }
    }
}

/// \brief Every row lands at the index its `kind` names, carries a spelling
///        and a C++ emission, round-trips through builtin_for_token(), and
///        no two float rows claim the same APFloat semantics.
///
/// \detail
///   A table is only safer than a switch if a wrong insert fails the build.
///   This is that check, and the distinct-sem clause is the one that matters
///   most: two rows sharing FloatSem::IEEEHalf is the f16/bf16 conflation the
///   enum spends three paragraphs warning about, and it should break the
///   build rather than a test.
eval fn verify_builtin_table() -> bool {
    var seen_sem: array::<bool, 16>;
    for (var s = 0; s < 16; ++s) { seen_sem[s] = false; }

    for (var i = 0; i < static_cast::<u8>(BuiltinKind::COUNT); ++i) {
        var row = &BuiltinTable[i];

        if (static_cast::<u8>(row->kind) != i) { return false; }
        if (row->spelling == "")               { return false; }
        if (row->cxx == "")                    { return false; }

        var is_float  = (row->flags & BF_FLOAT())   != 0;
        var is_int    = (row->flags & BF_INTEGER()) != 0;
        var is_target = (row->flags & BF_TARGET_WIDTH()) != 0;

        if (is_float && is_int) { return false; }

        if (is_float) {
            if (row->fp.sem == FloatSem::None)   { return false; }
            if (row->fp.fimpl == FloatImpl::None) { return false; }

            var s = static_cast::<u8>(row->fp.sem);
            if (seen_sem[s]) { return false; }   // two rows, one APFloat semantics.
            seen_sem[s] = true;
        } else {
            if (row->fp.sem != FloatSem::None)   { return false; }
            if (row->fp.fimpl != FloatImpl::None) { return false; }
        }

        // bits == 0 must mean "ask the store", and only for the rows that say so.
        if (is_target && (row->bits != 0)) { return false; }
        if ((!is_target) && (row->bits == 0)
            && (row->kind != BuiltinKind::Void)
            && (row->kind != BuiltinKind::Never)) { return false; }

        // Every row round-trips through the switch above. No sentinel rows.
        if (builtin_for_token(row->tk) != row->kind) { return false; }
    }
    return true;
}

// PORT(trivial): the table is static not evaluated, so the static_assert is a no-op in stage0.
// static_assert(verify_builtin_table(), r"BuiltinTable row is out of order, incomplete, or duplicates a FloatSem");

// FIXME: REFACTOR into separate files.

///
///  QualifiedType
///  const T | volatile T | const volatile T
///
///  `inner` is canonical and never itself a QualifiedType (the store folds);
///  `quals` is never 0 (the store returns `inner` for that). Layout is the
///  inner's.
///
class QualifiedType derives Type {
    pub var inner: *Type = &null;
    pub var quals: u8    = 0;      ///< QUAL_CONST | QUAL_VOLATILE; the key.

    /* OVERRIDE */ static fn classof(ptr: *Type) -> bool {
        return ptr->kind == TypeKind::QualifiedType;
    }

    /* OVERRIDE */ static fn type_kind() -> TypeKind {
        return TypeKind::QualifiedType;
    }
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

    fn info(self) -> *BuiltinInfo { return builtin_info(self.builtin); }
    fn spelling(self) -> string { return self.info()->spelling;  }
    fn cxx_emission(self) -> string { return self.info()->cxx;  }
    fn is_integer(self) -> bool { return self.info()->is_integer(); }
    fn is_signed(self)  -> bool { return self.info()->is_signed();  }
    fn is_float(self)   -> bool { return self.info()->is_float();   }
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

/// QualifiedType::quals bits. A bitset, not a bool: `volatile` is in real
/// headers (std::atomic members, MMIO wrappers) and retrofitting it would
/// be this whole sweep a second time.
eval fn QUAL_CONST()    -> u8 { return 1; }
eval fn QUAL_VOLATILE() -> u8 { return 2; }

/// The top-level qualifiers of a canonical; 0 for any other kind.
fn canon_quals(t: *Type) -> u8 {
    if (t == &null) || (!isa::<QualifiedType>(t)) { return 0; }
    return cast::<QualifiedType>(t)->quals;
}

/// \p t with its top-level qualifiers removed; \p t itself for any other
/// kind. ONE level: `*const i32` stays `*const i32`.
fn canon_unqual(t: *Type) -> *Type {
    if (t == &null) || (!isa::<QualifiedType>(t)) { return t; }
    return cast::<QualifiedType>(t)->inner;
}

fn canon_has_const(t: *Type)    -> bool { return (canon_quals(t) & QUAL_CONST())    != 0; }
fn canon_has_volatile(t: *Type) -> bool { return (canon_quals(t) & QUAL_VOLATILE()) != 0; }