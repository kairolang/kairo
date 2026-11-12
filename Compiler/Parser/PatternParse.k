/// --- The Kairo Project ------------------------ Parser/PatternParse.k --- ///
///
///   The pattern parser mixin, for `match` cases and destructuring binds.
///
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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------------- ///

ffi "c++" import "Native/Types.hh"

import AST::Node::Base::{
    Expr,
    Pattern,
    Type,
}
import AST::Node::Casting::{
    cast,
    is_recovery,
    isa,
}
import AST::Node::Declarations::{
    StorageClass,
    VariableDecl,
} // VariableDecl for BindingPattern::decl
import AST::Node::Expressions::UnaryOperatorExpr // UnaryOperatorExpr for a negated literal
import AST::Node::Patterns::{
    BindingPattern,
    ConstructorPattern,
    LiteralPattern,
    RangePattern,
    SlicePattern,
    TupleDestructurePattern,
    UnresolvedConstructorPattern,
    WildcardPattern,
}
import AST::Node::PrimaryExpressions::{
    BooleanLiteralExpr, ChainExpr,      CharacterLiteralExpr, FloatingLiteralExpr,
    IntegerLiteralExpr, NamedIdentExpr, NullLiteralExpr,      StringLiteralExpr,
}
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Token::Token::Token
import Token::TokenKind::{
    TokenKind,
    token_kind_to_readable_string,
}

// TODO(DUCK-GENERIC): T uses _reject_mode_binding, advance, check, check_peek, ctx, current, current_ptr, diag, enter_depth, exit_depth, ig_kind, is_eof, ... (18). Stage 0 was duck-typed; bound it or keep `: type`.
pub class <T: type> PatternParse {
    priv inline fn dyn(self) -> unsafe *T {
        return unsafe ((&self) as *T)
    }

    priv inline fn _error_pattern(self, range: SourceRange) -> unsafe *Pattern {
        return WildcardPattern::create_error(self.dyn()->ctx, range)
    }

    //  Entry

    /// \brief parses a single pattern. Returns a recovery pattern (never null)
    ///        on failure so the surrounding match-arm structure keeps its shape.
    fn parse_pattern(self) -> unsafe *Pattern {
        if self.dyn()->is_eof() {
            return self._error_pattern(SourceRange::invalid())
        }

        if !self.dyn()->enter_depth() {
            return self._error_pattern(self.dyn()->current_ptr()->range)
        }

        var unsafe *p = self._parse_pattern_inner()

        self.dyn()->exit_depth()
        return p
    }

    priv fn _parse_pattern_inner(self) -> unsafe *Pattern {
        var cur_ptr = self.dyn()->current_ptr()
        if cur_ptr == &null {
            return self._error_pattern(SourceRange::invalid())
        }

        var start = cur_ptr->range

        var k = self.dyn()->resolve_kind_deep(cur_ptr)

        /// # wildcard `_` (identifier whose text is exactly "_")
        if k == TokenKind::LitIdentifier && self.dyn()->ctx->get_spelling(*cur_ptr) == "_" {
            self.dyn()->advance()
            return WildcardPattern::create(self.dyn()->ctx, start)
        }

        /// # binding `var x` / `const x` / `var x: T`
        if k == TokenKind::KwVar || k == TokenKind::KwConst {
            return self._parse_binding_pattern()
        }

        /// # tuple `(p, ...)` : always a tuple at pattern start
        if k == TokenKind::OpLParen {
            return self._parse_tuple_pattern()
        }

        /// # slice `[...]`
        if k == TokenKind::OpLSquare {
            return self._parse_slice_pattern()
        }

        /// # dotted constructor `.Variant` / `.Variant(...)`
        /// No lookup: the scrutinee type (a sema fact) selects the enum.
        if k == TokenKind::OpDot {
            return self._parse_dotted_pattern()
        }

        /// # leading range with no lower bound `..hi` / `..=hi`
        if k == TokenKind::OpRange || k == TokenKind::OpRangeEqual {
            return self._parse_open_lower_range(start)
        }

        /// # literal or path head: parse a primary lead, then disambiguate
        /// A `-` counts only directly before a numeric literal (`case -1`,
        /// `case -10..=-1`); before anything else it is still no pattern.
        if self._starts_literal(k) || self._starts_path_head(k) || self._starts_negated_literal(k) {
            return self._parse_primary_led_pattern(start)
        }

        /// # nothing matched
        self.dyn()->diag->report(
            DiagID::S061E,
            start.start,
            f"expected a pattern, found '{token_kind_to_readable_string(k)}'",
        ).first(start)->emit()
        // a closer or terminator ends something around the missing pattern
        // (`case` then the match's `}`) and is left for its owner, if its
        // opener is still open (closer_is_owned); the pattern lists break
        // on a failed element, so nothing retries it.
        var keep = k == TokenKind::OpSemicolon || k == TokenKind::TkNewLine || k == TokenKind::TkEof
        if k == TokenKind::OpRBrace || k == TokenKind::OpRParen || k == TokenKind::OpRSquare {
            keep = self.dyn()->operand_closer_is_owned()
        }

        if !keep {
            self.dyn()->advance() // forward progress
        }

        return self._error_pattern(start)
    }

    //  Predicates

    priv fn _starts_literal(self, k: TokenKind) -> bool {
        return k == TokenKind::LitInt
            || k == TokenKind::LitFloat
            || k == TokenKind::LitString
            || k == TokenKind::LitChar
            || k == TokenKind::KwTrue
            || k == TokenKind::KwFalse
            || k == TokenKind::LitNull
    }

    /// `-` immediately followed by an integer or float literal.
    priv fn _starts_negated_literal(self, k: TokenKind) -> bool {
        if k != TokenKind::OpMinus {
            return false
        }

        return self.dyn()->check_peek(TokenKind::LitInt)
            || self.dyn()->check_peek(TokenKind::LitFloat)
    }

    /// `-<literal>`: the prefix UnaryOperatorExpr ExprParse builds for `-1`,
    /// so PatternSpace's constant reading sees one shape whichever parser
    /// produced it.
    priv fn _is_negated_literal(self, e: unsafe *Expr) -> bool {
        if !isa<UnaryOperatorExpr>(e) {
            return false
        }

        var unsafe *u = cast<UnaryOperatorExpr>(e)
        if u->fix != UnaryOperatorExpr::Fix::Prefix {
            return false
        }

        if u->op_token.kind != TokenKind::OpMinus {
            return false
        }

        return isa<IntegerLiteralExpr>(u->operand) || isa<FloatingLiteralExpr>(u->operand)
    }

    /// path head: a bare identifier, a global-root `::`, or `self`. Builtins
    /// (u32 etc.) also flow through primary's identifier-table dispatch.
    priv fn _starts_path_head(self, k: TokenKind) -> bool {
        return k == TokenKind::LitIdentifier
            || k == TokenKind::OpColonColon
            || k == TokenKind::KwSelf
            || k == TokenKind::BiSelf
    }

    priv fn _is_literal_expr(self, e: unsafe *Expr) -> bool {
        return isa<IntegerLiteralExpr>(e)
            || isa<FloatingLiteralExpr>(e)
            || isa<StringLiteralExpr>(e)
            || isa<CharacterLiteralExpr>(e)
            || isa<BooleanLiteralExpr>(e)
            || isa<NullLiteralExpr>(e)
    }

    //  Binding   `var x` | `const x` | `var x: T`

    priv fn _parse_binding_pattern(self) -> unsafe *Pattern {
        var start    = self.dyn()->current_ptr()->range
        var is_const = self.dyn()->check(TokenKind::KwConst)
        self.dyn()->advance()              // consume var/const
        self.dyn()->_reject_mode_binding() // `case var @move n`: parameter-only.

        if !self.dyn()->check(TokenKind::LitIdentifier) {
            self.dyn()->diag->report(
                DiagID::S062E,
                start.start,
                "expected a binding name after 'var'/'const' in pattern",
            ).first(start)->emit()
            return (BindingPattern::create_error(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
            ))
        }

        var name = self.dyn()->current()
        self.dyn()->advance()

        var ty: unsafe *Type = &null
        if self.dyn()->check(TokenKind::OpColon) {
            self.dyn()->advance(T::SkipNL::After) // consume `:`
            var parsed = self.dyn()->parse_type()
            if parsed != &null && !is_recovery(parsed) {
                ty = parsed
            }
        }

        var bp = BindingPattern::create(
            self.dyn()->ctx,
            start | self.dyn()->prev().range,
            name,
            is_const,
            ty,
        )

        // A binder IS a declaration; give uses in the arm body something to
        // bind to (BindingPattern::decl). Patterns.k cannot construct this
        // itself without importing Declarations.k.
        var storage = if (is_const) => (StorageClass::Const) else => StorageClass::Var
        var vd = VariableDecl::create(self.dyn()->ctx, bp->range, name, storage)
        vd->type_ = ty
        bp->decl  = vd
        return bp
    }

    //  Tuple   `(p, p, ...)`

    priv fn _parse_tuple_pattern(self) -> unsafe *Pattern {
        var start = self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::After) // consume `(`

        if self.dyn()->check(TokenKind::OpRParen) {
            self.dyn()->diag->report(
                DiagID::S062E,
                start.start,
                "empty tuple pattern '()' is not allowed",
            ).first(start)->emit()
            self.dyn()->advance() // consume `)`
            return (TupleDestructurePattern::create_error(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
            ))
        }

        var elems: kairo::std::StackBuf<unsafe *Pattern, 8>

        while !self.dyn()->is_eof() {
            if self.dyn()->check(TokenKind::OpRParen) {
                break
            }

            var unsafe *elem = self.parse_pattern()
            if is_recovery(elem) {
                self._sync_pattern_in_parens()
                if self.dyn()->check(TokenKind::OpComma) {
                    self.dyn()->advance(T::SkipNL::After)
                    continue
                }

                break
            }

            elems.push_back(elem)

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
            self.dyn()->diag->report(
                DiagID::S062E,
                start.start,
                "expected ')' to close tuple pattern",
            ).first(start)->emit()
        }

        var node = TupleDestructurePattern::create(
            self.dyn()->ctx,
            start | self.dyn()->prev().range,
        )

        node->elements.from_buf(elems.data(), elems.size(), self.dyn()->ctx)
        return node
    }

    //  Slice   `[p, p, ..rest]` | `[p, .., p]` | `[.., p]` | `[p, p]`

    priv fn _parse_slice_pattern(self) -> unsafe *Pattern {
        var start = self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::After) // consume `[`

        var prefix:       kairo::std::StackBuf<unsafe *Pattern, 8>
        var suffix:       kairo::std::StackBuf<unsafe *Pattern, 8>
        var seen_rest                                              = false
        var rest_binding: unsafe *Pattern                          = &null

        while !self.dyn()->is_eof() && !self.dyn()->check(TokenKind::OpRSquare) {
            // rest element: `..` or `..name`
            if self.dyn()->check(TokenKind::OpRange) {
                if seen_rest {
                    self.dyn()->report_tok(
                        DiagID::S062E,
                        self.dyn()->current_ptr(),
                        "a slice pattern may contain at most one '..' rest element",
                    )

                    self._sync_pattern_in_square()
                    break
                }

                seen_rest = true
                var rest_start = self.dyn()->current_ptr()->range
                self.dyn()->advance() // consume `..`

                if self.dyn()->check(TokenKind::LitIdentifier) {
                    var nm = self.dyn()->current()
                    self.dyn()->advance()
                    rest_binding = (BindingPattern::create(
                        self.dyn()->ctx,
                        rest_start | nm.range,
                        nm,
                        false,
                        &null,
                    ))
                }

                if self.dyn()->check(TokenKind::OpComma) {
                    self.dyn()->advance(T::SkipNL::After)
                }

                continue
            }

            var unsafe *elem = self.parse_pattern()
            if is_recovery(elem) {
                self._sync_pattern_in_square()
                if self.dyn()->check(TokenKind::OpComma) {
                    self.dyn()->advance(T::SkipNL::After)
                    continue
                }

                break
            }

            if seen_rest {
                suffix.push_back(elem)
            } else {
                prefix.push_back(elem)
            }

            if self.dyn()->check(TokenKind::OpComma) {
                self.dyn()->advance(T::SkipNL::After)
                continue
            }

            break
        }

        if self.dyn()->check(TokenKind::OpRSquare) {
            self.dyn()->advance()
        } else {
            self.dyn()->diag->report(
                DiagID::S062E,
                start.start,
                "expected ']' to close slice pattern",
            ).first(start)->emit()
        }

        var node = SlicePattern::create(
            self.dyn()->ctx,
            start | self.dyn()->prev().range,
            seen_rest,
            rest_binding,
        )

        node->prefix.from_buf(prefix.data(), prefix.size(), self.dyn()->ctx)
        node->suffix.from_buf(suffix.data(), suffix.size(), self.dyn()->ctx)
        return node
    }

    //  Dotted constructor   `.Variant` / `.Variant(...)`

    priv fn _parse_dotted_pattern(self) -> unsafe *Pattern {
        var start = self.dyn()->current_ptr()->range
        self.dyn()->advance() // consume `.`

        if !self.dyn()->check(TokenKind::LitIdentifier) {
            self.dyn()->diag->report(
                DiagID::S062E,
                start.start,
                "expected a variant name after '.' in pattern",
            ).first(start)->emit()
            return (ConstructorPattern::create_error(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
            ))
        }

        var variant = self.dyn()->current()
        self.dyn()->advance()

        var has_parens                                          = false
        var subs:      kairo::std::StackBuf<unsafe *Pattern, 8>
        if self.dyn()->check(TokenKind::OpLParen) {
            has_parens = true
            self._parse_ctor_payload(&subs)
        }

        var node = ConstructorPattern::create(
            self.dyn()->ctx,
            start | self.dyn()->prev().range,
            &null,
            variant,
            true,
            has_parens,
        )

        node->subpatterns.from_buf(subs.data(), subs.size(), self.dyn()->ctx)
        return node
    }

    //  Primary-led: literal value, range, or path constructor

    /// pattern led by something primary can parse: a literal or a path
    /// (`foo`, `A::B`, `Foo<T>`). parse_pattern_lead stops before postfix `(`
    /// and before `..`, so we peek after to choose range vs constructor vs bare.
    priv fn _parse_primary_led_pattern(self, start: SourceRange) -> *Pattern {
        var unsafe *lead = self._parse_lead()
        if lead == &null || is_recovery(lead) {
            return self._error_pattern(start | self.dyn()->prev().range)
        }

        // range: `lead .. hi` / `lead ..= hi`  (lead is the lower bound)
        if self.dyn()->check(TokenKind::OpRange) || self.dyn()->check(TokenKind::OpRangeEqual) {
            var inclusive = self.dyn()->check(TokenKind::OpRangeEqual)
            self.dyn()->advance(T::SkipNL::After) // consume `..` / `..=`
            var unsafe *hi = self._parse_range_hi()
            return (RangePattern::create(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
                lead,
                hi,
                inclusive,
            ))
        }

        // constructor with payload: `lead ( ... )`
        if self.dyn()->check(TokenKind::OpLParen) {
            var subs: kairo::std::StackBuf<unsafe *Pattern, 8>
            self._parse_ctor_payload(&subs)
            return self._build_ctor(start, lead, true, subs)
        }

        // bare literal value
        if self._is_literal_expr(lead) || self._is_negated_literal(lead) {
            return (LiteralPattern::create(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
                lead,
            ))
        }

        // bare (nullary) path constructor / name
        var empty: kairo::std::StackBuf<unsafe *Pattern, 8>
        return self._build_ctor(start, lead, false, empty)
    }

    /// The lead, or `-` over a numeric literal as one prefix UnaryOperatorExpr
    /// spanning both tokens (a literal value or a range's lower bound).
    priv fn _parse_lead(self) -> unsafe *Expr {
        var k = self.dyn()->resolve_kind_deep(self.dyn()->current_ptr())
        if !self._starts_negated_literal(k) {
            return self.dyn()->parse_pattern_lead()
        }

        var op_tok = self.dyn()->current()
        self.dyn()->advance() // consume `-`
        var lit = self.dyn()->parse_pattern_lead()
        if lit == &null || is_recovery(lit) {
            return lit
        }

        return ((UnaryOperatorExpr::create(
            self.dyn()->ctx,
            op_tok.range | lit->range,
            lit,
            op_tok,
            UnaryOperatorExpr::Fix::Prefix,
        )))
    }

    /// `..hi` / `..=hi` with no lower bound at pattern start.
    priv fn _parse_open_lower_range(self, start: SourceRange) -> *Pattern {
        var inclusive = self.dyn()->check(TokenKind::OpRangeEqual)
        self.dyn()->advance(T::SkipNL::After) // consume `..` / `..=`
        var unsafe *hi = self._parse_range_hi()
        return (RangePattern::create(
            self.dyn()->ctx,
            start | self.dyn()->prev().range,
            &null,
            hi,
            inclusive,
        ))
    }

    /// the upper bound of a range: a full runtime expression. Stop at the case
    /// boundary so we don't eat the next alternation arm (`,`) or the arm body
    /// (`{` or `=>`). `where` and `=>` end the expr naturally (neither is an
    /// infix continuation). NoStructLiteral keeps `case 0..N { }` from reading
    /// `N { }` as a named initializer: the brace is the arm's block.
    priv fn _parse_range_hi(self) -> unsafe *Expr {
        if self.dyn()->is_eof() {
            return &null
        }

        // an open-upper range `lo..` is followed by the arm body `{` / `=>`, a
        // guard `where`, the next alternative `,`, or end. None can start the
        // upper bound.
        var k = self.dyn()->resolve_kind_deep(self.dyn()->current_ptr())
        if k == TokenKind::OpLBrace
            || k == TokenKind::OpFatArrow
            || k == TokenKind::OpComma
            || k == TokenKind::KwWhere
            || k == TokenKind::TkNewLine {
            return &null // genuinely open-ended `lo..`
        }

        var hi = self.dyn()->parse_expr(
            self.dyn()->stop_on(T::ExprStopKind::StopComma).plus(
                T::ExprStopKind::StopBrace,
            ).plus(T::ExprStopKind::NoStructLiteral),
        )

        if hi == &null || is_recovery(hi) {
            return &null
        }

        return hi
    }

    /// shared hit/miss split for constructor patterns (paren + bare path).
    priv fn _build_ctor(self,
                        start:      SourceRange,
                        head:       unsafe *Expr,
                        has_parens: bool,
                        const subs: kairo::std::StackBuf<unsafe *Pattern, 8>) -> *Pattern {
        if self._head_resolves(head) {
            var node = ConstructorPattern::create(
                self.dyn()->ctx,
                start | self.dyn()->prev().range,
                head,
                Token(),
                false,
                has_parens,
            )

            node->subpatterns.from_buf(
                subs.data(),
                subs.size(),
                self.dyn()->ctx,
            )

            return node
        }

        var miss = UnresolvedConstructorPattern::create(
            self.dyn()->ctx,
            start | self.dyn()->prev().range,
            head,
            has_parens,
        )

        miss->subpatterns.from_buf(subs.data(), subs.size(), self.dyn()->ctx)
        return miss
    }

    /// SHALLOW hoisted lookup on the leading path segment. Hit -> the head is a
    /// known declaration (ConstructorPattern); miss -> unknown root, sema runs
    /// one resolve-or-error path (UnresolvedConstructorPattern). Full path
    /// resolution (does B live in A, is C a real variant) is sema's job.
    priv fn _head_resolves(self, head: unsafe *Expr) -> bool {
        var lead: unsafe *NamedIdentExpr = &null

        if isa<NamedIdentExpr>(head) {
            lead = cast<NamedIdentExpr>(head)
        } else if isa<ChainExpr>(head) {
            var unsafe *ce = cast<ChainExpr>(head)
            if ce->base != &null {
                lead = ce->leading_name() // base as NamedIdentExpr, or null
            }

            if lead == &null && !ce->steps.is_empty() {
                lead = ce->steps.get(0)->name // global-root chain: first step
            }
        }

        if lead == &null {
            return false
        }

        // `Self` is not a table name; it is always a resolvable head (the
        // enclosing type), and sema owns the "outside a type body" error.
        if lead->name.kind == TokenKind::BiSelf {
            return true
        }

        // is_type(), NOT found(): the table also stores value entries (vars,
        // functions) as negative evidence for `<` disambiguation, and a
        // global value name must never flip a bare binding pattern into a
        // constructor head. Constructor heads are types/variants only.
        return self.dyn()->ctx->hoisted->lookup_tok(lead->name).is_type()
    }

    //  Constructor payload   `( p (, p)* ,? )`

    /// precondition: current is `(`. Consumes through the matching `)`.
    priv fn _parse_ctor_payload(self, @inout out: kairo::std::StackBuf<unsafe *Pattern, 8>) {
        var lparen = self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::After) // consume `(`

        if self.dyn()->check(TokenKind::OpRParen) {
            self.dyn()->advance() // empty payload `Foo()`
            return
        }

        while !self.dyn()->is_eof() {
            if self.dyn()->check(TokenKind::OpRParen) {
                break
            }

            var unsafe *p = self.parse_pattern()
            if is_recovery(p) {
                self._sync_pattern_in_parens()
                if self.dyn()->check(TokenKind::OpComma) {
                    self.dyn()->advance(T::SkipNL::After)
                    continue
                }

                break
            }

            out.push_back(p)

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
            self.dyn()->diag->report(
                DiagID::S062E,
                lparen.start,
                "expected ')' to close constructor pattern payload",
            ).first(lparen)->emit()
        }
    }

    //  Recovery

    priv fn _sync_pattern_in_parens(self) {
        var   depth: i32 = 0
        var   iters: u32 = 0
        const MAX:   u32 = 128
        while !self.dyn()->is_eof() && iters < MAX {
            ++iters
            var k = self.dyn()->ig_kind()
            if k == TokenKind::OpLParen || k == TokenKind::OpLSquare {
                ++depth
            } else if k == TokenKind::OpRParen {
                if depth == 0 {
                    return
                }

                --depth
            } else if k == TokenKind::OpRSquare {
                if depth > 0 {
                    --depth
                }
            } else if depth == 0 && k == TokenKind::OpComma {
                return
            }

            self.dyn()->advance()
        }
    }

    priv fn _sync_pattern_in_square(self) {
        var   depth: i32 = 0
        var   iters: u32 = 0
        const MAX:   u32 = 128
        while !self.dyn()->is_eof() && iters < MAX {
            ++iters
            var k = self.dyn()->ig_kind()
            if k == TokenKind::OpLSquare || k == TokenKind::OpLParen {
                ++depth
            } else if k == TokenKind::OpRSquare {
                if depth == 0 {
                    return
                }

                --depth
            } else if k == TokenKind::OpRParen {
                if depth > 0 {
                    --depth
                }
            } else if depth == 0 && k == TokenKind::OpComma {
                return
            }

            self.dyn()->advance()
        }
    }
}
