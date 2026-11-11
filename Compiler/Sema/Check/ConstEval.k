/// --- The Kairo Project ----------------------- Sema/Check/ConstEval.k --- ///
///
///   \brief Integer constant evaluation: the value of an integer expression
///          that ExprTyper has typed, when it has one at compile time.
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
///     Arithmetic is exact, except a shift typed at an integer of at most
///     64 bits, which is the run-time shift (shift_in: the count modulo the
///     register width, the result truncated to the type). Values are IntConst (AST/Node/Declarations.k):
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
///     type ExprTyper gave its operand (`_complement`), which inside a
///     discriminant is the underlying type: the literal is typed against it,
///     and an earlier variant reads as it. The result is still exact; only
///     its meaning depends on the width.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "vector"

import AST::Context::DeclContext::DeclContext
import AST::Context::DepLog::dep_log_current
import AST::Context::SymbolTable::DeclName
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    EnumDecl,
    EnumVariantDecl,
    FieldDecl,
    IntConst,
    ModuleDecl,
    VariableDecl,
}
import AST::Node::Expressions::{
    BinaryOperatorExpr,
    CallExpr,
    TypeCastExpr,
    UnaryOperatorExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    IntegerLiteralExpr,
    NamedIdentExpr,
}
import AST::Node::Types::{
    TypeExpr,
    ValueOp,
}
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::SemaContext
import Sema::Type::TypeUtil::TypeUtil
import Token::TokenKind::TokenKind

pub class ConstEval {
    pub var sc: unsafe *SemaContext
    pub var tu: TypeUtil

    /// Why the last evaluation failed: the sub-expression that does not
    /// evaluate, a phrase saying why, and a decl worth a note (a variant
    /// named before it is defined, a variable that is not constant).
    pub var bad:      unsafe *Expr = &null
    pub var bad_why:  string
    pub var bad_decl: unsafe *Decl = &null
    /// The failure is one an earlier diagnostic already explains: a node X
    /// poisoned, or an earlier variant whose own value failed. The caller
    /// reports nothing, so one mistake is one error.
    pub var quiet: bool = false
    /// The first `const` (not `eval`) variable the last evaluation read, and
    /// the name that read it. A pattern bound or a discriminant may read
    /// one; an array length or a generic value argument must be eval-able
    /// (Compiler/Spec/Eval.md#generic-value-parameters), and reports it with a fix-it to `eval`.
    pub var const_decl: unsafe *VariableDecl = &null
    pub var const_at:   unsafe *Expr         = &null

    /// The enum whose discriminant is being evaluated, and the defining
    /// variant's position in it; null outside a discriminant.
    priv var _en:  unsafe *EnumDecl = &null
    priv var _pos: usize            = 0

    fn ConstEval(self) {
        self.sc = &null
    }

    fn ConstEval(self, sc: unsafe *SemaContext) {
        self.sc = sc
        self.tu = TypeUtil(sc)
    }

    /// # entry points

    /// \p e as an integer constant, with no enum variant in scope.
    fn eval_int(self, e: unsafe *Expr) -> IntConst {
        self._reset()
        self._en  = &null
        self._pos = 0
        return self._eval(e, 0)
    }

    /// The value of the variable \p d names, as if \p at (a name of it) were
    /// evaluated: a generic value argument written as a bare name parses as
    /// a type, so there is no expression to hand eval_int (Compiler/Spec/Eval.md#generic-value-parameters).
    fn eval_decl(self, at: unsafe *Expr, d: unsafe *Decl) -> IntConst {
        self._reset()
        self._en  = &null
        self._pos = 0
        return self._ref(at, d, 0)
    }

    /// \p e as the discriminant of the variant at position \p pos of \p en:
    /// the variants above it are constants too.
    fn eval_discriminant(self, e: unsafe *Expr, en: unsafe *EnumDecl, pos: usize) -> IntConst {
        self._reset()
        self._en  = en
        self._pos = pos
        var r = self._eval(e, 0)
        self._en = &null
        return r
    }

    /// A canonical value node (Compiler/Spec/Eval.md#value-nodes, 3) for \p vk over \p ops:
    /// folded to an exact value_arg when every operand is one and the
    /// operator is one this class evaluates (`[T; N + 1]` under N := 3 is
    /// `[T; 4]`), else the interned expression for C++ to compute. A call,
    /// an eval name and `~` (which needs a width) never fold here.
    fn value_node(self,
                  vk:   ValueOp,
                  tok:  TokenKind,
                  decl: unsafe *Decl,
                  ops:  unsafe *cxx::std::vector<unsafe *Type>,
                  ty:   unsafe *Type) -> unsafe *Type {
        var exact = vk == ValueOp::Unary || vk == ValueOp::Binary || vk == ValueOp::Cast
        var vals  = cxx::std::vector<IntConst>()
        for var i: usize = 0; i < ops->size(); ++i {
            var unsafe *v = dyn_cast<TypeExpr>((*ops)[i])
            if v == &null || !v->is_exact() {
                exact = false
                break
            }

            vals.push_back(self.make(v->vneg, v->vmag))
        }

        if exact {
            var r = IntConst{}
            if vk == ValueOp::Unary {
                if tok == TokenKind::OpMinus {
                    r = self.negate(vals[0])
                } else if tok == TokenKind::OpPlus {
                    r = vals[0]
                }
            } else if vk == ValueOp::Cast {
                var unsafe *u = self.tu.as_value(ty)
                if u != &null && self.tu.is_integer(u) {
                    r = self.wrap(vals[0], self.tu.int_bits(u), self.tu.is_signed_int(u))
                }
            } else {
                r = self._fold_binary(tok, vals[0], vals[1])
            }

            if r.ok && !r.overflow {
                return self.sc->types->value_arg(r.neg, r.mag)
            }
        }

        return self.sc->types->value_expr(vk, tok, decl, ops, ty)
    }

    /// The builtin binary operators on exact values, C++'s truncating `/`
    /// and `%` among them; not ok for anything else (and for a zero divisor
    /// or a negative shift, which C++ rejects in a constant expression).
    priv fn _fold_binary(self, k: TokenKind, l: IntConst, r: IntConst) -> IntConst {
        if k == TokenKind::OpPlus {
            return self.add(l, r)
        }

        if k == TokenKind::OpMinus {
            return self.sub(l, r)
        }

        if k == TokenKind::OpStar {
            return self.mul(l, r)
        }

        if k == TokenKind::OpPipe || k == TokenKind::KwBitor {
            return self.bitop(l, r, 0)
        }

        if k == TokenKind::OpAmp || k == TokenKind::KwBitand {
            return self.bitop(l, r, 1)
        }

        if k == TokenKind::OpCaret || k == TokenKind::KwXor {
            return self.bitop(l, r, 2)
        }

        if (k == TokenKind::OpLessLess || k == TokenKind::OpGreaterGreater) && !r.neg {
            return if (k == TokenKind::OpLessLess) => (self.shl(l, r)) else => self.shr(l, r)
        }

        if (k == TokenKind::OpSlash || k == TokenKind::OpPercent) && r.mag != (0 as u64) {
            if k == TokenKind::OpSlash {
                return self.make(l.neg != r.neg, l.mag / r.mag)
            }

            return self.make(l.neg, l.mag % r.mag)
        }

        return IntConst{}
    }

    priv fn _reset(self) {
        self.bad        = &null
        self.bad_why    = ""
        self.bad_decl   = &null
        self.quiet      = false
        self.const_decl = &null
        self.const_at   = &null
    }

    /// # values

    /// An ok constant `-mag` / `mag`, zero always non-negative.
    fn make(self, neg: bool, mag: u64) -> IntConst {
        var r = IntConst{}
        r.ok  = true
        r.neg = neg && mag != (0 as u64)
        r.mag = mag
        return r
    }

    /// A constant too wide for 64 bits.
    fn too_wide(self) -> IntConst {
        var r = IntConst{}
        r.ok       = true
        r.overflow = true
        return r
    }

    /// Does \p c fit the integer type \p t? Exact: no wrapping.
    fn fits(self, c: IntConst, t: unsafe *Type) -> bool {
        if !c.ok || c.overflow {
            return false
        }

        var unsafe *u = self.tu.as_value(t)
        if u == &null || !self.tu.is_integer(u) {
            return false
        }

        return self.fits_bits(c, self.tu.int_bits(u), self.tu.is_signed_int(u))
    }

    fn fits_bits(self, c: IntConst, bits: usize, signed_: bool) -> bool {
        if !c.ok || c.overflow {
            return false
        }

        if bits == 0 {
            return false
        }

        if !signed_ {
            if c.neg {
                return false
            }

            if bits >= 64 {
                return true
            }

            return c.mag <= ((1 as u64) << (bits as u64)) - (1 as u64)
        }

        // A magnitude below 2^64 is inside every signed type wider than 64.
        if bits > 64 {
            return true
        }

        var half = (1 as u64) << ((bits - 1) as u64)
        if c.neg {
            return c.mag <= half
        }

        return c.mag <= half - (1 as u64)
    }

    /// \p c cut to \p bits as `as` does: the low bits of its two's
    /// complement form, read back signed or unsigned. A value wider than
    /// 64 bits has lost the bits that decide the answer, so it stays
    /// overflowed.
    fn wrap(self, c: IntConst, bits: usize, signed_: bool) -> IntConst {
        if !c.ok || c.overflow {
            return c
        }

        if bits > 64 {
            // Every 64-bit magnitude fits a wider signed type unchanged; a
            // negative into a wider unsigned one needs the bits above 64.
            if !signed_ && c.neg {
                return self.too_wide()
            }

            return c
        }

        if bits == 0 {
            return IntConst{}
        }

        var all  = (0 as u64) - (1 as u64)
        var mask = if (bits == 64) => (all) else => ((1 as u64) << (bits as u64)) - (1 as u64)
        var low  = if (c.neg) => ((0 as u64) - c.mag) else => c.mag
        low = low & mask
        if signed_ && (low >> ((bits - 1) as u64) & (1 as u64)) == (1 as u64) {
            // 2^bits - low; at 64 bits mask - low + 1 cannot wrap, low >= 2^63.
            return self.make(true, mask - low + (1 as u64))
        }

        return self.make(false, low)
    }

    /// The decimal spelling of \p c, for messages.
    fn str(self, c: IntConst) -> string {
        if !c.ok {
            return "<not a constant>"
        }

        if c.overflow {
            return "a value wider than 64 bits"
        }

        if c.neg {
            return f"-{c.mag}"
        }

        return f"{c.mag}"
    }

    /// # arithmetic

    fn add(self, a: IntConst, b: IntConst) -> IntConst {
        if a.overflow || b.overflow {
            return self.too_wide()
        }

        if a.neg == b.neg {
            var s = a.mag + b.mag
            if s < a.mag {
                return self.too_wide()
            }

            return self.make(a.neg, s)
        }

        if a.mag >= b.mag {
            return self.make(a.neg, a.mag - b.mag)
        }

        return self.make(b.neg, b.mag - a.mag)
    }

    fn negate(self, a: IntConst) -> IntConst {
        if a.overflow {
            return a
        }

        return self.make(!a.neg, a.mag)
    }

    fn sub(self, a: IntConst, b: IntConst) -> IntConst {
        return self.add(a, self.negate(b))
    }

    fn mul(self, a: IntConst, b: IntConst) -> IntConst {
        if a.overflow || b.overflow {
            return self.too_wide()
        }

        if a.mag == (0 as u64) || b.mag == (0 as u64) {
            return self.make(false, 0)
        }

        var all = (0 as u64) - (1 as u64)
        if b.mag > all / a.mag {
            return self.too_wide()
        }

        return self.make(a.neg != b.neg, a.mag * b.mag)
    }

    /// `~a` is `-a - 1` on the infinite two's complement form, which is
    /// also its value in any signed type.
    fn complement(self, a: IntConst) -> IntConst {
        if a.overflow {
            return a
        }

        if a.neg {
            return self.make(false, a.mag - (1 as u64))
        }

        var all = (0 as u64) - (1 as u64)
        if a.mag == all {
            return self.too_wide()
        }

        return self.make(true, a.mag + (1 as u64))
    }

    /// `~a` in an integer type of \p bits: `-a - 1` when signed, and
    /// `(2^bits - 1) - a` when unsigned. Both are exact, so an `a` outside
    /// the type gives a result outside it too, and the final range check
    /// rejects it rather than this quietly wrapping it. Not ok for an
    /// unsigned type wider than 64 bits, whose all-ones value has no
    /// IntConst.
    fn complement_in(self, a: IntConst, bits: usize, signed_: bool) -> IntConst {
        if signed_ {
            return self.complement(a)
        }

        if bits == 0 || bits > 64 {
            return IntConst{}
        }

        var all  = (0 as u64) - (1 as u64)
        var ones = if (bits == 64) => (all) else => ((1 as u64) << (bits as u64)) - (1 as u64)
        return self.sub(self.make(false, ones), a)
    }

    /// `|` `&` `^` (\p which 0 / 1 / 2) on the infinite two's complement form:
    /// the low 64 bits, plus a sign bit standing for every bit above them.
    fn bitop(self, a: IntConst, b: IntConst, which: u8) -> IntConst {
        if a.overflow || b.overflow {
            return self.too_wide()
        }

        var la      = if (a.neg) => ((0 as u64) - a.mag) else => a.mag
        var lb      = if (b.neg) => ((0 as u64) - b.mag) else => b.mag
        var lo: u64 = 0
        var hi      = false
        if which == (0 as u8) {
            lo = la | lb
            hi = a.neg || b.neg
        } else if which == (1 as u8) {
            lo = la & lb
            hi = a.neg && b.neg
        } else {
            lo = la ^ lb
            hi = a.neg != b.neg
        }

        if !hi {
            return self.make(false, lo)
        }

        // Negative: -(2^64 - lo). lo == 0 would be -2^64, past 64 bits.
        if lo == (0 as u64) {
            return self.too_wide()
        }

        return self.make(true, (0 as u64) - lo)
    }

    /// `a << n`: `a * 2^n`, exact. The count is not ok when negative.
    fn shl(self, a: IntConst, n: IntConst) -> IntConst {
        if a.overflow || n.overflow {
            return self.too_wide()
        }

        if n.neg {
            return IntConst{}
        }

        if a.mag == (0 as u64) {
            return self.make(false, 0)
        }

        if n.mag >= (64 as u64) {
            return self.too_wide()
        }

        var all = (0 as u64) - (1 as u64)
        if a.mag > all >> n.mag {
            return self.too_wide()
        }

        return self.make(a.neg, a.mag << n.mag)
    }

    /// `a >> n`: floor(a / 2^n), so a negative rounds toward -infinity as
    /// an arithmetic shift does.
    fn shr(self, a: IntConst, n: IntConst) -> IntConst {
        if a.overflow || n.overflow {
            return self.too_wide()
        }

        if n.neg {
            return IntConst{}
        }

        var q:  u64 = 0
        var rem     = a.mag
        if n.mag < (64 as u64) {
            q   = a.mag >> n.mag
            rem = a.mag & ((1 as u64) << n.mag) - (1 as u64)
        }

        if a.neg && rem != (0 as u64) {
            q = q + (1 as u64)
        }

        return self.make(a.neg, q)
    }

    /// # the walk

    /// A failure at \p at, unless an inner one already said why.
    priv fn _fail(self, at: unsafe *Expr, const why: string, d: unsafe *Decl = &null) -> IntConst {
        if self.bad == &null && !self.quiet {
            self.bad      = at
            self.bad_why  = why
            self.bad_decl = d
        }

        return IntConst{}
    }

    /// A failure an earlier diagnostic already covers.
    priv fn _quiet(self) -> IntConst {
        self.quiet = true
        return IntConst{}
    }

    /// \p depth counts `const` initializers followed, so a cycle of them
    /// stops; the expression tree itself is finite.
    priv fn _eval(self, e0: unsafe *Expr, depth: u32) -> IntConst {
        if e0 == &null {
            return IntConst{}
        }

        if e0->is_poisoned() {
            return self._quiet()
        }

        var unsafe *e = self.tu.strip_parens(e0)
        if e == &null {
            return IntConst{}
        }

        if e->is_poisoned() {
            return self._quiet()
        }

        if isa<IntegerLiteralExpr>(e) {
            var unsafe *lit = cast<IntegerLiteralExpr>(e)
            if lit->imm == &null {
                return self._fail(e, "this literal has no value")
            }

            if lit->get_value_hi() != (0 as u64) {
                return self.too_wide()
            }

            return self.make(false, lit->get_value_lo())
        }

        if isa<UnaryOperatorExpr>(e) {
            var unsafe *u = cast<UnaryOperatorExpr>(e)
            if !u->is_prefix() || u->resolved_op != &null {
                return self._fail(e, "this operator is not evaluated at compile time")
            }

            var k     = u->op_token.kind
            var isneg = k == TokenKind::OpMinus
            var isnot = k == TokenKind::OpTilde || k == TokenKind::KwCompl
            var ispos = k == TokenKind::OpPlus
            if !isneg && !isnot && !ispos {
                return self._fail(e, "this operator is not evaluated at compile time")
            }

            var inner = self._eval(u->operand, depth)
            if !inner.ok {
                return inner
            }

            if isneg {
                return self.negate(inner)
            }

            if isnot {
                return self._complement(u, inner)
            }

            return inner
        }

        if isa<BinaryOperatorExpr>(e) {
            return self._binary(cast<BinaryOperatorExpr>(e), depth)
        }

        if isa<TypeCastExpr>(e) {
            return self._cast(cast<TypeCastExpr>(e), depth)
        }

        if isa<NamedIdentExpr>(e) {
            return self._ref(e, cast<NamedIdentExpr>(e)->resolved_decl, depth)
        }

        if isa<ChainExpr>(e) {
            var unsafe *ch = cast<ChainExpr>(e)
            if ch->steps.size() == 0 {
                return self._fail(e, "this does not evaluate at compile time")
            }

            var unsafe *last = ch->steps.get(ch->steps.size() - 1)->resolved_decl
            if last == &null {
                last = self.scope_path(ch)
            }

            return self._ref(e, last, depth)
        }

        if isa<CallExpr>(e) {
            return self._fail(e, "a call is not evaluated at compile time")
        }

        return self._fail(e, "this does not evaluate at compile time")
    }

    /// `m::K` / `C::K` before ChainBinding has bound it: TypeResolve
    /// evaluates an array length (`[i32; m::K]`) in phase T, where only the
    /// head of a chain is resolved. A path of `::` steps through modules and
    /// types is looked up here as ChainBinding would, through the frozen
    /// tables; a single unambiguous hit or nothing.
    fn scope_path(self, ch: unsafe *ChainExpr) -> unsafe *Decl {
        if ch->base == &null || !isa<NamedIdentExpr>(ch->base) {
            return &null
        }

        var unsafe *d = cast<NamedIdentExpr>(ch->base)->resolved_decl
        for var i: usize = 0; i < ch->steps.size(); ++i {
            var unsafe *st = ch->steps.get(i)
            if d == &null
                || st->access_kind != ChainExpr::AccessKind::ColonColon
                || st->name == &null {
                return &null
            }

            var imm = self.sc->ctx->get_ident_imm(st->name->name)
            if imm == u32::MAX {
                return &null
            }

            var name    = DeclName::ident(imm)
            var spelled = self.sc->ctx->get_spelling(st->name->name)
            var scopes  = cxx::std::vector<unsafe *DeclContext>()
            if isa<ModuleDecl>(d) {
                NameLookup::module_scopes(d, &scopes)
            } else {
                var unsafe *dc = NameLookup::context_of(d)
                if dc != &null {
                    scopes.push_back(dc)
                }
            }

            var hit: unsafe *Decl = &null
            for var k: usize = 0; k < scopes.size(); ++k {
                var r = self.sc->lookup.in_context(scopes[k], name, spelled)
                if !r.found() {
                    continue
                }

                if hit != &null || r.cell->size() != 1 {
                    return &null
                }

                hit = r.cell->get(0)
            }

            d = hit
        }

        return d
    }

    priv fn _binary(self, b: unsafe *BinaryOperatorExpr, depth: u32) -> IntConst {
        var unsafe *e = unsafe (b as unsafe *Expr)
        if b->resolved_op != &null {
            return self._fail(e, "a user operator is not evaluated at compile time")
        }

        var k = b->op_token.kind
        var known = k == TokenKind::OpPlus
            || k == TokenKind::OpMinus
            || k == TokenKind::OpStar
            || k == TokenKind::OpPipe
            || k == TokenKind::KwBitor
            || k == TokenKind::OpAmp
            || k == TokenKind::KwBitand
            || k == TokenKind::OpCaret
            || k == TokenKind::KwXor
            || k == TokenKind::OpLessLess
            || k == TokenKind::OpGreaterGreater
        if !known {
            return self._fail(
                e,
                f"'{self.sc->ctx->get_spelling(b->op_token)}' is not evaluated at compile time",
            )
        }

        var l = self._eval(b->lhs, depth)
        if !l.ok {
            return l
        }

        var r = self._eval(b->rhs, depth)
        if !r.ok {
            return r
        }

        if k == TokenKind::OpPlus {
            return self.add(l, r)
        }

        if k == TokenKind::OpMinus {
            return self.sub(l, r)
        }

        if k == TokenKind::OpStar {
            return self.mul(l, r)
        }

        if k == TokenKind::OpPipe || k == TokenKind::KwBitor {
            return self.bitop(l, r, 0)
        }

        if k == TokenKind::OpAmp || k == TokenKind::KwBitand {
            return self.bitop(l, r, 1)
        }

        if k == TokenKind::OpCaret || k == TokenKind::KwXor {
            return self.bitop(l, r, 2)
        }

        // A typed shift is the run-time one (SHIFT spec §1, §6): the count
        // modulo the register width, computed in it, truncated to T. Exact
        // shifting would call `0xFFu8 << 4` a 4080 that does not fit, where
        // the program computes 0xF0.
        var unsafe *st = self.tu.as_value(b->type_)
        if st != &null
            && self.tu.is_integer(st)
            && self.tu.int_bits(st) > 0
            && self.tu.int_bits(st) <= 64 {
            return self.shift_in(
                k == TokenKind::OpLessLess,
                l,
                r,
                self.tu.int_bits(st),
                self.tu.is_signed_int(st),
            )
        }

        if r.neg {
            return self._fail(b->rhs, "a shift count cannot be negative")
        }

        if k == TokenKind::OpLessLess {
            return self.shl(l, r)
        }

        return self.shr(l, r)
    }

    /// `a << n` / `a >> n` in an integer type of \p bits (at most 64), as
    /// EmitIR's forms compute it: n, converted modulo 2^64 (a negative count
    /// is a large unsigned one), taken modulo R (32 up to 32 bits, else
    /// 64); `<<` keeps the low bits; `>>` is arithmetic when \p signed.
    fn shift_in(self,
                left:    bool,
                a0:      IntConst,
                n:       IntConst,
                bits:    usize,
                signed_: bool) -> IntConst {
        if a0.overflow || n.overflow {
            return self.too_wide()
        }

        var rw:  u64 = if (bits <= 32) => (32) else => (64)
        var nlow     = if (n.neg) => ((0 as u64) - n.mag) else => n.mag
        var c        = nlow & rw - (1 as u64)
        var a        = self.wrap(a0, bits, signed_)
        if !left {
            return self.shr(a, self.make(false, c))
        }

        var low = if (a.neg) => ((0 as u64) - a.mag) else => a.mag
        return self.wrap(self.make(false, low << c), bits, signed_)
    }

    /// `~x` in the type of `x`. Without an integer builtin there is no width
    /// to complement within, and guessing one (u32, or the infinite form)
    /// would give a value the C++ `~` does not, so it does not evaluate.
    priv fn _complement(self, u: unsafe *UnaryOperatorExpr, v: IntConst) -> IntConst {
        var unsafe *e               = unsafe (u as unsafe *Expr)
        var        wt: unsafe *Type = if (u->operand != &null) => (u->operand->type_) else => &null
        var unsafe *ot              = self.tu.as_value(wt)
        if ot == &null || !self.tu.is_integer(ot) {
            return self._fail(
                e,
                "'~' is evaluated at compile time only on an operand of an integer type",
            )
        }

        var signed_ = self.tu.is_signed_int(ot)
        var bits    = self.tu.int_bits(ot)
        if !signed_ && bits > 64 {
            return self._fail(
                e,
                f"'~' on a '{self.tu.str(ot)}' operand is not evaluated at compile time; its value can be wider than 64 bits",
            )
        }

        return self.complement_in(v, bits, signed_)
    }

    /// `x as T` to an integer T, builtin only.
    priv fn _cast(self, c: unsafe *TypeCastExpr, depth: u32) -> IntConst {
        var unsafe *e = unsafe (c as unsafe *Expr)
        if c->resolved_op != &null || c->resolved_ctor != &null {
            return self._fail(e, "a user conversion is not evaluated at compile time")
        }

        var t: unsafe *Type = c->type_
        if t == &null && c->target != &null {
            t = c->target->canonical
        }

        var unsafe *u = self.tu.as_value(t)
        if u == &null || !self.tu.is_integer(u) {
            return self._fail(e, "only a cast to an integer type is evaluated at compile time")
        }

        var v = self._eval(c->operand, depth)
        if !v.ok {
            return v
        }

        return self.wrap(v, self.tu.int_bits(u), self.tu.is_signed_int(u))
    }

    /// A name: a `const` / `eval` variable, or a variant above the one
    /// being defined.
    priv fn _ref(self, at: unsafe *Expr, d: unsafe *Decl, depth: u32) -> IntConst {
        if d == &null {
            return self._fail(at, "this name does not evaluate at compile time")
        }

        // Folding through a name reads its initializer (or its
        // discriminant): the reader's result moves when that text does, even
        // where the declared type stays (AST/Context/DepLog.k).
        var unsafe *deps = dep_log_current()
        if deps != &null {
            deps->body(d as usize as u64)
        }

        var unsafe *vd = dyn_cast<VariableDecl>(d)
        if vd != &null {
            var nm = self.tu.decl_name(d)
            if !vd->is_const() && !vd->is_eval() {
                return self._fail(
                    at,
                    f"'{nm}' is a variable; only a 'const' or 'eval' name is a constant",
                    d,
                )
            }

            if !vd->is_eval() && self.const_decl == &null {
                self.const_decl = vd
                self.const_at   = at
            }

            if vd->init == &null || depth > 8 {
                return self._fail(at, f"'{nm}' has no initializer that evaluates", d)
            }

            var c = self._eval(vd->init, depth + 1)
            if !c.ok {
                // The init sits elsewhere: point at the name, not inside it.
                if !self.quiet {
                    self.bad      = at
                    self.bad_why  = f"the initializer of '{nm}' does not evaluate"
                    self.bad_decl = d
                }

                return c
            }

            // The constant is what the variable holds, so its own type
            // bounds it exactly as it bounds the C++ object.
            var vt: unsafe *Type = if (vd->type_ != &null) => (vd->type_->canonical) else => &null
            if vt != &null && self.tu.is_integer(self.tu.as_value(vt)) && !self.fits(c, vt) {
                return self._fail(
                    at,
                    f"'{nm}' is {self.str(c)}, which does not fit its type '{self.tu.str(vt)}'",
                    d,
                )
            }

            return c
        }

        // An `eval` field is a class constant (Compiler/Spec/Eval.md#eval-bindings, 7d): one value
        // per class, its initializer, as an `eval` variable is.
        var unsafe *fd = dyn_cast<FieldDecl>(d)
        if fd != &null && fd->is_eval() {
            var fnm = self.tu.decl_name(d)
            if fd->init == &null || depth > 8 {
                return self._fail(at, f"'{fnm}' has no initializer that evaluates", d)
            }

            var fc = self._eval(fd->init, depth + 1)
            if !fc.ok {
                if !self.quiet {
                    self.bad      = at
                    self.bad_why  = f"the initializer of '{fnm}' does not evaluate"
                    self.bad_decl = d
                }

                return fc
            }

            var ft: unsafe *Type = if (fd->type_ != &null) => (fd->type_->canonical) else => &null
            if ft != &null && self.tu.is_integer(self.tu.as_value(ft)) && !self.fits(fc, ft) {
                return self._fail(
                    at,
                    f"'{fnm}' is {self.str(fc)}, which does not fit its type '{self.tu.str(ft)}'",
                    d,
                )
            }

            return fc
        }

        var unsafe *v = dyn_cast<EnumVariantDecl>(d)
        if v != &null {
            return self._variant(at, v)
        }

        return self._fail(at, f"'{self.tu.decl_name(d)}' is not a constant")
    }

    /// A variant of the enum being defined, above the defining one. Its
    /// value is already written: StmtTyping fills the slot in declaration
    /// order. The test is by POSITION, never by whether the slot is ok, so a
    /// forward reference fails the same way however often the enum is walked.
    priv fn _variant(self, at: unsafe *Expr, v: unsafe *EnumVariantDecl) -> IntConst {
        var        nm   = self.tu.decl_name(unsafe (v as unsafe *Decl))
        var unsafe *vdc = v->semantic_dc
        var unsafe *owner = if (vdc != &null) => (dyn_cast<EnumDecl>(vdc->owner_decl()))
                            else => &null
        var same = self._en != &null && owner != &null
        if same {
            var unsafe *a = NameLookup::representative(owner)
            var unsafe *b = NameLookup::representative(self._en)
            same = a == b
        }

        if !same {
            return self._fail(
                at,
                f"'{nm}' is a variant of another enum; only this enum's own variants are constants here",
            )
        }

        var pos = owner->variants.size()
        for var i: usize = 0; i < owner->variants.size(); ++i {
            if owner->variants[i] == v {
                pos = i
                break
            }
        }

        if pos == owner->variants.size() {
            return self._fail(at, f"'{nm}' is not a variant of this enum")
        }

        if pos == self._pos {
            return self._fail(at, f"'{nm}' is the variant being defined")
        }

        if pos > self._pos {
            return self._fail(
                at,
                f"'{nm}' is declared below this variant, so it has no value yet",
                unsafe (v as unsafe *Decl),
            )
        }

        if !v->value.ok { // its own failure was reported.
            return self._quiet()
        }

        return v->value
    }
}
