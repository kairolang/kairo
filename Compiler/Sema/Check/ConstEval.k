/// --- The Kairo Project ------------------------- Sema/Check/ConstEval.k --- ///
///
///   \brief Integer constant evaluation: the value of an integer expression
///          that X has typed, when it has one at compile time.
///
///   \detail
///     Two callers. PatternSpace reads literal and range bounds through it,
///     and StmtTyping evaluates enum discriminants with it, writing the
///     result to EnumVariantDecl::value. Nothing here diagnoses or writes a
///     slot: a failed evaluation leaves `bad` / `bad_why` / `bad_decl` for
///     the caller to report.
///
///     What evaluates:
///       integer literals; unary `-` `~` `+`; binary `+ - * | & ^ << >>`
///       (and `bitor` / `bitand` / `xor`) when they are builtin, not a user
///       `op`; parentheses; `as` to an integer type; a `const` / `eval`
///       name whose initializer evaluates; and, inside a discriminant only,
///       a variant of the same enum declared ABOVE the one being defined,
///       whose value StmtTyping has already written.
///
///     Arithmetic is exact. Values are IntConst (AST/Node/Declarations.k):
///     sign-magnitude over u64, so every value of every 64-bit type has one
///     representation, and a result whose magnitude needs a 65th bit sets
///     `overflow` instead of wrapping. Nothing is checked against a type
///     until the end (`fits`), so `1 << 8` in a u8 enum is 256 that does not
///     fit, not a 0 that does. The one place a value is cut to a width is
///     `as`, which keeps the low bits of the two's complement value
///     (casting.md, Narrowing), as C++ does.
///
///     The binary bitwise operators work on the infinite two's complement
///     form: a value is its low 64 bits plus one sign bit that extends
///     forever, so `-1 & 0xFF` is 255 with no width in sight. `~` cannot:
///     on that form `~0` is -1, which no unsigned type holds, yet `~0` in a
///     u32 flags enum is meant as all 32 bits set. So `~x` is taken in the
///     type X gave its operand (`_complement`), which inside a
///     discriminant is the underlying type: the literal is typed against it,
///     and an earlier variant reads as it. The result is still exact; only
///     its meaning depends on the width.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sema::SemaContext::*;
import Sema::Type::TypeUtil::*;
import Sema::Resolve::NameLookup::*;
import AST::Context::DeclContext::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Declarations::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import Token::Token::*;
import Token::TokenKind::*;

class ConstEval {
    pub var sc: *SemaContext;
    pub var tu: TypeUtil;

    /// Why the last evaluation failed: the sub-expression that does not
    /// evaluate, a phrase saying why, and a decl worth a note (a variant
    /// named before it is defined, a variable that is not constant).
    pub var bad:      *Expr = &null;
    pub var bad_why:  string;
    pub var bad_decl: *Decl = &null;
    /// The failure is one an earlier diagnostic already explains: a node X
    /// poisoned, or an earlier variant whose own value failed. The caller
    /// reports nothing, so one mistake is one error.
    pub var quiet:    bool  = false;
    /// The first `const` (not `eval`) variable the last evaluation read, and
    /// the name that read it. A pattern bound or a discriminant may read
    /// one; an array length or a generic value argument must be eval-able
    /// (EVAL.md 3), and reports it with a fix-it to `eval`.
    pub var const_decl: *VariableDecl = &null;
    pub var const_at:   *Expr         = &null;

    /// The enum whose discriminant is being evaluated, and the defining
    /// variant's position in it; null outside a discriminant.
    priv var _en:  *EnumDecl = &null;
    priv var _pos: usize     = 0;

    fn ConstEval(self) { self.sc = &null; }
    fn ConstEval(self, sc: *SemaContext) {
        self.sc = sc;
        self.tu = TypeUtil(sc);
    }

    // === entry points =======================================================

    /// \p e as an integer constant, with no enum variant in scope.
    fn eval_int(self, e: *Expr) -> IntConst {
        self._reset();
        self._en  = &null;
        self._pos = 0;
        return self._eval(e, 0);
    }

    /// The value of the variable \p d names, as if \p at (a name of it) were
    /// evaluated: a generic value argument written as a bare name parses as
    /// a type, so there is no expression to hand eval_int (EVAL.md 3).
    fn eval_decl(self, at: *Expr, d: *Decl) -> IntConst {
        self._reset();
        self._en  = &null;
        self._pos = 0;
        return self._ref(at, d, 0);
    }

    /// \p e as the discriminant of the variant at position \p pos of \p en:
    /// the variants above it are constants too.
    fn eval_discriminant(self, e: *Expr, en: *EnumDecl, pos: usize) -> IntConst {
        self._reset();
        self._en  = en;
        self._pos = pos;
        var r = self._eval(e, 0);
        self._en = &null;
        return r;
    }

    priv fn _reset(self) {
        self.bad      = &null;
        self.bad_why  = "";
        self.bad_decl = &null;
        self.quiet    = false;
        self.const_decl = &null;
        self.const_at   = &null;
    }

    // === values =============================================================

    /// An ok constant `-mag` / `mag`, zero always non-negative.
    fn make(self, neg: bool, mag: u64) -> IntConst {
        var r = IntConst{};
        r.ok  = true;
        r.neg = neg && (mag != u64(0));
        r.mag = mag;
        return r;
    }

    /// A constant too wide for 64 bits.
    fn too_wide(self) -> IntConst {
        var r = IntConst{};
        r.ok       = true;
        r.overflow = true;
        return r;
    }

    /// Does \p c fit the integer type \p t? Exact: no wrapping.
    fn fits(self, c: IntConst, t: *Type) -> bool {
        if (!c.ok) || c.overflow { return false; }
        var u = self.tu.as_value(t);
        if (u == &null) || (!self.tu.is_integer(u)) { return false; }
        return self.fits_bits(c, self.tu.int_bits(u), self.tu.is_signed_int(u));
    }

    fn fits_bits(self, c: IntConst, bits: usize, signed: bool) -> bool {
        if (!c.ok) || c.overflow { return false; }
        if bits == 0 { return false; }
        if !signed {
            if c.neg { return false; }
            if bits >= 64 { return true; }
            return c.mag <= ((u64(1) << u64(bits)) - u64(1));
        }
        // A magnitude below 2^64 is inside every signed type wider than 64.
        if bits > 64 { return true; }
        var half = u64(1) << u64(bits - 1);
        if c.neg { return c.mag <= half; }
        return c.mag <= (half - u64(1));
    }

    /// \p c cut to \p bits as `as` does: the low bits of its two's
    /// complement form, read back signed or unsigned. A value wider than
    /// 64 bits has lost the bits that decide the answer, so it stays
    /// overflowed.
    fn wrap(self, c: IntConst, bits: usize, signed: bool) -> IntConst {
        if (!c.ok) || c.overflow { return c; }
        if bits > 64 {
            // Every 64-bit magnitude fits a wider signed type unchanged; a
            // negative into a wider unsigned one needs the bits above 64.
            if (!signed) && c.neg { return self.too_wide(); }
            return c;
        }
        if bits == 0 { return IntConst{}; }
        var all  = u64(0) - u64(1);
        var mask = (all) if (bits == 64) else ((u64(1) << u64(bits)) - u64(1));
        var low  = ((u64(0) - c.mag)) if (c.neg) else (c.mag);
        low = low & mask;
        if signed && (((low >> u64(bits - 1)) & u64(1)) == u64(1)) {
            // 2^bits - low; at 64 bits mask - low + 1 cannot wrap, low >= 2^63.
            return self.make(true, (mask - low) + u64(1));
        }
        return self.make(false, low);
    }

    /// The decimal spelling of \p c, for messages.
    fn str(self, c: IntConst) -> string {
        if !c.ok { return "<not a constant>"; }
        if c.overflow { return "a value wider than 64 bits"; }
        if c.neg { return f"-{c.mag}"; }
        return f"{c.mag}";
    }

    // === arithmetic =========================================================

    fn add(self, a: IntConst, b: IntConst) -> IntConst {
        if a.overflow || b.overflow { return self.too_wide(); }
        if a.neg == b.neg {
            var s = a.mag + b.mag;
            if s < a.mag { return self.too_wide(); }
            return self.make(a.neg, s);
        }
        if a.mag >= b.mag { return self.make(a.neg, a.mag - b.mag); }
        return self.make(b.neg, b.mag - a.mag);
    }

    fn negate(self, a: IntConst) -> IntConst {
        if a.overflow { return a; }
        return self.make(!a.neg, a.mag);
    }

    fn sub(self, a: IntConst, b: IntConst) -> IntConst {
        return self.add(a, self.negate(b));
    }

    fn mul(self, a: IntConst, b: IntConst) -> IntConst {
        if a.overflow || b.overflow { return self.too_wide(); }
        if (a.mag == u64(0)) || (b.mag == u64(0)) { return self.make(false, u64(0)); }
        var all = u64(0) - u64(1);
        if b.mag > (all / a.mag) { return self.too_wide(); }
        return self.make(a.neg != b.neg, a.mag * b.mag);
    }

    /// `~a` is `-a - 1` on the infinite two's complement form, which is
    /// also its value in any signed type.
    fn complement(self, a: IntConst) -> IntConst {
        if a.overflow { return a; }
        if a.neg { return self.make(false, a.mag - u64(1)); }
        var all = u64(0) - u64(1);
        if a.mag == all { return self.too_wide(); }
        return self.make(true, a.mag + u64(1));
    }

    /// `~a` in an integer type of \p bits: `-a - 1` when signed, and
    /// `(2^bits - 1) - a` when unsigned. Both are exact, so an `a` outside
    /// the type gives a result outside it too, and the final range check
    /// rejects it rather than this quietly wrapping it. Not ok for an
    /// unsigned type wider than 64 bits, whose all-ones value has no
    /// IntConst.
    fn complement_in(self, a: IntConst, bits: usize, signed: bool) -> IntConst {
        if signed { return self.complement(a); }
        if (bits == 0) || (bits > 64) { return IntConst{}; }
        var all  = u64(0) - u64(1);
        var ones = (all) if (bits == 64) else ((u64(1) << u64(bits)) - u64(1));
        return self.sub(self.make(false, ones), a);
    }

    /// `|` `&` `^` (\p which 0 / 1 / 2) on the infinite two's complement form:
    /// the low 64 bits, plus a sign bit standing for every bit above them.
    fn bitop(self, a: IntConst, b: IntConst, which: u8) -> IntConst {
        if a.overflow || b.overflow { return self.too_wide(); }
        var la = ((u64(0) - a.mag)) if (a.neg) else (a.mag);
        var lb = ((u64(0) - b.mag)) if (b.neg) else (b.mag);
        var lo: u64 = 0;
        var hi = false;
        if which == u8(0)      { lo = la | lb; hi = a.neg || b.neg; }
        else if which == u8(1) { lo = la & lb; hi = a.neg && b.neg; }
        else                   { lo = la ^ lb; hi = a.neg != b.neg; }
        if !hi { return self.make(false, lo); }
        // Negative: -(2^64 - lo). lo == 0 would be -2^64, past 64 bits.
        if lo == u64(0) { return self.too_wide(); }
        return self.make(true, u64(0) - lo);
    }

    /// `a << n`: `a * 2^n`, exact. The count is not ok when negative.
    fn shl(self, a: IntConst, n: IntConst) -> IntConst {
        if a.overflow || n.overflow { return self.too_wide(); }
        if n.neg { return IntConst{}; }
        if a.mag == u64(0) { return self.make(false, u64(0)); }
        if n.mag >= u64(64) { return self.too_wide(); }
        var all = u64(0) - u64(1);
        if a.mag > (all >> n.mag) { return self.too_wide(); }
        return self.make(a.neg, a.mag << n.mag);
    }

    /// `a >> n`: floor(a / 2^n), so a negative rounds toward -infinity as
    /// an arithmetic shift does.
    fn shr(self, a: IntConst, n: IntConst) -> IntConst {
        if a.overflow || n.overflow { return self.too_wide(); }
        if n.neg { return IntConst{}; }
        var q: u64 = 0;
        var rem = a.mag;
        if n.mag < u64(64) {
            q   = a.mag >> n.mag;
            rem = a.mag & ((u64(1) << n.mag) - u64(1));
        }
        if a.neg && (rem != u64(0)) { q = q + u64(1); }
        return self.make(a.neg, q);
    }

    // === the walk ===========================================================

    /// A failure at \p at, unless an inner one already said why.
    priv fn _fail(self, at: *Expr, why: string, d: *Decl = &null) -> IntConst {
        if (self.bad == &null) && (!self.quiet) {
            self.bad      = at;
            self.bad_why  = why;
            self.bad_decl = d;
        }
        return IntConst{};
    }

    /// A failure an earlier diagnostic already covers.
    priv fn _quiet(self) -> IntConst {
        self.quiet = true;
        return IntConst{};
    }

    /// \p depth counts `const` initializers followed, so a cycle of them
    /// stops; the expression tree itself is finite.
    priv fn _eval(self, e0: *Expr, depth: u32) -> IntConst {
        if e0 == &null { return IntConst{}; }
        if e0->is_poisoned() { return self._quiet(); }
        var e = self.tu.strip_parens(e0);
        if e == &null { return IntConst{}; }
        if e->is_poisoned() { return self._quiet(); }

        if isa::<IntegerLiteralExpr>(e) {
            var lit = cast::<IntegerLiteralExpr>(e);
            if lit->imm == &null { return self._fail(e, "this literal has no value"); }
            if lit->get_value_hi() != u64(0) { return self.too_wide(); }
            return self.make(false, lit->get_value_lo());
        }

        if isa::<UnaryOperatorExpr>(e) {
            var u = cast::<UnaryOperatorExpr>(e);
            if (!u->is_prefix()) || (u->resolved_op != &null) { return self._fail(e, "this operator is not evaluated at compile time"); }
            var k = u->op_token.kind;
            var isneg = (k == TokenKind::OpMinus);
            var isnot = (k == TokenKind::OpTilde) || (k == TokenKind::KwCompl);
            var ispos = (k == TokenKind::OpPlus);
            if (!isneg) && (!isnot) && (!ispos) { return self._fail(e, "this operator is not evaluated at compile time"); }
            var inner = self._eval(u->operand, depth);
            if !inner.ok { return inner; }
            if isneg { return self.negate(inner); }
            if isnot { return self._complement(u, inner); }
            return inner;
        }

        if isa::<BinaryOperatorExpr>(e) {
            return self._binary(cast::<BinaryOperatorExpr>(e), depth);
        }

        if isa::<TypeCastExpr>(e) {
            return self._cast(cast::<TypeCastExpr>(e), depth);
        }

        if isa::<NamedIdentExpr>(e) {
            return self._ref(e, cast::<NamedIdentExpr>(e)->resolved_decl, depth);
        }

        if isa::<ChainExpr>(e) {
            var ch = cast::<ChainExpr>(e);
            if ch->steps.size() == 0 { return self._fail(e, "this does not evaluate at compile time"); }
            var last = ch->steps.get(ch->steps.size() - 1)->resolved_decl;
            if last == &null { last = self._scope_path(ch); }
            return self._ref(e, last, depth);
        }

        if isa::<CallExpr>(e) {
            return self._fail(e, "a call is not evaluated at compile time");
        }
        return self._fail(e, "this does not evaluate at compile time");
    }

    /// `m::K` / `C::K` before ChainBinding has bound it: TypeResolve
    /// evaluates an array length (`[i32; m::K]`) in phase T, where only the
    /// head of a chain is resolved. A path of `::` steps through modules and
    /// types is looked up here as ChainBinding would, through the frozen
    /// tables; a single unambiguous hit or nothing.
    priv fn _scope_path(self, ch: *ChainExpr) -> *Decl {
        if (ch->base == &null) || (!isa::<NamedIdentExpr>(ch->base)) { return &null; }
        var d = cast::<NamedIdentExpr>(ch->base)->resolved_decl;
        for var i: usize = 0; i < ch->steps.size(); ++i {
            var st = ch->steps.get(i);
            if (d == &null) || (st->access_kind != ChainExpr::AccessKind::ColonColon) || (st->name == &null) { return &null; }
            var imm = self.sc->ctx->get_ident_imm(st->name->name);
            if imm == u32(-1) { return &null; }
            var name    = DeclName::ident(imm);
            var spelled = self.sc->ctx->get_spelling(st->name->name);
            var scopes  = vec::<*DeclContext>();
            if isa::<ModuleDecl>(d) { NameLookup::module_scopes(d, scopes); }
            else {
                var dc = NameLookup::context_of(d);
                if dc != &null { scopes.push_back(dc); }
            }
            var hit: *Decl = &null;
            for var k: usize = 0; k < scopes.size(); ++k {
                var r = self.sc->lookup.in_context(scopes[k], name, spelled);
                if !r.found() { continue; }
                if (hit != &null) || (r.cell->size() != 1) { return &null; }
                hit = r.cell->get(0);
            }
            d = hit;
        }
        return d;
    }

    priv fn _binary(self, b: *BinaryOperatorExpr, depth: u32) -> IntConst {
        var e = static_cast::<*Expr>(b);
        if b->resolved_op != &null { return self._fail(e, "a user operator is not evaluated at compile time"); }
        var k = b->op_token.kind;
        var known = (k == TokenKind::OpPlus) || (k == TokenKind::OpMinus) || (k == TokenKind::OpStar)
                 || (k == TokenKind::OpPipe) || (k == TokenKind::KwBitor)
                 || (k == TokenKind::OpAmp)  || (k == TokenKind::KwBitand)
                 || (k == TokenKind::OpCaret) || (k == TokenKind::KwXor)
                 || (k == TokenKind::OpLessLess) || (k == TokenKind::OpGreaterGreater);
        if !known { return self._fail(e, f"'{self.sc->ctx->get_spelling(b->op_token)}' is not evaluated at compile time"); }

        var l = self._eval(b->lhs, depth);
        if !l.ok { return l; }
        var r = self._eval(b->rhs, depth);
        if !r.ok { return r; }

        if k == TokenKind::OpPlus  { return self.add(l, r); }
        if k == TokenKind::OpMinus { return self.sub(l, r); }
        if k == TokenKind::OpStar  { return self.mul(l, r); }
        if (k == TokenKind::OpPipe)  || (k == TokenKind::KwBitor)  { return self.bitop(l, r, u8(0)); }
        if (k == TokenKind::OpAmp)   || (k == TokenKind::KwBitand) { return self.bitop(l, r, u8(1)); }
        if (k == TokenKind::OpCaret) || (k == TokenKind::KwXor)    { return self.bitop(l, r, u8(2)); }
        if r.neg { return self._fail(b->rhs, "a shift count cannot be negative"); }
        if k == TokenKind::OpLessLess { return self.shl(l, r); }
        return self.shr(l, r);
    }

    /// `~x` in the type of `x`. Without an integer builtin there is no width
    /// to complement within, and guessing one (u32, or the infinite form)
    /// would give a value the C++ `~` does not, so it does not evaluate.
    priv fn _complement(self, u: *UnaryOperatorExpr, v: IntConst) -> IntConst {
        var e  = static_cast::<*Expr>(u);
        var wt: *Type = (u->operand->type_) if (u->operand != &null) else (&null);
        var ot = self.tu.as_value(wt);
        if (ot == &null) || (!self.tu.is_integer(ot)) {
            return self._fail(e, "'~' is evaluated at compile time only on an operand of an integer type");
        }
        var signed = self.tu.is_signed_int(ot);
        var bits   = self.tu.int_bits(ot);
        if (!signed) && (bits > 64) {
            return self._fail(e, f"'~' on a '{self.tu.str(ot)}\x27 operand is not evaluated at compile time; its value can be wider than 64 bits");
        }
        return self.complement_in(v, bits, signed);
    }

    /// `x as T` to an integer T, builtin only.
    priv fn _cast(self, c: *TypeCastExpr, depth: u32) -> IntConst {
        var e = static_cast::<*Expr>(c);
        if (c->resolved_op != &null) || (c->resolved_ctor != &null) {
            return self._fail(e, "a user conversion is not evaluated at compile time");
        }
        var t: *Type = c->type_;
        if (t == &null) && (c->target != &null) { t = c->target->canonical; }
        var u = self.tu.as_value(t);
        if (u == &null) || (!self.tu.is_integer(u)) {
            return self._fail(e, "only a cast to an integer type is evaluated at compile time");
        }
        var v = self._eval(c->operand, depth);
        if !v.ok { return v; }
        return self.wrap(v, self.tu.int_bits(u), self.tu.is_signed_int(u));
    }

    /// A name: a `const` / `eval` variable, or a variant above the one
    /// being defined.
    priv fn _ref(self, at: *Expr, d: *Decl, depth: u32) -> IntConst {
        if d == &null { return self._fail(at, "this name does not evaluate at compile time"); }

        var vd = dyn_cast::<VariableDecl>(d);
        if vd != &null {
            var nm = self.tu.decl_name(d);
            if (!vd->is_const()) && (!vd->is_eval()) {
                return self._fail(at, f"'{nm}' is a variable; only a 'const' or 'eval' name is a constant", d);
            }
            if (!vd->is_eval()) && (self.const_decl == &null) {
                self.const_decl = vd;
                self.const_at   = at;
            }
            if (vd->init == &null) || (depth > 8) {
                return self._fail(at, f"'{nm}' has no initializer that evaluates", d);
            }
            var c = self._eval(vd->init, depth + 1);
            if !c.ok {
                // The init sits elsewhere: point at the name, not inside it.
                if !self.quiet {
                    self.bad      = at;
                    self.bad_why  = f"the initializer of '{nm}' does not evaluate";
                    self.bad_decl = d;
                }
                return c;
            }
            // The constant is what the variable holds, so its own type
            // bounds it exactly as it bounds the C++ object.
            var vt: *Type = (vd->type_->canonical) if (vd->type_ != &null) else (&null);
            if (vt != &null) && self.tu.is_integer(self.tu.as_value(vt)) && (!self.fits(c, vt)) {
                return self._fail(at, f"'{nm}' is {self.str(c)}, which does not fit its type '{self.tu.str(vt)}\x27", d);
            }
            return c;
        }

        // An `eval` field is a class constant (EVAL.md 1.2, 7d): one value
        // per class, its initializer, as an `eval` variable is.
        var fd = dyn_cast::<FieldDecl>(d);
        if (fd != &null) && fd->is_eval() {
            var fnm = self.tu.decl_name(d);
            if (fd->init == &null) || (depth > 8) {
                return self._fail(at, f"'{fnm}' has no initializer that evaluates", d);
            }
            var fc = self._eval(fd->init, depth + 1);
            if !fc.ok {
                if !self.quiet {
                    self.bad      = at;
                    self.bad_why  = f"the initializer of '{fnm}' does not evaluate";
                    self.bad_decl = d;
                }
                return fc;
            }
            var ft: *Type = (fd->type_->canonical) if (fd->type_ != &null) else (&null);
            if (ft != &null) && self.tu.is_integer(self.tu.as_value(ft)) && (!self.fits(fc, ft)) {
                return self._fail(at, f"'{fnm}' is {self.str(fc)}, which does not fit its type '{self.tu.str(ft)}\x27", d);
            }
            return fc;
        }

        var v = dyn_cast::<EnumVariantDecl>(d);
        if v != &null { return self._variant(at, v); }

        return self._fail(at, f"'{self.tu.decl_name(d)}' is not a constant");
    }

    /// A variant of the enum being defined, above the defining one. Its
    /// value is already written: StmtTyping fills the slot in declaration
    /// order. The test is by POSITION, never by whether the slot is ok, so a
    /// forward reference fails the same way however often the enum is walked.
    priv fn _variant(self, at: *Expr, v: *EnumVariantDecl) -> IntConst {
        var nm = self.tu.decl_name(static_cast::<*Decl>(v));
        var vdc = reinterpret_cast::<*DeclContext>(v->semantic_dc);
        var owner = (dyn_cast::<EnumDecl>(vdc->owner_decl())) if (vdc != &null) else (&null);
        var same = (self._en != &null) && (owner != &null);
        if same {
            var a = NameLookup::representative(static_cast::<*Decl>(owner));
            var b = NameLookup::representative(static_cast::<*Decl>(self._en));
            same = (a == b);
        }
        if !same {
            return self._fail(at, f"'{nm}' is a variant of another enum; only this enum\x27s own variants are constants here");
        }
        var pos = owner->variants.size();
        for var i: usize = 0; i < owner->variants.size(); ++i {
            if owner->variants[i] == v { pos = i; break; }
        }
        if pos == owner->variants.size() { return self._fail(at, f"'{nm}' is not a variant of this enum"); }
        if pos == self._pos { return self._fail(at, f"'{nm}' is the variant being defined"); }
        if pos > self._pos {
            return self._fail(at, f"'{nm}' is declared below this variant, so it has no value yet", static_cast::<*Decl>(v));
        }
        if !v->value.ok { return self._quiet(); }   // its own failure was reported.
        return v->value;
    }
}
