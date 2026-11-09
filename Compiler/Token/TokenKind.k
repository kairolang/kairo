/// --- The Kairo Project ---------------------------- Token/TokenKind.k --- ///
///
///   TokenKind, the enum of every token kind, and its classifiers.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

// DO NOT FORGET OPS CAN START WITH A PREFIX OF l or r


///
/// Key: (At) - Annotation, (Kw) - Keyword, (Op) - Operator,
///      (Bi) - Builtin, (Lit) - Literal
// TODO(ENUM-OPEN): hash-probe -- values are spelling hashes; is_valid_token_kind and the lexer cast an arbitrary hash before knowing it is a kind
@open
pub enum TokenKind derives u32 {
    /// # Special tokens                  (Reserved values = 0x00 - 0x23)
    TkUnknown      = 0x001, // (unrecognized)
    TkEof          = 0x002, // (end of file)
    TkError        = 0x003, // (lexing error)
    AtComment      = 0x004, // (comment)
    TkNewLine      = 0x005, // (newline)
    TkWhitespace   = 0x006, // (whitespace)                      RESERVED/UNUSED
    TkFileStart    = 0x007, // (start of file)
    TkFileEnd      = 0x008, // (end of file)
    TkGenerated    = 0x009, // (generated code marker)
    TkMacroExpand  = 0x00a, // (macro expansion marker)
    TkCodeComplete = 0x00b, // (code completion marker)

    /// # Special tokens Continued        (Reserved values = 0x24 - 0xFE)
    LitIdentifier = 0x024, // <identifier>
    LitInt        = 0x026, // e.g. "123", "0xFFF", "0b1010", "0o1298"
    LitFloat      = 0x027, // e.g. "10.290", "0x1.2p-3",
    //       ".5",    "3.14e-2" , "1e3"

    LitString = 0x028, // e.g.  "hello"
    LitChar   = 0x02b, // e.g.  'a'

    LitNull = 609591432, /* "null" */
    /// # Punctuators
    ///               "#" is valid within identifiers, so we treat it as such
    ///               "$" is an illegal token in kairo
    ///
    /// Each value is what compute_hash::<r"X">() returns for its spelling,
    ///    written as a literal: a call in an enum discriminant is not
    ///    evaluated at compile time yet (SC128E).
    ///
    /// TODO: use compute_hash instead of the raw values once compile-time evaluation of calls lands.
    ///
    OpLBrace      = (0xd60d1a11), // "{"
    OpRBrace      = (0xd60d6ae3), // "}"
    OpLParen = 3591201518,        /* "(" */
    // "("
    OpRParen = 3591204263, /* ")" */
    // ")"
    OpLSquare = 3591179377, /* "[" */
    // "["
    OpRSquare = 3591180355, /* "]" */
    // "]"
    OpBackslash = 3591179930, /* "\\" */
    // "\"
    OpLess = 3591191802, /* "<" */
    // "<"
    OpGreater = 3591191388, /* ">" */
    // ">"
    OpPlus = 3591201281, /* "+" */
    // "+"
    OpMinus = 3591181011, /* "-" */
    // "-"
    OpStar = 3591204176, /* "*" */
    // "*"
    OpSlash = 3591204669, /* "/" */
    // "/"
    OpPercent = 3591202667, /* "%" */
    // "%"
    OpCaret = 3591180796, /* "^" */
    // "^"
    OpPipe = 3591203130, /* "|" */
    // "|"
    OpAmp = 3591207460, /* "&" */
    // "&"
    OpCaretCaret = 2670488573, /* "^^" */
    // "^^"    (exponentiation)

    OpRange = 2647421437, /* ".." */
    // ".."    NOT (clang-compatible)
    OpRangeEqual = 3147726379, /* "..=" */
    // "..="   NOT (clang-compatible)

    OpTilde = 3591202716, /* "~" */
    // "~"
    OpQuestion = 3591190541, /* "?" */
    // "?"     NOT (clang-compatible)
    OpQuestionQuestion = 2621330219, /* "??" */
    // "??"    NOT (clang-compatible)
    OpExclaim = 3591201343, /* "!" */
    // "!"     NOT (clang-compatible)
    OpAt = 3591179046, /* "@" */
    // "@"     NOT (clang-compatible)

    OpEqual = 3591190435, /* "=" */
    // "="
    OpPlusPlus = 2645550931, /* "++" */
    // "++"
    OpMinusMinus = 2646982463, /* "--" */
    // "--"

    OpSemicolon = 3591190481, /* ";" */
    // ";"
    OpColon = 3591186464, /* ":" */
    // ":"

    OpArrow = 2646976548, /* "->" */
    // "->"
    OpArrowStar = 3074574747, /* "->*" */
    // "->*"
    OpFatArrow = 2620961076, /* "=>" */
    // "=>"    NOT (clang-comp)
    OpQuestionArrow = 1614154380, /* "?->" */
    // "?->"   NOT (clang-comp)
    OpQuestionArrowStar = 1409249956, /* "?->*" */
    // "?->*   NOT (clang-comp)
    OpComma = 3591180586, /* "," */
    // ","
    OpDot = 3591204748, /* "." */
    // "."
    OpDotStar = 2647420121, /* ".*" */
    // ".*"
    OpColonColon = 2621323397, /* "::" */
    // "::"
    OpQuestionDot = 2621277622, /* "?." */
    // "?."      NOT (clang-comp)
    OpQuestionDotStar = 1614779901, /* "?.*" */
    // "?.*"     NOT (clang-comp)

    OpEllipsis = 3147725628, /* "..." */
    // "..."

    /// # Assignment operators (Clang-compatible)
    OpPlusEqual = 2645540193, /* "+=" */
    // "+="
    OpMinusEqual = 2646993103, /* "-=" */
    // "-="
    OpStarEqual = 2644928314, /* "*=" */
    // "*="
    OpSlashEqual = 2645680349, /* "/=" */
    // "/="
    OpPercentEqual = 2646069383, /* "%=" */
    // "%="
    OpAmpEqual = 2643215326, /* "&=" */
    // "&="
    OpPipeEqual = 2556061704, /* "|=" */
    // "|="
    OpCaretEqual = 2670576726, /* "^=" */
    // "^="
    OpLessLessEqual = 2002054931, /* "<<=" */
    // "<<="
    OpGreaterGreaterEqual = 1861878763, /* ">>=" */
    // ">>="
    OpAtEqual = 2679702452, /* "@=" */
    // "@="   NOT (clang-comp)

    /// # Logical / comparison operators (Clang-compatible)
    OpLessEqualGreater = 2002417059, /* "<=>" */
    // "<=>" (spaceship operator)
    OpEqualEqualEqual = 1406598937, /* "===" */
    // "==="     NOT (clang-comp)
    OpEqualEqual = 2620949471, /* "==" */
    // "=="
    OpExclaimEqual = 2643083099, /* "!=" */
    // "!="
    OpLessLess = 2620989589, /* "<<" */
    // "<<"
    OpGreaterGreater = 2619618109, /* ">>" */
    // ">>"
    OpLessEqual = 2620991048, /* "<=" */
    // "<="
    OpGreaterEqual = 2619617910, /* ">=" */
    // ">="
    OpAmpAmp = 2643305437, /* "&&" */
    // "&&"
    OpPipePipe = 2556085781, /* "||" */
    // "||"

    /// # Keywords (Clang subset + Kairo)

    /// Control flow
    KwReturn = 1548198552, /* "return" */
    // "return"
    KwBreak = 4134047474, /* "break" */
    // "break"
    KwContinue = 372535702, /* "continue" */
    // "continue"
    KwPanic = 833965225, /* "panic" */
    // "panic"

    KwMatch = 3827136968, /* "match" */
    // "match"
    KwCase = 2525549991, /* "case" */
    // "case"
    KwDefault = 2812546841, /* "default" */
    // "default"

    KwCatch = 3307011504, /* "catch" */
    // "catch"
    KwTry = 1121086788, /* "try" */
    // "try"
    KwFinally = 2117440049, /* "finally" */
    // "finally"

    KwIf = 2672809008, /* "if" */
    // "if"
    KwElse = 2651961797, /* "else" */
    // "else"
    KwWhile = 76556390, /* "while" */
    // "while"
    KwFor = 1074397502, /* "for" */
    // "for"
    KwAssert = 3420412433, /* "assert" */
    // "assert"
    KwLoop = 2357363419, /* "loop" */
    // "loop"

    /// Declarations
    KwVar = 1253494392, /* "var" */
    // "var"
    KwConst = 3398138169, /* "const" */
    // "const"

    KwFn = 2670215509, /* "fn" */
    // "fn"
    KwOp = 2672621124, /* "op" */
    // "op"
    KwClass = 1948670795, /* "class" */
    // "class"
    KwUnion = 1081647249, /* "union" */
    // "union"
    KwEnum = 3136450037, /* "enum" */
    // "enum"
    KwType = 4217250243, /* "type" */
    // "type"
    KwStruct = 1093619721, /* "struct" */
    // "struct"
    KwInterface = 1438217232, /* "interface" */
    // "interface"
    KwExtend = 4145939201, /* "extend" */
    // "extend"

    KwModule = 861986363, /* "module" */
    // "module"
    KwTest = 144002539, /* "test" */
    // "test"

    KwMacro = 804996775, /* "macro" */
    // "macro"

    KwImport = 3970471453, /* "import" */
    // "import"
    KwOverride = 2908904680, /* "override" */
    // "override"
    KwFinal = 808321564, /* "final" */
    // "final"

    KwFfi = 1078514862, /* "ffi" */
    // "ffi"

    KwImpl = 1036746717, /* "impl" */
    // "impl"
    KwDerives = 2510959235, /* "derives" */
    // "derives"

    KwWhere = 912484924, /* "where" */
    // "where"
    KwRequires = 2945402443, /* "requires" */
    // "requires"

    /// Access control
    KwPub = 2317992058, /* "pub" */
    // "pub"
    KwPriv = 2981236216, /* "priv" */
    // "priv"
    KwProt = 2973200452, /* "prot" */
    // "prot"

    /// Specifiers / qualifiers
    KwEval = 4175334997, /* "eval" */
    // "eval"
    KwUnsafe = 2742166485, /* "unsafe" */
    // "unsafe"
    KwStatic = 3496634016, /* "static" */
    // "static"
    KwAsync = 3995743410, /* "async" */
    // "async"
    KwInline = 773996011, /* "inline" */
    // "inline"
    KwAtomic = 1956107680, /* "atomic" */
    // "atomic"
    KwVolatile = 2268188630, /* "volatile" */
    // "volatile"
    KwVirtual = 510670787, /* "virtual" */
    // "virtual"
    KwMutable = 3995743920, /* "mutable" */
    // "mutable"

    /// Special identifiers
    KwSelf = 1413877529, /* "self" */
    // "self"

    /// Booleans
    KwTrue = 559173848, /* "true" */
    // "true"
    KwFalse = 1009174351, /* "false" */
    // "false"

    /// # Binary operators
    KwIn = 2672807560, /* "in" */
    // "in"
    KwAs = 2668467601, /* "as" */
    // "as"
    KwAnd = 1271532484, /* "and" */
    // "and"
    KwAndEq = 1596910639, /* "and_eq" */
    // "and_eq"
    KwBitand = 2986416536, /* "bitand" */
    // "bitand"
    KwBitor = 810953134, /* "bitor" */
    // "bitor"
    KwCompl = 4133076459, /* "compl" */
    // "compl"
    KwNot = 3684237860, /* "not" */
    // "not"
    KwNotEq = 1099612233, /* "not_eq" */
    // "not_eq"
    KwOr = 2672621530, /* "or" */
    // "or"
    KwOrEq = 3553460670, /* "or_eq" */
    // "or_eq"
    KwXor = 2514153784, /* "xor" */
    // "xor"
    KwXorEq = 1049258362, /* "xor_eq" */
    // "xor_eq"

    /// # Primitive types
    AtVoid = 1369593215, /* "void" */
    // "void"
    AtBool = 528890972, /* "bool" */
    // "bool"
    AtByte = 1792751518, /* "byte" */
    // "byte"
    AtChar = 2961969427, /* "char" */
    // "char"

    AtUsize = 214327132, /* "usize" */
    // "usize"
    AtIsize = 2741535370, /* "isize" */
    // "isize"

    AtF8 = 2670694687, /* "f8" */
    // "f8"
    AtF8E4M3 = 3877620412, /* "f8e4m3" */
    // "f8e4m3"
    AtF8E5M2 = 4214817808, /* "f8e5m2" */
    // "f8e5m2"

    AtBf16 = 4067048641, /* "bf16" */
    // "bf16"
    AtF16 = 1185700612, /* "f16" */
    // "f16"
    AtF32 = 1185877498, /* "f32" */
    // "f32"
    AtF64 = 1178650939, /* "f64" */
    // "f64"
    AtF80 = 1178638685, /* "f80" */
    // "f80"
    AtF128 = 2777715991, /* "f128" */
    // "f128"
    AtF256 = 2841931243, /* "f256" */
    // "f256"
    AtF512 = 4133930508, /* "f512" */
    // "f512"

    AtU8 = 2678010582, /* "u8" */
    // "u8"
    AtU16 = 1176713787, /* "u16" */
    // "u16"
    AtU32 = 1177472785, /* "u32" */
    // "u32"
    AtU64 = 1177765928, /* "u64" */
    // "u64"
    AtU128 = 64698799, /* "u128" */
    // "u128"
    AtU256 = 989650331, /* "u256" */
    // "u256"
    AtU512 = 416552108, /* "u512" */
    // "u512"

    AtI8 = 2672755530, /* "i8" */
    // "i8"
    AtI16 = 3066919519, /* "i16" */
    // "i16"
    AtI32 = 3066712909, /* "i32" */
    // "i32"
    AtI64 = 3068777108, /* "i64" */
    // "i64"
    AtI128 = 780640568, /* "i128" */
    // "i128"
    AtI256 = 4153274276, /* "i256" */
    // "i256"
    AtI512 = 4089607859, /* "i512" */
    // "i512"

    /// # Unary keywords
    KwAwait = 140147941, /* "await" */
    // "await"
    KwThread = 1510034758, /* "thread" */
    // "thread" // this is for thread_local storage, not thread spawning
    KwSpawn = 3591600767, /* "spawn" */
    // "spawn"  // lowkey remove this

    KwDelete = 953473439, /* "delete" */
    // "delete"
    KwYield = 2627195468, /* "yield" */
    // "yield"

    KwSizeOf = 901067099, /* "sizeof" */
    // "sizeof"
    KwAlignOf = 1993645206, /* "alignof" */
    // "alignof"
    KwTypeOf = 2351760623, /* "typeof" */
    // "typeof"

    /// # Builtins
    BiFile = 3279741764, /* "__file__" */
    // "__file__"
    BiLine = 2796732843, /* "__line__" */
    // "__line__"
    BiColumn = 994238234, /* "__column__" */
    // "__column__"
    BiFunction = 851798554, /* "__function__" */
    // "__function__"
    BiModule = 2276621029, /* "__module__" */
    // "__module__"
    BiSelf = 147096117, /* "Self" */
    // "Self"
}

/******************************************************************************/
/**         # MAKE SURE TO KEEP THIS IN SYNC WITH THE ENUM ABOVE              */
/******************************************************************************/

pub fn is_valid_token_kind(kind: u32) -> bool {
    match kind as TokenKind {
        case TokenKind::TkUnknown,             TokenKind::TkEof,
             TokenKind::AtComment,             TokenKind::TkNewLine,
             TokenKind::TkFileStart,           TokenKind::TkFileEnd,
             TokenKind::TkMacroExpand,         TokenKind::LitIdentifier,
             TokenKind::LitInt,                TokenKind::LitFloat,
             TokenKind::OpRBrace,              TokenKind::OpLParen,
             TokenKind::OpLSquare,             TokenKind::OpRSquare,
             TokenKind::OpLess,                TokenKind::OpGreater,
             TokenKind::OpMinus,               TokenKind::OpStar,
             TokenKind::OpPercent,             TokenKind::OpCaret,
             TokenKind::OpAmp,                 TokenKind::OpCaretCaret,
             TokenKind::OpRangeEqual,          TokenKind::OpTilde,
             TokenKind::OpExclaim,             TokenKind::OpAt,
             TokenKind::OpPlusPlus,            TokenKind::OpMinusMinus,
             TokenKind::OpArrowStar,           TokenKind::OpQuestionArrow,
             TokenKind::OpFatArrow,            TokenKind::OpSemicolon,
             TokenKind::OpComma,               TokenKind::OpDotStar,
             TokenKind::OpColonColon,          TokenKind::OpQuestionDotStar,
             TokenKind::KwMutable,             TokenKind::OpEllipsis,
             TokenKind::OpPlusEqual,           TokenKind::OpStarEqual,
             TokenKind::OpSlashEqual,          TokenKind::OpAmpEqual,
             TokenKind::OpPipeEqual,           TokenKind::OpLessLessEqual,
             TokenKind::OpGreaterGreaterEqual, TokenKind::OpLessEqualGreater,
             TokenKind::OpEqualEqualEqual,     TokenKind::OpExclaimEqual,
             TokenKind::OpLessLess,            TokenKind::OpLessEqual,
             TokenKind::OpGreaterEqual,        TokenKind::OpPipePipe,
             TokenKind::OpQuestionQuestion,    TokenKind::KwReturn,
             TokenKind::KwBreak,               TokenKind::KwPanic,
             TokenKind::KwMatch,               TokenKind::KwDefault,
             TokenKind::KwCatch,               TokenKind::KwFinally,
             TokenKind::TkError,               TokenKind::KwIf,
             TokenKind::TkWhitespace,          TokenKind::KwElse,
             TokenKind::TkGenerated,           TokenKind::KwWhile,
             TokenKind::LitNull,               TokenKind::KwFor,
             TokenKind::LitString,             TokenKind::KwAssert,
             TokenKind::LitChar,               TokenKind::KwLoop,
             TokenKind::OpLBrace,              TokenKind::KwVar,
             TokenKind::OpRParen,              TokenKind::KwConst,
             TokenKind::OpBackslash,           TokenKind::KwFn,
             TokenKind::OpPlus,                TokenKind::KwOp,
             TokenKind::OpSlash,               TokenKind::KwClass,
             TokenKind::OpPipe,                TokenKind::KwEnum,
             TokenKind::OpRange,               TokenKind::KwType,
             TokenKind::OpQuestion,            TokenKind::KwStruct,
             TokenKind::OpEqual,               TokenKind::KwInterface,
             TokenKind::OpArrow,               TokenKind::KwExtend,
             TokenKind::OpQuestionArrowStar,   TokenKind::KwModule,
             TokenKind::OpColon,               TokenKind::KwTest,
             TokenKind::OpDot,                 TokenKind::KwMacro,
             TokenKind::OpQuestionDot,         TokenKind::KwImport,
             TokenKind::AtU64,                 TokenKind::KwOverride,
             TokenKind::OpMinusEqual,          TokenKind::KwFinal,
             TokenKind::OpPercentEqual,        TokenKind::KwFfi,
             TokenKind::OpCaretEqual,          TokenKind::KwImpl,
             TokenKind::OpAtEqual,             TokenKind::KwDerives,
             TokenKind::OpEqualEqual,          TokenKind::KwWhere,
             TokenKind::OpGreaterGreater,      TokenKind::KwPub,
             TokenKind::OpAmpAmp,              TokenKind::KwPriv,
             TokenKind::KwAtomic,              TokenKind::KwProt,
             TokenKind::KwContinue,            TokenKind::KwEval,
             TokenKind::KwCase,                TokenKind::KwUnsafe,
             TokenKind::KwTry,                 TokenKind::AtU128,
             TokenKind::KwStatic,              TokenKind::AtU256,
             TokenKind::KwAsync,               TokenKind::AtI8,
             TokenKind::KwInline,              TokenKind::AtI16,
             TokenKind::KwSelf,                TokenKind::AtI32,
             TokenKind::KwTrue,                TokenKind::AtI64,
             TokenKind::KwFalse,               TokenKind::AtI128,
             TokenKind::KwIn,                  TokenKind::AtI256,
             TokenKind::KwAs,                  TokenKind::KwAwait,
             TokenKind::KwAnd,                 TokenKind::KwThread,
             TokenKind::KwAndEq,               TokenKind::KwSpawn,
             TokenKind::KwBitand,              TokenKind::KwDelete,
             TokenKind::KwBitor,               TokenKind::KwYield,
             TokenKind::KwCompl,               TokenKind::KwSizeOf,
             TokenKind::KwNot,                 TokenKind::KwAlignOf,
             TokenKind::KwNotEq,               TokenKind::KwTypeOf,
             TokenKind::KwOr,                  TokenKind::BiFile,
             TokenKind::KwOrEq,                TokenKind::BiLine,
             TokenKind::KwXor,                 TokenKind::BiColumn,
             TokenKind::KwXorEq,               TokenKind::BiFunction,
             TokenKind::AtVoid,                TokenKind::BiModule,
             TokenKind::AtBool,                TokenKind::KwVolatile,
             TokenKind::AtUsize,               TokenKind::AtIsize,
             TokenKind::AtByte,                TokenKind::AtF32,
             TokenKind::AtChar,                TokenKind::AtF64,
             TokenKind::AtF8,                  TokenKind::AtF80,
             TokenKind::AtF8E4M3,              TokenKind::AtF128,
             TokenKind::AtF8E5M2,              TokenKind::AtU8,
             TokenKind::AtF512,                TokenKind::AtU16,
             TokenKind::AtF16,                 TokenKind::AtU32,
             TokenKind::AtBf16,                TokenKind::AtU512,
             TokenKind::AtI512,                TokenKind::AtF256,
             TokenKind::BiSelf,                TokenKind::KwRequires,
             TokenKind::KwUnion,               TokenKind::KwVirtual {
            return true
        } default {
            return false
        }
    }
}

/******************************************************************************/
/**         # MAKE SURE TO KEEP THIS IN SYNC WITH THE ENUM ABOVE              */
/******************************************************************************/

pub fn token_kind_to_string(kind: TokenKind) -> string {
    match kind {
        case TokenKind::TkUnknown {
            return "tk-unknown"
        } case TokenKind::TkEof {
            return "tk-eof"
        } case TokenKind::TkError {
            return "tk-error"
        } case TokenKind::AtComment {
            return "tk-comment"
        } case TokenKind::TkNewLine {
            return "tk-new-line"
        } case TokenKind::TkWhitespace {
            return "tk-whitespace"
        } case TokenKind::TkFileStart {
            return "tk-file-start"
        } case TokenKind::TkFileEnd {
            return "tk-file-end"
        } case TokenKind::TkGenerated {
            return "tk-generated"
        } case TokenKind::TkMacroExpand {
            return "tk-macro-expand"
        } case TokenKind::LitIdentifier {
            return "lit-identifier"
        } case TokenKind::LitNull {
            return "lit-null"
        } case TokenKind::LitInt {
            return "lit-int"
        } case TokenKind::LitFloat {
            return "lit-float"
        } case TokenKind::LitString {
            return "lit-string"
        } case TokenKind::LitChar {
            return "lit-char"
        } case TokenKind::OpLBrace {
            return "op-l-brace"
        } case TokenKind::OpRBrace {
            return "op-r-brace"
        } case TokenKind::OpLParen {
            return "op-l-paren"
        } case TokenKind::OpRParen {
            return "op-r-paren"
        } case TokenKind::OpLSquare {
            return "op-l-square"
        } case TokenKind::OpRSquare {
            return "op-r-square"
        } case TokenKind::OpBackslash {
            return "op-backslash"
        } case TokenKind::OpLess {
            return "op-less"
        } case TokenKind::OpGreater {
            return "op-greater"
        } case TokenKind::OpPlus {
            return "op-plus"
        } case TokenKind::OpMinus {
            return "op-minus"
        } case TokenKind::OpStar {
            return "op-star"
        } case TokenKind::OpSlash {
            return "op-slash"
        } case TokenKind::OpPercent {
            return "op-percent"
        } case TokenKind::OpCaret {
            return "op-caret"
        } case TokenKind::OpPipe {
            return "op-pipe"
        } case TokenKind::OpAmp {
            return "op-amp"
        } case TokenKind::OpCaretCaret {
            return "op-caret-caret"
        } case TokenKind::OpRange {
            return "op-range"
        } case TokenKind::OpRangeEqual {
            return "op-range-equal"
        } case TokenKind::OpTilde {
            return "op-tilde"
        } case TokenKind::OpQuestion {
            return "op-question"
        } case TokenKind::OpExclaim {
            return "op-exclaim"
        } case TokenKind::OpAt {
            return "op-at"
        } case TokenKind::OpEqual {
            return "op-equal"
        } case TokenKind::OpPlusPlus {
            return "op-plusplus"
        } case TokenKind::OpMinusMinus {
            return "op-minus-minus"
        } case TokenKind::OpArrow {
            return "op-arrow"
        } case TokenKind::OpArrowStar {
            return "op-arrow-star"
        } case TokenKind::OpFatArrow {
            return "op-fat-arrow"
        } case TokenKind::OpQuestionArrow {
            return "op-question-arrow"
        } case TokenKind::OpQuestionArrowStar {
            return "op-question-arrow-star"
        } case TokenKind::OpColon {
            return "op-colon"
        } case TokenKind::OpSemicolon {
            return "op-semicolon"
        } case TokenKind::OpComma {
            return "op-comma"
        } case TokenKind::OpDot {
            return "op-dot"
        } case TokenKind::OpDotStar {
            return "op-dot-star"
        } case TokenKind::OpColonColon {
            return "op-colon-colon"
        } case TokenKind::OpQuestionDot {
            return "op-question-dot"
        } case TokenKind::OpQuestionDotStar {
            return "op-question-dot-star"
        } case TokenKind::OpEllipsis {
            return "op-ellipsis"
        } case TokenKind::OpPlusEqual {
            return "op-plus-equal"
        } case TokenKind::OpMinusEqual {
            return "op-minus-equal"
        } case TokenKind::OpStarEqual {
            return "op-star-equal"
        } case TokenKind::OpSlashEqual {
            return "op-slash-equal"
        } case TokenKind::OpPercentEqual {
            return "op-percent-equal"
        } case TokenKind::OpAmpEqual {
            return "op-amp-equal"
        } case TokenKind::OpPipeEqual {
            return "op-pipe-equal"
        } case TokenKind::OpCaretEqual {
            return "op-caret-equal"
        } case TokenKind::OpLessLessEqual {
            return "op-less-less-equal"
        } case TokenKind::OpGreaterGreaterEqual {
            return "op-greater-greater-equal"
        } case TokenKind::OpAtEqual {
            return "op-at-equal"
        } case TokenKind::OpLessEqualGreater {
            return "op-less-equal-greater"
        } case TokenKind::OpEqualEqualEqual {
            return "op-equal-equal-equal"
        } case TokenKind::OpEqualEqual {
            return "op-equal-equal"
        } case TokenKind::OpExclaimEqual {
            return "op-exclaim-equal"
        } case TokenKind::OpLessLess {
            return "op-less-less"
        } case TokenKind::OpGreaterGreater {
            return "op-greater-greater"
        } case TokenKind::OpLessEqual {
            return "op-less-equal"
        } case TokenKind::OpGreaterEqual {
            return "op-greater-equal"
        } case TokenKind::OpAmpAmp {
            return "op-amp-amp"
        } case TokenKind::OpPipePipe {
            return "op-pipe-pipe"
        } case TokenKind::OpQuestionQuestion {
            return "op-question-question"
        } case TokenKind::KwReturn {
            return "kw-return"
        } case TokenKind::KwBreak {
            return "kw-break"
        } case TokenKind::KwContinue {
            return "kw-continue"
        } case TokenKind::KwPanic {
            return "kw-panic"
        } case TokenKind::KwMatch {
            return "kw-match"
        } case TokenKind::KwCase {
            return "kw-case"
        } case TokenKind::KwDefault {
            return "kw-default"
        } case TokenKind::KwCatch {
            return "kw-catch"
        } case TokenKind::KwTry {
            return "kw-try"
        } case TokenKind::KwFinally {
            return "kw-finally"
        } case TokenKind::KwIf {
            return "kw-if"
        } case TokenKind::KwElse {
            return "kw-else"
        } case TokenKind::KwWhile {
            return "kw-while"
        } case TokenKind::KwFor {
            return "kw-for"
        } case TokenKind::KwAssert {
            return "kw-assert"
        } case TokenKind::KwLoop {
            return "kw-loop"
        } case TokenKind::KwVar {
            return "kw-var"
        } case TokenKind::KwConst {
            return "kw-const"
        } case TokenKind::KwFn {
            return "kw-fn"
        } case TokenKind::KwOp {
            return "kw-op"
        } case TokenKind::KwClass {
            return "kw-class"
        } case TokenKind::KwEnum {
            return "kw-enum"
        } case TokenKind::KwType {
            return "kw-type"
        } case TokenKind::KwStruct {
            return "kw-struct"
        } case TokenKind::KwInterface {
            return "kw-interface"
        } case TokenKind::KwExtend {
            return "kw-extend"
        } case TokenKind::KwModule {
            return "kw-module"
        } case TokenKind::KwTest {
            return "kw-test"
        } case TokenKind::KwMacro {
            return "kw-macro"
        } case TokenKind::KwImport {
            return "kw-import"
        } case TokenKind::KwOverride {
            return "kw-override"
        } case TokenKind::KwFinal {
            return "kw-final"
        } case TokenKind::KwFfi {
            return "kw-ffi"
        } case TokenKind::KwImpl {
            return "kw-impl"
        } case TokenKind::KwDerives {
            return "kw-derives"
        } case TokenKind::KwWhere {
            return "kw-where"
        } case TokenKind::KwRequires {
            return "kw-requires"
        } case TokenKind::KwUnion {
            return "kw-union"
        } case TokenKind::KwPub {
            return "kw-pub"
        } case TokenKind::KwPriv {
            return "kw-priv"
        } case TokenKind::KwProt {
            return "kw-prot"
        } case TokenKind::KwEval {
            return "kw-eval"
        } case TokenKind::KwUnsafe {
            return "kw-unsafe"
        } case TokenKind::KwStatic {
            return "kw-static"
        } case TokenKind::KwAsync {
            return "kw-async"
        } case TokenKind::KwInline {
            return "kw-inline"
        } case TokenKind::KwSelf {
            return "kw-self"
        } case TokenKind::KwTrue {
            return "kw-true"
        } case TokenKind::KwFalse {
            return "kw-false"
        } case TokenKind::KwIn {
            return "kw-in"
        } case TokenKind::KwAs {
            return "kw-as"
        } case TokenKind::KwAnd {
            return "kw-and"
        } case TokenKind::KwAndEq {
            return "kw-and-eq"
        } case TokenKind::KwBitand {
            return "kw-bitand"
        } case TokenKind::KwBitor {
            return "kw-bitor"
        } case TokenKind::KwCompl {
            return "kw-compl"
        } case TokenKind::KwNot {
            return "kw-not"
        } case TokenKind::KwNotEq {
            return "kw-not-eq"
        } case TokenKind::KwOr {
            return "kw-or"
        } case TokenKind::KwOrEq {
            return "kw-or-eq"
        } case TokenKind::KwXor {
            return "kw-xor"
        } case TokenKind::KwXorEq {
            return "kw-xor-eq"
        } case TokenKind::AtVoid {
            return "at-void"
        } case TokenKind::AtBool {
            return "at-bool"
        } case TokenKind::AtByte {
            return "at-byte"
        } case TokenKind::AtChar {
            return "at-char"
        } case TokenKind::AtF8 {
            return "at-f8"
        } case TokenKind::AtF8E4M3 {
            return "at-f8e4m3"
        } case TokenKind::AtF8E5M2 {
            return "at-f8e5m2"
        } case TokenKind::AtF512 {
            return "at-f512"
        } case TokenKind::AtF16 {
            return "at-f16"
        } case TokenKind::AtBf16 {
            return "at-bf16"
        } case TokenKind::AtUsize {
            return "at-usize"
        } case TokenKind::AtIsize {
            return "at-isize"
        } case TokenKind::AtF32 {
            return "at-f32"
        } case TokenKind::AtF64 {
            return "at-f64"
        } case TokenKind::AtF80 {
            return "at-f80"
        } case TokenKind::AtF128 {
            return "at-f128"
        } case TokenKind::AtU8 {
            return "at-u8"
        } case TokenKind::AtU16 {
            return "at-u16"
        } case TokenKind::AtU32 {
            return "at-u32"
        } case TokenKind::AtU64 {
            return "at-u64"
        } case TokenKind::AtU128 {
            return "at-u128"
        } case TokenKind::AtU256 {
            return "at-u256"
        } case TokenKind::AtI8 {
            return "at-i8"
        } case TokenKind::AtI16 {
            return "at-i16"
        } case TokenKind::AtI32 {
            return "at-i32"
        } case TokenKind::AtI64 {
            return "at-i64"
        } case TokenKind::AtI128 {
            return "at-i128"
        } case TokenKind::AtI256 {
            return "at-i256"
        } case TokenKind::KwAwait {
            return "kw-await"
        } case TokenKind::KwThread {
            return "kw-thread"
        } case TokenKind::KwSpawn {
            return "kw-spawn"
        } case TokenKind::KwDelete {
            return "kw-delete"
        } case TokenKind::KwYield {
            return "kw-yield"
        } case TokenKind::KwSizeOf {
            return "kw-size-of"
        } case TokenKind::KwAlignOf {
            return "kw-align-of"
        } case TokenKind::KwTypeOf {
            return "kw-type-of"
        } case TokenKind::BiFile {
            return "bi-file"
        } case TokenKind::BiLine {
            return "bi-line"
        } case TokenKind::BiColumn {
            return "bi-column"
        } case TokenKind::BiFunction {
            return "bi-function"
        } case TokenKind::BiSelf {
            return "bi-self"
        } case TokenKind::BiModule {
            return "bi-module"
        } case TokenKind::KwVolatile {
            return "kw-volatile"
        } case TokenKind::KwVirtual {
            return "kw-virtual"
        } case TokenKind::KwMutable {
            return "kw-mutable"
        } default { } // TkCodeComplete, TkCount, ...: the return below
    }

    return "tk-unknown"
}

pub fn token_kind_to_readable_string(kind: TokenKind) -> string {
    match kind {
        case TokenKind::TkUnknown {
            return "UNKNOWN"
        } case TokenKind::TkEof {
            return "END OF FILE"
        } case TokenKind::TkError {
            return "ERROR"
        } case TokenKind::AtComment {
            return "comment"
        } case TokenKind::TkNewLine {
            return "new line"
        } case TokenKind::TkWhitespace {
            return "any whitespace"
        } case TokenKind::TkFileStart {
            return "FILE START"
        } case TokenKind::TkFileEnd {
            return "FILE END"
        } case TokenKind::TkGenerated {
            return "GENERATED"
        } case TokenKind::TkMacroExpand {
            return "MACRO EXPANDED"
        } case TokenKind::LitIdentifier {
            return "identifier"
        } case TokenKind::LitNull {
            return "null"
        } case TokenKind::LitInt {
            return "integer"
        } case TokenKind::LitFloat {
            return "floating point"
        } case TokenKind::LitString {
            return "string"
        } case TokenKind::LitChar {
            return "character"
        } case TokenKind::OpLBrace {
            return "{"
        } case TokenKind::OpRBrace {
            return "}"
        } case TokenKind::OpLParen {
            return "("
        } case TokenKind::OpRParen {
            return ")"
        } case TokenKind::OpLSquare {
            return "["
        } case TokenKind::OpRSquare {
            return "]"
        } case TokenKind::OpBackslash {
            return "\\"
        } case TokenKind::OpLess {
            return "<"
        } case TokenKind::OpGreater {
            return ">"
        } case TokenKind::OpPlus {
            return "+"
        } case TokenKind::OpMinus {
            return "-"
        } case TokenKind::OpStar {
            return "*"
        } case TokenKind::OpSlash {
            return "/"
        } case TokenKind::OpPercent {
            return "%"
        } case TokenKind::OpCaret {
            return "^"
        } case TokenKind::OpPipe {
            return "|"
        } case TokenKind::OpAmp {
            return "&"
        } case TokenKind::OpCaretCaret {
            return "^^"
        } case TokenKind::OpRange {
            return ".."
        } case TokenKind::OpRangeEqual {
            return "..="
        } case TokenKind::OpTilde {
            return "~"
        } case TokenKind::OpQuestion {
            return "?"
        } case TokenKind::OpExclaim {
            return "!"
        } case TokenKind::OpAt {
            return "@"
        } case TokenKind::OpEqual {
            return "="
        } case TokenKind::OpPlusPlus {
            return "++"
        } case TokenKind::OpMinusMinus {
            return "--"
        } case TokenKind::OpArrow {
            return "->"
        } case TokenKind::OpArrowStar {
            return "->*"
        } case TokenKind::OpFatArrow {
            return "=>"
        } case TokenKind::OpQuestionArrow {
            return "?->"
        } case TokenKind::OpQuestionArrowStar {
            return "?->*"
        } case TokenKind::OpColon {
            return ":"
        } case TokenKind::OpSemicolon {
            return ";"
        } case TokenKind::OpComma {
            return ","
        } case TokenKind::OpDot {
            return "."
        } case TokenKind::OpDotStar {
            return ".*"
        } case TokenKind::OpColonColon {
            return "::"
        } case TokenKind::OpQuestionDot {
            return "?."
        } case TokenKind::OpQuestionDotStar {
            return "?.*"
        } case TokenKind::OpEllipsis {
            return "..."
        } case TokenKind::OpPlusEqual {
            return "+="
        } case TokenKind::OpMinusEqual {
            return "-="
        } case TokenKind::OpStarEqual {
            return "*="
        } case TokenKind::OpSlashEqual {
            return "/="
        } case TokenKind::OpPercentEqual {
            return "%="
        } case TokenKind::OpAmpEqual {
            return "&="
        } case TokenKind::OpPipeEqual {
            return "|="
        } case TokenKind::OpCaretEqual {
            return "^="
        } case TokenKind::OpLessLessEqual {
            return "<<="
        } case TokenKind::OpGreaterGreaterEqual {
            return ">>="
        } case TokenKind::OpAtEqual {
            return "@="
        } case TokenKind::OpLessEqualGreater {
            return "<=>"
        } case TokenKind::OpEqualEqualEqual {
            return "==="
        } case TokenKind::OpEqualEqual {
            return "=="
        } case TokenKind::OpExclaimEqual {
            return "!="
        } case TokenKind::OpLessLess {
            return "<<"
        } case TokenKind::OpGreaterGreater {
            return ">>"
        } case TokenKind::OpLessEqual {
            return "<="
        } case TokenKind::OpGreaterEqual {
            return ">="
        } case TokenKind::OpAmpAmp {
            return "&&"
        } case TokenKind::OpPipePipe {
            return "||"
        } case TokenKind::OpQuestionQuestion {
            return "??"
        } case TokenKind::KwReturn {
            return "return"
        } case TokenKind::KwBreak {
            return "break"
        } case TokenKind::KwContinue {
            return "continue"
        } case TokenKind::KwPanic {
            return "panic"
        } case TokenKind::KwMatch {
            return "match"
        } case TokenKind::KwCase {
            return "case"
        } case TokenKind::KwDefault {
            return "default"
        } case TokenKind::KwCatch {
            return "catch"
        } case TokenKind::KwTry {
            return "try"
        } case TokenKind::KwFinally {
            return "finally"
        } case TokenKind::KwIf {
            return "if"
        } case TokenKind::KwElse {
            return "else"
        } case TokenKind::KwWhile {
            return "while"
        } case TokenKind::KwFor {
            return "for"
        } case TokenKind::KwAssert {
            return "assert"
        } case TokenKind::KwLoop {
            return "loop"
        } case TokenKind::KwVar {
            return "var"
        } case TokenKind::KwConst {
            return "const"
        } case TokenKind::KwFn {
            return "fn"
        } case TokenKind::KwOp {
            return "op"
        } case TokenKind::KwClass {
            return "class"
        } case TokenKind::KwEnum {
            return "enum"
        } case TokenKind::KwType {
            return "type"
        } case TokenKind::KwStruct {
            return "struct"
        } case TokenKind::KwInterface {
            return "interface"
        } case TokenKind::KwExtend {
            return "extend"
        } case TokenKind::KwModule {
            return "module"
        } case TokenKind::KwTest {
            return "test"
        } case TokenKind::KwMacro {
            return "macro"
        } case TokenKind::KwImport {
            return "import"
        } case TokenKind::KwOverride {
            return "override"
        } case TokenKind::KwFinal {
            return "final"
        } case TokenKind::KwFfi {
            return "ffi"
        } case TokenKind::KwImpl {
            return "impl"
        } case TokenKind::KwDerives {
            return "derives"
        } case TokenKind::KwWhere {
            return "where"
        } case TokenKind::KwRequires {
            return "requires"
        } case TokenKind::KwUnion {
            return "union"
        } case TokenKind::KwPub {
            return "pub"
        } case TokenKind::KwPriv {
            return "priv"
        } case TokenKind::KwProt {
            return "prot"
        } case TokenKind::KwEval {
            return "eval"
        } case TokenKind::KwUnsafe {
            return "unsafe"
        } case TokenKind::KwStatic {
            return "static"
        } case TokenKind::KwAsync {
            return "async"
        } case TokenKind::KwInline {
            return "inline"
        } case TokenKind::KwSelf {
            return "self"
        } case TokenKind::KwTrue {
            return "true"
        } case TokenKind::KwFalse {
            return "false"
        } case TokenKind::KwIn {
            return "in"
        } case TokenKind::KwAs {
            return "as"
        } case TokenKind::KwAnd {
            return "and"
        } case TokenKind::KwAndEq {
            return "and_eq"
        } case TokenKind::KwBitand {
            return "bitand"
        } case TokenKind::KwBitor {
            return "bitor"
        } case TokenKind::KwCompl {
            return "compl"
        } case TokenKind::KwNot {
            return "not"
        } case TokenKind::KwNotEq {
            return "not_eq"
        } case TokenKind::KwOr {
            return "or"
        } case TokenKind::KwOrEq {
            return "or_eq"
        } case TokenKind::KwXor {
            return "xor"
        } case TokenKind::KwXorEq {
            return "xor_eq"
        } case TokenKind::AtVoid {
            return "void"
        } case TokenKind::AtBool {
            return "bool"
        } case TokenKind::AtByte {
            return "byte"
        } case TokenKind::AtChar {
            return "char"
        } case TokenKind::AtF8 {
            return "f8"
        } case TokenKind::AtF8E4M3 {
            return "f8e4m3"
        } case TokenKind::AtF8E5M2 {
            return "f8e5m2"
        } case TokenKind::AtF512 {
            return "f512"
        } case TokenKind::AtF16 {
            return "f16"
        } case TokenKind::AtBf16 {
            return "bf16"
        } case TokenKind::AtUsize {
            return "usize"
        } case TokenKind::AtIsize {
            return "isize"
        } case TokenKind::AtF32 {
            return "f32"
        } case TokenKind::AtF64 {
            return "f64"
        } case TokenKind::AtF80 {
            return "f80"
        } case TokenKind::AtF128 {
            return "f128"
        } case TokenKind::AtF256 {
            return "f256"
        } case TokenKind::AtU8 {
            return "u8"
        } case TokenKind::AtU16 {
            return "u16"
        } case TokenKind::AtU32 {
            return "u32"
        } case TokenKind::AtU64 {
            return "u64"
        } case TokenKind::AtU128 {
            return "u128"
        } case TokenKind::AtU256 {
            return "u256"
        } case TokenKind::AtU512 {
            return "u512"
        } case TokenKind::AtI8 {
            return "i8"
        } case TokenKind::AtI16 {
            return "i16"
        } case TokenKind::AtI32 {
            return "i32"
        } case TokenKind::AtI64 {
            return "i64"
        } case TokenKind::AtI128 {
            return "i128"
        } case TokenKind::AtI256 {
            return "i256"
        } case TokenKind::AtI512 {
            return "i512"
        } case TokenKind::KwAwait {
            return "await"
        } case TokenKind::KwThread {
            return "thread"
        } case TokenKind::KwSpawn {
            return "spawn"
        } case TokenKind::KwDelete {
            return "delete"
        } case TokenKind::KwYield {
            return "yield"
        } case TokenKind::KwSizeOf {
            return "sizeof"
        } case TokenKind::KwAlignOf {
            return "alignof"
        } case TokenKind::KwTypeOf {
            return "typeof"
        } case TokenKind::BiFile {
            return "__file__!"
        } case TokenKind::BiLine {
            return "__line__!"
        } case TokenKind::BiColumn {
            return "__column__!"
        } case TokenKind::BiFunction {
            return "__function__!"
        } case TokenKind::BiModule {
            return "__module__!"
        } case TokenKind::BiSelf {
            return "Self"
        } case TokenKind::KwVolatile {
            return "volatile"
        } case TokenKind::KwVirtual {
            return "virtual"
        } case TokenKind::KwAtomic {
            return "atomic"
        } case TokenKind::KwMutable {
            return "mutable"
        } default { } // TkCodeComplete, TkCount, ...: the return below
    }

    return "UNKNOWN"
}

pub fn is_annotation(kind: TokenKind) -> bool {
    match kind {
        case TokenKind::AtI256,   TokenKind::AtU16,     TokenKind::AtVoid,  TokenKind::AtU32,
             TokenKind::AtBool,   TokenKind::AtU64,     TokenKind::AtUsize, TokenKind::AtU128,
             TokenKind::AtIsize,  TokenKind::AtU256,    TokenKind::AtF32,   TokenKind::AtI8,
             TokenKind::AtF64,    TokenKind::AtI16,     TokenKind::AtF80,   TokenKind::AtI32,
             TokenKind::AtF128,   TokenKind::AtI64,     TokenKind::AtU8,    TokenKind::AtI128,
             TokenKind::AtByte,   TokenKind::AtChar,    TokenKind::AtF8,    TokenKind::AtF8E4M3,
             TokenKind::AtF8E5M2, TokenKind::AtComment, TokenKind::AtF512,  TokenKind::AtF16,
             TokenKind::AtBf16,   TokenKind::AtF256,    TokenKind::AtI512,  TokenKind::AtU512 {
            return true
        } default {
            return false
        }
    }
}

pub fn is_keyword(kind: TokenKind) -> bool {
    match kind {
        case TokenKind::KwReturn,  TokenKind::KwBreak,    TokenKind::KwCase,
             TokenKind::KwDefault, TokenKind::KwIf,       TokenKind::KwElse,
             TokenKind::KwLoop,    TokenKind::KwVar,      TokenKind::KwClass,
             TokenKind::KwEnum,    TokenKind::KwExtend,   TokenKind::KwModule,
             TokenKind::KwFinal,   TokenKind::KwFfi,      TokenKind::KwDerives,
             TokenKind::KwWhere,   TokenKind::KwEval,     TokenKind::KwUnsafe,
             TokenKind::KwAwait,   TokenKind::KwThread,   TokenKind::KwSizeOf,
             TokenKind::KwAlignOf, TokenKind::KwPanic,    TokenKind::KwMatch,
             TokenKind::KwCatch,   TokenKind::KwTry,      TokenKind::KwWhile,
             TokenKind::KwFor,     TokenKind::KwConst,    TokenKind::KwFn,
             TokenKind::KwType,    TokenKind::KwStruct,   TokenKind::KwTest,
             TokenKind::KwMacro,   TokenKind::KwAs,       TokenKind::KwImpl,
             TokenKind::KwPub,     TokenKind::KwPriv,     TokenKind::KwStatic,
             TokenKind::KwAsync,   TokenKind::KwSpawn,    TokenKind::KwDelete,
             TokenKind::KwTypeOf,  TokenKind::KwContinue, TokenKind::KwFinally,
             TokenKind::KwImport,  TokenKind::KwAssert,   TokenKind::KwOverride,
             TokenKind::KwOp,      TokenKind::KwProt,     TokenKind::KwInterface,
             TokenKind::KwInline,  TokenKind::KwYield,    TokenKind::KwRequires,
             TokenKind::KwUnion {
            return true
        } default {
            return false
        }
    }
}

/// The kind an operator NAME is keyed on: the symbol for every word form.
/// `op bitand` and `a & b` are one operator, and op_name must not know
/// which spelling reached it.
pub fn canonical_operator_kind(k: TokenKind) -> TokenKind {
    match k {
        case TokenKind::KwBitand {
            return TokenKind::OpAmp
        } case TokenKind::KwBitor {
            return TokenKind::OpPipe
        } case TokenKind::KwXor {
            return TokenKind::OpCaret
        } case TokenKind::KwCompl {
            return TokenKind::OpTilde
        } case TokenKind::KwNotEq {
            return TokenKind::OpExclaimEqual
        } case TokenKind::KwAndEq {
            return TokenKind::OpAmpEqual
        } case TokenKind::KwOrEq {
            return TokenKind::OpPipeEqual
        } case TokenKind::KwXorEq {
            return TokenKind::OpCaretEqual
        } default {
            return k
        }
    }
}

pub fn is_unary_operator(kind: TokenKind) -> bool {
    match kind {
        case TokenKind::KwNot,     TokenKind::OpQuestion,   TokenKind::KwAwait,
             TokenKind::OpExclaim, TokenKind::KwThread,     TokenKind::KwCompl,
             TokenKind::KwSpawn,   TokenKind::OpAt,         TokenKind::KwDelete,
             TokenKind::OpEqual,   TokenKind::KwYield,      TokenKind::OpPlusPlus,
             TokenKind::KwSizeOf,  TokenKind::OpMinusMinus, TokenKind::KwAlignOf,
             TokenKind::OpPlus,    TokenKind::KwTypeOf,     TokenKind::OpMinus,
             TokenKind::KwAs,      TokenKind::OpStar,       TokenKind::OpRange,
             TokenKind::OpAmp,     TokenKind::OpTilde,      TokenKind::OpEllipsis {
            return true
        } default {
            return false
        }
    }
}

pub fn is_binary_operator(kind: TokenKind) -> bool {
    match kind {
        case TokenKind::KwIn,                TokenKind::OpLessLessEqual,
             TokenKind::KwAs,                TokenKind::OpGreaterGreaterEqual,
             TokenKind::KwAnd,               TokenKind::OpAtEqual,
             TokenKind::KwAndEq,             TokenKind::OpEqual,
             TokenKind::KwBitand,            TokenKind::OpLess,
             TokenKind::KwBitor,             TokenKind::OpGreater,
             TokenKind::KwNotEq,             TokenKind::OpPlus,
             TokenKind::KwOr,                TokenKind::OpMinus,
             TokenKind::KwOrEq,              TokenKind::OpStar,
             TokenKind::KwXor,               TokenKind::OpSlash,
             TokenKind::KwXorEq,             TokenKind::OpPercent,
             TokenKind::OpLessEqualGreater,  TokenKind::OpCaret,
             TokenKind::OpEqualEqualEqual,   TokenKind::OpPipe,
             TokenKind::OpEqualEqual,        TokenKind::OpAmp,
             TokenKind::OpExclaimEqual,      TokenKind::OpCaretCaret,
             TokenKind::OpLessLess,          TokenKind::OpRange,
             TokenKind::OpGreaterGreater,    TokenKind::OpRangeEqual,
             TokenKind::OpLessEqual,         TokenKind::OpAt,
             TokenKind::OpGreaterEqual,      TokenKind::OpArrow,
             TokenKind::OpAmpAmp,            TokenKind::OpArrowStar,
             TokenKind::OpPipePipe,          TokenKind::OpQuestionArrow,
             TokenKind::OpQuestionArrowStar, TokenKind::OpQuestionQuestion,
             TokenKind::OpQuestionDotStar,   TokenKind::OpPlusEqual,
             TokenKind::OpCaretEqual,        TokenKind::OpMinusEqual,
             TokenKind::OpComma,             TokenKind::OpStarEqual,
             TokenKind::OpDot,               TokenKind::OpSlashEqual,
             TokenKind::OpDotStar,           TokenKind::OpPercentEqual,
             TokenKind::OpQuestionDot,       TokenKind::OpAmpEqual,
             TokenKind::OpPipeEqual {
            return true
        } default {
            return false
        }
    }
}

pub fn is_assignment_operator(kind: TokenKind) -> bool {
    match kind {
        case TokenKind::OpPlusEqual,  TokenKind::OpPipeEqual,           TokenKind::OpMinusEqual,
             TokenKind::OpCaretEqual, TokenKind::OpStarEqual,           TokenKind::OpLessLessEqual,
             TokenKind::OpSlashEqual, TokenKind::OpGreaterGreaterEqual, TokenKind::OpPercentEqual,
             TokenKind::OpAtEqual,    TokenKind::OpAmpEqual,            TokenKind::OpEqual {
            return true
        } default {
            return false
        }
    }
}

pub fn is_punctuator(kind: TokenKind) -> bool {
    match kind {
        case TokenKind::TkNewLine,   TokenKind::OpLSquare, TokenKind::TkWhitespace,
             TokenKind::OpRSquare,   TokenKind::OpLBrace,  TokenKind::OpBackslash,
             TokenKind::OpRBrace,    TokenKind::OpColon,   TokenKind::OpLParen,
             TokenKind::OpSemicolon, TokenKind::OpRParen {
            return true
        } default {
            return false
        }
    }
}

pub fn is_operator(kind: TokenKind) -> bool {
    return is_unary_operator(kind) || is_binary_operator(kind) || is_assignment_operator(kind)
}

pub fn is_builtin(kind: TokenKind) -> bool {
    match kind {
        case TokenKind::BiFile,    TokenKind::BiLine, TokenKind::BiColumn,  TokenKind::BiFunction,
             TokenKind::BiModule,  TokenKind::BiSelf, TokenKind::KwVirtual, TokenKind::KwVolatile,
             TokenKind::KwMutable {
            return true
        } default {
            return false
        }
    }
}

pub fn is_special(kind: TokenKind) -> bool {
    match kind {
        case TokenKind::KwSelf,       TokenKind::TkUnknown,     TokenKind::TkEof,
             TokenKind::TkError,      TokenKind::AtComment,     TokenKind::TkNewLine,
             TokenKind::TkWhitespace, TokenKind::TkFileStart,   TokenKind::TkFileEnd,
             TokenKind::TkGenerated,  TokenKind::TkMacroExpand {
            return true
        } default {
            return false
        }
    }
}

pub fn is_internal(kind: TokenKind) -> bool {
    match kind {
        case TokenKind::TkUnknown,     TokenKind::TkEof,     TokenKind::TkError,
             TokenKind::TkFileStart,   TokenKind::TkFileEnd, TokenKind::TkGenerated,
             TokenKind::TkMacroExpand {
            return true
        } default {
            return false
        }
    }
}

pub fn is_literal(kind: TokenKind) -> bool {
    match kind {
        case TokenKind::KwTrue, TokenKind::KwFalse,  TokenKind::LitIdentifier, TokenKind::LitNull,
             TokenKind::LitInt, TokenKind::LitFloat, TokenKind::LitString,     TokenKind::LitChar {
            return true
        } default {
            return false
        }
    }
}

pub fn is_substitutable(kind: TokenKind) -> bool {
    match kind {
        case TokenKind::KwAnd,   TokenKind::KwAndEq, TokenKind::KwBitand, TokenKind::KwBitor,
             TokenKind::KwCompl, TokenKind::KwNot,   TokenKind::KwNotEq,  TokenKind::KwOr,
             TokenKind::KwOrEq,  TokenKind::KwXor,   TokenKind::KwXorEq {
            return true
        } default {
            return false
        }
    }
}

pub fn substitute(kind: TokenKind) -> TokenKind {
    match kind {
        case TokenKind::KwAnd {
            return TokenKind::OpAmpAmp
        } case TokenKind::KwAndEq {
            return TokenKind::OpAmpEqual
        } case TokenKind::KwBitand {
            return TokenKind::OpAmp
        } case TokenKind::KwBitor {
            return TokenKind::OpPipe
        } case TokenKind::KwCompl {
            return TokenKind::OpTilde
        } case TokenKind::KwNot {
            return TokenKind::OpExclaim
        } case TokenKind::KwNotEq {
            return TokenKind::OpExclaimEqual
        } case TokenKind::KwOr {
            return TokenKind::OpPipePipe
        } case TokenKind::KwOrEq {
            return TokenKind::OpPipeEqual
        } case TokenKind::KwXor {
            return TokenKind::OpCaret
        } case TokenKind::KwXorEq {
            return TokenKind::OpCaretEqual
        } default {
            return TokenKind::TkUnknown
        }
    }
}
