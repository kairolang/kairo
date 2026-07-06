/// --- The Kairo Project ----------------------------- AST/ASTSupport.k --- ///
///
///   Provides shared utilities, types, and helper functions for the AST module.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
/// Support code for the parser and related tools.  This is not intended to be
/// a general-purpose library, but rather a place for shared utilities that
/// are used across multiple parser components (e.g. the main parser, the
/// lexer, the AST printer, etc).

/// This contains:
///   - Common data strcutures, interfaces, and utilities for the parser and related tools.
///   - Also our custom RTTI system.

import AST::Context::ASTContext::*;
import Token::TokenKind::*;
import Memory::ArenaList::*;
import Location::SourceManager::*;
import Macro::Sentinel::*;
import Lexer::Immediate::*;
import Token::Token::*;

///
/// \class FrozenList<T>
/// \brief Non-owning, immutable view over a contiguous arena-allocated array.
///
/// Created by freezing an ArenaList<T> into the node arena via
/// ArenaList::freeze(). Once frozen, the array is fixedno push, no pop.
///
/// Lifetime: valid as long as the arena it was allocated from is alive.
/// The ASTContext's node_arena outlives all FrozenList instances.
///
/// Use this for all variable-length sequences inside AST nodes:
///   CompoundStmt::stmts
///   PathExpr::segments
///   ParamList::params
///   StringLiteralExpr::strings
///   ArgList::args
///   etc.
///
class <T> FrozenList {
    pub var items: *T    = &null;
    pub var count: usize = 0;
    pub var MAX:   usize = inline "c++" { (libcxx::numeric_limits<usize>::max)() };

    ///
    /// \brief Freeze an ArenaList into a FrozenList, allocating the
    /// contiguous backing array from the given arena.
    ///
    /// The ArenaList can be destroyed after this callthe FrozenList
    /// is fully independent.
    ///
    fn from_list(self, l: *ArenaList::<T>, arena: *ArenaAllocator) {
        self.count = l->size();
        self.items = l->freeze(arena);
    }

    fn from_vec(self, v: *vec::<T>, ctx: *ASTContext) {
        if (v == &null) || (v->size() == 0) {
            self.count = 0;
            self.items = &null;
            return;
        }

        self.count = v->size();
        self.items = ctx->alloc_array::<T>(self.count);
        for var i: usize = 0; i < self.count; ++i {
            self.items[i] = (*v)[i];
        }
    }

    fn from_buf(self, data: *T, count: usize, ctx: *ASTContext) {
        if count == 0 {
            self.count = 0;
            self.items = &null;
            return;
        }

        self.count = count;
        self.items = ctx->alloc_array::<T>(count);
        libcxx::memcpy(items, data, sizeof(T) * count);
    }

    fn begin(self) -> *T {
        return self.items;
    }

    fn end(self) -> *T {
        return self.items + self.count;
    }

    ///
    /// \brief Create directly from a raw pointer + count.
    /// Use when you already have an arena-allocated array.
    ///
    fn from_raw(self, items: *T, count: usize) {
        self.items = items;
        self.count = count;
    }

    ///
    /// \brief Empty FrozenListnull items, zero count.
    ///
    static fn empty() -> FrozenList::<T> {
        var fl: FrozenList::<T>;
        fl.items = &null;
        fl.count = 0;
        return fl;
    }

    ///
    /// \brief Bounds-checked element access. Returns null if OOB.
    ///
    fn get(self, index: usize) -> *T {
        if index >= self.count {
            return &null;
        }
        
        if self.items == &null {
            return &null;
        }

        return self.items + index;
    }

    ///
    /// \brief Bounds-checked subscript. Asserts if OOB.
    ///
    fn op [](self, index: usize) -> T {
        assert((index < self.count) && r"FrozenList index out of bounds");
        return *(self.items + index);
    }

    ///
    /// \brief First element. Null if empty.
    ///
    fn front(self) -> *T {
        if self.count == 0 { return &null; }
        return self.items;
    }

    ///
    /// \brief Last element. Null if empty.
    ///
    fn back(self) -> *T {
        if self.count == 0 { return &null; }
        return self.items + (self.count - 1);
    }

    fn size(self)  -> usize { return self.count; }
    fn is_empty(self) -> bool  { return self.count == 0; }

    ///
    /// \brief Linear searchreturns index of first match, usize::MAX if not found.
    /// Comparison uses == operator on T.
    ///
    fn find(self, val: T) -> usize {
        for var i: usize = 0; i < self.count; ++i {
            if self.items[i] == val {
                return i;
            }
        }

        return MAX; // not found
    }

    ///
    /// \brief Returns true if any element satisfies the predicate.
    /// pred must be a callable: fn(*T) -> bool
    ///
    fn any(self, pred: fn(*T) -> bool) -> bool {
        for var i: usize = 0; i < self.count; ++i {
            if pred(self.items + i) {
                return true;
            }
        }
        
        return false;
    }

    ///
    /// \brief Returns true if all elements satisfy the predicate.
    ///
    fn all(self, pred: fn(*T) -> bool) -> bool {
        for var i: usize = 0; i < self.count; ++i {
            if !pred(self.items + i) {
                return false;
            }
        }
        
        return true;
    }
}

fn <T> create_empty_frozen_list() -> FrozenList::<T> {
    inline "c++" {
        return FrozenList<T>::empty();
    }
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

    static fn resolve_basic(
        tok: Token,
        sm:  *SourceManager
    ) -> TokenText {
        var kind  = tok.kind;
        var range = tok.range;

        if kind == TokenKind::TkNewLine    { return TokenText("\n",  range, true, false); }
        if kind == TokenKind::TkWhitespace { return TokenText(" ",   range, true, false); }

        return TokenText(sm->get_text(tok.range), tok.range, false, false);
    }

    static fn resolve(
        tok:     Token,
        sm:      *SourceManager,
        imm_tbl: *ImmediateTable
    ) -> TokenText {
        var kind      = tok.kind;
        var imm       = tok.imm;
        var tok_range = tok.range;
        var is_expand = false;

        // if this token is a macro expansion AND it has a valid imm table entry
        // (i.e. below the sentinel threshold), resolve back to the original token
        if (static_cast::<u32>(kind) == static_cast::<u32>(TokenKind::TkMacroExpand))
        && (imm < static_cast::<u32>(MacroSentinel::Threshold)) {
            if imm_tbl != &null {
                var info  = imm_tbl->get::<Immediate::MacroExpansionInfo>(imm);
                kind      = info->original_kind;
                imm       = info->original_imm;
                tok_range = info->def_range;
                is_expand = true;
            }
        }

        // these are compiler-internal markers, not real source tokens
        if (static_cast::<u32>(kind) == static_cast::<u32>(TokenKind::TkMacroExpand))
        && (imm >= static_cast::<u32>(MacroSentinel::Threshold)) {
            if imm == static_cast::<u32>(MacroSentinel::Todo) {
                return TokenText("<todo>", tok_range, true, true);
            } else if imm == static_cast::<u32>(MacroSentinel::Unreachable) {
                return TokenText("<unreachable>", tok_range, true, true);
            } else if imm == static_cast::<u32>(MacroSentinel::Include) {
                return TokenText("<include>", tok_range, true, true);
            } else if imm == static_cast::<u32>(MacroSentinel::IncludeStr) {
                return TokenText("<include_str>", tok_range, true, true);
            } else if imm == static_cast::<u32>(MacroSentinel::Embed) {
                return TokenText("<embed>", tok_range, true, true);
            } else {
                return TokenText("<unknown_macro>", tok_range, true, true);
            }
        }

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
                if imm_tbl != &null {
                    var int_data = imm_tbl->get::<Immediate::IntData>(imm);
                    return create(f"{int_data->value_lo}");
                }

                return create(sm->get_text(tok_range));
            } case TokenKind::LitFloat {
                if imm_tbl != &null {
                    var float_data = imm_tbl->get::<Immediate::FloatData>(imm);
                    return create(f"{float_data->value_ieee}");
                }

                return create(sm->get_text(tok_range));
            } case TokenKind::LitIdentifier {
                /// this tis the bit now
                if imm_tbl != &null {
                    return create(imm_tbl->get_ident(tok.imm));
                }
                
                return create(f"$FALLBACK-MISSING-INTERN$ {sm->get_text(tok_range)}");
            }

            // maybe???? case TokenKind::LitString
            // maybe???? case TokenKind::LitChar
            // maybe???? case TokenKind::AtComment
        }

        // identifiers with imm > 0 and below threshold were renamed by the
        // macro hygiene system surface them with their internal unique id
        // so sema sees a stable non-garbled name
        
        /// **TODO - FIXME**
        /// \FUCK what to do FIXME....
        
        // if (static_cast::<u32>(kind) == static_cast::<u32>(TokenKind::LitIdentifier))
        // && (imm > 0)
        // && (imm < static_cast::<u32>(MacroSentinel::Threshold)) {
        //     return TokenText(f"__kairo_hyg_{imm}__", tok_range, true, true);
        // }


        // keywords, identifiers, string literals, float literals
        // all have their text directly in the source manager
        return TokenText(sm->get_text(tok_range), tok_range, true, false);
    }

    static fn from_token(token: Token, ctx: *ASTContext) -> TokenText {
        return TokenText::resolve(token, ctx->sm, ctx->get_imm_table());
    }

    static fn from_range(range: SourceRange, ctx: *ASTContext) -> TokenText {
        return TokenText(ctx->sm->get_text(range), range, false, false);
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





























/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿⢟⣛⣛⣛⣛⡻⠿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡟⢁⣺⣿⣿⣿⣿⣿⣿⣿⣶⠈⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡟⠃⠼⢽⣿⣿⠿⠻⠛⠻⢿⣿⠀⣾⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠁⠀⠀⠀⠙⠁⠀⠀⢠⡀⠀⢬⠃⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡟⠀⠀⠻⡄⠀⣇⠀⠃⠀⠘⡇⠀⠄⢿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡟⠀⠀⠀⢈⢸⡿⣦⣀⢀⣀⣴⣿⡆⢸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡇⠙⠳⠞⠁⠸⠷⠦⠈⠉⠉⠉⠀⠀⢸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣦⠀⠀⠆⠀⠀⠤⠿⠂⠀⠀⠀⠀⢸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣧⡄⠀⠀⠀⠈⣠⡼⠃⠀⠀⠀⢸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠃⠀⠀⠀⠛⠉⠀⢀⠠⠀⠀⢸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠠⠀⠀⠀⠀⢤⠘⠤⠁⢰⡆⢸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠀⠀⠀⢠⠋⠤⡉⠐⡀⠀⢿⠸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠀⠄⠀⠀⡘⢀⠆⠡⠀⠀⣈⠀⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡇⠀⠀⠀⠀⡐⠈⠤⢁⠂⠀⡟⢰⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡇⡀⠀⠀⠀⠠⠁⠂⠄⠀⣸⠁⣸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡇⠁⠀⠀⠀⠀⠀⠀⠀⠈⠁⢰⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿⢁⠆⠀⠀⠀⢀⣐⠀⠀⠀⢀⣸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡟⡁⠁⣼⡇⠀⠀⣿⣿⠀⡀⢀⣷⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠏⡔⠀⣼⣿⡇⣀⠀⣿⣿⡆⣡⠘⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿⢡⡞⢀⣾⣿⣿⣇⠀⠀⢿⣿⡇⠁⠀⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡏⣴⡇⢠⣾⣿⣿⣿⣿⠀⠀⢸⣿⣧⠀⠀⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠏⣼⠍⢀⣿⣿⣿⣿⣿⣿⡀⠀⢸⣿⣿⡀⠀⣻⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿⠋⡸⠁⢀⣾⣿⣿⣿⣿⣿⣿⣇⢀⠈⣿⣿⡇⠀⢸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠟⠁⠄⠀⢠⣾⣿⣿⣿⣿⣿⣿⣿⡟⠀⠀⢿⡿⠁⠀⠘⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿⠋⠀⠀⠀⣠⣾⣿⣿⣿⠿⠛⣛⣹⡏⠀⠀⠀⠀⢠⣾⣆⠀⢻⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣦⣀⡀⠀⢰⣿⣿⣿⡃⠄⠤⡶⠋⠉⣁⣠⣴⡆⠰⠛⠻⠻⠢⠘⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣷⣿⣿⣿⣿⣿⣷⣶⣶⣾⣿⣿⣿⣯⣁⣀⡊⣘⣀⣀⣤⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
///                                                                          ///
/// Yes, do not question the existence of this T^3 ascii art.                ///
/// It is a necessary part of the parser support code.     ~ @OjasTalgaonkar ///
///                                                                          ///
/// WHAT THE FUCK IS THIS                                          ~ @Ze7111 ///
///                                                                          ///