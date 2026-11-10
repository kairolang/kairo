/// --- The Kairo Project ---------- Sema/Expand/PrimitiveLimitDesugar.k --- ///
///
///   \brief `i32::MAX`, `f64::EPSILON`, `f32::INFINITY`, `u8::BITS`: each
///          primitive's associated constants, replaced by the literal they
///          are before anything resolves a name.
///
///   \detail
///     Nothing about a primitive's limits waits on resolution. A primitive
///     keyword is no name -- it is in no table and cannot be shadowed
///     (CanonicalNodes.k, BuiltinKind) -- and every value follows from the
///     builtin table and the target (AST/PrimitiveLimits.k). So this runs
///     first in E, and every later pass sees a literal: `eval if` folding,
///     array lengths, ConstEval, purity, the C++ printer. Nothing downstream
///     knows limits exist.
///
///     What is minted:
///       an integer-valued limit   an IntegerLiteralExpr PINNED to its type
///                                 (as a suffix would pin it: `u64::MAX` is
///                                 a u64 in any context), wrapped `(-L)`
///                                 for a negative one, so `i64::MIN` is the
///                                 -literal shape C++ spells exactly;
///       a float-valued limit      a FloatingLiteralExpr pinned to its type
///                                 and tagged with the limit, which EmitIR
///                                 spells (an exact hex float, or clang's
///                                 `__builtin_inf*` / `__builtin_nan*`).
///
///     What is refused, here, at the spelling: a limit the type does not
///     have (`f8e4m3::INFINITY`: the FN format has none; `bool::MAX`), f80
///     where the target has no x87 long double (the same P003E as spelling
///     it as a type), and an integer limit wider than 128 bits, which C++
///     output cannot write yet. A name that is no limit at all (`i32::FOO`)
///     is left alone for ChainBinding's "no member" error, as before.
///
///     A limit at the head of a longer chain (`f64::NAN.is_nan()`) is the
///     chain's base once minted, parenthesized, with the steps after it
///     applying to it (P754).
///
///     A generic argument `Buf<u8::BITS>` parses as a type; it becomes the
///     TypeExpr a value argument is (`Buf<8>`), over the minted literal.
///
///     `T::MAX` on a generic parameter is not this pass's: T is no keyword.
///
///   Phase: EXPAND (before EvalIfFolding)
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::ASTSupport::FrozenList
import AST::Node::Base::Expr
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    builtin_for_token,
    builtin_info,
}
import AST::Node::Casting::{
    cast,
    isa,
}
import AST::Node::Expressions::{
    ParenExpr,
    UnaryOperatorExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    FloatingLiteralExpr,
    IntegerLiteralExpr,
    NamedIdentExpr,
}
import AST::Node::Types::{
    ChainType,
    TypeExpr,
}
import AST::PrimitiveLimits::{
    PrimLimit,
    PrimLimitInt,
    PrimitiveLimits,
}
import AST::Visitor::ASTWriter::ASTWriter
import Diagnostic::Registry::DiagID
import Lexer::Immediate::Immediate
import Location::SourceRange::SourceRange
import Sema::SemaContext::SemaContext
import Token::Token::Token
import Token::TokenKind::{
    TokenKind,
    is_annotation,
}

pub class PrimitiveLimitDesugar derives ASTWriter<PrimitiveLimitDesugar> {
    pub var sc:       *SemaContext
    pub var n_minted: usize        = 0

    fn PrimitiveLimitDesugar(self, sc: *SemaContext) {
        self.sc       = sc
        self.ctx      = sc->ctx // ASTWriter rebuilds lists in this arena.
        self.n_minted = 0
    }

    fn run(self) {
        if self.sc->tu == &null || !self.sc->tu->has_prim_member {
            return
        }

        ASTWriter<PrimitiveLimitDesugar>::run(self, self.sc->tu)
    }

    fn transform_chain_expr(self, n: unsafe *ChainExpr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<PrimitiveLimitDesugar>::transform_chain_expr(self, n)
        if n->base == &null || !isa<NamedIdentExpr>(n->base) || n->steps.size() == 0 {
            return out
        }

        // `f64::NAN.is_nan()`, `i32::MAX.sq()`: the limit is the head of a
        // longer chain, so only the first step is the limit and the rest
        // apply to the literal (P754). A second `::` step (`f64::MAX::x`)
        // is no member access of a value; it stays for ChainBinding's error.
        if n->steps.size() > 1 {
            var unsafe *nx = n->steps.get(1)
            if nx == &null || nx->access_kind == ChainExpr::AccessKind::ColonColon {
                return out
            }
        }

        var unsafe *id = cast<NamedIdentExpr>(n->base)
        if !is_annotation(id->name.kind) || !id->generic_args.is_empty() {
            return out
        }

        var unsafe *st = n->steps.get(0)
        if st == &null || st->name == &null || st->target != ChainExpr::StepTarget::Name {
            return out
        }

        if st->access_kind != ChainExpr::AccessKind::ColonColon || !st->generic_args.is_empty() {
            return out
        }

        var b = builtin_for_token(id->name.kind)
        if b == BuiltinKind::COUNT {
            return out
        }

        var k = PrimitiveLimits::of_name(self.sc->ctx->get_spelling(st->name->name))
        if k == PrimLimit::None { // ChainBinding: "no member".
            return out
        }

        if n->steps.size() == 1 {
            var unsafe *e = self._mint(n->range, b, k)
            if e == &null {
                id->poison()
                n->poison()
                return n
            }

            return e
        }

        // The literal becomes the chain's base and the limit step drops out,
        // the shape `(f64::NAN).is_nan()` already has. Parenthesized, as a
        // negative integer limit already is, so the steps after it apply to
        // the whole literal. The steps stay in their arena array: the view
        // just starts one later.
        var        lr   = SourceRange(n->range.start, st->range.end)
        var unsafe *lim = self._mint(lr, b, k)
        if lim == &null {
            id->poison()
            n->poison()
            return n
        }

        if !isa<ParenExpr>(lim) {
            lim = unsafe (ParenExpr::create(self.sc->ctx, lr, lim) as unsafe *Expr)
        }

        var rest = FrozenList<ChainExpr::Step>::empty()
        rest.from_raw(n->steps.get(1), n->steps.size() - 1)
        n->base  = lim
        n->steps = rest
        return n
    }

    /// `Buf<u8::BITS>`: in an argument list a primitive's `::` path parses
    /// as a TYPE (`Vec<i32>` and `Buf<u8::BITS>` are one shape to the
    /// parser), and TypeResolution would call it a member of a primitive.
    /// A value argument is a TypeExpr over its expression, as `Buf<8>` is.
    fn transform_generic_arg(self, a: *ChainType::GenericArg) {
        ASTWriter<PrimitiveLimitDesugar>::transform_generic_arg(self, a)
        if a->ty == &null || !isa<ChainType>(a->ty) {
            return
        }

        var unsafe *ct = cast<ChainType>(a->ty)
        if ct->segments.size() != 2 {
            return
        }

        var unsafe *s0 = ct->segments.get(0)
        var unsafe *s1 = ct->segments.get(1)
        if s0 == &null || s1 == &null || s0->name == &null || s1->name == &null {
            return
        }

        if !s0->generic_args.is_empty() || !s1->generic_args.is_empty() {
            return
        }

        var b = builtin_for_token(s0->name->name.kind)
        if b == BuiltinKind::COUNT {
            return
        }

        var k = PrimitiveLimits::of_name(self.sc->ctx->get_spelling(s1->name->name))
        if k == PrimLimit::None {
            return
        }

        var unsafe *e = self._mint(ct->range, b, k)
        if e == &null {
            ct->poison()
            return
        }

        a->ty = TypeExpr::create(self.sc->ctx, ct->range, e)
    }

    /// \p b's \p k as the literal it is, or null after the error saying why
    /// it has none.
    priv fn _mint(self, range: SourceRange, b: BuiltinKind, k: PrimLimit) -> unsafe *Expr {
        var sp   = builtin_info(b)->spelling
        var name = PrimitiveLimits::name_of(k)
        if !PrimitiveLimits::exists(b, k) {
            var why = self._why_missing(b, k)
            var d   = self.sc->diag->report(DiagID::R024E, range.start, f"'{sp}' has no '{name}'")
            d.first(range)
            if why != "" {
                d.note(range.start, why)
            }

            d.emit()
            return &null
        }

        if b == BuiltinKind::F80 && !self._has_f80() {
            var *t = &self.sc->ctx->ci->target
            self.sc->diag->report(
                DiagID::P003E,
                range.start,
                f"'f80' is unavailable on '{t->describe()}': its 'long double' is {t->long_double_fmt_name}, not x87",
            ).first(range)->note(range.start, "see --explain P003E")->emit()
            return &null
        }

        var rk = PrimitiveLimits::result_kind(b, k)
        if PrimitiveLimits::is_float_valued(b, k) {
            return self._float(range, b, k)
        }

        var        width          = builtin_info(b)->bits
        var        storage: usize = 0
        var unsafe *bt            = self.sc->builtin(b)
        if bt != &null {
            storage = bt->size_bits
            if b == BuiltinKind::USize || b == BuiltinKind::ISize {
                width = bt->size_bits
            }
        }

        if k != PrimLimit::Bits && builtin_info(b)->is_integer() && width > 128 {
            self.sc->diag->report(
                DiagID::SC232E,
                range.start,
                f"'{sp}::{name}' is not supported yet: integer constants wider than 128 bits are not emitted",
            ).first(range)->emit()
            return &null
        }

        return self._int(range, rk, PrimitiveLimits::int_value(b, k, width, storage))
    }

    /// The note under "'T' has no 'X'": why the format lacks it.
    priv fn _why_missing(self, b: BuiltinKind, k: PrimLimit) -> string {
        if b == BuiltinKind::F8E4M3 && (k == PrimLimit::Infinity || k == PrimLimit::NegInfinity) {
            return "f8e4m3 is the E4M3FN format: it has no infinity, and overflow saturates to 448"
        }

        if b == BuiltinKind::Byte {
            return "a byte is not a number; it has only BITS"
        }

        if b == BuiltinKind::Bool {
            return "bool has no numeric limits"
        }

        if PrimitiveLimits::is_float_limit(k) {
            return f"'{PrimitiveLimits::name_of(k)}' is a float limit; integers have MIN, MAX and BITS"
        }

        return ""
    }

    /// TypeResolution's f80 gate, restated: no target facts (a hand-built
    /// invocation) is permissive there too.
    priv fn _has_f80(self) -> bool {
        if self.sc->ctx == &null || self.sc->ctx->ci == &null {
            return true
        }

        var *t = &self.sc->ctx->ci->target
        if !t->resolved {
            return true
        }

        return t->long_double_is_x87
    }

    priv fn _int(self, range: SourceRange, rk: BuiltinKind, v: PrimLimitInt) -> unsafe *Expr {
        var unsafe *tbl = self.sc->imm_table()
        var        idx  = tbl->create<Immediate::IntData>()
        var unsafe *d   = tbl->get<Immediate::IntData>(idx)
        d->value_lo = v.lo
        d->value_hi = v.hi
        d->bits     = (builtin_info(rk)->bits as u16)
        d->base     = 10
        // bit 3: suffixed -- a typed literal to every reader (overload
        // ranking does not defer it, EmitIR casts it to its type); bit 0
        // unsigned.
        d->flags = 8
        if !builtin_info(rk)->is_signed() {
            d->flags = 9
        }

        var t = Token()
        t.kind  = TokenKind::LitInt
        t.range = range
        t.imm   = idx
        var unsafe *lit = IntegerLiteralExpr::create(self.sc->ctx, range, t)
        lit->pinned_kind = (rk as u8)
        self.n_minted += 1
        if !v.neg {
            return lit
        }

        var minus = Token()
        minus.kind  = TokenKind::OpMinus
        minus.range = range
        var unsafe *neg = UnaryOperatorExpr::create(
            self.sc->ctx,
            range,
            lit,
            minus,
            UnaryOperatorExpr::Fix::Prefix,
        )

        // Parenthesized: the chain was a primary, and `i32::MIN.abs()` must
        // stay the call on the negated value.
        return unsafe (ParenExpr::create(self.sc->ctx, range, unsafe (neg as unsafe *Expr)) as unsafe *Expr)
    }

    priv fn _float(self, range: SourceRange, b: BuiltinKind, k: PrimLimit) -> unsafe *Expr {
        var unsafe *tbl = self.sc->imm_table()
        var        idx  = tbl->create<Immediate::FloatData>()
        var unsafe *d   = tbl->get<Immediate::FloatData>(idx)
        d->bits  = (builtin_info(b)->bits as u32)
        d->base  = 16
        d->flags = 16 | 4 // suffixed, hex: typed, and no decimal digits to re-read.

        var t = Token()
        t.kind  = TokenKind::LitFloat
        t.range = range
        t.imm   = idx
        var unsafe *lit = FloatingLiteralExpr::create(self.sc->ctx, range, t)
        lit->pinned_kind = (b as u8)
        lit->limit       = (k as u8)
        self.n_minted += 1
        return lit
    }
}
