/// --- The Kairo Project ------------------ Compiler/Parser/ExprParse.k ----- ///
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

import ASTNode::Base::*;
import ASTNode::PrimaryExpressions::*;
import ASTNode::Expressions::*;
import ASTNode::Types::*;
import ASTNode::Casting::*;
import AST::CodeCompleteConsumer::*;
import AST::ASTContext::*;
import Diag::DiagEngine::*;
import Diag::DiagRegistry::*;
import Source::SourceRange::*;
import Lexer::Token::*;
import TokenKind::*;

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
        Default    = 0,       ///< stop at ; newline EOF
        StopAngle  = 1 << 0,  ///< also stop at > >> at depth 0 (generic param defaults)
        StopParen  = 1 << 1,  ///< also stop at ) at depth 0
        StopSquare = 1 << 2,  ///< also stop at ] at depth 0
        StopBrace  = 1 << 3,  ///< also stop at } at depth 0
        StopComma  = 1 << 4,  ///< also stop at , at depth 0
    }

    // ════════════════════════════════════════════════════════════════════════
    //  CRTP helper
    // ════════════════════════════════════════════════════════════════════════

    priv inline fn dyn(self) -> *T {
        return static_cast::<*T>(&self);
    }

    priv inline fn _error_expr(self, range: SourceRange) -> *Expr {
        return static_cast::<*Expr>(ChainExpr::create_error(dyn()->ctx, range));
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Sync / recovery
    // ════════════════════════════════════════════════════════════════════════

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

    // ════════════════════════════════════════════════════════════════════════
    //  Entry point
    // ════════════════════════════════════════════════════════════════════════

    /// \brief operator precedence levels for the Pratt parser.
    ///        higher number = tighter binding.
    enum Precedence derives u8 {
        None       = 0,
        Assign     = 1,   // = += -= *= /= %= &= |= ^= <<= >>=
        Range      = 2,   // .. ..=
        Or         = 3,   // || or
        And        = 4,   // && and
        BitOr      = 5,   // | bitor
        BitXor     = 6,   // ^ xor
        BitAnd     = 7,   // & bitand
        Equality   = 8,   // == != ===
        Comparison = 9,   // < > <= >= <=>
        Shift      = 10,  // << >>
        Add        = 11,  // + -
        Multiply   = 12,  // * / %
        Power      = 13,  // ^^
        Prefix     = 14,  // unary (not used in table, just for reference)
        Postfix    = 15,  // call, subscript, access (not used in table)
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

            // ── range operators .. ..= ──────────────────────────────
            if cur_kind == TokenKind::OpRange || cur_kind == TokenKind::OpRangeEqual {
                lhs = self._parse_range_expr(lhs, stop);
                continue;
            }

            // ── assignment operators (right-associative) ────────────
            if self._is_assign_op(cur_kind) {
                var op_tok = dyn()->current();
                dyn()->advance(T::SkipNL::After); // consume operator

                var rhs = self._parse_unary_expr(stop);
                if rhs == &null {
                    dyn()->diag->report(DiagID::S045E, op_tok.range.start,
                        f"expected expression after '{token_kind_to_readable_string(op_tok.kind)}' "
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

            // ── exponentiation (right-associative) ──────────────
            if cur_kind == TokenKind::OpCaretCaret {
                var op_tok = dyn()->current();
                dyn()->advance(T::SkipNL::After);

                var rhs = self._parse_unary_expr(stop);
                if rhs == &null {
                    dyn()->diag->report(DiagID::S045E, op_tok.range.start,
                        "expected expression after '^^' "
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

            // ── regular binary operators (left-associative) ─────────
            var op_tok = dyn()->current();
            dyn()->advance(T::SkipNL::After); // consume operator

            var rhs = self._parse_unary_expr(stop);
            if rhs == &null {
                dyn()->diag->report(DiagID::S045E, op_tok.range.start,
                    f"expected expression after '{token_kind_to_readable_string(op_tok.kind)}' "
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


    // ════════════════════════════════════════════════════════════════════════
    //  Unary expressions
    // ════════════════════════════════════════════════════════════════════════

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

        // ── prefix unary operators ──────────────────────────────────
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
                dyn()->diag->report(DiagID::S045E, cur_range.start,
                    f"expected expression after '{token_kind_to_readable_string(op_tok.kind)}' "
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

        // ── keyword prefix: await ───────────────────────────────────
        if dyn()->check(TokenKind::KwAwait) {
            var kw_range = cur_range;
            dyn()->advance();
            var operand = self._parse_unary_expr(stop);
            if operand == &null {
                dyn()->diag->report(DiagID::S045E, kw_range.start,
                    "expected expression after 'await' "
                ).first(kw_range).emit();
                return AwaitExpr::create_error(dyn()->ctx, kw_range);
            }
            return AwaitExpr::create(dyn()->ctx, kw_range | operand->range, operand);
        }

        // ── keyword prefix: spawn ───────────────────────────────────
        if dyn()->check(TokenKind::KwSpawn) {
            var kw_range = cur_range;
            dyn()->advance();
            var operand = self._parse_unary_expr(stop);
            if operand == &null {
                dyn()->diag->report(DiagID::S045E, kw_range.start,
                    "expected expression after 'spawn' "
                ).first(kw_range).emit();
                return SpawnExpr::create_error(dyn()->ctx, kw_range);
            }
            return SpawnExpr::create(dyn()->ctx, kw_range | operand->range, operand);
        }

        // ── keyword prefix: thread ──────────────────────────────────
        if dyn()->check(TokenKind::KwThread) {
            var kw_range = cur_range;
            dyn()->advance();
            var operand = self._parse_unary_expr(stop);
            if operand == &null {
                dyn()->diag->report(DiagID::S045E, kw_range.start,
                    "expected expression after 'thread' "
                ).first(kw_range).emit();
                return ThreadExpr::create_error(dyn()->ctx, kw_range);
            }
            return ThreadExpr::create(dyn()->ctx, kw_range | operand->range, operand);
        }

        // ── keyword prefix: eval ────────────────────────────────────
        if dyn()->check(TokenKind::KwEval) {
            var kw_range = cur_range;
            dyn()->advance();
            var operand = self._parse_unary_expr(stop);
            if operand == &null {
                dyn()->diag->report(DiagID::S045E, kw_range.start,
                    "expected expression after 'eval' "
                ).first(kw_range).emit();
                return EvalExpr::create_error(dyn()->ctx, kw_range);
            }
            return EvalExpr::create(dyn()->ctx, kw_range | operand->range, operand);
        }

        // ── keyword prefix: unsafe ──────────────────────────────────
        if dyn()->check(TokenKind::KwUnsafe) {
            var kw_range = cur_range;
            dyn()->advance();
            var operand = self._parse_unary_expr(stop);
            if operand == &null {
                dyn()->diag->report(DiagID::S045E, kw_range.start,
                    "expected expression after 'unsafe' "
                ).first(kw_range).emit();
                return UnsafeExpr::create_error(dyn()->ctx, kw_range);
            }
            return UnsafeExpr::create(dyn()->ctx, kw_range | operand->range, operand);
        }

        // ── keyword prefix: delete ──────────────────────────────────
        if dyn()->check(TokenKind::KwDelete) {
            var kw_range = cur_range;
            dyn()->advance();

            var is_array = false;
            if dyn()->check(TokenKind::OpLSquare) {
                dyn()->advance();
                if !dyn()->check(TokenKind::OpRSquare) {
                    dyn()->diag->report(DiagID::S045E, kw_range.start,
                        "expected ']' after 'delete [' "
                    ).first(kw_range).emit();
                } else {
                    dyn()->advance(); // consume ]
                }
                is_array = true;
            }

            var operand = self._parse_unary_expr(stop);
            if operand == &null {
                dyn()->diag->report(DiagID::S045E, kw_range.start,
                    "expected expression after 'delete' "
                ).first(kw_range).emit();
                return DeleteExpr::create_error(dyn()->ctx, kw_range);
            }
            return DeleteExpr::create(dyn()->ctx, kw_range | operand->range, operand, is_array);
        }

        // ── keyword prefix: sizeof ──────────────────────────────────
        if dyn()->check(TokenKind::KwSizeOf) {
            return self._parse_sizeof_expr();
        }

        // ── keyword prefix: alignof ─────────────────────────────────
        if dyn()->check(TokenKind::KwAlignOf) {
            return self._parse_alignof_expr();
        }

        // ── keyword prefix: typeof ──────────────────────────────────
        if dyn()->check(TokenKind::KwTypeOf) {
            return self._parse_typeof_expr();
        }

        // ── no prefix: parse postfix ────────────────────────────────
        return self._parse_postfix_expr(stop);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  sizeof / alignof / typeof
    // ════════════════════════════════════════════════════════════════════════

    inline fn _parse_sizeof_expr(self) -> *Expr {
        var kw_range = dyn()->current_ptr()->range;
        dyn()->advance(); // consume `sizeof`

        var has_paren = dyn()->check(TokenKind::OpLParen);
        if has_paren { dyn()->advance(T::SkipNL::After); }

        var ty = dyn()->parse_type();
        if ty == &null {
            dyn()->diag->report(DiagID::S045E, kw_range.start,
                "expected type after 'sizeof' "
            ).first(kw_range).emit();
            return SizeOfExpr::create_error(dyn()->ctx, kw_range);
        }

        if has_paren {
            if !dyn()->check(TokenKind::OpRParen) {
                dyn()->diag->report(DiagID::S045E, kw_range.start,
                    "expected ')' after type in 'sizeof(T)' "
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
            dyn()->diag->report(DiagID::S045E, kw_range.start,
                "expected type after 'alignof' "
            ).first(kw_range).emit();
            return AlignOfExpr::create_error(dyn()->ctx, kw_range);
        }

        if has_paren {
            if !dyn()->check(TokenKind::OpRParen) {
                dyn()->diag->report(DiagID::S045E, kw_range.start,
                    "expected ')' after type in 'alignof(T)' "
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
            dyn()->diag->report(DiagID::S045E, kw_range.start,
                "expected expression after 'typeof' "
            ).first(kw_range).emit();
            return TypeOfExpr::create_error(dyn()->ctx, kw_range);
        }

        if has_paren {
            if !dyn()->check(TokenKind::OpRParen) {
                dyn()->diag->report(DiagID::S045E, kw_range.start,
                    "expected ')' after expression in 'typeof(expr)' "
                ).first(kw_range).emit();
            } else {
                dyn()->advance();
            }
        }

        return TypeOfExpr::create(dyn()->ctx, kw_range | dyn()->prev().range, operand);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Postfix expression loop
    // ════════════════════════════════════════════════════════════════════════

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
        if base == &null { return &null; }

        // pending chain steps accumulator
        var chain_steps: std::StackBuf::<ChainExpr::Step, 8>;
        var chain_start = base->range;

        while !dyn()->is_eof() {
            // ── access operators: accumulate into chain steps ────────
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

            // ── call: ( ─────────────────────────────────────────────
            if dyn()->check(TokenKind::OpLParen) {
                // flush pending chain steps first
                base = self._flush_chain(base, &chain_steps, chain_start);
                base = self._parse_call_expr(base);
                chain_start = base->range;
                continue;
            }

            // ── subscript: [ ────────────────────────────────────────
            if dyn()->check(TokenKind::OpLSquare) {
                base = self._flush_chain(base, &chain_steps, chain_start);
                base = self._parse_subscript_expr(base);
                chain_start = base->range;
                continue;
            }

            // ── postfix ++ -- ───────────────────────────────────────
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

            // ── postfix ... (pack expansion) ────────────────────────
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

            // ── postfix as Type (type cast) ─────────────────────────
            if dyn()->check(TokenKind::KwAs) {
                base = self._flush_chain(base, &chain_steps, chain_start);
                base = self._parse_type_cast(base);
                chain_start = base->range;
                continue;
            }

            // ── nothing matched: end of postfix ─────────────────────
            break;
        }

        // flush any remaining chain steps
        base = self._flush_chain(base, &chain_steps, chain_start);
        return base;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Chain step parsing
    // ════════════════════════════════════════════════════════════════════════

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
            dyn()->diag->report(DiagID::S045E, sep_range.start,
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

        // ── generic args after :: separator only ────────────────────
        // foo::<T> is generic, foo.<T> is not valid syntax
        // also check hoisted scope for disambiguation of foo::Bar<T>
        if dyn()->check(TokenKind::OpLess) {
            if result.access_kind == ChainExpr::AccessKind::ColonColon {
                // :: disambiguator: check hoisted scope first
                var name_text = TokenText::from_token(*id_ptr, dyn()->ctx);
                if self._is_generic_name(name_text.text) {
                    var generic_args: std::StackBuf::<ChainType::GenericArg, 4>;
                    dyn()->_parse_generic_args(&generic_args);
                    result.generic_args.from_buf(
                        generic_args.data(), generic_args.size(), dyn()->ctx
                    );
                    result.range = sep_range | dyn()->prev().range;
                } else {
                    // not in hoisted scope tentative fallback
                    self._try_step_generic_args(&result, id_range, sep_range);
                }
            } else {
                // all other access kinds: always tentative
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
        var saved = dyn()->tentative_begin();

        var generic_args: std::StackBuf::<ChainType::GenericArg, 4>;
        var ok = dyn()->_parse_generic_args(&generic_args);

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
                return;
            }
        }

        dyn()->tentative_rollback(saved);
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

        return ce;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Call expression
    // ════════════════════════════════════════════════════════════════════════

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
        var end_range = dyn()->prev().range;
        if dyn()->check(TokenKind::OpRParen) {
            end_range = dyn()->current_ptr()->range;
            dyn()->advance(); // consume `)`
        } else {
            dyn()->diag->report(DiagID::S045E, lparen_range.start,
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
    priv fn _parse_call_args(self, out: *std::StackBuf::<*Expr, 8>, start_range: SourceRange) {
        while !dyn()->is_eof() {
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
            if dyn()->check(TokenKind::LitIdentifier)
            && dyn()->check_peek(TokenKind::OpColon)
            && !dyn()->check_peek(TokenKind::OpColonColon) {
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
                    dyn()->diag->report(DiagID::S045E, name_range.start,
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

                if (arg == &null) || isa_recovery::<Expr>(arg) {
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

            // no comma and not `)` missing separator
            if !dyn()->check(TokenKind::OpRParen) {
                // check bail before reporting
                if self._is_decl_keyword(dyn()->current().kind) { return; }

                dyn()->diag->report(DiagID::S045E, dyn()->current_ptr()->range.start,
                    "expected ',' or ')' after argument in function call"
                ).first(dyn()->current_ptr()->range).emit();

                self._sync_expr(ExprSyncCtx::Paren, 1, 0, 0, true);
            }
        }
    }

    /// \brief returns true if the token kind is a declaration/statement keyword
    ///        that should never appear inside a call argument list.
    ///        used to bail out of arg parsing when sync has overshot.
    priv fn _is_decl_keyword(self, k: TokenKind) -> bool {
        return k == TokenKind::KwFn
            || k == TokenKind::KwClass
            || k == TokenKind::KwStruct
            || k == TokenKind::KwEnum
            || k == TokenKind::KwInterface
            || k == TokenKind::KwModule
            || k == TokenKind::KwVar
            || k == TokenKind::KwConst
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

    // ════════════════════════════════════════════════════════════════════════
    //  Subscript expression
    // ════════════════════════════════════════════════════════════════════════

    /// \brief parses a subscript: base [ index ]
    ///
    /// precondition: current token is `[`
    inline fn _parse_subscript_expr(self, base: *Expr) -> *Expr {
        var lsquare_range = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `[`

        if dyn()->check(TokenKind::OpRSquare) {
            dyn()->diag->report(DiagID::S045E, lsquare_range.start,
                "expected index expression inside '[]' "
            ).first(lsquare_range).emit();
            var rsquare_range = dyn()->current_ptr()->range;
            dyn()->advance(); // consume `]`
            return SubscriptExpr::create_error(dyn()->ctx, base->range | rsquare_range);
        }

        var index = self.parse_expr(
            static_cast::<ExprStopKind>(static_cast::<u8>(ExprStopKind::StopSquare))
        );

        if index == &null {
            dyn()->diag->report(DiagID::S045E, lsquare_range.start,
                "expected index expression after '[' "
            ).first(lsquare_range).emit();
            self._sync_expr(ExprSyncCtx::Square, 0, 1);
            return SubscriptExpr::create_error(dyn()->ctx, base->range | dyn()->prev().range);
        }

        var end_range = dyn()->prev().range;
        if dyn()->check(TokenKind::OpRSquare) {
            end_range = dyn()->current_ptr()->range;
            dyn()->advance(); // consume `]`
        } else {
            dyn()->diag->report(DiagID::S045E, lsquare_range.start,
                "expected ']' after index expression"
            ).first(lsquare_range).emit();
            self._sync_expr(ExprSyncCtx::Square, 0, 1, 0, true);
            end_range = dyn()->prev().range;
        }

        return SubscriptExpr::create(dyn()->ctx, base->range | end_range, base, index);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Type cast
    // ════════════════════════════════════════════════════════════════════════

    /// \brief parses: expr as Type | expr as unsafe *Type
    ///
    /// precondition: current token is `as`
    inline fn _parse_type_cast(self, operand: *Expr) -> *Expr {
        var as_range = dyn()->current_ptr()->range;
        dyn()->advance(); // consume `as`

        var is_unsafe = false;
        if dyn()->check(TokenKind::KwUnsafe) {
            is_unsafe = true;
            dyn()->advance();
        }

        var target = dyn()->parse_type();
        if target == &null {
            dyn()->diag->report(DiagID::S045E, as_range.start,
                "expected type after 'as' in type cast expression"
            ).first(as_range).emit();
            return TypeCastExpr::create_error(dyn()->ctx, operand->range | as_range);
        }

        return TypeCastExpr::create(
            dyn()->ctx,
            operand->range | target->range,
            operand,
            target,
            is_unsafe
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Primary expression dispatch
    // ════════════════════════════════════════════════════════════════════════

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

        // ── integer literal ─────────────────────────────────────────
        if dyn()->check(TokenKind::LitInt) {
            var tok = dyn()->current();
            dyn()->advance();
            return IntegerLiteralExpr::create(dyn()->ctx, tok.range, tok);
        }

        // ── float literal ───────────────────────────────────────────
        if dyn()->check(TokenKind::LitFloat) {
            var tok = dyn()->current();
            dyn()->advance();
            return FloatingLiteralExpr::create(dyn()->ctx, tok.range, tok);
        }

        // ── string literal ──────────────────────────────────────────
        if dyn()->check(TokenKind::LitString) {
            var tok = dyn()->current();
            dyn()->advance();
            // TODO: distinguish plain/raw/format by checking token imm
            return StringLiteralExpr::create(
                dyn()->ctx, tok.range, tok,
                StringLiteralExpr::StringKind::Plain
            );
        }

        // ── char literal ────────────────────────────────────────────
        if dyn()->check(TokenKind::LitChar) {
            var tok = dyn()->current();
            dyn()->advance();
            return CharacterLiteralExpr::create(dyn()->ctx, tok.range, tok);
        }

        // ── bool literal: true ──────────────────────────────────────
        if dyn()->check(TokenKind::KwTrue) {
            var tok_range = cur_range;
            dyn()->advance();
            return BooleanLiteralExpr::create(dyn()->ctx, tok_range, true);
        }

        // ── bool literal: false ─────────────────────────────────────
        if dyn()->check(TokenKind::KwFalse) {
            var tok_range = cur_range;
            dyn()->advance();
            return BooleanLiteralExpr::create(dyn()->ctx, tok_range, false);
        }

        // ── null literal ────────────────────────────────────────────
        if dyn()->check(TokenKind::LitNull) {
            var tok_range = cur_range;
            dyn()->advance();
            return NullLiteralExpr::create(dyn()->ctx, tok_range, false);
        }

        // ── parenthesized expr or tuple literal ─────────────────────
        if dyn()->check(TokenKind::OpLParen) {
            return self._parse_paren_expr();
        }

        // ── square bracket: array literal ───────────────────────────
        if dyn()->check(TokenKind::OpLSquare) {
            return self._parse_list_literal();
        }

        // ── brace: set/map literal or anon initializer ──────────────
        if dyn()->check(TokenKind::OpLBrace) {
            return self._parse_brace_expr();
        }

        // ── closure: fn ─────────────────────────────────────────────
        if dyn()->check(TokenKind::KwFn) {
            // TODO: parse closure expression
            // for now, fall through to error
            0;
        }

        // ── code completion ─────────────────────────────────────────
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

        // ── identifier (including `self`) ───────────────────────────
        if dyn()->check(fn(k: TokenKind) -> bool {
            return EXPR_IDENT_TBL.contains(k);
        }) {
            return self._parse_ident_expr();
        }

        // ── global root path: ::foo ─────────────────────────────────
        if dyn()->check(TokenKind::OpColonColon) {
            return self._parse_global_root_expr();
        }

        // ── no production matched ───────────────────────────────────
        var resolved_kind = dyn()->resolve_kind_deep(cur_ptr);
        dyn()->diag->report(DiagID::S045E, cur_range.start,
            f"expected expression, found '{token_kind_to_readable_string(resolved_kind)}' "
        ).first(cur_range).emit();

        dyn()->advance(); // skip to prevent infinite loop
        return self._error_expr(cur_range);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Identifier expression (with optional generic args)
    // ════════════════════════════════════════════════════════════════════════

    /// \brief parses a bare identifier, optionally followed by generic args
    ///        if the hoisted scope indicates it's generic.
    ///
    /// foo       -> NamedIdentExpr("foo")
    /// Bar<i32>  -> NamedIdentExpr("Bar", generic_args=[i32])
    /// self      -> NamedIdentExpr("self")
    inline fn _parse_ident_expr(self) -> *Expr {
        var id_ptr   = dyn()->current_ptr();
        var id_range = id_ptr->range;
        var id_tok   = *id_ptr;
        dyn()->advance(); // consume identifier

        var nte = NamedIdentExpr::create(dyn()->ctx, id_range, id_tok);

        // check for generic args: Foo<T>
        // only if `<` follows AND hoisted scope says this name is generic
        if dyn()->check(TokenKind::OpLess) {
            var name_text = TokenText::from_token(id_tok, dyn()->ctx);
            if self._is_generic_name(name_text.text) {
                var generic_args: std::StackBuf::<ChainType::GenericArg, 4>;
                dyn()->_parse_generic_args(&generic_args);
                nte->generic_args.from_buf(
                    generic_args.data(), generic_args.size(), dyn()->ctx
                );
                nte->range = id_range | dyn()->prev().range;
            }

            else {
                // not in hoisted scope tentative parse
                var saved = dyn()->tentative_begin();

                var generic_args: std::StackBuf::<ChainType::GenericArg, 4>;
                var ok = dyn()->_parse_generic_args(&generic_args);

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
                    } else {
                        // not a valid continuation rollback, treat < as comparison
                        dyn()->tentative_rollback(saved);
                    }
                } else {
                    // generic arg parse failed rollback
                    dyn()->tentative_rollback(saved);
                }
            }
        }

        return nte;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Global root path: ::foo::bar
    // ════════════════════════════════════════════════════════════════════════

    inline fn _parse_global_root_expr(self) -> *Expr {
        var start_range = dyn()->current_ptr()->range;
        dyn()->advance(); // consume leading `::`

        // expect identifier after `::`
        if !dyn()->check(fn(k: TokenKind) -> bool {
            return EXPR_IDENT_TBL.contains(k);
        }) {
            dyn()->diag->report(DiagID::S045E, start_range.start,
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
            var name_text = TokenText::from_token(*id_ptr, dyn()->ctx);
            if self._is_generic_name(name_text.text) {
                var generic_args: std::StackBuf::<ChainType::GenericArg, 4>;
                dyn()->_parse_generic_args(&generic_args);
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

    // ════════════════════════════════════════════════════════════════════════
    //  Parenthesized expression / tuple literal
    // ════════════════════════════════════════════════════════════════════════

    /// \brief parses (expr) or (expr, expr, ...)
    ///        single expr -> unwrapped (no GroupingExpr since CST not needed)
    ///        comma-separated -> TupleLiteralExpr
    inline fn _parse_paren_expr(self) -> *Expr {
        var lparen_range = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `(`

        // empty parens: () error, not a valid expression
        if dyn()->check(TokenKind::OpRParen) {
            var rparen_range = dyn()->current_ptr()->range;
            dyn()->advance();
            dyn()->diag->report(DiagID::S045E, lparen_range.start,
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
            dyn()->diag->report(DiagID::S045E, lparen_range.start,
                "expected expression after '(' "
            ).first(lparen_range).emit();
            self._sync_expr(ExprSyncCtx::Paren, 1, 0, 0, true);
            return self._error_expr(lparen_range | dyn()->prev().range);
        }

        // tuple: (expr, ...)
        if dyn()->check(TokenKind::OpComma) {
            return self._finish_tuple_literal(lparen_range, first);
        }

        // single parenthesized expr: (expr) just unwrap
        if dyn()->check(TokenKind::OpRParen) {
            dyn()->advance(); // consume `)`
            return first;
        } else {
            // advance one more token
            dyn()->advance();
        }

        // missing `)`
        dyn()->diag->report(DiagID::S045E, first->range.start,
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

            if (elem == &null) || isa_recovery::<Expr>(elem) {
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
            dyn()->diag->report(DiagID::S045E, start_range.start,
                "expected ')' to close tuple literal"
            ).first(start_range).emit();
        }

        var full_range = start_range | end_range;
        var tuple = TupleLiteralExpr::create(dyn()->ctx, full_range);
        tuple->elements.from_buf(elements.data(), elements.size(), dyn()->ctx);
        return tuple;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Array literal: [expr, expr, ...]
    // ════════════════════════════════════════════════════════════════════════

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

            if (elem == &null) || isa_recovery::<Expr>(elem) {
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
            dyn()->diag->report(DiagID::S045E, lsquare_range.start,
                "expected ']' to close array literal"
            ).first(lsquare_range).emit();
        }

        var ll = ListLiteralExpr::create(dyn()->ctx, lsquare_range | end_range);
        ll->elements.from_buf(elements.data(), elements.size(), dyn()->ctx);
        return ll;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Brace expression: set/map literal or anon initializer
    // ════════════════════════════════════════════════════════════════════════

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
            dyn()->diag->report(DiagID::S045E, lbrace_range.start,
                "expected expression after '{' "
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

            if (elem == &null) || isa_recovery::<Expr>(elem) {
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
            dyn()->diag->report(DiagID::S045E, start_range.start,
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
            dyn()->diag->report(DiagID::S045E, start_range.start,
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
                dyn()->diag->report(DiagID::S045E, key->range.start,
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
            dyn()->diag->report(DiagID::S045E, start_range.start,
                "expected '}' to close map literal"
            ).first(start_range).emit();
        }

        var ml = MapLiteralExpr::create(dyn()->ctx, start_range | end_range);
        ml->entries.from_buf(entries.data(), entries.size(), dyn()->ctx);
        return ml;
    }

    inline fn _parse_anon_initializer(self, start_range: SourceRange) -> *Expr {
        // current token is `.` (first field)
        var fields: std::StackBuf::<AnonInitializerExpr::FieldInit, 8>;

        while !dyn()->is_eof() {
            if dyn()->check(TokenKind::OpRBrace) { break; }

            if !dyn()->check(TokenKind::OpDot) {
                dyn()->diag->report(DiagID::S045E, dyn()->current_ptr()->range.start,
                    "expected '.field: value' in anonymous initializer"
                ).first(dyn()->current_ptr()->range).emit();
                self._sync_expr(ExprSyncCtx::Comma, 0, 0, 1);
                if dyn()->check(TokenKind::OpComma) {
                    dyn()->advance(T::SkipNL::After);
                }
                continue;
            }

            dyn()->advance(); // consume `.`

            if !dyn()->check(TokenKind::LitIdentifier) {
                dyn()->diag->report(DiagID::S045E, dyn()->current_ptr()->range.start,
                    "expected field name after '.' in anonymous initializer"
                ).first(dyn()->current_ptr()->range).emit();
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
                dyn()->diag->report(DiagID::S045E, name_range.start,
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

            var fi = AnonInitializerExpr::FieldInit{};
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
            dyn()->diag->report(DiagID::S045E, start_range.start,
                "expected '}' to close anonymous initializer"
            ).first(start_range).emit();
        }

        var ai = AnonInitializerExpr::create(dyn()->ctx, start_range | end_range);
        ai->fields.from_buf(fields.data(), fields.size(), dyn()->ctx);
        return ai;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Generic disambiguation helper
    // ════════════════════════════════════════════════════════════════════════

    /// \brief checks if a name refers to a generic type/function in hoisted scope.
    ///        used to disambiguate `<` as generic args vs comparison operator.
    inline fn _is_generic_name(self, name: string) -> bool {
        var hr = dyn()->ctx->hoisted->lookup(name);
        if hr.found() {
            return hr.first()->is_generic();
        }
        return false;
    }
}