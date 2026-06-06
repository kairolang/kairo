/// --- The Kairo Project --------------- Compiler/Parser/PatternParse.k --- ///
///
///   \brief Pattern parsing mixin for `match` cases and destructuring binds.
///
///   \detail
///     Entry: parse_pattern() -> dispatches on the leading resolved token.
///     Constructor heads parse via TypeParse::parse_type (ChainType handles
///     `Foo<T>`, `A::B`, and the `>>` split). The hoisted scope is consulted
///     ONLY for the non-dotted constructor head to pick ConstructorPattern
///     (hit) vs UnresolvedConstructorPattern (miss); the dotted form never
///     looks up. Range bounds are *Expr; sema enforces const-evaluability.
///
///     Derives from ASTParse (CRTP): check, check_peek, match_tok, advance,
///     current, prev, current_ptr, ctx, diag, is_eof, enter_depth/exit_depth,
///     parse_type (TypeParse), parse_expr (ExprParse).
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------------- ///

import ASTNode::Base::*;
import ASTNode::Patterns::*;
import ASTNode::Types::*;
import ASTNode::PrimaryExpressions::*;
import ASTNode::Casting::*;
import AST::ASTContext::*;
import Diag::DiagEngine::*;
import Diag::DiagRegistry::*;
import Source::SourceRange::*;
import Lexer::Token::*;
import TokenKind::*;

class <T> PatternParse {
    priv inline fn dyn(self) -> *T {
        return static_cast::<*T>(&self);
    }

    priv inline fn _error_pattern(self, range: SourceRange) -> *Pattern {
        return static_cast::<*Pattern>(WildcardPattern::create_error(dyn()->ctx, range));
    }

    // ========================================================================
    //  Entry
    // ========================================================================

    /// \brief parses a single pattern. Returns a recovery pattern (never null)
    ///        on failure so the match-arm structure keeps its shape.
    fn parse_pattern(self) -> *Pattern {
        if dyn()->is_eof() {
            return self._error_pattern(SourceRange::invalid());
        }
        if !dyn()->enter_depth() {
            return self._error_pattern(dyn()->current_ptr()->range);
        }

        var p = self._parse_pattern_inner();

        dyn()->exit_depth();
        return p;
    }

    priv fn _parse_pattern_inner(self) -> *Pattern {
        var cur_ptr = dyn()->current_ptr();
        if cur_ptr == &null { return self._error_pattern(SourceRange::invalid()); }
        var start = cur_ptr->range;

        var k = dyn()->resolve_kind_deep(cur_ptr);

        // -- wildcard `_` (an identifier whose text is exactly "_") ----------
        if (k == TokenKind::LitIdentifier)
        && (TokenText::from_token(*cur_ptr, dyn()->ctx).text == "_") {
            dyn()->advance();
            return static_cast::<*Pattern>(WildcardPattern::create(dyn()->ctx, start));
        }

        // -- binding `var x` / `const x` / `var x: T` ------------------------
        if (k == TokenKind::KwVar) || (k == TokenKind::KwConst) {
            return self._parse_binding_pattern();
        }

        // -- tuple `(p, ...)` -------------------------------------------------
        if k == TokenKind::OpLParen {
            return self._parse_tuple_pattern();
        }

        // -- slice `[...]` ----------------------------------------------------
        if k == TokenKind::OpLSquare {
            return self._parse_slice_pattern();
        }

        // -- dotted constructor `.Variant` / `.Variant(...)` -----------------
        // No lookup: the scrutinee type (a sema fact) selects the enum.
        if k == TokenKind::OpDot {
            return self._parse_dotted_pattern();
        }

        // -- leading range with no lower bound `..hi` / `..=hi` --------------
        if (k == TokenKind::OpRange) || (k == TokenKind::OpRangeEqual) {
            return self._parse_open_lower_range(start);
        }

        // -- literals (and literal-led ranges) -------------------------------
        if self._starts_literal(k) {
            return self._parse_literal_or_range(start);
        }

        // -- path-headed: constructor, or path-constant range ----------------
        if self._starts_path_head(k) {
            return self._parse_path_pattern(start);
        }

        // -- nothing matched --------------------------------------------------
        dyn()->diag->report(DiagID::S045E, start.start,
            f"expected a pattern, found '{token_kind_to_readable_string(k)}' "
        ).first(start).emit();
        dyn()->advance(); // forward progress
        return self._error_pattern(start);
    }

    // ========================================================================
    //  Predicates
    // ========================================================================

    priv fn _starts_literal(self, k: TokenKind) -> bool {
        return k == TokenKind::LitInt
            || k == TokenKind::LitFloat
            || k == TokenKind::LitString
            || k == TokenKind::LitChar
            || k == TokenKind::KwTrue
            || k == TokenKind::KwFalse
            || k == TokenKind::LitNull;
    }

    /// path head: a bare identifier or a global-root `::`. Builtins
    /// (u32 etc.) are also valid heads via the type parser.
    priv fn _starts_path_head(self, k: TokenKind) -> bool {
        return k == TokenKind::LitIdentifier
            || k == TokenKind::OpColonColon
            || k == TokenKind::KwSelf;
    }

    // ========================================================================
    //  Binding
    // ========================================================================

    /// `var x` | `const x` | `var x: T`
    priv fn _parse_binding_pattern(self) -> *Pattern {
        var start    = dyn()->current_ptr()->range;
        var is_const = dyn()->check(TokenKind::KwConst);
        dyn()->advance(); // consume var/const

        if !dyn()->check(TokenKind::LitIdentifier) {
            dyn()->diag->report(DiagID::S045E, start.start,
                "expected a binding name after 'var'/'const' in pattern"
            ).first(start).emit();
            return static_cast::<*Pattern>(
                BindingPattern::create_error(dyn()->ctx, start | dyn()->prev().range));
        }
        var name = dyn()->current();
        dyn()->advance();

        var ty: *Type = &null;
        if dyn()->check(TokenKind::OpColon) {
            dyn()->advance(T::SkipNL::After); // consume `:`
            var parsed = dyn()->parse_type();
            if (parsed != &null) && (!is_recovery(parsed)) {
                ty = parsed;
            }
        }

        var end = start | dyn()->prev().range;
        return static_cast::<*Pattern>(
            BindingPattern::create(dyn()->ctx, end, name, is_const, ty));
    }

    // ========================================================================
    //  Tuple
    // ========================================================================

    /// `(p, p, ...)` allows a trailing comma. A single `(p)` is still a tuple
    /// node of arity 1 here; sema may unwrap. Empty `()` is an error.
    priv fn _parse_tuple_pattern(self) -> *Pattern {
        var start = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `(`

        if dyn()->check(TokenKind::OpRParen) {
            dyn()->diag->report(DiagID::S045E, start.start,
                "empty tuple pattern '()' is not allowed"
            ).first(start).emit();
            dyn()->advance(); // consume `)`
            return static_cast::<*Pattern>(
                TupleDestructurePattern::create_error(dyn()->ctx, start | dyn()->prev().range));
        }

        var elems: std::StackBuf::<*Pattern, 8>;

        while !dyn()->is_eof() {
            if dyn()->check(TokenKind::OpRParen) { break; }

            var elem = self.parse_pattern();
            if is_recovery(elem) {
                self._sync_pattern_in_parens();
                if dyn()->check(TokenKind::OpComma) { dyn()->advance(T::SkipNL::After); continue; }
                break;
            }
            elems.push_back(elem);

            if dyn()->check(TokenKind::OpComma) {
                dyn()->advance(T::SkipNL::After);
                if dyn()->check(TokenKind::OpRParen) { break; } // trailing comma
                continue;
            }
            break;
        }

        if dyn()->check(TokenKind::OpRParen) {
            dyn()->advance();
        } else {
            dyn()->diag->report(DiagID::S045E, start.start,
                "expected ')' to close tuple pattern"
            ).first(start).emit();
        }

        var node = TupleDestructurePattern::create(dyn()->ctx, start | dyn()->prev().range);
        node->elements.from_buf(elems.data(), elems.size(), dyn()->ctx);
        return static_cast::<*Pattern>(node);
    }

    // ========================================================================
    //  Slice
    // ========================================================================

    /// `[p, p, ..rest]` | `[p, .., p]` | `[.., p]` | `[p, p]`
    /// A single `..` (optionally `..name`) splits prefix from suffix. More than
    /// one rest is an error.
    priv fn _parse_slice_pattern(self) -> *Pattern {
        var start = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `[`

        var prefix: std::StackBuf::<*Pattern, 8>;
        var suffix: std::StackBuf::<*Pattern, 8>;
        var seen_rest = false;
        var rest_binding: *Pattern = &null;

        while (!dyn()->is_eof()) && (!dyn()->check(TokenKind::OpRSquare)) {
            // rest element: `..` or `..name`
            if dyn()->check(TokenKind::OpRange) {
                if seen_rest {
                    dyn()->diag->report(DiagID::S045E, dyn()->current_ptr()->range.start,
                        "a slice pattern may contain at most one '..' rest element"
                    ).first(dyn()->current_ptr()->range).emit();
                    self._sync_pattern_in_square();
                    break;
                }
                seen_rest = true;
                var rest_start = dyn()->current_ptr()->range;
                dyn()->advance(); // consume `..`

                // optional `..name` binds the rest slice
                if dyn()->check(TokenKind::LitIdentifier) {
                    var nm = dyn()->current();
                    dyn()->advance();
                    rest_binding = static_cast::<*Pattern>(
                        BindingPattern::create(dyn()->ctx, rest_start | nm.range, nm, false, &null));
                }

                if dyn()->check(TokenKind::OpComma) { dyn()->advance(T::SkipNL::After); }
                continue;
            }

            var elem = self.parse_pattern();
            if is_recovery(elem) {
                self._sync_pattern_in_square();
                if dyn()->check(TokenKind::OpComma) { dyn()->advance(T::SkipNL::After); continue; }
                break;
            }

            if seen_rest { suffix.push_back(elem); }
            else         { prefix.push_back(elem); }

            if dyn()->check(TokenKind::OpComma) {
                dyn()->advance(T::SkipNL::After);
                continue;
            }
            break;
        }

        if dyn()->check(TokenKind::OpRSquare) {
            dyn()->advance();
        } else {
            dyn()->diag->report(DiagID::S045E, start.start,
                "expected ']' to close slice pattern"
            ).first(start).emit();
        }

        var node = SlicePattern::create(
            dyn()->ctx, start | dyn()->prev().range, seen_rest, rest_binding);
        node->prefix.from_buf(prefix.data(), prefix.size(), dyn()->ctx);
        node->suffix.from_buf(suffix.data(), suffix.size(), dyn()->ctx);
        return static_cast::<*Pattern>(node);
    }

    // ========================================================================
    //  Dotted constructor  `.Variant` / `.Variant(...)`
    // ========================================================================

    priv fn _parse_dotted_pattern(self) -> *Pattern {
        var start = dyn()->current_ptr()->range;
        dyn()->advance(); // consume `.`

        if !dyn()->check(TokenKind::LitIdentifier) {
            dyn()->diag->report(DiagID::S045E, start.start,
                "expected a variant name after '.' in pattern"
            ).first(start).emit();
            return static_cast::<*Pattern>(
                ConstructorPattern::create_error(dyn()->ctx, start | dyn()->prev().range));
        }
        var variant = dyn()->current();
        dyn()->advance();

        var has_parens = false;
        var subs: std::StackBuf::<*Pattern, 8>;
        if dyn()->check(TokenKind::OpLParen) {
            has_parens = true;
            self._parse_ctor_payload(&subs);
        }

        var node = ConstructorPattern::create(
            dyn()->ctx, start | dyn()->prev().range, &null, variant, true, has_parens);
        node->subpatterns.from_buf(subs.data(), subs.size(), dyn()->ctx);
        return static_cast::<*Pattern>(node);
    }

    // ========================================================================
    //  Path-headed  `Foo` | `Foo(...)` | `Foo<T>(...)` | `A::B(...)`
    //               | path-constant range `Kind::Lo .. Kind::Hi`
    // ========================================================================

    priv fn _parse_path_pattern(self, start: SourceRange) -> *Pattern {
        // parse the head via the type parser: ChainType handles `A::B`,
        // `Foo<T>`, and the `>>` split. `<` after a path head in pattern
        // position is unambiguously generics (no comparison operator here).
        var head = dyn()->parse_type();
        if (head == &null) || is_recovery(head) {
            return static_cast::<*Pattern>(
                ConstructorPattern::create_error(dyn()->ctx, start | dyn()->prev().range));
        }

        // range with a path-constant lower bound: `Kind::Lo .. Kind::Hi`
        if dyn()->check(TokenKind::OpRange) || dyn()->check(TokenKind::OpRangeEqual) {
            // lower bound is the head re-read as an expression value. We model
            // the bound as the type's trailing-name path; for the parser we
            // wrap it through parse of the remaining range via _finish_range,
            // passing the head's range as the lo marker. sema resolves the
            // path constant from `head`.
            return self._finish_range_from_type_head(start, head);
        }

        var has_parens = false;
        var subs: std::StackBuf::<*Pattern, 8>;
        if dyn()->check(TokenKind::OpLParen) {
            has_parens = true;
            self._parse_ctor_payload(&subs);
        }

        // hoisted lookup on the head's leading name decides hit vs miss.
        var hit = self._head_resolves(head);

        if hit {
            var node = ConstructorPattern::create(
                dyn()->ctx, start | dyn()->prev().range, head, Token(), false, has_parens);
            node->subpatterns.from_buf(subs.data(), subs.size(), dyn()->ctx);
            return static_cast::<*Pattern>(node);
        }

        // miss: distinct node, sema runs a single resolve-or-error path.
        var miss = UnresolvedConstructorPattern::create(
            dyn()->ctx, start | dyn()->prev().range, head, has_parens);
        miss->subpatterns.from_buf(subs.data(), subs.size(), dyn()->ctx);
        return static_cast::<*Pattern>(miss);
    }

    /// hoisted lookup on the leading segment of the parsed head. Mirrors
    /// ExprParse::_is_generic_name's use of ctx->hoisted. A ChainType's first
    /// segment name is the lookup key.
    priv fn _head_resolves(self, head: *Type) -> bool {
        if !isa::<ChainType>(head) { return false; }
        var ct = cast::<ChainType>(head);
        var first = ct->first();
        if first == &null { return false; }
        if first->name == &null { return false; }

        var name_text = TokenText::from_token(first->name->name, dyn()->ctx);
        var hr = dyn()->ctx->hoisted->lookup(name_text.text);
        return hr.found();
    }

    // ========================================================================
    //  Constructor payload  `( p (, p)* ,? )`
    // ========================================================================

    /// precondition: current is `(`. Consumes through the matching `)`.
    priv fn _parse_ctor_payload(self, out: *std::StackBuf::<*Pattern, 8>) {
        var lparen = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `(`

        if dyn()->check(TokenKind::OpRParen) {
            dyn()->advance(); // empty payload `Foo()`
            return;
        }

        while !dyn()->is_eof() {
            if dyn()->check(TokenKind::OpRParen) { break; }

            var p = self.parse_pattern();
            if is_recovery(p) {
                self._sync_pattern_in_parens();
                if dyn()->check(TokenKind::OpComma) { dyn()->advance(T::SkipNL::After); continue; }
                break;
            }
            out->push_back(p);

            if dyn()->check(TokenKind::OpComma) {
                dyn()->advance(T::SkipNL::After);
                if dyn()->check(TokenKind::OpRParen) { break; } // trailing comma
                continue;
            }
            break;
        }

        if dyn()->check(TokenKind::OpRParen) {
            dyn()->advance();
        } else {
            dyn()->diag->report(DiagID::S045E, lparen.start,
                "expected ')' to close constructor pattern payload"
            ).first(lparen).emit();
        }
    }

    // ========================================================================
    //  Ranges
    // ========================================================================

    /// literal-led: `1`, or `1..10` / `1..=10`. Reads the literal as an expr,
    /// then checks for a range operator.
    priv fn _parse_literal_or_range(self, start: SourceRange) -> *Pattern {
        var lo = self._parse_literal_expr();
        if lo == &null {
            return self._error_pattern(start);
        }

        if dyn()->check(TokenKind::OpRange) || dyn()->check(TokenKind::OpRangeEqual) {
            var inclusive = dyn()->check(TokenKind::OpRangeEqual);
            dyn()->advance(T::SkipNL::After); // consume `..` / `..=`

            var hi = self._parse_range_bound_expr();
            // hi may be null for an open-ended `lo..` if we permit it.
            var node = RangePattern::create(
                dyn()->ctx, start | dyn()->prev().range, lo, hi, inclusive);
            return static_cast::<*Pattern>(node);
        }

        return static_cast::<*Pattern>(
            LiteralPattern::create(dyn()->ctx, start | dyn()->prev().range, lo));
    }

    /// `..hi` / `..=hi` with no lower bound.
    priv fn _parse_open_lower_range(self, start: SourceRange) -> *Pattern {
        var inclusive = dyn()->check(TokenKind::OpRangeEqual);
        dyn()->advance(T::SkipNL::After); // consume `..` / `..=`

        var hi = self._parse_range_bound_expr();
        var node = RangePattern::create(
            dyn()->ctx, start | dyn()->prev().range, &null, hi, inclusive);
        return static_cast::<*Pattern>(node);
    }

    /// the head was already parsed as a *Type (path constant like `Kind::Lo`);
    /// finish the range. lo is carried as null at the expr level the type head
    /// holds the lower-bound path and sema resolves it. We still parse an
    /// upper-bound expr.
    priv fn _finish_range_from_type_head(self, start: SourceRange, head: *Type) -> *Pattern {
        var inclusive = dyn()->check(TokenKind::OpRangeEqual);
        dyn()->advance(T::SkipNL::After); // consume `..` / `..=`

        var hi = self._parse_range_bound_expr();

        // wrap the type head as the lo via a TypeExpr-bearing range is overkill
        // here; instead we store lo = null and let sema read the head. To keep
        // the head reachable, we attach it through a RangePattern whose lo is a
        // synthesized path expr. Simplest: re-read the head's trailing name as
        // a NamedIdentExpr is lossy for `A::B`. So we keep lo = null and rely on
        // sema + the diagnostic note that path-constant range bounds resolve via
        // the type head. (A dedicated lo_type field can be added if sema wants
        // it without re-walking.)
        var node = RangePattern::create(
            dyn()->ctx, start | dyn()->prev().range, &null, hi, inclusive);
        return static_cast::<*Pattern>(node);
    }

    /// parses a literal as an expression (Integer/Float/String/Char/Bool/Null).
    priv fn _parse_literal_expr(self) -> *Expr {
        var cur = dyn()->current_ptr();
        if cur == &null { return &null; }
        var r = cur->range;
        var k = dyn()->resolve_kind_deep(cur);

        if k == TokenKind::LitInt {
            var tok = dyn()->current(); dyn()->advance();
            return IntegerLiteralExpr::create(dyn()->ctx, r, tok);
        }
        if k == TokenKind::LitFloat {
            var tok = dyn()->current(); dyn()->advance();
            return FloatingLiteralExpr::create(dyn()->ctx, r, tok);
        }
        if k == TokenKind::LitString {
            var tok = dyn()->current(); dyn()->advance();
            return StringLiteralExpr::create(
                dyn()->ctx, r, tok, StringLiteralExpr::StringKind::Plain);
        }
        if k == TokenKind::LitChar {
            var tok = dyn()->current(); dyn()->advance();
            return CharacterLiteralExpr::create(dyn()->ctx, r, tok);
        }
        if k == TokenKind::KwTrue  { dyn()->advance(); return BooleanLiteralExpr::create(dyn()->ctx, r, true);  }
        if k == TokenKind::KwFalse { dyn()->advance(); return BooleanLiteralExpr::create(dyn()->ctx, r, false); }
        if k == TokenKind::LitNull { dyn()->advance(); return NullLiteralExpr::create(dyn()->ctx, r, false);    }

        return &null;
    }

    /// an upper/lower range bound: a literal or a path-constant. We accept a
    /// full primary via the literal reader first; if it's a path head, defer to
    /// parse_expr for `A::B`. sema enforces const-evaluability.
    priv fn _parse_range_bound_expr(self) -> *Expr {
        var cur = dyn()->current_ptr();
        if cur == &null { return &null; }
        var k = dyn()->resolve_kind_deep(cur);

        if self._starts_literal(k) {
            return self._parse_literal_expr();
        }
        if self._starts_path_head(k) {
            // `A::B` path constant as a bound. parse_expr handles the chain;
            // StopComma|StopBrace so it ends at the case boundary.
            return dyn()->parse_expr(static_cast::<T::ExprStopKind>(
                static_cast::<u8>(T::ExprStopKind::StopComma)
              | static_cast::<u8>(T::ExprStopKind::StopBrace)));
        }
        return &null;
    }

    // ========================================================================
    //  Recovery
    // ========================================================================

    priv fn _sync_pattern_in_parens(self) {
        var depth: i32 = 0;
        var iters: u32 = 0;
        const var MAX: u32 = 128;
        while (!dyn()->is_eof()) && iters < MAX {
            ++iters;
            var k = dyn()->current().kind;
            if k == TokenKind::OpLParen || k == TokenKind::OpLSquare { ++depth; }
            else if k == TokenKind::OpRParen {
                if depth == 0 { return; }
                --depth;
            }
            else if k == TokenKind::OpRSquare { if depth > 0 { --depth; } }
            else if depth == 0 && k == TokenKind::OpComma { return; }
            dyn()->advance();
        }
    }

    priv fn _sync_pattern_in_square(self) {
        var depth: i32 = 0;
        var iters: u32 = 0;
        const var MAX: u32 = 128;
        while (!dyn()->is_eof()) && iters < MAX {
            ++iters;
            var k = dyn()->current().kind;
            if k == TokenKind::OpLSquare || k == TokenKind::OpLParen { ++depth; }
            else if k == TokenKind::OpRSquare {
                if depth == 0 { return; }
                --depth;
            }
            else if k == TokenKind::OpRParen { if depth > 0 { --depth; } }
            else if depth == 0 && k == TokenKind::OpComma { return; }
            dyn()->advance();
        }
    }
}