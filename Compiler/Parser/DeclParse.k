/// --- The Kairo Project --------------------------- Parser/DeclParse.k --- ///
///
///   The declaration parser mixin: recursive descent over declarations.
///
///     Entry point: parse_decl() -> consumes leading annotations/visibility,
///     dispatches on the leading (resolved) keyword to the correct production,
///     stamps annotations, and returns a *Decl. Returns null only at EOF or
///     when the current token cannot begin a declaration (caller decides what
///     that means in its context).
///
///     Derives from ASTParse (CRTP) which provides: check, check_peek,
///     match_tok, expect, advance, retreat, current, peek, prev, current_ptr,
///     ctx, diag, scope, is_eof, enter_depth/exit_depth,
///     enter_scope/exit_scope, consume_leading_annotations,
///     apply_annotations_to_decl, parse_type (TypeParse), parse_expr
///     (ExprParse), parse_compound (StmtParse), etc.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the Kairo
///   Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------- ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::ASTSupport::FrozenList
import AST::Context::DeclContext::{
    DeclContext,
    DeclContextKind,
}
import AST::LangItems::{
    AllocNames,
    LangAttrs,
}
import AST::Mixin::Annotation::VisibilityKind
import AST::Mixin::FFILinkage::LinkageKind
import AST::Node::Base::{
    Decl,
    Expr,
    Stmt,
    Type,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    is_recovery,
    isa,
}
import AST::Node::Declarations
import AST::Node::Expressions::{
    BinaryOperatorExpr,
    ClosureExpr,
    ConstraintExpr,
    ParenExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
    StringLiteralExpr,
}
import AST::Node::Statements::FFILang
import AST::Node::Types::{
    ChainType,
    NullableType,
}
import AST::ParamMode::ParamMode
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Parser::LexicalScope::ScopeKind
import Support::FlagSet::FlagSet
import Token::Token::Token
import Token::TokenKind::{
    TokenKind,
    is_annotation,
    token_kind_to_readable_string,
}

// TODO(DUCK-GENERIC): T uses _consume_mode, _index_skip_block, _index_skip_stmt, _index_skip_to_body, _is_terminator_tok, _peek_mode, pay_close, _reject_mode_binding, _restore_cursor, advance, advance_raw, apply_annotations_to_decl, ... (60). Stage 0 was duck-typed; bound it or keep `: type`.
pub class <T: type> DeclParse {
    /// \enum DeclSyncCtx
    /// \brief sync contexts for declaration-level error recovery.
    enum DeclSyncCtx derives u8 {
        TopLevel, ///< sync to a decl lead-in keyword / newline / EOF.
        TypeBody, ///< inside a class/struct/enum/union body: sync to a member
        ///  lead-in or the closing `}`.
        Params,   ///< inside `( )` param list: sync to `,` or `)`.
        Generics, ///< inside `< >` generic list: sync to `,` or `>`.
    }

    //  CRTP helpers

    priv inline fn dyn(self) -> unsafe *T {
        return unsafe ((&self) as *T)
    }

    /// \brief the current token's range, or an empty range at the end of the
    ///        last token once the cursor has run off the stream.
    /// \details error recovery reaches EOF mid-decl (`fn h(@move`, `class D
    ///          derives`, `enum E { pub`), where current_ptr() is null; every
    ///          decl-path diagnostic and range join reads through here so a
    ///          truncated head reports at end of input instead of dereferencing
    ///          null.
    priv inline fn _cur_range(self) -> SourceRange {
        var cur = self.dyn()->current_ptr()
        if cur != &null {
            return cur->range
        }

        var last = self.dyn()->prev_ptr()
        if last == &null {
            return SourceRange::invalid()
        }

        return SourceRange(last->range.end, last->range.end)
    }

    /// \brief the kind of the token just consumed, or TkEof when there is
    ///        none.
    /// \details prev_ptr() is null once a recovery path advances a second
    ///          time past the last token (ASTParse::_advance moves the null
    ///          cursor into _prev), and a parameter list cut off by EOF
    ///          (`fn S :: h ( ( self ,`, `fn ( fn ( [`) gets there. The reads
    ///          after a parameter list or a panic set went through it
    ///          unguarded; the previous token's range has the same
    ///          guard in _prev_range().
    priv inline fn _prev_kind(self) -> TokenKind {
        var last = self.dyn()->prev_ptr()
        if last == &null {
            return TokenKind::TkEof
        }

        return last->kind
    }

    /// \brief the range of the token just consumed, or _cur_range() when
    ///        there is none (see _prev_kind).
    priv inline fn _prev_range(self) -> SourceRange {
        var last = self.dyn()->prev_ptr()
        if last == &null {
            return self._cur_range()
        }

        return last->range
    }

    pub inline fn is_fatal_decl(self, d: unsafe *Decl) -> bool {
        return self.dyn()->is_fatal<Decl>(d)
    }

    /// Switches on the RESOLVED kind, like check(): a token a macro expanded
    /// carries the expansion's kind, not the identifier's, so reading the raw
    /// kind rejected every name a macro body declared.
    priv inline fn check_is_ident(self) -> bool {
        if self.dyn()->current_ptr() == &null {
            return false
        }

        match self.dyn()->resolve_kind_deep(self.dyn()->current_ptr()) {
            case TokenKind::AtVoid {
                return true
            } case TokenKind::AtBool {
                return true
            } case TokenKind::AtByte {
                return true
            } case TokenKind::AtChar {
                return true
            } case TokenKind::AtUsize {
                return true
            } case TokenKind::AtIsize {
                return true
            } case TokenKind::AtF8 {
                return true
            } case TokenKind::AtF8E4M3 {
                return true
            } case TokenKind::AtF8E5M2 {
                return true
            } case TokenKind::AtBf16 {
                return true
            } case TokenKind::AtF16 {
                return true
            } case TokenKind::AtF32 {
                return true
            } case TokenKind::AtF64 {
                return true
            } case TokenKind::AtF80 {
                return true
            } case TokenKind::AtF128 {
                return true
            } case TokenKind::AtF256 {
                return true
            } case TokenKind::AtF512 {
                return true
            } case TokenKind::AtU8 {
                return true
            } case TokenKind::AtU16 {
                return true
            } case TokenKind::AtU32 {
                return true
            } case TokenKind::AtU64 {
                return true
            } case TokenKind::AtU128 {
                return true
            } case TokenKind::AtU256 {
                return true
            } case TokenKind::AtU512 {
                return true
            } case TokenKind::AtI8 {
                return true
            } case TokenKind::AtI16 {
                return true
            } case TokenKind::AtI32 {
                return true
            } case TokenKind::AtI64 {
                return true
            } case TokenKind::AtI128 {
                return true
            } case TokenKind::AtI256 {
                return true
            } case TokenKind::AtI512 {
                return true
            } case TokenKind::BiFile {
                return true
            } case TokenKind::BiLine {
                return true
            } case TokenKind::BiColumn {
                return true
            } case TokenKind::BiFunction {
                return true
            } case TokenKind::BiModule {
                return true
            } case TokenKind::LitIdentifier {
                return true
            } default {
                return false
            }
        }
    }

    /// \brief true if the resolved token can begin a declaration.
    /// \details mirrors StmtParse::_starts_decl; used both there and here.
    inline fn _starts_decl_kw(self, k: TokenKind) -> bool {
        return k == TokenKind::KwFn
            || k == TokenKind::KwClass
            || k == TokenKind::KwStruct
            || k == TokenKind::KwEnum
            || k == TokenKind::KwInterface
            || k == TokenKind::KwUnion
            || k == TokenKind::KwModule
            || k == TokenKind::KwImport
            || k == TokenKind::KwFfi
            || k == TokenKind::KwExtend
            || k == TokenKind::KwType
            || k == TokenKind::KwMacro
            || k == TokenKind::KwTest
            || k == TokenKind::KwStatic
            || k == TokenKind::KwVar
            || k == TokenKind::KwMutable
            || k == TokenKind::KwConst
            || k == TokenKind::KwEval
            || k == TokenKind::KwPub
            || k == TokenKind::KwPriv
            || k == TokenKind::KwProt
            || k == TokenKind::KwOverride
            || k == TokenKind::KwVirtual
            || k == TokenKind::KwFinal
            // `inline fn f()` is a decl; `inline "c++" { }` is not. Both lead
            // with `inline`, so admit it here and let _dispatch_decl return
            // null for the ffi form - every caller already falls back.
            || k == TokenKind::KwInline
    }

    /// \brief true if the storage keyword under the cursor opens a binding
    ///        rather than an expression.
    ///  Lookahead:  KW ( 'const' | 'static' | 'thread' | 'eval' | 'var'
    ///                 | 'unsafe'? '*'* name '?'? ( ':' | '=' | end ) )
    ///  where `end` is a newline, `;`, `}` or the end of the file.
    ///
    /// \details `thread` and `eval` each front two things: a declaration
    ///          (`thread n: i32 = 0`, `eval N = 4`) and a prefix expression
    ///          (`thread work(&x)`, tether-threading.mdx; `eval f(3)`). Only
    ///          what follows the name separates them: an expression operand
    ///          is never followed by `:`, nor by `=` (that would assign to
    ///          the operand of a spawn), and a spawn of a bare name means
    ///          nothing, so `thread n` alone is the binding -- Sema then
    ///          reports it has neither a type nor an initializer (SC046E), as
    ///          for `static n`, where the expression would pass silently. A
    ///          second binding keyword is always a binding, so
    ///          _parse_storage_head gets to name a bad combination. The guard
    ///          rolls the cursor back unconditionally.
    pub fn _storage_binding_ahead(self) -> bool {
        type ASTTentativeGuard = T::TentativeGuard
        var t = ASTTentativeGuard(self.dyn())

        self.dyn()->advance() // the keyword under test
        if self.dyn()->check(TokenKind::KwConst)
            || self.dyn()->check(TokenKind::KwStatic)
            || self.dyn()->check(TokenKind::KwThread)
            || self.dyn()->check(TokenKind::KwEval)
            || self.dyn()->check(TokenKind::KwVar) {
            return true
        }

        if self.dyn()->check(TokenKind::KwUnsafe) && self.dyn()->check_peek(TokenKind::OpStar) {
            self.dyn()->advance()
        }

        while self.dyn()->check(TokenKind::OpStar) {
            self.dyn()->advance()
        }

        if !self.dyn()->check_is_ident() {
            return false
        }

        self.dyn()->advance() // the name
        if self.dyn()->check(TokenKind::OpQuestion) {
            self.dyn()->advance()
        }

        if self.dyn()->check(TokenKind::OpColon) || self.dyn()->check(TokenKind::OpEqual) {
            return true
        }

        // `thread n` alone: a binding with neither a type nor an initializer,
        // which Sema reports (SC046E) as it does for `static n`. As a spawn
        // of a bare name it would be accepted silently.
        return self.dyn()->is_eof()
            || self.dyn()->check(TokenKind::OpRBrace)
            || self.dyn()->_is_terminator_tok(self.dyn()->current_ptr())
        // guard dtor rolls back unconditionally (never commit)
    }

    /// \brief _starts_decl_kw, plus `thread` when it opens a binding: the
    ///        gate for every place that walks declarations (the index pass,
    ///        a type body's index walk, top-level recovery). `thread` is not
    ///        in _starts_decl_kw itself because `thread work()` is an
    ///        expression and the callers of that predicate do not look ahead.
    pub fn _starts_decl_here(self, k: TokenKind) -> bool {
        if self._starts_decl_kw(k) {
            return true
        }

        return k == TokenKind::KwThread && self._storage_binding_ahead()
    }

    //  Entry point

    /// \brief parses a single declaration.
    ///  Grammar (dispatch):
    ///    visibility? modifiers? ( fn | class | struct | enum | interface
    ///      | union | module | extend | type | macro | test | import | ffi
    ///      | var | const | static | eval )
    ///
    /// \details consumes leading doc comments + visibility into a
    ///          PendingAnnotations buffer, parses the core decl, then stamps
    ///          annotations + visibility onto it. Returns null at EOF or when
    ///          the lead token cannot begin a decl.
    fn parse_decl(self, allow_closure_fallback: bool = false) -> unsafe *Decl {
        if self.dyn()->is_eof() {
            return &null
        }

        var annot: T::PendingAnnotations
        self.dyn()->consume_leading_annotations(&annot)

        if self.dyn()->is_eof() {
            return &null
        }

        var unsafe *d = self._dispatch_decl(allow_closure_fallback)
        if d != &null && !self.is_fatal_decl(d) {
            if !isa<Declarations::VisibilityGroupDecl>(d) {
                self.dyn()->apply_annotations_to_decl(d, &annot)
            }

            // group case: caller owns the annotation-on-group diagnostic,
            // since parse_decl's local annot buffer is empty when the caller
            // (parse / member-body) already consumed the annotations.
        }

        return d
    }

    /// `fn` is a decl iff the token after `fn` (and after an optional generic
    /// param list) is an identifier, `op`, or `self`. Anything else - `(`, `|`,
    /// `||` - is a closure literal. No diagnostics, no allocation, no sync.
    priv fn _fn_is_decl_head(self) -> bool {
        type ASTTentativeGuard = T::TentativeGuard
        var t = ASTTentativeGuard(self.dyn())
        self.dyn()->advance(T::SkipNL::After) // past `fn`
        if self.dyn()->check(TokenKind::OpLess) {
            var gp: kairo::std::StackBuf<unsafe *Declarations::GenericParamDecl, 2>
            self._parse_generic_params(&gp) // allocates; acceptable, discarded
        }

        if self.dyn()->check(TokenKind::LitIdentifier)
            || self.dyn()->check(TokenKind::KwOp)
            || self.dyn()->check(TokenKind::KwSelf) {
            return true
        }

        // `fn f16(c: T)`: a primitive type's name where the function's goes.
        // No closure starts that way, and taking it for one parsed
        // `f16` away and the rest as a parameterless closure, so every use
        // of a parameter was "undeclared". _parse_function reports the name.
        var k = self.dyn()->ig_kind()
        return is_annotation(k)
            && k != TokenKind::AtComment
            && (self.dyn()->ig_peek_kind() == TokenKind::OpLParen
                || self.dyn()->ig_peek_kind() == TokenKind::OpLess)
        // guard dtor rolls back unconditionally (never commit)
    }

    /// \brief routes the current token to its declaration production.
    /// \details visibility and the leading-modifier keywords (override/virtual/
    ///          final/static) are consumed here into a small modifier set that
    ///          is threaded into the function/type productions. Anything not a
    ///          decl lead-in returns null (caller's problem).
    priv fn _dispatch_decl(self, allow_closure_fallback: bool = false) -> unsafe *Decl {
        var cur_ptr = self.dyn()->current_ptr()
        if cur_ptr == &null {
            return &null
        }

        // pub { ... } / priv { ... } / prot { ... } visibility group.
        // consume_leading_annotations leaves the keyword when `{` follows.
        var lead_k = self.dyn()->resolve_kind_deep(cur_ptr)
        if (lead_k == TokenKind::KwPub
            || lead_k == TokenKind::KwPriv
            || lead_k == TokenKind::KwProt)
            && self.dyn()->check_peek(TokenKind::OpLBrace) {
            return self._parse_visibility_group()
        }

        // leading abi/dispatch modifiers (static/virtual/override) and the
        // `final` class/method modifier are collected, then we re-dispatch on
        // the keyword they precede.
        var lead = self._consume_leading_modifiers()

        var k = self.dyn()->resolve_kind_deep(self.dyn()->current_ptr())

        match k {
            case TokenKind::KwFn {
                if !allow_closure_fallback || lead.any {
                    return self._parse_function(unsafe &lead)
                }

                if !self._fn_is_decl_head() {
                    return &null
                }

                return self._parse_function(unsafe &lead) // committed: it IS a decl
            } case TokenKind::KwClass {
                return self._parse_class(unsafe &lead)
            } case TokenKind::KwStruct {
                return self._parse_struct()
            } case TokenKind::KwEnum {
                return self._parse_enum()
            } case TokenKind::KwInterface {
                return self._parse_interface()
            } case TokenKind::KwUnion {
                return self._parse_union()
            } case TokenKind::KwExtend {
                return self._parse_extension()
            } case TokenKind::KwType {
                return self._parse_type_alias()
            } case TokenKind::KwModule {
                return self._parse_module()
            } case TokenKind::KwTest {
                return self._parse_test()
            } case TokenKind::KwMacro {
                return self._parse_macro()
            } case TokenKind::KwImport {
                return self._parse_import()
            } case TokenKind::KwFfi {
                return self._parse_ffi()
            } case TokenKind::KwVar {
                return self._parse_var_decl()
            } case TokenKind::KwConst {
                return self._parse_var_decl()
            } case TokenKind::KwStatic {
                return self._parse_var_decl()
            } case TokenKind::KwThread { // callers saw _storage_binding_ahead
                return self._parse_var_decl()
            } case TokenKind::KwMutable {
                return self._parse_var_decl()
            } case TokenKind::KwEval {
                // `eval if` / `eval for` in a module or class body
                if self.dyn()->check_peek(TokenKind::KwIf)
                    || self.dyn()->check_peek(TokenKind::KwFor) {
                    return self._parse_eval_stmt_decl()
                }

                // `eval {` decl block vs `eval var/const/fn ...`
                if self.dyn()->check_peek(TokenKind::OpLBrace) {
                    return self._parse_eval_block_decl()
                }

                return self._parse_var_decl()
            } default { } // any other kind is not a decl lead-in: falls out to the recovery below.
        }

        // not a decl lead-in. If we consumed modifiers, that's a malformed
        // decl head report and recover; otherwise let the caller decide.
        if lead.any {
            var r = self._cur_range()
            self.dyn()->diag->report(
                DiagID::S063E,
                r.start,
                "expected a declaration after modifiers",
            ).first(r)->emit()
            self._sync_decl(Self::DeclSyncCtx::TopLevel)
            return unsafe (Declarations::FunctionDecl::create_error(self.dyn()->ctx, r) as unsafe *Decl)
        }

        return &null
    }

    /// \struct LeadMods
    /// \brief leading modifiers consumed before the decl keyword.
    struct LeadMods {
        var abi:         Declarations::AbiKind
        var is_final:    bool
        var any:         bool ///< true if any modifier was consumed.
        var fn_mods:     Declarations::FnModifier ///< leading `inline`/`eval`, folded into fd->modifiers.
        var is_const_fn: bool ///< leading `const` before `fn`: FunctionDecl::is_const_fn.
        var const_range: SourceRange ///< that `const`, for the fix-it that removes it.
        var range:       SourceRange
    }

    /// \brief if the next non-newline token is \p kind, consume any newlines in
    ///        front of it and return true; otherwise leave the cursor exactly
    ///        where it was.
    ///
    /// \details a decl head may wrap onto a continuation line -
    ///              struct <P> Foo<P>
    ///                requires is_ptr<P>() { ... }
    ///          - but a newline also *terminates* a bodyless decl, so the
    ///          newlines can only be eaten once we know a continuation keyword
    ///          follows. Peek first, commit second.
    priv fn _peek_past_nl(self, kind: TokenKind) -> bool {
        if self.dyn()->check(kind) {
            return true
        }

        if !self.dyn()->check(TokenKind::TkNewLine) {
            return false
        }

        var save = self.dyn()->c_idx
        self.dyn()->advance(T::SkipNL::Only)
        if self.dyn()->check(kind) {
            return true
        }

        self.dyn()->_restore_cursor(save)
        return false
    }

    /// \brief true if the modifier run starting at the current token leads to a
    ///        `fn` declaration head.
    ///
    /// \details `static`, `inline` and `eval` are each ambiguous on their own:
    ///
    ///            static fn f()      -> abi modifier    | static X: T   -> binding
    ///            inline fn f()      -> fn modifier     | inline "c++"  -> ffi block
    ///            eval fn f()        -> fn modifier     | eval N: u8    -> binding
    ///                                                  | eval { ... }  -> eval block
    ///
    ///          Only a lookahead past the whole modifier run can tell them
    ///          apart, so both `_consume_leading_modifiers` and the type-body
    ///          member dispatch ask this before claiming the keyword. The
    ///          tentative guard rolls the cursor back unconditionally.
    /// \param require_decl_head when true (decl/statement scope) the `fn` must
    ///        also be a decl head, so `eval fn (x) { }` stays a closure
    ///        expression. Type bodies pass false: a `fn` there is always a
    ///        member, and insisting on a well-formed head would push a
    ///        malformed one down the field path for three confused diagnostics
    ///        instead of one good one.
    pub fn _mods_lead_to_fn(self, require_decl_head: bool = true) -> bool {
        type ASTTentativeGuard = T::TentativeGuard
        var t = ASTTentativeGuard(self.dyn())

        while !self.dyn()->is_eof() {
            var k = self.dyn()->resolve_kind_deep(self.dyn()->current_ptr())
            if k == TokenKind::KwStatic
                || k == TokenKind::KwVirtual
                || k == TokenKind::KwOverride
                || k == TokenKind::KwFinal
                || k == TokenKind::KwInline
                || k == TokenKind::KwEval
                || k == TokenKind::KwConst {
                self.dyn()->advance(T::SkipNL::After)
                continue
            }

            if k != TokenKind::KwFn {
                return false
            }

            if !require_decl_head {
                return true
            }

            // A closure literal (`eval fn (x) { }`) is an expression, not a
            // decl: claiming `eval` there would strand the closure in
            // _parse_function. Only a real decl head counts.
            return self._fn_is_decl_head()
        }

        return false
        // guard dtor rolls back unconditionally (never commit)
    }

    /// \brief consumes static/virtual/override/final/inline/eval appearing
    ///        before a decl keyword. These bind to fn/class productions
    ///        downstream.
    ///
    /// \details `virtual`, `override` and `final` are unambiguous leads and are
    ///          always claimed (`final` also fronts a class). `static`,
    ///          `inline` and `eval` are claimed only when a `fn` head follows -
    ///          otherwise they belong to a binding, an ffi block or an eval
    ///          block, each of which owns its own production and needs to see
    ///          its keyword still on the cursor.
    priv fn _consume_leading_modifiers(self, require_decl_head: bool = true) -> Self::LeadMods {
        var m = Self::LeadMods{}
        m.abi         = Declarations::AbiKind::None
        m.is_final    = false
        m.any         = false
        m.fn_mods     = Declarations::FnModifier::None
        m.is_const_fn = false

        var start = self._cur_range()
        m.range = start

        var to_fn = self._mods_lead_to_fn(require_decl_head)

        while true {
            if self.dyn()->check(TokenKind::KwStatic) && to_fn {
                m.abi = Declarations::AbiKind::Static
                m.any = true
                self.dyn()->advance()
                continue
            }

            if self.dyn()->check(TokenKind::KwVirtual) {
                m.abi = Declarations::AbiKind::Virtual
                m.any = true
                self.dyn()->advance()
                continue
            }

            if self.dyn()->check(TokenKind::KwOverride) {
                m.abi = Declarations::AbiKind::Override
                m.any = true
                self.dyn()->advance()
                continue
            }

            if self.dyn()->check(TokenKind::KwFinal) {
                m.is_final = true
                m.any      = true
                self.dyn()->advance()
                continue
            }

            if self.dyn()->check(TokenKind::KwInline) && to_fn {
                m.fn_mods |= Declarations::FnModifier::IsInline
                m.any = true
                self.dyn()->advance()
                continue
            }

            if self.dyn()->check(TokenKind::KwEval) && to_fn {
                m.fn_mods |= Declarations::FnModifier::IsEval
                m.any = true
                self.dyn()->advance()
                continue
            }

            // `const fn`: only a `fn` head after it makes `const` a modifier;
            // `const x = 1` and `const static` stay bindings (to_fn is false).
            if self.dyn()->check(TokenKind::KwConst) && to_fn {
                m.is_const_fn = true
                m.any         = true
                m.const_range = self._cur_range()
                self.dyn()->advance()
                continue
            }

            break
        }

        if m.any {
            m.range = start | self.dyn()->prev().range
        }

        return m
    }

    //  Visibility group   pub { decl* }

    /// \brief parses a visibility group at decl scope.
    ///  Grammar:  ('pub'|'priv'|'prot') '{' decl* '}'
    ///
    /// \details every member's visibility is stamped from the group keyword.
    ///          an explicit visibility keyword on a member inside the group is
    ///          an ERROR the group is an at-a-glance guarantee and local
    ///          overrides destroy it. nesting another group inside is the same
    ///          error by construction (the inner keyword is explicit
    ///          visibility). attributes/doc-comments on the GROUP itself are
    ///          rejected by parse_decl (see annotation check there); members
    ///          carry their own annotations normally.
    priv fn _parse_visibility_group(self) -> unsafe *Decl {
        var start = self._cur_range()

        var vis: u8 = 3 // Public
        if self.dyn()->check(TokenKind::KwPriv) {
            vis = 1
        } else if self.dyn()->check(TokenKind::KwProt) {
            vis = 2
        }

        var vis_kind = (vis as VisibilityKind)

        self.dyn()->advance(T::SkipNL::After) // consume visibility keyword
        self.dyn()->advance(T::SkipNL::After) // consume `{`

        var vg = Declarations::VisibilityGroupDecl::create(self.dyn()->ctx, start, vis)
        var members: kairo::std::StackBuf<unsafe *Decl, 8>

        while !self.dyn()->is_eof() && !self.dyn()->check(TokenKind::OpRBrace) {
            if self.dyn()->check(TokenKind::TkNewLine)
                || self.dyn()->check(TokenKind::OpSemicolon) {
                self.dyn()->advance()
                continue
            }

            var unsafe *d = self.parse_decl()
            if d == &null {
                break
            }

            if self.is_fatal_decl(d) {
                break
            }

            if d->has_visibility() {
                self.dyn()->diag->report(
                    DiagID::S048E,
                    d->visibility_range().start,
                    "explicit visibility is not allowed inside a visibility group",
                ).first(d->visibility_range())->note(
                    DiagCode(DiagID::S048N),
                    d->visibility_range().start,
                    "every member of this group already has the group's visibility; "
                    "move the declaration outside the group to give it different visibility",
                )->emit()
            }

            d->set_visibility(vis_kind, start)

            members.push_back(d)
        }

        if self.dyn()->check(TokenKind::OpRBrace) {
            self.dyn()->advance(T::SkipNL::Before)
        } else {
            self.dyn()->diag->report(
                DiagID::S051E,
                start.start,
                "expected '}' to close visibility group",
            ).first(start)->emit()
        }

        vg->members.from_buf(members.data(), members.size(), self.dyn()->ctx)
        vg->range = start | self.dyn()->prev().range
        return vg
    }

    /// \brief visibility group inside a type body. Same rules as decl scope;
    ///        members land in the SAME fields/methods buffers as ungrouped
    ///        members (sema walks one list), and the group node goes into
    ///        owner->dc_decls for printing fidelity, holding member pointers.
    priv fn _parse_member_vis_group(
        self,
        owner:              unsafe *DeclContext,
        owner_name:         Token,
        @inout fields_out:  kairo::std::StackBuf<unsafe *Declarations::FieldDecl, 8>,
        @inout methods_out: kairo::std::StackBuf<unsafe *Declarations::FunctionDecl, 8>,
        allow_methods:      bool,
        field_idx:          unsafe *u32,
    ) {
        var start = self._cur_range()

        var vis: u8 = 3
        if self.dyn()->check(TokenKind::KwPriv) {
            vis = 1
        } else if self.dyn()->check(TokenKind::KwProt) {
            vis = 2
        }

        var vis_kind = (vis as VisibilityKind)

        self.dyn()->advance(T::SkipNL::After) // visibility keyword
        self.dyn()->advance(T::SkipNL::After) // `{`

        var vg = Declarations::VisibilityGroupDecl::create(self.dyn()->ctx, start, vis)
        var members: kairo::std::StackBuf<unsafe *Decl, 8>

        while !self.dyn()->is_eof() && !self.dyn()->check(TokenKind::OpRBrace) {
            if self.dyn()->check(TokenKind::TkNewLine)
                || self.dyn()->check(TokenKind::OpSemicolon) {
                self.dyn()->advance()
                continue
            }

            var m_annot: T::PendingAnnotations
            self.dyn()->consume_leading_annotations(unsafe &m_annot)
            if self.dyn()->check(TokenKind::OpRBrace) {
                break
            }

            // explicit visibility inside the group: error, then proceed.
            var m_has_vis = m_annot.visibility != VisibilityKind::None
            if m_has_vis {
                self.dyn()->diag->report(
                    DiagID::S048E,
                    m_annot.vis_range.start,
                    "explicit visibility is not allowed inside a visibility group",
                ).first(m_annot.vis_range)->note(
                    DiagCode(DiagID::S048N),
                    start.start,
                    "this visibility group already fixes the visibility of every member; "
                    "move the declaration out of the group to give it different visibility",
                )->child_first(start)->emit()
            }

            var k = self.dyn()->resolve_kind_deep(self.dyn()->current_ptr())

            var is_method_lead = self._mods_lead_to_fn(false)

            if is_method_lead {
                var mr   = self._cur_range()
                var lead = self._consume_leading_modifiers(false)
                if !self.dyn()->check(TokenKind::KwFn) {
                    self._sync_decl_progress(Self::DeclSyncCtx::TypeBody)
                    continue
                }

                var unsafe *m = self._parse_function(unsafe &lead)
                if m != &null && isa<Declarations::FunctionDecl>(m) {
                    var unsafe *fm = cast<Declarations::FunctionDecl>(m)
                    // struct/union bodies: constructors and operators only.
                    if !allow_methods && !fm->is_operator && !self._is_ctor_of(fm, owner_name) {
                        self.dyn()->diag->report(DiagID::S048E, mr.start,
                            "a struct or union body cannot contain a named function; "
                            "only fields, nested types, constructors, and operator "
                            "overloads are permitted"
                        ).first(mr)
                         // No location: same span as the error, so a second
                         // caret is noise. Plain text reads better.
                         .note(DiagCode(DiagID::S048N),
                            "move it into an 'extend' block on this type, or declare "
                            "the type as a 'class' if it needs methods"
                         )->emit()
                        continue
                    }

                    self.dyn()->apply_annotations_to_decl(
                        unsafe (fm as unsafe *Decl),
                        unsafe &m_annot,
                    )

                    fm->set_visibility(vis_kind, start)
                    methods_out.push_back(fm)
                    members.push_back(unsafe (fm as unsafe *Decl))
                }

                continue
            }

            var is_field_lead = k == TokenKind::KwVar
                || k == TokenKind::KwConst
                || k == TokenKind::KwStatic
                || k == TokenKind::KwEval
                || k == TokenKind::KwThread
                || k == TokenKind::KwMutable

            if is_field_lead {
                var unsafe *f = self._parse_field(*field_idx)
                if !is_recovery(unsafe (f as unsafe *Decl)) {
                    self.dyn()->apply_annotations_to_decl(
                        unsafe (f as unsafe *Decl),
                        unsafe &m_annot,
                    )

                    f->set_visibility(vis_kind, start)
                    fields_out.push_back(f)
                    members.push_back(unsafe (f as unsafe *Decl))
                    *field_idx += 1
                } else {
                    self._sync_decl_progress(Self::DeclSyncCtx::TypeBody)
                }

                continue
            }

            // nested types etc.
            var unsafe *nested = self._dispatch_decl()
            if nested != &null && !self.is_fatal_decl(nested) {
                self.dyn()->apply_annotations_to_decl(nested, unsafe &m_annot)
                nested->set_visibility(vis_kind, start)
                owner->add_decl(nested)
                members.push_back(nested)
                continue
            }

            self._sync_decl(Self::DeclSyncCtx::TypeBody)
        }

        if self.dyn()->check(TokenKind::OpRBrace) {
            self.dyn()->advance(T::SkipNL::Before)
        } else {
            self.dyn()->diag->report(
                DiagID::S051E,
                start.start,
                "expected '}' to close visibility group",
            ).first(start)->emit()
        }

        vg->members.from_buf(members.data(), members.size(), self.dyn()->ctx)
        vg->range = start | self.dyn()->prev().range
        owner->add_decl(unsafe (vg as unsafe *Decl))
    }

    //  Generic parameter list  <T, T impl Foo, const N: i32, ...T>

    /// \brief parses the leading generic/specialization introducer at a decl
    ///        head: either `<T, ...>` (type params) or `<>` (specialization
    ///        marker). See issue #68.
    ///
    /// \details Precondition: caller has NOT yet checked for `<`. Handles the
    ///          three head forms:
    ///            (a) no `<`            -> params empty, sets *intro = None
    ///            (b) `<>` empty        -> params empty, sets *intro = Explicit
    ///                                     (the definitive kind primary vs
    ///                                     explicit vs partial is decided by
    ///                                     the post-name pattern; `<>` alone
    ///                                     only tells us "this is specialized")
    ///            (c) `<T, ...>`        -> fills params, sets *intro = None
    ///                                     (a `<T>` primary is a plain generic;
    ///                                     Primary classification for the
    ///                                     `<> Name<T>` form is set later)
    ///
    ///          Unlike a bare `_parse_generic_params`, empty `<>` here is NOT
    ///          an error (S049E) it is the specialization introducer. This
    ///          function is the single decl-position entry point; the old
    ///          `_parse_generic_params` remains for contexts where empty `<>`
    ///          is genuinely malformed.
    ///
    /// \returns true if recovery was entered while parsing type params.
    fn _parse_generic_or_spec_intro(
        self,
        out:   unsafe *kairo::std::StackBuf<unsafe *Declarations::GenericParamDecl, 2>,
        intro: *Declarations::SpecKind,
    ) -> bool {
        *intro = Declarations::SpecKind::None

        if !self.dyn()->check(TokenKind::OpLess) {
            return false
        }

        // Peek for the empty `<>` specialization marker. `<>` is lexed as two
        // adjacent tokens (OpLess, OpGreater); there is no fused diamond token.
        if self.dyn()->check_peek(TokenKind::OpGreater) {
            self.dyn()->advance_raw()                 // consume `<`
            self.dyn()->advance_raw()                 // consume `>`
            *intro = Declarations::SpecKind::Explicit // provisional; refined post-name
            return false
        }

        // Ordinary `<T, ...>` type-parameter list.
        return self._parse_generic_params(&*out)
    }

    /// \brief parses the post-name specialization argument pattern
    ///        (`sum<i32>`, `Box<[T]>`, `Box<T>`) into `out` as a list of types.
    ///
    /// \details Precondition: current token is `<` immediately after the decl
    ///          name, and the head carried a `<>` introducer (so we are in a
    ///          specialization). Each argument is a full type parsed via
    ///          `parse_type(gen_arg=true)`; a type variable (`T`), a concrete
    ///          type (`i32`), or a structured pattern (`[T]`) are all just
    ///          types here classification into Primary/Explicit/Partial is
    ///          the caller's job based on whether the args are bare type vars.
    ///
    /// \returns true on clean close, false on recovery.
    fn _parse_spec_args(self, @inout out: kairo::std::StackBuf<unsafe *Type, 4>) -> bool {
        if !self.dyn()->check(TokenKind::OpLess) {
            return false
        }

        self.dyn()->advance(T::SkipNL::After) // consume `<`
        self.dyn()->nl_push()

        self.dyn()->forgive_close()

        // `<>` with no args after a name is not a valid specialization pattern.
        if self.dyn()->check(TokenKind::OpGreater) {
            self.dyn()->diag->report(
                DiagID::S049E,
                self.dyn()->prev().range.start,
                "specialization argument list cannot be empty",
            ).first(self.dyn()->prev().range)->emit()
            self.dyn()->nl_pop()
            self.dyn()->advance_raw()
            return false
        }

        while !self.dyn()->is_eof() {
            var ty = self.dyn()->parse_type(false, false, true) // gen_arg = true
            if ty == &null || is_recovery(ty) {
                self._sync_decl_progress(Self::DeclSyncCtx::Generics)
                if self.dyn()->pay_close() {
                    self.dyn()->nl_pop()
                    return false
                }

                if self.dyn()->check(TokenKind::OpGreater) {
                    self.dyn()->nl_pop()
                    self.dyn()->advance_raw()
                    return false
                }

                self.dyn()->nl_pop()
                return false
            }

            out.push_back(ty)

            // A nested `>>` may have been split, leaving us owing one `>`.
            if self.dyn()->pay_close() {
                self.dyn()->nl_pop()
                return true
            }

            if self.dyn()->check(TokenKind::OpComma) {
                self.dyn()->advance(T::SkipNL::After)
                if self.dyn()->check(TokenKind::OpGreater) {
                    break
                }

                if self.dyn()->check(TokenKind::OpGreaterGreater) {
                    break
                }

                continue
            }

            break
        }

        if self.dyn()->check(TokenKind::OpGreater) {
            self.dyn()->nl_pop()
            self.dyn()->advance_raw()
            return true
        }

        if self.dyn()->check(TokenKind::OpGreaterGreater) {
            self.dyn()->owe_close()
            self.dyn()->nl_pop()
            self.dyn()->advance_raw()
            return true
        }

        self.dyn()->diag->report(
            DiagID::S049E,
            self._cur_range().start,
            "expected '>' to close specialization arguments",
        ).first(self._cur_range())->emit()
        self.dyn()->nl_pop()
        return false
    }

    /// \brief coarse *syntactic* classification of a specialization from its
    ///        post-name argument pattern. See issue #68.
    ///
    /// \details The parser can only decide what is decidable from syntax alone:
    ///
    ///            all args are single simple identifiers (`Box<T>`, `Pair<A,B>`)
    ///              -> Primary  (candidate every arg *could* be a type var;
    ///                           sema confirms against the primary's params. A
    ///                           `Box<i32>` is syntactically identical to
    ///                           `Box<T>` at this stage one simple ident
    ///                           so both land here and sema splits Primary vs
    ///                           Explicit by checking whether the ident names a
    ///                           declared type.)
    ///
    ///            any arg is a *structured* type (`[T]`, `*T`, `(A, B)`, a path
    ///            with its own generic args like `Vec<T>`), AND the head bound
    ///            type parameters that the pattern can refer to
    ///              -> Partial  (`<P> Box<*P>`: `P` is free, so this is a
    ///                           pattern. `fn` rejects Partial - see below.)
    ///
    ///          Structure alone does NOT make a specialization partial. What
    ///          makes it partial is a free type variable in the pattern, and a
    ///          `<>` head binds none - so `<> Box<*i32>` is a *full*
    ///          specialization that merely happens to name a structured type.
    ///          This mirrors C++, which rejects `template <class T> bool f<T*>()`
    ///          as a function-template partial specialization but accepts
    ///          `template <> bool f<int*>()`. Collapsing the two would reject
    ///          the legal one.
    ///
    ///          The Primary/Explicit split for the all-simple-idents case is
    ///          intentionally left to sema: it is a name-resolution fact (does
    ///          the ident resolve to a type variable of the primary, or to a
    ///          concrete type?), not a syntactic one.
    ///
    /// \param head_has_params true when the decl head bound type parameters
    ///        (`<P> Name<...>`); false for the `<> Name<...>` marker.
    fn _classify_spec(self,
                      @inout spec_args: kairo::std::StackBuf<unsafe *Type, 4>,
                      head_has_params:  bool) -> Declarations::SpecKind {
        if spec_args.is_empty() {
            return Declarations::SpecKind::Explicit
        }

        // `<>` binds nothing, so no argument can be a pattern variable: this is
        // a full specialization regardless of how structured the args are.
        if !head_has_params {
            return Declarations::SpecKind::Explicit
        }

        for var i: usize = 0; i < ((spec_args.size()) as usize); ++i {
            if !self._is_simple_ident_type((spec_args)[(i as u32)]) {
                return Declarations::SpecKind::Partial // free var in a structured pattern
            }
        }

        return Declarations::SpecKind::Primary // all simple idents; sema refines vs Explicit
    }

    /// \brief _classify_spec for a RECORD, which can say more: the head's own
    ///        parameter names are known here, so an all-simple-idents
    ///        pattern is the primary form only when it is exactly those
    ///        parameters, in order (`<T> Box<T>`, `<A, B> Pair<A, B>`).
    ///        Anything else -- a name the head does not bind (`<X> Pair<X,
    ///        i32>`), a repeat or a reordering (`<A> Pair<A, A>`) -- is a
    ///        pattern over the head's variables: Partial. Left as Primary it
    ///        was a second primary to N, a redefinition of the first.
    ///        Functions keep _classify_spec: a partial function spec is an
    ///        error, and widening what lands there would change which
    ///        function forms are rejected.
    fn _classify_record_spec(
        self,
        spec_args: unsafe *kairo::std::StackBuf<unsafe *Type, 4>,
        gparams:   unsafe *kairo::std::StackBuf<unsafe *Declarations::GenericParamDecl, 2>,
    ) -> Declarations::SpecKind {
        var k = self._classify_spec(&*spec_args, !gparams->is_empty())
        if k != Declarations::SpecKind::Primary {
            return k
        }

        if spec_args->size() != gparams->size() {
            return Declarations::SpecKind::Partial
        }

        for var i: usize = 0; i < ((spec_args->size()) as usize); ++i {
            var unsafe *ct  = cast<ChainType>((*spec_args)[(i as u32)])
            var unsafe *seg = ct->segments.get(0)
            if seg == &null || seg->name == &null {
                return k
            }

            var        arg = self.dyn()->ctx->get_spelling(seg->name->name)
            var unsafe *gp = (*gparams)[(i as u32)]
            if gp == &null {
                return k
            }

            if arg != self.dyn()->ctx->get_spelling(gp->name) {
                return Declarations::SpecKind::Partial
            }
        }

        return k
    }

    /// \brief true if `ty` is a single-segment `ChainType` naming a bare
    ///        identifier with no generic args of its own (`T`, `i32`, `Foo`).
    ///        Structured types (`[T]`, `*T`, `Vec<T>`, `A::B`) return false.
    fn _is_simple_ident_type(self, ty: unsafe *Type) -> bool {
        if ty == &null {
            return false
        }

        if !isa<ChainType>(ty) {
            return false
        }

        return cast<ChainType>(ty)->is_simple() // single unqualified name, no args
    }

    /// \brief parses an optional generic parameter list into `out`.
    ///  Grammar:  '<' generic_param (',' generic_param)* '>'
    ///    generic_param := '...'? identifier (':' kind_bound)?
    ///    kind_bound    := 'class' | 'struct' | 'enum' | 'union' | 'type'
    ///                     (('impl'|'derives') 'virtual'? vis? type)*
    ///                     ('=' type)?
    ///                   | 'const' identifier ':' type ('=' type)?
    ///
    /// \details precondition: current token is `<` (caller checked). On a
    ///          malformed list, recovers to `>` and returns what parsed.
    fn _parse_generic_params(
        self,
        @inout out: kairo::std::StackBuf<unsafe *Declarations::GenericParamDecl, 2>,
    ) -> bool {
        if !self.dyn()->check(TokenKind::OpLess) {
            return false
        }

        var open = self._cur_range()
        self.dyn()->advance(T::SkipNL::After) // consume `<`
        self.dyn()->nl_push()                 // suppress newlines inside `< >`

        // A nested generic in a *prior* sibling could have left us a pending
        // close-angle, but at the param-list opener that can't have happened
        // yet. Still, clear it defensively so a stale flag from an earlier
        // recovered parse can't leak in.
        self.dyn()->forgive_close()

        if self.dyn()->check(TokenKind::OpGreater) {
            self.dyn()->diag->report(
                DiagID::S049E,
                open.start,
                "empty generic parameter list is not allowed",
            ).first(open)->emit()
            self.dyn()->nl_pop()
            self.dyn()->advance_raw() // consume `>`
            return false
        }

        var idx: u32 = 0
        while !self.dyn()->is_eof() {
            var unsafe *gp = self._parse_one_generic_param(idx)
            if gp == &null {
                self._sync_decl_progress(Self::DeclSyncCtx::Generics)
                // honor a pending close-angle during recovery too
                if self.dyn()->pay_close() {
                    self.dyn()->nl_pop()
                    return false
                }

                if self.dyn()->check(TokenKind::OpGreater) {
                    self.dyn()->nl_pop()
                    self.dyn()->advance_raw()
                    return false
                }

                self.dyn()->nl_pop()
                return false
            }

            out.push_back(gp)
            ++idx

            // A bound type on this param (`T: Vec<U>`) may have consumed a
            // `>>` and left us owing one `>`. That closes THIS list.
            if self.dyn()->pay_close() {
                self.dyn()->nl_pop()
                return true
            }

            if self.dyn()->check(TokenKind::OpComma) {
                self.dyn()->advance(T::SkipNL::After)
                // trailing comma before either closer
                if self.dyn()->check(TokenKind::OpGreater) {
                    break
                }

                if self.dyn()->check(TokenKind::OpGreaterGreater) {
                    break
                }

                continue
            }

            break
        }

        // single `>` closes the list cleanly
        if self.dyn()->check(TokenKind::OpGreater) {
            self.dyn()->nl_pop()
            self.dyn()->advance_raw()
            return true
        }

        // `>>` here means a nested generic did NOT consume it (e.g. the list
        // itself nests: `<T<U>>` is not valid param syntax, but a trailing
        // comma path can land us on `>>`). Consume one level, leave the other
        // for an enclosing list via the pending flag mirroring TypeParse.
        if self.dyn()->check(TokenKind::OpGreaterGreater) {
            self.dyn()->owe_close()
            self.dyn()->nl_pop()
            self.dyn()->advance_raw()
            return true
        }

        self.dyn()->diag->report(
            DiagID::S049E,
            open.start,
            "expected '>' to close generic parameter list",
        ).first(open)->emit()
        self._sync_decl(Self::DeclSyncCtx::Generics)
        self.dyn()->nl_pop()
        return false
    }

    /// \brief parses a single generic parameter.
    priv fn _parse_one_generic_param(self, idx: u32) -> unsafe *Declarations::GenericParamDecl {
        self.dyn()->_reject_mode_binding() // `<@move T>`: a generic param is not passed.
        var start = self._cur_range()

        // value parameter: `eval N: T` (Compiler/Spec/Eval.md#generic-value-parameters). `const N: T` is the old
        // spelling: an error with a fix-it to `eval`, parsed as the same
        // parameter so nothing after it cascades.
        if self.dyn()->check(TokenKind::KwEval) || self.dyn()->check(TokenKind::KwConst) {
            var kw = self.dyn()->current()
            if kw.kind == TokenKind::KwConst {
                var b = self.dyn()->diag->report(
                    DiagID::S082E,
                    kw.range.start,
                    "a generic value parameter is written 'eval N: T', not 'const N: T'; its value is a compile-time constant",
                )

                b.first(kw.range)
                b.fix(kw.range, "eval", "write 'eval'")
                b.emit()
            }

            self.dyn()->advance(T::SkipNL::After) // consume `eval` / `const`
            if !self.dyn()->check_is_ident() {
                self.dyn()->diag->report(
                    DiagID::S049E,
                    start.start,
                    "expected parameter name after 'eval' in generic parameter list",
                ).first(start)->emit()
                return &null
            }

            var nm = self.dyn()->current()
            self.dyn()->advance()
            if !self.dyn()->check(TokenKind::OpColon) {
                self.dyn()->diag->report(
                    DiagID::S049E,
                    start.start,
                    "expected ':' and a type for a generic value parameter",
                ).first(start)->emit()
                return &null
            }

            self.dyn()->advance(T::SkipNL::After) // consume `:`
            var vty = self.dyn()->parse_type()
            if vty == &null || is_recovery(vty) {
                return &null
            }

            var gp = Declarations::GenericParamDecl::create(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
                nm,
                idx,
            )

            gp->is_const_param = true
            gp->value_type     = vty
            self._maybe_parse_generic_default(gp)
            return gp
        }

        // variadic pack: `...T`
        var is_pack = false
        if self.dyn()->check(TokenKind::OpEllipsis) {
            is_pack = true
            self.dyn()->advance() // consume `...`
        }

        if !self.dyn()->check_is_ident() {
            self.dyn()->diag->report(
                DiagID::S049E,
                start.start,
                "expected type parameter name in generic parameter list",
            ).first(start)->emit()
            return &null
        }

        var name = self.dyn()->current()
        self.dyn()->advance()

        var gp = Declarations::GenericParamDecl::create(
            self.dyn()->ctx,
            start | self.dyn()->prev().range,
            name,
            idx,
        )

        gp->is_pack = is_pack

        // optional kind bound: `: class|struct|enum|union`
        if self.dyn()->check(TokenKind::OpColon) {
            var colon = self.dyn()->current().range
            self.dyn()->advance(T::SkipNL::After) // consume `:`
            gp->kind_bound       = self._parse_kind_bound(start)
            gp->kind_bound_range = colon | self.dyn()->prev().range
        }

        // optional impl/derives bounds. Both may appear (in either order) and
        // each is routed to its own list so the impl (structural) vs derives
        // (nominal, vtable) distinction survives into sema.
        if self.dyn()->check(TokenKind::KwImpl) || self.dyn()->check(TokenKind::KwDerives) {
            var impl_edges:    kairo::std::StackBuf<Declarations::InheritEdge, 4>
            var derives_edges: kairo::std::StackBuf<Declarations::InheritEdge, 4>
            self._parse_param_bounds(&impl_edges, &derives_edges)
            gp->impl_bounds.from_buf(impl_edges.data(), impl_edges.size(), self.dyn()->ctx)
            gp->derives_bounds.from_buf(derives_edges.data(), derives_edges.size(), self.dyn()->ctx)
        }

        self._maybe_parse_generic_default(gp)
        gp->range = start | self.dyn()->prev().range
        return gp
    }

    /// `: type` is not a kind the way `: class` is -- it is the DUCK bound,
    /// the opt-in to C++ template semantics, where the parameter admits any
    /// member access and every one of them is checked at instantiation
    /// instead of here. It is spelled in this slot because it occupies the
    /// same syntactic position and, like the kind bounds, describes the
    /// parameter SLOT rather than conjoining a constraint.
    priv fn _parse_kind_bound(self, ctx_range: SourceRange) -> Declarations::GenericParamKindBound {
        if self.dyn()->check(TokenKind::KwClass) {
            self.dyn()->advance()
            return Declarations::GenericParamKindBound::Class
        }

        if self.dyn()->check(TokenKind::KwStruct) {
            self.dyn()->advance()
            return Declarations::GenericParamKindBound::Struct
        }

        if self.dyn()->check(TokenKind::KwEnum) {
            self.dyn()->advance()
            return Declarations::GenericParamKindBound::Enum
        }

        if self.dyn()->check(TokenKind::KwUnion) {
            self.dyn()->advance()
            return Declarations::GenericParamKindBound::Union
        }

        if self.dyn()->check(TokenKind::KwType) {
            self.dyn()->advance()
            return Declarations::GenericParamKindBound::Duck
        }

        self.dyn()->diag->report(
            DiagID::S049E,
            ctx_range.start,
            "expected 'class', 'struct', 'enum', 'union', or 'type' as a kind bound after ':'",
        ).first(ctx_range)->emit()
        return Declarations::GenericParamKindBound::Any
    }

    /// \brief parses one or more impl/derives bound clauses after a generic
    ///        param, routing each edge to the matching list.
    ///  Grammar:  (('impl'|'derives') 'virtual'? visibility? type)+  - each
    ///  clause is keyword-led. A bare `,` belongs to the generic param list, not
    ///  the bound list, so we only continue on another impl/derives keyword.
    ///  `impl` edges go to \p impl_out, `derives` edges to \p derives_out; the
    ///  keyword that introduced the clause is what decides, preserving the
    ///  structural-vs-nominal distinction.
    /// \brief parse_type() returns null without a diagnostic at EOF (`class D
    ///        derives`, `fn <T impl`); a recovery node or any other null has
    ///        already been reported, so only the silent case speaks here.
    ///        Without it a truncated heritage clause was accepted cleanly.
    priv fn _report_missing_edge_type(self, bty: unsafe *Type, const kw: string) {
        if bty != &null || !self.dyn()->is_eof() {
            return
        }

        var r = self._cur_range()
        self.dyn()->diag->report(DiagID::S053E, r.start, f"expected a type after '{kw}'").first(
            r,
        )->emit()
    }

    priv fn _parse_param_bounds(
        self,
        @inout impl_out:    kairo::std::StackBuf<Declarations::InheritEdge, 4>,
        @inout derives_out: kairo::std::StackBuf<Declarations::InheritEdge, 4>,
    ) {
        while true {
            var is_derives = self.dyn()->check(TokenKind::KwDerives)
            var is_impl    = self.dyn()->check(TokenKind::KwImpl)
            if !is_derives && !is_impl {
                break
            }

            self.dyn()->advance(T::SkipNL::After) // consume `impl` / `derives`

            var e_start = self._cur_range()
            var edge    = Declarations::InheritEdge{}
            edge.visibility = 0
            edge.is_virtual = false

            if self.dyn()->check(TokenKind::KwVirtual) {
                edge.is_virtual = true
                self.dyn()->advance()
            }

            if self.dyn()->check(TokenKind::KwPub) {
                edge.visibility = 3
                self.dyn()->advance()
            } else if self.dyn()->check(TokenKind::KwProt) {
                edge.visibility = 2
                self.dyn()->advance()
            } else if self.dyn()->check(TokenKind::KwPriv) {
                edge.visibility = 1
                self.dyn()->advance()
            }

            var bty = self.dyn()->parse_type()
            if bty == &null || is_recovery(bty) {
                var bkw: string = if (is_derives) => ("derives") else => "impl"
                self._report_missing_edge_type(bty, bkw)
                break
            }

            edge.base  = bty
            edge.range = e_start | self.dyn()->prev().range

            if is_derives {
                derives_out.push_back(edge)
            } else {
                impl_out.push_back(edge)
            }

            // another bound only if another impl/derives follows (a bare `,`
            // belongs to the generic param list, not the bound list).
            if self.dyn()->check(TokenKind::KwImpl) || self.dyn()->check(TokenKind::KwDerives) {
                continue
            }

            break
        }
    }

    priv fn _maybe_parse_generic_default(self, gp: *Declarations::GenericParamDecl) {
        if self.dyn()->check(TokenKind::OpEqual) {
            self.dyn()->advance(T::SkipNL::After) // consume `=`
            var dty = self.dyn()->parse_type()
            if dty != &null && !is_recovery(dty) {
                gp->default_type = dty
            }
        }
    }

    //  Function declaration

    /// \returns false if validation failed
    pub fn _parse_and_validate_op_spelling(self,
                                           out: unsafe *kairo::std::StackBuf<Token, 2>) -> bool {
        // `op delete`, the destructor's pre-0.2.0 spelling: keyed as `op
        // finally` (a token minted with that spelling, so OperatorFacts and
        // CXXSpell read "finally" off it). The callers report the spelling.
        if self.dyn()->check(TokenKind::KwDelete) {
            out->push_back(
                self.dyn()->ctx->make_token(
                    self.dyn()->current_ptr()->range,
                    TokenKind::KwFinally,
                    "finally",
                ),
            )

            self.dyn()->advance(T::SkipNL::After)
            return true
        }

        // so we have upto 2 max 1 is single ops - anything else thats not a opener after is jut wrong
        var cur_tok = self.dyn()->current()
        out->push_back(cur_tok)

        if self.dyn()->current() == TokenKind::OpLParen {
            self.dyn()->advance()
            if self.dyn()->current() == TokenKind::OpRParen {
                out->push_back(self.dyn()->current())
                self.dyn()->advance(T::SkipNL::After)
                return true
            }

            self.dyn()->report_tok(
                DiagID::S045E,
                self.dyn()->current_ptr(),
                "expected ')' to close the matching opener",
            )

            return false
        }

        if self.dyn()->current() == TokenKind::OpLSquare {
            self.dyn()->advance()
            if self.dyn()->current() == TokenKind::OpRSquare {
                out->push_back(self.dyn()->current())
                self.dyn()->advance(T::SkipNL::After)
                return true
            }

            self.dyn()->report_tok(
                DiagID::S045E,
                self.dyn()->current_ptr(),
                "expected ']' to close the matching opener",
            )

            return false
        }

        if self.dyn()->current() == TokenKind::LitIdentifier {
            // an `l`/`r` prefix must be followed by `++` or `--`; anything
            // else is invalid. a bare identifier here is not a valid operator.
            var spelling = self.dyn()->ctx->get_spelling(self.dyn()->current())
            var is_lr    = spelling == "l" || spelling == "r"

            if !is_lr {
                self.dyn()->report_tok(
                    DiagID::S045E,
                    self.dyn()->current_ptr(),
                    "given operator is not valid to overload",
                )

                self.dyn()->advance(T::SkipNL::After)
                return false
            }

            // the `l`/`r` prefix is already out[0] (pushed above as cur_tok);
            // pushing it again made `op r++` three tokens, `r r ++`, which no
            // size()==2 fixity test matches and SemaDump prints as `rr++`.
            self.dyn()->advance()

            // must be `++` or `--`
            if self.dyn()->current() != TokenKind::OpPlusPlus
                && self.dyn()->current() != TokenKind::OpMinusMinus {
                self.dyn()->report_tok(
                    DiagID::S045E,
                    self.dyn()->current_ptr(),
                    "l or r prefix is only valid for '++' and '--' op's",
                )

                return false
            }

            out->push_back(self.dyn()->current()) // the `++` / `--`
            self.dyn()->advance(T::SkipNL::After)
            return true
        }

        match self.dyn()->ig_kind() {
            // arithmetic
            case TokenKind::OpPlus,           // +
                 TokenKind::OpMinus,          // -
                 TokenKind::OpStar,           // *
                 TokenKind::OpSlash,          // /
                 TokenKind::OpPercent,        // %
                 TokenKind::OpCaretCaret,     // ^^
                 TokenKind::OpLess,           // <
                 TokenKind::OpGreater,        // >
                 TokenKind::OpLessLess,       // "<<"
                 TokenKind::OpGreaterGreater, // ">>"
                 // bitwise
                 TokenKind::OpCaret, // ^
                 TokenKind::OpPipe,  // |
                 TokenKind::OpAmp,   // &
                 TokenKind::OpTilde, // ~
                 // boolean comparison
                 TokenKind::OpEqualEqual,       // "=="
                 TokenKind::OpExclaimEqual,     // "!="
                 TokenKind::OpLessEqualGreater, // "<=>"
                 TokenKind::OpEqualEqualEqual,  // "==="
                 TokenKind::OpAmpAmp,           // "&&"
                 TokenKind::OpPipePipe,         // "||"
                 TokenKind::OpLessEqual,        // "<="
                 TokenKind::OpGreaterEqual,     // ">="
                 // inc / dec
                 TokenKind::OpPlusPlus,   // ++
                 TokenKind::OpMinusMinus, // --
                 // assignment. Compound assignment is overloadable (one of each
                 // pair; the other is derived); `=` is NOT, but it parses here so
                 // OperatorSignatureCheck rejects it with the reason, the same as
                 // `===`, rather than a bare "not valid to overload".
                 TokenKind::OpEqual,               // =
                 TokenKind::OpPlusEqual,           // +=
                 TokenKind::OpMinusEqual,          // -=
                 TokenKind::OpStarEqual,           // *=
                 TokenKind::OpSlashEqual,          // /=
                 TokenKind::OpPercentEqual,        // %=
                 TokenKind::OpAmpEqual,            // &=
                 TokenKind::OpPipeEqual,           // |=
                 TokenKind::OpCaretEqual,          // ^=
                 TokenKind::OpLessLessEqual,       // <<=
                 TokenKind::OpGreaterGreaterEqual, // >>=
                 TokenKind::OpArrow, // ->
                 TokenKind::KwIn, // in
                 TokenKind::KwAs, // as
                 TokenKind::KwAwait,  // await
                 TokenKind::KwSpawn,  // spawn
                 TokenKind::KwThread, // thread
                 TokenKind::KwFinally, // finally: the destructor
                 TokenKind::KwYield,  // yield
                 // `fn op panic (const self) -> string`: an error type's message
                 // (Compiler/Spec/Panic.md#error-types). Optional; its signature is checked later.
                 TokenKind::KwPanic,  // panic
                 // nullability and boolean
                 TokenKind::OpQuestion { // ?
                self.dyn()->advance(T::SkipNL::After)
                return true
            } default {
                self.dyn()->report_tok(
                    DiagID::S045E,
                    self.dyn()->current_ptr(),
                    "given operator is not valid to overload",
                )

                self.dyn()->advance(T::SkipNL::After)
                return false
            }
        }
    }


    /// \brief parses a function/method/operator declaration.
    ///  Grammar:  'fn' generics? (identifier | 'op' operator | qualified-name)
    ///            '(' params? ')' fn_mods? ('->' return_type)? requires? body
    ///    body := block | '=' expr | '=' ('default'|'delete'|'virtual') | <none>
    ///
    /// \details precondition: current token is `fn`. `lead` carries any
    ///          static/virtual/override/final consumed before `fn`.
    priv fn _parse_function(self, lead: unsafe *Self::LeadMods) -> unsafe *Decl {
        var start = if (lead->any) => (lead->range) else => self._cur_range()

        if !self.dyn()->enter_depth() {
            return Declarations::FunctionDecl::create_error(self.dyn()->ctx, start)
        }

        self.dyn()->advance(T::SkipNL::After) // consume `fn`

        // capture the enclosing context *before* the function opens its own
        // scope: it tells us whether a `self` receiver is legal here.
        var enclosing_dc  = self.dyn()->scope.current_dc()
        var in_type_scope = enclosing_dc != &null && enclosing_dc->is_type_scope()

        var fd: *Declarations::FunctionDecl = Declarations::FunctionDecl::create(
            self.dyn()->ctx,
            start,
            Token(),
            enclosing_dc,
        )

        fd->abi = lead->abi
        if lead->is_final {
            fd->modifiers |= Declarations::FnModifier::IsFinal
        }

        // leading `inline` / `eval` land in the same bitset as their trailing
        // spellings (`fn f() inline`), so downstream sees one form.
        fd->modifiers |= lead->fn_mods
        fd->is_const_fn = lead->is_const_fn && !in_type_scope
        if fd->is_const_fn {
            fd->purity_at = lead->const_range
        }

        if lead->is_const_fn && self.dyn()->mode == T::ParseMode::Full {
            // A const function is spelled after its parameters, where the
            // other specifiers go: `fn f(x: f64) const -> f64`. A leading
            // `const` reads as a binding (`const x = 1`). Still parsed as
            // const, so nothing after it cascades. On a method neither
            // spelling exists: `const self` is its promise.
            var cr = lead->const_range
            var b = self.dyn()->diag->report(DiagID::S047E, cr.start,
                (if (in_type_scope) => ("a method cannot be const; 'const self' is how a method promises not to change its object") else => "a const function is spelled 'fn name(...) const', after the parameters, not with a leading 'const'"))
            b.first(cr)
            b.remove(cr, "remove the leading 'const'")
            b.emit()
        }

        // optional generics or specialization introducer:
        //   `fn <T> name(...)`  -> type params
        //   `fn <> name<i32>()` -> specialization marker (#68)
        var fn_intro: Declarations::SpecKind = Declarations::SpecKind::None
        var gparams: kairo::std::StackBuf<unsafe *Declarations::GenericParamDecl, 2>
        self._parse_generic_or_spec_intro(unsafe &gparams, &fn_intro)
        var has_generics = !gparams.is_empty()
        fd->generic_params.from_buf(gparams.data(), gparams.size(), self.dyn()->ctx)

        // name | `op <operator>` | qualified `Class::method`
        if self.dyn()->check(TokenKind::KwOp) {
            self.dyn()->advance() // consume `op`
            // A class's own allocator: `op new` (any storage; a
            // non-static one is ClassAllocatorCheck's error) and a STATIC
            // `op delete`, which a destructor never is. Both are declared
            // under the Allocator interface's member names, decided here at
            // the head because the index pass hoists from the head alone.
            var alloc_op: u8 = 0
            if self.dyn()->check(TokenKind::LitIdentifier)
                && self.dyn()->ctx->get_spelling(
                    self.dyn()->current(),
                ) == AllocNames::op_new_word() {
                alloc_op = 1
            } else if self.dyn()->check(TokenKind::KwDelete)
                && lead->abi == Declarations::AbiKind::Static {
                alloc_op = 2
            }

            if alloc_op != 0 {
                var at = self.dyn()->current()
                at.kind = TokenKind::LitIdentifier
                at.imm = self.dyn()->ctx->hoisted->intern(
                    if (alloc_op == 1) => (AllocNames::alloc_member())
                    else => AllocNames::free_member(),
                )

                fd->name           = at
                fd->class_alloc_op = alloc_op
                self.dyn()->advance(T::SkipNL::After)
            } else {
                fd->is_operator = true
                // `fn op delete(self)`: the destructor's spelling before
                // 0.2.0. Keyed as `op finally` from here on, so every later
                // pass sees one destructor; ClassAllocatorCheck reports the
                // spelling (S090E), except in the builtin / std library.
                if self.dyn()->check(TokenKind::KwDelete) {
                    fd->old_dtor_at = self.dyn()->current_ptr()->range
                }

                var ops: kairo::std::StackBuf<Token, 2>
                self._parse_and_validate_op_spelling(unsafe &ops)
                fd->op_token.from_buf(ops.data(), ops.size(), self.dyn()->ctx)
                fd->name = Token()
            }
        } else if self.dyn()->check(TokenKind::LitIdentifier)
            || self.dyn()->check(TokenKind::KwSelf) {
            var name_tok = self.dyn()->current()
            self.dyn()->advance()

            // out-of-line `Class::method` / `Class::Inner::method`
            if self.dyn()->check(TokenKind::OpColonColon) {
                fd->qualifier = self._parse_qualified_fn_name(name_tok)
                // the trailing segment becomes the function name.
                if self.dyn()->check(TokenKind::KwOp) {
                    self.dyn()->advance()
                    fd->is_operator = true
                    if self.dyn()->check(TokenKind::KwDelete) {
                        fd->old_dtor_at = self.dyn()->current_ptr()->range
                    }

                    var ops: kairo::std::StackBuf<Token, 2>
                    self._parse_and_validate_op_spelling(unsafe &ops)
                    fd->op_token.from_buf(ops.data(), ops.size(), self.dyn()->ctx)
                    fd->name = Token()
                } else {
                    fd->name = self.dyn()->current()
                    self.dyn()->advance()
                }
            } else {
                fd->name = name_tok
            }

            // specialization argument pattern: `name<i32>`, `name<[T]>`.
            // Only meaningful when a `<>` introducer preceded the name.
            if (fn_intro != Declarations::SpecKind::None || has_generics)
                && self.dyn()->check(TokenKind::OpLess) {
                var sargs: kairo::std::StackBuf<unsafe *Type, 4>
                self._parse_spec_args(&sargs)
                fd->spec_args.from_buf(sargs.data(), sargs.size(), self.dyn()->ctx)

                var kind = self._classify_spec(&sargs, has_generics)
                // Functions accept primary + explicit only; partial (a pattern
                // over the head's own type variables) is a class/struct/union
                // feature. See issue #68. Note a `<>` head can never land here:
                // it binds no variables, so `fn <> f<*i32>()` is a FULL
                // specialization and is accepted, matching C++.
                if kind == Declarations::SpecKind::Partial {
                    self.dyn()->diag->report(DiagID::S049E, fd->name.range.start,
                        "partial specialization is not allowed on functions; "
                        "only classes, structs, and unions may be partially specialized"
                    ).first(fd->name.range)
                     // FIXME(diag-table): placeholder id - S049N is not in the
                     // registry yet; wants its own note code next to S049E.
                     // No location: the note would point at the same span as the
                     // error, so a second caret is noise. Plain text reads better.
                     .note(DiagCode(DiagID::S045N),
                        "overload the function on the pattern instead, or move the "
                        "pattern onto a struct and partially specialize that"
                     )->emit()
                    kind = Declarations::SpecKind::Explicit // best-effort recovery
                }

                fd->spec_kind = kind
            } else if fn_intro != Declarations::SpecKind::None {
                // `fn <>` with no post-name `<...>` is malformed.
                self.dyn()->diag->report(
                    DiagID::S049E,
                    fd->name.range.start,
                    "expected specialization arguments '<...>' after the name "
                    "following the '<>' specialization marker",
                ).first(fd->name.range)->emit()
            }
        } else if is_annotation(self.dyn()->ig_kind())
            && self.dyn()->ig_kind() != TokenKind::AtComment
            && (self.dyn()->ig_peek_kind() == TokenKind::OpLParen
                || self.dyn()->ig_peek_kind() == TokenKind::OpLess) {
            // `fn f16(...)`: a primitive type's name is reserved.
            // Reported, then kept as the name so the parameters and body
            // still parse and resolve: nothing downstream cascades.
            var at = self.dyn()->current()
            self.dyn()->diag->report(
                DiagID::S047E,
                at.range.start,
                f"'{token_kind_to_readable_string(at.kind)}' names a primitive type and cannot name a function",
            ).first(at.range)->emit()
            at.imm   = self.dyn()->ctx->hoisted->intern(token_kind_to_readable_string(at.kind))
            at.kind  = TokenKind::LitIdentifier
            fd->name = at
            self.dyn()->advance()
        } else {
            self.dyn()->report_tok(
                DiagID::S047E,
                self.dyn()->current_ptr(),
                "expected function name, 'op', or a qualified name after 'fn'",
            )

            self.dyn()->exit_depth()
            self._sync_decl(Self::DeclSyncCtx::TopLevel)
            return (Declarations::FunctionDecl::create_error(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
            ))
        }

        // index mode: the head is fully parsed (generics, name, spec pattern
        // all live on `fd`). Token-skip the signature and body; the index
        // walker hoists from the returned node.
        if self.dyn()->mode == T::ParseMode::Index {
            self.dyn()->_index_skip_stmt()
            fd->range = start | self.dyn()->prev().range
            self.dyn()->exit_depth()
            return unsafe (fd as unsafe *Decl)
        }

        // parameter list
        self.dyn()->enter_scope(ScopeKind::Function, fd)

        if !self.dyn()->check(TokenKind::OpLParen) {
            self.dyn()->report_tok(
                DiagID::S047E,
                self.dyn()->current_ptr(),
                "expected '(' to begin the parameter list",
            )

            self.dyn()->exit_scope()
            self.dyn()->exit_depth()
            self._sync_decl(Self::DeclSyncCtx::TopLevel)
            return (Declarations::FunctionDecl::create_error(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
            ))
        }

        var params: kairo::std::StackBuf<unsafe *Declarations::ParamDecl, 4>
        self._parse_param_list(&params)
        fd->params.from_buf(params.data(), params.size(), self.dyn()->ctx)
        // The list's `)`, where a fix-it inserts a ` panic` specifier.
        if self._prev_kind() == TokenKind::OpRParen {
            fd->params_end = self._prev_range()
        }

        // DERIVED, never written directly: the parameter list is the truth
        // about which parameter is the pack (ParamDecl::is_pack), and a flag on
        // the function cannot say which one it is.
        fd->is_variadic = false
        for var i: usize = 0; i < fd->params.size(); ++i {
            if fd->params[i] != &null && fd->params[i]->is_pack {
                fd->is_variadic = true
            }
        }

        // A non-pack parameter after the pack can only ever be supplied by
        // name: every positional argument from the pack onward belongs to it.
        var seen_pack = false
        for var i: usize = 0; i < fd->params.size(); ++i {
            var unsafe *p = fd->params[i]
            if p == &null {
                continue
            }

            if p->is_pack {
                seen_pack = true
                continue
            }

            if seen_pack {
                p->keyword_only = true
            }
        }

        // a signature with any type-only (unnamed) parameter is a forward
        // declaration: it is purely a type signature and cannot carry a body.
        var is_type_only_sig = false
        var has_self_param   = false
        for var i: usize = 0; i < fd->params.size(); ++i {
            if fd->params[i]->unname {
                is_type_only_sig = true
            }

            if fd->params[i]->is_self {
                has_self_param = true
                // `const self` -> const method. RedeclMerge, DeclImport and
                // the printer all key on fd->is_const(); keeping that the
                // single flag means nothing downstream learns a second form.
                if fd->params[i]->is_const {
                    fd->modifiers |= Declarations::FnModifier::IsConst
                }
            }
        }

        // `self` is a method receiver: legal only inside a type body or on an
        // out-of-line method definition (`fn Class::m(self)`), never in a free
        // function.
        if has_self_param && !in_type_scope && !fd->is_out_of_line() {
            self.dyn()->diag->report(
                DiagID::S047E,
                start.start,
                "the `self` receiver is only allowed on a method; a free "
                "function cannot take `self`",
            ).first(start)->emit()
        }

        // function modifiers: volatile unsafe eval async final panic inline
        // (a trailing `const` is diagnosed there; it is spelled `const self`)
        self._parse_fn_modifiers(fd)

        // return type
        // `->` may start a continuation line under the signature. Nothing
        // else begins with `->`, so the newline in front of it never ends a
        // declaration; without the peek the arrow parsed on its own line only
        // when the `)` before it happened to be consumed under newline
        // suppression (a list ending in a typed parameter), and `fn f()` or
        // `fn m(self)` with it was S048E in a type body and S052E outside.
        if self._peek_past_nl(TokenKind::OpArrow) {
            self.dyn()->advance(T::SkipNL::After) // consume `->`
            if self.dyn()->check(TokenKind::OpExclaim) {
                fd->is_noreturn = true
                self.dyn()->advance() // consume `!`
            } else {
                var rty = self.dyn()->parse_type()
                if rty != &null && !is_recovery(rty) {
                    fd->return_type = rty
                }
            }
        }

        // optional `requires <expr>` constraint
        if self._peek_past_nl(TokenKind::KwRequires) {
            self.dyn()->advance(T::SkipNL::After)
            var req = self.dyn()->parse_expr()
            if req != &null && !is_recovery(req) {
                fd->requires_clause = req
            }
        }

        // optional `where <expr>` runtime-dispatch guard (functions only).
        // Comes after requires: `fn f(...) -> T requires <ct> where <rt> { }`.
        // where.mdx writes it on its own line under the head, the way
        // `requires` may sit; `where` cannot begin a declaration or a
        // statement, so the newline in front of it never ends anything.
        if self._peek_past_nl(TokenKind::KwWhere) {
            var wh = self._cur_range()
            self.dyn()->advance(T::SkipNL::After)
            var wex = self.dyn()->parse_guard_expr()
            if wex != &null && !is_recovery(wex) {
                fd->where_clause = wex
            } else if wex == &null {
                self.dyn()->diag->report(
                    DiagID::S052E,
                    wh.start,
                    "expected a condition after 'where'",
                ).first(wh)->emit()
            }
        }

        // body
        // In a type body the `{` may sit on its own line under a wrapped
        // signature: no member can begin with `{`, so the newline cannot be
        // ending a bodyless method, and without the join every following
        // member cascades into S048E. At module or block scope it stays a
        // terminator: a bodyless `fn f()` there may legally be followed by a
        // bare block statement, so joining would change what the code means.
        if in_type_scope {
            self._peek_past_nl(TokenKind::OpLBrace)
        }

        self._parse_fn_body(fd)

        // type-only signatures are forward declarations: reject any body.
        if is_type_only_sig && fd->body_kind != Declarations::FnBodyKind::None {
            self.dyn()->diag->report(
                DiagID::S047E,
                start.start,
                "a function signature with type-only (unnamed) parameters is a "
                "forward declaration and cannot have a body; name the parameters "
                "to give it one",
            ).first(start)->emit()
        }

        // a type-only signature is a forward declaration; never mark it as the
        // definition (even on the errored with-a-body path above) so it cannot
        // poison the redeclaration chain.
        if fd->body_kind != Declarations::FnBodyKind::None && !is_type_only_sig {
            fd->mark_definition()
        }

        fd->range = start | self.dyn()->prev().range
        self.dyn()->exit_scope()
        self.dyn()->exit_depth()
        return unsafe (fd as unsafe *Decl)
    }

    /// \brief parses the `Class::` (or `Class::Inner::`) qualifier path of an
    ///        out-of-line definition, leaving the cursor on the final segment.
    /// \returns a ChainExpr representing the qualifier path.
    priv fn _parse_qualified_fn_name(self, first: Token) -> *Expr {
        var start = first.range
        var base  = NamedIdentExpr::create(self.dyn()->ctx, first.range, first)

        var ce = ChainExpr::create(self.dyn()->ctx, start, base)
        var steps: kairo::std::StackBuf<ChainExpr::Step, 4>

        // we are sitting on the first `::`
        while self.dyn()->check(TokenKind::OpColonColon) {
            self.dyn()->advance() // consume `::`
            // if the next-next is NOT another `::` and this is the trailing
            // segment, stop so the caller can read the method name. We detect
            // the trailing segment by: identifier NOT followed by `::`.
            if self.dyn()->check_is_ident() && !self.dyn()->check_peek(TokenKind::OpColonColon) {
                // leave cursor on the trailing segment for the caller.
                break
            }

            if !self.dyn()->check_is_ident() {
                break
            }

            var seg_tok = self.dyn()->current()
            var step    = ChainExpr::Step{}
            step.name          = NamedIdentExpr::create(self.dyn()->ctx, seg_tok.range, seg_tok)
            step.range         = seg_tok.range
            step.access_kind   = ChainExpr::AccessKind::ColonColon
            step.resolved_type = &null
            step.resolved_decl = &null
            steps.push_back(step)
            self.dyn()->advance() // consume the segment identifier
        }

        ce->steps.from_buf(steps.data(), steps.size(), self.dyn()->ctx)
        ce->range = start | self.dyn()->prev().range
        return ce
    }

    /// \brief parses a parameter list `( param (',' param)* )`.
    ///  Grammar:  param := 'self' | '...'? name ':' type ('=' expr)?
    /// \returns true if a trailing variadic pack `...name: T` was seen.
    priv fn _parse_param_list(self,
                              @inout out: kairo::std::StackBuf<unsafe *Declarations::ParamDecl, 4>) -> bool {
        var lparen_tok = self.dyn()->current() // kept whole: expansion-aware diags below need the token, not just the range
        var lparen     = lparen_tok.range
        self.dyn()->advance(T::SkipNL::After) // consume `(`

        // a parameter list is bracket-delimited, so newlines inside it are
        // never significant - the closing `)` is the terminator, not the line
        // break. Suppress them for the whole list so signatures may wrap:
        //     fn create(
        //         ctx: *ASTContext,
        //         range: SourceRange
        //     ) -> *Expr
        self.dyn()->nl_push()

        var variadic     = false
        var idx:     u32 = 0

        // a parameter list is either all-named (`name: T`, the ordinary form,
        // which may carry a body) or all type-only (`T`, a forward-declaration
        // signature with no body). these track the two so a mixed list errors.
        var saw_named   = false
        var saw_unnamed = false

        if self.dyn()->check(TokenKind::OpRParen) {
            self.dyn()->nl_pop()
            self.dyn()->advance() // consume `)`
            return false
        }

        while !self.dyn()->is_eof() {
            // `self`. The receiver is neutral w.r.t. the named/type-only split:
            // it is compatible with both a named method (`fn m(self, x: T)`) and
            // a type-only member forward declaration (`fn m(self, T)`), so it
            // sets neither saw_named nor saw_unnamed. (Whether `self` is allowed
            // at all here is a placement check in `_parse_function`.)
            // `const self` is the only spelling of a const method: the
            // qualifier belongs to the receiver it actually constrains, not
            // to a trailing slot after `)` (that form is rejected in
            // `_parse_fn_modifiers`). `_parse_function` lifts it onto
            // FnModifier::IsConst so Sema keeps one source of truth.
            // Passing mode. Written either side of `const` (`@inout x: T`,
            // `const @move x: T`); the second spot is taken in the const probe
            // below. Taken here, first, so the `self` check sees it as well.
            // Never through the attribute parser: inside a parameter list
            // `@move` is a mode, never the transfer-ctor attribute.
            var p_mode       = self.dyn()->_peek_mode()
            var p_mode_range = SourceRange::invalid()
            if p_mode != ParamMode::Value {
                p_mode_range = self.dyn()->_consume_mode()
            }

            var self_const = false
            var self_start = self._cur_range()
            if self.dyn()->check(TokenKind::KwConst) && self.dyn()->check_peek(TokenKind::KwSelf) {
                self_const = true
                self.dyn()->advance() // consume `const`
            } else if self.dyn()->check(TokenKind::KwConst)
                && self.dyn()->check_peek(TokenKind::OpAt) {
                // `const @inout self`: the mode sits between `const` and
                // `self`, three tokens along, so probe. A hit falls into the
                // `self` path below and draws the same receiver error as
                // `@inout self`; a miss rolls back for the named-param probe.
                var sprobe = self.dyn()->tentative_begin()
                self.dyn()->advance() // consume `const`
                var sm       = self.dyn()->_peek_mode()
                var sm_range = SourceRange::invalid()
                if sm != ParamMode::Value {
                    sm_range = self.dyn()->_consume_mode()
                }

                if sm != ParamMode::Value && self.dyn()->check(TokenKind::KwSelf) {
                    self.dyn()->tentative_commit(sprobe)
                    self_const = true
                    if p_mode == ParamMode::Value {
                        p_mode       = sm
                        p_mode_range = sm_range
                    }
                } else {
                    self.dyn()->tentative_rollback(sprobe)
                }
            }

            if self.dyn()->check(TokenKind::KwSelf) {
                var s_tok = self.dyn()->current()
                self.dyn()->advance()
                // Reported and dropped: ParamDecl::mode is never set on `self`.
                if p_mode != ParamMode::Value {
                    self.dyn()->diag->report(
                        DiagID::S069E,
                        p_mode_range.start,
                        "'self' takes no passing mode; the receiver is already passed "
                        "by reference, and its mutability is written 'const self'",
                    ).first(p_mode_range)->emit()
                }

                var pd = Declarations::ParamDecl::create_self(
                    self.dyn()->ctx,
                    self_start | s_tok.range,
                    s_tok,
                )

                pd->is_const = self_const
                pd->index    = idx
                out.push_back(pd)
                ++idx
                if self.dyn()->check(TokenKind::OpComma) {
                    self.dyn()->advance(T::SkipNL::After)
                    continue
                }

                break
            }

            // The pack marker. `const ...s: T` and `...s: T` are both accepted
            // and mean the same thing; the qualifier comes FIRST, so the probe
            // below also has to accept `const` followed by `...`. Marked here
            // when the `...` leads; the const probe marks the other order.
            var p_start = self._cur_range()
            var p_pack  = false
            /// `...const s: T` -- diagnosed below, but the `const` is consumed
            /// and kept, so it still reaches the ParamDecl.
            var p_const_pre = false
            if self.dyn()->check(TokenKind::OpEllipsis) {
                p_pack = true
                self.dyn()->advance() // consume `...`
                // `...const s: T`: the marker is where the qualifier belongs.
                // Diagnosed, then the `const` is CONSUMED and kept, so the
                // parameter stays usable for everything downstream instead of
                // cascading into "expected type".
                if self.dyn()->check(TokenKind::KwConst) {
                    var c_tok = self.dyn()->current()
                    self.dyn()->diag->report(
                        DiagID::S067E,
                        c_tok.range.start,
                        "qualifiers precede the pack marker: write 'const ...s'",
                    ).first(c_tok.range)->emit()
                    self.dyn()->advance() // consume `const`
                    p_const_pre = true
                }
            }

            // Disambiguate a named param (`name: T`) from a bare type-only
            // param (`T`). A name is an identifier immediately followed by `:`
            // (but not `::`, which begins a scoped type path). Anything else
            // - a leading `*`/`[`/`(`, a scoped name, a bare type name - is a
            // type-only parameter, i.e. a forward-declaration signature
            // (`fn foo(i32, f64)`, the equivalent of C's `void foo(int, double)`).
            // optional `const` on a parameter. Two shapes stay distinct:
            //     const start: Source   -> named param, const binding
            //     const Source          -> type-only param, const type
            // Both open `const` + identifier, so the discriminator is the `:`
            // two tokens along. Probe for the named shape; on a miss roll back
            // so the `const` is left for parse_type to fold into the type.
            var p_const = p_const_pre
            if !p_pack && self.dyn()->check(TokenKind::KwConst) {
                var probe = self.dyn()->tentative_begin()
                self.dyn()->advance() // consume `const`
                // `const @mode x: T`, the other order of `@mode const x: T`.
                // Inside the probe: a rollback un-consumes it with the const.
                var c_mode       = self.dyn()->_peek_mode()
                var c_mode_range = SourceRange::invalid()
                if c_mode != ParamMode::Value {
                    c_mode_range = self.dyn()->_consume_mode()
                }

                // `const ...s: T`: the canonical pack spelling. Consumed here
                // so the named-shape test below sees `s :` as usual.
                var c_pack = false
                if self.dyn()->check(TokenKind::OpEllipsis) {
                    c_pack = true
                    self.dyn()->advance()
                }

                if self.dyn()->check(TokenKind::LitIdentifier)
                    && self.dyn()->check_peek(TokenKind::OpColon)
                    && !self.dyn()->check_peek(TokenKind::OpColonColon) {
                    self.dyn()->tentative_commit(probe)
                    p_const = true
                    if c_pack {
                        p_pack = true
                    }

                    if c_mode != ParamMode::Value && p_mode == ParamMode::Value {
                        p_mode       = c_mode
                        p_mode_range = c_mode_range
                    }
                } else {
                    self.dyn()->tentative_rollback(probe)
                }
            }

            var is_named = self.dyn()->check(TokenKind::LitIdentifier)
                && self.dyn()->check_peek(TokenKind::OpColon)
                && !self.dyn()->check_peek(TokenKind::OpColonColon)

            var pname = Token()
            if is_named {
                saw_named = true
                pname     = self.dyn()->current()
                self.dyn()->advance()                 // consume name
                self.dyn()->advance(T::SkipNL::After) // consume `:`
            } else {
                saw_unnamed = true
            }

            // Prevent parse_type from consuming delimiters on error
            if self.dyn()->check(TokenKind::OpComma) || self.dyn()->check(TokenKind::OpRParen) {
                self.dyn()->report_tok(DiagID::S053E, self.dyn()->current_ptr(), "expected type")
                if self.dyn()->check(TokenKind::OpComma) {
                    self.dyn()->advance(T::SkipNL::After)
                    continue
                }

                break
            }

            var pty = self.dyn()->parse_type()
            if pty == &null || is_recovery(pty) {
                self._sync_decl(Self::DeclSyncCtx::Params)
                if self.dyn()->check(TokenKind::OpComma) {
                    self.dyn()->advance(T::SkipNL::After)
                    continue
                }

                break
            }

            var pd = Declarations::ParamDecl::create(
                self.dyn()->ctx,
                p_start | self.dyn()->prev().range,
                pname,
                pty,
                idx,
                !is_named,
            )

            pd->is_const   = p_const
            pd->mode       = p_mode
            pd->mode_range = p_mode_range

            // A second pack has no rule that could decide where the first one
            // stops. Diagnosed, and NOT marked: the list keeps exactly one
            // pack so placement downstream stays well-defined.
            if p_pack && variadic {
                self.dyn()->diag->report(
                    DiagID::S068E,
                    p_start.start,
                    "only one pack parameter is allowed; the first pack takes every remaining positional argument",
                ).first(p_start)->emit()
            } else if p_pack {
                pd->is_pack = true
                variadic    = true
            }

            // `const` with a mode contradicts it. Reported at the mode, and the
            // mode KEPT: the decl stays usable for everything downstream.
            if p_const && p_mode != ParamMode::Value {
                var cmsg = "'const' cannot be combined with " + LangAttrs::quoted(LangAttrs::param_move())
                if p_mode == ParamMode::Inout {
                    var q = LangAttrs::quoted(LangAttrs::param_inout())
                    cmsg = "'const' and " + q + " contradict: an " + q + " parameter is a mutable borrow; a read-only borrow is 'const x: T'"
                }

                self.dyn()->diag->report(DiagID::S070E, p_mode_range.start, cmsg).first(
                    p_mode_range,
                )->emit()
            }

            // `x: const T` on a NAMED parameter is `const x: T` spelled on the
            // type: identical in meaning, harder to read. Same warning as
            // `var x: const T`. An unnamed parameter has no binding to move
            // the const onto, so it is left alone.
            if is_named && !p_const && pty->is_const() {
                var c_range = self.dyn()->top_const_range(pty)
                var b = self.dyn()->diag->report(
                    DiagID::S071W,
                    c_range.start,
                    "'const' on the type of a parameter is hard to read; declare the parameter 'const' instead",
                )

                b.first(c_range)
                b.insert(pname.range.start, "const ", "make the parameter 'const'")
                b.remove(c_range, "and drop it from the type")
                b.emit()
            } else if is_named && p_const && pty->is_const() {
                // `const x: const T`: the same rule as a variable, a hard error
                // on the second const.
                var c_range = self.dyn()->top_const_range(pty)
                self.dyn()->diag->report(
                    DiagID::S071E,
                    c_range.start,
                    "the parameter is already 'const'; a second 'const' on its type is not allowed",
                ).first(c_range)->remove(c_range, "remove the second 'const'")->emit()
            }

            // default value
            if self.dyn()->check(TokenKind::OpEqual) {
                self.dyn()->advance(T::SkipNL::After) // consume `=`
                var dv = self.dyn()->parse_expr(self.dyn()->stop_on(T::ExprStopKind::StopComma))
                if dv != &null && !is_recovery(dv) {
                    pd->default_val = dv
                }
            }

            // bind named params in the function scope for body lookups.
            // type-only params have no name to bind.
            if is_named {
                self.dyn()->scope.bind(self.dyn()->ctx->get_spelling(pname), pd, pname.range)
            }

            out.push_back(pd)
            ++idx

            if self.dyn()->check(TokenKind::OpComma) {
                self.dyn()->advance(T::SkipNL::After)
                if self.dyn()->check(TokenKind::OpRParen) { // trailing comma
                    break
                }

                continue
            }

            break
        }

        if self.dyn()->check(TokenKind::OpRParen) {
            self.dyn()->advance()
        } else {
            self.dyn()->report_tok(
                DiagID::S047E,
                &lparen_tok,
                "expected ')' to close the parameter list",
            )

            // Only synchronize to TopLevel if we are not at a capture list or body block
            if !self.dyn()->check(TokenKind::OpPipe)
                && !self.dyn()->check(TokenKind::OpPipePipe)
                && !self.dyn()->check(TokenKind::OpLBrace) {
                self._sync_decl(Self::DeclSyncCtx::TopLevel)
            }
        }

        // a list may be all-named or all type-only, never a mix: type-only
        // params name no binding for a body to refer to.
        if saw_named && saw_unnamed {
            self.dyn()->report_tok(
                DiagID::S047E,
                &lparen_tok,
                "cannot mix named parameters (`name: T`) and type-only "
                "parameters (`T`) in one signature; a type-only signature is a "
                "bodyless forward declaration",
            )
        }

        self.dyn()->nl_pop()
        return variadic
    }

    /// \brief Parses the capture list for a closure, supporting value, pointer, and const pointer captures.
    /// \details Implements the updated grammar:
    ///            '|' capture (',' capture)* '|'
    ///            capture := 'const'? '*'? identifier | '*'
    /// \returns true only for a list SPELLED empty (`| |`). An entry that
    ///          failed to parse (S047E) also leaves `out` empty, and keying
    ///          "captures nothing" on the count read `|3|` as `||`: the
    ///          closure then drew a follow-on "not captured" error for every
    ///          free name after the syntax error.
    pub fn _parse_capture_list(self,
                               @inout out: kairo::std::StackBuf<ClosureExpr::Capture, 4>) -> bool {
        self.dyn()->advance(T::SkipNL::After) // consume opening `|`

        // empty capture list `| |`
        if self.dyn()->check(TokenKind::OpPipe) {
            self.dyn()->advance() // consume closing `|`
            return true
        }

        // first capture, handled separately to avoid comma-before-first logic
        {
            var p_start        = self._cur_range()
            var is_const: bool = false

            if self.dyn()->check(TokenKind::KwConst) {
                is_const = true
                self.dyn()->advance() // consume `const`

                // Recovery: ensure 'const' is followed by a valid next token
                if !self.dyn()->check(TokenKind::OpStar) && !self.dyn()->check_is_ident() {
                    self.dyn()->report_tok(
                        DiagID::S047E,
                        self.dyn()->current_ptr(),
                        "expected '*' or identifier after 'const' in capture list",
                    )

                    self._sync_decl_progress(Self::DeclSyncCtx::Params)
                }
            }

            if self.dyn()->check(TokenKind::OpStar) {
                var star_range = self._cur_range()
                self.dyn()->advance() // consume `*`

                // `|*|` or `|const *|`, all-by-ptr sentinel, no named capture
                if self.dyn()->check(TokenKind::OpPipe) {
                    self.dyn()->advance() // consume `|`
                    var capture = ClosureExpr::Capture()
                    capture.name     = &null
                    capture.by_ptr   = true
                    capture.is_const = is_const
                    out.push_back(capture)
                    return false
                }

                if !self.dyn()->check_is_ident() {
                    self.dyn()->diag->report(
                        DiagID::S047E,
                        star_range.start,
                        "expected capture name after '*'",
                    ).first(star_range)->emit()
                    self._sync_decl_progress(Self::DeclSyncCtx::Params)
                    // fall through to closing `|` check
                } else {
                    var cname = self.dyn()->current()
                    self.dyn()->advance()
                    var capture = ClosureExpr::Capture()
                    capture.name = NamedIdentExpr::create(
                        self.dyn()->ctx,
                        p_start | cname.range,
                        cname,
                    )

                    capture.by_ptr   = true
                    capture.is_const = is_const
                    out.push_back(capture)
                }
            } else if self.dyn()->check(TokenKind::LitIdentifier)
                || self.dyn()->check(TokenKind::KwSelf) {
                // `self` names the receiver: spelled as a `self`
                // expression is, a NamedIdentExpr on the keyword, so it
                // resolves to the receiver ParamDecl and ClosureCaptures
                // gives it the receiver mode whatever the list says.
                var cname = self.dyn()->current()
                self.dyn()->advance()
                var capture = ClosureExpr::Capture()
                capture.name = NamedIdentExpr::create(self.dyn()->ctx, p_start | cname.range, cname)
                capture.by_ptr   = false
                capture.is_const = is_const
                out.push_back(capture)
            } else {
                self.dyn()->diag->report(
                    DiagID::S047E,
                    p_start.start,
                    "expected capture name or '*' in capture list",
                ).first(p_start)->emit()
                self._sync_decl_progress(Self::DeclSyncCtx::Params)
            }

            // after first capture: comma continues, pipe or nothing closes
            if self.dyn()->check(TokenKind::OpComma) {
                self.dyn()->advance(T::SkipNL::After)
                if self.dyn()->check(TokenKind::OpPipe) {
                    self.dyn()->advance() // handle trailing comma before closing `|`
                    return false
                }
            } else {
                if self.dyn()->check(TokenKind::OpPipe) {
                    self.dyn()->advance()
                }

                return false
            }
        }

        // remaining captures
        while !self.dyn()->is_eof() {
            var p_start        = self._cur_range()
            var is_const: bool = false
            var by_ptr:   bool = false

            if self.dyn()->check(TokenKind::KwConst) {
                //TODO recovery incase of anything other than const here
                is_const = true
                self.dyn()->advance() // consume `const`

                // Recovery: ensure valid structural capture token follows
                if !self.dyn()->check(TokenKind::OpStar) && !self.dyn()->check_is_ident() {
                    self.dyn()->report_tok(
                        DiagID::S047E,
                        self.dyn()->current_ptr(),
                        "expected '*' or identifier after 'const' in capture list",
                    )

                    self._sync_decl(Self::DeclSyncCtx::Params)
                    if self.dyn()->check(TokenKind::OpComma) {
                        self.dyn()->advance(T::SkipNL::After)
                        continue
                    }

                    break
                }
            }

            if self.dyn()->check(TokenKind::OpStar) {
                by_ptr = true
                self.dyn()->advance() // consume `*`
            }

            if !self.dyn()->check_is_ident() && !self.dyn()->check(TokenKind::KwSelf) {
                self.dyn()->diag->report(
                    DiagID::S047E,
                    p_start.start,
                    "expected capture name",
                ).first(p_start)->emit()
                self._sync_decl(Self::DeclSyncCtx::Params)
                if self.dyn()->check(TokenKind::OpComma) {
                    self.dyn()->advance(T::SkipNL::After)
                    continue
                }

                break
            }

            var cname = self.dyn()->current()
            self.dyn()->advance()

            var capture = ClosureExpr::Capture()
            capture.name     = NamedIdentExpr::create(self.dyn()->ctx, p_start | cname.range, cname)
            capture.by_ptr   = by_ptr
            capture.is_const = is_const
            out.push_back(capture)

            if self.dyn()->check(TokenKind::OpComma) {
                self.dyn()->advance(T::SkipNL::After)
                if self.dyn()->check(TokenKind::OpPipe) { // trailing comma
                    break
                }

                continue
            }

            break
        }

        if self.dyn()->check(TokenKind::OpPipe) {
            self.dyn()->advance() // consume closing `|`
        } else {
            self.dyn()->report_tok(
                DiagID::S047E,
                self.dyn()->current_ptr(),
                "expected '|' to close the capture list",
            )

            self._sync_decl(Self::DeclSyncCtx::TopLevel)
        }

        return false
    }

    priv fn _sync_to_closure_milestone(self) {
        var depth: i32 = 0
        while !self.dyn()->is_eof() {
            var k = self.dyn()->ig_kind()
            if k == TokenKind::OpLParen || k == TokenKind::OpLSquare || k == TokenKind::OpLBrace {
                ++depth
            } else if k == TokenKind::OpRParen
                || k == TokenKind::OpRSquare
                || k == TokenKind::OpRBrace {
                if depth > 0 {
                    --depth
                }
            } else if depth == 0 {
                if k == TokenKind::OpPipe
                    || k == TokenKind::OpArrow
                    || k == TokenKind::OpEqual
                    || self._is_closure_modifier(k) {
                    return
                }
            }

            self.dyn()->advance()
        }
    }

    priv fn _is_closure_modifier(self, k: TokenKind) -> bool {
        return k == TokenKind::KwPanic
            || k == TokenKind::KwVolatile
            || k == TokenKind::KwAsync
            || k == TokenKind::KwConst
            || k == TokenKind::KwUnsafe
            || k == TokenKind::KwEval
            || k == TokenKind::KwFinal
            || k == TokenKind::KwInline
            || k == TokenKind::KwVirtual
            || k == TokenKind::KwOverride
    }

    /// \brief parses trailing function modifiers into fd->modifiers.
    priv fn _parse_fn_modifiers(self, fd: *Declarations::FunctionDecl) {
        while true {
            if self.dyn()->check(TokenKind::KwConst) {
                self._reject_trailing_const(fd)
            } else if self.dyn()->check(TokenKind::KwVolatile) {
                fd->modifiers |= Declarations::FnModifier::IsVolatile
                self.dyn()->advance()
            } else if self.dyn()->check(TokenKind::KwUnsafe) {
                fd->modifiers |= Declarations::FnModifier::IsUnsafe
                self.dyn()->advance()
            } else if self.dyn()->check(TokenKind::KwEval) {
                fd->modifiers |= Declarations::FnModifier::IsEval
                self.dyn()->advance()
            } else if self.dyn()->check(TokenKind::KwAsync) {
                fd->modifiers |= Declarations::FnModifier::IsAsync
                self.dyn()->advance()
            } else if self.dyn()->check(TokenKind::KwFinal) {
                fd->modifiers |= Declarations::FnModifier::IsFinal
                self.dyn()->advance()
            } else if self.dyn()->check(TokenKind::KwPanic) {
                fd->modifiers |= Declarations::FnModifier::IsPanic
                var pk = self._cur_range()
                self.dyn()->advance()
                // `panic(E1, E2)`: the declared set (TypeParse::parse_panic_set
                // has the disambiguation rule).
                if self.dyn()->check(TokenKind::OpLParen) {
                    var pset: kairo::std::StackBuf<unsafe *Type, 4>
                    self.dyn()->parse_panic_set(&pset)
                    fd->panic_set.from_buf(pset.data(), pset.size(), self.dyn()->ctx)
                }

                // The specifier as written, its set included: what a fix-it
                // removes or rewrites.
                fd->panic_range = pk | self._prev_range()
            } else if self.dyn()->check(TokenKind::KwInline) {
                fd->modifiers |= Declarations::FnModifier::IsInline
                self.dyn()->advance()
            } else {
                break
            }
        }
    }

    /// \brief diagnoses the C++-style trailing `fn f(self) const` and consumes it.
    /// \details the const belongs on the receiver: `fn f(const self)`. Recovery
    ///          still marks the method (and its receiver) const, so a decl
    ///          paired with a `const self` definition does not cascade into a
    ///          const-disagreement error on top of this one.
    priv fn _reject_trailing_const(self, fd: *Declarations::FunctionDecl) {
        var c_range = self._cur_range()
        self.dyn()->advance() // consume `const`

        var recv: unsafe *Declarations::ParamDecl = &null
        for var i: usize = 0; i < fd->params.size(); ++i {
            if fd->params[i]->is_self {
                recv = fd->params[i]
                break
            }
        }

        if recv == &null {
            // `fn f(x: f64) const -> f64`: a function that reads only its
            // inputs (FunctionDecl::is_const_fn). A method has no such form:
            // `const self` is its promise, and a static one has no receiver
            // to make that promise about.
            var unsafe *dc = fd->parent_context()
            if dc != &null && dc->is_type_scope() {
                self.dyn()->diag->report(
                    DiagID::S047E,
                    c_range.start,
                    "a method cannot be const; 'const self' is how a method promises not to change its object",
                ).first(c_range)->remove(c_range, "remove the trailing 'const'")->emit()
                return
            }

            fd->is_const_fn = true
            fd->purity_at   = c_range
            return
        }

        if recv->is_const {
            self.dyn()->diag->report(
                DiagID::S047E,
                c_range.start,
                "a trailing 'const' is not valid; the receiver is already 'const self'",
            ).first(c_range)->remove(c_range, "remove the trailing 'const'")->emit()
            return
        }

        var b = self.dyn()->diag->report(
            DiagID::S047E,
            c_range.start,
            "a const method is spelled 'fn name(const self)', not with a trailing 'const'",
        )

        // strike the misplaced const in place; the one fix-it moves it onto
        // the receiver, which is not itself at fault so it gets no label.
        b.strike(c_range)
        b.insert(recv->range.start, "const ", "qualify the receiver instead")
        b.emit()

        recv->is_const = true
        fd->modifiers |= Declarations::FnModifier::IsConst
    }

    priv fn _parse_closure_fn_modifiers(self, fd: *ClosureExpr) {
        while true {
            if self.dyn()->check(TokenKind::KwConst) {
                fd->modifiers |= Declarations::FnModifier::IsConst
                self.dyn()->advance()
            } else if self.dyn()->check(TokenKind::KwVolatile) {
                fd->modifiers |= Declarations::FnModifier::IsVolatile
                self.dyn()->advance()
            } else if self.dyn()->check(TokenKind::KwUnsafe) {
                fd->modifiers |= Declarations::FnModifier::IsUnsafe
                self.dyn()->advance()
            } else if self.dyn()->check(TokenKind::KwEval) {
                fd->modifiers |= Declarations::FnModifier::IsEval
                self.dyn()->advance()
            } else if self.dyn()->check(TokenKind::KwAsync) {
                fd->modifiers |= Declarations::FnModifier::IsAsync
                self.dyn()->advance()
            } else if self.dyn()->check(TokenKind::KwFinal) {
                fd->modifiers |= Declarations::FnModifier::IsFinal
                self.dyn()->advance()
            } else if self.dyn()->check(TokenKind::KwPanic) {
                fd->modifiers |= Declarations::FnModifier::IsPanic
                var pk = self._cur_range()
                self.dyn()->advance()
                // `panic(E1, E2)`: the declared set (TypeParse::parse_panic_set
                // has the disambiguation rule).
                if self.dyn()->check(TokenKind::OpLParen) {
                    var pset: kairo::std::StackBuf<unsafe *Type, 4>
                    self.dyn()->parse_panic_set(&pset)
                    fd->panic_set.from_buf(pset.data(), pset.size(), self.dyn()->ctx)
                }

                // The specifier as written, its set included: what a fix-it
                // removes or rewrites.
                fd->panic_range = pk | self._prev_range()
            } else if self.dyn()->check(TokenKind::KwInline) {
                fd->modifiers |= Declarations::FnModifier::IsInline
                self.dyn()->advance()
            } else {
                break
            }
        }
    }

    /// \brief parses the function body, setting body_kind + body_block/expr.
    ///  Grammar:  block | '=' expr | '=' ('default'|'delete'|'virtual') | <none>
    priv fn _parse_fn_body(self, fd: *Declarations::FunctionDecl) {
        // `= default` / `= delete` / `= expr`
        if self.dyn()->check(TokenKind::OpEqual) {
            var before_eq = self.dyn()->prev().range
            self.dyn()->advance(T::SkipNL::After) // consume `=`

            if self.dyn()->check(TokenKind::KwDefault) {
                self.dyn()->advance()
                fd->body_kind = Declarations::FnBodyKind::Default
                return
            }

            if self.dyn()->check(TokenKind::KwDelete) {
                self.dyn()->advance()
                fd->body_kind = Declarations::FnBodyKind::Delete
                return
            }

            // `= virtual` was the old pure-virtual spelling. A pure virtual
            // method is now a `virtual fn` with no body (_parse_class marks
            // it), so the fix-it rewrites to that, and recovery reads the
            // method as pure virtual so the class is not also reported for
            // a missing body or a non-abstract instantiation.
            if self.dyn()->check(TokenKind::KwVirtual) {
                var vr   = self._cur_range()
                var gone = SourceRange(before_eq.end, vr.end)
                var b = self.dyn()->diag->report(
                    DiagID::S047E,
                    vr.start,
                    "'= virtual' is not a function body; a pure virtual method is a 'virtual fn' with no body",
                )

                b.first(vr)
                b.remove(gone, "remove '= virtual'")
                if fd->abi != Declarations::AbiKind::Virtual {
                    b.insert(fd->range.start, "virtual ", "declare the method 'virtual'")
                }

                b.emit()
                self.dyn()->advance()
                fd->abi = Declarations::AbiKind::Virtual
                return
            }

            if self.dyn()->check(TokenKind::KwStatic) {
                self.dyn()->report_tok(
                    DiagID::S047E,
                    self.dyn()->current_ptr(),
                    "static functions must be declared with the 'static' modifier",
                )

                self.dyn()->advance()
                return
            }

            if self.dyn()->check(TokenKind::KwAsync) {
                self.dyn()->report_tok(
                    DiagID::S047E,
                    self.dyn()->current_ptr(),
                    "async functions must be declared with the 'async' modifier",
                )

                self.dyn()->advance()
                return
            }

            if self.dyn()->check(TokenKind::KwInline) {
                self.dyn()->report_tok(
                    DiagID::S047E,
                    self.dyn()->current_ptr(),
                    "inline functions must be declared with the 'inline' modifier",
                )

                self.dyn()->advance()
                return
            }

            if self.dyn()->check(TokenKind::KwFinal) {
                self.dyn()->report_tok(
                    DiagID::S047E,
                    self.dyn()->current_ptr(),
                    "final functions must be declared with the 'final' modifier",
                )

                self.dyn()->advance()
                return
            }

            if self.dyn()->check(TokenKind::KwPanic) {
                self.dyn()->report_tok(
                    DiagID::S047E,
                    self.dyn()->current_ptr(),
                    "panic functions must be declared with the 'panic' modifier",
                )

                self.dyn()->advance()
                return
            }

            // expression-bodied
            var e = self.dyn()->parse_expr()
            if e != &null && !is_recovery(e) {
                fd->body_kind = Declarations::FnBodyKind::Expr
                fd->body_expr = e
            }

            return
        }

        // block body
        if self.dyn()->check(TokenKind::OpLBrace) {
            // --check-past-syntax-errors: errors the body kept inside its own
            // braces leave the rest of the file parsed as it would have been;
            // the driver may drop the body and check the signature
            // (Driver/CompilerRecovery.k). Outermost bodies only: a nested
            // function or closure is part of the body around it.
            var open   = self.dyn()->c_idx
            var errs0  = self.dyn()->diag->error_count()
            var watch  = self.dyn()->recover_bodies && self.dyn()->recover_body_depth == 0
            self.dyn()->recover_body_depth += 1
            var block = self.dyn()->parse_compound()
            self.dyn()->recover_body_depth -= 1
            fd->body_kind  = Declarations::FnBodyKind::Block
            fd->body_block = block
            var errs = self.dyn()->diag->error_count() - errs0
            if watch && errs > 0 && self.dyn()->closes_lexically(open) {
                self.dyn()->tu->recovered_bodies.push(unsafe (fd as unsafe *Decl))
                self.dyn()->tu->recovered_errors += errs
            }

            return
        }

        // no body forward declaration / FFI import.
        fd->body_kind = Declarations::FnBodyKind::None
    }

    //  Variable / field declaration

    /// \struct StorageHead
    /// \brief the keywords that open a binding, read by _parse_storage_head.
    struct StorageHead {
        var storage:       Declarations::StorageClass
        var is_thread:     bool
        var const_binding: bool ///< `static const` / `thread const`: the binding itself is const.
        var saw_const:     bool ///< a `const` was read, whatever it meant (`eval const` sets nothing else).
    }

    /// \brief reads the keywords that open a binding or a field, in either
    ///        order where `const` combines with a storage keyword.
    ///  Grammar:  'var'
    ///          | 'const' ( 'static' 'thread'? | 'thread' | 'eval' )?
    ///          | 'static' 'thread'? 'const'?
    ///          | 'thread' 'const'?
    ///          | 'eval' 'const'?
    ///
    /// \details `static const x` and `const static x` are one declaration
    ///          (variables.mdx): the storage keyword says where the object
    ///          lives, `const` that the binding cannot be reassigned. Both
    ///          orders land on the same node -- `storage` keeps the storage
    ///          keyword and `const_binding` the const -- so nothing after the
    ///          parser can tell which was written. `eval` is const already, so
    ///          `eval const` / `const eval` is plain `eval` and sets nothing.
    ///          `thread` is `static` storage with `is_thread`, the shape
    ///          `static thread` always had: every consumer that asks
    ///          is_static() (`Type::name` lookup, nullness, the C++ spelling)
    ///          is already right for it. Anything else after the keyword is
    ///          left for the name check, whose S046E names the real problem.
    priv fn _parse_storage_head(self) -> Self::StorageHead {
        var first = self.dyn()->current()
        var h     = self._storage_head_core()

        // A keyword of the set still on the cursor is a combination the
        // grammar above refuses (`var thread`, `static eval`, `const const`).
        // Named here, where both keywords are known: left for the name check
        // it was S046E "expected a name", which hides the real mistake. The
        // extra keyword is dropped and the declaration parses on.
        // FIXME(diag-table): S045 is "unexpected token in parsing"; a
        // storage-class combination wants its own code.
        while self.dyn()->check(TokenKind::KwVar)
            || self.dyn()->check(TokenKind::KwConst)
            || self.dyn()->check(TokenKind::KwStatic)
            || self.dyn()->check(TokenKind::KwEval)
            || self.dyn()->check(TokenKind::KwThread) {
            var extra = self.dyn()->current()
            var msg = f"'{self.dyn()->ctx->get_spelling(first)}' cannot be combined with '{self.dyn()->ctx->get_spelling(extra)}'; a binding takes one of 'var', 'static', 'thread' or 'eval', and 'const' once"
            if self.dyn()->check(TokenKind::KwConst) && h.saw_const {
                msg = "'const' is written twice; a binding takes it once"
            }

            var b = self.dyn()->diag->report(DiagID::S045E, extra.range.start, msg)
            b.first(extra.range)
            b.remove(extra.range, "remove it")
            b.emit()
            self.dyn()->advance() // consume the extra keyword
        }

        return h
    }

    priv fn _storage_head_core(self) -> Self::StorageHead {
        var h = Self::StorageHead{}
        h.storage       = Declarations::StorageClass::Var
        h.is_thread     = false
        h.const_binding = false
        h.saw_const     = false

        var lead_const = self.dyn()->check(TokenKind::KwConst)
        if lead_const {
            h.storage   = Declarations::StorageClass::Const
            h.saw_const = true
            self.dyn()->advance() // consume `const`
            if self.dyn()->check(TokenKind::KwStatic) || self.dyn()->check(TokenKind::KwThread) {
                h.storage       = Declarations::StorageClass::Static
                h.is_thread     = self.dyn()->check(TokenKind::KwThread)
                h.const_binding = true
                self.dyn()->advance() // consume `static` / `thread`
                if !h.is_thread && self.dyn()->check(TokenKind::KwThread) {
                    h.is_thread = true
                    self.dyn()->advance() // consume `thread` of `const static thread`
                }
            } else if self.dyn()->check(TokenKind::KwEval) {
                h.storage = Declarations::StorageClass::Eval
                self.dyn()->advance() // consume `eval`
            }

            return h
        }

        if self.dyn()->check(TokenKind::KwStatic) {
            h.storage = Declarations::StorageClass::Static
        } else if self.dyn()->check(TokenKind::KwThread) {
            h.storage   = Declarations::StorageClass::Static
            h.is_thread = true
        } else if self.dyn()->check(TokenKind::KwEval) {
            h.storage = Declarations::StorageClass::Eval
        }

        var is_var = self.dyn()->check(TokenKind::KwVar)
        self.dyn()->advance() // consume the storage keyword
        if is_var {
            return h
        }

        if h.storage == Declarations::StorageClass::Static
            && !h.is_thread
            && self.dyn()->check(TokenKind::KwThread) {
            h.is_thread = true
            self.dyn()->advance() // consume `thread` of `static thread`
        }

        if self.dyn()->check(TokenKind::KwConst) {
            if h.storage == Declarations::StorageClass::Static {
                h.const_binding = true
            }

            h.saw_const = true
            self.dyn()->advance() // consume `const`
        }

        return h
    }

    /// \brief parses a var/const/static/eval binding as a VariableDecl.
    ///  Grammar:  ('var'|'const'|'static'|'eval') identifier (':' type)?
    ///            ('=' expr)?
    ///
    /// \note destructuring (`var (a, b) = ...`) is handled by StmtParse at
    ///       statement scope; this path is for plain single-name bindings,
    ///       including the C-style for-loop init and namespace/local decls.
    fn _parse_var_decl(self) -> unsafe *Decl {
        var start = self._cur_range()

        var head    = self._parse_storage_head()
        var storage = head.storage
        self.dyn()->_reject_mode_binding() // `var @inout x`: modes are parameter-only.

        // `var *y = e`, `var **y = e`, `var unsafe *y = e`: the pointer
        // shorthand (Compiler/Spec/Nullables.md#declaration-shorthands). Before the name, so the name check
        // below sees the identifier; left unread, the `*` was S046E.
        // `unsafe` counts only before a star: alone it is no shorthand.
        var p_depth  = (0 as u32)
        var p_unsafe = false
        var p_range  = SourceRange::invalid()
        if self.dyn()->check(TokenKind::KwUnsafe) && self.dyn()->check_peek(TokenKind::OpStar) {
            p_range  = self._cur_range()
            p_unsafe = true
            self.dyn()->advance() // consume `unsafe`
        }

        while self.dyn()->check(TokenKind::OpStar) {
            if p_depth == 0 && !p_unsafe {
                p_range = self._cur_range()
            } else {
                p_range = p_range | self._cur_range()
            }

            p_depth += 1
            self.dyn()->advance() // consume `*`
        }

        if !self.dyn()->check_is_ident() {
            self.dyn()->diag->report(
                DiagID::S046E,
                start.start,
                "expected a name after the binding keyword",
            ).first(start)->emit()
            self._sync_decl(Self::DeclSyncCtx::TopLevel)
            return (Declarations::VariableDecl::create_error(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
            ))
        }

        var name = self.dyn()->current()
        self.dyn()->advance()

        var vd = Declarations::VariableDecl::create(self.dyn()->ctx, start, name, storage)
        vd->storage_kw     = start // the first binding keyword: a Sema fix-it rewrites it.
        vd->is_thread      = head.is_thread
        vd->const_binding  = head.const_binding
        vd->pointer_depth  = p_depth
        vd->pointer_unsafe = p_unsafe
        vd->pointer_range  = p_range

        // `var x? = e`: the nullable shorthand. Read before the index-mode
        // skip so both parses see the same name; left for the statement
        // parser, the `?` became an expression and S052E.
        var q_range = SourceRange()
        if self.dyn()->check(TokenKind::OpQuestion) {
            q_range = self._cur_range()
            self.dyn()->advance()
            vd->nullable_shorthand = true
        }

        // index mode: the name is all the table needs; skip type and init
        // (the init is an expression parsing it here would query the
        // half-built table).
        if self.dyn()->mode == T::ParseMode::Index {
            self.dyn()->_index_skip_stmt()
            vd->range = start | self.dyn()->prev().range
            return vd
        }

        // optional `: type`
        if self.dyn()->check(TokenKind::OpColon) {
            self.dyn()->advance(T::SkipNL::After) // consume `:`
            var ty = self.dyn()->parse_type()
            if ty != &null && !is_recovery(ty) && vd->pointer_depth > 0 {
                // `var *y: T`. Same reasoning as `var x?: T` below: the
                // stars restate what the annotation already says, and if
                // they disagree one of them is a mistake. The annotation
                // wins (it is the explicit one); the fix-it drops the stars.
                var stars = Declarations::pointer_shorthand_spelling(
                    vd->pointer_depth,
                    vd->pointer_unsafe,
                )

                var b = self.dyn()->diag->report(
                    DiagID::S058E,
                    vd->pointer_range.start,
                    f"'{stars}{self.dyn()->ctx->get_spelling(name)}' states that the binding is a pointer, but the declaration also annotates its type; drop the '{stars}'",
                )

                b.first(vd->pointer_range)
                b.remove(vd->pointer_range, "remove the shorthand")
                b.emit()
                vd->pointer_depth  = 0
                vd->pointer_unsafe = false
            }

            if ty != &null && !is_recovery(ty) && vd->nullable_shorthand {
                // `var x?: T`. The shorthand exists to infer the type, and
                // the annotation says it outright, so one of them is a
                // mistake: refused rather than read as redundant, because
                // `var x?: i32` would otherwise mean `x: i32?` through a
                // spelling no other declaration uses. Recovered as the
                // annotation made nullable (`x: T?`, or `x: T` when T is
                // already nullable), which is what the fix-it writes.
                var already = isa<NullableType>(ty)
                var b = self.dyn()->diag->report(
                    DiagID::S058E,
                    q_range.start,
                    f"'{self.dyn()->ctx->get_spelling(name)}?' infers a nullable type, but the declaration also annotates one; write the '?' on the type",
                )

                b.first(q_range)
                b.remove(q_range, "remove the shorthand")
                if !already {
                    b.insert(ty->range.end, "?", "make the annotated type nullable")
                }

                b.emit()
                vd->nullable_shorthand = false
                if !already {
                    ty = NullableType::create(self.dyn()->ctx, ty->range, ty)
                }
            }

            if ty != &null && !is_recovery(ty) {
                vd->type_ = ty
                // `var x: const T` is `const x: T`: legal and identical in
                // meaning, but the binding keyword no longer says what the
                // binding is. A readability warning, not an error; the fix
                // moves the const onto the binding.
                if storage == Declarations::StorageClass::Var && ty->is_const() {
                    var c_range = self.dyn()->top_const_range(ty)
                    var b = self.dyn()->diag->report(
                        DiagID::S071W,
                        c_range.start,
                        "'const' on the type of a 'var' binding is hard to read; declare the binding 'const' instead",
                    )

                    b.first(c_range)
                    b.strike(start)
                    b.fix(start, "const", "make the binding 'const'")
                    b.remove(c_range, "and drop it from the type")
                    b.emit()
                } else if (storage == Declarations::StorageClass::Const || vd->const_binding)
                    && ty->is_const() {
                    // `const x: const T` says it twice. The second is the one
                    // at fault: the binding keyword is the idiomatic place.
                    var c_range = self.dyn()->top_const_range(ty)
                    self.dyn()->diag->report(
                        DiagID::S071E,
                        c_range.start,
                        "the binding is already 'const'; a second 'const' on its type is not allowed",
                    ).first(c_range)->remove(c_range, "remove the second 'const'")->emit()
                }
            }
        }

        // optional `= init`
        if self.dyn()->check(TokenKind::OpEqual) {
            self.dyn()->advance(T::SkipNL::After) // consume `=`
            var init = self.dyn()->parse_expr()
            if init != &null && !is_recovery(init) {
                vd->init = init
            }
        }

        // bind into the current scope for subsequent lookups.
        self.dyn()->scope.bind(self.dyn()->ctx->get_spelling(name), vd, name.range)

        vd->range = start | self.dyn()->prev().range
        return vd
    }

    /// \brief parses a class/struct/union member field as a FieldDecl.
    ///  Grammar:  'mutable'? ('var'|'const'|'static'|'eval') name ':' type
    ///            ('=' expr)?
    ///
    /// \details fields require an explicit type (no inference at member scope)
    ///          except where a default initializer is present; sema enforces.
    priv fn _parse_field(self, idx: u32) -> unsafe *Declarations::FieldDecl {
        var start = self._cur_range()

        var is_mutable = false
        if self.dyn()->check(TokenKind::KwMutable) {
            is_mutable = true
            self.dyn()->advance()
        }

        if !(self.dyn()->check(TokenKind::KwConst)
            || self.dyn()->check(TokenKind::KwStatic)
            || self.dyn()->check(TokenKind::KwEval)
            || self.dyn()->check(TokenKind::KwVar)
            || self.dyn()->check(TokenKind::KwThread)) {
            self.dyn()->diag->report(
                DiagID::S048E,
                start.start,
                "expected 'var', 'const', 'static', 'thread', or 'eval' to begin a field",
            ).first(start)->emit()
            return Declarations::FieldDecl::create_error(self.dyn()->ctx, start)
        }

        var head    = self._parse_storage_head()
        var storage = head.storage
        self.dyn()->_reject_mode_binding() // `var @inout f: T` on a field.

        // `var *f = e` in a type body: refused for the reason `var f? = e`
        // is below (a field never infers). Read here so the name is still
        // found and the member parses; left unread, the `*` was S048E.
        var p_depth  = (0 as u32)
        var p_unsafe = false
        var p_range  = SourceRange::invalid()
        if self.dyn()->check(TokenKind::KwUnsafe) && self.dyn()->check_peek(TokenKind::OpStar) {
            p_range  = self._cur_range()
            p_unsafe = true
            self.dyn()->advance() // consume `unsafe`
        }

        while self.dyn()->check(TokenKind::OpStar) {
            if p_depth == 0 && !p_unsafe {
                p_range = self._cur_range()
            } else {
                p_range = p_range | self._cur_range()
            }

            p_depth += 1
            self.dyn()->advance() // consume `*`
        }

        if !self.dyn()->check_is_ident() {
            self.dyn()->diag->report(DiagID::S048E, start.start, "expected field name").first(
                start,
            )->emit()
            return Declarations::FieldDecl::create_error(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
            )
        }

        var name = self.dyn()->current()
        self.dyn()->advance()

        // `var f? = e` in a type body. A field's type is declared, never
        // inferred (StmtTyping types a field's default against it), so the
        // shorthand has nothing to reshape. Refused here, where the `?` is
        // still known to be the shorthand: left alone it parses as the
        // start of the next member and the real mistake is lost.
        var q_range = SourceRange()
        var has_q   = false
        if self.dyn()->check(TokenKind::OpQuestion) {
            q_range = self._cur_range()
            has_q   = true
            self.dyn()->advance()
        }

        var fty: unsafe *Type = &null
        if self.dyn()->check(TokenKind::OpColon) {
            self.dyn()->advance(T::SkipNL::After) // consume `:`
            fty = self.dyn()->parse_type()
            if fty != &null && is_recovery(fty) {
                fty = &null
            }
        }

        if has_q {
            // Reported after the type so the fix-it can move the `?` onto
            // it when one is written (and drop it when that is nullable).
            var b = self.dyn()->diag->report(
                DiagID::S058E,
                q_range.start,
                f"a field declares its type and cannot use the '?' shorthand; write '{self.dyn()->ctx->get_spelling(name)}: T?'",
            )

            b.first(q_range)
            b.remove(q_range, "remove the shorthand")
            if fty != &null && !isa<NullableType>(fty) {
                b.insert(fty->range.end, "?", "make the field's type nullable")
            }

            b.emit()
        }

        if p_depth > 0 {
            var stars = Declarations::pointer_shorthand_spelling(p_depth, p_unsafe)
            var b = self.dyn()->diag->report(
                DiagID::S058E,
                p_range.start,
                f"a field declares its type and cannot use the '{stars}' shorthand; write '{self.dyn()->ctx->get_spelling(name)}: {stars}T'",
            )

            b.first(p_range)
            b.remove(p_range, "remove the shorthand")
            b.emit()
        }

        var fd = Declarations::FieldDecl::create(self.dyn()->ctx, start, name, storage, fty, idx)
        fd->is_mutable    = is_mutable
        fd->is_thread     = head.is_thread
        fd->const_binding = head.const_binding

        if self.dyn()->check(TokenKind::OpEqual) {
            self.dyn()->advance(T::SkipNL::After) // consume `=`
            var init = self.dyn()->parse_expr()
            if init != &null && !is_recovery(init) {
                fd->init = init
            }
        }

        fd->range = start | self.dyn()->prev().range
        return fd
    }

    //  Inheritance clauses:  derives <edges> | impl <edges>

    /// \brief parses an inheritance edge list following `derives` or `impl`.
    ///  Grammar:  ('derives'|'impl') ('virtual'? visibility? type)
    ///            (',' 'virtual'? visibility? type)*
    ///
    /// \details precondition: current is `derives` or `impl` (caller decides
    ///          which list it fills). Visibility/virtual modifiers attach
    ///          per-edge. Stops at `{`, `requires`, or a non-comma token.
    priv fn _parse_inherit_edges(self,
                                 @inout out: kairo::std::StackBuf<Declarations::InheritEdge, 4>) {
        var kw: string = if (self.dyn()->check(TokenKind::KwDerives)) => ("derives") else => "impl"
        self.dyn()->advance(T::SkipNL::After) // consume `derives` / `impl`

        while true {
            var e_start = self._cur_range()
            var edge    = Declarations::InheritEdge{}
            edge.visibility = 0
            edge.is_virtual = false

            if self.dyn()->check(TokenKind::KwVirtual) {
                edge.is_virtual = true
                self.dyn()->advance()
            }

            // per-edge visibility (derives pub/prot/priv Base)
            if self.dyn()->check(TokenKind::KwPub) {
                edge.visibility = 3
                self.dyn()->advance()
            } else if self.dyn()->check(TokenKind::KwProt) {
                edge.visibility = 2
                self.dyn()->advance()
            } else if self.dyn()->check(TokenKind::KwPriv) {
                edge.visibility = 1
                self.dyn()->advance()
            }

            var bty = self.dyn()->parse_type()
            if bty == &null || is_recovery(bty) {
                self._report_missing_edge_type(bty, kw)
                break
            }

            edge.base  = bty
            edge.range = e_start | self.dyn()->prev().range
            out.push_back(edge)

            if self.dyn()->check(TokenKind::OpComma) {
                self.dyn()->advance(T::SkipNL::After)
                continue
            }

            break
        }
    }

    /// \brief parses an interface's `derives` clause as an expression over
    ///        interfaces: `derives X + (Y - Z) & W`, and `derives A, B` as
    ///        `A + B`. The expression parser does the precedence climbing
    ///        and reads the leaves (names, `::` chains, generic applications);
    ///        this checks the shape and turns each leaf into the type
    ///        derives_list[i] resolves (InterfaceDecl::derives_expr).
    ///
    ///        Its precedence is the expression grammar's: `+`/`-` bind tighter
    ///        than `&`, so `A + B & C` is `(A + B) & C`, and mixing them
    ///        unparenthesized is warned.
    priv fn _parse_derives_expr(self,
                                id:  *Declarations::InterfaceDecl,
                                out: unsafe *kairo::std::StackBuf<Declarations::InheritEdge, 4>) -> bool {
        self.dyn()->advance(T::SkipNL::After) // consume `derives` (or a recovered `impl`)
        var stop = self.dyn()->stop_on(T::ExprStopKind::NoStructLiteral).plus(
            T::ExprStopKind::StopComma,
        )

        // `X - fn goo`: caught before the expression parser, which would read
        // `fn goo { ... }` as a closure and take the body with it.
        var n = self.dyn()->span.size()
        for var i: usize = self.dyn()->c_idx; i < n; ++i {
            var tk = self.dyn()->span.get(i)
            if tk == &null || tk->kind == TokenKind::OpLBrace {
                break
            }

            if tk->kind == TokenKind::KwFn {
                self._reject_member_removal(tk->range)
                return false
            }
        }

        var tree: unsafe *Expr = &null
        while true {
            var e = self.dyn()->parse_expr(stop)
            if e == &null || is_recovery(e) {
                self.dyn()->diag->report(
                    DiagID::S083E,
                    self._cur_range().start,
                    "expected an interface after 'derives'",
                ).first(self._cur_range())->emit()
                return false
            }

            if tree == &null {
                tree = e
            } else {
                // `A, B` is `A + B`: the comma becomes the union operator.
                var plus = self.dyn()->ctx->make_token(e->range, TokenKind::OpPlus, "+")
                tree = (BinaryOperatorExpr::create(
                    self.dyn()->ctx,
                    tree->range | e->range,
                    tree,
                    e,
                    plus,
                ))
            }

            if self.dyn()->check(TokenKind::OpComma) {
                self.dyn()->advance(T::SkipNL::After)
                continue
            }

            break
        }

        var composed = false
        if !self._derives_leaves(tree, out, unsafe &composed) {
            return false
        }

        id->derives_expr     = tree
        id->derives_composed = composed
        id->derives_end      = self.dyn()->prev().range
        return true
    }

    /// After a malformed `derives` clause: skip to the body's `{`, so the
    /// interface's members still parse and the next declaration is not
    /// swallowed. Stops at end of file or a newline-led declaration keyword.
    priv fn _sync_to_body(self) {
        while !self.dyn()->is_eof() {
            if self.dyn()->check(TokenKind::OpLBrace) {
                return
            }

            self.dyn()->advance()
        }
    }

    /// Check \p e is `+` / `-` / `&` over interface names, appending each leaf
    /// as a type to \p out in source order. False after a diagnostic.
    priv fn _derives_leaves(self,
                            e_in:     unsafe *Expr,
                            out:      unsafe *kairo::std::StackBuf<Declarations::InheritEdge, 4>,
                            composed: unsafe *bool) -> bool {
        var unsafe *e = e_in
        while e != &null && isa<ParenExpr>(e) {
            e = cast<ParenExpr>(e)->inner
        }

        if e == &null {
            return false
        }

        if isa<BinaryOperatorExpr>(e) {
            var unsafe *b = cast<BinaryOperatorExpr>(e)
            var        k  = b->op_token.kind
            if k == TokenKind::OpPipe {
                var pb = self.dyn()->diag->report(
                    DiagID::S084E,
                    b->op_token.range.start,
                    "'|' is not an interface operator; union is '+'",
                )

                pb.first(b->op_token.range)
                pb.fix(b->op_token.range, "+", "replace '|' with '+'")
                pb.emit()
                return false
            }

            if k == TokenKind::OpCaret {
                self.dyn()->diag->report(
                    DiagID::S084E,
                    b->op_token.range.start,
                    "'^' (symmetric difference) is not an interface operator; use '+', '-' or '&'",
                ).first(b->op_token.range)->emit()
                return false
            }

            if k != TokenKind::OpPlus && k != TokenKind::OpMinus && k != TokenKind::OpAmp {
                self.dyn()->diag->report(
                    DiagID::S084E,
                    b->op_token.range.start,
                    "only '+' (union), '-' (difference) and '&' (intersection) compose interfaces",
                ).first(b->op_token.range)->emit()
                return false
            }

            if k != TokenKind::OpPlus {
                *composed = true
            }

            if k == TokenKind::OpAmp {
                self._warn_mixed_amp(b)
            }

            if !self._derives_leaves(b->lhs, out, composed) {
                return false
            }

            return self._derives_leaves(b->rhs, out, composed)
        }

        if isa<ClosureExpr>(e) {
            self._reject_member_removal(e->range)
            return false
        }

        var unsafe *t = self._expr_as_type(e)
        if t == &null {
            self.dyn()->diag->report(
                DiagID::S083E,
                e->range.start,
                "expected an interface name in a 'derives' clause",
            ).first(e->range)->emit()
            return false
        }

        var edge = Declarations::InheritEdge{}
        edge.visibility = 0
        edge.is_virtual = false
        edge.base       = t
        edge.range      = e->range
        out->push_back(edge)
        return true
    }

    /// `-` and `&` group LOOSER than `+`/`-` here, as in every C expression:
    /// `A + B & C` is `(A + B) & C`. Unparenthesized, that is a guess.
    priv fn _warn_mixed_amp(self, b: unsafe *BinaryOperatorExpr) {
        var sides = cxx::std::vector<unsafe *Expr>()
        sides.push_back(b->lhs)
        sides.push_back(b->rhs)
        for var i: usize = 0; i < sides.size(); ++i {
            var unsafe *o = dyn_cast<BinaryOperatorExpr>(sides[i])
            if o == &null {
                continue
            }

            var k = o->op_token.kind
            if k != TokenKind::OpPlus && k != TokenKind::OpMinus {
                continue
            }

            if self.dyn()->is_parenthesized(o) {
                continue
            }

            var w = self.dyn()->diag->report(
                DiagID::S085W,
                o->range.start,
                "'+' and '-' bind tighter than '&' in a 'derives' clause; parenthesize to say which you mean",
            )

            w.first(o->range)
            w.insert(o->range.start, "(", "insert '('")
            w.insert(o->range.end, ")", "insert ')'")
            w.emit()
        }
    }

    /// A single member cannot be removed from a composition (`X - fn goo`):
    /// requirements come and go by whole interface.
    priv fn _reject_member_removal(self, at: SourceRange) {
        self.dyn()->diag->report(
            DiagID::S086E,
            at.start,
            "a 'derives' clause composes whole interfaces; a single member cannot be removed. "
            "Declare an interface with that member and subtract it",
        ).first(at)->emit()
    }

    /// The type a name, a `::` path or a generic application denotes, as the
    /// type parser would have built it: a ChainType, one segment per name,
    /// each with its generic arguments. Null for any other expression.
    priv fn _expr_as_type(self, e: unsafe *Expr) -> unsafe *Type {
        var segs = cxx::std::vector<ChainType::ChainSegment>()
        if isa<NamedIdentExpr>(e) {
            self._push_segment(
                &segs,
                cast<NamedIdentExpr>(e)->name,
                cast<NamedIdentExpr>(e)->generic_args,
                e->range,
                ChainType::SegmentSeparator::None,
            )
        } else if isa<ChainExpr>(e) {
            var unsafe *ch   = cast<ChainExpr>(e)
            var unsafe *base = dyn_cast<NamedIdentExpr>(ch->base)
            if base == &null {
                return &null
            }

            self._push_segment(
                &segs,
                base->name,
                base->generic_args,
                base->range,
                ChainType::SegmentSeparator::None,
            )

            for var i: usize = 0; i < ch->steps.size(); ++i {
                var unsafe *st = ch->steps.get(i)
                if st->access_kind != ChainExpr::AccessKind::ColonColon
                    || st->is_operator()
                    || st->name == &null {
                    return &null
                }

                self._push_segment(
                    &segs,
                    st->name->name,
                    st->generic_args,
                    st->range,
                    ChainType::SegmentSeparator::ColonColon,
                )
            }
        } else {
            return &null
        }

        var buf = self.dyn()->ctx->alloc_array<ChainType::ChainSegment>(segs.size())
        for var i: usize = 0; i < segs.size(); ++i {
            buf[i] = segs[i]
        }

        var ct = ChainType::create(self.dyn()->ctx, e->range)
        ct->segments.from_raw(buf, segs.size())
        return ct
    }

    priv fn _push_segment(self,
                          @inout out: cxx::std::vector<ChainType::ChainSegment>,
                          name:       Token,
                          args:       FrozenList<ChainType::GenericArg>,
                          range:      SourceRange,
                          sep:        ChainType::SegmentSeparator) {
        var seg = ChainType::ChainSegment{}
        seg.name          = NamedIdentExpr::create(self.dyn()->ctx, name.range, name)
        seg.generic_args  = args
        seg.resolved_type = &null
        seg.resolved_decl = &null
        seg.range         = range
        seg.sep           = sep
        seg.seg_kind = if (args.size() > 0) => (ChainType::SegmentKind::GenericApp)
                       else => ChainType::SegmentKind::Named
        out.push_back(seg)
    }

    /// \brief rejects a `where` clause on a type declaration. `where` is
    ///        runtime-conditional dispatch, which only free functions/methods
    ///        support; type instantiation and interface conformance are
    ///        compile-time only and must use `requires`. Consumes and discards
    ///        the offending clause so parsing can recover into the body.
    priv fn _reject_where_on_type(self, const kind_word: string) {
        // On its own line too (where.mdx writes `class <T> Buffer` and then
        // `where ...` under it): the newline must not hide the clause, or it
        // reaches the body parser as a stray `where`.
        if !self._peek_past_nl(TokenKind::KwWhere) {
            return
        }

        var wh = self._cur_range()
        self.dyn()->diag->report(
            DiagID::S045E,
            wh.start,
            f"'where' is not allowed on a {kind_word}; runtime-conditional "
            "dispatch is only valid on functions. Use 'requires' for a "
            "compile-time constraint instead",
        ).first(wh)->fix(wh, "requires", "use 'requires'")->emit()
        self.dyn()->advance(T::SkipNL::After) // consume `where`
        var _discard = self.dyn()->parse_expr(self.dyn()->stop_on(T::ExprStopKind::NoStructLiteral)) // eat + drop the clause
    }

    /// \brief parses the `derives ...` and `impl ...` clauses in either order,
    ///        filling the provided edge buffers. Either may be absent.
    priv fn _parse_class_heritage(
        self,
        derives_out: unsafe *kairo::std::StackBuf<Declarations::InheritEdge, 4>,
        impl_out:    unsafe *kairo::std::StackBuf<Declarations::InheritEdge, 4>,
    ) {
        while true {
            // heritage clauses may sit on their own continuation line:
            //     class StreamCursor
            //       derives ImportGrammar<StreamCursor> { ... }
            // neither keyword can begin a declaration, so a newline in front of
            // them is never ambiguous with the start of a new one.
            if self.dyn()->nl_depth == 0 && self.dyn()->ig_kind() == TokenKind::TkNewLine {
                var hk = self.dyn()->peek_past_nl_kind()
                if hk == TokenKind::KwDerives || hk == TokenKind::KwImpl {
                    self.dyn()->advance(T::SkipNL::Only)
                }
            }

            if self.dyn()->check(TokenKind::KwDerives) {
                self._parse_inherit_edges(&*derives_out)
                continue
            }

            if self.dyn()->check(TokenKind::KwImpl) {
                self._parse_inherit_edges(&*impl_out)
                continue
            }

            break
        }
    }

    //  Type-scope body  { fields, methods, nested types }

    /// \brief parses a braced member body into the given DeclContext owner,
    ///        collecting fields and methods into the supplied buffers.
    ///  Grammar:  '{' (field | method | nested-decl | visibility-group)* '}'
    ///
    /// \param allow_methods  false for structs/unions (no in-body methods).
    /// \details pushes no scope of its own the caller owns scope lifetime;
    ///          this only routes members. Nested type decls are appended to
    ///          the owner's dc_decls via add_decl.
    /// \brief index-mode type-body walk: parses member decls shallowly (every
    ///        production cuts after its head in index mode) and lands them in
    ///        \p owner->dc_decls so the post-parse hoist recursion
    ///        (ASTParse::_index_hoist_decl) can insert them under the type's
    ///        scope-path segment. Anything that is not a decl lead-in is
    ///        token-skipped never walked into.
    ///
    /// \pre the opening `{` is consumed (via _index_skip_to_body).
    /// \post the closing `}` is consumed if present.
    priv fn _index_walk_body(self, owner: *DeclContext) {
        var prev_idx: usize = 0
        var have_prev       = false

        while !self.dyn()->is_eof() && !self.dyn()->check(TokenKind::OpRBrace) {
            // progress guard (same rationale as _parse_member_body).
            if have_prev && self.dyn()->c_idx == prev_idx {
                self.dyn()->advance()
                continue
            }

            prev_idx  = self.dyn()->c_idx
            have_prev = true

            if self.dyn()->check(TokenKind::TkNewLine)
                || self.dyn()->check(TokenKind::OpSemicolon) {
                self.dyn()->advance()
                continue
            }

            var k = self.dyn()->resolve_kind_deep(self.dyn()->current_ptr())
            if self._starts_decl_here(k) {
                var unsafe *d = self.parse_decl()
                if d == &null {
                    self.dyn()->_index_skip_stmt()
                } else if !self.is_fatal_decl(d) {
                    owner->add_decl(d)
                }
            } else {
                self.dyn()->_index_skip_stmt()
            }
        }

        if self.dyn()->check(TokenKind::OpRBrace) {
            self.dyn()->advance(T::SkipNL::Before) // consume `}`
        }
    }

    /// \brief true if `fd` names the type it is declared in, i.e. it is a
    ///        constructor rather than a named method.
    ///
    /// \details identifiers are interned per file, so the enclosing type's name
    ///          and a ctor's name share an imm - the same test the symbol
    ///          indexer uses to key a decl as DeclName::ctor().
    priv fn _is_ctor_of(self, fd: unsafe *Declarations::FunctionDecl, owner_name: Token) -> bool {
        if fd->is_operator {
            return false
        }

        var fn_imm    = self.dyn()->ctx->get_ident_imm(fd->name)
        var owner_imm = self.dyn()->ctx->get_ident_imm(owner_name)
        if fn_imm == u32::MAX || owner_imm == u32::MAX {
            return false
        }

        return fn_imm == owner_imm
    }

    /// \param owner_name the enclosing type's name, used to tell a constructor
    ///        from a named method in bodies that forbid the latter. Pass an
    ///        empty Token where the distinction does not apply (extensions).
    priv fn _parse_member_body(
        self,
        owner:         unsafe *DeclContext,
        owner_name:    Token,
        fields_out:    unsafe *kairo::std::StackBuf<unsafe *Declarations::FieldDecl, 8>,
        methods_out:   unsafe *kairo::std::StackBuf<unsafe *Declarations::FunctionDecl, 8>,
        allow_methods: bool,
    ) -> bool {
        if self.dyn()->is_eof() {
            // No token to point at: anchor on the last one read.
            var pr = self.dyn()->prev().range
            self.dyn()->diag->report(
                DiagID::S048E,
                pr.start,
                "expected '{' to begin the type body",
            ).first(pr)->emit()
            return false
        }

        if !self.dyn()->check(TokenKind::OpLBrace) {
            var r = self._cur_range()
            self.dyn()->diag->report(
                DiagID::S048E,
                r.start,
                "expected '{' to begin the type body",
            ).first(r)->emit()
            return false
        }

        self.dyn()->advance(T::SkipNL::After) // consume `{`

        var field_idx: u32   = 0
        var prev_idx:  usize = 0
        var have_prev        = false

        while !self.dyn()->is_eof() && !self.dyn()->check(TokenKind::OpRBrace) {
            // progress guard: if the previous iteration consumed nothing - a
            // recovery path whose `_sync_decl` stopped on a member-start token
            // it could not parse (e.g. a `fn` in a method-less body) - force a
            // single advance so a malformed member can never spin the parser.
            if have_prev && self.dyn()->c_idx == prev_idx {
                self.dyn()->advance()
                continue
            }

            prev_idx  = self.dyn()->c_idx
            have_prev = true

            if self.dyn()->check(TokenKind::TkNewLine)
                || self.dyn()->check(TokenKind::OpSemicolon) {
                self.dyn()->advance()
                continue
            }

            // leading annotations on a member (doc comments, @attr, visibility)
            var m_annot: T::PendingAnnotations
            self.dyn()->consume_leading_annotations(unsafe &m_annot)

            // annotations can run to EOF (`class C { @`): the missing `}` is
            // reported after the loop, there is no member left to dispatch.
            if self.dyn()->is_eof() || self.dyn()->check(TokenKind::OpRBrace) {
                break
            }

            var k = self.dyn()->resolve_kind_deep(self.dyn()->current_ptr())

            // visibility group inside a type body: members route through the
            // normal field/method paths with the group's visibility stamped.
            if (k == TokenKind::KwPub || k == TokenKind::KwPriv || k == TokenKind::KwProt)
                && self.dyn()->check_peek(TokenKind::OpLBrace) {
                var grp_annot = !m_annot.empty()
                if grp_annot {
                    self.dyn()->report_tok(
                        DiagID::S048E,
                        self.dyn()->current_ptr(),
                        "annotations and attributes cannot be applied to a visibility group; "
                        "apply them to individual members instead",
                    )
                }

                self._parse_member_vis_group(
                    owner,
                    owner_name,
                    &*fields_out,
                    &*methods_out,
                    allow_methods,
                    unsafe &field_idx,
                )

                continue
            }

            // `eval if` / `eval for`: before the field lead, which `eval`
            // also opens. Its branches are statements, not members of this
            // type (DeclParse::_parse_eval_stmt_decl).
            if k == TokenKind::KwEval
                && (self.dyn()->check_peek(TokenKind::KwIf)
                    || self.dyn()->check_peek(TokenKind::KwFor)) {
                var unsafe *ev = self._parse_eval_stmt_decl()
                if ev != &null && !self.is_fatal_decl(ev) {
                    self.dyn()->apply_annotations_to_decl(ev, unsafe &m_annot)
                    owner->add_decl(ev)
                }

                continue
            }

            // method lead: `fn`, possibly behind static/virtual/override/final/
            // inline/eval. The lookahead is what separates `static fn f()` from
            // the `static x: T` field that shares its keyword.
            var is_method_lead = self._mods_lead_to_fn(false)

            if is_method_lead && allow_methods {
                var lead = self._consume_leading_modifiers(false)
                if self.dyn()->check(TokenKind::KwFn) {
                    var unsafe *m = self._parse_function(unsafe &lead)
                    if m != &null && isa<Declarations::FunctionDecl>(m) {
                        var unsafe *fm = cast<Declarations::FunctionDecl>(m)
                        self.dyn()->apply_annotations_to_decl(
                            unsafe (fm as unsafe *Decl),
                            unsafe &m_annot,
                        )

                        methods_out->push_back(fm)
                    }
                } else {
                    var r = self._cur_range()
                    self.dyn()->diag->report(
                        DiagID::S048E,
                        r.start,
                        "expected 'fn' after method modifiers",
                    ).first(r)->emit()
                    self._sync_decl_progress(Self::DeclSyncCtx::TypeBody)
                }

                continue
            }

            // Function member in a struct/union body. These bodies admit
            // constructors and operator overloads but no *named* functions, so
            // the member is always parsed in full - dropping tokens would
            // desync the body and turn one bad member into a cascade - and only
            // the named-function case is rejected, for exactly one diagnostic.
            if is_method_lead {
                var        mr   = self._cur_range()
                var        lead = self._consume_leading_modifiers(false)
                var unsafe *m   = self._parse_function(unsafe &lead)
                if m != &null && isa<Declarations::FunctionDecl>(m) {
                    var unsafe *fm = cast<Declarations::FunctionDecl>(m)
                    if fm->is_operator || self._is_ctor_of(fm, owner_name) {
                        self.dyn()->apply_annotations_to_decl(
                            unsafe (fm as unsafe *Decl),
                            unsafe &m_annot,
                        )

                        methods_out->push_back(fm)
                    } else {
                        self.dyn()->diag->report(DiagID::S048E, mr.start,
                            "a struct or union body cannot contain a named function; "
                            "only fields, nested types, constructors, and operator "
                            "overloads are permitted"
                        ).first(mr)
                         // No location: same span as the error, so a second
                         // caret is noise. Plain text reads better.
                         .note(DiagCode(DiagID::S048N),
                            "move it into an 'extend' block on this type, or declare "
                            "the type as a 'class' if it needs methods"
                         )->emit()
                    }
                }

                continue
            }

            // nested type decl
            if k == TokenKind::KwClass
                || k == TokenKind::KwStruct
                || k == TokenKind::KwEnum
                || k == TokenKind::KwUnion
                || k == TokenKind::KwInterface
                || k == TokenKind::KwType {
                var unsafe *nested = self._dispatch_decl()
                if nested != &null && !self.is_fatal_decl(nested) {
                    self.dyn()->apply_annotations_to_decl(nested, unsafe &m_annot)
                    owner->add_decl(nested)
                }

                continue
            }

            // field: mutable? var/const/static/eval ...
            var is_field_lead = k == TokenKind::KwVar
                || k == TokenKind::KwConst
                || k == TokenKind::KwStatic
                || k == TokenKind::KwEval
                || k == TokenKind::KwThread
                || k == TokenKind::KwMutable

            if is_field_lead {
                var unsafe *f = self._parse_field(field_idx)
                if !is_recovery(unsafe (f as unsafe *Decl)) {
                    self.dyn()->apply_annotations_to_decl(
                        unsafe (f as unsafe *Decl),
                        unsafe &m_annot,
                    )

                    fields_out->push_back(f)
                    ++field_idx
                } else {
                    self._sync_decl_progress(Self::DeclSyncCtx::TypeBody)
                }

                continue
            }

            // unknown member lead recover.
            var r = self._cur_range()
            self.dyn()->diag->report(
                DiagID::S048E,
                r.start,
                "expected a field, method, or nested type in the type body",
            ).first(r)->emit()
            self._sync_decl(Self::DeclSyncCtx::TypeBody)
        }

        if self.dyn()->check(TokenKind::OpRBrace) {
            self.dyn()->advance(T::SkipNL::Before) // consume `}`
            return true
        }

        self.dyn()->diag->report(
            DiagID::S048E,
            self.dyn()->prev().range.start,
            "expected '}' to close the type body",
        ).first(self.dyn()->prev().range)->emit()
        return false
    }

    //  Class

    /// \brief parses a class declaration.
    ///  Grammar:  'final'? 'class' generics? name (derives ...)? (impl ...)? body
    priv fn _parse_class(self, lead: unsafe *Self::LeadMods) -> unsafe *Decl {
        var start = if (lead->any) => (lead->range) else => self._cur_range()

        if !self.dyn()->enter_depth() {
            return Declarations::ClassDecl::create_error(self.dyn()->ctx, start)
        }

        self.dyn()->advance(T::SkipNL::After) // consume `class`

        // a class name may itself carry generics or a specialization marker:
        //   `class <T> Foo`     -> type params
        //   `class <> Box<T>`   -> primary via specialization form (#68)
        //   `class <> Box<i32>` -> explicit specialization
        //   `class <> Box<[T]>` -> partial specialization
        var gparams: kairo::std::StackBuf<unsafe *Declarations::GenericParamDecl, 2>
        var cls_intro: Declarations::SpecKind = Declarations::SpecKind::None
        self._parse_generic_or_spec_intro(unsafe &gparams, &cls_intro)
        var has_generics = !gparams.is_empty()

        if !self.dyn()->check_is_ident() {
            self.dyn()->diag->report(DiagID::S046E, start.start, "expected class name").first(
                start,
            )->emit()
            self.dyn()->exit_depth()
            self._sync_decl(Self::DeclSyncCtx::TopLevel)
            return (Declarations::ClassDecl::create_error(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
            ))
        }

        var name = self.dyn()->current()
        self.dyn()->advance()

        var cd: *Declarations::ClassDecl = Declarations::ClassDecl::create(
            self.dyn()->ctx,
            start,
            name,
            self.dyn()->scope.current_dc(),
        )

        cd->is_final = lead->is_final
        if has_generics {
            cd->generic_params.from_buf(gparams.data(), gparams.size(), self.dyn()->ctx)
        }

        // specialization argument pattern after the name: `Box<T>`, `Box<[T]>`.
        // classes/structs/unions accept primary, explicit, and partial. (#68)
        if (cls_intro != Declarations::SpecKind::None || has_generics)
            && self.dyn()->check(TokenKind::OpLess) {
            var sargs: kairo::std::StackBuf<unsafe *Type, 4>
            self._parse_spec_args(&sargs)
            cd->spec_args.from_buf(sargs.data(), sargs.size(), self.dyn()->ctx)
            cd->spec_kind = self._classify_record_spec(unsafe &sargs, unsafe &gparams)
        } else if cls_intro != Declarations::SpecKind::None {
            self.dyn()->diag->report(
                DiagID::S049E,
                name.range.start,
                "expected specialization arguments '<...>' after the name "
                "following the '<>' specialization marker",
            ).first(name.range)->emit()
        }

        // index mode: token-skip heritage/requires to the body (no type or
        // expression parsing against the half-built table), then walk members
        // shallowly into dc_decls for the hoist recursion.
        if self.dyn()->mode == T::ParseMode::Index {
            if self.dyn()->_index_skip_to_body() {
                self._index_walk_body(cd)
            }

            cd->range = start | self.dyn()->prev().range
            self.dyn()->exit_depth()
            return unsafe (cd as unsafe *Decl)
        }

        // heritage
        var dlist: kairo::std::StackBuf<Declarations::InheritEdge, 4>
        var ilist: kairo::std::StackBuf<Declarations::InheritEdge, 4>
        self._parse_class_heritage(unsafe &dlist, unsafe &ilist)
        cd->derives_list.from_buf(dlist.data(), dlist.size(), self.dyn()->ctx)
        cd->implements.from_buf(ilist.data(), ilist.size(), self.dyn()->ctx)

        // optional requires
        if self._peek_past_nl(TokenKind::KwRequires) {
            self.dyn()->advance(T::SkipNL::After)
            var req = self.dyn()->parse_expr(self.dyn()->stop_on(T::ExprStopKind::NoStructLiteral))
            if req != &null && !is_recovery(req) {
                cd->requires_clause = req
            }
        }

        self._reject_where_on_type("class")

        // body, or a bodyless forward declaration (`class Foo`). A `{` opens the
        // definition; anything else leaves `cd` a forward declaration (a
        // non-definition redecl link) for FFI / mutually-recursive types.
        if self.dyn()->check(TokenKind::OpLBrace) {
            self.dyn()->enter_scope(ScopeKind::Block, cd)
            var fields:  kairo::std::StackBuf<unsafe *Declarations::FieldDecl, 8>
            var methods: kairo::std::StackBuf<unsafe *Declarations::FunctionDecl, 8>
            self._parse_member_body(cd, name, &fields, &methods, true)
            cd->fields.from_buf(fields.data(), fields.size(), self.dyn()->ctx)
            cd->methods.from_buf(methods.data(), methods.size(), self.dyn()->ctx)

            // A `virtual fn` with no body is pure virtual, and its class
            // abstract (a bodyless method that is not virtual stays a
            // declaration). FnBodyKind::Virtual is what every later stage
            // reads: TypeUtil's polymorphism, ClassLifecycle, the `= 0`.
            for var i: usize = 0; i < cd->methods.size(); ++i {
                var unsafe *m = cd->methods[i]
                if m->abi == Declarations::AbiKind::Virtual
                    && m->body_kind == Declarations::FnBodyKind::None {
                    m->body_kind = Declarations::FnBodyKind::Virtual
                }

                if m->body_kind == Declarations::FnBodyKind::Virtual {
                    cd->is_abstract = true
                }
            }

            cd->mark_definition()
            self.dyn()->exit_scope()
        }

        cd->range = start | self.dyn()->prev().range
        self.dyn()->exit_depth()
        return unsafe (cd as unsafe *Decl)
    }

    //  Struct

    /// \brief parses a struct declaration.
    ///  Grammar:  'struct' generics? name (impl ...)? body?  (no methods in-body; no body = forward decl)
    priv fn _parse_struct(self) -> unsafe *Decl {
        var start = self._cur_range()

        if !self.dyn()->enter_depth() {
            return Declarations::StructDecl::create_error(self.dyn()->ctx, start)
        }

        self.dyn()->advance(T::SkipNL::After) // consume `struct`

        var gparams: kairo::std::StackBuf<unsafe *Declarations::GenericParamDecl, 2>
        var struct_intro: Declarations::SpecKind = Declarations::SpecKind::None
        self._parse_generic_or_spec_intro(unsafe &gparams, &struct_intro)
        var has_generics = !gparams.is_empty()

        if !self.dyn()->check_is_ident() {
            self.dyn()->diag->report(DiagID::S046E, start.start, "expected struct name").first(
                start,
            )->emit()
            self.dyn()->exit_depth()
            self._sync_decl(Self::DeclSyncCtx::TopLevel)
            return (Declarations::StructDecl::create_error(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
            ))
        }

        var name = self.dyn()->current()
        self.dyn()->advance()

        var sd: *Declarations::StructDecl = Declarations::StructDecl::create(
            self.dyn()->ctx,
            start,
            name,
            self.dyn()->scope.current_dc(),
        )

        if has_generics {
            sd->generic_params.from_buf(gparams.data(), gparams.size(), self.dyn()->ctx)
        }

        // Specialization argument pattern (#68). Two heads reach it:
        //   `<> Name<i32>`  - the explicit/full specialization marker.
        //   `<P> Name<*P>`  - a PARTIAL specialization: the param list binds
        //                     the pattern variables, the post-name args give
        //                     the pattern. Without the second form SpecKind::
        //                     Partial would be unreachable from the grammar.
        // A bare `Name<i32>` with neither head is still not a specialization.
        if (struct_intro != Declarations::SpecKind::None || has_generics)
            && self.dyn()->check(TokenKind::OpLess) {
            var sargs: kairo::std::StackBuf<unsafe *Type, 4>
            self._parse_spec_args(&sargs)
            sd->spec_args.from_buf(sargs.data(), sargs.size(), self.dyn()->ctx)
            sd->spec_kind = self._classify_record_spec(unsafe &sargs, unsafe &gparams)
        } else if struct_intro != Declarations::SpecKind::None {
            self.dyn()->diag->report(
                DiagID::S049E,
                name.range.start,
                "expected specialization arguments '<...>' after the name "
                "following the '<>' specialization marker",
            ).first(name.range)->emit()
        }

        // index mode: see _parse_class.
        if self.dyn()->mode == T::ParseMode::Index {
            if self.dyn()->_index_skip_to_body() {
                self._index_walk_body(sd)
            }

            sd->range = start | self.dyn()->prev().range
            self.dyn()->exit_depth()
            return unsafe (sd as unsafe *Decl)
        }

        // structs take only `impl` (no derives).
        var ilist: kairo::std::StackBuf<Declarations::InheritEdge, 4>
        while self.dyn()->check(TokenKind::KwImpl) {
            self._parse_inherit_edges(&ilist)
        }

        sd->implements.from_buf(ilist.data(), ilist.size(), self.dyn()->ctx)

        if self._peek_past_nl(TokenKind::KwRequires) {
            self.dyn()->advance(T::SkipNL::After)
            var req = self.dyn()->parse_expr(self.dyn()->stop_on(T::ExprStopKind::NoStructLiteral))
            if req != &null && !is_recovery(req) {
                sd->requires_clause = req
            }
        }

        self._reject_where_on_type("struct")

        // No `{`: a forward declaration (`struct Node`), like a bodiless
        // class -- a non-definition link N(a) merges with the definition
        // wherever it sits in the scope. Under ffi (`ffi "c" struct
        // timezone`) it may instead name the header's tag
        // (ImportResolution::_bind_ffi_forwards keys on the ffi linkage,
        // not on the missing body).
        if !self.dyn()->check(TokenKind::OpLBrace) {
            sd->range = start | self.dyn()->prev().range
            self.dyn()->exit_depth()
            return unsafe (sd as unsafe *Decl)
        }

        self.dyn()->enter_scope(ScopeKind::Block, sd)
        var fields:  kairo::std::StackBuf<unsafe *Declarations::FieldDecl, 8>
        var methods: kairo::std::StackBuf<unsafe *Declarations::FunctionDecl, 8> // ctors + operators only
        self._parse_member_body(sd, name, &fields, &methods, false)
        sd->fields.from_buf(fields.data(), fields.size(), self.dyn()->ctx)
        sd->methods.from_buf(methods.data(), methods.size(), self.dyn()->ctx)

        sd->mark_definition()
        sd->range = start | self.dyn()->prev().range
        self.dyn()->exit_scope()
        self.dyn()->exit_depth()
        return unsafe (sd as unsafe *Decl)
    }

    //  Union

    /// \brief parses a union declaration.
    ///  Grammar:  'union' generics? name body?   (fields only, no methods; no body = forward decl)
    priv fn _parse_union(self) -> unsafe *Decl {
        var start = self._cur_range()

        if !self.dyn()->enter_depth() {
            return Declarations::UnionDecl::create_error(self.dyn()->ctx, start)
        }

        self.dyn()->advance(T::SkipNL::After) // consume `union`

        var gparams: kairo::std::StackBuf<unsafe *Declarations::GenericParamDecl, 2>
        var union_intro: Declarations::SpecKind = Declarations::SpecKind::None
        self._parse_generic_or_spec_intro(unsafe &gparams, &union_intro)
        var has_generics = !gparams.is_empty()

        if !self.dyn()->check_is_ident() {
            self.dyn()->diag->report(DiagID::S046E, start.start, "expected union name").first(
                start,
            )->emit()
            self.dyn()->exit_depth()
            self._sync_decl(Self::DeclSyncCtx::TopLevel)
            return (Declarations::UnionDecl::create_error(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
            ))
        }

        var name = self.dyn()->current()
        self.dyn()->advance()

        var ud: *Declarations::UnionDecl = Declarations::UnionDecl::create(
            self.dyn()->ctx,
            start,
            name,
            self.dyn()->scope.current_dc(),
        )

        if has_generics {
            ud->generic_params.from_buf(gparams.data(), gparams.size(), self.dyn()->ctx)
        }

        // Specialization argument pattern (#68). Two heads reach it:
        //   `<> Name<i32>`  - the explicit/full specialization marker.
        //   `<P> Name<*P>`  - a PARTIAL specialization: the param list binds
        //                     the pattern variables, the post-name args give
        //                     the pattern. Without the second form SpecKind::
        //                     Partial would be unreachable from the grammar.
        // A bare `Name<i32>` with neither head is still not a specialization.
        if (union_intro != Declarations::SpecKind::None || has_generics)
            && self.dyn()->check(TokenKind::OpLess) {
            var sargs: kairo::std::StackBuf<unsafe *Type, 4>
            self._parse_spec_args(&sargs)
            ud->spec_args.from_buf(sargs.data(), sargs.size(), self.dyn()->ctx)
            ud->spec_kind = self._classify_record_spec(unsafe &sargs, unsafe &gparams)
        } else if union_intro != Declarations::SpecKind::None {
            self.dyn()->diag->report(
                DiagID::S049E,
                name.range.start,
                "expected specialization arguments '<...>' after the name "
                "following the '<>' specialization marker",
            ).first(name.range)->emit()
        }

        // index mode: see _parse_class.
        if self.dyn()->mode == T::ParseMode::Index {
            if self.dyn()->_index_skip_to_body() {
                self._index_walk_body(ud)
            }

            ud->range = start | self.dyn()->prev().range
            self.dyn()->exit_depth()
            return unsafe (ud as unsafe *Decl)
        }

        // No `{`: a forward declaration (`union Payload`); see _parse_struct.
        if !self.dyn()->check(TokenKind::OpLBrace) {
            ud->range = start | self.dyn()->prev().range
            self.dyn()->exit_depth()
            return unsafe (ud as unsafe *Decl)
        }

        self.dyn()->enter_scope(ScopeKind::Block, ud)
        var fields:  kairo::std::StackBuf<unsafe *Declarations::FieldDecl, 8>
        var methods: kairo::std::StackBuf<unsafe *Declarations::FunctionDecl, 8> // ctors + operators only
        self._parse_member_body(ud, name, &fields, &methods, false)
        ud->fields.from_buf(fields.data(), fields.size(), self.dyn()->ctx)
        ud->methods.from_buf(methods.data(), methods.size(), self.dyn()->ctx)

        ud->mark_definition()
        ud->range = start | self.dyn()->prev().range
        self.dyn()->exit_scope()
        self.dyn()->exit_depth()
        return unsafe (ud as unsafe *Decl)
    }

    //  Interface

    /// \brief parses an interface declaration.
    ///  Grammar:  'interface' generics? name (derives ...)? '{' sig* '}'
    ///    sig := method/operator/ctor/static signature (no body)
    priv fn _parse_interface(self) -> unsafe *Decl {
        var start = self._cur_range()

        if !self.dyn()->enter_depth() {
            return Declarations::InterfaceDecl::create_error(self.dyn()->ctx, start)
        }

        self.dyn()->advance(T::SkipNL::After) // consume `interface`

        var gparams:     kairo::std::StackBuf<unsafe *Declarations::GenericParamDecl, 2>
        var has_generics                                                                 = false
        if self.dyn()->check(TokenKind::OpLess) {
            self._parse_generic_params(&gparams)
            has_generics = true
        }

        if !self.dyn()->check_is_ident() {
            self.dyn()->diag->report(DiagID::S046E, start.start, "expected interface name").first(
                start,
            )->emit()
            self.dyn()->exit_depth()
            self._sync_decl(Self::DeclSyncCtx::TopLevel)
            return (Declarations::InterfaceDecl::create_error(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
            ))
        }

        var name = self.dyn()->current()
        self.dyn()->advance()

        var id: *Declarations::InterfaceDecl = Declarations::InterfaceDecl::create(
            self.dyn()->ctx,
            start,
            name,
            self.dyn()->scope.current_dc(),
        )

        if has_generics {
            id->generic_params.from_buf(gparams.data(), gparams.size(), self.dyn()->ctx)
        }

        // index mode: see _parse_class.
        if self.dyn()->mode == T::ParseMode::Index {
            if self.dyn()->_index_skip_to_body() {
                self._index_walk_body(id)
            }

            id->range = start | self.dyn()->prev().range
            self.dyn()->exit_depth()
            return unsafe (id as unsafe *Decl)
        }

        // interface composition via `derives <expr>`. `impl` is accepted for
        // recovery only: an interface that composes others conforms to
        // nothing, it derives.
        var dlist: kairo::std::StackBuf<Declarations::InheritEdge, 4>
        if self.dyn()->check(TokenKind::KwImpl) {
            var it = self._cur_range()
            var b = self.dyn()->diag->report(
                DiagID::S087E,
                it.start,
                "an interface derives from other interfaces; 'impl' is for a type that conforms to one",
            )

            b.first(it)
            b.fix(it, "derives", "replace 'impl' with 'derives'")
            b.emit()
        }

        if self.dyn()->check(TokenKind::KwDerives) || self.dyn()->check(TokenKind::KwImpl) {
            if !self._parse_derives_expr(id, unsafe &dlist) {
                self._sync_to_body()
            }
        }

        id->derives_list.from_buf(dlist.data(), dlist.size(), self.dyn()->ctx)

        if self._peek_past_nl(TokenKind::KwRequires) {
            self.dyn()->advance(T::SkipNL::After)
            var req = self.dyn()->parse_expr(self.dyn()->stop_on(T::ExprStopKind::NoStructLiteral))
            if req != &null && !is_recovery(req) {
                id->requires_clause = req
            }
        }

        self._reject_where_on_type("interface")

        // body: method signatures (bodies are a sema error; parser still
        // accepts a body for recovery via _parse_member_body's method path,
        // which yields FunctionDecls with body_kind set sema rejects bodies).
        self.dyn()->enter_scope(ScopeKind::Block, id)
        var fields:  kairo::std::StackBuf<unsafe *Declarations::FieldDecl, 8> // sema rejects fields in interfaces
        var methods: kairo::std::StackBuf<unsafe *Declarations::FunctionDecl, 8>
        self._parse_member_body(id, name, &fields, &methods, true)
        id->methods.from_buf(methods.data(), methods.size(), self.dyn()->ctx)

        id->mark_definition()
        id->range = start | self.dyn()->prev().range
        self.dyn()->exit_scope()
        self.dyn()->exit_depth()
        return unsafe (id as unsafe *Decl)
    }

    //  Extension

    /// \brief parses an extension declaration.
    ///  Grammar:  'extend' generics? type (impl ...)? '{' (method|static)* '}'
    priv fn _parse_extension(self) -> unsafe *Decl {
        var start = self._cur_range()

        if !self.dyn()->enter_depth() {
            return Declarations::ExtensionDecl::create_error(self.dyn()->ctx, start)
        }

        self.dyn()->advance(T::SkipNL::After) // consume `extend`

        // `extend <T> Foo` introduces type params; `extend <> Foo<bool>` is the
        // full-specialization marker, exactly as on struct/class/fn. Unlike
        // those, the specialization arguments live in the *target type*
        // (`Foo<bool>`) rather than after a name, so there is no separate
        // _parse_spec_args step here.
        var gparams: kairo::std::StackBuf<unsafe *Declarations::GenericParamDecl, 2>
        var ext_intro: Declarations::SpecKind = Declarations::SpecKind::None
        self._parse_generic_or_spec_intro(unsafe &gparams, &ext_intro)
        var has_generics = !gparams.is_empty()

        var target = self.dyn()->parse_type()
        if target == &null || is_recovery(target) {
            self.dyn()->diag->report(
                DiagID::S053E,
                start.start,
                "expected a type to extend after 'extend'",
            ).first(start)->emit()
            self.dyn()->exit_depth()
            self._sync_decl(Self::DeclSyncCtx::TopLevel)
            return (Declarations::ExtensionDecl::create_error(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
            ))
        }

        var ed: *Declarations::ExtensionDecl = Declarations::ExtensionDecl::create(
            self.dyn()->ctx,
            start,
            target,
            self.dyn()->scope.current_dc(),
        )

        if has_generics {
            ed->generic_params.from_buf(gparams.data(), gparams.size(), self.dyn()->ctx)
        }

        ed->spec_kind = ext_intro

        var ilist: kairo::std::StackBuf<Declarations::InheritEdge, 4>
        while self.dyn()->check(TokenKind::KwImpl) {
            self._parse_inherit_edges(&ilist)
        }

        ed->implements.from_buf(ilist.data(), ilist.size(), self.dyn()->ctx)

        // A specialized extension is constrained the same way its type is:
        //   extend <P> NS<P> requires is_ptr<P>() { ... }
        // Without this the clause parsed as a stray expression and took the
        // whole body down with it.
        if self._peek_past_nl(TokenKind::KwRequires) {
            self.dyn()->advance(T::SkipNL::After)
            var req = self.dyn()->parse_expr(self.dyn()->stop_on(T::ExprStopKind::NoStructLiteral))
            if req != &null && !is_recovery(req) {
                ed->requires_clause = req
            }
        }

        self.dyn()->enter_scope(ScopeKind::Block, ed)
        var fields:  kairo::std::StackBuf<unsafe *Declarations::FieldDecl, 8> // not valid in extends; sema rejects
        var methods: kairo::std::StackBuf<unsafe *Declarations::FunctionDecl, 8>
        self._parse_member_body(
            unsafe (ed as unsafe *DeclContext),
            Token(),
            unsafe &fields,
            unsafe &methods,
            true,
        )

        ed->methods.from_buf(methods.data(), methods.size(), self.dyn()->ctx)

        ed->range = start | self.dyn()->prev().range
        self.dyn()->exit_scope()
        self.dyn()->exit_depth()
        return unsafe (ed as unsafe *Decl)
    }

    //  Enum

    /// \brief parses an enum declaration.
    ///  Grammar:  'enum' generics? name ('derives' int_type)? ('requires' expr)? '{' variant* '}'
    ///    variant := name ('=' const_expr)?                  (plain)
    ///             | name '{' field (',' field)* '}'         (ADT payload)
    priv fn _parse_enum(self) -> unsafe *Decl {
        var start = self._cur_range()

        if !self.dyn()->enter_depth() {
            return unsafe (Declarations::EnumDecl::create_error(self.dyn()->ctx, start) as unsafe *Decl)
        }

        self.dyn()->advance(T::SkipNL::After) // consume `enum`

        var gparams:     kairo::std::StackBuf<unsafe *Declarations::GenericParamDecl, 2>
        var has_generics                                                                 = false
        if self.dyn()->check(TokenKind::OpLess) {
            self._parse_generic_params(&gparams)
            has_generics = true
        }

        if !self.dyn()->check_is_ident() {
            self.dyn()->diag->report(DiagID::S046E, start.start, "expected enum name").first(
                start,
            )->emit()
            self.dyn()->exit_depth()
            self._sync_decl(Self::DeclSyncCtx::TopLevel)
            return unsafe (Declarations::EnumDecl::create_error(self.dyn()->ctx, start | self.dyn()->prev().range) as unsafe *Decl)
        }

        var name = self.dyn()->current()
        self.dyn()->advance()

        var en = Declarations::EnumDecl::create(
            self.dyn()->ctx,
            start,
            name,
            self.dyn()->scope.current_dc(),
        )

        if has_generics {
            en->generic_params.from_buf(gparams.data(), gparams.size(), self.dyn()->ctx)
        }

        // index mode: variants are not decls and are not hoisted; skip the
        // `derives` clause and the whole body.
        if self.dyn()->mode == T::ParseMode::Index {
            if self.dyn()->_index_skip_to_body() {
                self.dyn()->_index_skip_block()
            }

            en->range = start | self.dyn()->prev().range
            self.dyn()->exit_depth()
            return unsafe (en as unsafe *Decl)
        }

        // `derives <int type>` underlying type (NOT inheritance for enums).
        if self.dyn()->check(TokenKind::KwDerives) {
            self.dyn()->advance(T::SkipNL::After) // consume `derives`
            var uty = self.dyn()->parse_type()
            if uty != &null && !is_recovery(uty) {
                en->underlying = uty
            }
        }

        // `enum <T> Compact requires sizeof T <= 8 { ... }` (requires.mdx,
        // Requires on Types), on its own line too, as a class's. Without it
        // the clause parsed as a stray expression and took the body with it.
        if self._peek_past_nl(TokenKind::KwRequires) {
            self.dyn()->advance(T::SkipNL::After)
            var req = self.dyn()->parse_expr(self.dyn()->stop_on(T::ExprStopKind::NoStructLiteral))
            if req != &null && !is_recovery(req) {
                en->requires_clause = req
            }
        }

        self._reject_where_on_type("enum")

        // forward decl: `enum Foo derives u8` with no body.
        if !self.dyn()->check(TokenKind::OpLBrace) {
            en->range = start | self.dyn()->prev().range
            self.dyn()->exit_depth()
            return unsafe (en as unsafe *Decl)
        }

        self.dyn()->advance(T::SkipNL::After) // consume `{`

        var variants: kairo::std::StackBuf<unsafe *Declarations::EnumVariantDecl, 8>
        var vidx:     u32                                                            = 0
        var any_adt                                                                  = false

        while !self.dyn()->is_eof() && !self.dyn()->check(TokenKind::OpRBrace) {
            if self.dyn()->check(TokenKind::TkNewLine) || self.dyn()->check(TokenKind::OpComma) {
                self.dyn()->advance()
                continue
            }

            var v_annot: T::PendingAnnotations
            self.dyn()->consume_leading_annotations(unsafe &v_annot)
            if self.dyn()->check(TokenKind::OpRBrace) {
                break
            }

            var unsafe *v = self._parse_enum_variant(vidx)
            if v == &null {
                self._sync_decl_progress(Self::DeclSyncCtx::TypeBody)
                continue
            }

            self.dyn()->apply_annotations_to_decl(unsafe (v as unsafe *Decl), unsafe &v_annot)
            if v->is_adt() {
                any_adt = true
            }

            variants.push_back(v)
            ++vidx

            if self.dyn()->check(TokenKind::OpComma) {
                self.dyn()->advance(T::SkipNL::After)
                continue
            }

            if self.dyn()->check(TokenKind::TkNewLine) {
                self.dyn()->advance(T::SkipNL::Only)
                continue
            }

            break
        }

        en->variants.from_buf(variants.data(), variants.size(), self.dyn()->ctx)
        en->is_adt = any_adt

        if self.dyn()->check(TokenKind::OpRBrace) {
            self.dyn()->advance(T::SkipNL::Before) // consume `}`
        } else {
            self.dyn()->diag->report(
                DiagID::S048E,
                start.start,
                "expected '}' to close the enum body",
            ).first(start)->emit()
        }

        en->mark_definition()
        en->range = start | self.dyn()->prev().range
        self.dyn()->exit_depth()
        return unsafe (en as unsafe *Decl)
    }

    /// \brief parses one enum variant (plain or ADT-payload).
    priv fn _parse_enum_variant(self, idx: u32) -> unsafe *Declarations::EnumVariantDecl {
        if !self.dyn()->check_is_ident() {
            var r = self._cur_range()
            self.dyn()->diag->report(
                DiagID::S048E,
                r.start,
                "expected variant name in enum body",
            ).first(r)->emit()
            return &null
        }

        var name  = self.dyn()->current()
        var start = name.range
        self.dyn()->advance()

        var v = Declarations::EnumVariantDecl::create(self.dyn()->ctx, start, name, idx)

        // ADT payload: `Found { key: K, value: V }`
        if self.dyn()->check(TokenKind::OpLBrace) {
            self.dyn()->advance(T::SkipNL::After) // consume `{`
            var pf:   kairo::std::StackBuf<unsafe *Declarations::FieldDecl, 4>
            var fidx: u32                                                      = 0
            while !self.dyn()->is_eof() && !self.dyn()->check(TokenKind::OpRBrace) {
                if self.dyn()->check(TokenKind::TkNewLine)
                    || self.dyn()->check(TokenKind::OpComma) {
                    self.dyn()->advance()
                    continue
                }

                // payload fields are `name: Type` (no var/const keyword).
                self.dyn()->_reject_mode_binding()
                if !self.dyn()->check_is_ident() {
                    break
                }

                var fname  = self.dyn()->current()
                var fstart = fname.range
                self.dyn()->advance()
                if !self.dyn()->check(TokenKind::OpColon) {
                    self.dyn()->diag->report(
                        DiagID::S048E,
                        fstart.start,
                        "expected ':' and a type in enum variant payload",
                    ).first(fstart)->emit()
                    break
                }

                self.dyn()->advance(T::SkipNL::After) // consume `:`
                var fty = self.dyn()->parse_type()
                if fty == &null || is_recovery(fty) {
                    break
                }

                var fd = Declarations::FieldDecl::create(
                    self.dyn()->ctx,
                    fstart | self.dyn()->prev().range,
                    fname,
                    Declarations::StorageClass::Var,
                    fty,
                    fidx,
                )

                pf.push_back(fd)
                ++fidx
                if self.dyn()->check(TokenKind::OpComma) {
                    self.dyn()->advance(T::SkipNL::After)
                    continue
                }

                break
            }

            if self.dyn()->check(TokenKind::OpRBrace) {
                self.dyn()->advance()
            }

            v->payload.from_buf(pf.data(), pf.size(), self.dyn()->ctx)
        } // explicit discriminant: `= <const expr>`
        else if self.dyn()->check(TokenKind::OpEqual) {
            self.dyn()->advance(T::SkipNL::After) // consume `=`
            var disc = self.dyn()->parse_expr(self.dyn()->stop_on(T::ExprStopKind::StopComma))
            if disc != &null && !is_recovery(disc) {
                v->discriminant = disc
            }
        }

        // A pack-expanded variant, `Err { e: E }...`: one variant per element
        // of the pack its payload names. A nullary `V...` is read too, so
        // Sema can say why it means nothing (VariadicEnumCheck).
        if self.dyn()->check(TokenKind::OpEllipsis) {
            v->is_pack_expansion = true
            v->pack_range        = self._cur_range()
            self.dyn()->advance()
        }

        v->range = start | self.dyn()->prev().range
        return v
    }

    //  Type alias

    /// \brief parses a type alias.
    ///  Grammar:  'type' generics? name '=' type
    priv fn _parse_type_alias(self) -> unsafe *Decl {
        var start = self._cur_range()
        self.dyn()->advance(T::SkipNL::After) // consume `type`

        var gparams:     kairo::std::StackBuf<unsafe *Declarations::GenericParamDecl, 2>
        var has_generics                                                                 = false
        if self.dyn()->check(TokenKind::OpLess) {
            self._parse_generic_params(&gparams)
            has_generics = true
        }

        if !self.dyn()->check_is_ident() {
            self.dyn()->diag->report(
                DiagID::S046E,
                start.start,
                "expected alias name after 'type'",
            ).first(start)->emit()
            self._sync_decl(Self::DeclSyncCtx::TopLevel)
            return (Declarations::TypeAliasDecl::create_error(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
            ))
        }

        var name = self.dyn()->current()
        self.dyn()->advance()

        // index mode: the name and generics are all the table needs; the
        // aliased type is sema's business. Node carries a null `aliased`.
        if self.dyn()->mode == T::ParseMode::Index {
            var ita = Declarations::TypeAliasDecl::create(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
                name,
                &null,
            )

            if has_generics {
                ita->generic_params.from_buf(gparams.data(), gparams.size(), self.dyn()->ctx)
            }

            self.dyn()->_index_skip_stmt()
            return ita
        }

        // Inside an interface, `type N` is an ASSOCIATED type
        // (interfaces.md, "Associated Types"): `=` gives its default and is
        // optional, and `impl X, Y` bounds it. Anywhere else it is an alias,
        // `=` is required and `impl` has no meaning.
        var cur                   = self.dyn()->scope.current_dc()
        var in_iface              = cur != &null && cur->dc_kind == DeclContextKind::Interface
        var bounds:  unsafe *Expr = &null
        if self.dyn()->check(TokenKind::KwImpl) {
            if !in_iface {
                var it = self._cur_range()
                self.dyn()->diag->report(
                    DiagID::S088E,
                    it.start,
                    "'impl' bounds an associated type, which is only declared inside an interface",
                ).first(it)->emit()
                self._sync_decl(Self::DeclSyncCtx::TopLevel)
                return (Declarations::TypeAliasDecl::create_error(
                    self.dyn()->ctx,
                    start | self.dyn()->prev().range,
                ))
            }

            bounds = self._parse_assoc_bounds(name)
            if bounds == &null {
                return (Declarations::TypeAliasDecl::create_error(
                    self.dyn()->ctx,
                    start | self.dyn()->prev().range,
                ))
            }
        }

        var aliased: unsafe *Type = &null
        if self.dyn()->check(TokenKind::OpEqual) {
            self.dyn()->advance(T::SkipNL::After) // consume `=`
            aliased = self.dyn()->parse_type()
            if aliased == &null || is_recovery(aliased) {
                return (Declarations::TypeAliasDecl::create_error(
                    self.dyn()->ctx,
                    start | self.dyn()->prev().range,
                ))
            }
        } else if !in_iface {
            var b = self.dyn()->diag->report(
                DiagID::S050E,
                start.start,
                "expected '=' in type alias declaration",
            )

            b.first(start)
            b.note(
                start.start,
                "a 'type' with no '=' is an associated type, which is only declared inside an interface",
            )

            b.emit()
            self._sync_decl(Self::DeclSyncCtx::TopLevel)
            return (Declarations::TypeAliasDecl::create_error(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
            ))
        }

        var ta = Declarations::TypeAliasDecl::create(
            self.dyn()->ctx,
            start | self.dyn()->prev().range,
            name,
            aliased,
        )

        ta->is_associated   = in_iface
        ta->requires_clause = bounds
        if has_generics {
            ta->generic_params.from_buf(gparams.data(), gparams.size(), self.dyn()->ctx)
        }

        return ta
    }

    /// `impl X, Y` on associated type \p name: its bounds as the requires
    /// clause every bound is, `N impl X && N impl Y` (ConstraintExpr
    /// conjuncts), so ConstraintExtraction partitions them as it does any
    /// decl's. Null after a diagnostic.
    priv fn _parse_assoc_bounds(self, name: Token) -> unsafe *Expr {
        var impl_tok = self.dyn()->current()
        self.dyn()->advance(T::SkipNL::After) // consume `impl`
        var clause: unsafe *Expr = &null
        while true {
            var ty = self.dyn()->parse_type()
            if ty == &null || is_recovery(ty) {
                self.dyn()->diag->report(
                    DiagID::S083E,
                    self._cur_range().start,
                    "expected an interface after 'impl'",
                ).first(self._cur_range())->emit()
                return &null
            }

            var lhs = NamedIdentExpr::create(self.dyn()->ctx, name.range, name)
            var c = unsafe (ConstraintExpr::create(self.dyn()->ctx, name.range | ty->range, lhs, ty, impl_tok) as unsafe *Expr)
            if clause == &null {
                clause = c
            } else {
                var and_tok = self.dyn()->ctx->make_token(ty->range, TokenKind::OpAmpAmp, "&&")
                clause = (BinaryOperatorExpr::create(
                    self.dyn()->ctx,
                    clause->range | c->range,
                    clause,
                    c,
                    and_tok,
                ))
            }

            if self.dyn()->check(TokenKind::OpComma) {
                self.dyn()->advance(T::SkipNL::After)
                continue
            }

            break
        }

        return clause
    }

    //  Module

    /// \brief parses a module declaration.
    ///  Grammar:  'inline'? 'module' name? '{' decl* '}'
    priv fn _parse_module(self) -> unsafe *Decl {
        var start = self._cur_range()

        if !self.dyn()->enter_depth() {
            return Declarations::ModuleDecl::create_error(self.dyn()->ctx, start)
        }

        var is_inline = false
        // `inline` may precede `module` (rare; the dispatcher routes KwInline
        // to the stmt path normally, but a module-inline reaches here when the
        // caller pre-checked). Defensive handling:
        if self.dyn()->check(TokenKind::KwInline) {
            is_inline = true
            self.dyn()->advance(T::SkipNL::After)
        }

        self.dyn()->advance(T::SkipNL::After) // consume `module`

        var name_tok = Token()
        var anon     = true
        if self.dyn()->check(TokenKind::LitIdentifier) {
            name_tok = self.dyn()->current()
            anon     = false
            self.dyn()->advance()
        }

        var md: *Declarations::ModuleDecl = Declarations::ModuleDecl::create(
            self.dyn()->ctx,
            start,
            name_tok,
            self.dyn()->scope.current_dc(),
        )

        md->is_inline    = is_inline
        md->is_anonymous = anon

        if !self.dyn()->check(TokenKind::OpLBrace) {
            self.dyn()->diag->report(
                DiagID::S050E,
                start.start,
                "expected '{' to begin module body",
            ).first(start)->emit()
            self.dyn()->exit_depth()
            self._sync_decl(Self::DeclSyncCtx::TopLevel)
            return (Declarations::ModuleDecl::create_error(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
            ))
        }

        self.dyn()->advance(T::SkipNL::After) // consume `{`

        self.dyn()->enter_scope(ScopeKind::Block, md)

        while !self.dyn()->is_eof() && !self.dyn()->check(TokenKind::OpRBrace) {
            if self.dyn()->check(TokenKind::TkNewLine)
                || self.dyn()->check(TokenKind::OpSemicolon) {
                self.dyn()->advance()
                continue
            }

            var unsafe *inner = self.parse_decl()
            if inner == &null {
                break
            }

            if self.is_fatal_decl(inner) {
                break
            }

            (unsafe (md as unsafe *DeclContext))->add_decl(inner)
        }

        if self.dyn()->check(TokenKind::OpRBrace) {
            self.dyn()->advance(T::SkipNL::Before) // consume `}`
        } else {
            self.dyn()->diag->report(
                DiagID::S051E,
                start.start,
                "expected '}' to close module body",
            ).first(start)->emit()
        }

        md->mark_definition()
        md->range = start | self.dyn()->prev().range
        self.dyn()->exit_scope()
        self.dyn()->exit_depth()
        return unsafe (md as unsafe *Decl)
    }

    //  Test

    /// \brief parses a test declaration.
    ///  Grammar:  'test' string_literal block
    priv fn _parse_test(self) -> unsafe *Decl {
        var start = self._cur_range()
        self.dyn()->advance(T::SkipNL::After) // consume `test`

        var td: *Declarations::TestDecl = Declarations::TestDecl::create(
            self.dyn()->ctx,
            start,
            self.dyn()->scope.current_dc(),
        )

        // index mode: tests contribute nothing to the table; skip wholesale.
        if self.dyn()->mode == T::ParseMode::Index {
            self.dyn()->_index_skip_stmt()
            td->range = start | self.dyn()->prev().range
            return unsafe (td as unsafe *Decl)
        }

        if self.dyn()->check(TokenKind::LitString) {
            var s_tok = self.dyn()->current()
            td->label = StringLiteralExpr::create(
                self.dyn()->ctx,
                s_tok.range,
                s_tok,
                FlagSet<StringLiteralExpr::StringKind, u8>(),
            )

            self.dyn()->advance(T::SkipNL::After)
        }

        if !self.dyn()->check(TokenKind::OpLBrace) {
            self.dyn()->diag->report(
                DiagID::S050E,
                start.start,
                "expected '{' to begin test body",
            ).first(start)->emit()
            self._sync_decl(Self::DeclSyncCtx::TopLevel)
            return (Declarations::TestDecl::create_error(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
            ))
        }

        self.dyn()->enter_scope(ScopeKind::Function, td)
        td->body = self.dyn()->parse_compound()
        self.dyn()->exit_scope()

        td->range = start | self.dyn()->prev().range
        return unsafe (td as unsafe *Decl)
    }

    //  Macro (token macro vs proc/attribute macro)

    /// \brief parses a macro declaration.
    ///  Grammar:  'macro' ( name '!' '(' params? ')' '{' raw '}'      (token macro)
    ///                     | '@' name '(' typed_params? ')' block )   (proc macro)
    priv fn _parse_macro(self) -> unsafe *Decl {
        var start = self._cur_range()

        // dispatch invariant, not a user error: this production is only ever
        // entered on `macro` (including the `macro @proc` form, which is
        // dispatched below AFTER `macro` is consumed). ICE-with-report instead
        // of a compiled-out assert so release builds fail loudly instead of
        // mis-parsing.
        if !self.dyn()->check(TokenKind::KwMacro) {
            self.dyn()->diag->report(
                DiagID::I002F,
                start.start,
                f"internal: _parse_macro entered on '{token_kind_to_readable_string(self.dyn()->current().kind)}', expected 'macro '",
            ).first(start)->emit()
            self._sync_decl(Self::DeclSyncCtx::TopLevel)
            return Declarations::MacroDecl::create_error(self.dyn()->ctx, start)
        }

        self.dyn()->advance(T::SkipNL::After) // consume `macro`

        if self.dyn()->check(TokenKind::OpAt) {
            return self._parse_proc_macro(start)
        }

        var hdr = self.dyn()->parse_macro_header()
        if !hdr.ok {
            self._sync_decl(Self::DeclSyncCtx::TopLevel)
            return (Declarations::MacroDecl::create_error(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
            ))
        }

        var mac = Declarations::MacroDecl::create(self.dyn()->ctx, start, hdr.name)

        // step 1: keep MacroDecl's existing lossy Token param list pure
        // adapter, zero node changes. step 2 swaps this block for
        // FrozenList<MacroParamSpec>.
        var params: cxx::std::vector<Declarations::MacroParamSpec>
        for var i: usize = 0; i < hdr.params.size(); ++i {
            if hdr.params[i].variadic != 0 {
                mac->is_variadic = true
            }

            if hdr.params[i].variadic != 2 {
                var sp = Declarations::MacroParamSpec{}
                sp.name     = hdr.params[i].name
                sp.variadic = hdr.params[i].variadic
                params.push_back(sp)
            }
        }

        mac->params_spec.from_buf(params.data(), params.size(), self.dyn()->ctx)

        // body: unchanged from current implementation (brace-balance, span)
        if !self.dyn()->check(TokenKind::OpLBrace) {
            self.dyn()->diag->report(
                DiagID::S050E,
                start.start,
                "expected '{' to begin macro body",
            ).first(start)->emit()
            self._sync_decl(Self::DeclSyncCtx::TopLevel)
            return (Declarations::MacroDecl::create_error(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
            ))
        }

        self.dyn()->advance()
        var body_start     = self._cur_range()
        var body_end       = body_start
        var depth:     u32 = 1
        while !self.dyn()->is_eof() && depth > 0 {
            var k = self.dyn()->ig_kind()
            if k == TokenKind::OpLBrace {
                depth += 1
            } else if k == TokenKind::OpRBrace {
                depth -= 1
                if depth == 0 {
                    break
                }
            }

            body_end = self._cur_range()
            self.dyn()->advance()
        }

        if self.dyn()->check(TokenKind::OpRBrace) {
            self.dyn()->advance(T::SkipNL::Before)
        }

        mac->body_span = body_start | body_end
        mac->range     = start | self.dyn()->prev().range
        return mac
    }

    /// \brief parses a procedural / attribute macro `macro @name(...) { }`.
    priv fn _parse_proc_macro(self, start: SourceRange) -> unsafe *Decl {
        self.dyn()->advance() // consume `@`
        if !self.dyn()->check_is_ident() {
            self.dyn()->diag->report(
                DiagID::S046E,
                start.start,
                "expected name after 'macro @'",
            ).first(start)->emit()
            self._sync_decl(Self::DeclSyncCtx::TopLevel)
            return (Declarations::ProcedureMacroDecl::create_error(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
            ))
        }

        var name = self.dyn()->current()
        self.dyn()->advance()

        var pm: *Declarations::ProcedureMacroDecl = Declarations::ProcedureMacroDecl::create(
            self.dyn()->ctx,
            start,
            name,
            self.dyn()->scope.current_dc(),
        )

        // index mode: proc-macro bodies are full statement blocks; skip them.
        // (Token macros run their normal production its body is a raw
        // brace-balanced span, no expression parsing.)
        if self.dyn()->mode == T::ParseMode::Index {
            self.dyn()->_index_skip_stmt()
            pm->range = start | self.dyn()->prev().range
            return unsafe (pm as unsafe *Decl)
        }

        self.dyn()->enter_scope(ScopeKind::Function, pm)

        // typed param list (reuse the function param parser shape)
        if self.dyn()->check(TokenKind::OpLParen) {
            var params: kairo::std::StackBuf<unsafe *Declarations::ParamDecl, 4>
            self._parse_param_list(&params)
            pm->params.from_buf(params.data(), params.size(), self.dyn()->ctx)
        }

        // attribute macros transform AST in place they cannot declare a
        // return type. catch `-> T` here for a targeted message instead of
        // letting the body parser produce garbage.
        if self.dyn()->check(TokenKind::OpArrow) {
            var r = self._cur_range()
            self.dyn()->diag->report(
                DiagID::S047E,
                r.start,
                "an attribute macro cannot declare a return type; it transforms its node argument in place",
            ).first(r)->emit()
            self.dyn()->advance(T::SkipNL::After) // consume `->`
            var dead = self.dyn()->parse_type()   // consume the type for recovery
            // discard; body parse continues below
        }

        // A body is MANDATORY: unlike a function, a proc macro cannot be
        // forward-declared.
        if !self.dyn()->check(TokenKind::OpLBrace) {
            var r = self._cur_range()
            self.dyn()->diag->report(
                DiagID::S050E,
                r.start,
                "a proc macro requires a body; it cannot be forward-declared "
                "(proc macros run at compile time and must be defined before use)",
            ).first(start)->emit()
            self.dyn()->exit_scope()
            self._sync_decl(Self::DeclSyncCtx::TopLevel)
            return (Declarations::ProcedureMacroDecl::create_error(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
            ))
        }

        pm->body = self.dyn()->parse_compound()

        self.dyn()->exit_scope()
        pm->range = start | self.dyn()->prev().range
        return unsafe (pm as unsafe *Decl)
    }

    //  Import

    /// \brief parses an import declaration.
    ///  Grammar:
    ///    'import' (('self' | 'module') '::')? path
    ///      ('::' '{' import_item (',' import_item)* '}')?
    ///      ('::' '*')?
    ///      ('as' name)?
    ///    path        := identifier ('::' identifier)*
    ///    import_item := sub_path ('as' name)? | '*'
    ///    sub_path    := identifier ('::' identifier)*
    ///
    /// \details resolution semantics (enforced by the import resolution pass,
    ///          not the parser):
    ///    `import Foo`         the search roots (libraries, -I, std, builtin)
    ///    `import self::Foo`   the importing file's own directory
    ///    `import module::Foo` the importing file's module root (nearest module.k)
    ///    each in one place: Foo.k or Foo/module.k there, both is an error
    ///    `import Foo::bar`    resolve Foo, then find symbol bar
    ///    `import module Foo`  removed (S089E, fix-it drops `module`)
    fn _parse_import(self) -> unsafe *Decl {
        var start = self._cur_range()

        var spec = self.dyn()->parse_import_spec()
        if !spec.ok {
            self._sync_decl(Self::DeclSyncCtx::TopLevel)
            return (Declarations::ImportDecl::create_error(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
            ))
        }

        var id = Declarations::ImportDecl::create(self.dyn()->ctx, spec.range, spec.kind)

        // base path
        var segs: kairo::std::StackBuf<Token, 8>
        for var i: usize = 0; i < spec.segments.size(); ++i {
            segs.push_back(spec.segments[i])
        }

        id->path_segments.from_buf(segs.data(), segs.size(), self.dyn()->ctx)
        id->last_seg_is_macro = spec.last_seg_is_macro // NEW field, see below
        id->is_wildcard       = spec.is_wildcard

        // selective items
        if spec.has_items {
            var items: kairo::std::StackBuf<Declarations::ImportItem, 8>
            for var i: usize = 0; i < spec.items.size(); ++i {
                var s                                   = &spec.items[i]
                var item                                = Declarations::ImportItem{}
                var sub: kairo::std::StackBuf<Token, 4>
                for var j: usize = 0; j < s->sub_path.size(); ++j {
                    sub.push_back(s->sub_path[j])
                }

                item.sub_path.from_buf(sub.data(), sub.size(), self.dyn()->ctx)
                item.alias       = s->alias
                item.has_alias   = s->has_alias
                item.is_wildcard = s->is_wildcard
                item.is_macro    = s->is_macro    // NEW field, see below
                item.range       = s->range
                items.push_back(item)
            }

            id->items.from_buf(items.data(), items.size(), self.dyn()->ctx)
            id->has_items = true
        }

        id->alias     = spec.alias
        id->has_alias = spec.has_alias
        id->range     = spec.range
        return id
    }

    //  FFI

    /// \brief parses an ffi construct.
    ///  Grammar:
    ///    'ffi' string_literal 'import' string_literal ('as' name)?
    ///    'ffi' string_literal '{' decl* '}'
    ///    'ffi' string_literal decl
    ///
    /// \details
    ///   - ffi import      ImportDecl with FFILinkage stamped
    ///   - ffi { } block   FFIBlockDecl grouping N child decls, each stamped
    ///   - ffi single decl the decl itself, stamped with FFILinkage
    ///
    ///   The parser rejects decl kinds that don't carry the FFILinkage mixin
    ///   (test, macro, enum, etc.). Sema validates deeper constraints (e.g.
    ///   ffi "c" on a ClassDecl).
    fn _parse_ffi(self) -> unsafe *Decl {
        var start = self._cur_range()
        self.dyn()->advance(T::SkipNL::After) // consume `ffi`

        // language string: "c", "c++", etc.
        if !self.dyn()->check(TokenKind::LitString) {
            self.dyn()->diag->report(
                DiagID::S064E,
                start.start,
                "expected a language string after 'ffi' (e.g. \"c++\")",
            ).first(start)->emit()
            self._sync_decl(Self::DeclSyncCtx::TopLevel)
            return (Declarations::ImportDecl::create_error(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
            ))
        }

        var lang_tok = self.dyn()->current()
        var lang     = self.dyn()->parse_ffi_lang(lang_tok, start)
        self.dyn()->advance(T::SkipNL::After) // consume the language string; parse_ffi_lang only classifies, it does not advance
        var linkage_kind: LinkageKind
        match lang {
            case FFILang::C {
                linkage_kind = LinkageKind::C
            } case FFILang::Cpp {
                linkage_kind = LinkageKind::Cpp
            } default {
                self.dyn()->diag->report(
                    DiagID::S064E,
                    start.start,
                    f"unsupported FFI language, expected 'c' or 'c++'",
                ).first(start)->emit()
                self._sync_decl(Self::DeclSyncCtx::TopLevel)
                return (Declarations::ImportDecl::create_error(
                    self.dyn()->ctx,
                    start | self.dyn()->prev().range,
                ))
            }
        }

        var ffi_range = start | lang_tok.range

        /// # ffi "c++" import "header.h" (as alias)?
        if self.dyn()->check(TokenKind::KwImport) {
            self.dyn()->advance(T::SkipNL::After) // consume `import`

            if !self.dyn()->check(TokenKind::LitString) {
                self.dyn()->diag->report(
                    DiagID::S064E,
                    start.start,
                    "expected a header path string after 'ffi \"...\" import'",
                ).first(start)->emit()
                self._sync_decl(Self::DeclSyncCtx::TopLevel)
                return (Declarations::ImportDecl::create_error(
                    self.dyn()->ctx,
                    start | self.dyn()->prev().range,
                ))
            }

            var header_tok = self.dyn()->current()
            self.dyn()->advance()

            var id = Declarations::ImportDecl::create(
                self.dyn()->ctx,
                start,
                Declarations::ImportKind::Native,
            )

            id->set_ffi_linkage(linkage_kind, lang_tok, ffi_range)
            id->header = header_tok

            // optional alias: `as gfx`
            if self.dyn()->check(TokenKind::KwAs) {
                self.dyn()->advance(T::SkipNL::After) // consume `as`
                if self.dyn()->check(TokenKind::LitIdentifier) {
                    id->alias     = self.dyn()->current()
                    id->has_alias = true
                    self.dyn()->advance()
                } else {
                    self.dyn()->report_tok(
                        DiagID::S064E,
                        self.dyn()->current_ptr(),
                        "expected a name after 'as' in ffi import",
                    )
                }
            }

            id->range = start | self.dyn()->prev().range
            return id
        }

        /// # ffi "c++" { decl* }
        if self.dyn()->check(TokenKind::OpLBrace) {
            self.dyn()->advance(T::SkipNL::After) // consume `{`

            var fb = Declarations::FFIBlockDecl::create(self.dyn()->ctx, start, lang_tok)
            var decls: kairo::std::StackBuf<unsafe *Decl, 8>

            while !self.dyn()->is_eof() && !self.dyn()->check(TokenKind::OpRBrace) {
                if self.dyn()->check(TokenKind::TkNewLine)
                    || self.dyn()->check(TokenKind::OpSemicolon) {
                    self.dyn()->advance()
                    continue
                }

                self.dyn()->ffi_decl_depth = self.dyn()->ffi_decl_depth + 1
                var unsafe *d = self.parse_decl()
                self.dyn()->ffi_decl_depth = self.dyn()->ffi_decl_depth - 1
                if d == &null {
                    break
                }

                if self.is_fatal_decl(d) {
                    break
                }

                if !self._stamp_ffi_linkage(d, linkage_kind, lang_tok, ffi_range) {
                    self.dyn()->diag->report(
                        DiagID::S064E,
                        d->range.start,
                        "this declaration cannot appear in an ffi block",
                    ).first(d->range)->emit()
                }

                decls.push_back(d)
            }

            if self.dyn()->check(TokenKind::OpRBrace) {
                self.dyn()->advance(T::SkipNL::Before) // consume `}`
            } else {
                self.dyn()->diag->report(
                    DiagID::S064E,
                    start.start,
                    "expected '}' to close ffi block",
                ).first(start)->emit()
            }

            fb->body.from_buf(decls.data(), decls.size(), self.dyn()->ctx)
            fb->range = start | self.dyn()->prev().range
            return fb
        }

        /// # ffi "c++" fn foo(...)
        self.dyn()->ffi_decl_depth = self.dyn()->ffi_decl_depth + 1
        var unsafe *d = self._dispatch_decl()
        self.dyn()->ffi_decl_depth = self.dyn()->ffi_decl_depth - 1
        if d == &null || self.is_fatal_decl(d) {
            self.dyn()->diag->report(
                DiagID::S064E,
                start.start,
                "expected a declaration, 'import', or '{' after 'ffi \"...\"'",
            ).first(start)->emit()
            self._sync_decl(Self::DeclSyncCtx::TopLevel)
            return (Declarations::ImportDecl::create_error(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
            ))
        }

        if !self._stamp_ffi_linkage(d, linkage_kind, lang_tok, ffi_range) {
            self.dyn()->diag->report(
                DiagID::S064E,
                d->range.start,
                "this declaration cannot have foreign linkage",
            ).first(d->range)->emit()
        }

        return d
    }

    /// \brief stamps FFILinkage on a decl if it carries the mixin.
    /// \returns true if the stamp succeeded, false if the decl kind doesn't
    ///          support foreign linkage.
    priv fn _stamp_ffi_linkage(self,
                               d:         *Decl,
                               kind:      LinkageKind,
                               lang_tok:  Token,
                               ffi_range: SourceRange) -> bool {
        if isa<Declarations::FunctionDecl>(d) {
            cast<Declarations::FunctionDecl>(d)->set_ffi_linkage(kind, lang_tok, ffi_range)
            return true
        }

        if isa<Declarations::ClassDecl>(d) {
            cast<Declarations::ClassDecl>(d)->set_ffi_linkage(kind, lang_tok, ffi_range)
            return true
        }

        if isa<Declarations::StructDecl>(d) {
            cast<Declarations::StructDecl>(d)->set_ffi_linkage(kind, lang_tok, ffi_range)
            return true
        }

        if isa<Declarations::UnionDecl>(d) {
            cast<Declarations::UnionDecl>(d)->set_ffi_linkage(kind, lang_tok, ffi_range)
            return true
        }

        if isa<Declarations::TypeAliasDecl>(d) {
            cast<Declarations::TypeAliasDecl>(d)->set_ffi_linkage(kind, lang_tok, ffi_range)
            return true
        }

        if isa<Declarations::VariableDecl>(d) {
            cast<Declarations::VariableDecl>(d)->set_ffi_linkage(kind, lang_tok, ffi_range)
            return true
        }

        if isa<Declarations::ImportDecl>(d) {
            cast<Declarations::ImportDecl>(d)->set_ffi_linkage(kind, lang_tok, ffi_range)
            return true
        }

        return false
    }

    //  eval { decl* }  decl block

    /// \brief index mode: crosses an `eval if` / `eval for` without parsing
    ///        it. _index_skip_stmt stops at a `;` or a newline, which a C-style
    ///        `for` header and an `else` on its own line both contain: here
    ///        the header runs to the body's `{`, the body to its `}`, and an
    ///        `else` (same line or the next) continues the chain.
    priv fn _index_skip_eval_stmt(self) {
        while !self.dyn()->is_eof() {
            var depth: u32 = 0
            while !self.dyn()->is_eof() {
                var k = self.dyn()->resolve_kind_deep(self.dyn()->current_ptr())
                if depth == 0 && k == TokenKind::OpLBrace {
                    break
                }

                // no body before the enclosing closer: malformed, leave it
                if depth == 0 && k == TokenKind::OpRBrace {
                    return
                }

                if k == TokenKind::OpLParen || k == TokenKind::OpLSquare {
                    depth += 1
                } else if k == TokenKind::OpRParen || k == TokenKind::OpRSquare {
                    if depth > 0 {
                        depth -= 1
                    }
                }

                self.dyn()->advance_raw()
            }

            if self.dyn()->is_eof() {
                return
            }

            self.dyn()->advance_raw()       // `{`
            self.dyn()->_index_skip_block() // through the matching `}`

            if self.dyn()->nl_depth == 0
                && self.dyn()->ig_kind() == TokenKind::TkNewLine
                && self.dyn()->peek_past_nl_kind() == TokenKind::KwElse {
                self.dyn()->advance(T::SkipNL::Only)
            }

            if !self.dyn()->check(TokenKind::KwElse) {
                return
            }

            self.dyn()->advance_raw() // `else`
        }
    }

    /// \brief index mode: walks EVERY branch of an `eval if` chain and lands
    ///        the declarations written in them in \p out, so the hoist
    ///        recursion (ASTParse::_index_hoist_decl, EvalBlockDecl) puts
    ///        them in the disambig table as if hoisted.
    ///
    /// \details EvalIfFolding (phase E) hoists the taken branch's
    ///          declarations, so an importer's Sema sees them; but the table
    ///          built here is what the importer's PARSER asks whether
    ///          `name<T>` is generic, and is frozen long before the fold. A
    ///          branch that hoisted nothing left `pick<i32> + 1` a chain of
    ///          comparisons in every importer. Which branch is taken is not
    ///          known here, so all of them are indexed, like an overload set:
    ///          a generic in any branch makes the name generic, the same
    ///          over-approximation the full-mode symbol index makes
    ///          (ASTParse::_index_eval_branches). The header and the
    ///          condition are crossed as _index_skip_eval_stmt crosses them.
    priv fn _index_eval_if_branches(self, @inout out: kairo::std::StackBuf<unsafe *Decl, 8>) {
        while !self.dyn()->is_eof() {
            var depth: u32 = 0
            while !self.dyn()->is_eof() {
                var k = self.dyn()->resolve_kind_deep(self.dyn()->current_ptr())
                if depth == 0 && k == TokenKind::OpLBrace {
                    break
                }

                if depth == 0 && k == TokenKind::OpRBrace {
                    return
                }

                if k == TokenKind::OpLParen || k == TokenKind::OpLSquare {
                    depth += 1
                } else if k == TokenKind::OpRParen || k == TokenKind::OpRSquare {
                    if depth > 0 {
                        depth -= 1
                    }
                }

                self.dyn()->advance_raw()
            }

            if self.dyn()->is_eof() {
                return
            }

            self.dyn()->advance_raw() // `{`

            // The branch body: the loop of _index_walk_body, into \p out. A
            // nested `eval if` is a decl lead-in, so it recurses through
            // _parse_eval_stmt_decl and is hoisted from its own carrier.
            var prev_idx: usize = 0
            var have_prev       = false
            while !self.dyn()->is_eof() && !self.dyn()->check(TokenKind::OpRBrace) {
                if have_prev && self.dyn()->c_idx == prev_idx {
                    self.dyn()->advance()
                    continue
                }

                prev_idx  = self.dyn()->c_idx
                have_prev = true

                if self.dyn()->check(TokenKind::TkNewLine)
                    || self.dyn()->check(TokenKind::OpSemicolon) {
                    self.dyn()->advance()
                    continue
                }

                var k = self.dyn()->resolve_kind_deep(self.dyn()->current_ptr())
                if self._starts_decl_here(k) {
                    var unsafe *d = self.parse_decl()
                    if d == &null {
                        self.dyn()->_index_skip_stmt()
                    } else if !self.is_fatal_decl(d) {
                        out.push_back(d)
                    }
                } else {
                    self.dyn()->_index_skip_stmt()
                }
            }

            if self.dyn()->is_eof() {
                return
            }

            self.dyn()->advance_raw() // `}`

            if self.dyn()->nl_depth == 0
                && self.dyn()->ig_kind() == TokenKind::TkNewLine
                && self.dyn()->peek_past_nl_kind() == TokenKind::KwElse {
                self.dyn()->advance(T::SkipNL::Only)
            }

            if !self.dyn()->check(TokenKind::KwElse) {
                return
            }

            self.dyn()->advance_raw() // `else`
        }
    }

    /// \brief an `eval if` / `eval for` written directly in a module or class
    ///        body, carried by an EvalBlockDecl whose `stmt` is the statement.
    ///  Grammar:  'eval' ( if_stmt | for_stmt )
    ///
    /// \details the statement is the statement parser's own, so the node is
    ///          the one file scope and a function body build (a
    ///          ConditionalStmt / RangedForStmt / IndexedForStmt with
    ///          declarations as DeclStmts in its blocks). Those bodies hold
    ///          declarations only, hence the carrier. Which branch is taken,
    ///          and putting its declarations into the enclosing scope, is eval
    ///          semantics, not the parser's: here the branches' declarations
    ///          stay branch-local (eval_branch_dc keeps a module body from
    ///          absorbing them), and FeatureGateCheck reports the form as not
    ///          yet supported. Index mode walks an `eval if`'s branches into
    ///          the carrier's `body` (_index_eval_if_branches) and skips an
    ///          `eval for`, whose body hoists nothing.
    priv fn _parse_eval_stmt_decl(self) -> unsafe *Decl {
        var start = self._cur_range()
        var eb    = Declarations::EvalBlockDecl::create(self.dyn()->ctx, start)

        if self.dyn()->mode == T::ParseMode::Index {
            if self.dyn()->check_peek(TokenKind::KwIf) {
                var decls: kairo::std::StackBuf<unsafe *Decl, 8>
                self._index_eval_if_branches(&decls)
                eb->body.from_buf(decls.data(), decls.size(), self.dyn()->ctx)
                eb->range = start | self.dyn()->prev().range
                return eb
            }

            self._index_skip_eval_stmt()
            eb->range = start | self.dyn()->prev().range
            return eb
        }

        if self.dyn()->check_peek(TokenKind::KwIf) && self.dyn()->tu != &null {
            self.dyn()->tu->has_eval_if = true
        }

        var saved_dc = self.dyn()->eval_branch_dc
        self.dyn()->eval_branch_dc = self.dyn()->scope.current_dc()
        var s = self.dyn()->parse_stmt()
        self.dyn()->eval_branch_dc = saved_dc

        if s == &null || self.dyn()->is_fatal<Stmt>(s) {
            return (Declarations::EvalBlockDecl::create_error(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
            ))
        }

        eb->stmt  = s
        eb->range = start | self.dyn()->prev().range
        return eb
    }

    /// \brief parses a decl-only eval block at namespace/type scope.
    ///  Grammar:  'eval' '{' decl* '}'
    priv fn _parse_eval_block_decl(self) -> unsafe *Decl {
        var start = self._cur_range()
        self.dyn()->advance(T::SkipNL::After) // consume `eval`

        if !self.dyn()->check(TokenKind::OpLBrace) {
            self.dyn()->diag->report(DiagID::S050E, start.start, "expected '{' after 'eval'").first(
                start,
            )->emit()
            self._sync_decl(Self::DeclSyncCtx::TopLevel)
            return (Declarations::EvalBlockDecl::create_error(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
            ))
        }

        self.dyn()->advance(T::SkipNL::After) // consume `{`

        var eb = Declarations::EvalBlockDecl::create(self.dyn()->ctx, start)
        var decls: kairo::std::StackBuf<unsafe *Decl, 8>

        while !self.dyn()->is_eof() && !self.dyn()->check(TokenKind::OpRBrace) {
            if self.dyn()->check(TokenKind::TkNewLine)
                || self.dyn()->check(TokenKind::OpSemicolon) {
                self.dyn()->advance()
                continue
            }

            var unsafe *d = self.parse_decl()
            if d == &null {
                break
            }

            if self.is_fatal_decl(d) {
                break
            }

            decls.push_back(d)
        }

        if self.dyn()->check(TokenKind::OpRBrace) {
            self.dyn()->advance(T::SkipNL::Before) // consume `}`
        } else {
            self.dyn()->diag->report(
                DiagID::S051E,
                start.start,
                "expected '}' to close eval block",
            ).first(start)->emit()
        }

        eb->body.from_buf(decls.data(), decls.size(), self.dyn()->ctx)
        eb->range = start | self.dyn()->prev().range
        return eb
    }

    //  Recovery

    /// \brief consumes tokens until a declaration boundary or stop delimiter.
    /// \details delimiter-aware (tracks ()/[]/{} and <> for generics). Stops
    ///          at depth 0 on a decl lead-in keyword, a `}` closing the
    ///          enclosing scope, a newline/`;` at top level, or EOF. Capped at
    ///          MAX_SYNC tokens.
    fn _sync_decl(self, ctx: Self::DeclSyncCtx) {
        var   bp:       i32 = 0   // paren
        var   bs:       i32 = 0   // square
        var   bb:       i32 = 0   // brace
        var   ba:       i32 = 0   // angle (generics)
        var   consumed: u32 = 0
        const MAX_SYNC: u32 = 128

        while !self.dyn()->is_eof() {
            if consumed >= MAX_SYNC {
                return
            }

            ++consumed

            var k = self.dyn()->ig_kind()

            if k == TokenKind::OpLParen {
                ++bp
            } else if k == TokenKind::OpLSquare {
                ++bs
            } else if k == TokenKind::OpLBrace {
                ++bb
            } else if k == TokenKind::OpLess {
                ++ba
            } else if k == TokenKind::OpRParen {
                if bp == 0 && ctx == Self::DeclSyncCtx::Params {
                    return
                }

                if bp > 0 {
                    --bp
                }
            } else if k == TokenKind::OpRSquare {
                if bs > 0 {
                    --bs
                }
            } else if k == TokenKind::OpGreater {
                if ba == 0 && ctx == Self::DeclSyncCtx::Generics {
                    return
                }

                if ba > 0 {
                    --ba
                }
            } else if k == TokenKind::OpRBrace {
                if bb == 0 {
                    // closer of the enclosing type/module body don't consume.
                    return
                }

                --bb
            } else if bp == 0 && bs == 0 && bb == 0 && ba == 0 {
                if ctx == Self::DeclSyncCtx::Params || ctx == Self::DeclSyncCtx::Generics {
                    if k == TokenKind::OpComma {
                        return
                    }

                    if k == TokenKind::OpPipe
                        || k == TokenKind::OpPipePipe
                        || k == TokenKind::OpLBrace {
                        return
                    }
                }

                if ctx == Self::DeclSyncCtx::TopLevel {
                    if k == TokenKind::TkNewLine || k == TokenKind::OpSemicolon {
                        return
                    }

                    if self._starts_decl_here(k) {
                        return
                    }
                }

                if ctx == Self::DeclSyncCtx::TypeBody {
                    // member lead-ins inside a type body.
                    if k == TokenKind::KwFn
                        || k == TokenKind::KwVar
                        || k == TokenKind::KwConst
                        || k == TokenKind::KwStatic
                        || k == TokenKind::KwEval
                        || k == TokenKind::KwThread
                        || k == TokenKind::KwClass
                        || k == TokenKind::KwStruct
                        || k == TokenKind::KwEnum
                        || k == TokenKind::KwUnion
                        || k == TokenKind::KwInterface
                        || k == TokenKind::KwType
                        || k == TokenKind::KwOverride
                        || k == TokenKind::KwVirtual
                        || k == TokenKind::KwFinal
                        || k == TokenKind::KwMutable {
                        return
                    }
                }
            }

            self.dyn()->advance()
        }
    }

    /// Sync, then guarantee the cursor moved. For use inside recovery LOOPS:
    /// _sync_decl stops ON a boundary token without consuming it, which is
    /// correct positioning but spins a caller that retries from the same spot.
    priv fn _sync_decl_progress(self, ctx: Self::DeclSyncCtx) {
        var before = self.dyn()->current_ptr()
        self._sync_decl(ctx)
        // at EOF "no progress" is the end, not a stuck token: advancing there
        // would null out prev() too, and the caller's loop ends on is_eof().
        if self.dyn()->is_eof() {
            return
        }

        if self.dyn()->current_ptr() == before {
            self.dyn()->advance()
        }
    }

    // Closures

    /// \brief Parses a complete closure signature with structured error recovery.
    pub fn _parse_closure_sig(self) -> (FrozenList<unsafe *Declarations::ParamDecl>, FrozenList<unsafe *Declarations::GenericParamDecl>, FrozenList<ClosureExpr::Capture>, Declarations::FnModifier, unsafe *Type, bool) {
        var gparams:  kairo::std::StackBuf<unsafe *Declarations::GenericParamDecl, 2>
        var params:   kairo::std::StackBuf<unsafe *Declarations::ParamDecl, 4>
        var captures: kairo::std::StackBuf<ClosureExpr::Capture, 4>
        var ret_type:           unsafe *Type = &null
        var explicit_no_capture              = false

        // optional generic params: `fn <T> |captures| (params) -> T`
        if self.dyn()->check(TokenKind::OpLess) {
            self._parse_generic_params(&gparams)
        }

        // parameter list: `(x: i32, y: i32)`
        self.dyn()->closure_params_end = SourceRange::invalid()
        if self.dyn()->check(TokenKind::OpLParen) {
            self._parse_param_list(&params)
            if self._prev_kind() == TokenKind::OpRParen {
                self.dyn()->closure_params_end = self._prev_range()
            }
        }

        // Recovery: If parameter list parsing exited unexpectedly or left corrupt tokens,
        // synchronize up to the next logical milestone before proceeding.
        if !self.dyn()->check(TokenKind::OpPipe)
            && !self.dyn()->check(TokenKind::OpPipePipe)
            && !self.dyn()->check(TokenKind::OpArrow)
            && !self.dyn()->check(TokenKind::OpLBrace)
            && !self.dyn()->check(TokenKind::OpEqual)
            && !self._is_closure_modifier(self.dyn()->ig_kind())
            && !self.dyn()->is_eof() {
            self._sync_to_closure_milestone()
        }

        // capture list: `|a, *b|` / `|*|` / `||`
        self.dyn()->closure_cap_range = SourceRange::invalid()
        if self.dyn()->check(TokenKind::OpPipe) {
            var cap_start     = self._cur_range()
            var spelled_empty = self._parse_capture_list(&captures)
            self.dyn()->closure_cap_range = cap_start | self._prev_range()
            // `| |` is the empty list spelled apart: no captures, as `||` is.
            // Keyed on the tokens, not on captures.size(): see the callee.
            explicit_no_capture = spelled_empty
        } else if self.dyn()->check(TokenKind::OpPipePipe) {
            self.dyn()->closure_cap_range = self._cur_range()
            self.dyn()->advance() // consume `||`
            explicit_no_capture = true
        }

        // capture list: `|a, *b|` / `|*|` / `||`
        if self.dyn()->check(TokenKind::OpPipe) {
            self._parse_capture_list(&captures)
        }

        // trailing modifiers: const / unsafe / async / eval
        var modifiers = Declarations::FnModifier::None
        self.dyn()->closure_panic_set   = FrozenList<unsafe *Type>::empty()
        self.dyn()->closure_panic_range = SourceRange::invalid()
        while true {
            if self.dyn()->check(TokenKind::KwConst) {
                var r = self._cur_range()
                self.dyn()->diag->report(
                    DiagID::S047E,
                    r.start,
                    "'const' is not a valid closure modifier",
                ).first(r)->emit()
                self.dyn()->advance()
            } else if self.dyn()->check(TokenKind::KwUnsafe) {
                var r = self._cur_range()
                self.dyn()->diag->report(
                    DiagID::S047E,
                    r.start,
                    "'unsafe' is not a valid closure modifier",
                ).first(r)->emit()
                self.dyn()->advance()
            } else if self.dyn()->check(TokenKind::KwEval) {
                var r = self._cur_range()
                self.dyn()->diag->report(
                    DiagID::S047E,
                    r.start,
                    "'eval' is not a valid closure modifier",
                ).first(r)->emit()
                self.dyn()->advance()
            } else if self.dyn()->check(TokenKind::KwFinal) {
                var r = self._cur_range()
                self.dyn()->diag->report(
                    DiagID::S047E,
                    r.start,
                    "'final' is not a valid closure modifier",
                ).first(r)->emit()
                self.dyn()->advance()
            } else if self.dyn()->check(TokenKind::KwInline) {
                var r = self._cur_range()
                self.dyn()->diag->report(
                    DiagID::S047E,
                    r.start,
                    "'inline' is not a valid closure modifier",
                ).first(r)->emit()
                self.dyn()->advance()
            } else if self.dyn()->check(TokenKind::KwVirtual) {
                var r = self._cur_range()
                self.dyn()->diag->report(
                    DiagID::S047E,
                    r.start,
                    "'virtual' is not a valid closure modifier",
                ).first(r)->emit()
                self.dyn()->advance()
            } else if self.dyn()->check(TokenKind::KwOverride) {
                var r = self._cur_range()
                self.dyn()->diag->report(
                    DiagID::S047E,
                    r.start,
                    "'override' is not a valid closure modifier",
                ).first(r)->emit()
                self.dyn()->advance()
            } else if self.dyn()->check(TokenKind::KwPanic) {
                modifiers |= Declarations::FnModifier::IsPanic
                var pk = self._cur_range()
                self.dyn()->advance()
                if self.dyn()->check(TokenKind::OpLParen) {
                    var pset: kairo::std::StackBuf<unsafe *Type, 4>
                    self.dyn()->parse_panic_set(&pset)
                    self.dyn()->closure_panic_set.from_buf(
                        pset.data(),
                        pset.size(),
                        self.dyn()->ctx,
                    )
                }

                self.dyn()->closure_panic_range = pk | self._prev_range()
            } else if self.dyn()->check(TokenKind::KwVolatile) {
                modifiers |= Declarations::FnModifier::IsVolatile
                self.dyn()->advance()
            } else if self.dyn()->check(TokenKind::KwAsync) {
                modifiers |= Declarations::FnModifier::IsAsync
                self.dyn()->advance()
            } else {
                break
            }
        }

        // return type: `-> T`
        if self.dyn()->check(TokenKind::OpArrow) {
            self.dyn()->advance(T::SkipNL::After) // consume `->`
            if self.dyn()->check(TokenKind::OpExclaim) {
                self.dyn()->advance() // consume `!`, noreturn closure, sema validates
            } else {
                var rty = self.dyn()->parse_type()
                if rty != &null && !is_recovery(rty) {
                    ret_type = rty
                }
            }
        }

        var gp_list:  FrozenList<unsafe *Declarations::GenericParamDecl>
        var p_list:   FrozenList<unsafe *Declarations::ParamDecl>
        var cap_list: FrozenList<ClosureExpr::Capture>

        gp_list.from_buf(gparams.data(), gparams.size(), self.dyn()->ctx)
        p_list.from_buf(params.data(), params.size(), self.dyn()->ctx)
        cap_list.from_buf(captures.data(), captures.size(), self.dyn()->ctx)

        return (p_list, gp_list, cap_list, modifiers, ret_type, explicit_no_capture)
    }
}
