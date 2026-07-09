/// --- The Kairo Project ------------------------ Parser/PatternParse.k --- ///
///
///   \brief Pattern parsing mixin for `match` cases and destructuring binds.
///
///   \detail
///     Entry: parse_pattern() -> dispatches on the leading resolved token.
///
///     Pattern-only forms are ruled out first (`_`, `var`/`const`, `(`, `[`,
///     leading `.`, leading `..`). What remains -- a literal or a path head --
///     is parsed via ExprParse::parse_pattern_lead (a single primary expr that
///     stops before postfix `(`, `..`, `.`), then disambiguated by lookahead:
///       lead `..` hi      -> RangePattern  (lead is the lower bound)
///       lead `(` payload  -> ConstructorPattern / UnresolvedConstructorPattern
///       bare literal      -> LiteralPattern
///       bare path         -> nullary ConstructorPattern / Unresolved...
///
///     Constructor hit/miss is decided by a SHALLOW hoisted lookup on the
///     leading path segment only (full resolution is sema's job). A hit tags
///     ConstructorPattern; a miss tags UnresolvedConstructorPattern so sema
///     walks one resolve-or-error path instead of re-deriving the split.
///
///     The dotted form (`.Variant` / `.Variant(...)`) never looks up: the
///     scrutinee type (a sema fact) selects the enum. `(` at pattern start is
///     ALWAYS a tuple pattern; parenthesized range lower bounds are not
///     supported. Range bounds are full expressions (the upper via parse_expr,
///     the lower via the primary-led lead); sema enforces const-evaluability.
///
///     Derives from ASTParse (CRTP): check, check_peek, advance, current, prev,
///     current_ptr, ctx, diag, is_eof, enter_depth/exit_depth,
///     resolve_kind_deep, parse_type (TypeParse), parse_expr /
///     parse_pattern_lead (ExprParse).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the Kairo
///   Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------------- ///

import AST::Node::Base::*;
import AST::Node::Patterns::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Casting::*;
import AST::Context::ASTContext::*;
import Diagnostic::Engine::*;
import Diagnostic::Registry::*;
import Location::SourceRange::*;
import Token::Token::*;
import Token::TokenKind::*;

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
    ///        on failure so the surrounding match-arm structure keeps its shape.
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

        // -- wildcard `_` (identifier whose text is exactly "_") -------------
        if (k == TokenKind::LitIdentifier)
        && (dyn()->ctx->get_spelling(*cur_ptr) == "_") {
            dyn()->advance();
            return static_cast::<*Pattern>(WildcardPattern::create(dyn()->ctx, start));
        }

        // -- binding `var x` / `const x` / `var x: T` ------------------------
        if (k == TokenKind::KwVar) || (k == TokenKind::KwConst) {
            return self._parse_binding_pattern();
        }

        // -- tuple `(p, ...)` : always a tuple at pattern start --------------
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

        // -- literal or path head: parse a primary lead, then disambiguate ---
        if self._starts_literal(k) || self._starts_path_head(k) {
            return self._parse_primary_led_pattern(start);
        }

        // -- nothing matched --------------------------------------------------
        dyn()->diag->report(DiagID::S061E, start.start,
            f"expected a pattern, found '{token_kind_to_readable_string(k)}\x27"
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

    /// path head: a bare identifier, a global-root `::`, or `self`. Builtins
    /// (u32 etc.) also flow through primary's identifier-table dispatch.
    priv fn _starts_path_head(self, k: TokenKind) -> bool {
        return k == TokenKind::LitIdentifier
            || k == TokenKind::OpColonColon
            || k == TokenKind::KwSelf;
    }

    priv fn _is_literal_expr(self, e: *Expr) -> bool {
        return isa::<IntegerLiteralExpr>(e)
            || isa::<FloatingLiteralExpr>(e)
            || isa::<StringLiteralExpr>(e)
            || isa::<CharacterLiteralExpr>(e)
            || isa::<BooleanLiteralExpr>(e)
            || isa::<NullLiteralExpr>(e);
    }

    // ========================================================================
    //  Binding   `var x` | `const x` | `var x: T`
    // ========================================================================

    priv fn _parse_binding_pattern(self) -> *Pattern {
        var start    = dyn()->current_ptr()->range;
        var is_const = dyn()->check(TokenKind::KwConst);
        dyn()->advance(); // consume var/const

        if !dyn()->check(TokenKind::LitIdentifier) {
            dyn()->diag->report(DiagID::S062E, start.start,
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

        return static_cast::<*Pattern>(
            BindingPattern::create(dyn()->ctx, start | dyn()->prev().range, name, is_const, ty));
    }

    // ========================================================================
    //  Tuple   `(p, p, ...)`
    // ========================================================================

    priv fn _parse_tuple_pattern(self) -> *Pattern {
        var start = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `(`

        if dyn()->check(TokenKind::OpRParen) {
            dyn()->diag->report(DiagID::S062E, start.start,
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
            dyn()->diag->report(DiagID::S062E, start.start,
                "expected ')' to close tuple pattern"
            ).first(start).emit();
        }

        var node = TupleDestructurePattern::create(dyn()->ctx, start | dyn()->prev().range);
        node->elements.from_buf(elems.data(), elems.size(), dyn()->ctx);
        return static_cast::<*Pattern>(node);
    }

    // ========================================================================
    //  Slice   `[p, p, ..rest]` | `[p, .., p]` | `[.., p]` | `[p, p]`
    // ========================================================================

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
                    dyn()->diag->report(DiagID::S062E, dyn()->current_ptr()->range.start,
                        "a slice pattern may contain at most one '..' rest element"
                    ).first(dyn()->current_ptr()->range).emit();
                    self._sync_pattern_in_square();
                    break;
                }
                seen_rest = true;
                var rest_start = dyn()->current_ptr()->range;
                dyn()->advance(); // consume `..`

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
            dyn()->diag->report(DiagID::S062E, start.start,
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
    //  Dotted constructor   `.Variant` / `.Variant(...)`
    // ========================================================================

    priv fn _parse_dotted_pattern(self) -> *Pattern {
        var start = dyn()->current_ptr()->range;
        dyn()->advance(); // consume `.`

        if !dyn()->check(TokenKind::LitIdentifier) {
            dyn()->diag->report(DiagID::S062E, start.start,
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
    //  Primary-led: literal value, range, or path constructor
    // ========================================================================

    /// pattern led by something primary can parse: a literal or a path
    /// (`foo`, `A::B`, `Foo<T>`). parse_pattern_lead stops before postfix `(`
    /// and before `..`, so we peek after to choose range vs constructor vs bare.
    priv fn _parse_primary_led_pattern(self, start: SourceRange) -> *Pattern {
        var lead = dyn()->parse_pattern_lead();
        if (lead == &null) || is_recovery(lead) {
            return self._error_pattern(start | dyn()->prev().range);
        }

        // range: `lead .. hi` / `lead ..= hi`  (lead is the lower bound)
        if dyn()->check(TokenKind::OpRange) || dyn()->check(TokenKind::OpRangeEqual) {
            var inclusive = dyn()->check(TokenKind::OpRangeEqual);
            dyn()->advance(T::SkipNL::After); // consume `..` / `..=`
            var hi = self._parse_range_hi();
            return static_cast::<*Pattern>(
                RangePattern::create(dyn()->ctx, start | dyn()->prev().range, lead, hi, inclusive));
        }

        // constructor with payload: `lead ( ... )`
        if dyn()->check(TokenKind::OpLParen) {
            var subs: std::StackBuf::<*Pattern, 8>;
            self._parse_ctor_payload(&subs);
            return self._build_ctor(start, lead, true, &subs);
        }

        // bare literal value
        if self._is_literal_expr(lead) {
            return static_cast::<*Pattern>(
                LiteralPattern::create(dyn()->ctx, start | dyn()->prev().range, lead));
        }

        // bare (nullary) path constructor / name
        var empty: std::StackBuf::<*Pattern, 8>;
        return self._build_ctor(start, lead, false, &empty);
    }

    /// `..hi` / `..=hi` with no lower bound at pattern start.
    priv fn _parse_open_lower_range(self, start: SourceRange) -> *Pattern {
        var inclusive = dyn()->check(TokenKind::OpRangeEqual);
        dyn()->advance(T::SkipNL::After); // consume `..` / `..=`
        var hi = self._parse_range_hi();
        return static_cast::<*Pattern>(
            RangePattern::create(dyn()->ctx, start | dyn()->prev().range, &null, hi, inclusive));
    }

    /// the upper bound of a range: a full runtime expression. Stop at the case
    /// boundary so we don't eat the next alternation arm (`,`) or the case body
    /// (`{`). `where` ends the expr naturally (not an infix continuation).
    priv fn _parse_range_hi(self) -> *Expr {
        if dyn()->is_eof() { return &null; }
        // an open-upper range `lo..` is followed by the case body `{`, a guard
        // `where`, the next arm `,`, or end. None can start the upper bound.
        var k = dyn()->resolve_kind_deep(dyn()->current_ptr());
        if k == TokenKind::OpLBrace
        || k == TokenKind::OpComma
        || k == TokenKind::KwWhere
        || k == TokenKind::TkNewLine {
            return &null;   // genuinely open-ended `lo..`
        }
        var hi = dyn()->parse_expr(static_cast::<T::ExprStopKind>(
            static_cast::<u8>(T::ExprStopKind::StopComma)
          | static_cast::<u8>(T::ExprStopKind::StopBrace)));
        if (hi == &null) || is_recovery(hi) { return &null; }
        return hi;
    }

    /// shared hit/miss split for constructor patterns (paren + bare path).
    priv fn _build_ctor(
        self,
        start:      SourceRange,
        head:       *Expr,
        has_parens: bool,
        subs:       *std::StackBuf::<*Pattern, 8>
    ) -> *Pattern {
        if self._head_resolves(head) {
            var node = ConstructorPattern::create(
                dyn()->ctx, start | dyn()->prev().range, head, Token(), false, has_parens);
            node->subpatterns.from_buf(subs->data(), subs->size(), dyn()->ctx);
            return static_cast::<*Pattern>(node);
        }
        var miss = UnresolvedConstructorPattern::create(
            dyn()->ctx, start | dyn()->prev().range, head, has_parens);
        miss->subpatterns.from_buf(subs->data(), subs->size(), dyn()->ctx);
        return static_cast::<*Pattern>(miss);
    }

    /// SHALLOW hoisted lookup on the leading path segment. Hit -> the head is a
    /// known declaration (ConstructorPattern); miss -> unknown root, sema runs
    /// one resolve-or-error path (UnresolvedConstructorPattern). Full path
    /// resolution (does B live in A, is C a real variant) is sema's job.
    priv fn _head_resolves(self, head: *Expr) -> bool {
        var lead: *NamedIdentExpr = &null;

        if isa::<NamedIdentExpr>(head) {
            lead = cast::<NamedIdentExpr>(head);
        } else if isa::<ChainExpr>(head) {
            var ce = cast::<ChainExpr>(head);
            if ce->base != &null {
                lead = ce->leading_name();          // base as NamedIdentExpr, or null
            }
            if (lead == &null) && (!ce->steps.is_empty()) {
                lead = ce->steps.get(0)->name;      // global-root chain: first step
            }
        }

        if lead == &null { return false; }

        return dyn()->ctx->hoisted->lookup_tok(lead->name).found();
    }

    // ========================================================================
    //  Constructor payload   `( p (, p)* ,? )`
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
            dyn()->diag->report(DiagID::S062E, lparen.start,
                "expected ')' to close constructor pattern payload"
            ).first(lparen).emit();
        }
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