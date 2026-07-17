/// --- The Kairo Project --------------------------- Parser/ExprParse.k --- ///
///
///   \brief Expression parsing mixin. Pratt parser with postfix chain building.
///
///   \detail
///     Entry point: parse_expr() -> Pratt loop with precedence climbing.
///     Primary dispatch: parse_primary_expr() -> literals, identifiers, prefix
///     unary, parenthesized exprs, keyword exprs (sizeof, typeof, etc.).
///     Postfix loop: `_parse_postfix()` -> builds ChainExpr steps for `.`, `::`,
///     `->`, `?.`; wraps in CallExpr for `(`; wraps in SubscriptExpr for `[`.
///
///     Generic disambiguation: when `<` follows an identifier, checks hoisted
///     scope for generic arity before deciding comparison vs generic args.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the Kairo
///   Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------- ///

import AST::Node::Base::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Declarations::*;
import AST::Node::Types::*;
import AST::Node::Casting::*;
import AST::CodeCompleteConsumer::*;
import AST::Context::ASTContext::*;
import Diagnostic::Engine::*;
import Diagnostic::Registry::*;
import Location::SourceRange::*;
import Token::Token::*;
import Token::TokenKind::*;
import Macro::Sentinel::*;
import AST::Node::Statements::*;
import Parser::LexicalScope::*;

class <T> ExprParse {
    /// \brief token set for primary expression dispatch. identifiers, builtins,
    ///        and `self` can start a primary expression.
    const var EXPR_IDENT_TBL: set::<TokenKind> = {
        TokenKind::LitIdentifier,
        TokenKind::KwSelf,
        TokenKind::BiFile,
        TokenKind::BiLine,
        TokenKind::BiColumn,
        TokenKind::BiFunction,
        TokenKind::BiModule
    };

    enum ExprSyncCtx derives u8 {
        TopLevel,   ///< sync to newline, ;, EOF
        Paren,      ///< sync to ) at depth 0
        Square,     ///< sync to ] at depth 0
        Brace,      ///< sync to } at depth 0
        Comma,      ///< sync to , or closing delimiter
    }

    /// \brief context flags controlling what tokens terminate an expression.
    ///        passed into parse_expr so the Pratt loop knows when to stop.
    enum ExprStopKind derives u8 {
        Default    = 0,           ///< stop at ; newline EOF
        StopAngle  = 1 << 0,      ///< also stop at > >> at depth 0 (generic param defaults)
        StopParen  = 1 << 1,      ///< also stop at ) at depth 0
        StopSquare = 1 << 2,      ///< also stop at ] at depth 0
        StopBrace  = 1 << 3,      ///< also stop at } at depth 0
        StopComma  = 1 << 4,      ///< also stop at , at depth 0
        NoStructLiteral = 1 << 5, ///< disallow { ... } struct literal parsing
    }

    // ========================================================================
    //  CRTP helper
    // ========================================================================

    priv inline fn dyn(self) -> *T {
        return static_cast::<*T>(&self);
    }

    priv inline fn _error_expr(self, range: SourceRange) -> *Expr {
        return static_cast::<*Expr>(ChainExpr::create_error(dyn()->ctx, range));
    }

    // ========================================================================
    //  Sync / recovery
    // ========================================================================

    priv inline fn _sync_expr(
        self,
        ctx:             ExprSyncCtx,
        paren_depth:     i32  = 0,
        square_depth:    i32  = 0,
        brace_depth:     i32  = 0,
        stop_at_newline: bool = false
    ) {
        var balance_paren:   i32 = paren_depth;
        var balance_square:  i32 = square_depth;
        var balance_brace:   i32 = brace_depth;
        var tokens_consumed: u32 = 0;
        const var MAX_SYNC:  u32 = 64;

        while !dyn()->is_eof() {
            if tokens_consumed >= MAX_SYNC { return; }
            ++tokens_consumed;

            var k = dyn()->current().kind;

            if stop_at_newline && k == TokenKind::TkNewLine
            && balance_paren == 0 && balance_square == 0 && balance_brace == 0 {
                return;
            }

            if k == TokenKind::OpLParen  { ++balance_paren;  }
            else if k == TokenKind::OpLSquare { ++balance_square; }
            else if k == TokenKind::OpLBrace  { ++balance_brace;  }
            else if k == TokenKind::OpRParen {
                if balance_paren == 0 { return; }
                --balance_paren;
            }
            else if k == TokenKind::OpRSquare {
                if balance_square == 0 { return; }
                --balance_square;
            }
            else if k == TokenKind::OpRBrace {
                if balance_brace == 0 { return; }
                --balance_brace;
            }
            else if balance_paren == 0 && balance_square == 0 && balance_brace == 0 {
                if k == TokenKind::OpComma {
                    if ctx == ExprSyncCtx::Comma
                    || ctx == ExprSyncCtx::Paren
                    || ctx == ExprSyncCtx::Square { return; }
                }
                if k == TokenKind::TkNewLine && ctx == ExprSyncCtx::TopLevel { return; }
                if k == TokenKind::OpSemicolon { return; }
            }

            dyn()->advance();
        }
    }

    // ========================================================================
    //  Entry point
    // ========================================================================

    /// \brief operator precedence levels for the Pratt parser.
    ///        higher number = tighter binding.
    enum Precedence derives u8 {
        None       = 0,
        Assign     = 1,   // = += -= *= /= %= &= |= ^= <<= >>=
        Coalesce   = 2,   // ?? (right-assoc, lower than ||)
        Range      = 3,   // .. ..=
        Or         = 4,   // || or
        And        = 5,   // && and
        BitOr      = 6,   // | bitor
        BitXor     = 7,   // ^ xor
        BitAnd     = 8,   // & bitand
        Equality   = 9,   // == != ===
        Comparison = 10,  // < > <= >= <=>
        Shift      = 11,  // << >>
        Add        = 12,  // + -
        Multiply   = 13,  // * / %
        Power      = 14,  // ^^
        Prefix     = 15,  // unary (not used in table, just for reference)
        Postfix    = 16,  // call, subscript, access (not used in table)
    }

    fn parse_expr(self, stop: ExprStopKind = ExprStopKind::Default) -> *Expr {
        if dyn()->is_eof() { return &null; }
        if self._should_stop(stop) { return &null; }
        if !dyn()->enter_depth() { return &null; }

        var lhs = self._parse_unary_expr(stop);
        if lhs == &null {
            dyn()->exit_depth();
            return &null;
        }

        lhs = self._parse_expr_prec(lhs, Precedence::None, stop);

        dyn()->exit_depth();
        return lhs;
    }

    /// \brief Pratt precedence climbing loop. Consumes binary operators
    ///        whose precedence is strictly greater than `min_prec` and
    ///        builds left-associative or right-associative BinaryOperatorExpr
    ///        / AssignOperatorExpr nodes.
    priv fn _parse_expr_prec(self, lhs_in: *Expr, min_prec: Precedence, stop: ExprStopKind) -> *Expr {
        var lhs = lhs_in;

        while !dyn()->is_eof() {
            if self._should_stop(stop) { break; }

            var cur_kind = dyn()->current().kind;
            var prec = self._infix_precedence(cur_kind);

            if static_cast::<u8>(prec) <= static_cast::<u8>(min_prec) { break; }

            // -- range operators .. ..= ------------------------------
            if cur_kind == TokenKind::OpRange || cur_kind == TokenKind::OpRangeEqual {
                lhs = self._parse_range_expr(lhs, stop);
                continue;
            }

            // -- assignment operators (right-associative) ------------
            if self._is_assign_op(cur_kind) {
                var op_tok = dyn()->current();
                dyn()->advance(T::SkipNL::After); // consume operator

                var rhs = self._parse_unary_expr(stop);
                if rhs == &null {
                    dyn()->diag->report(DiagID::S052E, op_tok.range.start,
                        f"expected expression after '{token_kind_to_readable_string(op_tok.kind)}\x27"
                    ).first(op_tok.range).emit();
                    return lhs;
                }

                // right-associative: recurse at same precedence
                rhs = self._parse_expr_prec(rhs, static_cast::<Precedence>(static_cast::<u8>(prec) - 1), stop);

                lhs = AssignOperatorExpr::create(
                    dyn()->ctx,
                    lhs->range | rhs->range,
                    lhs, rhs, op_tok
                );
                continue;
            }

            // -- exponentiation (right-associative) --------------
            if cur_kind == TokenKind::OpCaretCaret {
                var op_tok = dyn()->current();
                dyn()->advance(T::SkipNL::After);

                var rhs = self._parse_unary_expr(stop);
                if rhs == &null {
                    dyn()->diag->report(DiagID::S052E, op_tok.range.start,
                        "expected expression after '^^\x27"
                    ).first(op_tok.range).emit();
                    return lhs;
                }

                // right-associative: recurse at prec - 1
                rhs = self._parse_expr_prec(rhs, static_cast::<Precedence>(static_cast::<u8>(prec) - 1), stop);

                lhs = BinaryOperatorExpr::create(
                    dyn()->ctx,
                    lhs->range | rhs->range,
                    lhs, rhs, op_tok
                );
                continue;
            }

            // -- null-coalescing (right-associative) -------------
            if cur_kind == TokenKind::OpQuestionQuestion {
                var op_tok = dyn()->current();
                dyn()->advance(T::SkipNL::After);
                var rhs = self._parse_unary_expr(stop);
                if rhs == &null {
                    dyn()->diag->report(DiagID::S052E, op_tok.range.start,
                        "expected expression after '??\x27"
                    ).first(op_tok.range).emit();
                    return lhs;
                }
                // right-associative: recurse at prec - 1
                rhs = self._parse_expr_prec(rhs, static_cast::<Precedence>(static_cast::<u8>(prec) - 1), stop);
                lhs = BinaryOperatorExpr::create(
                    dyn()->ctx,
                    lhs->range | rhs->range,
                    lhs, rhs, op_tok
                );
                continue;
            }

            // -- regular binary operators (left-associative) ---------
            var op_tok = dyn()->current();
            dyn()->advance(T::SkipNL::After); // consume operator

            var rhs = self._parse_unary_expr(stop);
            if rhs == &null {
                dyn()->diag->report(DiagID::S052E, op_tok.range.start,
                    f"expected expression after '{token_kind_to_readable_string(op_tok.kind)}\x27"
                ).first(op_tok.range).emit();
                return lhs;
            }

            // left-associative: recurse at current precedence (strictly greater binds tighter)
            rhs = self._parse_expr_prec(rhs, prec, stop);

            lhs = BinaryOperatorExpr::create(
                dyn()->ctx,
                lhs->range | rhs->range,
                lhs, rhs, op_tok
            );
        }

        return lhs;
    }

    /// \brief parses a single primary expression for pattern position: the lead
    ///        of a range bound or a constructor head. Stops before postfix `(`,
    ///        `..`, `.` the pattern parser owns those. Returns null/recovery
    ///        on no production.
    pub fn parse_pattern_lead(self) -> *Expr {
        var base = self._parse_primary_expr(ExprStopKind::Default);
        if base == &null { return &null; }

        // accumulate `::` steps only (Direction::North), with generics.
        // stop before `(`, `..`, `.`, `[` the pattern parser owns those.
        if dyn()->check(TokenKind::OpColonColon) {
            var chain_steps: std::StackBuf::<ChainExpr::Step, 4>;
            var chain_start = base->range;
            while dyn()->check(TokenKind::OpColonColon) {
                var step = self._parse_access_step();
                if step.name == &null { break; }
                chain_steps.push_back(step);
            }

            if chain_steps.size() > 0 {
                var ce = ChainExpr::create(dyn()->ctx, chain_start | dyn()->prev().range, base);
                ce->steps.from_buf(chain_steps.data(), chain_steps.size(), dyn()->ctx);
                return static_cast::<*Expr>(ce);
            }
        }

        return base;
    }

    /// \brief parses a range expression: lhs .. rhs | lhs ..= rhs
    ///        also handles prefix ranges: ..rhs | ..=rhs
    ///        range has its own precedence level and is non-associative.
    priv fn _parse_range_expr(self, lhs: *Expr, stop: ExprStopKind) -> *Expr {
        var op_range = dyn()->current_ptr()->range;
        var is_inclusive = dyn()->check(TokenKind::OpRangeEqual);
        dyn()->advance(T::SkipNL::After); // consume .. or ..=

        // check if there's a RHS or if this is an open-ended range (lhs..)
        if self._should_stop(stop) || dyn()->is_eof() {
            return RangeExpr::create(dyn()->ctx, lhs->range | op_range, lhs, &null, is_inclusive);
        }

        // check if next token can start an expression
        var k = dyn()->current().kind;
        if k == TokenKind::OpRParen
        || k == TokenKind::OpRSquare
        || k == TokenKind::OpRBrace
        || k == TokenKind::OpComma
        || k == TokenKind::OpSemicolon
        || k == TokenKind::TkNewLine {
            // open-ended range: lhs..
            return RangeExpr::create(dyn()->ctx, lhs->range | op_range, lhs, &null, is_inclusive);
        }

        var rhs = self._parse_unary_expr(stop);
        if rhs != &null {
            // don't recurse range is non-associative (a..b..c is illegal)
            // but do parse higher-precedence ops on the rhs
            rhs = self._parse_expr_prec(rhs, Precedence::Range, stop);
        }

        var end_range = (rhs->range) if (rhs != &null) else op_range;
        return RangeExpr::create(dyn()->ctx, lhs->range | end_range, lhs, rhs, is_inclusive);
    }

    /// \brief returns the infix precedence for a token kind, or Precedence::None
    ///        if the token is not a binary operator.
    priv fn _infix_precedence(self, k: TokenKind) -> Precedence {
        // assignment
        if (k == TokenKind::OpEqual)
        || (k == TokenKind::OpPlusEqual)
        || (k == TokenKind::OpMinusEqual)
        || (k == TokenKind::OpStarEqual)
        || (k == TokenKind::OpSlashEqual)
        || (k == TokenKind::OpPercentEqual)
        || (k == TokenKind::OpAmpEqual)
        || (k == TokenKind::OpPipeEqual)
        || (k == TokenKind::OpCaretEqual)
        || (k == TokenKind::OpLessLessEqual)
        || (k == TokenKind::OpGreaterGreaterEqual) {
            return Precedence::Assign;
        }

        if k == TokenKind::OpQuestionQuestion {
            return Precedence::Coalesce;
        }

        // range
        if (k == TokenKind::OpRange)
        || (k == TokenKind::OpRangeEqual) {
            return Precedence::Range;
        }

        // logical or
        if (k == TokenKind::OpPipePipe)
        || (k == TokenKind::KwOr) {
            return Precedence::Or;
        }

        // logical and
        if (k == TokenKind::OpAmpAmp)
        || (k == TokenKind::KwAnd) {
            return Precedence::And;
        }

        // bitwise or
        if (k == TokenKind::OpPipe)
        || (k == TokenKind::KwBitor) {
            return Precedence::BitOr;
        }

        // bitwise xor
        if (k == TokenKind::OpCaret)
        || (k == TokenKind::KwXor) {
            return Precedence::BitXor;
        }

        // bitwise and
        if (k == TokenKind::OpAmp)
        || (k == TokenKind::KwBitand) {
            return Precedence::BitAnd;
        }

        // equality
        if (k == TokenKind::OpEqualEqual)
        || (k == TokenKind::OpExclaimEqual)
        || (k == TokenKind::OpEqualEqualEqual)
        || (k == TokenKind::KwNotEq) {
            return Precedence::Equality;
        }

        // comparison
        if (k == TokenKind::OpLess)
        || (k == TokenKind::OpGreater)
        || (k == TokenKind::OpLessEqual)
        || (k == TokenKind::OpGreaterEqual)
        || (k == TokenKind::OpLessEqualGreater) {
            return Precedence::Comparison;
        }

        // shift
        if (k == TokenKind::OpLessLess)
        || (k == TokenKind::OpGreaterGreater) {
            return Precedence::Shift;
        }

        // additive
        if (k == TokenKind::OpPlus)
        || (k == TokenKind::OpMinus) {
            return Precedence::Add;
        }

        // multiplicative
        if (k == TokenKind::OpStar)
        || (k == TokenKind::OpSlash)
        || (k == TokenKind::OpPercent) {
            return Precedence::Multiply;
        }

        // exponentiation
        if k == TokenKind::OpCaretCaret {
            return Precedence::Power;
        }

        return Precedence::None;
    }

    /// \brief returns true if the token is an assignment operator.
    priv fn _is_assign_op(self, k: TokenKind) -> bool {
        return (k == TokenKind::OpEqual)
            || (k == TokenKind::OpPlusEqual)
            || (k == TokenKind::OpMinusEqual)
            || (k == TokenKind::OpStarEqual)
            || (k == TokenKind::OpSlashEqual)
            || (k == TokenKind::OpPercentEqual)
            || (k == TokenKind::OpAmpEqual)
            || (k == TokenKind::OpPipeEqual)
            || (k == TokenKind::OpCaretEqual)
            || (k == TokenKind::OpLessLessEqual)
            || (k == TokenKind::OpGreaterGreaterEqual);
    }

    /// \brief checks if the current token is a stop token for the given context.
    ///        returns true if the expression should terminate here.
    priv fn _should_stop(self, stop: ExprStopKind) -> bool {
        if dyn()->is_eof() { return true; }
        var k = dyn()->current().kind;

        if k == TokenKind::OpRParen
        && (static_cast::<u8>(stop) & static_cast::<u8>(ExprStopKind::StopParen)) != 0 {
            return true;
        }
        if k == TokenKind::OpRSquare
        && (static_cast::<u8>(stop) & static_cast::<u8>(ExprStopKind::StopSquare)) != 0 {
            return true;
        }
        if k == TokenKind::OpRBrace
        && (static_cast::<u8>(stop) & static_cast::<u8>(ExprStopKind::StopBrace)) != 0 {
            return true;
        }
        if k == TokenKind::OpComma
        && (static_cast::<u8>(stop) & static_cast::<u8>(ExprStopKind::StopComma)) != 0 {
            return true;
        }
        if (k == TokenKind::OpGreater || k == TokenKind::OpGreaterGreater)
        && (static_cast::<u8>(stop) & static_cast::<u8>(ExprStopKind::StopAngle)) != 0 {
            return true;
        }
        return false;
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
        var k = dyn()->current().kind;

        if (k == TokenKind::OpComma)
        || (k == TokenKind::OpGreater)
        || (k == TokenKind::OpGreaterGreater) {
            return false;
        }

        // postfix openers: call, subscript, member access
        if (k == TokenKind::OpLParen)
        || (k == TokenKind::OpLSquare)
        || (k == TokenKind::OpDot)
        || (k == TokenKind::OpArrow)
        || (k == TokenKind::OpQuestionDot)
        || (k == TokenKind::OpQuestionArrow) {
            return true;
        }

        // any remaining infix operator (arithmetic, bitwise, logical, ...)
        return self._infix_precedence(k) != Precedence::None;
    }

    // ========================================================================
    //  Unary expressions
    // ========================================================================

    /// \brief parses prefix unary operators then delegates to postfix.
    ///
    /// prefix ops: ! - ~ & * ++ --
    /// keyword prefixes: await spawn thread eval unsafe delete sizeof alignof typeof
    inline fn _parse_unary_expr(self, stop: ExprStopKind) -> *Expr {
        if dyn()->is_eof() { return &null; }

        var cur_ptr = dyn()->current_ptr();
        if cur_ptr == &null { return &null; }
        var cur_range = cur_ptr->range;

        if dyn()->check(TokenKind::OpAmp) && dyn()->check_peek(TokenKind::LitNull) {
            var amp_range = cur_range;
            dyn()->advance(); // consume &
            var null_range = dyn()->current_ptr()->range;
            dyn()->advance(); // consume null
            return NullLiteralExpr::create(dyn()->ctx, amp_range | null_range, true);
        }

        // -- prefix unary operators ----------------------------------
        if dyn()->check(TokenKind::OpExclaim)
        || dyn()->check(TokenKind::OpMinus)
        || dyn()->check(TokenKind::OpTilde)
        || dyn()->check(TokenKind::OpAmp)
        || dyn()->check(TokenKind::OpStar)
        || dyn()->check(TokenKind::OpPlusPlus)
        || dyn()->check(TokenKind::OpMinusMinus) {
            var op_tok = dyn()->current();
            dyn()->advance();

            var operand = self._parse_unary_expr(stop);
            if operand == &null {
                dyn()->diag->report(DiagID::S052E, cur_range.start,
                    f"expected expression after '{token_kind_to_readable_string(op_tok.kind)}\x27"
                ).first(cur_range).emit();
                return self._error_expr(cur_range);
            }

            return UnaryOperatorExpr::create(
                dyn()->ctx,
                cur_range | operand->range,
                operand,
                op_tok,
                UnaryOperatorExpr::Fix::Prefix
            );
        }

        // -- keyword prefix: await -----------------------------------
        if dyn()->check(TokenKind::KwAwait) {
            var kw_range = cur_range;
            dyn()->advance();
            var operand = self._parse_unary_expr(stop);
            if operand == &null {
                dyn()->diag->report(DiagID::S052E, kw_range.start,
                    "expected expression after 'await\x27"
                ).first(kw_range).emit();
                return AwaitExpr::create_error(dyn()->ctx, kw_range);
            }
            return AwaitExpr::create(dyn()->ctx, kw_range | operand->range, operand);
        }

        // -- keyword prefix: spawn -----------------------------------
        if dyn()->check(TokenKind::KwSpawn) {
            var kw_range = cur_range;
            dyn()->advance();
            var operand = self._parse_unary_expr(stop);
            if operand == &null {
                dyn()->diag->report(DiagID::S052E, kw_range.start,
                    "expected expression after 'spawn\x27"
                ).first(kw_range).emit();
                return SpawnExpr::create_error(dyn()->ctx, kw_range);
            }
            return SpawnExpr::create(dyn()->ctx, kw_range | operand->range, operand);
        }

        // -- keyword prefix: thread ----------------------------------
        if dyn()->check(TokenKind::KwThread) {
            var kw_range = cur_range;
            dyn()->advance();
            var operand = self._parse_unary_expr(stop);
            if operand == &null {
                dyn()->diag->report(DiagID::S052E, kw_range.start,
                    "expected expression after 'thread\x27"
                ).first(kw_range).emit();
                return ThreadExpr::create_error(dyn()->ctx, kw_range);
            }
            return ThreadExpr::create(dyn()->ctx, kw_range | operand->range, operand);
        }

        // -- keyword prefix: eval ------------------------------------
        if dyn()->check(TokenKind::KwEval) {
            var kw_range = cur_range;
            dyn()->advance();
            var operand = self._parse_unary_expr(stop);
            if operand == &null {
                dyn()->diag->report(DiagID::S052E, kw_range.start,
                    "expected expression after 'eval\x27"
                ).first(kw_range).emit();
                return EvalExpr::create_error(dyn()->ctx, kw_range);
            }
            return EvalExpr::create(dyn()->ctx, kw_range | operand->range, operand);
        }

        // -- keyword prefix: unsafe ----------------------------------
        if dyn()->check(TokenKind::KwUnsafe) {
            var kw_range = cur_range;
            dyn()->advance();
            var operand = self._parse_unary_expr(stop);
            if operand == &null {
                dyn()->diag->report(DiagID::S052E, kw_range.start,
                    "expected expression after 'unsafe\x27"
                ).first(kw_range).emit();
                return UnsafeExpr::create_error(dyn()->ctx, kw_range);
            }
            return UnsafeExpr::create(dyn()->ctx, kw_range | operand->range, operand);
        }

        // -- keyword prefix: delete ----------------------------------
        if dyn()->check(TokenKind::KwDelete) {
            var kw_range = cur_range;
            dyn()->advance();

            var is_array = false;
            if dyn()->check(TokenKind::OpLSquare) {
                dyn()->advance();
                if !dyn()->check(TokenKind::OpRSquare) {
                    dyn()->diag->report(DiagID::S054E, kw_range.start,
                        "expected ']' after 'delete [\x27"
                    ).first(kw_range).emit();
                } else {
                    dyn()->advance(); // consume ]
                }
                is_array = true;
            }

            var operand = self._parse_unary_expr(stop);
            if operand == &null {
                dyn()->diag->report(DiagID::S052E, kw_range.start,
                    "expected expression after 'delete\x27"
                ).first(kw_range).emit();
                return DeleteExpr::create_error(dyn()->ctx, kw_range);
            }
            return DeleteExpr::create(dyn()->ctx, kw_range | operand->range, operand, is_array);
        }

        // -- keyword prefix: sizeof ----------------------------------
        if dyn()->check(TokenKind::KwSizeOf) {
            return self._parse_sizeof_expr();
        }

        // -- keyword prefix: alignof ---------------------------------
        if dyn()->check(TokenKind::KwAlignOf) {
            return self._parse_alignof_expr();
        }

        // -- keyword prefix: typeof ----------------------------------
        if dyn()->check(TokenKind::KwTypeOf) {
            return self._parse_typeof_expr();
        }

        // -- no prefix: parse postfix --------------------------------
        return self._parse_postfix_expr(stop);
    }

    // ========================================================================
    //  sizeof / alignof / typeof
    // ========================================================================

    inline fn _parse_sizeof_expr(self) -> *Expr {
        var kw_range = dyn()->current_ptr()->range;
        dyn()->advance(); // consume `sizeof`

        var has_paren = dyn()->check(TokenKind::OpLParen);
        if has_paren { dyn()->advance(T::SkipNL::After); }

        var ty = dyn()->parse_type();
        if ty == &null {
            dyn()->diag->report(DiagID::S053E, kw_range.start,
                "expected type after 'sizeof\x27"
            ).first(kw_range).emit();
            return SizeOfExpr::create_error(dyn()->ctx, kw_range);
        }

        if has_paren {
            if !dyn()->check(TokenKind::OpRParen) {
                dyn()->diag->report(DiagID::S054E, kw_range.start,
                    "expected ')' after type in 'sizeof(T)\x27"
                ).first(kw_range).emit();
            } else {
                dyn()->advance(); // consume )
            }
        }

        return SizeOfExpr::create(dyn()->ctx, kw_range | dyn()->prev().range, ty);
    }

    inline fn _parse_alignof_expr(self) -> *Expr {
        var kw_range = dyn()->current_ptr()->range;
        dyn()->advance(); // consume `alignof`

        var has_paren = dyn()->check(TokenKind::OpLParen);
        if has_paren { dyn()->advance(T::SkipNL::After); }

        var ty = dyn()->parse_type();
        if ty == &null {
            dyn()->diag->report(DiagID::S053E, kw_range.start,
                "expected type after 'alignof\x27"
            ).first(kw_range).emit();
            return AlignOfExpr::create_error(dyn()->ctx, kw_range);
        }

        if has_paren {
            if !dyn()->check(TokenKind::OpRParen) {
                dyn()->diag->report(DiagID::S054E, kw_range.start,
                    "expected ')' after type in 'alignof(T)\x27"
                ).first(kw_range).emit();
            } else {
                dyn()->advance();
            }
        }

        return AlignOfExpr::create(dyn()->ctx, kw_range | dyn()->prev().range, ty);
    }

    inline fn _parse_typeof_expr(self) -> *Expr {
        var kw_range = dyn()->current_ptr()->range;
        dyn()->advance(); // consume `typeof`

        var has_paren = dyn()->check(TokenKind::OpLParen);
        if has_paren { dyn()->advance(T::SkipNL::After); }

        var operand = self.parse_expr(ExprStopKind::StopParen);
        if operand == &null {
            dyn()->diag->report(DiagID::S052E, kw_range.start,
                "expected expression after 'typeof\x27"
            ).first(kw_range).emit();
            return TypeOfExpr::create_error(dyn()->ctx, kw_range);
        }

        if has_paren {
            if !dyn()->check(TokenKind::OpRParen) {
                dyn()->diag->report(DiagID::S054E, kw_range.start,
                    "expected ')' after expression in 'typeof(expr)\x27"
                ).first(kw_range).emit();
            } else {
                dyn()->advance();
            }
        }

        return TypeOfExpr::create(dyn()->ctx, kw_range | dyn()->prev().range, operand);
    }

    // ========================================================================
    //  Postfix expression loop
    // ========================================================================

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
    inline fn _parse_postfix_expr(self, stop: ExprStopKind) -> *Expr {
        var base = self._parse_primary_expr(stop);
        if (base == &null) { return &null; }

        // pending chain steps accumulator
        var chain_steps: std::StackBuf::<ChainExpr::Step, 8>;
        var chain_start = base->range;

        while !dyn()->is_eof() {
            // brush a trailing comment so the newline-continuation guard below
            // sees the real next token, not an AtComment sitting between the
            // primary and its terminator (`b // c\n`).
            // if (dyn()->current().kind) == TokenKind::AtComment {
            //     dyn()->_stash_comment(dyn()->current_ptr());
            //     dyn()->advance_raw();
            //     continue;
            // }

            // -- newline continuation: only the member-access family may
            //    continue an expression across a raw newline. `::` is
            //    excluded (ambiguous with a new statement); binary ops
            //    require enclosing parens (nl_depth handles those).
            if (dyn()->nl_depth == 0) && ((dyn()->current().kind) == TokenKind::TkNewLine) {
                var nk = dyn()->peek_past_nl_kind();
                if (nk == TokenKind::OpDot)
                || (nk == TokenKind::OpArrow)
                || (nk == TokenKind::OpQuestionDot)
                || (nk == TokenKind::OpQuestionArrow) {
                    dyn()->advance(T::SkipNL::Only);
                    continue;
                }
                break; // newline ends the postfix chain
            }

            if dyn()->check(TokenKind::OpDot)
            || dyn()->check(TokenKind::OpArrow)
            || dyn()->check(TokenKind::OpColonColon)
            || dyn()->check(TokenKind::OpQuestionDot)
            || dyn()->check(TokenKind::OpQuestionArrow) {
                var step = self._parse_access_step();
                if step.name != &null {
                    chain_steps.push_back(step);
                    continue;
                }
                // recovery: step parse failed, break out
                break;
            }

            // -- call: ( ---------------------------------------------
            if dyn()->check(TokenKind::OpLParen) {
                // flush pending chain steps first
                base = self._flush_chain(base, &chain_steps, chain_start);
                base = self._parse_call_expr(base);
                chain_start = base->range;
                continue;
            }

            // -- subscript: [ ----------------------------------------
            if dyn()->check(TokenKind::OpLSquare) {
                base = self._flush_chain(base, &chain_steps, chain_start);
                base = self._parse_subscript_expr(base);
                chain_start = base->range;
                continue;
            }

            // -- named initializer:  Path '{' field (',' field)* '}' ------
            if dyn()->check(TokenKind::OpLBrace) {
                // Suppressed in condition/scrutinee/iterable positions, where a
                // trailing `{` is the block of the enclosing construct, not an
                // initializer. The statement parser relies on us leaving `{` alone.
                var suppressed = (static_cast::<u8>(stop)
                                & static_cast::<u8>(ExprStopKind::NoStructLiteral)) != 0;
                if suppressed {
                    break; // hand the `{` back to the caller (it's a block opener)
                }

                // Only a *type path* can be initialized. Reject `foo() { }`,
                // `(a + b) { }`, `arr[i] { }` the base must be a name or a
                // qualified/generic path, never a call/subscript/operator result.
                base = self._flush_chain(base, &chain_steps, chain_start);
                if !self._is_initializable_path(base) {
                    break; // not a named-init; let the caller see the `{`
                }

                base = self._parse_named_initializer(base, stop);
                continue;
            }

            // -- postfix ++ -- ---------------------------------------
            if dyn()->check(TokenKind::OpPlusPlus)
            || dyn()->check(TokenKind::OpMinusMinus) {
                base = self._flush_chain(base, &chain_steps, chain_start);
                var op_tok = dyn()->current();
                dyn()->advance();
                base = UnaryOperatorExpr::create(
                    dyn()->ctx,
                    base->range | op_tok.range,
                    base,
                    op_tok,
                    UnaryOperatorExpr::Fix::Postfix
                );
                chain_start = base->range;
                continue;
            }

            // -- postfix ... (pack expansion) ------------------------
            if dyn()->check(TokenKind::OpEllipsis) {
                base = self._flush_chain(base, &chain_steps, chain_start);
                var ellipsis_range = dyn()->current_ptr()->range;
                dyn()->advance();
                base = PackExpansionExpr::create(
                    dyn()->ctx,
                    base->range | ellipsis_range,
                    base
                );
                chain_start = base->range;
                continue;
            }

            // -- postfix as Type (type cast) -------------------------
            if dyn()->check(TokenKind::KwAs) {
                // `as var`: var can't begin a type, so this is unambiguously
                // a bare context binding. Hand `as` to the statement layer.
                if dyn()->check_peek(TokenKind::KwVar) {
                    break;
                }

                base = self._flush_chain(base, &chain_steps, chain_start);

                // Everything else speculates: `as const`, `as (`, and plain
                // type positions are disambiguated inside _try_type_cast by
                // the trailing-`{` tiebreaker.
                var maybe_cast = self._try_type_cast(base);
                if maybe_cast == &null {
                    break; // binding (or unparseable) -> stmt layer owns `as`
                }
                base = maybe_cast;
                chain_start = base->range;
                continue;
            }

            // -- nothing matched: end of postfix ---------------------
            break;
        }

        // flush any remaining chain steps
        base = self._flush_chain(base, &chain_steps, chain_start);
        return base;
    }

    // ========================================================================
    //  Chain step parsing
    // ========================================================================

    /// \brief parses a single access step: separator + identifier + optional
    ///        generic args.
    ///
    /// precondition: current token is one of . -> :: ?. ?->
    inline fn _parse_access_step(self) -> ChainExpr::Step {
        var result = ChainExpr::Step{};
        result.name          = &null;
        result.access_kind   = ChainExpr::AccessKind::Dot;
        result.resolved_type = &null;
        result.resolved_decl = &null;
        result.is_ufcs       = false;

        var sep_range = dyn()->current_ptr()->range;

        // determine access kind from separator token
        if      dyn()->check(TokenKind::OpDot)           { result.access_kind = ChainExpr::AccessKind::Dot;           }
        else if dyn()->check(TokenKind::OpArrow)         { result.access_kind = ChainExpr::AccessKind::Arrow;         }
        else if dyn()->check(TokenKind::OpColonColon)    { result.access_kind = ChainExpr::AccessKind::ColonColon;    }
        else if dyn()->check(TokenKind::OpQuestionDot)   { result.access_kind = ChainExpr::AccessKind::QuestionDot;   }
        else if dyn()->check(TokenKind::OpQuestionArrow) { result.access_kind = ChainExpr::AccessKind::QuestionArrow; }

        dyn()->advance(T::SkipNL::After); // consume separator

        // code completion after separator
        if dyn()->check(TokenKind::TkCodeComplete) {
            dyn()->maybe_complete(CompletionContextKind::ExprStart);
            dyn()->advance(T::SkipNL::After);
            result.range = sep_range;
            return result; // name stays null, caller handles
        }

        // expect identifier
        if !dyn()->check(fn(k: TokenKind) -> bool {
            return EXPR_IDENT_TBL.contains(k);
        }) {
            dyn()->diag->report(DiagID::S054E, sep_range.start,
                f"expected identifier after '{token_kind_to_readable_string(dyn()->resolve_kind_deep(dyn()->current_ptr()))}' in access expression"
            ).first(sep_range).emit();
            return result; // name stays null
        }

        var id_ptr   = dyn()->current_ptr();
        var id_range = id_ptr->range;
        dyn()->advance(); // consume identifier

        var nte = NamedIdentExpr::create(dyn()->ctx, id_range, *id_ptr);
        result.name  = nte;
        result.range = sep_range | id_range;

        // -- generic args after :: separator only --------------------
        // foo::<T> is generic, foo.<T> is not valid syntax
        // also check hoisted scope for disambiguation of foo::Bar<T>
        if dyn()->check(TokenKind::OpLess) {
            if result.access_kind == ChainExpr::AccessKind::ColonColon {
                if self._is_generic_name(*id_ptr) {
                    var generic_args: std::StackBuf::<ChainType::GenericArg, 4>;
                    dyn()->_parse_generic_args(&generic_args);
                    if dyn()->_pending_close_angle { dyn()->_pending_close_angle = false; }
                    result.generic_args.from_buf(
                        generic_args.data(), generic_args.size(), dyn()->ctx
                    );
                    result.range = sep_range | dyn()->prev().range;
                } else {
                    self._try_step_generic_args(&result, id_range, sep_range);
                }
            } else {
                self._try_step_generic_args(&result, id_range, sep_range);
            }
        }

        return result;
    }

    inline fn _try_step_generic_args(
        self,
        step:      *ChainExpr::Step,
        id_range:  SourceRange,
        sep_range: SourceRange
    ) {
        inline "c++" {
            using ASTTentativeGuard = typename T::TentativeGuard;
        }

        var t = ASTTentativeGuard(dyn());
        var generic_args: std::StackBuf::<ChainType::GenericArg, 4>;
        var ok = dyn()->_parse_generic_args(&generic_args);
        if dyn()->_pending_close_angle { dyn()->_pending_close_angle = false; }

        if ok && !generic_args.is_empty() {
            var k = dyn()->current().kind;
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
                    generic_args.data(), generic_args.size(), dyn()->ctx
                );
                step->range = sep_range | dyn()->prev().range;
                t.commit();
                return;
            }
        }
        // fall through: guard dtor pops suppress and rolls cursor back
    }

    /// \brief flushes accumulated chain steps into a ChainExpr wrapping base.
    ///        if no steps are pending, returns base unchanged.
    inline fn _flush_chain(
        self,
        base:        *Expr,
        steps:       *std::StackBuf::<ChainExpr::Step, 8>,
        chain_start: SourceRange
    ) -> *Expr {
        if steps->size() == 0 { return base; }

        var end_range = dyn()->prev().range;
        var full_range = chain_start | end_range;

        var ce = ChainExpr::create(dyn()->ctx, full_range, base);
        ce->steps.from_buf(steps->data(), steps->size(), dyn()->ctx);

        steps->clear();   // consume the accumulator; without this, the next
                          // flush re-freezes these same steps onto the next chain

        return ce;
    }

    // ========================================================================
    //  Call expression
    // ========================================================================

    /// \brief parses a function call: callee ( args )
    ///        supports named arguments: foo(x: 10, y: 20)
    ///
    /// precondition: current token is `(`
    inline fn _parse_call_expr(self, callee: *Expr) -> *Expr {
        var lparen_range = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `(`

        var args: std::StackBuf::<*Expr, 8>;

        // empty arg list: foo()
        if dyn()->check(TokenKind::OpRParen) {
            var rparen_range = dyn()->current_ptr()->range;
            dyn()->advance(); // consume `)`

            var ce = CallExpr::create(dyn()->ctx, callee->range | rparen_range, callee);
            // args stays empty
            return ce;
        }

        // parse argument list
        self._parse_call_args(&args, lparen_range);

        // expect closing `)`
        dyn()->advance(T::SkipNL::Only);
        var end_range = dyn()->prev().range;
        if dyn()->check(TokenKind::OpRParen) {
            end_range = dyn()->current_ptr()->range;
            dyn()->advance(); // consume `)`
        } else {
            dyn()->diag->report(DiagID::S054E, lparen_range.start,
                "expected ')' to close function call argument list"
            ).first(lparen_range).emit();
            self._sync_expr(ExprSyncCtx::Paren, 1, 0, 0, true);
            end_range = dyn()->prev().range;
        }

        var ce = CallExpr::create(dyn()->ctx, callee->range | end_range, callee);
        ce->args.from_buf(args.data(), args.size(), dyn()->ctx);
        return ce;
    }

    /// \brief parses comma-separated call arguments.
    ///        handles named args (name: expr) and positional args (expr).
    ///
    /// named args are parsed as AssignOperatorExpr with lhs=NamedIdentExpr
    /// and rhs=value. sema distinguishes named vs positional by checking
    /// if the arg is an AssignOperatorExpr with a bare NamedIdentExpr lhs.
    pub fn _parse_call_args(self, out: *std::StackBuf::<*Expr, 8>, start_range: SourceRange) {
        while !dyn()->is_eof() {
            dyn()->advance(T::SkipNL::Only);

            if dyn()->check(TokenKind::OpRParen) { return; }

            if dyn()->check(TokenKind::TkCodeComplete) {
                dyn()->maybe_complete(CompletionContextKind::ExprStart);
                dyn()->advance(T::SkipNL::After);
                return;
            }

            // bail if we've clearly left the call context
            if self._is_decl_keyword(dyn()->current().kind) {
                return;
            }

            // check for named argument: ident `:` expr (but not ident `::`)
            if (dyn()->check(TokenKind::LitIdentifier))
            && (dyn()->check_peek(TokenKind::OpColon))
            && (!dyn()->check_peek(TokenKind::OpColonColon)) {
                var name_ptr   = dyn()->current_ptr();
                var name_range = name_ptr->range;
                var name_tok   = *name_ptr;

                dyn()->advance(); // consume identifier
                dyn()->advance(T::SkipNL::After); // consume `:`

                var value = self.parse_expr(
                    static_cast::<ExprStopKind>(
                        static_cast::<u8>(ExprStopKind::StopComma)
                    | static_cast::<u8>(ExprStopKind::StopParen)
                    )
                );

                if value == &null {
                    dyn()->diag->report(DiagID::S052E, name_range.start,
                        "expected expression after ':' in named argument"
                    ).first(name_range).emit();

                    if self._is_decl_keyword(dyn()->current().kind) { return; }
                    self._sync_expr(ExprSyncCtx::Comma, 1);
                } else {
                    var name_expr = NamedIdentExpr::create(dyn()->ctx, name_range, name_tok);
                    var colon_tok = Token();
                    colon_tok.kind  = TokenKind::OpColon;
                    colon_tok.range = name_range;

                    var named = AssignOperatorExpr::create(
                        dyn()->ctx,
                        name_range | value->range,
                        name_expr,
                        value,
                        colon_tok
                    );
                    out->push_back(named);
                }
            } else {
                // positional argument
                var arg = self.parse_expr(
                    static_cast::<ExprStopKind>(
                        static_cast::<u8>(ExprStopKind::StopComma)
                    | static_cast::<u8>(ExprStopKind::StopParen)
                    )
                );

                if (arg == &null) || is_recovery(arg) {
                    if self._is_decl_keyword(dyn()->current().kind) { return; }
                    self._sync_expr(ExprSyncCtx::Comma, 1);

                    // after sync, if we landed on comma consume it and continue
                    if dyn()->check(TokenKind::OpComma) {
                        dyn()->advance(T::SkipNL::After);
                        continue;
                    }
                    // if we landed on ) or a decl keyword, let the outer loop handle it
                    continue;
                } else {
                    out->push_back(arg);
                }
            }

            // consume comma between args
            if dyn()->check(TokenKind::OpComma) {
                dyn()->advance(T::SkipNL::After);

                // trailing comma before closer: foo(a, b,)
                if dyn()->check(TokenKind::OpRParen) { return; }

                continue;
            }

            dyn()->advance(T::SkipNL::Only);

            // no comma and not `)` missing separator
            if !dyn()->check(TokenKind::OpRParen) {
                // check bail before reporting
                if self._is_decl_keyword(dyn()->current().kind) { return; }

                dyn()->report_tok(DiagID::S054E, dyn()->current_ptr(),
                    "expected ',' or ')' after argument in function call"
                );

                self._sync_expr(ExprSyncCtx::Paren, 1, 0, 0, true);
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
            || k == TokenKind::TkEof;
    }

    // ========================================================================
    //  Subscript expression
    // ========================================================================

    /// \brief parses a subscript: base [ index ]
    ///
    /// precondition: current token is `[`
    inline fn _parse_subscript_expr(self, base: *Expr) -> *Expr {
        var lsquare_range = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `[`

        if dyn()->check(TokenKind::OpRSquare) {
            dyn()->diag->report(DiagID::S054E, lsquare_range.start,
                "expected index expression inside '[]\x27"
            ).first(lsquare_range).emit();
            var rsquare_range = dyn()->current_ptr()->range;
            dyn()->advance(); // consume `]`
            return SubscriptExpr::create_error(dyn()->ctx, base->range | rsquare_range);
        }

        var index = self.parse_expr(
            static_cast::<ExprStopKind>(static_cast::<u8>(ExprStopKind::StopSquare))
        );

        if index == &null {
            dyn()->diag->report(DiagID::S052E, lsquare_range.start,
                "expected index expression after '[\x27"
            ).first(lsquare_range).emit();
            self._sync_expr(ExprSyncCtx::Square, 0, 1);
            return SubscriptExpr::create_error(dyn()->ctx, base->range | dyn()->prev().range);
        }

        var end_range = dyn()->prev().range;
        if dyn()->check(TokenKind::OpRSquare) {
            end_range = dyn()->current_ptr()->range;
            dyn()->advance(); // consume `]`
        } else {
            dyn()->diag->report(DiagID::S054E, lsquare_range.start,
                "expected ']' after index expression"
            ).first(lsquare_range).emit();
            self._sync_expr(ExprSyncCtx::Square, 0, 1, 0, true);
            end_range = dyn()->prev().range;
        }

        return SubscriptExpr::create(dyn()->ctx, base->range | end_range, base, index);
    }

    // ========================================================================
    //  Type cast
    // ========================================================================

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
    inline fn _try_type_cast(self, operand: *Expr) -> *Expr {
        inline "c++" {
            using ASTTentativeGuard = typename T::TentativeGuard;
        }
        var t = ASTTentativeGuard(dyn());

        dyn()->advance(); // consume `as`

        var is_unsafe = false;
        if dyn()->check(TokenKind::KwUnsafe) {
            is_unsafe = true;
            dyn()->advance();
        }

        var target = dyn()->parse_type();
        if (target == &null) || is_recovery(target) {
            return &null; // guard dtor pops suppress + rolls cursor back to `as`
        }

        // tiebreaker: a `{` after the parsed type is a context-binding body
        // (`as const x { ... }`), never a cast. roll back.
        if dyn()->check(TokenKind::OpLBrace) {
            return &null;
        }

        t.commit();
        return TypeCastExpr::create(
            dyn()->ctx,
            operand->range | target->range,
            operand,
            target,
            is_unsafe
        );
    }

    // ========================================================================
    //  Primary expression dispatch
    // ========================================================================

    /// \brief dispatches the current token to the correct primary production.
    ///
    /// handles: integer/float/string/char/bool/null literals, identifiers
    /// (with optional generic args), parenthesized expressions and tuple
    /// literals, array/set/map literals, closure expressions.
    priv fn _parse_primary_expr(self, stop: ExprStopKind = ExprStopKind::Default) -> *Expr {
        if dyn()->is_eof() { return &null; }

        var cur_ptr = dyn()->current_ptr();
        if cur_ptr == &null { return &null; }
        var cur_range = cur_ptr->range;
        
        while true {
            
            if dyn()->check(TokenKind::KwFinal) {
                var r = dyn()->current_ptr()->range;
                dyn()->diag->report(DiagID::S052E, r.start,
                    "'final' is not valid in this position of an expression"
                ).first(r).emit();
                dyn()->advance();
            }
            
            else if dyn()->check(TokenKind::KwInline) {
                var r = dyn()->current_ptr()->range;
                dyn()->diag->report(DiagID::S052E, r.start,
                    "'inline' is not valid in this position of an expression"
                ).first(r).emit();
                dyn()->advance();
            }

            else if dyn()->check(TokenKind::KwPanic) {
                var r = dyn()->current_ptr()->range;
                dyn()->diag->report(DiagID::S052E, r.start,
                    "'panic' is not valid in this position of an expression"
                ).first(r).emit();
                dyn()->advance();
            }

            else if dyn()->check(TokenKind::KwVolatile) {
                var r = dyn()->current_ptr()->range;
                dyn()->diag->report(DiagID::S052E, r.start,
                    "'volatile' is not valid in this position of an expression"
                ).first(r).emit();
                dyn()->advance();
            }

            else if dyn()->check(TokenKind::KwAsync) {
                var r = dyn()->current_ptr()->range;
                dyn()->diag->report(DiagID::S052E, r.start,
                    "'async' is not valid in this position of an expression"
                ).first(r).emit();
                dyn()->advance();
            }
            
            
            else {
                cur_ptr = dyn()->current_ptr();
                if cur_ptr == &null { break; }
                cur_range = cur_ptr->range;
                break;
            }
        }

        // -- integer literal -----------------------------------------
        if dyn()->check(TokenKind::LitInt) {
            var tok = dyn()->current();
            dyn()->advance();
            return IntegerLiteralExpr::create(dyn()->ctx, tok.range, tok);
        }

        // -- float literal -------------------------------------------
        if dyn()->check(TokenKind::LitFloat) {
            var tok = dyn()->current();
            dyn()->advance();
            return FloatingLiteralExpr::create(dyn()->ctx, tok.range, tok);
        }

        // -- string literal ------------------------------------------
        if dyn()->check(TokenKind::LitString) {
            var tok = dyn()->current();
            dyn()->advance();
            return self._parse_string_literal(tok);
        }

        // -- char literal --------------------------------------------
        if dyn()->check(TokenKind::LitChar) {
            var tok = dyn()->current();
            dyn()->advance();
            return CharacterLiteralExpr::create(dyn()->ctx, tok.range, tok);
        }

        // -- bool literal: true --------------------------------------
        if dyn()->check(TokenKind::KwTrue) {
            var tok_range = cur_range;
            dyn()->advance();
            return BooleanLiteralExpr::create(dyn()->ctx, tok_range, true);
        }

        // -- bool literal: false -------------------------------------
        if dyn()->check(TokenKind::KwFalse) {
            var tok_range = cur_range;
            dyn()->advance();
            return BooleanLiteralExpr::create(dyn()->ctx, tok_range, false);
        }

        // -- null literal --------------------------------------------
        if dyn()->check(TokenKind::LitNull) {
            var tok_range = cur_range;
            dyn()->advance();
            return NullLiteralExpr::create(dyn()->ctx, tok_range, false);
        }

        // -- parenthesized expr or tuple literal ---------------------
        if dyn()->check(TokenKind::OpLParen) {
            return self._parse_paren_expr();
        }

        // -- square bracket: array literal ---------------------------
        if dyn()->check(TokenKind::OpLSquare) {
            return self._parse_list_literal();
        }

        // -- brace: set/map literal or anon initializer --------------
        if dyn()->check(TokenKind::OpLBrace) {
            return self._parse_brace_expr();
        }

        // -- closure: fn ---------------------------------------------
        if dyn()->check(TokenKind::KwFn) {
            return self._parse_closure_expr();
        }

        // -- keyword prefix: if --------------------------------------
        if dyn()->check(TokenKind::KwIf)  {
            return self._parse_if_expr();
        }

        // -- keyword prefix: try -------------------------------------
        if dyn()->check(TokenKind::KwTry) {
            return self._parse_try_catch_expr();
        }

        // -- keyword prefix: match -----------------------------------
        if dyn()->check(TokenKind::KwMatch) {
            return self._parse_match_expr();
        }

        // -- code completion -----------------------------------------
        if dyn()->check(TokenKind::TkCodeComplete) {
            dyn()->maybe_complete(CompletionContextKind::ExprStart);
            dyn()->advance(T::SkipNL::After);
            return self._error_expr(cur_range);
        }

        if dyn()->check(TokenKind::OpRange) || dyn()->check(TokenKind::OpRangeEqual) {
            var op_range = dyn()->current_ptr()->range;
            var is_inclusive = dyn()->check(TokenKind::OpRangeEqual);
            dyn()->advance(T::SkipNL::After);

            if (dyn()->is_eof()) || (self._should_stop(stop)) {
                return RangeExpr::create(dyn()->ctx, op_range, &null, &null, is_inclusive);
            }

            var k = dyn()->current().kind;
            if k == TokenKind::OpRParen
            || k == TokenKind::OpRSquare
            || k == TokenKind::OpRBrace
            || k == TokenKind::OpComma
            || k == TokenKind::OpSemicolon
            || k == TokenKind::TkNewLine {
                return RangeExpr::create(dyn()->ctx, op_range, &null, &null, is_inclusive);
            }

            var rhs = self._parse_unary_expr(stop);
            var end_range = (rhs->range) if (rhs != &null) else op_range;
            return RangeExpr::create(dyn()->ctx, op_range | end_range, &null, rhs, is_inclusive);
        }

        // -- identifier (including `self`) ---------------------------
        if dyn()->check(fn(k: TokenKind) -> bool {
            return EXPR_IDENT_TBL.contains(k);
        }) {
            return self._parse_ident_expr();
        }

        // -- global root path: ::foo ---------------------------------
        if dyn()->check(TokenKind::OpColonColon) {
            return self._parse_global_root_expr();
        }

        // -- no production matched -----------------------------------
        var resolved = dyn()->resolve_deep(cur_ptr);

        // poisoned macro expansion: the PP already reported the real error at
        // the invocation site. A second "expected expression" here is pure
        // noise consume the sentinel and recover silently.
        if (static_cast::<u32>(resolved.kind) == static_cast::<u32>(TokenKind::TkMacroExpand))
        && (resolved.imm == static_cast::<u32>(MacroSentinel::Poison)) {
            dyn()->advance();
            return self._error_expr(cur_range);
        }

        dyn()->diag->report(DiagID::S052E, cur_range.start,
            f"expected expression, found '{token_kind_to_readable_string(resolved.kind)}\x27"
        ).first(cur_range).emit();

        dyn()->advance(); // skip to prevent infinite loop
        return self._error_expr(cur_range);
    }

    // ========================================================================
    //  Identifier expression (with optional generic args)
    // ========================================================================

    /// \brief parses a bare identifier, optionally followed by generic args
    ///        if the hoisted scope indicates it's generic.
    ///
    /// foo       -> NamedIdentExpr("foo")
    /// Bar<i32>  -> NamedIdentExpr("Bar", generic_args=[i32])
    /// self      -> NamedIdentExpr("self")
    inline fn _parse_ident_expr(self) -> *Expr {
        inline "c++" {
            using ASTTentativeGuard = typename T::TentativeGuard;
        }

        var id_ptr   = dyn()->current_ptr();
        var id_range = id_ptr->range;
        var id_tok   = *id_ptr;
        dyn()->advance(); // consume identifier

        var nte = NamedIdentExpr::create(dyn()->ctx, id_range, id_tok);

        // check for generic args: Foo<T>
        // three-state verdict (rule 3/4): known generic commits generic args,
        // known non-generic commits comparison (rule 4 no tentative), and
        // only genuinely unknown names run the tentative parse.
        if dyn()->check(TokenKind::OpLess) {
            var verdict = self._generic_verdict(*id_ptr);
            if verdict == GenericVerdict::Generic {
                var generic_args: std::StackBuf::<ChainType::GenericArg, 4>;
                dyn()->_parse_generic_args(&generic_args);
                if dyn()->_pending_close_angle { dyn()->_pending_close_angle = false; }
                nte->generic_args.from_buf(
                    generic_args.data(), generic_args.size(), dyn()->ctx
                );
                nte->range = id_range | dyn()->prev().range;
            }
            else if verdict == GenericVerdict::Unknown { // no evidence tentative parse
                var t = ASTTentativeGuard(dyn());
                var generic_args: std::StackBuf::<ChainType::GenericArg, 4>;
                var ok = dyn()->_parse_generic_args(&generic_args);

                if dyn()->_pending_close_angle { dyn()->_pending_close_angle = false; }

                if ok && !generic_args.is_empty() {
                    // check what follows: must be a valid postfix continuation
                    var k = dyn()->current().kind;
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
                            generic_args.data(), generic_args.size(), dyn()->ctx
                        );
                        nte->range = id_range | dyn()->prev().range;
                        t.commit();
                    }
                }
            }
        }

        return nte;
    }

    // ========================================================================
    //  Global root path: ::foo::bar
    // ========================================================================

    inline fn _parse_global_root_expr(self) -> *Expr {
        var start_range = dyn()->current_ptr()->range;
        dyn()->advance(); // consume leading `::`

        // expect identifier after `::`
        if !dyn()->check(fn(k: TokenKind) -> bool {
            return EXPR_IDENT_TBL.contains(k);
        }) {
            dyn()->diag->report(DiagID::S054E, start_range.start,
                "expected identifier after '::' in global scope path"
            ).first(start_range).emit();
            return self._error_expr(start_range);
        }

        var id_ptr   = dyn()->current_ptr();
        var id_range = id_ptr->range;
        dyn()->advance(); // consume identifier

        var nte = NamedIdentExpr::create(dyn()->ctx, id_range, *id_ptr);

        // build a global-root chain with first step
        var first_step = ChainExpr::Step{};
        first_step.name          = nte;
        first_step.access_kind   = ChainExpr::AccessKind::ColonColon;
        first_step.range         = start_range | id_range;
        first_step.resolved_type = &null;
        first_step.resolved_decl = &null;
        first_step.is_ufcs       = false;

        // check for generic args on first segment
        if dyn()->check(TokenKind::OpLess) {
            if self._is_generic_name(*id_ptr) {
                var generic_args: std::StackBuf::<ChainType::GenericArg, 4>;
                dyn()->_parse_generic_args(&generic_args);
                if dyn()->_pending_close_angle { dyn()->_pending_close_angle = false; }

                first_step.generic_args.from_buf(
                    generic_args.data(), generic_args.size(), dyn()->ctx
                );
                
                first_step.range = start_range | dyn()->prev().range;
            }
        }

        var ce = ChainExpr::create_global(dyn()->ctx, start_range | dyn()->prev().range);

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

        var steps_buf: std::StackBuf::<ChainExpr::Step, 1>;
        steps_buf.push_back(first_step);
        ce->steps.from_buf(steps_buf.data(), steps_buf.size(), dyn()->ctx);
        ce->range = start_range | dyn()->prev().range;

        return ce;
    }

    // ========================================================================
    //  Parenthesized expression / tuple literal
    // ========================================================================

    /// \brief parses (expr) or (expr, expr, ...)
    ///        single expr -> unwrapped (no GroupingExpr since CST not needed)
    ///        comma-separated -> TupleLiteralExpr
    /// TODO apply the same nl logic to <> [] and {} parse functions
    inline fn _parse_paren_expr(self) -> *Expr {
        var lparen_range = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `(`
        dyn()->nl_push();

        if dyn()->check(TokenKind::OpRParen) {
            var rparen_range = dyn()->current_ptr()->range;
            dyn()->nl_pop();
            dyn()->advance_raw();
            dyn()->diag->report(DiagID::S054E, lparen_range.start,
                "empty parenthesized expression is not valid, did you mean to call a function?"
            ).first(lparen_range | rparen_range).emit();
            return self._error_expr(lparen_range | rparen_range);
        }

        var first = self.parse_expr(
            static_cast::<ExprStopKind>(
                static_cast::<u8>(ExprStopKind::StopComma)
              | static_cast::<u8>(ExprStopKind::StopParen)
            )
        );

        if first == &null {
            dyn()->diag->report(DiagID::S052E, lparen_range.start,
                "expected expression after '(\x27"
            ).first(lparen_range).emit();
            self._sync_expr(ExprSyncCtx::Paren, 1, 0, 0, true);
            dyn()->nl_pop();
            return self._error_expr(lparen_range | dyn()->prev().range);
        }

        if dyn()->check(TokenKind::OpComma) {
            // _finish_tuple_literal pops on all of its exits
            return self._finish_tuple_literal(lparen_range, first);
        }

        dyn()->nl_pop();
        if dyn()->check(TokenKind::OpRParen) {
            dyn()->advance_raw(); // consume `)` keep trailing NL significant
            return first;
        }

        // missing `)` report WITHOUT eating the offending token (old code
        // advanced blindly and could swallow the statement terminator).
        dyn()->diag->report(DiagID::S054E, first->range.start,
            "expected ')' or ',' after expression"
        ).first(first->range).emit();
        return first;
    }

    /// \brief finishes parsing a tuple literal after the first element and comma.
    inline fn _finish_tuple_literal(self, start_range: SourceRange, first: *Expr) -> *Expr {
        var elements: std::StackBuf::<*Expr, 8>;
        elements.push_back(first);

        while dyn()->check(TokenKind::OpComma) {
            dyn()->advance(T::SkipNL::After); // consume `,`

            if dyn()->check(TokenKind::OpRParen) { break; } // trailing comma

            var elem = self.parse_expr(
                static_cast::<ExprStopKind>(
                    static_cast::<u8>(ExprStopKind::StopComma)
                  | static_cast::<u8>(ExprStopKind::StopParen)
                )
            );

            if (elem == &null) || is_recovery(elem) {
                self._sync_expr(ExprSyncCtx::Comma, 1);
                continue;
            }

            elements.push_back(elem);
        }

        var end_range = dyn()->prev().range;
        if dyn()->check(TokenKind::OpRParen) {
            end_range = dyn()->current_ptr()->range;
            dyn()->advance(); // consume `)`
        } else {
            dyn()->diag->report(DiagID::S054E, start_range.start,
                "expected ')' to close tuple literal"
            ).first(start_range).emit();
        }

        var full_range = start_range | end_range;
        var tuple = TupleLiteralExpr::create(dyn()->ctx, full_range);
        tuple->elements.from_buf(elements.data(), elements.size(), dyn()->ctx);
        return tuple;
    }

    // ========================================================================
    //  Array literal: [expr, expr, ...]
    // ========================================================================

    inline fn _parse_list_literal(self) -> *Expr {
        var lsquare_range = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `[`

        // empty array: []
        if dyn()->check(TokenKind::OpRSquare) {
            var rsquare_range = dyn()->current_ptr()->range;
            dyn()->advance();
            var ll = ListLiteralExpr::create(dyn()->ctx, lsquare_range | rsquare_range);
            return ll;
        }

        var elements: std::StackBuf::<*Expr, 8>;

        while !dyn()->is_eof() {
            if dyn()->check(TokenKind::OpRSquare) { break; }

            var elem = self.parse_expr(
                static_cast::<ExprStopKind>(
                    static_cast::<u8>(ExprStopKind::StopComma)
                  | static_cast::<u8>(ExprStopKind::StopSquare)
                )
            );

            if (elem == &null) || is_recovery(elem) {
                self._sync_expr(ExprSyncCtx::Comma, 0, 1);
                if dyn()->check(TokenKind::OpComma) {
                    dyn()->advance(T::SkipNL::After);
                }
                continue;
            }

            elements.push_back(elem);

            if dyn()->check(TokenKind::OpComma) {
                dyn()->advance(T::SkipNL::After);
                continue;
            }

            break;
        }

        var end_range = dyn()->prev().range;
        if dyn()->check(TokenKind::OpRSquare) {
            end_range = dyn()->current_ptr()->range;
            dyn()->advance();
        } else {
            dyn()->diag->report(DiagID::S054E, lsquare_range.start,
                "expected ']' to close array literal"
            ).first(lsquare_range).emit();
        }

        var ll = ListLiteralExpr::create(dyn()->ctx, lsquare_range | end_range);
        ll->elements.from_buf(elements.data(), elements.size(), dyn()->ctx);
        return ll;
    }

    // ========================================================================
    // String literal
    // ========================================================================
    
    priv fn _parse_string_literal(self, tok: Token) -> *Expr {
        // The token reaching here passed check(LitString), but _resolve_and_check
        // re-badges a failed-string TkError (whose recovery imm == LitString) as
        // LitString, so a lex error can launder itself into this branch. Resolve
        // the macro chain and inspect the TRUE kind: if it's TkError, the string
        // never lexed; emit a recovery node instead of reading tok.imm as a
        // StringData index (which it isn't, it's the recovery TokenKind).
        
        inline "c++" {
            using _StreamGuard = typename T::StreamGuard;
        }

        var resolved = dyn()->resolve_deep(&tok);
        if resolved.kind == TokenKind::TkError {
            return self._error_expr(tok.range);
        }

        var imm_tbl = dyn()->ctx->get_imm_table();
        if imm_tbl == &null {
            // no imm table: bare plain node so the null-imm accessors are never hit.
            return static_cast::<*Expr>(
                StringLiteralExpr::create(dyn()->ctx, tok.range, tok,
                                        StringLiteralExpr::StringKind::Plain));
        }

        inline "c++" {
            auto sdata = imm_tbl->template get<Immediate::StringData>(resolved.imm);
        }

        // map prefix_kind flags -> StringKind flags. Both are flag enums now, so
        // raw|format (rf) is representable. prefix_kind: None=0, Format=1<<0, Raw=1<<1.
        var skind: u8 = 0;
        if sdata != &null {
            if (static_cast::<u8>(sdata->prefix_kind)
            & static_cast::<u8>(Immediate::TextPrefixKind::Format)) != 0 {
                skind |= static_cast::<u8>(StringLiteralExpr::StringKind::Format);
            }
            if (static_cast::<u8>(sdata->prefix_kind)
            & static_cast::<u8>(Immediate::TextPrefixKind::Raw)) != 0 {
                skind |= static_cast::<u8>(StringLiteralExpr::StringKind::Raw);
            }
        }

        var node = StringLiteralExpr::create(
            dyn()->ctx, tok.range, tok,
            static_cast::<StringLiteralExpr::StringKind>(skind));
        node->imm = sdata;   // attach: every get_*/is_* accessor asserts on null imm

        // Parse holes off the DATA, not the kind: rf is both raw and format, and a
        // format string with zero holes needs no loop. exprs.size() > 0 is the
        // unambiguous "has holes" signal the lexer already computed.
        if (sdata == &null) || (sdata->exprs.size() == 0) {
            return static_cast::<*Expr>(node);
        }

        var parts: std::StackBuf::<*Expr, 8>;

        for var i: usize = 0; i < sdata->exprs.size(); ++i {
            var hole_buf   = libcxx::get::<0>(sdata->exprs[i]);
            var hole_range = libcxx::get::<1>(sdata->exprs[i]);

            if hole_buf == &null {
                parts.push_back(self._error_expr(hole_range));
                continue;
            }

            var count = hole_buf->size();
            inline "c++" {
                auto flat_tokens = dyn()->ctx->template alloc_array<Token>(count);
            }

            for var k: usize = 0; k < count; ++k {
                var t_ptr = hole_buf->get(k);
                if t_ptr != &null {
                    flat_tokens[k] = *t_ptr;
                }
            }

            var hole_span = TokenSpan(flat_tokens, count);

            // swap the cursor onto the hole's TokenBuffer<16>, parse one expr,
            // restore. No TentativeGuard may outlive this scope.
            var hole_expr: *Expr = &null;
            {
                var g = _StreamGuard(dyn(), hole_span);
                hole_expr = dyn()->parse_expr();
            } // g.op delete restores the main stream here

            if (hole_expr == &null) || is_recovery(hole_expr) {
                dyn()->diag->report(DiagID::S052E, hole_range.start,
                    "expected an expression inside f-string interpolation '{ }\x27"
                ).first(hole_range).emit();
                parts.push_back(self._error_expr(hole_range));
                continue;
            }
            parts.push_back(hole_expr);
        }

        node->parts.from_buf(parts.data(), parts.size(), dyn()->ctx);
        return static_cast::<*Expr>(node);
    }

    // ========================================================================
    //  Brace expression: set/map literal or anon initializer
    // ========================================================================

    /// \brief parses { ... } which could be:
    ///        - set literal:        {1, 2, 3}
    ///        - map literal:        {"a": 1, "b": 2}
    ///        - anon initializer:   { .x: 1, .y: 2 }
    inline fn _parse_brace_expr(self) -> *Expr {
        var lbrace_range = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `{`

        // empty braces
        if dyn()->check(TokenKind::OpRBrace) {
            var rbrace_range = dyn()->current_ptr()->range;
            dyn()->advance();
            // empty set literal
            var sl = SetLiteralExpr::create(dyn()->ctx, lbrace_range | rbrace_range);
            return sl;
        }

        // anon initializer: { .field: value, ... }
        if dyn()->check(TokenKind::OpDot) {
            return self._parse_anon_initializer(lbrace_range);
        }

        // parse first element to disambiguate set vs map
        var first = self.parse_expr(
            static_cast::<ExprStopKind>(
                static_cast::<u8>(ExprStopKind::StopComma)
              | static_cast::<u8>(ExprStopKind::StopBrace)
            )
        );

        if first == &null {
            dyn()->diag->report(DiagID::S052E, lbrace_range.start,
                "expected expression after '{\x27"
            ).first(lbrace_range).emit();
            self._sync_expr(ExprSyncCtx::Brace, 0, 0, 1);
            return self._error_expr(lbrace_range | dyn()->prev().range);
        }

        // map literal: { key: value, ... }
        if dyn()->check(TokenKind::OpColon) {
            return self._finish_map_literal(lbrace_range, first);
        }

        // set literal: { expr, ... }
        return self._finish_set_literal(lbrace_range, first);
    }

    inline fn _finish_set_literal(self, start_range: SourceRange, first: *Expr) -> *Expr {
        var elements: std::StackBuf::<*Expr, 8>;
        elements.push_back(first);

        while dyn()->check(TokenKind::OpComma) {
            dyn()->advance(T::SkipNL::After);

            if dyn()->check(TokenKind::OpRBrace) { break; }

            var elem = self.parse_expr(
                static_cast::<ExprStopKind>(
                    static_cast::<u8>(ExprStopKind::StopComma)
                  | static_cast::<u8>(ExprStopKind::StopBrace)
                )
            );

            if (elem == &null) || is_recovery(elem) {
                self._sync_expr(ExprSyncCtx::Comma, 0, 0, 1);
                continue;
            }

            elements.push_back(elem);
        }

        var end_range = dyn()->prev().range;
        if dyn()->check(TokenKind::OpRBrace) {
            end_range = dyn()->current_ptr()->range;
            dyn()->advance();
        } else {
            dyn()->diag->report(DiagID::S054E, start_range.start,
                "expected '}' to close set literal"
            ).first(start_range).emit();
        }

        var sl = SetLiteralExpr::create(dyn()->ctx, start_range | end_range);
        sl->elements.from_buf(elements.data(), elements.size(), dyn()->ctx);
        return sl;
    }

    inline fn _finish_map_literal(self, start_range: SourceRange, first_key: *Expr) -> *Expr {
        // current token is `:` after first key
        var entries: std::StackBuf::<MapLiteralExpr::Entry, 8>;

        // parse first value
        dyn()->advance(T::SkipNL::After); // consume `:`

        var first_val = self.parse_expr(
            static_cast::<ExprStopKind>(
                static_cast::<u8>(ExprStopKind::StopComma)
              | static_cast::<u8>(ExprStopKind::StopBrace)
            )
        );

        if first_val == &null {
            dyn()->diag->report(DiagID::S054E, start_range.start,
                "expected value after ':' in map literal"
            ).first(start_range).emit();
            self._sync_expr(ExprSyncCtx::Brace, 0, 0, 1);
            return self._error_expr(start_range | dyn()->prev().range);
        }

        var first_entry = MapLiteralExpr::Entry{};
        first_entry.key   = first_key;
        first_entry.value = first_val;
        first_entry.range = first_key->range | first_val->range;
        entries.push_back(first_entry);

        while dyn()->check(TokenKind::OpComma) {
            dyn()->advance(T::SkipNL::After);

            if dyn()->check(TokenKind::OpRBrace) { break; }

            var key = self.parse_expr(
                static_cast::<ExprStopKind>(
                    static_cast::<u8>(ExprStopKind::StopComma)
                  | static_cast::<u8>(ExprStopKind::StopBrace)
                )
            );

            if key == &null {
                self._sync_expr(ExprSyncCtx::Comma, 0, 0, 1);
                continue;
            }

            if !dyn()->check(TokenKind::OpColon) {
                dyn()->diag->report(DiagID::S054E, key->range.start,
                    "expected ':' after key in map literal"
                ).first(key->range).emit();
                self._sync_expr(ExprSyncCtx::Comma, 0, 0, 1);
                continue;
            }
            dyn()->advance(T::SkipNL::After); // consume `:`

            var val = self.parse_expr(
                static_cast::<ExprStopKind>(
                    static_cast::<u8>(ExprStopKind::StopComma)
                  | static_cast::<u8>(ExprStopKind::StopBrace)
                )
            );

            if val == &null {
                self._sync_expr(ExprSyncCtx::Comma, 0, 0, 1);
                continue;
            }

            var entry = MapLiteralExpr::Entry{};
            entry.key   = key;
            entry.value = val;
            entry.range = key->range | val->range;
            entries.push_back(entry);
        }

        var end_range = dyn()->prev().range;
        if dyn()->check(TokenKind::OpRBrace) {
            end_range = dyn()->current_ptr()->range;
            dyn()->advance();
        } else {
            dyn()->diag->report(DiagID::S054E, start_range.start,
                "expected '}' to close map literal"
            ).first(start_range).emit();
        }

        var ml = MapLiteralExpr::create(dyn()->ctx, start_range | end_range);
        ml->entries.from_buf(entries.data(), entries.size(), dyn()->ctx);
        return ml;
    }

    inline fn _parse_anon_initializer(self, start_range: SourceRange) -> *Expr {
        // current token is `.` (first field)
        var fields: std::StackBuf::<InitField, 8>;

        while !dyn()->is_eof() {
            if dyn()->check(TokenKind::OpRBrace) { break; }

            if !dyn()->check(TokenKind::OpDot) {
                dyn()->report_tok(DiagID::S054E, dyn()->current_ptr(),
                    "expected '.field: value' in anonymous initializer"
                );
                self._sync_expr(ExprSyncCtx::Comma, 0, 0, 1);
                if dyn()->check(TokenKind::OpComma) {
                    dyn()->advance(T::SkipNL::After);
                }
                continue;
            }

            dyn()->advance(); // consume `.`

            if !dyn()->check(TokenKind::LitIdentifier) {
                dyn()->report_tok(DiagID::S054E, dyn()->current_ptr(),
                    "expected field name after '.' in anonymous initializer"
                );
                self._sync_expr(ExprSyncCtx::Comma, 0, 0, 1);
                if dyn()->check(TokenKind::OpComma) {
                    dyn()->advance(T::SkipNL::After);
                }
                continue;
            }

            var name_tok   = dyn()->current();
            var name_range = name_tok.range;
            dyn()->advance(); // consume field name

            if !dyn()->check(TokenKind::OpColon) {
                dyn()->diag->report(DiagID::S054E, name_range.start,
                    "expected ':' after field name in anonymous initializer"
                ).first(name_range).emit();
                self._sync_expr(ExprSyncCtx::Comma, 0, 0, 1);
                if dyn()->check(TokenKind::OpComma) {
                    dyn()->advance(T::SkipNL::After);
                }
                continue;
            }
            dyn()->advance(T::SkipNL::After); // consume `:`

            var value = self.parse_expr(
                static_cast::<ExprStopKind>(
                    static_cast::<u8>(ExprStopKind::StopComma)
                  | static_cast::<u8>(ExprStopKind::StopBrace)
                )
            );

            if value == &null {
                self._sync_expr(ExprSyncCtx::Comma, 0, 0, 1);
                if dyn()->check(TokenKind::OpComma) {
                    dyn()->advance(T::SkipNL::After);
                }
                continue;
            }

            var fi = InitField{};
            fi.name  = name_tok;
            fi.value = value;
            fi.range = name_range | value->range;
            fields.push_back(fi);

            if dyn()->check(TokenKind::OpComma) {
                dyn()->advance(T::SkipNL::After);
                continue;
            }

            break;
        }

        var end_range = dyn()->prev().range;
        if dyn()->check(TokenKind::OpRBrace) {
            end_range = dyn()->current_ptr()->range;
            dyn()->advance();
        } else {
            dyn()->diag->report(DiagID::S054E, start_range.start,
                "expected '}' to close anonymous initializer"
            ).first(start_range).emit();
        }

        var ai = AnonInitializerExpr::create(dyn()->ctx, start_range | end_range);
        ai->fields.from_buf(fields.data(), fields.size(), dyn()->ctx);
        return ai;
    }

    /// \brief true if `e` is a type path that may precede a `{ ... }`
    ///        named initializer.
    /// \details accepts a bare identifier (NamedIdentExpr) or a chain whose
    ///          steps are all name/`::`/generic-instantiation (ChainExpr).
    ///          Rejects call results, subscripts, literals, and operator
    ///          expressions those can never name a type to initialize.
    ///          This is a *syntactic* gate; sema still verifies the path
    ///          actually resolves to an initializable aggregate.
    priv fn _is_initializable_path(self, e: *Expr) -> bool {
        if e == &null { return false; }
        if isa::<NamedIdentExpr>(e) { return true; }
        if isa::<ChainExpr>(e) {
            // A ChainExpr is initializable only if every step is a static
            // path step (`::`) or generic args, not a value access (`.`) or
            // a call. We let sema do the deep check; syntactically, a chain
            // ending in a type-ish step is admissible.
            return true;
        }
        return false;
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
    priv fn _parse_named_initializer(self, path: *Expr, stop: ExprStopKind) -> *Expr {
        var start_range = path->range;

        if !dyn()->enter_depth() {
            return static_cast::<*Expr>(NamedInitializerExpr::create_error(dyn()->ctx, start_range));
        }

        var lbrace_range = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `{`

        var fields: std::StackBuf::<InitField, 8>;

        while (!dyn()->is_eof()) && (!dyn()->check(TokenKind::OpRBrace)) {
            // tolerate stray newlines between fields
            if dyn()->check(TokenKind::TkNewLine) {
                dyn()->advance();
                continue;
            }

            var field = self._parse_init_field();
            if field.value == &null {
                // malformed field: sync to next `,` or the closing `}`.
                self._sync_init_field();
                if dyn()->check(TokenKind::OpRBrace) { break; }
                if dyn()->check(TokenKind::OpComma) {
                    dyn()->advance(T::SkipNL::After);
                    continue;
                }
                break;
            }
            fields.push_back(field);

            if dyn()->check(TokenKind::OpComma) {
                dyn()->advance(T::SkipNL::After);
                if dyn()->check(TokenKind::OpRBrace) { break; } // trailing comma
                continue;
            }
            break; // no comma => field list done
        }

        var full_range = start_range;
        if dyn()->check(TokenKind::OpRBrace) {
            full_range = start_range | dyn()->current_ptr()->range;
            dyn()->advance(T::SkipNL::Before); // consume `}`
        } else {
            dyn()->diag->report(DiagID::S054E, lbrace_range.start,
                "expected '}' to close named initializer"
            ).first(lbrace_range).emit();
            full_range = start_range | dyn()->prev().range;
        }

        var node = NamedInitializerExpr::create(dyn()->ctx, full_range, path);
        node->fields.from_buf(fields.data(), fields.size(), dyn()->ctx);

        dyn()->exit_depth();
        return static_cast::<*Expr>(node);
    }

    /// \brief parses a single `name : value` initializer field.
    /// \details returns an InitField with value == null on failure (caller
    ///          recovers). The field value is parsed with comma/brace stops so
    ///          it ends at the field boundary; nested named initializers in the
    ///          value are allowed (NoStructLiteral is not set on this call).
    priv fn _parse_init_field(self) -> InitField {
        var result = InitField{};
        result.name  = Token();
        result.value = &null;

        var start = dyn()->current_ptr()->range;

        if !dyn()->check(TokenKind::LitIdentifier) {
            dyn()->diag->report(DiagID::S054E, start.start,
                "expected field name in named initializer"
            ).first(start).emit();
            return result; // value stays null
        }
        var id_ptr   = dyn()->current_ptr();
        var id_range = id_ptr->range;
        dyn()->advance(); // consume field name
        result.name = *id_ptr;

        if !dyn()->check(TokenKind::OpColon) {
            dyn()->diag->report(DiagID::S054E, id_range.start,
                "expected ':' after field name in named initializer"
            ).first(id_range).emit();
            return result; // value stays null
        }
        dyn()->advance(T::SkipNL::After); // consume `:`

        // Field value: stop at `,` (next field) or `}` (end). Fresh stop kind,
        // so NoStructLiteral does NOT leak in nested initializers are legal.
        var value = dyn()->parse_expr(static_cast::<ExprStopKind>(
            static_cast::<u8>(ExprStopKind::StopComma)
          | static_cast::<u8>(ExprStopKind::StopBrace)
        ));
        if (value == &null) || (is_recovery(value)) {
            return result; // value stays null
        }
        result.value = value;
        result.range = start | value->range;
        return result;
    }

    /// \brief recovery: skip to the next field boundary inside an initializer.
    /// \details delimiter-aware; stops at depth-0 `,` or `}` so a malformed
    ///          field value doesn't swallow the rest of the initializer.
    priv fn _sync_init_field(self) {
        var depth_paren:  i32 = 0;
        var depth_square: i32 = 0;
        var depth_brace:  i32 = 0;
        var iters: u32 = 0;
        const var MAX: u32 = 128;

        while (!dyn()->is_eof()) && iters < MAX {
            ++iters;
            var k = dyn()->current().kind;

            if      k == TokenKind::OpLParen  { ++depth_paren;  }
            else if k == TokenKind::OpLSquare { ++depth_square; }
            else if k == TokenKind::OpLBrace  { ++depth_brace;  }
            else if k == TokenKind::OpRParen  { if depth_paren  > 0 { --depth_paren;  } }
            else if k == TokenKind::OpRSquare { if depth_square > 0 { --depth_square; } }
            else if k == TokenKind::OpRBrace {
                if depth_brace == 0 { return; } // closing brace of the initializer
                --depth_brace;
            }
            else if depth_paren == 0 && depth_square == 0 && depth_brace == 0 {
                if k == TokenKind::OpComma { return; }
            }
            dyn()->advance();
        }
    }

    // ========================================================================
    // Expression-form branches
    // ========================================================================

    /// \brief parses a single braced expression branch: '{' expr '}'
    /// \details shared by IfExpr and TryCatchExpr (and MatchExpr later). Exactly
    ///          one expression per branch; a statement or a second expression
    ///          inside the braces is a hard error. Returns null on any failure
    ///          so the caller can recover.
    priv fn _parse_expr_branch(self) -> *Expr {
        if !dyn()->check(TokenKind::OpLBrace) {
            var r = dyn()->current_ptr()->range;
            dyn()->diag->report(DiagID::S054E, r.start,
                "expected '{' to begin an expression branch"
            ).first(r).emit();
            return &null;
        }
        var lbrace = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `{`

        // empty branch `{ }` has no value.
        if dyn()->check(TokenKind::OpRBrace) {
            dyn()->diag->report(DiagID::S054E, lbrace.start,
                "expression branch must contain a value expression"
            ).first(lbrace).emit();
            return &null;
        }

        var value = dyn()->parse_expr(T::ExprStopKind::StopBrace);
        if (value == &null) || is_recovery(value) {
            return &null;
        }

        if !dyn()->check(TokenKind::OpRBrace) {
            dyn()->diag->report(DiagID::S054E, lbrace.start,
                "expression-form branch allows exactly one expression; "
                "use a statement form for multi-statement bodies"
            ).first(lbrace).emit();
            return &null;
        }
        dyn()->advance(T::SkipNL::Before); // consume `}`
        return value;
    }

    /// \brief parses an expression-form if.
    ///  Grammar:  'if' expr '{' expr '}' ('else' 'if' expr '{' expr '}')* 'else' '{' expr '}'
    ///
    /// \details called from _parse_primary_expr on KwIf. Conditions parse with
    ///          NoStructLiteral so `if Foo { }` is not read as a named init.
    ///          Each body is a single expression. The final `else` is mandatory
    ///          and parser-enforced.
    priv fn _parse_if_expr(self) -> *Expr {
        var start_range = dyn()->current_ptr()->range;

        if !dyn()->enter_depth() {
            return static_cast::<*Expr>(IfExpr::create_error(dyn()->ctx, start_range));
        }

        dyn()->advance(T::SkipNL::After); // consume `if`

        // primary condition
        var condition = dyn()->parse_expr(T::ExprStopKind::NoStructLiteral);
        if (condition == &null) || is_recovery(condition) {
            dyn()->exit_depth();
            return static_cast::<*Expr>(IfExpr::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }

        // primary then-branch
        var then_expr = self._parse_expr_branch();
        if then_expr == &null {
            dyn()->exit_depth();
            return static_cast::<*Expr>(IfExpr::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }

        var else_ifs:  std::StackBuf::<IfExpr::ElseIf, 4>;
        var else_expr: *Expr = &null;

        // else / else-if chain
        while dyn()->check(TokenKind::KwElse) {
            dyn()->advance(T::SkipNL::After); // consume `else`

            if dyn()->check(TokenKind::KwIf) {
                // `else if` arm
                var ei_start = dyn()->current_ptr()->range;
                dyn()->advance(T::SkipNL::After); // consume `if`

                var ei_cond = dyn()->parse_expr(T::ExprStopKind::NoStructLiteral);
                if (ei_cond == &null) || is_recovery(ei_cond) {
                    dyn()->exit_depth();
                    return static_cast::<*Expr>(IfExpr::create_error(dyn()->ctx, start_range | dyn()->prev().range));
                }

                var ei_body = self._parse_expr_branch();
                if ei_body == &null {
                    dyn()->exit_depth();
                    return static_cast::<*Expr>(IfExpr::create_error(dyn()->ctx, start_range | dyn()->prev().range));
                }

                var arm = IfExpr::ElseIf{};
                arm.condition = ei_cond;
                arm.body      = ei_body;
                arm.range     = ei_start | ei_body->range;
                else_ifs.push_back(arm);
                continue;
            }

            // final `else` branch
            else_expr = self._parse_expr_branch();
            if else_expr == &null {
                dyn()->exit_depth();
                return static_cast::<*Expr>(IfExpr::create_error(dyn()->ctx, start_range | dyn()->prev().range));
            }
            break; // else is terminal
        }

        // mandatory else
        if else_expr == &null {
            dyn()->diag->report(DiagID::S054E, start_range.start,
                "expression-form 'if' requires a final 'else' (every branch must yield a value)"
            ).first(start_range).emit();
            dyn()->exit_depth();
            return static_cast::<*Expr>(IfExpr::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }

        var node = IfExpr::create(dyn()->ctx, start_range | else_expr->range, condition, then_expr, else_expr);
        node->else_ifs.from_buf(else_ifs.data(), else_ifs.size(), dyn()->ctx);

        dyn()->exit_depth();
        return static_cast::<*Expr>(node);
    }

    /// \brief parses an expression-form try/catch.
    ///  Grammar:  'try' '{' expr '}'
    ///            ('catch' ('var'|'const')? ident ':' type '{' expr '}')*
    ///            ('catch' ('var'|'const')? ident? '{' expr '}')?
    ///
    /// \details at least one catch arm is required (parser-enforced). A default
    ///          arm (filter == null) is terminal: anything after it is an error
    ///          (this also rejects multiple defaults). Bodies are single
    ///          expressions.
    priv fn _parse_try_catch_expr(self) -> *Expr {
        var start_range = dyn()->current_ptr()->range;

        if !dyn()->enter_depth() {
            return static_cast::<*Expr>(TryCatchExpr::create_error(dyn()->ctx, start_range));
        }

        dyn()->advance(T::SkipNL::After); // consume `try`

        var try_expr = self._parse_expr_branch();
        if try_expr == &null {
            dyn()->exit_depth();
            return static_cast::<*Expr>(TryCatchExpr::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }

        var arms:        std::StackBuf::<TryCatchExpr::CatchArm, 4>;
        var seen_default = false;

        while dyn()->check(TokenKind::KwCatch) {
            // a default arm is terminal; another arm after it is an error.
            if seen_default {
                var r = dyn()->current_ptr()->range;
                dyn()->diag->report(DiagID::S054E, r.start,
                    "no catch arm may follow a default 'catch' (the default is terminal)"
                ).first(r).emit();
                self._sync_to_brace_or_catch();
                dyn()->exit_depth();
                return static_cast::<*Expr>(TryCatchExpr::create_error(dyn()->ctx, start_range | dyn()->prev().range));
            }

            var arm = self._parse_catch_arm_expr();
            if arm.body == &null {
                self._sync_to_brace_or_catch();
                dyn()->exit_depth();
                return static_cast::<*Expr>(TryCatchExpr::create_error(dyn()->ctx, start_range | dyn()->prev().range));
            }
            if arm.filter == &null {
                seen_default = true; // untyped/bare catch is the default
            }
            arms.push_back(arm);
        }

        if arms.size() == 0 {
            dyn()->diag->report(DiagID::S054E, start_range.start,
                "'try' expression requires at least one 'catch' arm"
            ).first(start_range).emit();
            dyn()->exit_depth();
            return static_cast::<*Expr>(TryCatchExpr::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }

        var node = TryCatchExpr::create(dyn()->ctx, start_range | dyn()->prev().range, try_expr);
        node->catch_arms.from_buf(arms.data(), arms.size(), dyn()->ctx);

        dyn()->exit_depth();
        return static_cast::<*Expr>(node);
    }

    /// \brief parses an expression-form match.
    ///  Grammar:  'match' expr '{' (case|default)+ '}'
    ///
    /// \details reuses the statement-form match parser, then lifts each case's
    ///          body into expression position: every branch must be a single
    ///          ExpressionStmt, whose inner expr becomes the case value. A branch
    ///          that is empty, multi-statement, a non-expression statement, or a
    ///          recovery node is an error (the case is dropped to recovery).
    ///          Exhaustiveness is NOT checked here; sema owns coverage.
    priv fn _parse_match_expr(self) -> *Expr {
        var start_range = dyn()->current_ptr()->range;

        // parse via the statement form: scrutinee, braces, cases, patterns,
        // guards, and block bodies are all handled there and stay in sync.
        var ms_stmt = dyn()->_parse_match();
        if (ms_stmt == &null) || is_recovery(ms_stmt) {
            return static_cast::<*Expr>(
                MatchExpr::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }
        if !isa::<MatchStmt>(ms_stmt) {
            // defensive: _parse_match should always yield a MatchStmt on success.
            return static_cast::<*Expr>(
                MatchExpr::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }
        var ms = cast::<MatchStmt>(ms_stmt);

        // lift each case body (a CompoundStmt) into a single expression.
        var cases: std::StackBuf::<MatchCase, 8>;

        for var i: usize = 0; i < ms->cases.size(); ++i {
            var src = *(ms->cases.get(i));
            var lifted = self._lift_case_to_expr(&src);
            cases.push_back(lifted);
        }

        var node = MatchExpr::create(dyn()->ctx, ms->range, ms->scrutinee);
        node->cases.from_buf(cases.data(), cases.size(), dyn()->ctx);
        return static_cast::<*Expr>(node);
    }

    /// \brief lifts a single block-form MatchCase into expression form.
    /// \details copies patterns/guard/default flag, then resolves the body: the
    ///          CompoundStmt must hold exactly one non-error ExpressionStmt whose
    ///          expr is non-recovery. On any violation, emits a diagnostic and
    ///          returns the case with both body and expression null (recovery).
    priv fn _lift_case_to_expr(self, src: *MatchCase) -> MatchCase {
        var out = MatchCase{};
        out.patterns   = src->patterns;     // FrozenList copy; same arena nodes.
        out.guard      = src->guard;
        out.is_default = src->is_default;
        out.range      = src->range;
        out.body       = &null;
        out.expression = &null;

        var cb = src->body;
        if cb == &null {
            dyn()->diag->report(DiagID::S054E, src->range.start,
                "match expression branch must yield a value"
            ).first(src->range).emit();
            return out;
        }

        // exactly one statement
        if cb->body.size() == 0 {
            dyn()->diag->report(DiagID::S054E, cb->range.start,
                "match expression branch must contain a value expression"
            ).first(cb->range).emit();
            return out;
        }
        if cb->body.size() > 1 {
            dyn()->diag->report(DiagID::S054E, cb->range.start,
                "match expression branch allows exactly one expression; "
                "use a statement-form match for multi-statement bodies"
            ).first(cb->range).emit();
            return out;
        }

        // the single statement must be a non-error ExpressionStmt
        var only = *(cb->body.get(0));
        if (only == &null) || only->is_error() || (!isa::<ExpressionStmt>(only)) {
            dyn()->diag->report(DiagID::S054E, cb->range.start,
                "match expression branch must be a single value expression"
            ).first(cb->range).emit();
            return out;
        }

        // and its inner expression must be non-recovery
        var es = cast::<ExpressionStmt>(only);
        if (es->expr == &null) || is_recovery(es->expr) {
            dyn()->diag->report(DiagID::S054E, cb->range.start,
                "match expression branch contains an invalid expression"
            ).first(cb->range).emit();
            return out;
        }

        out.expression = es->expr;   // body stays null: expression path is live.
        return out;
    }

    /// \brief parses one catch arm of a try expression.
    ///  Grammar:  'catch' ('var'|'const')? ident? (':' type)? '{' expr '}'
    ///
    /// \details forms: `catch { v }` (bare default), `catch e { v }` /
    ///          `catch var e { v }` / `catch const e { v }` (untyped default,
    ///          mutable unless const), `catch e: T { v }` (typed). Mutability
    ///          defaults to mutable; `const` overrides. Returns an arm with a
    ///          null body on failure.
    priv fn _parse_catch_arm_expr(self) -> TryCatchExpr::CatchArm {
        var result = TryCatchExpr::CatchArm{};
        result.has_binding = false;
        result.is_const    = false;
        result.binding     = &null;
        result.filter      = &null;
        result.body        = &null;

        var start_range = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `catch`

        // optional mutability keyword
        if dyn()->check(TokenKind::KwConst) {
            result.is_const = true;
            dyn()->advance();
        } else if dyn()->check(TokenKind::KwVar) {
            result.is_const = false; // explicit mutable
            dyn()->advance();
        }

        // optional binding identifier
        if dyn()->check(TokenKind::LitIdentifier) {
            var id_ptr   = dyn()->current_ptr();
            var id_range = id_ptr->range;
            dyn()->advance();
            result.binding     = NamedIdentExpr::create(dyn()->ctx, id_range, *id_ptr);
            result.has_binding = true;

            // optional `: Type` filter (only meaningful with a binding)
            if dyn()->check(TokenKind::OpColon) {
                dyn()->advance(T::SkipNL::After); // consume `:`
                var filter = dyn()->parse_type();
                if (filter == &null) || is_recovery(filter) {
                    dyn()->diag->report(DiagID::S053E, start_range.start,
                        "expected a panic type after ':' in catch arm"
                    ).first(start_range).emit();
                    return result; // body stays null
                }
                result.filter = filter;
            }
        } else {
            // no identifier. A mutability keyword without a binding is invalid.
            if result.is_const {
                dyn()->diag->report(DiagID::S054E, start_range.start,
                    "'const' in a catch arm must be followed by a binding name"
                ).first(start_range).emit();
                return result; // body stays null
            }
        }

        // body
        var body = self._parse_expr_branch();
        if body == &null {
            return result; // body stays null
        }
        result.body  = body;
        result.range = start_range | body->range;
        return result;
    }

    /// \brief recovery: skip to the next `catch`, a closing brace at depth 0, or
    ///        a statement boundary, after a malformed catch arm. Delimiter-aware.
    priv fn _sync_to_brace_or_catch(self) {
        var depth: i32 = 0;
        var iters: u32 = 0;
        const var MAX:  u32 = 128;

        while (!dyn()->is_eof()) && iters < MAX {
            ++iters;
            var k = dyn()->current().kind;

            if k == TokenKind::OpLBrace || k == TokenKind::OpLParen || k == TokenKind::OpLSquare {
                ++depth;
            } else if k == TokenKind::OpRBrace || k == TokenKind::OpRParen || k == TokenKind::OpRSquare {
                if depth == 0 { return; }
                --depth;
            } else if depth == 0 {
                if k == TokenKind::KwCatch
                || k == TokenKind::TkNewLine
                || k == TokenKind::OpSemicolon {
                    return;
                }
            }
            dyn()->advance();
        }
    }

    // ========================================================================
    //  Generic disambiguation helper
    // ========================================================================

    /// \brief checks if a name refers to a generic type/function in hoisted scope.
    ///        used to disambiguate `<` as generic args vs comparison operator.
    ///
    /// \details scans ALL entries for the name, not first(): a mixed overload
    ///          set (non-generic + generic under one name) is generic if ANY
    ///          overload is the entry insertion order must not decide.
    inline fn _is_generic_name(self, tok: Token) -> bool {
        var hr = dyn()->ctx->hoisted->lookup_tok(tok);
        if !hr.found() { return false; }
        for var i: usize = 0; i < hr.entries->size(); ++i {
            if (*hr.entries)[i].is_generic() { return true; }
        }
        return false;
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
        Generic,     ///< commit `<` as generic arguments.
        NotGeneric,  ///< commit `<` as a comparison operator.
        Unknown,     ///< tentative parse decides.
    }

    fn _generic_verdict(self, tok: Token) -> GenericVerdict {
        // 1. lexical bindings shadow everything.
        var b = dyn()->scope.lookup(dyn()->ctx->get_spelling(tok));
        if b != &null {
            if b->is_tparam { return GenericVerdict::Generic; }
            if (b->decl != &null) && isa::<VariableDecl>(b->decl) {
                var vd = cast::<VariableDecl>(b->decl);
                if (vd->init != &null) && isa::<ClosureExpr>(vd->init) {
                    var cl = cast::<ClosureExpr>(vd->init);
                    if !cl->generic_params.is_empty() {
                        return GenericVerdict::Generic;
                    }
                }
            }
            return GenericVerdict::NotGeneric;
        }

        // 2. hoisted table.
        var hr = dyn()->ctx->hoisted->lookup_tok(tok);
        if hr.found() {
            var all_vars = true;
            for var i: usize = 0; i < hr.entries->size(); ++i {
                if (*hr.entries)[i].is_generic() { return GenericVerdict::Generic; }
                if (*hr.entries)[i].kind != DisambigKind::Variable { all_vars = false; }
            }
            if all_vars { return GenericVerdict::NotGeneric; }
            return GenericVerdict::Unknown; // known fn/op/type: assume generic if it parses as one
        }

        // 3. no evidence either way.
        return GenericVerdict::Unknown;
    }


    /// \brief parses a closure expression.
    ///  Grammar:  'fn' ('<' generic_params '>')? ('|' captures '|')?
    ///            ('(' params ')')? fn_modifiers? ('->' type)? (block | '=' expr)
    ///
    /// \details called from _parse_primary_expr on KwFn. Delegates signature
    ///          parsing to DeclParse::_parse_closure_sig via dyn(), then parses
    ///          the body as either a block or an expression body.
    priv fn _parse_closure_expr(self) -> *Expr {
        var start = dyn()->current_ptr()->range;

        if !dyn()->enter_depth() {
            return static_cast::<*Expr>(ClosureExpr::create_error(dyn()->ctx, start));
        }

        dyn()->advance(T::SkipNL::After); // consume `fn`

        dyn()->enter_scope(ScopeKind::Function, static_cast::<*DeclContext>(&null));
        var sig_result = dyn()->_parse_closure_sig();
        // signature: generics, captures, params, modifiers, return type
        // var (params, gparams, captures, modifiers, ret_type) = dyn()->_parse_closure_sig();
        var params               = libcxx::get::<0>(sig_result);
        var gparams              = libcxx::get::<1>(sig_result);
        var captures             = libcxx::get::<2>(sig_result);
        var modifiers            = libcxx::get::<3>(sig_result);
        var ret_type             = libcxx::get::<4>(sig_result);
        var explicit_no_capture = libcxx::get::<5>(sig_result);

        // open a function scope so param names resolve inside the body
        var ce = ClosureExpr::create(dyn()->ctx, start);
        ce->generic_params = gparams;
        ce->captures       = captures;
        ce->params         = params;
        ce->modifiers      = modifiers;
        ce->return_type    = ret_type;
        ce->explicit_no_capture = explicit_no_capture;

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

        // body: block `{ ... }` or expression `= expr`
        if dyn()->check(TokenKind::OpLBrace) {
            var block = dyn()->parse_compound();
            ce->body_kind  = FnBodyKind::Block;
            ce->body_block = block;
        } else if dyn()->check(TokenKind::OpEqual) {
            dyn()->advance(T::SkipNL::After); // consume `=`
            
            // Recovery if the token immediately following '=' cannot start an expression
            // remeber a nested closure is fully valid
            if dyn()->_starts_decl_kw(dyn()->current().kind) && (!dyn()->current().kind == TokenKind::KwFn) {
                dyn()->diag->report(DiagID::S052E, start.start,
                    "expected expression after '=' in closure body"
                ).first(start).emit();
                dyn()->exit_scope();
                dyn()->exit_depth();
                return static_cast::<*Expr>(
                    ClosureExpr::create_error(dyn()->ctx,
                    (start | dyn()->prev().range)
                ));
            }
            
            var expr = dyn()->parse_expr();
            if (expr != &null) && (!is_recovery(expr)) {
                ce->body_kind = FnBodyKind::Expr;
                ce->body_expr = expr;
            } else {
                dyn()->diag->report(DiagID::S052E, start.start,
                    "expected expression after '=' in closure body"
                ).first(start).emit();
                dyn()->exit_scope();
                dyn()->exit_depth();
                return static_cast::<*Expr>(
                    ClosureExpr::create_error(dyn()->ctx,
                    (start | dyn()->prev().range)
                ));
            }
        } else {
            dyn()->diag->report(DiagID::S054E, start.start,
                "expected '{' or '=' to begin closure body"
            ).first(start).emit();
            dyn()->exit_scope();
            dyn()->exit_depth();
            return static_cast::<*Expr>(
                ClosureExpr::create_error(dyn()->ctx,
                (start | dyn()->prev().range)
            ));
        }

        ce->range = start | dyn()->prev().range;
        dyn()->exit_scope();
        dyn()->exit_depth();
        return static_cast::<*Expr>(ce);
    }
}