/// --- The Kairo Project --------------------------- Parser/ExprParse.k --- ///
///
///   The expression parser mixin: a Pratt parser with postfix chains.
///
///     Entry point: parse_expr() -> Pratt loop with precedence climbing.
///     Primary dispatch: parse_primary_expr() -> literals, identifiers, prefix
///     unary, parenthesized exprs, keyword exprs (sizeof, typeof, etc.).
///     Postfix loop: `_parse_postfix()` -> builds ChainExpr steps for `.`,
///     `::`, `->`, `?.`; wraps in CallExpr for `(`; wraps in SubscriptExpr for
///     `[`.
///
///     Generic disambiguation: when `<` follows an identifier, checks hoisted
///     scope for generic arity before deciding comparison vs generic args.
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
ffi "c++" import "set"
ffi "c++" import "vector"

import AST::CodeCompleteConsumer::CompletionContextKind
import AST::Context::DisambigTable::DisambigKind
import AST::Context::GlobalDisambigTable::GlobalDisambigTable
import AST::LangItems::{
    LangAttrs,
    LangIntrinsics,
}
import AST::Node::Base::{
    Expr,
    Stmt,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    is_recovery,
    isa,
}
import AST::Node::Declarations::{
    FnBodyKind,
    ImportDecl,
    StorageClass,
    VariableDecl,
}
import AST::Node::Expressions
import AST::Node::PrimaryExpressions::{
    BooleanLiteralExpr, ChainExpr,      CharacterLiteralExpr, FloatingLiteralExpr,
    IntegerLiteralExpr, NamedIdentExpr, NullLiteralExpr,      StringLiteralExpr,
}
import AST::Node::Statements::{
    BreakStmt,
    CompoundStmt,
    ContinueStmt,
    ExpressionStmt,
    MatchCase,
    ReturnStmt,
}
import AST::Node::Types::ChainType
import AST::ParamMode::ParamMode
import Diagnostic::DiagBuilder::DiagBuilder
import Diagnostic::Registry::DiagID
import Lexer::Immediate::Immediate
import Location::SourceLocation::SourceLocation
import Location::SourceRange::SourceRange
import Macro::Sentinel::MacroSentinel
import Parser::LexicalScope::ScopeKind
import Support::FlagSet::{
    FlagBit,
    FlagSet,
}
import Support::Limits::U32_MAX
import Token::Token::Token
import Token::TokenKind::{
    TokenKind,
    is_annotation,
    is_unary_operator,
    token_kind_to_readable_string,
}
import Token::TokenSpan::TokenSpan

/// \brief what, besides `;` / newline / EOF, terminates an expression: one bit
///        each. A stop set is a FlagSet of them (ExprParse<T>::ExprStop),
///        passed into parse_expr so the Pratt loop knows when to stop; the
///        empty set stops at `;` / newline / EOF only. At module scope, not
///        nested in ExprParse<T>: the FlagBit extension needs a type it can
///        name, and an enum nested in a class template is not one.
enum ExprStopBit derives u8 {
    StopAngle       = 1 << 0, ///< also stop at > >> at depth 0 (generic param defaults)
    StopParen       = 1 << 1, ///< also stop at ) at depth 0
    StopSquare      = 1 << 2, ///< also stop at ] at depth 0
    StopBrace       = 1 << 3, ///< also stop at } at depth 0
    StopComma       = 1 << 4, ///< also stop at , at depth 0
    NoStructLiteral = 1 << 5, ///< disallow { ... } struct literal parsing
}

/// ExprStopBit's variants are its FlagSet's bits (Support/FlagSet.k).
extend ExprStopBit impl FlagBit<u8> {
    inline fn bit(const self) -> u8 {
        return self as u8
    }
}

// TODO(DUCK-GENERIC): T uses _consume_mode, _is_terminator_tok, _parse_and_validate_op_spelling, _parse_closure_sig, _parse_generic_args, _parse_match_core, _peek_mode, _pending_close_angle, _reject_mode_binding, _starts_decl_kw, advance, advance_raw, ... (48). Stage 0 was duck-typed; bound it or keep `: type`.
pub class <T: type> ExprParse {
    /// \brief token kinds that can start a primary expression: identifiers,
    ///        builtins, and `self`.
    ///
    /// \details A match, not a per-parser `std::set` built in every ExprParse
    ///          and probed as a red-black tree on each test; the kinds are
    ///          hashes (no dense range for a bitset), so clang lowers this to a
    ///          compare tree over constants.
    static fn _is_expr_ident_kind(k: TokenKind) -> bool {
        match k {
            case TokenKind::LitIdentifier, TokenKind::KwSelf,   TokenKind::BiSelf,
                 TokenKind::BiFile,        TokenKind::BiLine,   TokenKind::BiColumn,
                 TokenKind::BiFunction,    TokenKind::BiModule {
                return true
            } default {
                return false
            }
        }
    }

    /// `if`/`try` expressions written inside grouping `( )`; see
    /// _was_parenthesized.
    priv var _parened_open: cxx::std::vector<unsafe *Expr>

    /// 1 + the token index at which a `try` would be the bare operand or
    /// catch-arm value of an enclosing `try`; 0 when there is none. See
    /// _parse_try_catch_expr.
    priv var _bare_try_at: usize = 0

    enum ExprSyncCtx derives u8 {
        TopLevel, ///< sync to newline, ;, EOF
        Paren,    ///< sync to ) at depth 0
        Square,   ///< sync to ] at depth 0
        Brace,    ///< sync to } at depth 0
        Comma,    ///< sync to , or closing delimiter
    }

    /// \brief one stop bit (ExprStopBit above), as the parsers name it:
    ///        `T::ExprStopKind::StopComma`.
    type ExprStopKind = ExprStopBit
    /// \brief a stop set: what tokens terminate an expression.
    type ExprStop = FlagSet<ExprStopBit, u8>

    /// \brief the stop set of \p f alone; `.plus(g)` adds more (what
    ///        `F | G` was before the enum closed).
    inline fn stop_on(self, f: Self::ExprStopKind) -> Self::ExprStop {
        return FlagSet<ExprStopBit, u8>(f)
    }

    /// \brief the empty stop set: stop at `;` / newline / EOF only.
    inline fn no_stop(self) -> Self::ExprStop {
        return FlagSet<ExprStopBit, u8>()
    }

    //  CRTP helper

    priv inline fn dyn(self) -> unsafe *T {
        return unsafe ((&self) as *T)
    }

    priv inline fn _error_expr(self, range: SourceRange) -> *Expr {
        return ChainExpr::create_error(self.dyn()->ctx, range)
    }

    /// `x.finally()` / `x.op finally()` is the explicit early destructor call,
    /// planned for 0.3. SC116E is the "not yet
    /// supported" family; reporting at the parse keeps it independent of
    /// whether the receiver ever type-checks (generic bodies included).
    priv fn _report_finally_call(self, at: SourceRange) {
        var b = self.dyn()->diag->report(
            DiagID::SC116E,
            at.start,
            "'finally()' is not implemented yet (planned for 0.3)",
        )

        b.first(at)
        b.emit()
    }

    //  Sync / recovery

    priv inline fn _sync_expr(self,
                              ctx:             Self::ExprSyncCtx,
                              paren_depth:     i32  = 0,
                              square_depth:    i32  = 0,
                              brace_depth:     i32  = 0,
                              stop_at_newline: bool = false) {
        var   balance_paren:   i32 = paren_depth
        var   balance_square:  i32 = square_depth
        var   balance_brace:   i32 = brace_depth
        var   tokens_consumed: u32 = 0
        const MAX_SYNC:        u32 = 64

        while !self.dyn()->is_eof() {
            if tokens_consumed >= MAX_SYNC {
                return
            }

            ++tokens_consumed

            var k = self.dyn()->ig_kind()

            if stop_at_newline
                && k == TokenKind::TkNewLine
                && balance_paren == 0
                && balance_square == 0
                && balance_brace == 0 {
                return
            }

            if k == TokenKind::OpLParen {
                ++balance_paren
            } else if k == TokenKind::OpLSquare {
                ++balance_square
            } else if k == TokenKind::OpLBrace {
                ++balance_brace
            } else if k == TokenKind::OpRParen {
                if balance_paren == 0 {
                    return
                }

                --balance_paren
            } else if k == TokenKind::OpRSquare {
                if balance_square == 0 {
                    return
                }

                --balance_square
            } else if k == TokenKind::OpRBrace {
                if balance_brace == 0 {
                    return
                }

                --balance_brace
            } else if balance_paren == 0 && balance_square == 0 && balance_brace == 0 {
                if k == TokenKind::OpComma {
                    if ctx == Self::ExprSyncCtx::Comma
                        || ctx == Self::ExprSyncCtx::Paren
                        || ctx == Self::ExprSyncCtx::Square {
                        return
                    }
                }

                if k == TokenKind::TkNewLine && ctx == Self::ExprSyncCtx::TopLevel {
                    return
                }

                if k == TokenKind::OpSemicolon {
                    return
                }
            }

            self.dyn()->advance()
        }
    }

    /// Sync, then guarantee the cursor moved. For use inside recovery LOOPS:
    /// _sync_expr stops ON a boundary token without consuming it, which is
    /// correct positioning but spins a caller that retries from the same spot.
    priv fn _sync_expr_progress(self,
                                ctx:             Self::ExprSyncCtx,
                                paren_depth:     i32  = 0,
                                square_depth:    i32  = 0,
                                brace_depth:     i32  = 0,
                                stop_at_newline: bool = false) {
        var before = self.dyn()->c_idx
        self._sync_expr(ctx, paren_depth, square_depth, brace_depth, stop_at_newline)
        if self.dyn()->c_idx == before {
            self.dyn()->advance()
        }
    }

    //  Entry point

    /// \brief operator precedence levels for the Pratt parser.
    ///        higher number = tighter binding.
    enum Precedence derives u8 {
        None        = 0,
        Assign      = 1,  // = += -= *= /= %= &= |= ^= <<= >>=
        Coalesce    = 2,  // ?? (right-assoc, lower than ||)
        Range       = 3,  // .. ..=
        Or          = 4,  // || or
        And         = 5,  // && and
        BitOr       = 6,  // | bitor
        BitXor      = 7,  // ^ xor
        BitAnd      = 8,  // & bitand
        Equality    = 9,  // == != ===
        Comparison  = 10, // < > <= >= <=> in
        Shift       = 11, // << >>
        Add         = 12, // + -
        Multiply    = 13, // * / %
        Power       = 14, // ^^
        PtrToMember = 15, // .* ->* ?.* ?->*
        Prefix      = 16, // unary (not used in table, just for reference)
        Postfix     = 17, // call, subscript, access (not used in table)
    }

    fn parse_expr(self, stop: Self::ExprStop = FlagSet<ExprStopBit, u8>()) -> unsafe *Expr {
        if self.dyn()->is_eof() {
            return &null
        }

        if self._should_stop(stop) {
            return &null
        }

        if !self.dyn()->enter_expr_depth() {
            return &null
        }

        var unsafe *lhs = self._parse_cast_expr(stop)
        if lhs == &null {
            self.dyn()->exit_expr_depth()
            return &null
        }

        lhs = self._parse_expr_prec(lhs, Self::Precedence::None, stop)

        self.dyn()->exit_expr_depth()
        return lhs
    }

    /// \brief A `where` guard on a function head: an expression that stops
    ///        before an assignment operator and never reads `{` as a struct
    ///        literal.
    ///
    /// Both stops are the body's: `where ok { ... }` opens the body, not
    /// `ok { ... }`, and `where x > 0 = x` is an expression body, not an
    /// assignment to `x > 0`. A guard is a bool test, so it has no use for
    /// either form, and refusing them here is what lets the head end without
    /// a separator.
    fn parse_guard_expr(self) -> unsafe *Expr {
        var stop = self.stop_on(Self::ExprStopKind::NoStructLiteral)
        if self.dyn()->is_eof() {
            return &null
        }

        if self._should_stop(stop) {
            return &null
        }

        if !self.dyn()->enter_expr_depth() {
            return &null
        }

        var unsafe *lhs = self._parse_cast_expr(stop)
        if lhs == &null {
            self.dyn()->exit_expr_depth()
            return &null
        }

        // Precedence::Assign as the floor: the loop takes only operators that
        // bind tighter, so `=` (and `+=`, ...) ends the guard.
        lhs = self._parse_expr_prec(lhs, Self::Precedence::Assign, stop)

        self.dyn()->exit_expr_depth()
        return lhs
    }

    /// \brief Pratt precedence climbing loop. Consumes binary operators
    ///        whose precedence is strictly greater than `min_prec` and
    ///        builds left-associative or right-associative BinaryOperatorExpr
    ///        / AssignOperatorExpr nodes.
    priv fn _parse_expr_prec(self,
                             lhs_in:   unsafe *Expr,
                             min_prec: Self::Precedence,
                             stop:     Self::ExprStop) -> unsafe *Expr {
        var unsafe *lhs = lhs_in

        while !self.dyn()->is_eof() {
            if self._should_stop(stop) {
                break
            }

            // -- newline continuation: an infix operator on the next line
            //    continues the expression, but only when that operator cannot
            //    also open a new statement. `is_unary_operator` covers exactly
            //    the ambiguous set (+ - * & ~ ! ++ -- .. ...): after a newline
            //    `* bar` is equally readable as a fresh statement dereferencing
            //    `bar`, so those still terminate. Mirrors the member-access
            //    rule in _parse_postfix_expr; nl_depth already suppresses this
            //    inside brackets.
            if self.dyn()->nl_depth == 0 && self.dyn()->ig_kind() == TokenKind::TkNewLine {
                var nk = self.dyn()->peek_past_nl_kind()
                if !is_unary_operator(nk) && self._infix_precedence(nk) != Self::Precedence::None {
                    self.dyn()->advance(T::SkipNL::Only)
                    continue
                }

                break // newline ends the expression
            }

            var cur_kind = self.dyn()->ig_kind()
            var prec     = self._infix_precedence(cur_kind)

            if (prec as u8) <= (min_prec as u8) {
                break
            }

            /// ### range operators .. ..=
            if cur_kind == TokenKind::OpRange || cur_kind == TokenKind::OpRangeEqual {
                lhs = self._parse_range_expr(lhs, stop)
                continue
            }

            /// ### assignment operators (right-associative)
            if self._is_assign_op(cur_kind) {
                var op_tok = self.dyn()->current()
                self.dyn()->advance(T::SkipNL::After) // consume operator

                var unsafe *rhs = self._parse_cast_expr(stop)
                if rhs == &null {
                    self.dyn()->diag->report(
                        DiagID::S052E,
                        op_tok.range.start,
                        f"expected expression after '{token_kind_to_readable_string(op_tok.kind)}'",
                    ).first(op_tok.range)->emit()
                    return lhs
                }

                // right-associative: recurse at same precedence
                rhs = self._parse_expr_prec(rhs, ((prec as u8) - 1) as u8 as Self::Precedence, stop)

                lhs = Expressions::AssignOperatorExpr::create(
                    self.dyn()->ctx,
                    lhs->range | rhs->range,
                    lhs,
                    rhs,
                    op_tok,
                )

                continue
            }

            /// ### exponentiation (right-associative)
            if cur_kind == TokenKind::OpCaretCaret {
                var op_tok = self.dyn()->current()
                self.dyn()->advance(T::SkipNL::After)

                var unsafe *rhs = self._parse_cast_expr(stop)
                if rhs == &null {
                    self.dyn()->diag->report(
                        DiagID::S052E,
                        op_tok.range.start,
                        "expected expression after '^^'",
                    ).first(op_tok.range)->emit()
                    return lhs
                }

                // right-associative: recurse at prec - 1
                rhs = self._parse_expr_prec(rhs, ((prec as u8) - 1) as u8 as Self::Precedence, stop)
                self._warn_open_operand(rhs)

                lhs = Expressions::BinaryOperatorExpr::create(
                    self.dyn()->ctx,
                    lhs->range | rhs->range,
                    lhs,
                    rhs,
                    op_tok,
                )

                continue
            }

            /// ### null-coalescing (right-associative)
            if cur_kind == TokenKind::OpQuestionQuestion {
                var op_tok = self.dyn()->current()
                self.dyn()->advance(T::SkipNL::After)
                var unsafe *rhs = self._parse_cast_expr(stop)
                if rhs == &null {
                    self.dyn()->diag->report(
                        DiagID::S052E,
                        op_tok.range.start,
                        "expected expression after '??'",
                    ).first(op_tok.range)->emit()
                    return lhs
                }

                // right-associative: recurse at prec - 1
                rhs = self._parse_expr_prec(rhs, ((prec as u8) - 1) as u8 as Self::Precedence, stop)
                self._warn_open_operand(rhs)
                lhs = Expressions::BinaryOperatorExpr::create(
                    self.dyn()->ctx,
                    lhs->range | rhs->range,
                    lhs,
                    rhs,
                    op_tok,
                )

                continue
            }

            /// ### type conformance constraint: `lhs impl/derives Type`
            /// The RHS is a TYPE, not an expression, so it is parsed with the
            /// type parser (this is what prevents `Foo` being misread as a
            /// named-initializer). Produces a bool-typed ConstraintExpr that
            /// sema partitions out of a requires conjunction.
            if cur_kind == TokenKind::KwImpl || cur_kind == TokenKind::KwDerives {
                var c_op = self.dyn()->current()
                self.dyn()->advance(T::SkipNL::After) // consume `impl` / `derives`

                var rty = self.dyn()->parse_type()
                if rty == &null || is_recovery(rty) {
                    self.dyn()->diag->report(
                        DiagID::S052E,
                        c_op.range.start,
                        f"expected an interface or base type after '{token_kind_to_readable_string(c_op.kind)}'",
                    ).first(c_op.range)->emit()
                    return lhs
                }

                lhs = (unsafe (Expressions::ConstraintExpr::create(
                    self.dyn()->ctx,
                    lhs->range | self.dyn()->prev().range,
                    lhs, rty, c_op
                ) as unsafe *Expr))
                continue
            }

            /// ### regular binary operators (left-associative)
            var op_tok = self.dyn()->current()
            self.dyn()->advance(T::SkipNL::After) // consume operator

            var unsafe *rhs = self._parse_cast_expr(stop)
            if rhs == &null {
                self.dyn()->diag->report(
                    DiagID::S052E,
                    op_tok.range.start,
                    f"expected expression after '{token_kind_to_readable_string(op_tok.kind)}'",
                ).first(op_tok.range)->emit()
                return lhs
            }

            // left-associative: recurse at current precedence (strictly greater binds tighter)
            rhs = self._parse_expr_prec(rhs, prec, stop)
            self._warn_open_operand(rhs)

            lhs = Expressions::BinaryOperatorExpr::create(
                self.dyn()->ctx,
                lhs->range | rhs->range,
                lhs,
                rhs,
                op_tok,
            )
        }

        return lhs
    }

    /// \brief parses a single primary expression for pattern position: the lead
    ///        of a range bound or a constructor head. Stops before postfix `(`,
    ///        `..`, `.` the pattern parser owns those. Returns null/recovery
    ///        on no production.
    pub fn parse_pattern_lead(self) -> unsafe *Expr {
        var unsafe *base = self._parse_primary_expr(self.no_stop())
        if base == &null {
            return &null
        }

        // accumulate `::` steps only (Direction::North), with generics.
        // stop before `(`, `..`, `.`, `[` the pattern parser owns those.
        if self.dyn()->check(TokenKind::OpColonColon) {
            var chain_steps: kairo::std::StackBuf<ChainExpr::Step, 4>
            var chain_start                                           = base->range
            while self.dyn()->check(TokenKind::OpColonColon) {
                var step = self._parse_access_step()
                if step.name == &null {
                    break
                }

                chain_steps.push_back(step)
            }

            if chain_steps.size() > 0 {
                var ce = ChainExpr::create(
                    self.dyn()->ctx,
                    chain_start | self.dyn()->prev().range,
                    base,
                )

                ce->steps.from_buf(chain_steps.data(), chain_steps.size(), self.dyn()->ctx)
                return ce
            }
        }

        return base
    }

    /// \brief after `..` / `..=`: does an upper bound follow?
    ///
    /// \details the bound is optional (`a[i..]`), so what follows decides. A
    ///          closer, `,`, `;` or a newline ends the range in every
    ///          context, and so does a keyword that can only begin a
    ///          statement. `{` ends it where a brace cannot open a literal
    ///          (an `if`/`while` condition, a `for` header): there it is the
    ///          body, and reading it as a bound took the body for an operand.
    ///          `=>` ends it as well: it introduces an arm's value and can
    ///          never begin one (`case 5.. => 1`, `if x in 0.. => a ...`).
    priv fn _range_has_upper(self, stop: Self::ExprStop) -> bool {
        if self.dyn()->is_eof() || self._should_stop(stop) {
            return false
        }

        var k = self.dyn()->ig_kind()
        if k == TokenKind::OpRParen
            || k == TokenKind::OpRSquare
            || k == TokenKind::OpRBrace
            || k == TokenKind::OpComma
            || k == TokenKind::OpSemicolon
            || k == TokenKind::TkNewLine {
            return false
        }

        if k == TokenKind::OpLBrace && stop.has(Self::ExprStopKind::NoStructLiteral) {
            return false
        }

        if k == TokenKind::KwVar
            || k == TokenKind::KwConst
            || k == TokenKind::KwReturn
            || k == TokenKind::KwBreak
            || k == TokenKind::KwContinue
            || k == TokenKind::KwFor
            || k == TokenKind::KwWhile
            || k == TokenKind::KwElse
            || k == TokenKind::KwCase
            || k == TokenKind::KwDefault
            || k == TokenKind::OpFatArrow {
            return false
        }

        return true
    }

    /// `a..=` has no meaning: inclusive of a bound that is not there.
    priv fn _inclusive_needs_upper(self, op_tok: *Token) {
        self.dyn()->report_tok(
            DiagID::S052E,
            op_tok,
            "expected an upper bound after '..='; an open range is written with '..' alone",
        )
    }

    /// \brief parses a range expression: lhs .. rhs | lhs ..= rhs
    ///        also handles prefix ranges: ..rhs | ..=rhs
    ///        range has its own precedence level and is non-associative.
    priv fn _parse_range_expr(self, lhs: unsafe *Expr, stop: Self::ExprStop) -> unsafe *Expr {
        var op_tok       = self.dyn()->current_ptr()
        var op_range     = op_tok->range
        var is_inclusive = self.dyn()->check(TokenKind::OpRangeEqual)
        // Newlines stay significant: a line ending in `..` is an open range,
        // not the left half of one whose bound is the next statement.
        self.dyn()->advance() // consume .. or ..=

        if !self._range_has_upper(stop) {
            // open-ended range: lhs..
            if is_inclusive {
                self._inclusive_needs_upper(op_tok)
            }

            return Expressions::RangeExpr::create(
                self.dyn()->ctx,
                lhs->range | op_range,
                lhs,
                &null,
                is_inclusive,
            )
        }

        var unsafe *rhs = self._parse_cast_expr(stop)
        if rhs != &null {
            // don't recurse range is non-associative (a..b..c is illegal)
            // but do parse higher-precedence ops on the rhs
            rhs = self._parse_expr_prec(rhs, Self::Precedence::Range, stop)
            self._warn_open_operand(rhs)
        }

        var end_range = if (rhs != &null) => (rhs->range) else => op_range
        return Expressions::RangeExpr::create(
            self.dyn()->ctx,
            lhs->range | end_range,
            lhs,
            rhs,
            is_inclusive,
        )
    }

    /// \brief returns the infix precedence for a token kind, or Precedence::None
    ///        if the token is not a binary operator.
    priv fn _infix_precedence(self, k: TokenKind) -> Self::Precedence {
        // assignment
        if k == TokenKind::OpEqual
            || k == TokenKind::OpPlusEqual
            || k == TokenKind::OpMinusEqual
            || k == TokenKind::OpStarEqual
            || k == TokenKind::OpSlashEqual
            || k == TokenKind::OpPercentEqual
            || k == TokenKind::OpAmpEqual
            || k == TokenKind::OpPipeEqual
            || k == TokenKind::OpCaretEqual
            || k == TokenKind::OpLessLessEqual
            || k == TokenKind::OpGreaterGreaterEqual {
            return Self::Precedence::Assign
        }

        if k == TokenKind::OpQuestionQuestion {
            return Self::Precedence::Coalesce
        }

        // range
        if k == TokenKind::OpRange || k == TokenKind::OpRangeEqual {
            return Self::Precedence::Range
        }

        // logical or
        if k == TokenKind::OpPipePipe || k == TokenKind::KwOr {
            return Self::Precedence::Or
        }

        // logical and
        if k == TokenKind::OpAmpAmp || k == TokenKind::KwAnd {
            return Self::Precedence::And
        }

        // bitwise or
        if k == TokenKind::OpPipe || k == TokenKind::KwBitor {
            return Self::Precedence::BitOr
        }

        // bitwise xor
        if k == TokenKind::OpCaret || k == TokenKind::KwXor {
            return Self::Precedence::BitXor
        }

        // bitwise and
        if k == TokenKind::OpAmp || k == TokenKind::KwBitand {
            return Self::Precedence::BitAnd
        }

        // equality
        if k == TokenKind::OpEqualEqual
            || k == TokenKind::OpExclaimEqual
            || k == TokenKind::OpEqualEqualEqual
            || k == TokenKind::KwNotEq {
            return Self::Precedence::Equality
        }

        // comparison
        if k == TokenKind::OpLess
            || k == TokenKind::OpGreater
            || k == TokenKind::OpLessEqual
            || k == TokenKind::OpGreaterEqual
            || k == TokenKind::OpLessEqualGreater {
            return Self::Precedence::Comparison
        }

        // containment: `x in xs` is `xs.op in(x)`, a relation, so it binds
        // with the comparisons. The ranged-for `in` never reaches here: the
        // for header parses a binding, not an expression, before it.
        if k == TokenKind::KwIn {
            return Self::Precedence::Comparison
        }

        // type conformance constraint (requires clauses): T impl Foo | T derives Base
        if k == TokenKind::KwImpl || k == TokenKind::KwDerives {
            return Self::Precedence::Comparison
        }

        // shift
        if k == TokenKind::OpLessLess || k == TokenKind::OpGreaterGreater {
            return Self::Precedence::Shift
        }

        // additive
        if k == TokenKind::OpPlus || k == TokenKind::OpMinus {
            return Self::Precedence::Add
        }

        // multiplicative
        if k == TokenKind::OpStar || k == TokenKind::OpSlash || k == TokenKind::OpPercent {
            return Self::Precedence::Multiply
        }

        // exponentiation
        if k == TokenKind::OpCaretCaret {
            return Self::Precedence::Power
        }

        // pointer-to-member: binds tighter than every other binary operator,
        // looser than unary. `a.*p * b` is `(a.*p) * b`; `a.*p ^^ 2` is
        // `(a.*p) ^^ 2`; `!a.*p` is `(!a).*p`, matching C++.
        //
        // NOT an access separator   `.`/`->` take an id-expression, while
        // `.*`/`->*` take a full cast-expression on the right (the C++
        // pm-expression level), which is exactly what the generic binary path
        // below already produces via _parse_cast_expr.
        if k == TokenKind::OpDotStar
            || k == TokenKind::OpArrowStar
            || k == TokenKind::OpQuestionDotStar
            || k == TokenKind::OpQuestionArrowStar {
            return Self::Precedence::PtrToMember
        }

        return Self::Precedence::None
    }

    /// \brief returns true if the token is an assignment operator.
    priv fn _is_assign_op(self, k: TokenKind) -> bool {
        return k == TokenKind::OpEqual
            || k == TokenKind::OpPlusEqual
            || k == TokenKind::OpMinusEqual
            || k == TokenKind::OpStarEqual
            || k == TokenKind::OpSlashEqual
            || k == TokenKind::OpPercentEqual
            || k == TokenKind::OpAmpEqual
            || k == TokenKind::OpPipeEqual
            || k == TokenKind::OpCaretEqual
            || k == TokenKind::OpLessLessEqual
            || k == TokenKind::OpGreaterGreaterEqual
    }

    /// \brief checks if the current token is a stop token for the given context.
    ///        returns true if the expression should terminate here.
    priv fn _should_stop(self, stop: Self::ExprStop) -> bool {
        if self.dyn()->is_eof() {
            return true
        }

        var k = self.dyn()->ig_kind()

        if k == TokenKind::OpRParen && stop.has(Self::ExprStopKind::StopParen) {
            return true
        }

        if k == TokenKind::OpRSquare && stop.has(Self::ExprStopKind::StopSquare) {
            return true
        }

        if k == TokenKind::OpRBrace && stop.has(Self::ExprStopKind::StopBrace) {
            return true
        }

        if k == TokenKind::OpComma && stop.has(Self::ExprStopKind::StopComma) {
            return true
        }

        if (k == TokenKind::OpGreater || k == TokenKind::OpGreaterGreater)
            && stop.has(Self::ExprStopKind::StopAngle) {
            return true
        }

        return false
    }

    /// \brief true if the current token continues a value expression, i.e. it is
    ///        an infix operator or a postfix opener (call/index/member).
    ///
    /// \details used by the type parser to disambiguate a value generic argument
    ///          (`Foo<i32, N + 1>`, `Foo<i32, bar()>`) from a type argument: a
    ///          clean type parse that stops here on an operator means the arg was
    ///          really a value expression that merely began with a type-shaped
    ///          token. The generic-list terminators `,` `>` `>>` are deliberately
    ///          excluded (`>`/`>>` are operators in the precedence table but here
    ///          they close the list, not continue an expression).
    pub fn at_value_expr_continuation(self) -> bool {
        var k = self.dyn()->ig_kind()

        if k == TokenKind::OpComma
            || k == TokenKind::OpGreater
            || k == TokenKind::OpGreaterGreater {
            return false
        }

        // `impl` / `derives` are constraint operators (bound/heritage/requires
        // position), never value-expression continuations. Exclude them so the
        // type parser's generic value-arg disambiguation is unaffected by their
        // presence in the infix precedence table.
        if k == TokenKind::KwImpl || k == TokenKind::KwDerives {
            return false
        }

        // postfix openers: call, subscript, member access
        if k == TokenKind::OpLParen
            || k == TokenKind::OpLSquare
            || k == TokenKind::OpDot
            || k == TokenKind::OpArrow
            || k == TokenKind::OpQuestionDot
            || k == TokenKind::OpQuestionArrow {
            return true
        }

        // any remaining infix operator (arithmetic, bitwise, logical, ...)
        return self._infix_precedence(k) != Self::Precedence::None
    }

    //  Cast expressions

    /// \brief a unary expression followed by any number of `as` casts.
    ///
    /// `as` binds looser than every prefix operator and tighter than every
    /// binary one (Rust's table), so `&x as *const T` casts the ADDRESS,
    /// `-1 as u8` casts the negated literal, and `x as i64 + 1` is
    /// `(x as i64) + 1`. While `as` was a postfix step the first two cast
    /// `x` and `1` instead and the prefix applied to the result -- a
    /// silent misparse, not an error. Nothing lower is possible anyway:
    /// the right side of `as` is a type, so no operator can follow it and
    /// still reach back over the cast.
    ///
    /// Every binary / range / assignment operand comes through here; prefix
    /// operands do not (they recurse on _parse_unary_expr), which is what
    /// puts the cast outside them.
    inline fn _parse_cast_expr(self, stop: Self::ExprStop) -> unsafe *Expr {
        var unsafe *e = self._parse_unary_expr(stop)
        if e == &null {
            return &null
        }

        while self.dyn()->check(TokenKind::KwAs) {
            // `as var`: var can't begin a type, so this is unambiguously a
            // bare context binding. Hand `as` to the statement layer.
            if self.dyn()->check_peek(TokenKind::KwVar) {
                break
            }

            // Everything else speculates: `as const`, `as (`, and plain type
            // positions are disambiguated inside _try_type_cast by the
            // trailing-`{` tiebreaker.
            var unsafe *c = self._try_type_cast(e, stop)
            if c == &null { // binding (or unparseable) -> stmt layer owns `as`
                break
            }

            e = c
        }

        return e
    }

    //  Unary expressions

    /// \brief parses an attribute applied to an expression.
    ///  Grammar:  '@' identifier ( '(' call-args? ')' )? unary-expr
    ///
    /// \details an expression attribute is an attribute like any other
    ///          (attributes.mdx, `@create T(args)`), so its head is the
    ///          declaration attribute's grammar (ASTParse::
    ///          consume_leading_annotations): a name, and an argument list
    ///          exactly when `(` follows the name.
    ///
    ///          The operand binds as a keyword prefix's does (`await`,
    ///          `thread`): one unary expression, postfix chain included. So
    ///          `@create Config(8080)` attributes the constructor call, which
    ///          is what every docs example means (`@create i32(10)`,
    ///          `@create AST::Block()`, `@create Point{ x: 1.0 }`), and
    ///          `@create Foo(1).bar` is `@create (Foo(1).bar)`: to reach the
    ///          result write `(@create Foo(1)).bar`. Binary operators bind
    ///          looser: `@a x + y` is `(@a x) + y`.
    ///
    ///          At the start of a statement the annotation pass runs first,
    ///          and leaves the `@` here only when an expression follows it on
    ///          the same line (ASTParse::_attr_opens_expr_stmt): `@destroy p`
    ///          is this production, `@likely if` and `@copy fn` are not.
    priv fn _parse_attributed_expr(self, stop: Self::ExprStop) -> unsafe *Expr {
        var at_range = self.dyn()->current_ptr()->range

        // `f(@inout x)` / `f(@move x)`: a parameter mode written at a call.
        // A mistake, not an attribute waiting for a meaning
        // (functions-parameter-modes.mdx: the call site writes `&x` / `x`),
        // so it is the binding sites' S069E with the call-site spelling as
        // the fix-it, and the operand parses as if the mode were not there.
        var mode = self.dyn()->_peek_mode()
        if mode != ParamMode::Value {
            var r = self.dyn()->_consume_mode()
            var b = self.dyn()->diag->report(
                DiagID::S069E,
                r.start,
                "'@inout' and '@move' are parameter passing modes; a mode can only be written on a function or closure parameter, and a call passes '&x' to an '@inout' parameter and 'x' to a '@move' one",
            )

            b.first(r)
            if mode == ParamMode::Inout {
                b.fix(r, "&", "pass the address")
            } else {
                b.remove(r, "pass the value")
            }

            b.emit()
            return self._parse_unary_expr(stop)
        }

        self.dyn()->advance() // consume `@`

        // `@cxx::new` / `@cxx::delete`: C++'s own new and delete, not an
        // attribute (c-cpp-memory.mdx).
        if self.dyn()->check(TokenKind::LitIdentifier)
            && self.dyn()->check_peek(TokenKind::OpColonColon)
            && self.dyn()->ctx->get_spelling(self.dyn()->current()) == LangAttrs::cxx_mem() {
            return self._parse_cxx_mem_expr(at_range, stop)
        }

        if !self.dyn()->check(TokenKind::LitIdentifier) {
            self.dyn()->diag->report(
                DiagID::S046E,
                at_range.start,
                "expected attribute name after '@'",
            ).first(at_range)->emit()
            return Expressions::AttributedExpr::create_error(self.dyn()->ctx, at_range)
        }

        var name_tok = self.dyn()->current()
        self.dyn()->advance() // consume the name
        var head = at_range | name_tok.range

        // `@create` / `@destroy` are sugar for alloc.k's create / destroy
        // (AllocSugarDesugar rewrites them before N). The generic form,
        // `@create<T>(args)` / `@destroy<T>(p)`, already names the library
        // call, so it parses AS that call: the operand is `create<T>(args)`,
        // its callee spelled with the attribute's own token. Without this the
        // `<` would be read as the operand and fail as "expected an
        // expression".
        var attr_nm  = self.dyn()->ctx->get_spelling(name_tok)
        var is_alloc = attr_nm == LangAttrs::create() || attr_nm == LangAttrs::destroy()
        if is_alloc {
            self.dyn()->tu->has_alloc_sugar = true
        }

        if is_alloc && self.dyn()->check(TokenKind::OpLess) {
            var callee = NamedIdentExpr::create(self.dyn()->ctx, name_tok.range, name_tok)
            var gargs: kairo::std::StackBuf<ChainType::GenericArg, 4>
            self.dyn()->_parse_generic_args(&gargs)
            if self.dyn()->_pending_close_angle {
                self.dyn()->_pending_close_angle = false
            }

            callee->generic_args.from_buf(gargs.data(), gargs.size(), self.dyn()->ctx)
            callee->range = name_tok.range | self.dyn()->prev().range
            if !self.dyn()->check(TokenKind::OpLParen) {
                self.dyn()->diag->report(
                    DiagID::S052E,
                    head.start,
                    f"expected '(' after '@{attr_nm}<...>'; the generic form is a call: '@{attr_nm}<T>(...)'",
                ).first(head | callee->range)->emit()
                return Expressions::AttributedExpr::create_error(
                    self.dyn()->ctx,
                    head | callee->range,
                )
            }

            var lp = self.dyn()->current_ptr()->range
            self.dyn()->advance(T::SkipNL::After) // consume `(`
            self.dyn()->nl_push()
            var cargs: kairo::std::StackBuf<*Expr, 8>
            if !self.dyn()->check(TokenKind::OpRParen) {
                self._parse_call_args(&cargs, lp)
            }

            self.dyn()->nl_pop()
            var end_r = lp
            if self.dyn()->check(TokenKind::OpRParen) {
                end_r = self.dyn()->current_ptr()->range
                self.dyn()->advance_raw()
            } else {
                self.dyn()->diag->report(
                    DiagID::S051E,
                    lp.start,
                    "expected ')' to close the argument list",
                ).first(lp)->emit()
            }

            var call = Expressions::CallExpr::create(self.dyn()->ctx, callee->range | end_r, callee)
            call->args.from_buf(cargs.data(), cargs.size(), self.dyn()->ctx)
            var gae = Expressions::AttributedExpr::create(
                self.dyn()->ctx,
                head | end_r,
                name_tok,
                call,
            )

            return gae
        }

        var args:    kairo::std::StackBuf<unsafe *Expr, 8>
        var has_args                                       = false
        if self.dyn()->check(TokenKind::OpLParen) {
            has_args = true
            var lparen = self.dyn()->current_ptr()->range
            self.dyn()->advance(T::SkipNL::After) // consume `(`
            self.dyn()->nl_push()
            if !self.dyn()->check(TokenKind::OpRParen) {
                self._parse_call_args(&args, lparen)
            }

            self.dyn()->nl_pop()
            if self.dyn()->check(TokenKind::OpRParen) {
                head = head | self.dyn()->current_ptr()->range
                self.dyn()->advance_raw()
            } else {
                self.dyn()->diag->report(
                    DiagID::S051E,
                    lparen.start,
                    "expected ')' to close attribute argument list",
                ).first(lparen)->emit()
            }
        }

        // Nothing to apply to (`var b = @create`, `f(@create)`): said here,
        // naming the attribute. The operand parser's own "expected
        // expression, found ')'" points past it, and its recovery cascades.
        var operand: unsafe *Expr = &null
        var ends = self.dyn()->is_eof()
            || self.dyn()->_is_terminator_tok(self.dyn()->current_ptr())
            || self.dyn()->check(TokenKind::OpRParen)
            || self.dyn()->check(TokenKind::OpRSquare)
            || self.dyn()->check(TokenKind::OpRBrace)
            || self.dyn()->check(TokenKind::OpComma)
        if !ends {
            operand = self._parse_unary_expr(stop)
        }

        // `@destroy(p)`: the parenthesized spelling of `@destroy p`. The one
        // argument is the operand; there is no attribute argument list.
        if operand == &null
            && is_alloc
            && attr_nm == LangAttrs::destroy()
            && has_args
            && args.size() == 1 {
            operand  = args[0]
            has_args = false
            args.clear()
        }

        if operand == &null {
            var nm = self.dyn()->ctx->get_spelling(name_tok)
            self.dyn()->diag->report(
                DiagID::S052E,
                head.start,
                f"expected an expression after '@{nm}'; an attribute in an expression applies to the expression that follows it",
            ).first(head)->emit()
            return Expressions::AttributedExpr::create_error(self.dyn()->ctx, head)
        }

        var ae = Expressions::AttributedExpr::create(
            self.dyn()->ctx,
            head | operand->range,
            name_tok,
            operand,
        )

        ae->has_args = has_args
        ae->args.from_buf(args.data(), args.size(), self.dyn()->ctx)
        return ae
    }

    /// \brief `@cxx::new T(args)`, `@cxx::new [T; n]`, `@cxx::delete p`,
    ///        `@cxx::delete [] p` (c-cpp-memory.mdx).
    /// \details precondition: `@` consumed, current token is `cxx`, then `::`.
    priv fn _parse_cxx_mem_expr(self, at_range: SourceRange, stop: Self::ExprStop) -> unsafe *Expr {
        self.dyn()->advance() // `cxx`
        self.dyn()->advance() // `::`
        var head = at_range | self.dyn()->current_range()
        if self.dyn()->check(TokenKind::KwDelete) {
            self.dyn()->advance()
            return self._parse_delete_tail(head, stop, true)
        }

        if !self.dyn()->check(TokenKind::LitIdentifier)
            || self.dyn()->ctx->get_spelling(self.dyn()->current()) != LangAttrs::cxx_new() {
            self.dyn()->diag->report(
                DiagID::S046E,
                head.start,
                "expected 'new' or 'delete' after '@cxx::'; '@cxx::new' and '@cxx::delete' are C++'s own allocation",
            ).first(head)->emit()
            return Expressions::CxxNewExpr::create_error(self.dyn()->ctx, head)
        }

        self.dyn()->advance() // `new`

        // `@cxx::new [T; n]`: C++'s `new T[n]`.
        if self.dyn()->check(TokenKind::OpLSquare) {
            var lsq = self.dyn()->current_range()
            self.dyn()->advance(T::SkipNL::After)
            var ty = self.dyn()->parse_type()
            if ty == &null {
                self.dyn()->diag->report(
                    DiagID::S053E,
                    lsq.start,
                    "expected the element type after '@cxx::new ['; the array form is '@cxx::new [T; n]'",
                ).first(head | lsq)->emit()
                return Expressions::CxxNewExpr::create_error(self.dyn()->ctx, head)
            }

            if !self.dyn()->check(TokenKind::OpSemicolon) {
                self.dyn()->diag->report(
                    DiagID::S054E,
                    ty->range.start,
                    "expected ';' and the element count after the type; the array form is '@cxx::new [T; n]'",
                ).first(ty->range)->emit()
                return Expressions::CxxNewExpr::create_error(self.dyn()->ctx, head | ty->range)
            }

            self.dyn()->advance(T::SkipNL::After) // `;`
            var cnt = self.parse_expr()
            if cnt == &null {
                self.dyn()->diag->report(
                    DiagID::S052E,
                    head.start,
                    "expected the element count in '@cxx::new [T; n]'",
                ).first(head)->emit()
                return Expressions::CxxNewExpr::create_error(self.dyn()->ctx, head)
            }

            var end_r = cnt->range
            if self.dyn()->check(TokenKind::OpRSquare) {
                end_r = self.dyn()->current_range()
                self.dyn()->advance_raw()
            } else {
                self.dyn()->diag->report(
                    DiagID::S054E,
                    lsq.start,
                    "expected ']' to close '@cxx::new [T; n]'",
                ).first(lsq)->emit()
            }

            var sz = Expressions::SizeOfExpr::create(self.dyn()->ctx, ty->range, ty)
            return Expressions::CxxNewExpr::create_array(self.dyn()->ctx, head | end_r, sz, cnt)
        }

        // `@cxx::new T(args)`: the construction as Kairo types it.
        var init = self._parse_unary_expr(stop)
        if init == &null || !isa<Expressions::CallExpr>(init) {
            self.dyn()->diag->report(
                DiagID::S052E,
                head.start,
                "expected a construction after '@cxx::new': '@cxx::new T(args)', or '@cxx::new [T; n]' for an array",
            ).first(if (init != &null) => (head | init->range) else => head)->emit()
            return Expressions::CxxNewExpr::create_error(
                self.dyn()->ctx,
                if (init != &null) => (head | init->range) else => head,
            )
        }

        return Expressions::CxxNewExpr::create(self.dyn()->ctx, head | init->range, init)
    }

    /// `delete` already consumed: the optional `[]` and the operand.
    /// \p is_cxx: written `@cxx::delete`; false is a bare `delete`, parsed
    /// only so the statement recovers (S091E was reported).
    priv fn _parse_delete_tail(self,
                               kw_range: SourceRange,
                               stop:     Self::ExprStop,
                               is_cxx:   bool) -> unsafe *Expr {
        var is_array = false
        if self.dyn()->check(TokenKind::OpLSquare) {
            self.dyn()->advance()
            if !self.dyn()->check(TokenKind::OpRSquare) {
                self.dyn()->diag->report(
                    DiagID::S054E,
                    kw_range.start,
                    "expected ']' after 'delete ['",
                ).first(kw_range)->emit()
            } else {
                self.dyn()->advance() // consume ]
            }

            is_array = true
        }

        var unsafe *operand = self._parse_unary_expr(stop)
        if operand == &null {
            self.dyn()->diag->report(
                DiagID::S052E,
                kw_range.start,
                "expected expression after 'delete'",
            ).first(kw_range)->emit()
            return Expressions::DeleteExpr::create_error(self.dyn()->ctx, kw_range)
        }

        var unsafe *de = Expressions::DeleteExpr::create(
            self.dyn()->ctx,
            kw_range | operand->range,
            operand,
            is_array,
        )

        de->is_cxx = is_cxx
        return de
    }

    /// \brief parses prefix unary operators then delegates to postfix.
    ///
    /// prefix ops: ! + - ~ & * ++ --
    /// keyword prefixes: await spawn thread eval unsafe delete sizeof alignof typeof
    /// attribute prefix: `@name operand` (_parse_attributed_expr)
    inline fn _parse_unary_expr(self, stop: Self::ExprStop) -> unsafe *Expr {
        if self.dyn()->is_eof() {
            return &null
        }

        var cur_ptr = self.dyn()->current_ptr()
        if cur_ptr == &null {
            return &null
        }

        var cur_range = cur_ptr->range

        if self.dyn()->check(TokenKind::OpAt) {
            return self._parse_attributed_expr(stop)
        }

        if self.dyn()->check(TokenKind::OpAmp) && self.dyn()->check_peek(TokenKind::LitNull) {
            var amp_range = cur_range
            self.dyn()->advance() // consume &
            var null_range = self.dyn()->current_ptr()->range
            self.dyn()->advance() // consume null
            return NullLiteralExpr::create(self.dyn()->ctx, amp_range | null_range, true)
        }

        /// # prefix unary operators
        if self.dyn()->check(TokenKind::OpExclaim)
            || self.dyn()->check(TokenKind::OpPlus)
            || self.dyn()->check(TokenKind::OpMinus)
            || self.dyn()->check(TokenKind::OpTilde)
            || self.dyn()->check(TokenKind::OpAmp)
            || self.dyn()->check(TokenKind::OpStar)
            || self.dyn()->check(TokenKind::OpPlusPlus)
            || self.dyn()->check(TokenKind::OpMinusMinus) {
            var op_tok = self.dyn()->current()
            self.dyn()->advance()

            var unsafe *operand = self._parse_unary_expr(stop)
            if operand == &null {
                self.dyn()->diag->report(
                    DiagID::S052E,
                    cur_range.start,
                    f"expected expression after '{token_kind_to_readable_string(op_tok.kind)}'",
                ).first(cur_range)->emit()
                return self._error_expr(cur_range)
            }

            self._warn_open_operand(operand)

            return Expressions::UnaryOperatorExpr::create(
                self.dyn()->ctx,
                cur_range | operand->range,
                operand,
                op_tok,
                Expressions::UnaryOperatorExpr::Fix::Prefix,
            )
        }

        /// # prefix ... (pack expansion)
        /// `...args` is the same expansion as the postfix `args...`; both
        /// spellings build a PackExpansionExpr so downstream sees one node.
        /// The prefix form mirrors how a pack is *introduced* in a parameter
        /// list (`fn <...U> f(...args: U)`), which is why call sites reach
        /// for it.
        if self.dyn()->check(TokenKind::OpEllipsis) {
            var dots_range = cur_range
            self.dyn()->advance(T::SkipNL::After)
            var unsafe *operand = self._parse_unary_expr(stop)
            if operand == &null {
                self.dyn()->diag->report(
                    DiagID::S052E,
                    dots_range.start,
                    "expected an expression after '...' to expand",
                ).first(dots_range)->emit()
                return self._error_expr(dots_range)
            }

            return Expressions::PackExpansionExpr::create(
                self.dyn()->ctx,
                dots_range | operand->range,
                operand,
            )
        }

        /// # keyword prefix: await
        if self.dyn()->check(TokenKind::KwAwait) {
            var kw_range = cur_range
            self.dyn()->advance()
            var unsafe *operand = self._parse_unary_expr(stop)
            if operand == &null {
                self.dyn()->diag->report(
                    DiagID::S052E,
                    kw_range.start,
                    "expected expression after 'await'",
                ).first(kw_range)->emit()
                return Expressions::AwaitExpr::create_error(self.dyn()->ctx, kw_range)
            }

            return Expressions::AwaitExpr::create(
                self.dyn()->ctx,
                kw_range | operand->range,
                operand,
            )
        }

        /// # keyword prefix: spawn
        if self.dyn()->check(TokenKind::KwSpawn) {
            var kw_range = cur_range
            self.dyn()->advance()
            var unsafe *operand = self._parse_unary_expr(stop)
            if operand == &null {
                self.dyn()->diag->report(
                    DiagID::S052E,
                    kw_range.start,
                    "expected expression after 'spawn'",
                ).first(kw_range)->emit()
                return Expressions::SpawnExpr::create_error(self.dyn()->ctx, kw_range)
            }

            return Expressions::SpawnExpr::create(
                self.dyn()->ctx,
                kw_range | operand->range,
                operand,
            )
        }

        /// # keyword prefix: thread
        if self.dyn()->check(TokenKind::KwThread) {
            var kw_range = cur_range
            self.dyn()->advance()
            var unsafe *operand = self._parse_unary_expr(stop)
            if operand == &null {
                self.dyn()->diag->report(
                    DiagID::S052E,
                    kw_range.start,
                    "expected expression after 'thread'",
                ).first(kw_range)->emit()
                return Expressions::ThreadExpr::create_error(self.dyn()->ctx, kw_range)
            }

            return Expressions::ThreadExpr::create(
                self.dyn()->ctx,
                kw_range | operand->range,
                operand,
            )
        }

        /// # keyword prefix: eval
        if self.dyn()->check(TokenKind::KwEval) {
            var kw_range = cur_range
            self.dyn()->advance()
            var unsafe *operand = self._parse_unary_expr(stop)
            if operand == &null {
                self.dyn()->diag->report(
                    DiagID::S052E,
                    kw_range.start,
                    "expected expression after 'eval'",
                ).first(kw_range)->emit()
                return Expressions::EvalExpr::create_error(self.dyn()->ctx, kw_range)
            }

            return Expressions::EvalExpr::create(
                self.dyn()->ctx,
                kw_range | operand->range,
                operand,
            )
        }

        /// # keyword prefix: unsafe
        if self.dyn()->check(TokenKind::KwUnsafe) {
            var kw_range = cur_range
            self.dyn()->advance()
            var unsafe *operand = self._parse_unary_expr(stop)
            if operand == &null {
                self.dyn()->diag->report(
                    DiagID::S052E,
                    kw_range.start,
                    "expected expression after 'unsafe'",
                ).first(kw_range)->emit()
                return Expressions::UnsafeExpr::create_error(self.dyn()->ctx, kw_range)
            }

            return Expressions::UnsafeExpr::create(
                self.dyn()->ctx,
                kw_range | operand->range,
                operand,
            )
        }

        /// # keyword prefix: delete -- removed (0.2.0). `@destroy p` frees
        /// what `@create` made through the allocator in effect; C++ memory is
        /// `@cxx::delete p`. Still parsed, so the statement recovers.
        if self.dyn()->check(TokenKind::KwDelete) {
            var kw_range = cur_range
            self.dyn()->advance()
            var arr = self.dyn()->check(TokenKind::OpLSquare)
            var b = self.dyn()->diag->report(DiagID::S091E, kw_range.start,
                (if (arr) => ("Kairo has no 'delete' expression; memory from C++'s 'new T[n]' is freed with '@cxx::delete [] p'") else => "Kairo has no 'delete' expression; '@destroy p' runs the destructor and frees the memory through the allocator that '@create' took it from"))
            b.first(kw_range)
            if arr {
                b.fix(kw_range, "@cxx::delete", "free C++ array memory with C++'s delete[]")
            } else {
                b.fix(kw_range, "@destroy", "write '@destroy'")
            }

            b.emit()
            return self._parse_delete_tail(kw_range, stop, false)
        }

        /// # keyword prefix: sizeof
        if self.dyn()->check(TokenKind::KwSizeOf) {
            return self._parse_sizeof_expr()
        }

        /// # keyword prefix: alignof
        if self.dyn()->check(TokenKind::KwAlignOf) {
            return self._parse_alignof_expr()
        }

        /// # keyword prefix: typeof
        if self.dyn()->check(TokenKind::KwTypeOf) {
            return self._parse_typeof_expr()
        }

        /// # no prefix: parse postfix
        return self._parse_postfix_expr(stop)
    }

    //  sizeof / alignof / typeof

    inline fn _parse_sizeof_expr(self) -> unsafe *Expr {
        var kw_range = self.dyn()->current_ptr()->range
        self.dyn()->advance() // consume `sizeof`

        var has_paren = self.dyn()->check(TokenKind::OpLParen)
        if has_paren {
            self.dyn()->advance(T::SkipNL::After)
        }

        var ty = self.dyn()->parse_type()
        if ty == &null {
            self.dyn()->diag->report(
                DiagID::S053E,
                kw_range.start,
                "expected type after 'sizeof'",
            ).first(kw_range)->emit()
            return Expressions::SizeOfExpr::create_error(self.dyn()->ctx, kw_range)
        }

        if has_paren {
            if !self.dyn()->check(TokenKind::OpRParen) {
                self.dyn()->diag->report(
                    DiagID::S054E,
                    kw_range.start,
                    "expected ')' after type in 'sizeof(T)'",
                ).first(kw_range)->emit()
            } else {
                self.dyn()->advance() // consume )
            }
        }

        return Expressions::SizeOfExpr::create(
            self.dyn()->ctx,
            kw_range | self.dyn()->prev().range,
            ty,
        )
    }

    inline fn _parse_alignof_expr(self) -> unsafe *Expr {
        var kw_range = self.dyn()->current_ptr()->range
        self.dyn()->advance() // consume `alignof`

        var has_paren = self.dyn()->check(TokenKind::OpLParen)
        if has_paren {
            self.dyn()->advance(T::SkipNL::After)
        }

        var ty = self.dyn()->parse_type()
        if ty == &null {
            self.dyn()->diag->report(
                DiagID::S053E,
                kw_range.start,
                "expected type after 'alignof'",
            ).first(kw_range)->emit()
            return Expressions::AlignOfExpr::create_error(self.dyn()->ctx, kw_range)
        }

        if has_paren {
            if !self.dyn()->check(TokenKind::OpRParen) {
                self.dyn()->diag->report(
                    DiagID::S054E,
                    kw_range.start,
                    "expected ')' after type in 'alignof(T)'",
                ).first(kw_range)->emit()
            } else {
                self.dyn()->advance()
            }
        }

        return Expressions::AlignOfExpr::create(
            self.dyn()->ctx,
            kw_range | self.dyn()->prev().range,
            ty,
        )
    }

    /// The operand of `typeof` with no parentheses: one prefix-level
    /// expression, never a binary one. In a type position a whole
    /// expression ran on through the initializer: `var y: typeof x = 100`
    /// parsed as `typeof (x = 100)` with no initializer at all.
    fn parse_typeof_operand(self,
                            stop: Self::ExprStop = FlagSet<ExprStopBit, u8>()) -> unsafe *Expr {
        if self.dyn()->is_eof() {
            return &null
        }

        if !self.dyn()->enter_expr_depth() {
            return &null
        }

        var unsafe *e = self._parse_unary_expr(stop)
        self.dyn()->exit_expr_depth()
        return e
    }

    inline fn _parse_typeof_expr(self) -> unsafe *Expr {
        var kw_range = self.dyn()->current_ptr()->range
        self.dyn()->advance() // consume `typeof`

        var has_paren = self.dyn()->check(TokenKind::OpLParen)
        if has_paren {
            self.dyn()->advance(T::SkipNL::After)
        }

        // Unparenthesized, the operand is a prefix-level one (operators.mdx:
        // `typeof` binds as a unary operator), so `typeof x == i32` compares
        // the type and `typeof x + 1` is not `typeof (x + 1)`.
        var operand: unsafe *Expr = &null
        if has_paren {
            operand = self.parse_expr(self.stop_on(Self::ExprStopKind::StopParen))
        } else {
            operand = self.parse_typeof_operand()
        }

        if operand == &null {
            self.dyn()->diag->report(
                DiagID::S052E,
                kw_range.start,
                "expected expression after 'typeof'",
            ).first(kw_range)->emit()
            return Expressions::TypeOfExpr::create_error(self.dyn()->ctx, kw_range)
        }

        if has_paren {
            if !self.dyn()->check(TokenKind::OpRParen) {
                self.dyn()->diag->report(
                    DiagID::S054E,
                    kw_range.start,
                    "expected ')' after expression in 'typeof(expr)'",
                ).first(kw_range)->emit()
            } else {
                self.dyn()->advance()
            }
        }

        return Expressions::TypeOfExpr::create(
            self.dyn()->ctx,
            kw_range | self.dyn()->prev().range,
            operand,
        )
    }

    /// \brief parses `defined!(NAME)` (Compiler/Spec/Eval.md#defined). The preprocessor only
    ///        lets a well-formed one through, so a malformed one here was
    ///        written some way the PP did not see (a macro's output).
    ///  Grammar:  'defined' '!' '(' identifier ')'
    inline fn _parse_defined_intrinsic(self) -> unsafe *Expr {
        var kw_range = self.dyn()->current_ptr()->range
        self.dyn()->advance() // consume `defined`
        self.dyn()->advance() // consume `!`
        if !self.dyn()->check(TokenKind::OpLParen)
            || self.dyn()->ig_peek_kind() != TokenKind::LitIdentifier {
            self.dyn()->diag->report(
                DiagID::S060E,
                kw_range.start,
                "expected '(name)' after 'defined!': write 'defined!(NAME)'",
            ).first(kw_range | self.dyn()->prev().range)->emit()
            return BooleanLiteralExpr::create(self.dyn()->ctx, kw_range, false)
        }

        self.dyn()->advance() // consume `(`
        var name = self.dyn()->current()
        self.dyn()->advance() // consume NAME
        if !self.dyn()->check(TokenKind::OpRParen) {
            self.dyn()->diag->report(
                DiagID::S060E,
                kw_range.start,
                "expected ')' to close 'defined!(...)'",
            ).first(kw_range | self.dyn()->prev().range)->emit()
            return BooleanLiteralExpr::create(self.dyn()->ctx, kw_range, false)
        }

        self.dyn()->advance() // consume `)`
        if self.dyn()->tu != &null { // EvalIfFolding answers it.
            self.dyn()->tu->has_eval_if = true
        }

        return (Expressions::DefinedExpr::create(
            self.dyn()->ctx,
            kw_range | self.dyn()->prev().range,
            name,
        ))
    }

    /// \brief parses the unwrap intrinsic (Compiler/Spec/Nullables.md#unwrap).
    ///  Grammar:  'unwrap' '!' '(' expr ')'
    inline fn _parse_unwrap_intrinsic(self) -> unsafe *Expr {
        var kw_range = self.dyn()->current_ptr()->range
        self.dyn()->advance() // consume `unwrap`
        self.dyn()->advance() // consume `!`
        if !self.dyn()->check(TokenKind::OpLParen) {
            self.dyn()->diag->report(
                DiagID::S060E,
                kw_range.start,
                "expected '(' after 'unwrap!': write 'unwrap!(expr)'",
            ).first(kw_range | self.dyn()->prev().range)->emit()
            return Expressions::UnwrapExpr::create_error(
                self.dyn()->ctx,
                kw_range | self.dyn()->prev().range,
            )
        }

        self.dyn()->advance(T::SkipNL::After) // consume `(`

        var unsafe *operand = self.parse_expr(self.stop_on(Self::ExprStopKind::StopParen))
        if operand == &null {
            self.dyn()->diag->report(
                DiagID::S052E,
                kw_range.start,
                "expected expression inside 'unwrap!(...)'",
            ).first(kw_range)->emit()
            return Expressions::UnwrapExpr::create_error(self.dyn()->ctx, kw_range)
        }

        if !self.dyn()->check(TokenKind::OpRParen) {
            self.dyn()->diag->report(
                DiagID::S060E,
                kw_range.start,
                "expected ')' to close 'unwrap!(...)'",
            ).first(kw_range | operand->range)->emit()
            return Expressions::UnwrapExpr::create_error(self.dyn()->ctx, kw_range | operand->range)
        }

        self.dyn()->advance() // consume `)`
        return Expressions::UnwrapExpr::create(
            self.dyn()->ctx,
            kw_range | self.dyn()->prev().range,
            operand,
        )
    }

    /// \brief parses a type-fact intrinsic (Compiler/Spec/Eval.md#deferred-conditions). A malformed one
    ///        is reported and reads as `false`, as a malformed `defined!` does.
    ///  Grammar:  ('is_trivially_copyable' | 'is_trivially_destructible') '!' '(' type ')'
    inline fn _parse_type_trait_intrinsic(self) -> unsafe *Expr {
        var kw_range = self.dyn()->current_ptr()->range
        var fact = Expressions::type_trait_of(self.dyn()->ctx->get_spelling(self.dyn()->current()))
        var nm   = Expressions::type_trait_spelling(fact)
        self.dyn()->advance() // consume the name
        self.dyn()->advance() // consume `!`
        if !self.dyn()->check(TokenKind::OpLParen) {
            self.dyn()->diag->report(
                DiagID::S060E,
                kw_range.start,
                f"expected '(' after '{nm}!': write '{nm}!(T)'",
            ).first(kw_range | self.dyn()->prev().range)->emit()
            return BooleanLiteralExpr::create(self.dyn()->ctx, kw_range, false)
        }

        self.dyn()->advance(T::SkipNL::After) // consume `(`
        var ty = self.dyn()->parse_type()
        if ty == &null {
            self.dyn()->diag->report(
                DiagID::S053E,
                kw_range.start,
                f"expected a type inside '{nm}!(...)'",
            ).first(kw_range)->emit()
            return BooleanLiteralExpr::create(self.dyn()->ctx, kw_range, false)
        }

        if !self.dyn()->check(TokenKind::OpRParen) {
            self.dyn()->diag->report(
                DiagID::S060E,
                kw_range.start,
                f"expected ')' to close '{nm}!(...)'",
            ).first(kw_range | self.dyn()->prev().range)->emit()
            return BooleanLiteralExpr::create(self.dyn()->ctx, kw_range, false)
        }

        self.dyn()->advance() // consume `)`
        return (Expressions::TypeTraitExpr::create(
            self.dyn()->ctx,
            kw_range | self.dyn()->prev().range,
            fact,
            ty,
        ))
    }

    //  Postfix expression loop

    /// \brief parses a primary expression then loops consuming postfix ops.
    ///
    /// postfix ops:
    ///   . -> :: ?. ?->           -> accumulate ChainExpr steps
    ///   (                        -> wrap current expr in CallExpr
    ///   [                        -> wrap current expr in SubscriptExpr
    ///   ++ --                    -> wrap in postfix UnaryOperatorExpr
    ///   ...                      -> wrap in PackExpansionExpr
    ///   as                       -> wrap in TypeCastExpr
    ///
    /// chain steps are accumulated into a StackBuf. when a non-access postfix
    /// or end-of-postfix is reached, any pending steps are frozen into a
    /// ChainExpr before wrapping. this keeps ChainExpr pure (access only)
    /// while allowing arbitrary postfix interleaving.
    inline fn _parse_postfix_expr(self, stop: Self::ExprStop) -> unsafe *Expr {
        var unsafe *base = self._parse_primary_expr(stop)
        if base == &null {
            return &null
        }

        // pending chain steps accumulator
        var chain_steps: kairo::std::StackBuf<ChainExpr::Step, 8>
        var chain_start                                           = base->range

        while !self.dyn()->is_eof() {
            // brush a trailing comment so the newline-continuation guard below
            // sees the real next token, not an AtComment sitting between the
            // primary and its terminator (`b // c\n`).
            // if (dyn()->ig_kind()) == TokenKind::AtComment {
            //     dyn()->_stash_comment(dyn()->current_ptr());
            //     dyn()->advance_raw();
            //     continue;
            // }

            // -- newline continuation: only the member-access family may
            //    continue an expression across a raw newline. `::` is
            //    excluded (ambiguous with a new statement); binary ops
            //    require enclosing parens (nl_depth handles those).
            if self.dyn()->nl_depth == 0 && self.dyn()->ig_kind() == TokenKind::TkNewLine {
                var nk = self.dyn()->peek_past_nl_kind()
                if nk == TokenKind::OpDot
                    || nk == TokenKind::OpArrow
                    || nk == TokenKind::OpQuestionDot
                    || nk == TokenKind::OpQuestionArrow {
                    self.dyn()->advance(T::SkipNL::Only)
                    continue
                }

                break // newline ends the postfix chain
            }

            if self.dyn()->check(TokenKind::OpDot)
                || self.dyn()->check(TokenKind::OpArrow)
                || self.dyn()->check(TokenKind::OpColonColon)
                || self.dyn()->check(TokenKind::OpQuestionDot)
                || self.dyn()->check(TokenKind::OpQuestionArrow) {
                var step = self._parse_access_step()
                // well-formed under any target: an Operator/TupleIndex step
                // carries no `name`, so `name != null` alone is not the test.
                if step.target != ChainExpr::StepTarget::Name || step.name != &null {
                    chain_steps.push_back(step)
                    continue
                }

                // recovery: named step failed to produce a name, break out
                break
            }

            /// ### call: (
            if self.dyn()->check(TokenKind::OpLParen) {
                // flush pending chain steps first
                base        = self._flush_chain(base, &chain_steps, chain_start)
                base        = self._parse_call_expr(base)
                chain_start = base->range
                continue
            }

            /// ### subscript: [
            if self.dyn()->check(TokenKind::OpLSquare) {
                base        = self._flush_chain(base, &chain_steps, chain_start)
                base        = self._parse_subscript_expr(base)
                chain_start = base->range
                continue
            }

            /// ### named initializer:  Path '{' field (',' field)* '}'
            if self.dyn()->check(TokenKind::OpLBrace) {
                // Suppressed in condition/scrutinee/iterable positions, where a
                // trailing `{` is the block of the enclosing construct, not an
                // initializer. The statement parser relies on us leaving `{` alone.
                var suppressed = stop.has(Self::ExprStopKind::NoStructLiteral)
                if suppressed {
                    break // hand the `{` back to the caller (it's a block opener)
                }

                // Only a *type path* can be initialized. Reject `foo() { }`,
                // `(a + b) { }`, `arr[i] { }` the base must be a name or a
                // qualified/generic path, never a call/subscript/operator result.
                base = self._flush_chain(base, &chain_steps, chain_start)
                if !self._is_initializable_path(base) {
                    break // not a named-init; let the caller see the `{`
                }

                base = self._parse_named_initializer(base, stop)
                continue
            }

            /// ### postfix ++ --
            if self.dyn()->check(TokenKind::OpPlusPlus)
                || self.dyn()->check(TokenKind::OpMinusMinus) {
                base = self._flush_chain(base, &chain_steps, chain_start)
                var op_tok = self.dyn()->current()
                self.dyn()->advance()
                base = Expressions::UnaryOperatorExpr::create(
                    self.dyn()->ctx,
                    base->range | op_tok.range,
                    base,
                    op_tok,
                    Expressions::UnaryOperatorExpr::Fix::Postfix,
                )

                chain_start = base->range
                continue
            }

            /// ### postfix ... (pack expansion)
            if self.dyn()->check(TokenKind::OpEllipsis) {
                base = self._flush_chain(base, &chain_steps, chain_start)
                var ellipsis_range = self.dyn()->current_ptr()->range
                self.dyn()->advance()
                base = Expressions::PackExpansionExpr::create(
                    self.dyn()->ctx,
                    base->range | ellipsis_range,
                    base,
                )

                chain_start = base->range
                continue
            }

            /// ### postfix ? (has-value test)
            /// `mem?` asks whether a nullable holds a value. Unambiguous: the
            /// related surface operators lex as their own tokens (`??`, `?.`,
            /// `?->`), and `?` carries no infix precedence, so a bare `?` here
            /// is always the postfix form. Sema desugars it to the storage
            /// primitive (`!is_null()`).
            if self.dyn()->check(TokenKind::OpQuestion) {
                base = self._flush_chain(base, &chain_steps, chain_start)
                var q_tok = self.dyn()->current()
                self.dyn()->advance()
                base = Expressions::UnaryOperatorExpr::create(
                    self.dyn()->ctx,
                    base->range | q_tok.range,
                    base,
                    q_tok,
                    Expressions::UnaryOperatorExpr::Fix::Postfix,
                )

                chain_start = base->range
                continue
            }

            /// ### nothing matched: end of postfix
            /// `as` is not postfix: _parse_cast_expr owns it, one level
            /// looser than prefix operators.
            break
        }

        // flush any remaining chain steps
        base = self._flush_chain(base, &chain_steps, chain_start)
        return base
    }

    //  Chain step parsing

    /// \brief parses a single access step: separator + identifier + optional
    ///        generic args.
    ///
    /// precondition: current token is one of . -> :: ?. ?->
    inline fn _parse_access_step(self) -> ChainExpr::Step {
        var result = ChainExpr::Step{}
        result.name          = &null
        result.target        = ChainExpr::StepTarget::Name
        result.access_kind   = ChainExpr::AccessKind::Dot
        result.resolved_type = &null
        result.resolved_decl = &null

        var sep_range = self.dyn()->current_ptr()->range
        var sep_raw   = *self.dyn()->current_ptr() // wrapped as is: _tuple_index_gap reads where it was written.
        var sep_kind  = self.dyn()->resolve_kind_deep(self.dyn()->current_ptr())

        // determine access kind from separator token
        if self.dyn()->check(TokenKind::OpDot) {
            result.access_kind = ChainExpr::AccessKind::Dot
        } else if self.dyn()->check(TokenKind::OpArrow) {
            result.access_kind = ChainExpr::AccessKind::Arrow
        } else if self.dyn()->check(TokenKind::OpColonColon) {
            result.access_kind = ChainExpr::AccessKind::ColonColon
        } else if self.dyn()->check(TokenKind::OpQuestionDot) {
            result.access_kind = ChainExpr::AccessKind::QuestionDot
        } else if self.dyn()->check(TokenKind::OpQuestionArrow) {
            result.access_kind = ChainExpr::AccessKind::QuestionArrow
        }

        self.dyn()->advance(T::SkipNL::After) // consume separator

        // code completion after separator
        if self.dyn()->check(TokenKind::TkCodeComplete) {
            self.dyn()->maybe_complete(CompletionContextKind::ExprStart)
            self.dyn()->advance(T::SkipNL::After)
            result.range = sep_range
            return result // name stays null, caller handles
        }

        /// # qualified operator: `Foo::op+`, `a->op[]`, `a.op<<i32>(..)`
        /// an `op` after the separator names an overloaded operator instead of
        /// an identifier. mirror the decl side: parse+validate the spelling,
        /// freeze the tokens onto the step, leave `name` null.
        if self.dyn()->check(TokenKind::KwOp) {
            var op_start = self.dyn()->current_ptr()->range
            self.dyn()->advance() // consume `op`
            result.target = ChainExpr::StepTarget::Operator
            // `x.op delete()`: the destructor's pre-0.2.0 name. Read as `op
            // finally` (the spelling parser keys it so) after the error.
            var spelled_delete = self.dyn()->check(TokenKind::KwDelete)
            if spelled_delete {
                var dr = self.dyn()->current_range()
                var b = self.dyn()->diag->report(
                    DiagID::S090E,
                    dr.start,
                    "the destructor is 'op finally'; 'op delete' is not a Kairo operator",
                )

                b.first(dr)
                b.fix(dr, "finally", "write 'finally'")
                b.emit()
            }

            // `<<` after `op` is ambiguous: the shift operator, or the `<`
            // operator followed by a generic-args opener (`(k.op<)<i32>(..)`).
            // Try the split reading tentatively; on rollback the `<<` token is
            // restored and we fall through to the greedy shift-op reading.
            if self.dyn()->check(TokenKind::OpLessLess)
                && self._try_op_less_less_split(&result, op_start, sep_range) {
                return result
            }

            var ops: kairo::std::StackBuf<Token, 2>
            self.dyn()->_parse_and_validate_op_spelling(&ops)
            // One error per site: `op delete` already has S090E and its
            // fix-it, and SC116E on top would point at a `finally` the user
            // never wrote.
            if !spelled_delete && ops.size() > 0 && ops[0].kind == TokenKind::KwFinally {
                self._report_finally_call(ops[0].range)
            }

            result.op_tokens.from_buf(ops.data(), ops.size(), self.dyn()->ctx)
            result.range = sep_range | self.dyn()->prev().range

            // generic args on the operator: `op+<i32>(..)`. tentative, so a
            // trailing shift/comparison (`k = a.op<<i32`) rolls back cleanly
            // while `a.op+<i32>(..)` commits.
            if self.dyn()->check(TokenKind::OpLess) {
                self._try_step_generic_args(&result, op_start, sep_range)
            }

            return result
        }

        /// # `x.finally()`: an explicit early destructor call. The planned
        /// 0.3 design; NOT implemented before it: the parse still produces the same step as `x.op finally()`
        /// so recovery sees one shape, and the error stops codegen. Lowering
        /// it to `x.~T()` ran the destructor twice (scope exit still runs it).
        if self.dyn()->check(TokenKind::KwFinally)
            && result.access_kind != ChainExpr::AccessKind::ColonColon {
            var ft = self.dyn()->current()
            self._report_finally_call(ft.range)
            self.dyn()->advance()
            result.target = ChainExpr::StepTarget::Operator
            var fops: kairo::std::StackBuf<Token, 2>
            fops.push_back(ft)
            result.op_tokens.from_buf(fops.data(), fops.size(), self.dyn()->ctx)
            result.range = sep_range | ft.range
            return result
        }

        /// # tuple index: `.0`, `t->0`, `t?.0`, `t?->0`
        /// Only the *target* differs from a named step; the separator is
        /// whatever it was and stays in access_kind. `::` is excluded   a
        /// tuple element is a member, never a scope-qualified name.
        if self.dyn()->check(TokenKind::LitInt)
            && result.access_kind != ChainExpr::AccessKind::ColonColon {
            var idx_raw   = *self.dyn()->current_ptr()
            var idx_range = idx_raw.range

            // Adjacency. `t.0` is an index; `t. 0` is not. Whitespace here is
            // always a mistake, and permitting it makes macro-expanded synthetic
            // locations unanswerable.
            //
            // Across a newline this is NOT an index at all: the separator's
            // `SkipNL::After` advance looked past the line break, so for
            //
            //     1.
            //     2
            //
            // the integer it landed on belongs to the next statement. Falling
            // through to the identifier path is what makes that report the
            // honest "expected identifier or tuple index after '.'" instead of
            // inventing a whitespace rule about two different lines.
            var gap = self._tuple_index_gap(sep_raw, idx_raw)
            if gap != 0 {
                if gap == 1 {
                    self.dyn()->diag->report(
                        DiagID::S054E,
                        sep_range.start,
                        "no whitespace allowed between the access operator and a tuple index",
                    ).first(sep_range | idx_range)->emit()
                    // Consume it. Left in place, the postfix loop breaks on the
                    // failed step and the STATEMENT loop re-parses this same
                    // integer as a statement of its own.
                    self.dyn()->advance()
                    return result // target stays Name, name null; caller recovers
                }
            } else {
                var idx_val:  u32 = 0
                var too_large     = false
                if !self._read_tuple_index(idx_raw, &idx_val, &too_large) {
                    if too_large {
                        // Name the offending value. Truncating it silently is
                        // the one outcome worse than any message here.
                        var spelling = self.dyn()->ctx->sm->get_text(
                            self.dyn()->ctx->written_range(idx_raw),
                        )

                        self.dyn()->diag->report(
                            DiagID::S054E,
                            idx_range.start,
                            f"tuple index {spelling} is too large; the largest addressable element is 4294967295",
                        ).first(idx_range)->emit()
                    } else {
                        self.dyn()->diag->report(
                            DiagID::S054E,
                            idx_range.start,
                            "tuple index must be a plain decimal integer with no prefix, suffix, digit separator, or leading zero",
                        ).first(idx_range)->emit()
                    }

                    self.dyn()->advance() // same: do not leave it for the stmt loop
                    return result
                }

                self.dyn()->advance() // consume the index
                result.target = ChainExpr::StepTarget::TupleIndex
                result.index  = idx_val
                result.range  = sep_range | idx_range
                return result // no generic args on a tuple index
            }
        }

        // expect identifier
        if !self.dyn()->check(
            fn(k: TokenKind) -> bool {
                return Self::_is_expr_ident_kind(k)
            },
        ) {
            self.dyn()->diag->report(
                DiagID::S054E,
                sep_range.start,
                f"expected identifier or tuple index after '{token_kind_to_readable_string(sep_kind)}' in access expression",
            ).first(sep_range)->emit()
            return result // name stays null
        }

        var id_ptr   = self.dyn()->current_ptr()
        var id_range = id_ptr->range
        self.dyn()->advance() // consume identifier

        var nte = NamedIdentExpr::create(self.dyn()->ctx, id_range, *id_ptr)
        result.name  = nte
        result.range = sep_range | id_range

        /// # generic args after :: separator only
        /// foo::<T> is generic, foo.<T> is not valid syntax
        /// also check hoisted scope for disambiguation of foo::Bar<T>
        if self.dyn()->check(TokenKind::OpLess) && self._can_take_generic_args(*id_ptr) {
            if result.access_kind == ChainExpr::AccessKind::ColonColon {
                if self._is_generic_name(*id_ptr) {
                    var generic_args: kairo::std::StackBuf<ChainType::GenericArg, 4>
                    self.dyn()->_parse_generic_args(&generic_args)
                    if self.dyn()->_pending_close_angle {
                        self.dyn()->_pending_close_angle = false
                    }

                    result.generic_args.from_buf(
                        generic_args.data(),
                        generic_args.size(),
                        self.dyn()->ctx,
                    )

                    result.range = sep_range | self.dyn()->prev().range
                } else {
                    self._try_step_generic_args(&result, id_range, sep_range)
                }
            } else {
                self._try_step_generic_args(&result, id_range, sep_range)
            }
        }

        return result
    }

    /// \brief validates a LitInt as a tuple index and extracts its value.
    ///
    /// \details rejects anything that isn't a plain decimal ordinal: `t.0x1`,
    ///          `t.1u8`, `t.1_0`, `t.01`. Each is a typo with a plausible wrong
    ///          reading, so silently accepting one is worse than erroring.
    ///          Reads the flags the lexer already computed in `finalize_number`
    ///          rather than reclassifying the token.
    ///
    /// \param tok       the macro-resolved LitInt token (imm indexes the imm table).
    /// \param out       receives the ordinal on success; untouched on failure.
    /// \param too_large set only when the failure is "does not fit u32", so the
    ///                  caller can name the value instead of talking about
    ///                  prefixes and separators. Never cleared here   the
    ///                  caller initialises it.
    /// \returns false if the token is not a valid tuple index.
    /// \brief what separates a tuple index from its access operator: 0
    ///        nothing (`t.0`), 1 whitespace on one line (S054E), 2 a line
    ///        break (not an index; the caller's identifier path reports).
    ///
    /// \details both tokens of a macro body (`t.1` in an imported macro)
    ///          carry the invocation's range, so their ranges said "spaced"
    ///          for every expanded index. A wrapped token is judged where it
    ///          was written. An operator and an index written in two places
    ///          (the body's `.`, the argument's `1`; or two files) had no
    ///          spacing written between them, and are adjacent.
    priv fn _tuple_index_gap(self, sep: Token, idx: Token) -> u8 {
        var ctx = self.dyn()->ctx
        var wrapped = (sep.kind as u32) == (TokenKind::TkMacroExpand as u32)
            || (idx.kind as u32) == (TokenKind::TkMacroExpand as u32)
        if !wrapped {
            if idx.range.start == sep.range.end {
                return 0
            }

            if ctx->sm->is_multiline(sep.range | idx.range) {
                return 2
            }

            return 1
        }

        var s = ctx->written_range(sep)
        var i = ctx->written_range(idx)
        if i.start == s.end {
            return 0
        }

        if ctx->sm->get_fid(s.start) != ctx->sm->get_fid(i.start) {
            return 0
        }

        if i.start < s.end {
            return 0
        }

        var between = ctx->sm->get_text(SourceRange::from_bounds(s.end, i.start))
        var len     = between.length()
        var data    = between.raw()
        var nl      = false
        for var k: usize = 0; k < len; ++k {
            var c = data[k]
            if c == ('\n' as u8) || c == ('\r' as u8) {
                nl = true
                continue
            }

            if c != (' ' as u8) && c != ('\t' as u8) {
                return 0
            }
        }

        if nl {
            return 2
        }

        return 1
    }

    /// \p tok is the index token as the stream holds it, wrapped or not: a
    /// wrapped one's imm is its expansion record, and its payload is in the
    /// table of the file that wrote the literal (ASTContext::get_payload_table).
    priv fn _read_tuple_index(self, raw: Token, out: unsafe *u32, too_large: unsafe *bool) -> bool {
        var imm_tbl = self.dyn()->ctx->get_payload_table(raw)
        if imm_tbl == &null {
            return false
        }

        var tok = self.dyn()->ctx->unwrap_token(raw)

        // `imm_tbl` is dependent inside this CRTP mixin, so the member template
        // needs an explicit `template` keyword   not expressible in Kairo yet.
        var idata = imm_tbl->get<Immediate::IntData>(tok.imm)
        if idata == &null {
            return false
        }

        // bit4 = has_prefix (0x/0b/0o), bit3 = has_suffix
        if (idata->flags & 0b00011000) != 0 {
            return false
        }

        if idata->base != 10 {
            return false
        }

        var text = self.dyn()->ctx->sm->get_text(idata->body)
        var len  = text.length()
        if len == 0 {
            return false
        }

        var data = text.raw()

        // leading zero, unless the index is exactly `0`
        if len > 1 && data[0] == ('0' as u8) {
            return false
        }

        // The bound is `U32_MAX`: `t.4294967296` must not truncate to `t.0`.

        // Validate every character before deciding the value is merely too big:
        // `t.1_0` is a malformed index, not a large one. Accumulation stops at
        // the first overflow so `v` itself can never wrap, however long the
        // digit run is.
        var v:         u64 = 0
        var overflowed     = false
        for var i: usize = 0; i < len; ++i {
            var c = data[i]
            if c < ('0' as u8) || c > ('9' as u8) { // catches `_`
                return false
            }

            if !overflowed {
                v = v * 10 + ((c - ('0' as u8)) as u64)
                if v > U32_MAX {
                    overflowed = true
                }
            }
        }

        if overflowed {
            *too_large = true
            return false
        }

        *out = (v as u32)
        return true
    }

    inline fn _try_step_generic_args(self,
                                     step:      *ChainExpr::Step,
                                     id_range:  SourceRange,
                                     sep_range: SourceRange) {
        type ASTTentativeGuard = T::TentativeGuard

        var t = ASTTentativeGuard(self.dyn())
        var generic_args: kairo::std::StackBuf<ChainType::GenericArg, 4>
        var ok = self.dyn()->_parse_generic_args(&generic_args)
        if self.dyn()->_pending_close_angle {
            self.dyn()->_pending_close_angle = false
        }

        if ok && !generic_args.is_empty() {
            var k = self.dyn()->ig_kind()
            if k == TokenKind::OpLParen
                || k == TokenKind::OpDot
                || k == TokenKind::OpArrow
                || k == TokenKind::OpColonColon
                || k == TokenKind::OpQuestionDot
                || k == TokenKind::OpQuestionArrow
                || k == TokenKind::OpLSquare
                || k == TokenKind::OpLBrace
                || k == TokenKind::OpComma
                || k == TokenKind::OpSemicolon
                || k == TokenKind::OpRParen
                || k == TokenKind::OpRSquare
                || k == TokenKind::OpRBrace
                || k == TokenKind::TkNewLine
                || k == TokenKind::TkEof {
                step->generic_args.from_buf(
                    generic_args.data(),
                    generic_args.size(),
                    self.dyn()->ctx,
                )

                step->range = sep_range | self.dyn()->prev().range
                t.commit()
                return
            }
        }

        // fall through: guard dtor pops suppress and rolls cursor back
    }

    /// \brief tentatively splits a `<<` after `op` into the `<` operator plus a
    ///        generic-args opener: `(k.op<)<i32>(..)`.
    ///
    /// \details the lexer fuses `op<` + `<` into `op` `<<`. When generic args
    ///          are actually present, the first `<` is the overloaded operator
    ///          and the second opens the generic list. We rewrite the physical
    ///          `<<` token in place to a single `<` covering only its second
    ///          column, then run the normal generic-args parse. On success the
    ///          op token is the synthesized `<` over the first column. On
    ///          failure we restore the `<<` token (TentativeGuard does NOT
    ///          snapshot the token buffer) and return false so the caller falls
    ///          back to reading `<<` as the shift operator.
    ///
    /// precondition: current token is `<<`, `op` already consumed.
    /// \returns true if the split reading committed (result is fully populated).
    inline fn _try_op_less_less_split(self,
                                      result:    *ChainExpr::Step,
                                      op_start:  SourceRange,
                                      sep_range: SourceRange) -> bool {
        type ASTTentativeGuard = T::TentativeGuard

        var ll_ptr   = self.dyn()->current_ptr()
        var ll_range = ll_ptr->range             // saved for restore on rollback

        // first column: the `<` operator; second column: generic opener.
        var lt_range = SourceRange::from_bounds(ll_range.start, ll_range.start.with_offset(1))
        var op_tok   = Token(lt_range, TokenKind::OpLess)

        // rewrite the buffer token to the leftover `<` (second column) so the
        // generic-args parser consumes it as the opener.
        ll_ptr->kind  = TokenKind::OpLess
        ll_ptr->range = SourceRange::from_bounds(ll_range.start.with_offset(1), ll_range.end)

        var t = ASTTentativeGuard(self.dyn())
        var generic_args: kairo::std::StackBuf<ChainType::GenericArg, 4>
        var ok = self.dyn()->_parse_generic_args(&generic_args)
        if self.dyn()->_pending_close_angle {
            self.dyn()->_pending_close_angle = false
        }

        if ok && !generic_args.is_empty() {
            var k = self.dyn()->ig_kind()
            if k == TokenKind::OpLParen
                || k == TokenKind::OpDot
                || k == TokenKind::OpArrow
                || k == TokenKind::OpColonColon
                || k == TokenKind::OpQuestionDot
                || k == TokenKind::OpQuestionArrow
                || k == TokenKind::OpLSquare
                || k == TokenKind::OpLBrace
                || k == TokenKind::OpComma
                || k == TokenKind::OpSemicolon
                || k == TokenKind::OpRParen
                || k == TokenKind::OpRSquare
                || k == TokenKind::OpRBrace
                || k == TokenKind::TkNewLine
                || k == TokenKind::TkEof {
                var ops: kairo::std::StackBuf<Token, 2>
                ops.push_back(op_tok)
                result->op_tokens.from_buf(ops.data(), ops.size(), self.dyn()->ctx)
                result->generic_args.from_buf(
                    generic_args.data(),
                    generic_args.size(),
                    self.dyn()->ctx,
                )

                result->range = sep_range | self.dyn()->prev().range
                t.commit()
                return true
            }
        }

        // rollback: the guard restores the cursor, but NOT the token buffer.
        // put the fused `<<` token back so the shift-op fallback sees it whole.
        ll_ptr->kind  = TokenKind::OpLessLess
        ll_ptr->range = ll_range
        return false
    }

    /// \brief flushes accumulated chain steps into a ChainExpr wrapping base.
    ///        if no steps are pending, returns base unchanged.
    inline fn _flush_chain(self,
                           base:         unsafe *Expr,
                           @inout steps: kairo::std::StackBuf<ChainExpr::Step, 8>,
                           chain_start:  SourceRange) -> unsafe *Expr {
        if steps.size() == 0 {
            return base
        }

        var end_range  = self.dyn()->prev().range
        var full_range = chain_start | end_range

        var ce = ChainExpr::create(self.dyn()->ctx, full_range, base)
        ce->steps.from_buf(steps.data(), steps.size(), self.dyn()->ctx)

        steps.clear() // consume the accumulator; without this, the next
        // flush re-freezes these same steps onto the next chain

        return ce
    }

    //  Call expression

    /// \brief parses a function call: callee ( args )
    ///        supports named arguments: foo(x: 10, y: 20)
    ///
    /// precondition: current token is `(`
    inline fn _parse_call_expr(self, callee: unsafe *Expr) -> unsafe *Expr {
        var lparen_range = self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::After) // consume `(`

        var args: kairo::std::StackBuf<*Expr, 8>

        // empty arg list: foo()
        if self.dyn()->check(TokenKind::OpRParen) {
            var rparen_range = self.dyn()->current_ptr()->range
            self.dyn()->advance() // consume `)`

            var ce = Expressions::CallExpr::create(
                self.dyn()->ctx,
                callee->range | rparen_range,
                callee,
            )

            // args stays empty
            return ce
        }

        // an argument list is bracket-delimited, so newlines inside it are not
        // significant - `)` terminates it, not the line break. Suppression is
        // scoped to the argument scan only: the closing `)` below is consumed
        // outside it so a statement terminator after the call survives.
        self.dyn()->nl_push()
        self._parse_call_args(&args, lparen_range)
        self.dyn()->nl_pop()

        // expect closing `)`
        self.dyn()->advance(T::SkipNL::Only)
        var end_range = self.dyn()->prev().range
        if self.dyn()->check(TokenKind::OpRParen) {
            end_range = self.dyn()->current_ptr()->range
            self.dyn()->advance() // consume `)`
        } else {
            self.dyn()->diag->report(
                DiagID::S054E,
                lparen_range.start,
                "expected ')' to close function call argument list",
            ).first(lparen_range)->emit()
            self._sync_expr(Self::ExprSyncCtx::Paren, 1, 0, 0, true)
            end_range = self.dyn()->prev().range
        }

        var ce = Expressions::CallExpr::create(self.dyn()->ctx, callee->range | end_range, callee)
        ce->args.from_buf(args.data(), args.size(), self.dyn()->ctx)
        return ce
    }

    /// \brief parses comma-separated call arguments.
    ///        handles named args (name: expr) and positional args (expr).
    ///
    /// named args are parsed as AssignOperatorExpr with lhs=NamedIdentExpr
    /// and rhs=value. sema distinguishes named vs positional by checking
    /// if the arg is an AssignOperatorExpr with a bare NamedIdentExpr lhs.
    pub fn _parse_call_args(self,
                            out:         unsafe *kairo::std::StackBuf<unsafe *Expr, 8>,
                            start_range: SourceRange) {
        while !self.dyn()->is_eof() {
            self.dyn()->advance(T::SkipNL::Only)

            if self.dyn()->check(TokenKind::OpRParen) {
                return
            }

            if self.dyn()->check(TokenKind::TkCodeComplete) {
                self.dyn()->maybe_complete(CompletionContextKind::ExprStart)
                self.dyn()->advance(T::SkipNL::After)
                return
            }

            // bail if we've clearly left the call context
            if self._is_decl_keyword(self.dyn()->ig_kind()) {
                return
            }

            // check for named argument: ident `:` expr (but not ident `::`)
            if self.dyn()->check(TokenKind::LitIdentifier)
                && self.dyn()->check_peek(TokenKind::OpColon)
                && !self.dyn()->check_peek(TokenKind::OpColonColon) {
                var name_ptr   = self.dyn()->current_ptr()
                var name_range = name_ptr->range
                var name_tok   = *name_ptr

                self.dyn()->advance()                 // consume identifier
                self.dyn()->advance(T::SkipNL::After) // consume `:`

                var unsafe *value = self.parse_expr(
                    self.stop_on(Self::ExprStopKind::StopComma).plus(Self::ExprStopKind::StopParen),
                )

                if value == &null {
                    self.dyn()->diag->report(
                        DiagID::S052E,
                        name_range.start,
                        "expected expression after ':' in named argument",
                    ).first(name_range)->emit()

                    if self._is_decl_keyword(self.dyn()->ig_kind()) {
                        return
                    }

                    self._sync_expr_progress(Self::ExprSyncCtx::Comma, 1)
                } else {
                    // A real node, not an AssignOperatorExpr wearing a `:`.
                    // The label was never an expression, and every reader of
                    // an argument list had to know to step around it.
                    var named = Expressions::NamedArgExpr::create(
                        self.dyn()->ctx,
                        name_range | value->range,
                        name_tok,
                        value,
                    )

                    out->push_back(named)
                }
            } else {
                // positional argument
                var unsafe *arg = self.parse_expr(
                    self.stop_on(Self::ExprStopKind::StopComma).plus(Self::ExprStopKind::StopParen),
                )

                if arg == &null || is_recovery(arg) {
                    if self._is_decl_keyword(self.dyn()->ig_kind()) {
                        return
                    }

                    self._sync_expr_progress(Self::ExprSyncCtx::Comma, 1)

                    // sync guarantees progress; let the outer loop handle
                    // whatever we landed on
                    continue
                } else {
                    out->push_back(arg)
                }
            }

            // consume comma between args
            if self.dyn()->check(TokenKind::OpComma) {
                self.dyn()->advance(T::SkipNL::After)

                // trailing comma before closer: foo(a, b,)
                if self.dyn()->check(TokenKind::OpRParen) {
                    return
                }

                continue
            }

            self.dyn()->advance(T::SkipNL::Only)

            // no comma and not `)` missing separator
            if !self.dyn()->check(TokenKind::OpRParen) {
                // check bail before reporting
                if self._is_decl_keyword(self.dyn()->ig_kind()) {
                    return
                }

                self.dyn()->report_tok(
                    DiagID::S054E,
                    self.dyn()->current_ptr(),
                    "expected ',' or ')' after argument in function call",
                )

                self._sync_expr(Self::ExprSyncCtx::Paren, 1, 0, 0, true)
            }
        }
    }

    /// \brief returns true if the token kind is a declaration/statement keyword
    ///        that should never appear inside a call argument list.
    ///        used to bail out of arg parsing when sync has overshot.
    priv fn _is_decl_keyword(self, k: TokenKind) -> bool {
        return k == TokenKind::KwClass
            || k == TokenKind::KwStruct
            || k == TokenKind::KwEnum
            || k == TokenKind::KwInterface
            || k == TokenKind::KwUnion
            || k == TokenKind::KwModule
            || k == TokenKind::KwImport
            || k == TokenKind::KwFfi
            || k == TokenKind::KwExtend
            || k == TokenKind::KwType
            || k == TokenKind::KwTest
            || k == TokenKind::KwMacro
            || k == TokenKind::KwPub
            || k == TokenKind::KwPriv
            || k == TokenKind::KwProt
            || k == TokenKind::KwReturn
            || k == TokenKind::KwBreak
            || k == TokenKind::KwContinue
            || k == TokenKind::KwWhile
            || k == TokenKind::KwFor
            || k == TokenKind::KwLoop
            || k == TokenKind::TkEof
    }

    //  Subscript expression

    /// \brief parses a subscript: base [ index ]
    ///
    /// precondition: current token is `[`
    inline fn _parse_subscript_expr(self, base: unsafe *Expr) -> unsafe *Expr {
        var lsquare_range = self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::After) // consume `[`

        if self.dyn()->check(TokenKind::OpRSquare) {
            self.dyn()->diag->report(
                DiagID::S054E,
                lsquare_range.start,
                "expected index expression inside '[]'",
            ).first(lsquare_range)->emit()
            var rsquare_range = self.dyn()->current_ptr()->range
            self.dyn()->advance() // consume `]`
            return Expressions::SubscriptExpr::create_error(
                self.dyn()->ctx,
                base->range | rsquare_range,
            )
        }

        // bracket-delimited like an argument list: `]` ends the index, not
        // a newline. Popped before `]`, so its trailing newline stays.
        self.dyn()->nl_push()
        var unsafe *index = self.parse_expr(self.stop_on(Self::ExprStopKind::StopSquare))
        self.dyn()->nl_pop()

        if index == &null {
            self.dyn()->diag->report(
                DiagID::S052E,
                lsquare_range.start,
                "expected index expression after '['",
            ).first(lsquare_range)->emit()
            self._sync_expr(Self::ExprSyncCtx::Square, 0, 1)
            return Expressions::SubscriptExpr::create_error(
                self.dyn()->ctx,
                base->range | self.dyn()->prev().range,
            )
        }

        var end_range = self.dyn()->prev().range
        if self.dyn()->check(TokenKind::OpRSquare) {
            end_range = self.dyn()->current_ptr()->range
            self.dyn()->advance() // consume `]`
        } else {
            self.dyn()->diag->report(
                DiagID::S054E,
                lsquare_range.start,
                "expected ']' after index expression",
            ).first(lsquare_range)->emit()
            self._sync_expr(Self::ExprSyncCtx::Square, 0, 1, 0, true)
            end_range = self.dyn()->prev().range
        }

        return Expressions::SubscriptExpr::create(
            self.dyn()->ctx,
            base->range | end_range,
            base,
            index,
        )
    }

    //  Type cast

    /// \brief speculatively parses `as Type` / `as unsafe *Type`.
    ///
    /// \details handles the cast-vs-context-binding ambiguity. On a clean type
    ///          parse with no trailing `{`, commits and returns the cast. On
    ///          failure the type recovers (e.g. `(var a, ...)`), or a `{`
    ///          follows the parsed type (`as const x { ... }`, a binding header,
    ///          since a cast is never followed by a brace) rolls the cursor
    ///          back to `as`, discards speculative diagnostics, and returns null
    ///          so the statement layer routes to context binding.
    ///
    /// precondition: current token is `as`.
    inline fn _try_type_cast(self, operand: unsafe *Expr, stop: Self::ExprStop) -> unsafe *Expr {
        type ASTTentativeGuard = T::TentativeGuard
        var t = ASTTentativeGuard(self.dyn())

        self.dyn()->advance() // consume `as`

        // The word after `as` picks the cast MODE. `const` and `unsafe` are
        // also type qualifiers, so they are peeked and left for parse_type to
        // consume: `as const T` must still produce a const-spelled target (the
        // const-cast rung compares the written type), and `as unsafe *T` must
        // produce the `unsafe *T` canonical, which only the qualifier path
        // builds. `static` is not a qualifier, so it is eaten here.
        var mode      = Expressions::CastMode::Default
        var is_unsafe = false
        if self.dyn()->check(TokenKind::KwUnsafe) {
            mode      = Expressions::CastMode::Unsafe
            is_unsafe = true
        } else if self.dyn()->check(TokenKind::KwConst) {
            mode = Expressions::CastMode::Const
        } else if self.dyn()->check(TokenKind::KwStatic) {
            mode = Expressions::CastMode::Static
            self.dyn()->advance()
        }

        var target = self.dyn()->parse_type()
        if target == &null || is_recovery(target) {
            return &null // guard dtor pops suppress + rolls cursor back to `as`
        }

        // tiebreaker: a `{` after the parsed type is a context-binding body
        // (`as const x { ... }`), never a cast. roll back. Not in a head that
        // ends at `{` (NoStructLiteral: if / while / for / match / where):
        // a binding cannot appear there, and the brace is the body, so
        // `if m == x as unsafe *u8 {` is a cast.
        var in_head = stop.has(Self::ExprStopKind::NoStructLiteral)
        if !in_head && self.dyn()->check(TokenKind::OpLBrace) {
            return &null
        }

        t.commit()
        return Expressions::TypeCastExpr::create(
            self.dyn()->ctx,
            operand->range | target->range,
            operand,
            target,
            is_unsafe,
            mode,
        )
    }

    //  Primary expression dispatch

    /// \brief dispatches the current token to the correct primary production.
    ///
    /// handles: integer/float/string/char/bool/null literals, identifiers
    /// (with optional generic args), parenthesized expressions and tuple
    /// literals, array/set/map literals, closure expressions.
    priv fn _parse_primary_expr(self,
                                stop: Self::ExprStop = FlagSet<ExprStopBit, u8>()) -> unsafe *Expr {
        if self.dyn()->is_eof() {
            return &null
        }

        var cur_ptr = self.dyn()->current_ptr()
        if cur_ptr == &null {
            return &null
        }

        var cur_range = cur_ptr->range

        while true {
            if self.dyn()->check(TokenKind::KwFinal) {
                var r = self.dyn()->current_ptr()->range
                self.dyn()->diag->report(
                    DiagID::S052E,
                    r.start,
                    "'final' is not valid in this position of an expression",
                ).first(r)->emit()
                self.dyn()->advance()
            } else if self.dyn()->check(TokenKind::KwInline) {
                var r = self.dyn()->current_ptr()->range
                self.dyn()->diag->report(
                    DiagID::S052E,
                    r.start,
                    "'inline' is not valid in this position of an expression",
                ).first(r)->emit()
                self.dyn()->advance()
            } else if self.dyn()->check(TokenKind::KwPanic) {
                var r = self.dyn()->current_ptr()->range
                self.dyn()->diag->report(
                    DiagID::S052E,
                    r.start,
                    "'panic' is not valid in this position of an expression",
                ).first(r)->emit()
                self.dyn()->advance()
            } else if self.dyn()->check(TokenKind::KwVolatile) {
                var r = self.dyn()->current_ptr()->range
                self.dyn()->diag->report(
                    DiagID::S052E,
                    r.start,
                    "'volatile' is not valid in this position of an expression",
                ).first(r)->emit()
                self.dyn()->advance()
            } else if self.dyn()->check(TokenKind::KwAsync) {
                var r = self.dyn()->current_ptr()->range
                self.dyn()->diag->report(
                    DiagID::S052E,
                    r.start,
                    "'async' is not valid in this position of an expression",
                ).first(r)->emit()
                self.dyn()->advance()
            } else {
                cur_ptr = self.dyn()->current_ptr()
                if cur_ptr == &null {
                    break
                }

                cur_range = cur_ptr->range
                break
            }
        }

        // the rejected keywords above may have been the last tokens (`[ panic`):
        // same contract as the EOF check on entry, the caller reports it.
        if cur_ptr == &null {
            return &null
        }

        /// # integer literal
        if self.dyn()->check(TokenKind::LitInt) {
            var tok = self.dyn()->current()
            self.dyn()->advance()
            return IntegerLiteralExpr::create(self.dyn()->ctx, tok.range, tok)
        }

        /// # float literal
        if self.dyn()->check(TokenKind::LitFloat) {
            var tok = self.dyn()->current()
            self.dyn()->advance()
            return FloatingLiteralExpr::create(self.dyn()->ctx, tok.range, tok)
        }

        /// # string literal
        if self.dyn()->check(TokenKind::LitString) {
            var tok = self.dyn()->current()
            self.dyn()->advance()
            return self._parse_string_literal(tok)
        }

        /// # char literal
        if self.dyn()->check(TokenKind::LitChar) {
            var tok = self.dyn()->current()
            self.dyn()->advance()
            return CharacterLiteralExpr::create(self.dyn()->ctx, tok.range, tok)
        }

        /// # bool literal: true
        if self.dyn()->check(TokenKind::KwTrue) {
            var tok_range = cur_range
            self.dyn()->advance()
            return BooleanLiteralExpr::create(self.dyn()->ctx, tok_range, true)
        }

        /// # bool literal: false
        if self.dyn()->check(TokenKind::KwFalse) {
            var tok_range = cur_range
            self.dyn()->advance()
            return BooleanLiteralExpr::create(self.dyn()->ctx, tok_range, false)
        }

        /// # null literal
        if self.dyn()->check(TokenKind::LitNull) {
            var tok_range = cur_range
            self.dyn()->advance()
            return NullLiteralExpr::create(self.dyn()->ctx, tok_range, false)
        }

        /// # parenthesized expr or tuple literal
        if self.dyn()->check(TokenKind::OpLParen) {
            return self._parse_paren_expr()
        }

        /// # square bracket: array literal
        if self.dyn()->check(TokenKind::OpLSquare) {
            return self._parse_list_literal()
        }

        /// # brace: set/map literal or anon initializer
        if self.dyn()->check(TokenKind::OpLBrace) {
            return self._parse_brace_expr()
        }

        /// # closure: fn
        if self.dyn()->check(TokenKind::KwFn) {
            return unsafe (self._parse_closure_expr() as unsafe *Expr)
        }

        /// # keyword prefix: if
        if self.dyn()->check(TokenKind::KwIf) {
            return self._parse_if_expr(stop)
        }

        /// # keyword prefix: try
        if self.dyn()->check(TokenKind::KwTry) {
            return self._parse_try_catch_expr(stop)
        }

        /// # keyword prefix: match
        if self.dyn()->check(TokenKind::KwMatch) {
            return self._parse_match_expr()
        }

        /// # code completion
        if self.dyn()->check(TokenKind::TkCodeComplete) {
            self.dyn()->maybe_complete(CompletionContextKind::ExprStart)
            self.dyn()->advance(T::SkipNL::After)
            return self._error_expr(cur_range)
        }

        if self.dyn()->check(TokenKind::OpRange) || self.dyn()->check(TokenKind::OpRangeEqual) {
            var op_tok       = self.dyn()->current_ptr()
            var op_range     = op_tok->range
            var is_inclusive = self.dyn()->check(TokenKind::OpRangeEqual)
            self.dyn()->advance() // newlines stay significant, as in _parse_range_expr

            if !self._range_has_upper(stop) {
                if is_inclusive {
                    self._inclusive_needs_upper(op_tok)
                }

                return Expressions::RangeExpr::create(
                    self.dyn()->ctx,
                    op_range,
                    &null,
                    &null,
                    is_inclusive,
                )
            }

            var unsafe *rhs      = self._parse_cast_expr(stop)
            var        end_range = if (rhs != &null) => (rhs->range) else => op_range
            return Expressions::RangeExpr::create(
                self.dyn()->ctx,
                op_range | end_range,
                &null,
                rhs,
                is_inclusive,
            )
        }

        /// # primitive head: u32(-1), usize(argc), i32::MAX
        /// A primitive type token is not a value, so it can only open an
        /// expression when something follows that makes it one: `(` applies
        /// it (a conversion), `::` names a member of it (an associated
        /// constant). Gating on those two keeps a bare `u32` in value position
        /// reporting "expected expression" instead of silently parsing as a
        /// name. Postfix then sees the `(` or `::` and builds the CallExpr or
        /// the chain, exactly as it does after an identifier.
        /// `typeof u32` and `typeof T == u32` (eval.md "Type-based
        /// branching") name the type itself: after `typeof`, or as the
        /// other side of an equality, a bare primitive is the type operand
        /// OperatorTyping compares (a value comparison still reports it as a
        /// type, not a value, in Sema).
        var pk = self.dyn()->prev().kind
        var type_operand = pk == TokenKind::KwTypeOf
            || pk == TokenKind::OpEqualEqual
            || pk == TokenKind::OpExclaimEqual
            || pk == TokenKind::KwNotEq
        if self.dyn()->check(
            fn(k: TokenKind) -> bool {
                return is_annotation(k)
            },
        )
            && (type_operand
                || self.dyn()->ig_peek_kind() == TokenKind::OpLParen
                || self.dyn()->ig_peek_kind() == TokenKind::OpColonColon) {
            if self.dyn()->ig_peek_kind() == TokenKind::OpColonColon && self.dyn()->tu != &null {
                self.dyn()->tu->has_prim_member = true // PrimitiveLimitDesugar mints it.
            }

            return self._parse_ident_expr()
        }

        // -- is_trivially_copyable!(T) / is_trivially_destructible!(T): type
        // facts (Compiler/Spec/Eval.md#deferred-conditions), parser intrinsics the PP passes through raw,
        // as unwrap! is. Their operand is a TYPE.
        if self.dyn()->check(TokenKind::LitIdentifier)
            && self.dyn()->check_peek(TokenKind::OpExclaim)
            && Expressions::type_trait_of(
                self.dyn()->ctx->get_spelling(self.dyn()->current()),
            ) != Expressions::TypeTraitKind::None {
            return self._parse_type_trait_intrinsic()
        }

        // -- unwrap!(expr): a parser intrinsic, passed through raw by the
        // PP (Preprocessor::_detect_invocation), as label!/jump! are.
        if self.dyn()->check(TokenKind::LitIdentifier)
            && self.dyn()->check_peek(TokenKind::OpExclaim)
            && self.dyn()->ctx->get_spelling(self.dyn()->current()) == LangIntrinsics::unwrap() {
            return self._parse_unwrap_intrinsic()
        }

        // -- defined!(NAME) the PP's table could not answer (it passes those
        // through raw, Preprocessor::_builtin_defined): clang's macros do.
        if self.dyn()->check(TokenKind::LitIdentifier)
            && self.dyn()->check_peek(TokenKind::OpExclaim)
            && self.dyn()->ctx->get_spelling(self.dyn()->current()) == LangIntrinsics::defined() {
            return self._parse_defined_intrinsic()
        }

        /// # identifier (including `self`)
        if self.dyn()->check(
            fn(k: TokenKind) -> bool {
                return Self::_is_expr_ident_kind(k)
            },
        ) {
            return self._parse_ident_expr()
        }

        /// # global root path: ::foo
        if self.dyn()->check(TokenKind::OpColonColon) {
            return self._parse_global_root_expr()
        }

        /// # leading dot: .Variant | .Variant { f: e }
        if self.dyn()->check(TokenKind::OpDot) {
            return self._parse_dotted_variant(stop)
        }

        /// # no production matched
        var resolved = self.dyn()->resolve_deep(cur_ptr)

        // poisoned macro expansion: the PP already reported the real error at
        // the invocation site. A second "expected expression" here is pure
        // noise consume the sentinel and recover silently.
        if (resolved.kind as u32) == (TokenKind::TkMacroExpand as u32)
            && resolved.imm == (MacroSentinel::Poison as u32) {
            self.dyn()->advance()
            return self._error_expr(cur_range)
        }

        self.dyn()->diag->report(
            DiagID::S052E,
            cur_range.start,
            f"expected expression, found '{token_kind_to_readable_string(resolved.kind)}'",
        ).first(cur_range)->emit()

        self.dyn()->advance() // skip to prevent infinite loop
        return self._error_expr(cur_range)
    }

    //  Identifier expression (with optional generic args)

    /// \brief parses a bare identifier, optionally followed by generic args
    ///        if the hoisted scope indicates it's generic.
    ///
    /// foo       -> NamedIdentExpr("foo")
    /// Bar<i32>  -> NamedIdentExpr("Bar", generic_args=[i32])
    /// self      -> NamedIdentExpr("self")
    inline fn _parse_ident_expr(self) -> unsafe *Expr {
        type ASTTentativeGuard = T::TentativeGuard

        var id_ptr   = self.dyn()->current_ptr()
        var id_range = id_ptr->range
        var id_tok   = *id_ptr
        self.dyn()->advance() // consume identifier

        var nte = NamedIdentExpr::create(self.dyn()->ctx, id_range, id_tok)

        // check for generic args: Foo<T>
        // three-state verdict (rule 3/4): known generic commits generic args,
        // known non-generic commits comparison (rule 4 no tentative), and
        // only genuinely unknown names run the tentative parse.
        if self.dyn()->check(TokenKind::OpLess) && self._can_take_generic_args(id_tok) {
            var verdict = self._generic_verdict(*id_ptr)
            if verdict == Self::GenericVerdict::Generic {
                var generic_args: kairo::std::StackBuf<ChainType::GenericArg, 4>
                self.dyn()->_parse_generic_args(&generic_args)
                if self.dyn()->_pending_close_angle {
                    self.dyn()->_pending_close_angle = false
                }

                nte->generic_args.from_buf(
                    generic_args.data(),
                    generic_args.size(),
                    self.dyn()->ctx,
                )

                nte->range = id_range | self.dyn()->prev().range
            } else if verdict == Self::GenericVerdict::Unknown { // no evidence tentative parse
                var t = ASTTentativeGuard(self.dyn())
                var generic_args: kairo::std::StackBuf<ChainType::GenericArg, 4>
                var ok = self.dyn()->_parse_generic_args(&generic_args)

                if self.dyn()->_pending_close_angle {
                    self.dyn()->_pending_close_angle = false
                }

                if ok && !generic_args.is_empty() {
                    // check what follows: must be a valid postfix continuation
                    var k = self.dyn()->ig_kind()
                    if k == TokenKind::OpLParen
                        || k == TokenKind::OpDot
                        || k == TokenKind::OpArrow
                        || k == TokenKind::OpColonColon
                        || k == TokenKind::OpQuestionDot
                        || k == TokenKind::OpQuestionArrow
                        || k == TokenKind::OpLSquare
                        || k == TokenKind::OpLBrace
                        || k == TokenKind::OpComma
                        || k == TokenKind::OpSemicolon
                        || k == TokenKind::OpRParen
                        || k == TokenKind::OpRSquare
                        || k == TokenKind::OpRBrace
                        || k == TokenKind::TkNewLine
                        || k == TokenKind::TkEof {
                        // commit
                        nte->generic_args.from_buf(
                            generic_args.data(),
                            generic_args.size(),
                            self.dyn()->ctx,
                        )

                        nte->range = id_range | self.dyn()->prev().range
                        t.commit()
                    }
                }
            }
        }

        return nte
    }

    //  Leading-dot variant: .Variant | .Variant { field: value, ... }

    /// \brief parses `.Variant`, a variant of the enum the expected type
    ///        names, alone or with its payload in braces.
    ///
    /// \details nothing is looked up: as for the `.Variant` pattern, which enum
    ///          is a sema fact. Both forms are a NamedInitializerExpr with no
    ///          head, `is_dotted` set and `has_braces` saying which was written.
    ///          Where NoStructLiteral holds the `{` is left for the caller, as
    ///          the postfix loop leaves it after a path: in `if x == .A { }`
    ///          it is the block.
    ///
    /// precondition: current token is `.`
    priv fn _parse_dotted_variant(self, stop: Self::ExprStop) -> unsafe *Expr {
        var dot_range = self.dyn()->current_ptr()->range
        self.dyn()->advance() // consume `.`

        if !self.dyn()->check(TokenKind::LitIdentifier) {
            self.dyn()->diag->report(
                DiagID::S054E,
                dot_range.start,
                "expected a variant name after '.'",
            ).first(dot_range)->emit()
            return Expressions::NamedInitializerExpr::create_error(self.dyn()->ctx, dot_range)
        }

        var name = self.dyn()->current()
        self.dyn()->advance() // consume the variant name
        var head_range = dot_range | name.range

        var suppressed              = stop.has(Self::ExprStopKind::NoStructLiteral)
        var braces                  = !suppressed && self.dyn()->check(TokenKind::OpLBrace)
        var e:         unsafe *Expr = &null
        if braces {
            e = self._parse_init_braces(&null, head_range)
        } else {
            e = Expressions::NamedInitializerExpr::create(self.dyn()->ctx, head_range, &null)
        }

        if isa<Expressions::NamedInitializerExpr>(e) {
            var unsafe *ni = cast<Expressions::NamedInitializerExpr>(e)
            ni->is_dotted   = true
            ni->dotted_name = name
            ni->has_braces  = braces
        }

        return e
    }

    //  Global root path: ::foo::bar

    inline fn _parse_global_root_expr(self) -> unsafe *Expr {
        var start_range = self.dyn()->current_ptr()->range
        self.dyn()->advance() // consume leading `::`

        // expect identifier after `::`
        if !self.dyn()->check(
            fn(k: TokenKind) -> bool {
                return Self::_is_expr_ident_kind(k)
            },
        ) {
            self.dyn()->diag->report(
                DiagID::S054E,
                start_range.start,
                "expected identifier after '::' in global scope path",
            ).first(start_range)->emit()
            return self._error_expr(start_range)
        }

        var id_ptr   = self.dyn()->current_ptr()
        var id_range = id_ptr->range
        self.dyn()->advance() // consume identifier

        var nte = NamedIdentExpr::create(self.dyn()->ctx, id_range, *id_ptr)

        // build a global-root chain with first step
        var first_step = ChainExpr::Step{}
        first_step.name          = nte
        first_step.access_kind   = ChainExpr::AccessKind::ColonColon
        first_step.range         = start_range | id_range
        first_step.resolved_type = &null
        first_step.resolved_decl = &null

        // check for generic args on first segment
        if self.dyn()->check(TokenKind::OpLess) && self._can_take_generic_args(*id_ptr) {
            if self._is_generic_name(*id_ptr) {
                var generic_args: kairo::std::StackBuf<ChainType::GenericArg, 4>
                self.dyn()->_parse_generic_args(&generic_args)
                if self.dyn()->_pending_close_angle {
                    self.dyn()->_pending_close_angle = false
                }

                first_step.generic_args.from_buf(
                    generic_args.data(),
                    generic_args.size(),
                    self.dyn()->ctx,
                )

                first_step.range = start_range | self.dyn()->prev().range
            }
        }

        var ce = ChainExpr::create_global(self.dyn()->ctx, start_range | self.dyn()->prev().range)

        // we need to put the first step in, but more steps may follow
        // via the postfix loop. so we create the chain with just this one step.
        // the postfix loop will NOT add to this chain (it creates new ChainExprs
        // wrapping this one). but :: steps after this one come through the postfix
        // loop's access step accumulation, which creates a new chain wrapping
        // this global-root chain as base. that's correct: ::foo::bar becomes
        // ChainExpr(base=ChainExpr(global, [::foo]), steps=[::bar]).
        //
        // actually that's one level of nesting too deep. let's just return
        // the NamedIdentExpr and let the postfix loop handle the rest, but
        // mark that we started with a global root. hmm, that loses the `::` prefix
        // information.
        //
        // simplest: create the global chain now with one step. if more :: follow
        // in the postfix loop, they accumulate in the same chain via the step buffer.
        // but the postfix loop creates steps on a NEW chain wrapping this one as base.
        //
        // ok this is fine. ::foo::bar::baz is:
        //   postfix loop sees base = ChainExpr(global, [::foo])
        //   then accumulates steps [::bar, ::baz]
        //   flush_chain wraps: ChainExpr(base=ChainExpr(global, [::foo]), steps=[::bar, ::baz])
        //
        // that nests one level but it's correct and sema can flatten if needed.

        var steps_buf: kairo::std::StackBuf<ChainExpr::Step, 1>
        steps_buf.push_back(first_step)
        ce->steps.from_buf(steps_buf.data(), steps_buf.size(), self.dyn()->ctx)
        ce->range = start_range | self.dyn()->prev().range

        return ce
    }

    //  Parenthesized expression / tuple literal

    /// \brief parses (expr) or (expr, expr, ...)
    ///        single expr -> unwrapped (no GroupingExpr since CST not needed)
    ///        comma-separated -> TupleLiteralExpr
    /// TODO apply the same nl logic to <> [] and {} parse functions
    inline fn _parse_paren_expr(self) -> unsafe *Expr {
        var lparen_range = self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::After) // consume `(`
        self.dyn()->nl_push()

        if self.dyn()->check(TokenKind::OpRParen) {
            var rparen_range = self.dyn()->current_ptr()->range
            self.dyn()->nl_pop()
            self.dyn()->advance_raw()
            self.dyn()->diag->report(
                DiagID::S054E,
                lparen_range.start,
                "empty parenthesized expression is not valid, did you mean to call a function?",
            ).first(lparen_range | rparen_range)->emit()
            return self._error_expr(lparen_range | rparen_range)
        }

        // `(` `{` is ALWAYS a statement expression, never a parenthesized
        // set/map literal or anon initializer: one token of lookahead decides
        // it, so the reading cannot depend on what the braces contain.
        if self.dyn()->check(TokenKind::OpLBrace) {
            self.dyn()->nl_pop()
            return self._finish_stmt_expr(lparen_range)
        }

        var unsafe *first = self.parse_expr(
            self.stop_on(Self::ExprStopKind::StopComma).plus(Self::ExprStopKind::StopParen),
        )

        if first == &null {
            self.dyn()->diag->report(
                DiagID::S052E,
                lparen_range.start,
                "expected expression after '('",
            ).first(lparen_range)->emit()
            self._sync_expr(Self::ExprSyncCtx::Paren, 1, 0, 0, true)
            self.dyn()->nl_pop()
            return self._error_expr(lparen_range | self.dyn()->prev().range)
        }

        if self.dyn()->check(TokenKind::OpComma) {
            // _finish_tuple_literal pops on all of its exits
            return self._finish_tuple_literal(lparen_range, first)
        }

        self.dyn()->nl_pop()
        if self.dyn()->check(TokenKind::OpRParen) {
            self.dyn()->advance_raw() // consume `)` keep trailing NL significant
            // the parens leave no node; remember them for _is_open_form, and
            // for a binary operator, whose grouping the derives clause's
            // mixed-operator warning reads (is_parenthesized).
            if isa<Expressions::IfExpr>(first)
                || isa<Expressions::TryCatchExpr>(first)
                || isa<Expressions::BinaryOperatorExpr>(first) {
                self._parened_open.push_back(first)
            }

            return first
        }

        // missing `)` report WITHOUT eating the offending token (old code
        // advanced blindly and could swallow the statement terminator).
        self.dyn()->diag->report(
            DiagID::S054E,
            first->range.start,
            "expected ')' or ',' after expression",
        ).first(first->range)->emit()
        return first
    }

    /// \brief finishes a statement expression after its `(`; current is `{`.
    ///  Grammar:  '(' '{' stmt* expr-stmt '}' ')'
    ///
    /// \details the value is the last statement, so it MUST be an
    ///          ExpressionStmt; anything else (including an empty block) is a
    ///          hard error and yields a RecoveryExpr, so Sema never sees a
    ///          StmtExpr without a value slot.
    inline fn _finish_stmt_expr(self, lparen_range: SourceRange) -> *Expr {
        var lbrace_range = self.dyn()->current_ptr()->range

        // The block is a statement context even though it sits inside `(`:
        // newlines terminate statements again. Left suppressed, `a` newline
        // `-b` in the block would fold into the single statement `a - b`.
        var saved_nl = self.dyn()->nl_depth
        self.dyn()->nl_depth = 0
        var body = self.dyn()->parse_compound()
        self.dyn()->nl_depth = saved_nl

        // `}` and `)` may be split across lines, but only look past the
        // newline when `)` is really there, else the terminator the caller
        // needs is gone.
        if self.dyn()->peek_past_nl_kind() == TokenKind::OpRParen {
            self.dyn()->advance(T::SkipNL::Only)
        }

        var ok = true
        if self.dyn()->check(TokenKind::OpRParen) {
            self.dyn()->advance_raw() // consume `)` keep trailing NL significant
        } else {
            ok = false
            var at = self.dyn()->prev().range
            self.dyn()->diag->report(
                DiagID::S054E,
                at.end,
                "expected ')' to close statement expression",
            ).first(at)->second(
                lparen_range | lbrace_range,
                "statement expression opened here",
            )->insert(at.end, ")", "insert ')'")->emit()
        }

        var full_range = lparen_range | self.dyn()->prev().range

        // A block that already failed to parse has reported its own error;
        // judging its (partial) last statement would only pile on.
        if is_recovery(body) {
            return self._error_expr(full_range)
        }

        var n = body->body.size()
        if n == 0 {
            self.dyn()->diag->report(
                DiagID::S054E,
                lbrace_range.start,
                "statement expression has no value",
            ).first(body->range, "empty block")->note(
                lbrace_range.start,
                "the value of '({ ... })' is its last statement, which must be an expression",
            )->emit()
            return self._error_expr(full_range)
        }

        var last = body->body[n - 1]
        if !isa<ExpressionStmt>(last) && !is_recovery(last) {
            self.dyn()->diag->report(
                DiagID::S054E,
                last->range.start,
                "last statement of a statement expression must be an expression",
            ).first(last->range, "this statement has no value")->second(
                lparen_range | lbrace_range,
                "statement expression opened here",
            )->note(
                lbrace_range.start,
                "the value of '({ ... })' is its last statement, which must be an expression",
            )->emit()
            return self._error_expr(full_range)
        }

        if !ok || is_recovery(last) {
            return self._error_expr(full_range)
        }

        return Expressions::StmtExpr::create(self.dyn()->ctx, full_range, body)
    }

    /// \brief finishes parsing a tuple literal after the first element and comma.
    inline fn _finish_tuple_literal(self,
                                    start_range: SourceRange,
                                    first:       unsafe *Expr) -> unsafe *Expr {
        var elements: kairo::std::StackBuf<unsafe *Expr, 8>
        elements.push_back(first)

        var first_comma = self.dyn()->current_ptr()->range
        while self.dyn()->check(TokenKind::OpComma) {
            self.dyn()->advance(T::SkipNL::After) // consume `,`

            if self.dyn()->check(TokenKind::OpRParen) { // trailing comma
                break
            }

            var unsafe *elem = self.parse_expr(
                self.stop_on(Self::ExprStopKind::StopComma).plus(Self::ExprStopKind::StopParen),
            )

            if elem == &null || is_recovery(elem) {
                self._sync_expr_progress(Self::ExprSyncCtx::Comma, 1)
                continue
            }

            elements.push_back(elem)
        }

        var end_range = self.dyn()->prev().range
        if self.dyn()->check(TokenKind::OpRParen) {
            end_range = self.dyn()->current_ptr()->range
            self.dyn()->advance() // consume `)`
        } else {
            self.dyn()->diag->report(
                DiagID::S054E,
                start_range.start,
                "expected ')' to close tuple literal",
            ).first(start_range)->emit()
        }

        var full_range = start_range | end_range

        // `(a,)`: a one-element tuple does not exist (no record has arity
        // one, and `(T)` is a parenthesized type). The parentheses group.
        if elements.size() == 1 {
            self.dyn()->diag->report(
                DiagID::S054E,
                first_comma.start,
                "a one-element tuple does not exist; remove the trailing comma to parenthesize the expression",
            ).first(first_comma)->strike(first_comma)->emit()
            return first
        }

        var tuple = Expressions::TupleLiteralExpr::create(self.dyn()->ctx, full_range)
        tuple->elements.from_buf(elements.data(), elements.size(), self.dyn()->ctx)
        return tuple
    }

    //  Array literal: [expr, expr, ...]

    inline fn _parse_list_literal(self) -> unsafe *Expr {
        var lsquare_range = self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::After) // consume `[`

        // empty array: []
        if self.dyn()->check(TokenKind::OpRSquare) {
            var rsquare_range = self.dyn()->current_ptr()->range
            self.dyn()->advance()
            var ll = Expressions::ListLiteralExpr::create(
                self.dyn()->ctx,
                lsquare_range | rsquare_range,
            )

            return ll
        }

        var elements: kairo::std::StackBuf<unsafe *Expr, 8>

        // as in an argument list, newlines inside `[ ]` are not significant:
        // `[a,` newline `b` newline `]` and an element continued on the next
        // line both parse. Popped before `]`, so its trailing newline
        // stays the enclosing context's.
        self.dyn()->nl_push()
        while !self.dyn()->is_eof() {
            if self.dyn()->check(TokenKind::OpRSquare) {
                break
            }

            var unsafe *elem = self.parse_expr(
                self.stop_on(Self::ExprStopKind::StopComma).plus(Self::ExprStopKind::StopSquare),
            )

            if elem == &null || is_recovery(elem) {
                self._sync_expr_progress(Self::ExprSyncCtx::Comma, 0, 1)
                continue
            }

            elements.push_back(elem)

            if self.dyn()->check(TokenKind::OpComma) {
                self.dyn()->advance(T::SkipNL::After)
                continue
            }

            break
        }

        self.dyn()->nl_pop()

        var end_range = self.dyn()->prev().range
        if self.dyn()->check(TokenKind::OpRSquare) {
            end_range = self.dyn()->current_ptr()->range
            self.dyn()->advance()
        } else {
            self.dyn()->diag->report(
                DiagID::S054E,
                lsquare_range.start,
                "expected ']' to close array literal",
            ).first(lsquare_range)->emit()
        }

        var ll = Expressions::ListLiteralExpr::create(self.dyn()->ctx, lsquare_range | end_range)
        ll->elements.from_buf(elements.data(), elements.size(), self.dyn()->ctx)
        return ll
    }

    // String literal

    priv fn _parse_string_literal(self, tok: Token) -> *Expr {
        // The token reaching here passed check(LitString), but _resolve_and_check
        // re-badges a failed-string TkError (whose recovery imm == LitString) as
        // LitString, so a lex error can launder itself into this branch. Resolve
        // the macro chain and inspect the TRUE kind: if it's TkError, the string
        // never lexed; emit a recovery node instead of reading tok.imm as a
        // StringData index (which it isn't, it's the recovery TokenKind).

        type _StreamGuard = T::StreamGuard

        var resolved = self.dyn()->resolve_deep(&tok)
        if resolved.kind == TokenKind::TkError {
            return self._error_expr(tok.range)
        }

        // the payload's table, not this file's: a string from an imported
        // macro's body indexes the defining file's literals.
        var imm_tbl = self.dyn()->ctx->get_payload_table(tok)
        if imm_tbl == &null {
            // no imm table: bare plain node so the null-imm accessors are never hit.
            return ((StringLiteralExpr::create(
                self.dyn()->ctx,
                tok.range,
                tok,
                FlagSet<StringLiteralExpr::StringKind, u8>(),
            )))
        }

        var sdata = imm_tbl->get<Immediate::StringData>(resolved.imm)

        // map prefix_kind flags -> StringKind flags, bit by bit: the two
        // enums number Raw and Format differently. Both are sets, so raw|format
        // (rf) is representable.
        var skind = FlagSet<StringLiteralExpr::StringKind, u8>()
        if sdata != &null {
            if sdata->prefix_kind.has(Immediate::TextPrefixKind::Format) {
                skind.set(StringLiteralExpr::StringKind::Format)
            }

            if sdata->prefix_kind.has(Immediate::TextPrefixKind::Raw) {
                skind.set(StringLiteralExpr::StringKind::Raw)
            }
        }

        var node = StringLiteralExpr::create(self.dyn()->ctx, tok.range, tok, skind)
        node->imm = sdata // attach: every get_*/is_* accessor asserts on null imm

        // Parse holes off the DATA, not the kind: rf is both raw and format, and a
        // format string with zero holes needs no loop. exprs.size() > 0 is the
        // unambiguous "has holes" signal the lexer already computed.
        if sdata == &null || sdata->exprs.size() == 0 {
            return node
        }

        var parts: kairo::std::StackBuf<unsafe *Expr, 8>
        // A string another file wrote (an imported macro's body): its holes
        // are that file's raw tokens, whose imms index its tables, not ours.
        var foreign = imm_tbl != self.dyn()->ctx->get_imm_table()

        for var i: usize = 0; i < sdata->exprs.size(); ++i {
            var hole_buf   = sdata->exprs[i].0
            var hole_range = sdata->exprs[i].1

            if hole_buf == &null {
                parts.push_back(self._error_expr(hole_range))
                continue
            }

            var count       = hole_buf->size()
            var flat_tokens = self.dyn()->ctx->alloc_array<Token>(count)

            for var k: usize = 0; k < count; ++k {
                var t_ptr = hole_buf->get(k)
                if t_ptr != &null {
                    flat_tokens[k] = *t_ptr
                    if foreign {
                        flat_tokens[k] = self.dyn()->ctx->wrap_foreign_token(*t_ptr, tok)
                    }
                }
            }

            var hole_span = TokenSpan(flat_tokens, count)

            // swap the cursor onto the hole's TokenBuffer<16>, parse one expr,
            // restore. No TentativeGuard may outlive this scope.
            var hole_expr: unsafe *Expr = &null
            {
                var g = _StreamGuard(self.dyn(), hole_span)
                hole_expr = self.dyn()->parse_expr()
            } // g.op finally restores the main stream here

            if hole_expr == &null || is_recovery(hole_expr) {
                self.dyn()->diag->report(
                    DiagID::S052E,
                    hole_range.start,
                    "expected an expression inside f-string interpolation '{ }'",
                ).first(hole_range)->emit()
                parts.push_back(self._error_expr(hole_range))
                continue
            }

            parts.push_back(hole_expr)
        }

        node->parts.from_buf(parts.data(), parts.size(), self.dyn()->ctx)
        return node
    }

    //  Brace expression: set/map literal or anon initializer

    /// \brief parses { ... } which could be:
    ///        - set literal:        {1, 2, 3}
    ///        - map literal:        {"a": 1, "b": 2}
    ///        - anon initializer:   { .x: 1, .y: 2 }
    inline fn _parse_brace_expr(self) -> unsafe *Expr {
        var lbrace_range = self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::After) // consume `{`

        // empty braces
        if self.dyn()->check(TokenKind::OpRBrace) {
            var rbrace_range = self.dyn()->current_ptr()->range
            self.dyn()->advance()
            // empty set literal
            var sl = Expressions::SetLiteralExpr::create(
                self.dyn()->ctx,
                lbrace_range | rbrace_range,
            )

            return sl
        }

        // anon initializer: { .field: value, ... }
        if self.dyn()->check(TokenKind::OpDot) {
            return self._parse_anon_initializer(lbrace_range)
        }

        // parse first element to disambiguate set vs map
        var unsafe *first = self.parse_expr(
            self.stop_on(Self::ExprStopKind::StopComma).plus(Self::ExprStopKind::StopBrace),
        )

        if first == &null {
            self.dyn()->diag->report(
                DiagID::S052E,
                lbrace_range.start,
                "expected expression after '{'",
            ).first(lbrace_range)->emit()
            self._sync_expr(Self::ExprSyncCtx::Brace, 0, 0, 1)
            return self._error_expr(lbrace_range | self.dyn()->prev().range)
        }

        // map literal: { key: value, ... }
        if self.dyn()->check(TokenKind::OpColon) {
            return self._finish_map_literal(lbrace_range, first)
        }

        // set literal: { expr, ... }
        return self._finish_set_literal(lbrace_range, first)
    }

    inline fn _finish_set_literal(self, start_range: SourceRange, first: unsafe *Expr) -> *Expr {
        var elements: kairo::std::StackBuf<unsafe *Expr, 8>
        elements.push_back(first)

        while self.dyn()->check(TokenKind::OpComma) {
            self.dyn()->advance(T::SkipNL::After)

            if self.dyn()->check(TokenKind::OpRBrace) {
                break
            }

            var unsafe *elem = self.parse_expr(
                self.stop_on(Self::ExprStopKind::StopComma).plus(Self::ExprStopKind::StopBrace),
            )

            if elem == &null || is_recovery(elem) {
                self._sync_expr_progress(Self::ExprSyncCtx::Comma, 0, 0, 1)
                continue
            }

            elements.push_back(elem)
        }

        // a `}` on its own line closes the literal. The element loop only skips
        // newlines *after* a `,`, so a list without a trailing comma leaves the
        // cursor on the newline. `}` is consumed outside suppression so the
        // statement terminator after the literal survives.
        self.dyn()->advance(T::SkipNL::Only)

        var end_range = self.dyn()->prev().range
        if self.dyn()->check(TokenKind::OpRBrace) {
            end_range = self.dyn()->current_ptr()->range
            self.dyn()->advance()
        } else {
            self.dyn()->diag->report(
                DiagID::S054E,
                start_range.start,
                "expected '}' to close set literal",
            ).first(start_range)->emit()
        }

        var sl = Expressions::SetLiteralExpr::create(self.dyn()->ctx, start_range | end_range)
        sl->elements.from_buf(elements.data(), elements.size(), self.dyn()->ctx)
        return sl
    }

    inline fn _finish_map_literal(self,
                                  start_range: SourceRange,
                                  first_key:   unsafe *Expr) -> *Expr {
        // current token is `:` after first key
        var entries: kairo::std::StackBuf<Expressions::MapLiteralExpr::Entry, 8>

        // parse first value
        self.dyn()->advance(T::SkipNL::After) // consume `:`

        var unsafe *first_val = self.parse_expr(
            self.stop_on(Self::ExprStopKind::StopComma).plus(Self::ExprStopKind::StopBrace),
        )

        if first_val == &null {
            self.dyn()->diag->report(
                DiagID::S054E,
                start_range.start,
                "expected value after ':' in map literal",
            ).first(start_range)->emit()
            self._sync_expr(Self::ExprSyncCtx::Brace, 0, 0, 1)
            return self._error_expr(start_range | self.dyn()->prev().range)
        }

        var first_entry = Expressions::MapLiteralExpr::Entry{}
        first_entry.key   = first_key
        first_entry.value = first_val
        first_entry.range = first_key->range | first_val->range
        entries.push_back(first_entry)

        while self.dyn()->check(TokenKind::OpComma) {
            self.dyn()->advance(T::SkipNL::After)

            if self.dyn()->check(TokenKind::OpRBrace) {
                break
            }

            var unsafe *key = self.parse_expr(
                self.stop_on(Self::ExprStopKind::StopComma).plus(Self::ExprStopKind::StopBrace),
            )

            if key == &null {
                self._sync_expr_progress(Self::ExprSyncCtx::Comma, 0, 0, 1)
                continue
            }

            if !self.dyn()->check(TokenKind::OpColon) {
                self.dyn()->diag->report(
                    DiagID::S054E,
                    key->range.start,
                    "expected ':' after key in map literal",
                ).first(key->range)->emit()
                self._sync_expr_progress(Self::ExprSyncCtx::Comma, 0, 0, 1)
                continue
            }

            self.dyn()->advance(T::SkipNL::After) // consume `:`

            var unsafe *val = self.parse_expr(
                self.stop_on(Self::ExprStopKind::StopComma).plus(Self::ExprStopKind::StopBrace),
            )

            if val == &null {
                self._sync_expr_progress(Self::ExprSyncCtx::Comma, 0, 0, 1)
                continue
            }

            var entry = Expressions::MapLiteralExpr::Entry{}
            entry.key   = key
            entry.value = val
            entry.range = key->range | val->range
            entries.push_back(entry)
        }

        // see _finish_set_literal: an entry list with no trailing comma leaves
        // the cursor on the newline before `}`.
        self.dyn()->advance(T::SkipNL::Only)

        var end_range = self.dyn()->prev().range
        if self.dyn()->check(TokenKind::OpRBrace) {
            end_range = self.dyn()->current_ptr()->range
            self.dyn()->advance()
        } else {
            self.dyn()->diag->report(
                DiagID::S054E,
                start_range.start,
                "expected '}' to close map literal",
            ).first(start_range)->emit()
        }

        var ml = Expressions::MapLiteralExpr::create(self.dyn()->ctx, start_range | end_range)
        ml->entries.from_buf(entries.data(), entries.size(), self.dyn()->ctx)
        return ml
    }

    inline fn _parse_anon_initializer(self, start_range: SourceRange) -> *Expr {
        // current token is `.` (first field)
        var fields: kairo::std::StackBuf<Expressions::InitField, 8>

        while !self.dyn()->is_eof() {
            if self.dyn()->check(TokenKind::OpRBrace) {
                break
            }

            if !self.dyn()->check(TokenKind::OpDot) {
                self.dyn()->report_tok(
                    DiagID::S054E,
                    self.dyn()->current_ptr(),
                    "expected '.field: value' in anonymous initializer",
                )

                self._sync_expr_progress(Self::ExprSyncCtx::Comma, 0, 0, 1)
                if self.dyn()->check(TokenKind::OpComma) {
                    self.dyn()->advance(T::SkipNL::After)
                }

                continue
            }

            self.dyn()->advance() // consume `.`

            if !self.dyn()->check(TokenKind::LitIdentifier) {
                self.dyn()->report_tok(
                    DiagID::S054E,
                    self.dyn()->current_ptr(),
                    "expected field name after '.' in anonymous initializer",
                )

                self._sync_expr_progress(Self::ExprSyncCtx::Comma, 0, 0, 1)
                if self.dyn()->check(TokenKind::OpComma) {
                    self.dyn()->advance(T::SkipNL::After)
                }

                continue
            }

            var name_tok   = self.dyn()->current()
            var name_range = name_tok.range
            self.dyn()->advance() // consume field name

            if !self.dyn()->check(TokenKind::OpColon) {
                self.dyn()->diag->report(
                    DiagID::S054E,
                    name_range.start,
                    "expected ':' after field name in anonymous initializer",
                ).first(name_range)->emit()
                self._sync_expr_progress(Self::ExprSyncCtx::Comma, 0, 0, 1)
                if self.dyn()->check(TokenKind::OpComma) {
                    self.dyn()->advance(T::SkipNL::After)
                }

                continue
            }

            self.dyn()->advance(T::SkipNL::After) // consume `:`

            var unsafe *value = self.parse_expr(
                self.stop_on(Self::ExprStopKind::StopComma).plus(Self::ExprStopKind::StopBrace),
            )

            if value == &null {
                self._sync_expr_progress(Self::ExprSyncCtx::Comma, 0, 0, 1)
                if self.dyn()->check(TokenKind::OpComma) {
                    self.dyn()->advance(T::SkipNL::After)
                }

                continue
            }

            var fi = Expressions::InitField{}
            fi.name  = name_tok
            fi.value = value
            fi.range = name_range | value->range
            fields.push_back(fi)

            if self.dyn()->check(TokenKind::OpComma) {
                self.dyn()->advance(T::SkipNL::After)
                continue
            }

            break
        }

        // see _finish_set_literal: a field list with no trailing comma leaves
        // the cursor on the newline before `}`.
        self.dyn()->advance(T::SkipNL::Only)

        var end_range = self.dyn()->prev().range
        if self.dyn()->check(TokenKind::OpRBrace) {
            end_range = self.dyn()->current_ptr()->range
            self.dyn()->advance()
        } else {
            self.dyn()->diag->report(
                DiagID::S054E,
                start_range.start,
                "expected '}' to close anonymous initializer",
            ).first(start_range)->emit()
        }

        var ai = Expressions::AnonInitializerExpr::create(self.dyn()->ctx, start_range | end_range)
        ai->fields.from_buf(fields.data(), fields.size(), self.dyn()->ctx)
        return ai
    }

    /// \brief true if `e` is a type path that may precede a `{ ... }`
    ///        named initializer.
    /// \details accepts a bare identifier (NamedIdentExpr) or a chain whose
    ///          steps are all name/`::`/generic-instantiation (ChainExpr).
    ///          Rejects call results, subscripts, literals, and operator
    ///          expressions those can never name a type to initialize.
    ///          This is a *syntactic* gate; sema still verifies the path
    ///          actually resolves to an initializable aggregate.
    priv fn _is_initializable_path(self, e: unsafe *Expr) -> bool {
        if e == &null {
            return false
        }

        if isa<NamedIdentExpr>(e) {
            return true
        }

        if isa<ChainExpr>(e) {
            // A ChainExpr is initializable only if every step is a static
            // path step (`::`) or generic args, not a value access (`.`) or
            // a call. We let sema do the deep check; syntactically, a chain
            // ending in a type-ish step is admissible.
            return true
        }

        return false
    }

    /// \brief parses a named (struct/aggregate) initializer.
    ///  Grammar:  path '{' (init_field (',' init_field)*)? ','? '}'
    ///    init_field := identifier ':' expr
    ///
    /// \details precondition: `path` is the already-parsed type path and the
    ///          current token is `{`. Field values are parsed with StopComma|
    ///          StopBrace so a `,` or the closing `}` terminates each value;
    ///          NoStructLiteral is intentionally NOT propagated inward a
    ///          nested `Inner { ... }` as a field value is legal and desired.
    ///          A trailing comma is permitted. Empty `{}` is allowed (zero-field
    ///          aggregate / default init).
    priv fn _parse_named_initializer(self,
                                     path: unsafe *Expr,
                                     stop: Self::ExprStop) -> unsafe *Expr {
        return self._parse_init_braces(path, path->range)
    }

    /// \brief the `{ ... }` of a named initializer whose head spans
    ///        \p start_range. \p path is that head, or null for the dotted
    ///        form, which has none (_parse_dotted_variant).
    ///
    /// precondition: current token is `{`.
    priv fn _parse_init_braces(self, path: unsafe *Expr, start_range: SourceRange) -> unsafe *Expr {
        if !self.dyn()->enter_expr_depth() {
            return Expressions::NamedInitializerExpr::create_error(self.dyn()->ctx, start_range)
        }

        var lbrace_range = self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::After) // consume `{`

        var fields: kairo::std::StackBuf<Expressions::InitField, 8>

        // the field list is brace-delimited: a newline before `}` with no
        // trailing comma, or inside a value, ends nothing. Popped
        // before `}`, so the statement terminator after it survives.
        self.dyn()->nl_push()
        while !self.dyn()->is_eof() && !self.dyn()->check(TokenKind::OpRBrace) {
            // tolerate stray newlines between fields
            if self.dyn()->check(TokenKind::TkNewLine) {
                self.dyn()->advance()
                continue
            }

            var field = self._parse_init_field()
            if field.value == &null {
                // malformed field: sync to next `,` or the closing `}`.
                self._sync_init_field()
                if self.dyn()->check(TokenKind::OpRBrace) {
                    break
                }

                if self.dyn()->check(TokenKind::OpComma) {
                    self.dyn()->advance(T::SkipNL::After)
                    continue
                }

                break
            }

            fields.push_back(field)

            if self.dyn()->check(TokenKind::OpComma) {
                self.dyn()->advance(T::SkipNL::After)
                if self.dyn()->check(TokenKind::OpRBrace) { // trailing comma
                    break
                }

                continue
            }

            break // no comma => field list done
        }

        self.dyn()->nl_pop()

        var full_range = start_range
        if self.dyn()->check(TokenKind::OpRBrace) {
            full_range = start_range | self.dyn()->current_ptr()->range
            self.dyn()->advance(T::SkipNL::Before) // consume `}`
        } else {
            self.dyn()->diag->report(
                DiagID::S054E,
                lbrace_range.start,
                "expected '}' to close named initializer",
            ).first(lbrace_range)->emit()
            full_range = start_range | self.dyn()->prev().range
        }

        var node = Expressions::NamedInitializerExpr::create(self.dyn()->ctx, full_range, path)
        node->fields.from_buf(fields.data(), fields.size(), self.dyn()->ctx)

        self.dyn()->exit_expr_depth()
        return node
    }

    /// \brief parses a single `name : value` initializer field.
    /// \details returns an InitField with value == null on failure (caller
    ///          recovers). The field value is parsed with comma/brace stops so
    ///          it ends at the field boundary; nested named initializers in the
    ///          value are allowed (NoStructLiteral is not set on this call).
    priv fn _parse_init_field(self) -> Expressions::InitField {
        var result = Expressions::InitField{}
        result.name  = Token()
        result.value = &null

        var start = self.dyn()->current_ptr()->range

        if !self.dyn()->check(TokenKind::LitIdentifier) {
            self.dyn()->diag->report(
                DiagID::S054E,
                start.start,
                "expected field name in named initializer",
            ).first(start)->emit()
            return result // value stays null
        }

        var id_ptr   = self.dyn()->current_ptr()
        var id_range = id_ptr->range
        self.dyn()->advance() // consume field name
        result.name = *id_ptr

        if !self.dyn()->check(TokenKind::OpColon) {
            self.dyn()->diag->report(
                DiagID::S054E,
                id_range.start,
                "expected ':' after field name in named initializer",
            ).first(id_range)->emit()
            return result // value stays null
        }

        self.dyn()->advance(T::SkipNL::After) // consume `:`

        // Field value: stop at `,` (next field) or `}` (end). Fresh stop kind,
        // so NoStructLiteral does NOT leak in nested initializers are legal.
        var value = self.dyn()->parse_expr(
            self.stop_on(Self::ExprStopKind::StopComma).plus(Self::ExprStopKind::StopBrace),
        )

        if value == &null || is_recovery(value) {
            return result // value stays null
        }

        result.value = value
        result.range = start | value->range
        return result
    }

    /// \brief recovery: skip to the next field boundary inside an initializer.
    /// \details delimiter-aware; stops at depth-0 `,` or `}` so a malformed
    ///          field value doesn't swallow the rest of the initializer.
    priv fn _sync_init_field(self) {
        var   depth_paren:  i32 = 0
        var   depth_square: i32 = 0
        var   depth_brace:  i32 = 0
        var   iters:        u32 = 0
        const MAX:          u32 = 128

        while !self.dyn()->is_eof() && iters < MAX {
            ++iters
            var k = self.dyn()->ig_kind()

            if k == TokenKind::OpLParen {
                ++depth_paren
            } else if k == TokenKind::OpLSquare {
                ++depth_square
            } else if k == TokenKind::OpLBrace {
                ++depth_brace
            } else if k == TokenKind::OpRParen {
                if depth_paren > 0 {
                    --depth_paren
                }
            } else if k == TokenKind::OpRSquare {
                if depth_square > 0 {
                    --depth_square
                }
            } else if k == TokenKind::OpRBrace {
                if depth_brace == 0 { // closing brace of the initializer
                    return
                }

                --depth_brace
            } else if depth_paren == 0 && depth_square == 0 && depth_brace == 0 {
                if k == TokenKind::OpComma {
                    return
                }
            }

            self.dyn()->advance()
        }
    }

    // Value arms
    //
    // The expression forms of `if`, `try` and `match` give each arm its value
    // with `=>`, which introduces exactly one value expression. A `{ }` after a
    // control keyword is always a statement block; the braced value arm is the
    // removed spelling and only survives as recovery (_recover_braced_branch).

    /// \brief what a braced arm stood for, which decides the S073E fix-it.
    enum BraceArm derives u8 {
        Value,      ///< an arm value: `{ v }` becomes `=> v`.
        TryOperand, ///< a `try` operand: `{ v }` becomes `v`.
        ArrowBlock, ///< `=> { stmts }`: the arrow is already consumed; wrap in `({ ... })`.
    }

    /// \brief true when the `{` that follows the current `=>` opens statements
    ///        rather than a set or map literal. Consumes nothing.
    /// \details a literal separates its elements with `,` and never has a `;`
    ///          at its own depth, so a `;`, a statement-only opener, or a line
    ///          that ends without `,` in front of another element can only be a
    ///          block. Without this the arm parses as a set literal and the user
    ///          is told about a missing `}` instead of the arm rule.
    priv fn _arrow_brace_is_block(self) -> bool {
        var i = self.dyn()->c_idx + 1 // past the `=>`
        var n = self.dyn()->span.size()
        while i < n {
            var k0 = self.dyn()->resolve_kind_deep(self.dyn()->span.get(i))
            if k0 != TokenKind::TkNewLine && k0 != TokenKind::AtComment {
                break
            }

            ++i
        }

        if i >= n || self.dyn()->resolve_kind_deep(self.dyn()->span.get(i)) != TokenKind::OpLBrace {
            return false
        }

        ++i
        var depth: i32    = 1
        var first         = true
        var prev          = TokenKind::OpLBrace
        var nl_after_elem = false
        while i < n {
            var k = self.dyn()->resolve_kind_deep(self.dyn()->span.get(i))
            ++i
            if k == TokenKind::AtComment {
                continue
            }

            if k == TokenKind::TkNewLine {
                if depth == 1 && prev != TokenKind::OpComma && prev != TokenKind::OpLBrace {
                    nl_after_elem = true
                }

                continue
            }

            if depth == 1 {
                if first && self._starts_statement_only(k) {
                    return true
                }

                if k == TokenKind::OpSemicolon {
                    return true
                }

                if nl_after_elem && k != TokenKind::OpRBrace {
                    return true
                }
            }

            first         = false
            nl_after_elem = false
            if k == TokenKind::OpLBrace || k == TokenKind::OpLParen || k == TokenKind::OpLSquare {
                ++depth
            } else if k == TokenKind::OpRBrace || k == TokenKind::OpRParen || k == TokenKind::OpRSquare {
                --depth
                if depth == 0 {
                    return false
                }
            }

            prev = k
        }

        return false
    }

    /// \brief the kind of the next token that is not a newline, `skip` real
    ///        tokens ahead of the cursor. Consumes nothing. Comments are
    ///        stepped over too: the cursor never rests on one, so neither may
    ///        the lookahead.
    pub fn _peek_kind_past_nl(self, skip: usize = 0) -> TokenKind {
        // Past EOF c_idx still names the last token, which was consumed: a
        // scan from it answered `}` after `{ { }` ran off the end, and the
        // caller then took the null cursor as that brace.
        if self.dyn()->current_ptr() == &null {
            return TokenKind::TkEof
        }

        var i    = self.dyn()->c_idx
        var left = skip
        while i < self.dyn()->span.size() {
            var k = self.dyn()->resolve_kind_deep(self.dyn()->span.get(i))
            if k != TokenKind::TkNewLine && k != TokenKind::AtComment {
                if left == 0 {
                    return k
                }

                --left
            }

            ++i
        }

        return TokenKind::TkEof
    }

    /// \brief if the next non-newline token is `k`, consume the newlines in
    ///        front of it and return true; otherwise consume nothing.
    /// \details only ever asked for `=>`, `else` and `catch`. None of them can
    ///          begin a statement, and the value forms require their `else`,
    ///          so looking past a newline for one can never take the start of
    ///          the next statement.
    pub fn _skip_nl_if_next(self, k: TokenKind) -> bool {
        if self._peek_kind_past_nl() != k {
            return false
        }

        self.dyn()->advance(T::SkipNL::Only)
        return true
    }

    /// \brief '=>' NL* value.
    /// \details precondition: current token is `=>`. The value runs as far
    ///          right as `stop` lets it, so callers pass the flags of the
    ///          context the whole construct sits in: without them the last arm
    ///          of `f(if c => 1 else => 2, 3)` swallows `, 3`. Newlines inside
    ///          the value follow the ordinary expression rules. `bare_try`
    ///          marks the value as a slot where a nested `try` takes the arms
    ///          that follow it (see _parse_try_catch_expr). Returns null, after
    ///          reporting, when no value follows.
    pub fn _parse_arm_value(self, stop: Self::ExprStop, bare_try: bool = false) -> unsafe *Expr {
        var arrow = self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::After) // consume `=>`

        if bare_try {
            self._bare_try_at = self.dyn()->c_idx + 1
        }

        var unsafe *value = self.parse_expr(stop)
        if bare_try {
            self._bare_try_at = 0
        }

        if value == &null {
            self.dyn()->diag->report(
                DiagID::S052E,
                arrow.start,
                "expected a value expression after '=>'",
            ).first(arrow)->emit()
        }

        return value
    }

    /// \brief a `try` expression arm that leaves (Compiler/Spec/Panic.md#try-and-arms):
    ///        `=> return [v]`, `=> break [label]`, `=> continue [label]`.
    /// \details precondition: current token is `=>`. The jump is wrapped in
    ///          a StmtExpr marked `is_jump`, its body that one statement; X
    ///          types it `!`. A bare `return` ends where a statement would,
    ///          or at the next `catch`, `)` or `,` of the enclosing form.
    priv fn _parse_jump_arm(self, stop: Self::ExprStop) -> unsafe *Expr {
        self.dyn()->advance(T::SkipNL::After) // consume `=>`
        var start              = self.dyn()->current_ptr()->range
        var jump: unsafe *Stmt = &null
        if self.dyn()->check(TokenKind::KwReturn) {
            self.dyn()->advance() // no NL skip: a bare return ends at the line
            if self.dyn()->is_eof()
                || self.dyn()->check(TokenKind::TkNewLine)
                || self.dyn()->check(TokenKind::OpSemicolon)
                || self.dyn()->check(TokenKind::OpRBrace)
                || self.dyn()->check(TokenKind::OpRParen)
                || self.dyn()->check(TokenKind::OpComma)
                || self.dyn()->check(TokenKind::KwCatch) {
                jump = ReturnStmt::create(self.dyn()->ctx, start, &null)
            } else {
                var unsafe *value = self.parse_expr(stop)
                if value == &null || is_recovery(value) {
                    return &null
                }

                jump = (ReturnStmt::create(self.dyn()->ctx, start | value->range, value))
            }
        } else {
            var is_break = self.dyn()->check(TokenKind::KwBreak)
            self.dyn()->advance() // consume `break` / `continue`; a label is on its line
            var has_label = self.dyn()->check(TokenKind::LitIdentifier)
            var label     = Token()
            var r         = start
            if has_label {
                label = self.dyn()->current()
                r     = start | label.range
                self.dyn()->advance()
            }

            if is_break {
                jump = BreakStmt::create(self.dyn()->ctx, r, has_label, label)
            } else {
                jump = ContinueStmt::create(self.dyn()->ctx, r, has_label, label)
            }
        }

        var body = CompoundStmt::create(self.dyn()->ctx, jump->range)
        var one: kairo::std::StackBuf<unsafe *Stmt, 1>
        one.push_back(jump)
        body->body.from_buf(one.data(), one.size(), self.dyn()->ctx)
        var se = Expressions::StmtExpr::create(self.dyn()->ctx, jump->range, body)
        se->is_jump = true
        return se
    }

    /// \brief S074E: the arm's `=>` is missing. Fix-it inserts it at the
    ///        cursor; then the value is parsed as if it were there, so a lone
    ///        forgotten `=>` costs one diagnostic and no cascade.
    pub fn _expect_arrow_recover(self, const after: string, stop: Self::ExprStop) -> unsafe *Expr {
        var at = self.dyn()->current_range() // the arm may be missing at EOF
        var b  = self.dyn()->diag->report(DiagID::S074E, at.start, f"expected '=>' after {after}")
        b.first(at)
        b.insert(at.start, "=> ", "insert '=>'")
        b.emit()

        var k = self.dyn()->ig_kind()
        if k == TokenKind::TkNewLine
            || k == TokenKind::KwElse
            || k == TokenKind::KwCatch
            || k == TokenKind::KwCase
            || k == TokenKind::KwDefault {
            return &null
        }

        return self.parse_expr(stop)
    }

    /// \brief a token that can only begin a statement, never a value, so a
    ///        braced arm starting with it is a statement body.
    priv fn _starts_statement_only(self, k: TokenKind) -> bool {
        return k == TokenKind::KwVar
            || k == TokenKind::KwConst
            || k == TokenKind::KwPanic
            || k == TokenKind::KwYield
            || k == TokenKind::KwAssert
            || self._is_decl_keyword(k)
    }

    /// \brief line of a location, for fix-its that must not join lines.
    priv fn _line_of(self, loc: SourceLocation) -> u32 {
        return self.dyn()->ctx->sm->get_line_col(loc).line
    }

    /// \brief RECOVERY ONLY: a braced value arm `{ expr }`, the removed
    ///        spelling of a value arm (or of a `try` operand).
    ///
    /// \details precondition: current token is `{`. Reports S073E, then
    ///          parses the braces so the enclosing node is still built and
    ///          later diagnostics still fire. When the braces hold exactly one
    ///          expression the fix-it rewrites the arm to `=> expr` (`expr`
    ///          for a `try` operand); anything else is skipped to the matching
    ///          `}`, gets no fix-it, and yields a recovery node. Never returns
    ///          null.
    ///
    ///          Every brace is parsed ONCE. A body that opens with a
    ///          statement-only token is skipped unparsed; otherwise its first
    ///          expression is parsed for real, and when `}` does not follow it
    ///          the rest of the block is skipped. A speculative parse to decide
    ///          first, then the real one, would double the work at every
    ///          nesting level -- 2^depth for braced arms inside braced arms.
    pub fn _recover_braced_branch(self, kind: Self::BraceArm) -> unsafe *Expr {
        var lbrace = self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::After) // consume `{`

        var value:   unsafe *Expr = &null
        var last_end              = lbrace.end // end of the value's last token
        if !self.dyn()->check(TokenKind::OpRBrace)
            && !self._starts_statement_only(self.dyn()->ig_kind()) {
            value = self.parse_expr(self.stop_on(Self::ExprStopKind::StopBrace))
            if value == &null || is_recovery(value) {
                value = &null
            } else {
                last_end = self.dyn()->prev().range.end
                // the value may sit on its own line inside the braces; a
                // second statement after it makes the body a statement block.
                if !self._skip_nl_if_next(TokenKind::OpRBrace) {
                    value = &null
                }
            }
        }

        var rbrace = SourceRange::invalid()
        if value != &null {
            rbrace = self.dyn()->current_ptr()->range
            self.dyn()->advance() // consume `}`, keep the trailing newline
        } else {
            rbrace = self._skip_to_matching_brace()
        }

        var arm_msg = "value arms are written '=> expr'; '{ }' arms are statement-only"
        if kind == Self::BraceArm::ArrowBlock {
            arm_msg = "an arm is a single expression, not a block; use a statement expression '({ ... })'"
        }

        var b = self.dyn()->diag->report(
            DiagID::S073E,
            lbrace.start,
            arm_msg,
        )

        b.first(lbrace)

        if kind == Self::BraceArm::ArrowBlock {
            // value is null here: the caller only routes blocks with statements,
            // so the single-expression rewrite below never applies.
            b.insert(lbrace.start, "(", "wrap the block in '(' ... ')'")
            b.insert(rbrace.end, ")", "close the statement expression")
        } else if value != &null {
            var same_open = self._line_of(lbrace.start) == self._line_of(value->range.start)

            // `{` and the space after it become `=> `. A value on the next
            // line keeps its line: only the brace is replaced.
            var open_end = if (same_open) => (value->range.start) else => lbrace.end
            var open     = SourceRange(lbrace.start, open_end)
            if kind == Self::BraceArm::Value {
                var arrow = if (same_open) => ("=> ") else => "=>"
                b.fix(open, arrow, "replace '{' with '=>'")
            } else {
                b.remove(open, "remove '{'")
            }

            // `}` goes with the space in front of it when it shares the
            // value's line (`{ 1 } else` -> `1 else`). A `}` on its own line
            // in front of more code takes the space after it instead
            // (`} else {` -> `else {`); one that ends its line joins it.
            // Measured from the value's last TOKEN, not its range: a braced
            // arm nested in this one ends at its own `}`, which its own
            // fix-it removes, and the two edits must not overlap.
            var close = SourceRange(last_end, rbrace.end)
            if self._line_of(rbrace.start) != self._line_of(last_end) {
                var nxt = self.dyn()->current_ptr()
                if nxt != &null
                    && nxt->kind != TokenKind::TkNewLine
                    && self._line_of(nxt->range.start) == self._line_of(rbrace.start) {
                    close = SourceRange(rbrace.start, nxt->range.start)
                }
            }

            b.remove(close, "remove '}'")
        } else {
            b.note(
                lbrace.start,
                "multi-statement arms are statement-only; use a statement form or a '({ ... })' statement expression",
            )
        }

        if kind == Self::BraceArm::TryOperand {
            b.note(
                lbrace.start,
                "to 'try' a brace expression (a set literal or an anonymous initializer), parenthesize it: 'try ({ ... })'",
            )
        }

        b.emit()

        if value != &null {
            return value
        }

        return self._error_expr(lbrace | rbrace)
    }

    /// \brief recovery: skip to the `}` matching an already-consumed `{`,
    ///        consume it, and return its range. Delimiter-aware.
    priv fn _skip_to_matching_brace(self) -> SourceRange {
        var depth: i32 = 0
        while !self.dyn()->is_eof() {
            var k = self.dyn()->ig_kind()
            if k == TokenKind::OpLBrace || k == TokenKind::OpLParen || k == TokenKind::OpLSquare {
                ++depth
            } else if k == TokenKind::OpRParen || k == TokenKind::OpRSquare {
                --depth
            } else if k == TokenKind::OpRBrace {
                if depth == 0 {
                    var r = self.dyn()->current_ptr()->range
                    self.dyn()->advance() // consume `}`
                    return r
                }

                --depth
            }

            self.dyn()->advance()
        }

        return self.dyn()->prev().range
    }

    //  Readability rules for the open-ended forms
    //
    //  The last arm of an `if` or `try` expression runs to the end of the
    //  surrounding expression (a `match` closes with `}` and never does). Where
    //  such an expression sits in front of more of an enclosing construct, which
    //  construct the next `else` / `=>` / `catch` belongs to is a guess for the
    //  reader, so S077E requires parentheses; as an operator's operand the parse
    //  is merely easy to misread, so S078W only warns.

    /// \brief an `if` or `try` expression that is not wrapped in `( )`.
    pub fn _is_open_form(self, e: unsafe *Expr) -> bool {
        if e == &null || is_recovery(e) {
            return false
        }

        if (!isa<Expressions::IfExpr>(e)) && !isa<Expressions::TryCatchExpr>(e) {
            return false
        }

        return !self._was_parenthesized(e)
    }

    /// \brief grouping parens leave no node behind (_parse_paren_expr returns
    ///        the inner expression), so the open forms written inside them are
    ///        recorded by identity as they are unwrapped.
    /// \details no parse mode builds ParenExpr today (Verbatim fidelity is
    ///          unimplemented). If one does, the node at every check site is
    ///          then the ParenExpr itself, which _is_open_form already rejects,
    ///          so S077E / S078W / S079W come out the same either way.
    /// \brief \p e was written inside grouping `( )` (an `if`, `try` or binary
    ///        operator: the kinds recorded as their parens are unwrapped).
    pub fn is_parenthesized(self, e: unsafe *Expr) -> bool {
        return self._was_parenthesized(e)
    }

    priv fn _was_parenthesized(self, e: unsafe *Expr) -> bool {
        var i = self._parened_open.size()
        while i > 0 {
            --i
            if self._parened_open[i] == e {
                return true
            }
        }

        return false
    }

    priv fn _open_form_name(self, e: unsafe *Expr) -> string {
        return if (isa<Expressions::TryCatchExpr>(e)) => ("a 'try'") else => "an 'if'"
    }

    /// \brief the two zero-width insertions that wrap `e` in parentheses.
    priv fn _paren_fixits(self, b: *DiagBuilder, e: *Expr) {
        b->insert(e->range.start, "(", "insert '('")
        b->insert(e->range.end, ")", "insert ')'")
    }

    /// \brief S077E when `e` is an unparenthesized `if`/`try` in a position
    ///        that must not hold one (an `if` arm or condition, a `where`
    ///        guard, a `try` operand or non-final catch arm, a scrutinee).
    pub fn _require_parens(self, e: unsafe *Expr) {
        if !self._is_open_form(e) {
            return
        }

        var b = self.dyn()->diag->report(
            DiagID::S077E,
            e->range.start,
            f"{self._open_form_name(e)} expression here must be parenthesized",
        )

        b.first(e->range)
        self._paren_fixits(&b, e)
        b.emit()
    }

    /// \brief S077E for a `try` nested bare inside another `try`. It took
    ///        every `catch` after it, so the split the user meant cannot be
    ///        recovered and there is no fix-it.
    priv fn _report_try_in_try(self, inner: unsafe *Expr) {
        var b = self.dyn()->diag->report(
            DiagID::S077E,
            inner->range.start,
            "a 'try' expression here must be parenthesized",
        )

        b.first(inner->range)
        b.note(
            inner->range.start,
            "the inner 'try' took every following 'catch' arm; parenthesize the inner 'try' and its own arms",
        )

        b.emit()
    }

    /// \brief S078W when an operator's operand is an unparenthesized `if`/`try`.
    /// \details assignment operators and initializers never come here: their
    ///          right side runs to the end of the expression anyway.
    priv fn _warn_open_operand(self, e: unsafe *Expr) {
        if !self._is_open_form(e) {
            return
        }

        var what = if (isa<Expressions::TryCatchExpr>(e)) => ("try") else => "if"
        var b = self.dyn()->diag->report(
            DiagID::S078W,
            e->range.start,
            f"this '{what}' expression extends to the end of the expression",
        )

        b.first(e->range)
        self._paren_fixits(&b, e)
        b.emit()
    }

    /// \brief parses an expression-form if.
    ///  Grammar:  'if' cond NL* '=>' NL* value
    ///            (NL* 'else' NL* 'if' cond NL* '=>' NL* value)*
    ///            NL* 'else' NL* '=>' NL* value
    ///    cond  := expr (NoStructLiteral)
    ///    value := expr (the stop flags of the surrounding context)
    ///
    /// \details called from _parse_primary_expr on KwIf. Conditions parse with
    ///          NoStructLiteral so `if Foo => ...` is not read as a named init.
    ///          The final `else` is mandatory and parser-enforced. The rest of
    ///          the construct is _finish_if_expr, shared with the statement
    ///          parser, which only learns it holds a value form once it sees
    ///          the `=>` after the condition.
    priv fn _parse_if_expr(self, stop: Self::ExprStop) -> unsafe *Expr {
        var start_range = self.dyn()->current_ptr()->range

        if !self.dyn()->enter_expr_depth() {
            return Expressions::IfExpr::create_error(self.dyn()->ctx, start_range)
        }

        self.dyn()->advance(T::SkipNL::After) // consume `if`

        // primary condition
        var condition = self.dyn()->parse_expr(
            self.dyn()->stop_on(T::ExprStopKind::NoStructLiteral),
        )

        if condition == &null || is_recovery(condition) {
            self.dyn()->exit_expr_depth()
            return (Expressions::IfExpr::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        self._require_parens(condition)

        var node = self._finish_if_expr(start_range, condition, stop)
        self.dyn()->exit_expr_depth()
        return node
    }

    /// \brief one arm of an `if` expression after its condition (or `else`):
    ///        `=> value`, the removed `{ value }`, or S074E.
    priv fn _parse_if_arm(self, stop: Self::ExprStop, const after: string) -> unsafe *Expr {
        if self._skip_nl_if_next(TokenKind::OpFatArrow) {
            return self._parse_arm_value(stop)
        }

        if self.dyn()->check(TokenKind::OpLBrace) {
            return self._recover_braced_branch(Self::BraceArm::Value)
        }

        return self._expect_arrow_recover(after, stop)
    }

    /// \brief the `if` expression after its primary condition: the then-arm,
    ///        the else-if arms and the mandatory final else.
    /// \details precondition: the condition is parsed and checked; the caller
    ///          owns enter_depth/exit_depth. `stop` is the context's flags,
    ///          used for every arm value.
    pub fn _finish_if_expr(self,
                           start_range: SourceRange,
                           condition:   *Expr,
                           stop:        Self::ExprStop) -> *Expr {
        // primary then-arm
        var unsafe *then_expr = self._parse_if_arm(stop, "condition")
        if then_expr == &null {
            return (Expressions::IfExpr::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        self._require_parens(then_expr)

        var else_ifs:  kairo::std::StackBuf<Expressions::IfExpr::ElseIf, 4>
        var else_expr: unsafe *Expr                                         = &null

        // else / else-if chain
        while self._skip_nl_if_next(TokenKind::KwElse) {
            self.dyn()->advance(T::SkipNL::After) // consume `else`

            if self.dyn()->check(TokenKind::KwIf) {
                // `else if` arm
                var ei_start = self.dyn()->current_ptr()->range
                self.dyn()->advance(T::SkipNL::After) // consume `if`

                var ei_cond = self.dyn()->parse_expr(
                    self.dyn()->stop_on(T::ExprStopKind::NoStructLiteral),
                )

                if ei_cond == &null || is_recovery(ei_cond) {
                    return (Expressions::IfExpr::create_error(
                        self.dyn()->ctx,
                        start_range | self.dyn()->prev().range,
                    ))
                }

                self._require_parens(ei_cond)

                var unsafe *ei_body = self._parse_if_arm(stop, "condition")
                if ei_body == &null {
                    return (Expressions::IfExpr::create_error(
                        self.dyn()->ctx,
                        start_range | self.dyn()->prev().range,
                    ))
                }

                self._require_parens(ei_body)

                var arm = Expressions::IfExpr::ElseIf{}
                arm.condition = ei_cond
                arm.body      = ei_body
                arm.range     = ei_start | ei_body->range
                else_ifs.push_back(arm)
                continue
            }

            // final `else` arm
            if self.dyn()->check(TokenKind::OpFatArrow) {
                var arrow = self.dyn()->current_ptr()->range
                else_expr = self._parse_arm_value(stop)

                // `else => if` is `else if` spelled the long way round.
                if else_expr != &null
                    && isa<Expressions::IfExpr>(else_expr)
                    && self._is_open_form(else_expr) {
                    var b = self.dyn()->diag->report(DiagID::S079W, arrow.start, "write 'else if'")
                    b.first(arrow)
                    b.remove(SourceRange(arrow.start, else_expr->range.start), "remove '=>'")
                    b.emit()
                }
            } else if self.dyn()->check(TokenKind::OpLBrace) {
                else_expr = self._recover_braced_branch(Self::BraceArm::Value)
            } else {
                else_expr = self._expect_arrow_recover("'else'", stop)
            }

            if else_expr == &null {
                return (Expressions::IfExpr::create_error(
                    self.dyn()->ctx,
                    start_range | self.dyn()->prev().range,
                ))
            }

            break // else is terminal
        }

        // mandatory else
        if else_expr == &null {
            self.dyn()->diag->report(
                DiagID::S054E,
                start_range.start,
                "expression-form 'if' requires a final 'else' (every branch must yield a value)",
            ).first(start_range)->emit()
            return (Expressions::IfExpr::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        var node = Expressions::IfExpr::create(
            self.dyn()->ctx,
            start_range | else_expr->range,
            condition,
            then_expr,
            else_expr,
        )

        node->else_ifs.from_buf(else_ifs.data(), else_ifs.size(), self.dyn()->ctx)
        return node
    }

    /// \brief parses an expression-form try/catch.
    ///  Grammar:  'try' NL* operand catch_arm+
    ///    operand   := expr (the stop flags of the surrounding context)
    ///    catch_arm := NL* 'catch' ('var'|'const')? ident? (':' type)? NL* '=>' NL* value
    ///
    /// \details there is no `=>` after the operand: it ends at `catch`, which
    ///          is a keyword, not an operator. A bare `try {` here is always
    ///          the removed braced form (S073E); a brace expression is tried by
    ///          parenthesizing it. At least one catch arm is required. A default
    ///          arm (filter == null) is terminal: anything after it is an error
    ///          (this also rejects multiple defaults).
    ///
    ///          A `try` that is itself the bare operand or catch-arm value of an
    ///          enclosing `try` takes every `catch` that follows, since arms are
    ///          not terminal, so the outer one is left with none. That inner
    ///          `try` keeps taking arms past its default instead of erroring,
    ///          and the outer one reports the nesting (S077E, no fix-it) in
    ///          place of its own "requires at least one 'catch' arm". The slot
    ///          is identified by token index (`_bare_try_at`), so a `try`
    ///          inside parentheses, a call or a match body is never mistaken
    ///          for one.
    priv fn _parse_try_catch_expr(self, stop: Self::ExprStop) -> unsafe *Expr {
        var start_range = self.dyn()->current_ptr()->range
        var nested_bare = self.dyn()->c_idx + 1 == self._bare_try_at

        if !self.dyn()->enter_expr_depth() {
            return Expressions::TryCatchExpr::create_error(self.dyn()->ctx, start_range)
        }

        self.dyn()->advance(T::SkipNL::After) // consume `try`

        var try_expr: unsafe *Expr = &null
        if self.dyn()->check(TokenKind::OpLBrace) {
            try_expr = self._recover_braced_branch(Self::BraceArm::TryOperand)
        } else {
            self._bare_try_at = self.dyn()->c_idx + 1
            try_expr          = self.parse_expr(stop)
            self._bare_try_at = 0

            if try_expr == &null {
                self.dyn()->diag->report(
                    DiagID::S052E,
                    start_range.start,
                    "expected an expression after 'try'",
                ).first(start_range)->emit()
                self.dyn()->exit_expr_depth()
                return (Expressions::TryCatchExpr::create_error(
                    self.dyn()->ctx,
                    start_range | self.dyn()->prev().range,
                ))
            }
        }

        // a bare inner `try` has already taken every arm; see \details.
        var try_in_try = self._is_open_form(try_expr) && isa<Expressions::TryCatchExpr>(try_expr)
        if try_in_try {
            self._report_try_in_try(try_expr)
        } else {
            self._require_parens(try_expr)
        }

        var arms:        kairo::std::StackBuf<Expressions::TryCatchExpr::CatchArm, 4>
        var seen_default                                                              = false

        while self._skip_nl_if_next(TokenKind::KwCatch) {
            // a default arm is terminal; another arm after it is an error.
            if seen_default && !nested_bare {
                var r = self.dyn()->current_ptr()->range
                self.dyn()->diag->report(
                    DiagID::S054E,
                    r.start,
                    "no catch arm may follow a default 'catch' (the default is terminal)",
                ).first(r)->emit()
                self._sync_to_brace_or_catch()
                self.dyn()->exit_expr_depth()
                return (Expressions::TryCatchExpr::create_error(
                    self.dyn()->ctx,
                    start_range | self.dyn()->prev().range,
                ))
            }

            var arm = self._parse_catch_arm_expr(stop)
            if arm.body == &null {
                self._sync_to_brace_or_catch()
                self.dyn()->exit_expr_depth()
                return (Expressions::TryCatchExpr::create_error(
                    self.dyn()->ctx,
                    start_range | self.dyn()->prev().range,
                ))
            }

            if arm.filter == &null {
                seen_default = true // untyped/bare catch is the default
            }

            arms.push_back(arm)
        }

        if arms.size() == 0 {
            if !try_in_try {
                self.dyn()->diag->report(
                    DiagID::S054E,
                    start_range.start,
                    "'try' expression requires at least one 'catch' arm",
                ).first(start_range)->emit()
            }

            self.dyn()->exit_expr_depth()
            return (Expressions::TryCatchExpr::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        // every arm but the last sits in front of another `catch`. The last
        // may hold a bare `try`, unless that one ran past its own default: then
        // it took arms meant for this one.
        for var i: usize = 0; i < (arms.size() as usize); ++i {
            var unsafe *body = arms[(i as u32)].body
            if i + 1 < (arms.size() as usize) {
                self._require_parens(body)
            } else if self._is_open_form(body)
                && isa<Expressions::TryCatchExpr>(body)
                && self._overran_default(cast<Expressions::TryCatchExpr>(body)) {
                self._report_try_in_try(body)
            }
        }

        var node = Expressions::TryCatchExpr::create(
            self.dyn()->ctx,
            start_range | self.dyn()->prev().range,
            try_expr,
        )

        node->catch_arms.from_buf(arms.data(), arms.size(), self.dyn()->ctx)

        self.dyn()->exit_expr_depth()
        return node
    }

    /// \brief a nested-bare `try` that kept taking arms past its default.
    priv fn _overran_default(self, t: unsafe *Expressions::TryCatchExpr) -> bool {
        var n = t->catch_arms.size()
        for var i: usize = 0; i + 1 < n; ++i {
            if t->catch_arms.get(i)->filter == &null {
                return true
            }
        }

        return false
    }

    /// \brief parses an expression-form match.
    ///  Grammar:  'match' expr(NoStructLiteral) '{' arm* '}'
    ///    arm      := 'case' pattern (',' pattern)* ('where' expr)? NL* '=>' NL* value
    ///              | 'default' NL* '=>' NL* value
    ///    value    := expr (stop = StopBrace)
    ///
    /// \details the scrutinee, braces, patterns and guards are shared with the
    ///          statement form through _parse_match_core. Every block arm here
    ///          is the removed braced spelling and reports S073E; its value is
    ///          recovered by _recover_case_to_expr. Mixed arms are covered by
    ///          those per-arm errors, so S075E is never added on top. A match
    ///          value is closed by its `}` and never extends past it, so no
    ///          readability rule applies to it. Exhaustiveness is NOT checked
    ///          here; sema owns coverage.
    priv fn _parse_match_expr(self) -> unsafe *Expr {
        var start_range = self.dyn()->current_ptr()->range

        var core = self.dyn()->_parse_match_core(start_range)
        if !core.ok {
            return Expressions::MatchExpr::create_error(self.dyn()->ctx, core.range)
        }

        var cases: kairo::std::StackBuf<MatchCase, 8>
        for var i: usize = 0; i < core.cases.size(); ++i {
            var src = *core.cases.get(i)
            if src.body != &null {
                cases.push_back(self._recover_case_to_expr(&src))
            } else {
                cases.push_back(src)
            }
        }

        var node = Expressions::MatchExpr::create(self.dyn()->ctx, core.range, core.scrutinee)
        node->cases.from_buf(cases.data(), cases.size(), self.dyn()->ctx)
        return node
    }

    /// \brief RECOVERY ONLY: a block arm in an expression-form match.
    /// \details reports S073E on the arm's block. When the block holds exactly
    ///          one ExpressionStmt, the fix-it rewrites `{ e }` to `=> e` and
    ///          that expression becomes the case value, so the MatchExpr is
    ///          still well-formed. Otherwise the note points at the statement
    ///          forms and the case keeps both body and expression null.
    priv fn _recover_case_to_expr(self, src: *MatchCase) -> MatchCase {
        var out = MatchCase{}
        out.patterns   = src->patterns   // FrozenList copy; same arena nodes.
        out.guard      = src->guard
        out.is_default = src->is_default
        out.range      = src->range
        out.body       = &null
        out.expression = &null

        var unsafe *cb    = src->body
        var        lbrace = SourceRange(cb->range.start, cb->range.start.with_offset(1))
        var        rbrace = SourceRange(cb->range.end.with_offset(-1), cb->range.end)

        var value: unsafe *Expr = &null
        if cb->body.size() == 1 && !is_recovery(unsafe (cb as unsafe *Stmt)) {
            var unsafe *only = *cb->body.get(0)
            if only != &null && !only->is_error() && isa<ExpressionStmt>(only) {
                var unsafe *es = cast<ExpressionStmt>(only)
                if es->expr != &null && !is_recovery(es->expr) {
                    value = es->expr
                }
            }
        }

        var b = self.dyn()->diag->report(
            DiagID::S073E,
            lbrace.start,
            "value arms are written '=> expr'; '{ }' arms are statement-only",
        )

        b.first(lbrace)
        if value != &null {
            var same_open = self._line_of(lbrace.start) == self._line_of(value->range.start)
            var open_end  = if (same_open) => (value->range.start) else => lbrace.end
            var arrow     = if (same_open) => ("=> ") else => "=>"
            b.fix(SourceRange(lbrace.start, open_end), arrow, "replace '{' with '=>'")

            // the arm list is newline-separated, so `}` always takes the space
            // in front of it: on its own line it joins the value's line.
            b.remove(SourceRange(value->range.end, rbrace.end), "remove '}'")
        } else {
            b.note(
                lbrace.start,
                "multi-statement arms are statement-only; use a statement-form match or a '({ ... })' statement expression",
            )
        }

        b.emit()

        out.expression = value // body stays null: expression path is live.
        return out
    }

    /// \brief parses one catch arm of a try expression.
    ///  Grammar:  NL* 'catch' ('var'|'const')? ident? (':' type)? NL* '=>' NL* value
    ///
    /// \details forms: `catch => v` (bare default), `catch e => v` /
    ///          `catch var e => v` / `catch const e => v` (untyped default,
    ///          mutable unless const), `catch e: T => v` (typed). Mutability
    ///          defaults to mutable; `const` overrides. The value takes the
    ///          context's stop flags and ends at the next `catch`. Returns an
    ///          arm with a null body on failure.
    priv fn _parse_catch_arm_expr(self,
                                  stop: Self::ExprStop) -> Expressions::TryCatchExpr::CatchArm {
        var result = Expressions::TryCatchExpr::CatchArm{}
        result.has_binding = false
        result.is_const    = false
        result.binding     = &null
        result.filter      = &null
        result.body        = &null

        var start_range = self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::After) // consume `catch`

        // optional mutability keyword
        if self.dyn()->check(TokenKind::KwConst) {
            result.is_const = true
            self.dyn()->advance()
        } else if self.dyn()->check(TokenKind::KwVar) {
            result.is_const = false // explicit mutable
            self.dyn()->advance()
        }

        self.dyn()->_reject_mode_binding() // `catch @inout e`: parameter-only.

        // optional binding identifier
        if self.dyn()->check(TokenKind::LitIdentifier) {
            var id_ptr   = self.dyn()->current_ptr()
            var id_range = id_ptr->range
            self.dyn()->advance()
            result.binding     = NamedIdentExpr::create(self.dyn()->ctx, id_range, *id_ptr)
            result.has_binding = true
            // The caught error is a declaration; see CatchArm::decl.
            var cstor = if (result.is_const) => (StorageClass::Const) else => StorageClass::Var
            result.decl = VariableDecl::create(self.dyn()->ctx, id_range, *id_ptr, cstor)

            // optional `: Type` filter (only meaningful with a binding)
            if self.dyn()->check(TokenKind::OpColon) {
                self.dyn()->advance(T::SkipNL::After) // consume `:`
                var filter = self.dyn()->parse_type()
                if filter == &null || is_recovery(filter) {
                    self.dyn()->diag->report(
                        DiagID::S053E,
                        start_range.start,
                        "expected a panic type after ':' in catch arm",
                    ).first(start_range)->emit()
                    return result // body stays null
                }

                result.filter = filter
            }
        } else {
            // no identifier. A mutability keyword without a binding is invalid.
            if result.is_const {
                self.dyn()->diag->report(
                    DiagID::S054E,
                    start_range.start,
                    "'const' in a catch arm must be followed by a binding name",
                ).first(start_range)->emit()
                return result // body stays null
            }
        }

        // value
        var body: unsafe *Expr = &null
        if self._skip_nl_if_next(TokenKind::OpFatArrow) {
            var after = self._peek_kind_past_nl(1) // past the `=>`
            if after == TokenKind::KwReturn
                || after == TokenKind::KwBreak
                || after == TokenKind::KwContinue {
                body = self._parse_jump_arm(stop)
            } else if after == TokenKind::OpLBrace && self._arrow_brace_is_block() {
                self.dyn()->advance(T::SkipNL::After) // consume `=>`
                body = self._recover_braced_branch(Self::BraceArm::ArrowBlock)
            } else {
                body = self._parse_arm_value(stop, true)
            }
        } else if self.dyn()->check(TokenKind::OpLBrace) {
            body = self._recover_braced_branch(Self::BraceArm::Value)
        } else {
            body = self._expect_arrow_recover("catch arm", stop)
        }

        if body == &null {
            return result // body stays null
        }

        result.body  = body
        result.range = start_range | body->range
        return result
    }

    /// \brief recovery: skip to the next `catch`, a closing brace at depth 0, or
    ///        a statement boundary, after a malformed catch arm. Delimiter-aware.
    priv fn _sync_to_brace_or_catch(self) {
        var   depth: i32 = 0
        var   iters: u32 = 0
        const MAX:   u32 = 128

        while !self.dyn()->is_eof() && iters < MAX {
            ++iters
            var k = self.dyn()->ig_kind()

            if k == TokenKind::OpLBrace || k == TokenKind::OpLParen || k == TokenKind::OpLSquare {
                ++depth
            } else if k == TokenKind::OpRBrace
                || k == TokenKind::OpRParen
                || k == TokenKind::OpRSquare {
                if depth == 0 {
                    return
                }

                --depth
            } else if depth == 0 {
                if k == TokenKind::KwCatch
                    || k == TokenKind::TkNewLine
                    || k == TokenKind::OpSemicolon {
                    return
                }
            }

            self.dyn()->advance()
        }
    }

    //  Generic disambiguation helper

    /// \brief checks if a name refers to a generic type/function in hoisted scope.
    ///        used to disambiguate `<` as generic args vs comparison operator.
    ///
    /// \details scans ALL entries for the name, not first(): a mixed overload
    ///          set (non-generic + generic under one name) is generic if ANY
    ///          overload is the entry insertion order must not decide.
    inline fn _is_generic_name(self, tok: Token) -> bool {
        var hr = self.dyn()->ctx->hoisted->lookup_tok(tok)
        if hr.found() {
            for var i: usize = 0; i < hr.entries->size(); ++i {
                if (*hr.entries)[i].is_generic() {
                    return true
                }
            }

            return false
        }

        // hoisted miss: fall back to imported generics (unqualified surface).
        return self._import_generic_fallback(tok)
    }

    /// `Self` is the enclosing type WITH its arguments; `Self<T>` is never
    /// legal, and a `<` after it is always the comparison operator. Also keeps
    /// a non-identifier token out of the hoisted-table probes, which key on
    /// identifier imms.
    priv fn _can_take_generic_args(self, tok: Token) -> bool {
        return tok.kind != TokenKind::BiSelf
    }

    /// \brief three-state `<`-disambiguation verdict for a head-position name
    ///        (rules 3/4 of the disambiguation model).
    ///
    /// \details lookup order is lexical-first locals shadow globals:
    ///          1. LexicalScope binding (params, locals). A var bound to a
    ///             generic closure (`var f = fn <T> ...`) is Generic; a
    ///             generic-param binding (is_tparam, rule 2) is Generic;
    ///             any other local binding is a plain VALUE -> NotGeneric.
    ///          2. Hoisted table. Any generic overload -> Generic. All
    ///             entries Variables -> NotGeneric (a var can never take
    ///             generic args; commit comparison, rule 4). Known
    ///             non-generic fn/op/type -> Unknown: assume generic WHEN
    ///             THE SHAPE FITS (tentative), because "foo takes no
    ///             generic arguments" is the right diagnostic for
    ///             `foo<a>(10)`, while `foo < limit` still rolls back to a
    ///             comparison. An unconditional generic commit here would
    ///             re-break the `foo < limit` shape (old bug 1).
    ///          3. Unknown -> the caller runs the tentative parse (also
    ///             covers unqualified imported generics).
    enum GenericVerdict derives u8 {
        Generic,    ///< commit `<` as generic arguments.
        NotGeneric, ///< commit `<` as a comparison operator.
        Unknown,    ///< tentative parse decides.
    }

    fn _generic_verdict(self, tok: Token) -> Self::GenericVerdict {
        // 1. lexical bindings shadow everything.
        var b = self.dyn()->scope.lookup(self.dyn()->ctx->get_spelling(tok))
        if b != &null {
            if b->is_tparam {
                return Self::GenericVerdict::Generic
            }

            if b->decl != &null && isa<VariableDecl>(b->decl) {
                var vd = cast<VariableDecl>(b->decl)
                if vd->init != &null && isa<Expressions::ClosureExpr>(vd->init) {
                    var cl = cast<Expressions::ClosureExpr>(vd->init)
                    if !cl->generic_params.is_empty() {
                        return Self::GenericVerdict::Generic
                    }
                }
            }

            return Self::GenericVerdict::NotGeneric
        }

        // 2. hoisted table.
        var hr = self.dyn()->ctx->hoisted->lookup_tok(tok)
        if hr.found() {
            var all_vars = true
            for var i: usize = 0; i < hr.entries->size(); ++i {
                if (*hr.entries)[i].is_generic() {
                    return Self::GenericVerdict::Generic
                }

                if (*hr.entries)[i].kind != DisambigKind::Variable {
                    all_vars = false
                }
            }

            if all_vars {
                return Self::GenericVerdict::NotGeneric
            }

            return Self::GenericVerdict::Unknown // known fn/op/type: assume generic if it parses as one
        }

        // 3. hoisted miss: consult imported generics. A positive hit is
        //    authoritative (the source module says the name is generic), so
        //    commit `<` as generic args. A miss preserves the tentative path
        //    (also the correct home for unqualified imported generics whose
        //    genericity we cannot prove here).
        if self._import_generic_fallback(tok) {
            return Self::GenericVerdict::Generic
        }

        // 4. no evidence either way.
        return Self::GenericVerdict::Unknown
    }

    /// \brief lazy import-edge fallback for unqualified generic disambiguation.
    ///
    /// \details On a hoisted-table MISS, walk this fid's import edges (written
    ///          by the PP in declaration order, Compiler/Spec/Pipeline.md #2 lazy-not-merge)
    ///          and ask each edge's SOURCE fid whether the probed name is a
    ///          generic. Full mode only the index barrier (CompilerInstance
    ///          wait_group(5)) guarantees every imported fid is already indexed
    ///          in the GlobalDisambigTable, so `lookup_in(fid, name)` is safe.
    ///
    ///          Edge shape rules (unqualified probe):
    ///            - wildcard  `import a::*`      : probe the name UNMAPPED.
    ///            - selective `import a::{x, y}` : the name must match an item's
    ///              VISIBLE name (its alias if present, else the item's last
    ///              sub_path segment); look the ORIGINAL name up in the source.
    ///              A `{*}` item behaves like a wildcard edge.
    ///            - plain     `import a [as m]`  : binds only a module handle, so
    ///              it contributes NOTHING to an unqualified probe (the handle
    ///              heads a qualified chain, disambiguated per-segment elsewhere).
    ///
    ///          First hit wins parse-time only needs "is this a generic?", not
    ///          full resolution. Collisions are ImportResolution's problem, not
    ///          the parser's (Compiler/Spec/Pipeline.md #2, lazy-not-merge bullet). NO merge
    ///          of disambig tables, ever.
    fn _import_generic_fallback(self, tok: Token) -> bool {
        if !self.dyn()->is_full_mode() {
            return false
        }

        var tu = self.dyn()->tu
        if tu == &null {
            return false
        }

        var gs = tu->global_scope
        if gs == &null {
            return false
        }

        var probe = self.dyn()->ctx->get_spelling(tok)

        for var i: usize = 0; i < tu->import_edges.size(); ++i {
            var edge = tu->import_edges[i]              // *ImportEdge
            var id   = dyn_cast<ImportDecl>(edge->decl)
            if id == &null {
                continue
            }

            var fid = edge->target_fid
            // 0 with no file segments is an unresolved ffi edge; a native one
            // to fid 0 is the first input, imported back by a module of it.
            if fid == 0 && id->file_seg_count == 0 {
                continue
            }

            /// ## wildcard edge: probe unmapped
            if id->is_wildcard {
                if self._src_name_is_generic(gs, fid, probe) {
                    return true
                }

                continue
            }

            /// ## selective edge: match a visible item, look up the original
            if id->has_items {
                for var j: usize = 0; j < id->items.size(); ++j {
                    var it = id->items[j]
                    if it.is_wildcard {
                        if self._src_name_is_generic(gs, fid, probe) {
                            return true
                        }

                        continue
                    }

                    if it.sub_path.size() == 0 {
                        continue
                    }

                    var orig_tok    = it.sub_path[it.sub_path.size() - 1]
                    var visible_tok = if (it.has_alias) => (it.alias) else => orig_tok
                    if self.dyn()->ctx->get_spelling(visible_tok) != probe {
                        continue
                    }

                    // matched the alias/name the user wrote resolve the ORIGINAL.
                    if self._src_name_is_generic(gs, fid, self.dyn()->ctx->get_spelling(orig_tok)) {
                        return true
                    }
                }

                continue
            }

            /// ## plain edge: module handle only, nothing unqualified
        }

        return false
    }

    /// \brief cross-file "is this name a generic in fid?" boolean.
    ///        Reads `is_generic()` off the source fid's frozen DisambigEntry a
    ///        pure name-domain bool, no cross-TU imm hazard (the source table
    ///        interns the string itself).
    inline fn _src_name_is_generic(self,
                                   gs:         *GlobalDisambigTable,
                                   fid:        u32,
                                   const name: string) -> bool {
        var lr = gs->lookup_in(fid, name)
        if !lr.found() {
            return false
        }

        for var i: usize = 0; i < lr.entries->size(); ++i {
            if (*lr.entries)[i].is_generic() {
                return true
            }
        }

        return false
    }


    /// \brief parses a closure expression.
    ///  Grammar:  'fn' ('<' generic_params '>')? ('|' captures '|')?
    ///            ('(' params ')')? fn_modifiers? ('->' type)? (block | '=' expr)
    ///
    /// \details called from _parse_primary_expr on KwFn. Delegates signature
    ///          parsing to DeclParse::_parse_closure_sig via dyn(), then parses
    ///          the body as either a block or an expression body.
    priv fn _parse_closure_expr(self) -> unsafe *Expr {
        var start = self.dyn()->current_ptr()->range

        if !self.dyn()->enter_expr_depth() {
            return Expressions::ClosureExpr::create_error(self.dyn()->ctx, start)
        }

        self.dyn()->advance(T::SkipNL::After) // consume `fn`

        self.dyn()->enter_scope(ScopeKind::Function, &null)
        var sig_result = self.dyn()->_parse_closure_sig()
        // signature: generics, captures, params, modifiers, return type
        // var (params, gparams, captures, modifiers, ret_type) = dyn()->_parse_closure_sig();
        var params              = sig_result.0
        var gparams             = sig_result.1
        var captures            = sig_result.2
        var modifiers           = sig_result.3
        var ret_type            = sig_result.4
        var explicit_no_capture = sig_result.5

        // open a function scope so param names resolve inside the body
        var ce = Expressions::ClosureExpr::create(self.dyn()->ctx, start)
        ce->generic_params = gparams
        ce->captures       = captures
        ce->params         = params
        // Derived from the parameters, exactly as FunctionDecl::is_variadic is.
        // Nothing set this before, so a closure's pack was invisible to every
        // reader that asked the closure instead of the list.
        ce->is_variadic = false
        for var i: usize = 0; i < ce->params.size(); ++i {
            if ce->params[i] != &null && ce->params[i]->is_pack {
                ce->is_variadic = true
            }
        }

        var ce_seen_pack = false
        for var i: usize = 0; i < ce->params.size(); ++i {
            var cp = ce->params[i]
            if cp == &null {
                continue
            }

            if cp->is_pack {
                ce_seen_pack = true
                continue
            }

            if ce_seen_pack {
                cp->keyword_only = true
            }
        }

        ce->modifiers           = modifiers
        ce->return_type         = ret_type
        ce->explicit_no_capture = explicit_no_capture
        ce->capture_range       = self.dyn()->closure_cap_range
        ce->panic_set           = self.dyn()->closure_panic_set
        ce->panic_range         = self.dyn()->closure_panic_range
        ce->params_end          = self.dyn()->closure_params_end

        // bind captured names into the closure scope so the body can see them
        // for var i: usize = 0; i < ce->captures.size(); ++i {
        //     var cap = ce->captures[i];
        //     if cap.name != &null {
        //         var cap_name = cast::<NamedIdentExpr>(cap.name);
        //         dyn()->scope.bind(
        //             dyn()->ctx->get_spelling(cap_name->token),
        //             static_cast::<*Decl>(CaptureDecl::create(dyn()->ctx, cap.name->range, cap_name->token, cap.by_ptr)),
        //             cap.name->range
        //         );
        //     }
        // }

        // A `where` guard selects among overloads, and a closure is one
        // value with no overload set to select from (where.mdx, "What where
        // Cannot Do"). Consumed after the error so the body still parses.
        if self.dyn()->check(TokenKind::KwWhere) {
            var wh = self.dyn()->current_ptr()->range
            self.dyn()->diag->report(
                DiagID::S045E,
                wh.start,
                "'where' is not allowed on a closure; a guard selects among "
                "overloads of a named function, and a closure has none. Test "
                "the condition with an 'if' in the body instead",
            ).first(wh)->emit()
            self.dyn()->advance(T::SkipNL::After) // consume `where`
            var _discard = self.dyn()->parse_guard_expr()
        }

        // body: block `{ ... }` or expression `= expr`
        if self.dyn()->check(TokenKind::OpLBrace) {
            var block = self.dyn()->parse_compound()
            ce->body_kind  = FnBodyKind::Block
            ce->body_block = block
        } else if self.dyn()->check(TokenKind::OpEqual) {
            self.dyn()->advance(T::SkipNL::After) // consume `=`

            // Recovery if the token immediately following '=' cannot start an expression
            // remeber a nested closure is fully valid
            if self.dyn()->_starts_decl_kw(self.dyn()->ig_kind())
                && self.dyn()->ig_kind() != TokenKind::KwFn {
                self.dyn()->diag->report(
                    DiagID::S052E,
                    start.start,
                    "expected expression after '=' in closure body",
                ).first(start)->emit()
                self.dyn()->exit_scope()
                self.dyn()->exit_expr_depth()
                return ((Expressions::ClosureExpr::create_error(
                    self.dyn()->ctx,
                    start | self.dyn()->prev().range,
                )))
            }

            var expr = self.dyn()->parse_expr()
            if expr != &null && !is_recovery(expr) {
                ce->body_kind = FnBodyKind::Expr
                ce->body_expr = expr
            } else {
                self.dyn()->diag->report(
                    DiagID::S052E,
                    start.start,
                    "expected expression after '=' in closure body",
                ).first(start)->emit()
                self.dyn()->exit_scope()
                self.dyn()->exit_expr_depth()
                return ((Expressions::ClosureExpr::create_error(
                    self.dyn()->ctx,
                    start | self.dyn()->prev().range,
                )))
            }
        } else {
            self.dyn()->diag->report(
                DiagID::S054E,
                start.start,
                "expected '{' or '=' to begin closure body",
            ).first(start)->emit()
            self.dyn()->exit_scope()
            self.dyn()->exit_expr_depth()
            return ((Expressions::ClosureExpr::create_error(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
            )))
        }

        ce->range = start | self.dyn()->prev().range
        self.dyn()->exit_scope()
        self.dyn()->exit_expr_depth()
        return ce
    }
}
