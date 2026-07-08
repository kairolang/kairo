/// --- The Kairo Project ------------------------- Token/TokenText.k --- ///
///
///   \brief single source of truth for token text and expansion unwrapping.
///
///   \detail
///     Two layers, both here so they cannot drift:
///
///     1. unwrap_expansion() — the MECHANISM. Walks a TkMacroExpand chain
///        back to the original (kind, imm, def_range). No diagnostics, no
///        cursor movement, no policy. Every consumer that needs to look
///        through macro wrapping calls this; policy (emitting a diag on
///        depth overflow, skipping AtComment by advancing a cursor, etc.)
///        stays in the consumer.
///
///     2. TokenText::resolve() — the TEXT ACCESSOR. The only sanctioned way
///        to turn a token into its spelled text. Identifier spellings come
///        from the imm interner (synthesized identifiers have NO backing
///        source text); literals come from their imm payloads; operators
///        and keywords have canonical spellings; everything else falls back
///        to the source manager.
///
///     RULE: no consumer outside this file may call sm->get_text on a token
///     range to obtain token text. Raw source access is legitimate only for
///     source EXCERPTS (diagnostic carets, lexer escape errors) — never for
///     token spellings.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Token::Token::*;
import Token::TokenKind::*;
import Location::SourceRange::*;
import Location::SourceManager::*;
import Lexer::Immediate::*;
import Macro::Sentinel::*;

/// \struct UnwrappedToken
/// \brief result of walking a macro-expansion chain to its origin.
struct UnwrappedToken {
    var kind:        TokenKind;    ///< original token kind.
    var imm:         u32;          ///< original imm index (ident/literal payload).
    var def_range:   SourceRange;  ///< innermost definition-body site.
    var depth:       u32 = 0;      ///< chain hops walked (0 = not wrapped).
    var hit_limit:   bool = false; ///< chain exceeded max_depth; result truncated.
    var is_sentinel: bool = false; ///< compiler marker (todo!/include!/embed!...),
                                   ///  kind stays TkMacroExpand, imm is the sentinel.
}

/// \brief walks a TkMacroExpand chain back to the original token identity.
///
/// \details wrap_token chains original_kind/original_imm through nested
///          wraps, so a well-formed token unwraps in one hop; the loop is
///          defensive against malformed chains. Pure mechanism: reports
///          nothing, moves nothing. Callers decide what hit_limit and
///          is_sentinel mean for them.
fn unwrap_expansion(
    tok:       Token,
    tbl:   *ImmediateTable,
    max_depth: u32 = 32
) -> UnwrappedToken {
    var r = UnwrappedToken{};
    r.kind      = tok.kind;
    r.imm       = tok.imm;
    r.def_range = tok.range;

    while static_cast::<u32>(r.kind) == static_cast::<u32>(TokenKind::TkMacroExpand) {
        if r.imm >= static_cast::<u32>(MacroSentinel::Threshold) {
            r.is_sentinel = true;
            return r;
        }

        if (tbl == &null) || (r.depth >= max_depth) {
            r.hit_limit = (r.depth >= max_depth);
            return r;
        }

        var info    = tbl->get::<Immediate::MacroExpansionInfo>(r.imm);
        r.kind      = info->original_kind;
        r.imm       = info->original_imm;
        r.def_range = info->def_range;
        r.depth    += 1;
    }

    return r;
}

/// \brief canonical display text for a macro sentinel imm value.
fn sentinel_text(imm: u32) -> string {
    if imm == static_cast::<u32>(MacroSentinel::Todo)        { return "<todo>";        }
    if imm == static_cast::<u32>(MacroSentinel::Unreachable) { return "<unreachable>"; }
    if imm == static_cast::<u32>(MacroSentinel::Include)     { return "<include>";     }
    if imm == static_cast::<u32>(MacroSentinel::IncludeStr)  { return "<include_str>"; }
    if imm == static_cast::<u32>(MacroSentinel::Embed)       { return "<embed>";       }
    return "<unknown_macro>";
}

class TokenText {
    pub var text:      string;
    pub var range:     SourceRange;
    pub var is_expand: bool = false;
    pub var is_marker: bool = false;

    fn TokenText(
        self,
        txt: string,
        rng: SourceRange,
        expand: bool = false,
        marker: bool = false
    ) -> void {
        self.text      = txt;
        self.range     = rng;
        self.is_expand = expand;
        self.is_marker = marker;
    }

    /// \brief resolves a token to its spelled text.
    static fn resolve(
        tok:  Token,
        sm:  *SourceManager,
        tbl: *ImmediateTable
    ) -> TokenText {
        assert((sm  != &null) && r"SourceManager is null in TokenText::resolve");
        assert((tbl != &null) && r"ImmediateTable is null in TokenText::resolve");

        var u = unwrap_expansion(tok, tbl);

        // compiler-internal markers (todo!/include!/embed!...), not source tokens
        if u.is_sentinel {
            return TokenText(sentinel_text(u.imm), u.def_range, true, true);
        }

        var kind      = u.kind;
        var imm       = u.imm;
        var tok_range = u.def_range;
        var is_expand = (u.depth > 0);

        var create = fn (s: string) -> TokenText {
            return TokenText(s, tok_range, is_expand, false);
        };

        // these have no meaningful text return canonical representation
        switch kind {
            case TokenKind::TkUnknown {
                return create("$unknown$");
            } case TokenKind::TkEof {
                return create("$eof$");
            } case TokenKind::TkError {
                return create("$error$");
            } case TokenKind::TkNewLine {
                return create("\\n");
            } case TokenKind::TkWhitespace {
                return create(" ");
            } case TokenKind::TkFileStart {
                return create("$start$");
            } case TokenKind::TkFileEnd {
                return create("$end$");
            } case TokenKind::TkGenerated {
                return create("$generated$");
            } case TokenKind::TkMacroExpand {
                return create("$macro_expand$");
            } case TokenKind::TkCodeComplete {
                return create("$IDE_COMPL$");
            } case TokenKind::LitNull {
                return create("null");
            } case TokenKind::OpLBrace {
                return create("\x123");
            } case TokenKind::OpRBrace {
                return create("\x125");
            } case TokenKind::OpLParen {
                return create("(");
            } case TokenKind::OpRParen {
                return create(")");
            } case TokenKind::OpLSquare {
                return create("[");
            } case TokenKind::OpRSquare {
                return create("]");
            } case TokenKind::OpBackslash {
                return create("\\");
            } case TokenKind::OpLess {
                return create("<");
            } case TokenKind::OpGreater {
                return create(">");
            } case TokenKind::OpPlus {
                return create("+");
            } case TokenKind::OpMinus {
                return create("-");
            } case TokenKind::OpStar {
                return create("*");
            } case TokenKind::OpSlash {
                return create("/");
            } case TokenKind::OpPercent {
                return create("%");
            } case TokenKind::OpCaret {
                return create("^");
            } case TokenKind::OpPipe {
                return create("|");
            } case TokenKind::OpAmp {
                return create("&");
            } case TokenKind::OpCaretCaret {
                return create("^^");
            } case TokenKind::OpRange {
                return create("..");
            } case TokenKind::OpRangeEqual {
                return create("..=");
            } case TokenKind::OpTilde {
                return create("~");
            } case TokenKind::OpQuestion {
                return create("?");
            } case TokenKind::OpQuestionQuestion {
                return create("??");
            } case TokenKind::OpExclaim {
                return create("!");
            } case TokenKind::OpAt {
                return create("@");
            } case TokenKind::OpEqual {
                return create("=");
            } case TokenKind::OpPlusPlus {
                return create("++");
            } case TokenKind::OpMinusMinus {
                return create("--");
            } case TokenKind::OpSemicolon {
                return create(";");
            } case TokenKind::OpColon {
                return create(":");
            } case TokenKind::OpArrow {
                return create("->");
            } case TokenKind::OpArrowStar {
                return create("->*");
            } case TokenKind::OpQuestionArrow {
                return create("?->");
            } case TokenKind::OpQuestionArrowStar {
                return create("?->*");
            } case TokenKind::OpComma {
                return create(",");
            } case TokenKind::OpDot {
                return create(".");
            } case TokenKind::OpDotStar {
                return create(".*");
            } case TokenKind::OpColonColon {
                return create("::");
            } case TokenKind::OpQuestionDot {
                return create("?.");
            } case TokenKind::OpQuestionDotStar {
                return create("?.*");
            } case TokenKind::OpEllipsis {
                return create("...");
            } case TokenKind::OpPlusEqual {
                return create("+=");
            } case TokenKind::OpMinusEqual {
                return create("-=");
            } case TokenKind::OpStarEqual {
                return create("*=");
            } case TokenKind::OpSlashEqual {
                return create("/=");
            } case TokenKind::OpPercentEqual {
                return create("%=");
            } case TokenKind::OpAmpEqual {
                return create("&=");
            } case TokenKind::OpPipeEqual {
                return create("|=");
            } case TokenKind::OpCaretEqual {
                return create("^=");
            } case TokenKind::OpLessLessEqual {
                return create("<<=");
            } case TokenKind::OpGreaterGreaterEqual {
                return create(">>=");
            } case TokenKind::OpAtEqual {
                return create("@=");
            } case TokenKind::OpLessEqualGreater {
                return create("<=>");
            } case TokenKind::OpEqualEqualEqual {
                return create("===");
            } case TokenKind::OpEqualEqual {
                return create("==");
            } case TokenKind::OpExclaimEqual {
                return create("!=");
            } case TokenKind::OpLessLess {
                return create("<<");
            } case TokenKind::OpGreaterGreater {
                return create(">>");
            } case TokenKind::OpLessEqual {
                return create("<=");
            } case TokenKind::OpGreaterEqual {
                return create(">=");
            } case TokenKind::OpAmpAmp {
                return create("&&");
            } case TokenKind::OpPipePipe {
                return create("||");
            } case TokenKind::KwReturn {
                return create("return");
            } case TokenKind::KwBreak {
                return create("break");
            } case TokenKind::KwContinue {
                return create("continue");
            } case TokenKind::KwPanic {
                return create("panic");
            } case TokenKind::KwMatch {
                return create("match");
            } case TokenKind::KwCase {
                return create("case");
            } case TokenKind::KwDefault {
                return create("default");
            } case TokenKind::KwCatch {
                return create("catch");
            } case TokenKind::KwTry {
                return create("try");
            } case TokenKind::KwFinally {
                return create("finally");
            } case TokenKind::KwIf {
                return create("if");
            } case TokenKind::KwElse {
                return create("else");
            } case TokenKind::KwWhile {
                return create("while");
            } case TokenKind::KwFor {
                return create("for");
            } case TokenKind::KwAssert {
                return create("assert");
            } case TokenKind::KwLoop {
                return create("loop");
            } case TokenKind::KwVar {
                return create("var");
            } case TokenKind::KwConst {
                return create("const");
            } case TokenKind::KwFn {
                return create("fn");
            } case TokenKind::KwOp {
                return create("op");
            } case TokenKind::KwClass {
                return create("class");
            } case TokenKind::KwUnion {
                return create("union");
            } case TokenKind::KwEnum {
                return create("enum");
            } case TokenKind::KwType {
                return create("type");
            } case TokenKind::KwStruct {
                return create("struct");
            } case TokenKind::KwInterface {
                return create("interface");
            } case TokenKind::KwExtend {
                return create("extend");
            } case TokenKind::KwModule {
                return create("module");
            } case TokenKind::KwTest {
                return create("test");
            } case TokenKind::KwMacro {
                return create("macro");
            } case TokenKind::KwImport {
                return create("import");
            } case TokenKind::KwOverride {
                return create("override");
            } case TokenKind::KwFinal {
                return create("final");
            } case TokenKind::KwFfi {
                return create("ffi");
            } case TokenKind::KwImpl {
                return create("impl");
            } case TokenKind::KwDerives {
                return create("derives");
            } case TokenKind::KwWhere {
                return create("where");
            } case TokenKind::KwRequires {
                return create("requires");
            } case TokenKind::KwPub {
                return create("pub");
            } case TokenKind::KwPriv {
                return create("priv");
            } case TokenKind::KwProt {
                return create("prot");
            } case TokenKind::KwEval {
                return create("eval");
            } case TokenKind::KwUnsafe {
                return create("unsafe");
            } case TokenKind::KwStatic {
                return create("static");
            } case TokenKind::KwAsync {
                return create("async");
            } case TokenKind::KwInline {
                return create("inline");
            } case TokenKind::KwAtomic {
                return create("atomic");
            } case TokenKind::KwVolatile {
                return create("volatile");
            } case TokenKind::KwVirtual {
                return create("virtual");
            } case TokenKind::KwSelf {
                return create("self");
            } case TokenKind::KwTrue {
                return create("true");
            } case TokenKind::KwFalse {
                return create("false");
            } case TokenKind::KwIn {
                return create("in");
            } case TokenKind::KwAs {
                return create("as");
            } case TokenKind::KwAnd {
                return create("and");
            } case TokenKind::KwAndEq {
                return create("and_eq");
            } case TokenKind::KwBitand {
                return create("bitand");
            } case TokenKind::KwBitor {
                return create("bitor");
            } case TokenKind::KwCompl {
                return create("compl");
            } case TokenKind::KwNot {
                return create("not");
            } case TokenKind::KwNotEq {
                return create("not_eq");
            } case TokenKind::KwOr {
                return create("or");
            } case TokenKind::KwOrEq {
                return create("or_eq");
            } case TokenKind::KwXor {
                return create("xor");
            } case TokenKind::KwXorEq {
                return create("xor_eq");
            } case TokenKind::AtVoid {
                return create("void");
            } case TokenKind::AtBool {
                return create("bool");
            } case TokenKind::AtUsize {
                return create("usize");
            } case TokenKind::AtIsize {
                return create("isize");
            } case TokenKind::AtF16 {
                return create("f16");
            } case TokenKind::AtF32 {
                return create("f32");
            } case TokenKind::AtF64 {
                return create("f64");
            } case TokenKind::AtF80 {
                return create("f80");
            } case TokenKind::AtF128 {
                return create("f128");
            } case TokenKind::AtF256 {
                return create("f256");
            } case TokenKind::AtU8 {
                return create("u8");
            } case TokenKind::AtU16 {
                return create("u16");
            } case TokenKind::AtU32 {
                return create("u32");
            } case TokenKind::AtU64 {
                return create("u64");
            } case TokenKind::AtU128 {
                return create("u128");
            } case TokenKind::AtU256 {
                return create("u256");
            } case TokenKind::AtU512 {
                return create("u512");
            } case TokenKind::AtI8 {
                return create("i8");
            } case TokenKind::AtI16 {
                return create("i16");
            } case TokenKind::AtI32 {
                return create("i32");
            } case TokenKind::AtI64 {
                return create("i64");
            } case TokenKind::AtI128 {
                return create("i128");
            } case TokenKind::AtI256 {
                return create("i256");
            } case TokenKind::AtI512 {
                return create("i512");
            } case TokenKind::KwAwait {
                return create("await");
            } case TokenKind::KwThread {
                return create("thread");
            } case TokenKind::KwSpawn {
                return create("spawn");
            } case TokenKind::KwDelete {
                return create("delete");
            } case TokenKind::KwYield {
                return create("yield");
            } case TokenKind::KwSizeOf {
                return create("sizeof");
            } case TokenKind::KwAlignOf {
                return create("alignof");
            } case TokenKind::KwTypeOf {
                return create("typeof");
            } case TokenKind::BiFile {
                return create("__file__");
            } case TokenKind::BiLine {
                return create("__line__");
            } case TokenKind::BiColumn {
                return create("__column__");
            } case TokenKind::BiFunction {
                return create("__function__");
            } case TokenKind::BiModule {
                return create("__module__");
            } case TokenKind::BiSelf {
                return create("Self");
            } case TokenKind::LitInt {
                if tbl != &null {
                    var int_data = tbl->get::<Immediate::IntData>(imm);
                    return create(f"{int_data->value_lo}");
                }

                return create(sm->get_text(tok_range));
            } case TokenKind::LitFloat {
                if tbl != &null {
                    var float_data = tbl->get::<Immediate::FloatData>(imm);
                    return create(f"{float_data->value_ieee}");
                }

                return create(sm->get_text(tok_range));
            } case TokenKind::LitIdentifier {
                // identifier spelling lives in the imm interner, NEVER in the
                // source range: synthesized identifiers (unique_id!, gensym)
                // have no backing source text, and `imm` here is the UNWRAPPED
                // ident index (tok.imm on a wrapped token is the expansion
                // record, not the ident — see unwrap_expansion).
                if tbl != &null {
                    return create(tbl->get_ident(imm));
                }

                return create(f"$FALLBACK-MISSING-INTERN$ {sm->get_text(tok_range)}");
            } default {
                // everything else falls back to the source manager
                return TokenText(sm->get_text(tok_range), tok_range, is_expand, false);
            }

            // LitString / LitChar deliberately fall through to the range
            // fallback below: their spelled text (quotes, prefixes, escapes)
            // is exactly the source bytes. Decoded VALUES come from their imm
            // payloads (StringData/CharData), which is a different question
            // than spelling.
        }

        // string/char literals, doc comments, and anything unlisted: the
        // source bytes are the spelling.
        //
        // THIS is dead-code, the default branch handles it, but we keep it here for clarity.
        return TokenText(sm->get_text(tok_range), tok_range, is_expand, false);
    }

    /// \brief raw source slice for a RANGE (not a token).
    static fn from_range(range: SourceRange, sm: *SourceManager) -> TokenText {
        assert((sm != &null) && r"SourceManager is null in TokenText::from_range");
        return TokenText(sm->get_text(range), range, false, false);
    }

    fn get_text(self) -> string {
        return self.text;
    }

    fn get_range(self) -> SourceRange {
        return self.range;
    }

    fn is_macro_expansion(self) -> bool {
        return self.is_expand;
    }

    fn is_macro_marker(self) -> bool {
        return self.is_marker;
    }
}
