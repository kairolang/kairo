/// --- The Kairo Project ------------------- Codegen/Emit/EmitIRForms.k --- ///
///
///   EmitIR, part: the checked arithmetic forms. The wrap, shift, division
///   and compound-assignment forms (WrapForms) an operator is written as when
///   C++'s own would be undefined or differ, bit-field places, and the binding
///   forms that hold an operand in a temporary.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/Shims.hh"
ffi "c++" import "clang/Basic/TokenKinds.h"
ffi "c++" import "vector"

import AST::Kind::StmtKind::StmtKind
import AST::LangItems::LowerTargets
import AST::Node::Base::{
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    BuiltinType,
    builtin_info,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::FieldDecl
import AST::Node::Expressions::{
    AssignOperatorExpr,
    ParenExpr,
    StmtExpr,
    UnaryOperatorExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Statements::ExpressionStmt
import AST::Node::Types::PointerType
import AST::OperatorFacts::OperatorFacts
import Codegen::Emit::EmitIR::EmitIR
import Codegen::Emit::EmitIRConvert
import Codegen::Emit::EmitIRDecls
import Codegen::Emit::EmitIRExprs
import Codegen::Emit::EmitIRStmts
import Codegen::Emit::Spell::Speller
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Location::FullSourceLocation::FullSourceLocation
import Location::SourceRange::SourceRange
import Token::TokenKind::TokenKind

extend EmitIR {
    /// Integer arithmetic on `t` wraps: a builtin integer or `char`,
    /// through a C++ reference (an imported `operator[]`'s `int&`). Not bool.
    prot fn _wraps(self, t: unsafe *Type) -> bool {
        var unsafe *c = Speller::strip_ref(t)
        if c == &null || !isa<BuiltinType>(c) {
            return false
        }

        var unsafe *b = cast<BuiltinType>(c)
        if b->builtin == BuiltinKind::Char {
            return true
        }

        return b->info()->is_integer()
    }

    /// A primitive whose `<=>` C++ answers with a `std::strong_ordering`: an
    /// integer, `char` or `bool`. A float's is a `std::partial_ordering`,
    /// whose unordered answer (NaN) has no Ordering variant, so it is left
    /// as it was.
    prot fn _cmp3_scalar(self, t: unsafe *Type) -> bool {
        if self._wraps(t) {
            return true
        }

        var unsafe *c = Speller::strip_ref(t)
        return c != &null
            && isa<BuiltinType>(c)
            && cast<BuiltinType>(c)->builtin == BuiltinKind::Bool
    }

    priv fn _signed_int(self, t: unsafe *Type) -> bool {
        var unsafe *c = Speller::strip_ref(t)
        if c == &null || !isa<BuiltinType>(c) {
            return false
        }

        return cast<BuiltinType>(c)->info()->is_signed()
    }

    /// `x`, a local or parameter (parens aside): evaluating it twice is
    /// free and does nothing, so its compound forms bind nothing. So is a
    /// bit-field off an object without effects (`b.f`, `p->f`), which no
    /// `auto&` could bind.
    priv fn _is_local_place(self, e: unsafe *Expr) -> bool {
        var unsafe *x = e
        while x != &null && isa<ParenExpr>(x) {
            x = cast<ParenExpr>(x)->inner
        }

        if x != &null
            && self._bitfield_chain(x) != &null
            && self._simple_object(cast<ChainExpr>(x)->base) {
            return true
        }

        if x == &null || !isa<NamedIdentExpr>(x) {
            return false
        }

        var unsafe *d = cast<NamedIdentExpr>(x)->resolved_decl
        return d != &null && self._is_local(d)
    }

    /// `e` names an object with no effect to repeat: a name, a field path
    /// off one, or a dereference of one.
    priv fn _simple_object(self, e: unsafe *Expr) -> bool {
        var unsafe *x = self._strip(e)
        if x == &null {
            return false
        }

        if isa<NamedIdentExpr>(x) {
            return true
        }

        if isa<ChainExpr>(x) {
            var unsafe *c = cast<ChainExpr>(x)
            for var i: usize = 0; i < c->steps.size(); ++i {
                var unsafe *st = c->steps.get(i)
                if st->is_operator() || !isa<FieldDecl>(st->resolved_decl) {
                    return false
                }
            }

            return self._simple_object(c->base)
        }

        var unsafe *u = dyn_cast<UnaryOperatorExpr>(x)
        if u != &null && u->op_token.kind == TokenKind::OpStar && u->resolved_op == &null {
            return self._simple_object(u->operand)
        }

        return false
    }

    /// `e` is `obj.f` (one step or more) with f a bit-field: the chain, else null.
    priv fn _bitfield_chain(self, e: unsafe *Expr) -> unsafe *ChainExpr {
        var unsafe *c = dyn_cast<ChainExpr>(e)
        if c == &null || c->steps.size() == 0 {
            return &null
        }

        var unsafe *fd = dyn_cast<FieldDecl>(
            c->steps.get(c->steps.size() - 1)->resolved_decl,
        )

        if fd == &null || !fd->is_bitfield {
            return &null
        }

        return c
    }

    /// A bit-field place whose object has an effect: the object is bound
    /// once and the field re-read through it, `({ auto&& o = (obj); o.f =
    /// <o.f OP v>; o.f; })`. The store truncates to the field's width, which
    /// is the wrap at that width ([conv.integral]); the re-read returns it.
    priv fn _bitfield_form(self,
                           n:           unsafe *Expr,
                           place:       unsafe *ChainExpr,
                           k:           TokenKind,
                           v:           fn(),
                           t:           unsafe *Type,
                           postfix_old: bool) {
        if place->steps.size() != 1 {
            self._ice(
                n->range,
                "EmitIR: a bit-field written through a multi-step chain whose object has an effect; bind the object first",
            )
        }

        var        at = n->range
        var unsafe *s = self._cg->sink
        var        d  = self._bind_depth
        self._bind_depth += 1
        var        o   = LowerTargets::wrap_tmp("p", d)
        var        old = LowerTargets::wrap_tmp("o", d)
        var unsafe *fd = cast<FieldDecl>(place->steps.get(0)->resolved_decl)
        var unsafe *bt = place->base->type_
        var arrow = bt != &null
            && bt->canonical != &null
            && isa<PointerType>(canon_unqual(bt->canonical))
        var mem  = o + (if (arrow) => ("->") else => ".") + self._spell.leaf(fd)
        var stmt = self._stmt_node == n
        self._form_open(at)
        s->spell(at, "auto&& " + o + " = (")
        self.emit(place->base)
        s->spell(at, "); ")
        if postfix_old && !stmt {
            s->spell(at, "auto " + old + " = " + mem + "; ")
        }

        s->spell(at, mem + " = ")
        self._op_form(at, k, fn () { s->spell(at, mem) }, v, t)
        s->spell(at, ";")
        if !stmt {
            s->spell(at, " ")
            self._form_value(at)
            s->spell(at, (if (postfix_old) => (old) else => mem) + ";")
        }

        self._form_close(at)
        self._bind_depth = d
    }

    /// The op a compound assignment applies, TkUnknown when it has no wrap form
    /// (`&= |= ^=` are native: defined, a truncating store).
    prot fn _compound_op(self, k: TokenKind) -> TokenKind {
        var b = OperatorFacts::compound_base(k)
        if b == TokenKind::OpAmp || b == TokenKind::OpPipe || b == TokenKind::OpCaret {
            return TokenKind::TkUnknown
        }

        return b
    }

    /// Binary op `k` on integer type `t` has a wrap form (`t` is the
    /// node's type): `+ - * / % << >>`, and `& | ^` narrower than int.
    prot fn _has_wrap_form(self, k: TokenKind, t: unsafe *Type) -> bool {
        if k == TokenKind::OpPlus || k == TokenKind::OpMinus || k == TokenKind::OpStar {
            return true
        }

        if k == TokenKind::OpSlash || k == TokenKind::OpPercent {
            return true
        }

        if k == TokenKind::OpLessLess || k == TokenKind::OpGreaterGreater {
            return true
        }

        if k == TokenKind::OpAmp || k == TokenKind::OpPipe || k == TokenKind::OpCaret {
            return Speller::int_width(t) < (32 as u32)
        }

        return false
    }

    prot fn _sc(self, at: SourceRange, const ty: string) {
        self._cg->sink->spell(at, "static_cast<" + ty + ">(")
    }

    /// A statement expression in a namespace-scope initializer (`var c =
    /// unwrap!(one())`, a checked `as` into a closed enum): C++ allows no
    /// statement expression there, so it is the body of a lambda
    /// called on the spot, as a binding form is (_form_open), its last
    /// expression statement returned. No capture: nothing at namespace
    /// scope needs one. Inside the lambda is a function body again.
    prot fn _ns_stmt_expr(self, se: unsafe *StmtExpr) {
        var unsafe *e = unsafe (se as unsafe *Expr)
        var unsafe *b = se->body
        if b == &null {
            self._ice(e->range, "EmitIR: statement expression with no block")
        }

        self._cg->sink->spell(e->range, "[]() { ")
        var saved = self._ns_init
        self._ns_init = false
        var n = b->body.size()
        for var i: usize = 0; i < n; ++i {
            var unsafe *s = b->body[i]
            if i + 1 == n && s != &null && s->kind == StmtKind::ExpressionStmt {
                self._cg->sink->spell(s->range, "return ")
                self.emit(cast<ExpressionStmt>(s)->expr)
                self._cg->sink->spell(s->range, ";")
            } else {
                self.emit(s)
            }
        }

        self._ns_init = saved
        self._cg->sink->spell(e->range, " }()")
    }

    /// A binding form's brackets: a statement expression, or at namespace
    /// scope (_ns_init) a lambda called on the spot, whose value is
    /// returned (_form_value).
    prot fn _form_open(self, at: SourceRange) {
        if self._ns_init {
            self._cg->sink->spell(at, "[]() { ")
        } else {
            self._cg->sink->spell(at, "({ ")
        }
    }

    prot fn _form_value(self, at: SourceRange) {
        if self._ns_init {
            self._cg->sink->spell(at, "return ")
        }
    }

    prot fn _form_close(self, at: SourceRange) {
        if self._ns_init {
            self._cg->sink->spell(at, " }()")
        } else {
            self._cg->sink->spell(at, " })")
        }
    }

    /// The value of op `k` (a wrap-form binary op) on T = `t`, the
    /// operands emitted by `a` and `b`. A division binds its operands
    /// (_div_form); every other form is pure (an operand once).
    prot fn _op_form(self, at: SourceRange, k: TokenKind, a: fn(), b: fn(), t: unsafe *Type) {
        if k == TokenKind::OpSlash || k == TokenKind::OpPercent {
            self._div_form(at, k == TokenKind::OpPercent, a, b, t)
            return
        }

        var        ts = self._spell._type(Speller::strip_ref(t))
        var        u  = self._spell.wrap_carrier(t)
        var unsafe *s = self._cg->sink
        if k == TokenKind::OpLessLess || k == TokenKind::OpGreaterGreater {
            self._shift_form(at, k, a, b, t, false)
            return
        }

        var sym = "+"
        if k == TokenKind::OpMinus {
            sym = "-"
        }

        if k == TokenKind::OpStar {
            sym = "*"
        }

        if k == TokenKind::OpAmp || k == TokenKind::OpPipe || k == TokenKind::OpCaret {
            // Narrow bitwise: defined in int already; the cast keeps the
            // result at T instead of the promoted int.
            sym = if (k == TokenKind::OpAmp) => ("&")
                  else => (if (k == TokenKind::OpPipe) => ("|") else => "^")
            self._sc(at, ts)
            s->spell(at, "(")
            a()
            s->spell(at, ") " + sym + " (")
            b()
            s->spell(at, "))")
            return
        }

        self._sc(at, ts)
        self._sc(at, u)
        a()
        s->spell(at, ") " + sym + " ")
        self._sc(at, u)
        b()
        s->spell(at, "))")
    }

    /// `a << b` / `a >> b` on integer T = `t` (SHIFT spec §1, §3.1): the
    /// count, converted to the carrier U, is taken modulo R, the register
    /// width (Speller::reg_width: 32 below 32 bits), and the shift is done
    /// in R bits and truncated to T. `& (R - 1)` is the mask the carrier's
    /// shift instruction applies itself on x86, AArch64 and RISC-V, so it
    /// is free there; ARM32 shifts by the count's low byte and pays one
    /// instruction for it (two on ARMv6-M, which must load the 31). A narrow
    /// T masks by 31, not W - 1, for the same reason: `u8 << 9` is 0.
    /// `<<` and a logical `>>` shift the carrier; an arithmetic `>>` the
    /// left operand sign-extended to R_T (C++20 defines it). `proven` is
    /// the node's no_wrap (§4): the count is known to be in [0, W), so the
    /// mask is left out, and the shift is still UB-free.
    prot fn _shift_form(self,
                        at:     SourceRange,
                        k:      TokenKind,
                        a:      fn(),
                        b:      fn(),
                        t:      unsafe *Type,
                        proven: bool) {
        var        ts = self._spell._type(Speller::strip_ref(t))
        var        u  = self._spell.wrap_carrier(t)
        var unsafe *s = self._cg->sink
        var arith = k == TokenKind::OpGreaterGreater && self._signed_int(t)
        if !proven {
            self._warn_unproven_shift(at, t)
        }

        self._sc(at, ts)
        self._sc(at, if (arith) => (self._spell.reg_signed(t)) else => u)
        a()
        s->spell(at, ")")
        s->shift(at, k == TokenKind::OpLessLess)

        if proven {
            self._sc(at, u)
            b()
            s->spell(at, "))")
            return
        }

        var rm1 = Speller::reg_width(t) - (1 as u32)
        s->spell(at, "(")
        self._sc(at, u)
        b()
        s->spell(at, ")")
        s->spell(at, " & ")
        self._sc(at, u)
        s->spell(at, f"{rm1}" + ")")
        s->spell(at, "))")
    }

    /// `at` lies in a file under the builtins or std root.
    priv fn _in_lib_root(self, at: SourceRange) -> bool {
        var unsafe *ctx = self._cg->ctx
        if ctx->sm == &null || ctx->ci == &null || !at.start.is_valid() {
            return false
        }

        var full: FullSourceLocation = ctx->sm->get_line_col(at.start)
        var path                     = full.path.full_path()
        var b                        = ctx->ci->pp.builtins_dir.copy()
        var d                        = ctx->ci->pp.std_dir.copy()
        if !b.is_empty() && path.starts_with(b) {
            return true
        }

        return !d.is_empty() && path.starts_with(d)
    }

    /// -Wshift-count-unproven (SHIFT spec §5): a shift whose count is not
    /// proven below the width costs its mask on ARM32 only, so the warning
    /// is for an embedded build that wants every such instruction named.
    /// Off unless asked for, and silent on every target that masks free.
    priv fn _warn_unproven_shift(self, at: SourceRange, t: unsafe *Type) {
        if !self._cg->opts.warn_unproven_shift {
            return
        }

        // Only the user's own code: a library body emitted into this TU (a
        // builtin's inline or generic body), or Lib/builtin and Lib/std
        // compiled as TUs of their own, are not theirs to change.
        if self._owning_fid() != self._cg->tu->fid {
            return
        }

        if self._in_lib_root(at) {
            return
        }

        var tr = self._cg->opts.target_triple.copy()
        // ARM32 only: `arm64` is AArch64, which masks free.
        var arm32 = tr.starts_with("thumb") || tr.starts_with("arm") && !tr.starts_with("arm64")
        if !arm32 {
            return
        }

        var unsafe *ct = Speller::strip_ref(t)
        var        tn  = self._spell._type(ct)
        if ct != &null && isa<BuiltinType>(ct) {
            tn = builtin_info(cast<BuiltinType>(ct)->builtin)->spelling.copy()
        }

        var wm1 = Speller::int_width(t) - (1 as u32)
        var b = self._cg->ctx->diag_sink.report(
            DiagCode(DiagID::SC241W),
            at.start,
            f"shift count is not proven below the width of '{tn}'; masking costs an instruction on this target",
        )

        b.first(at, "this shift masks its count")
        b.note(
            at.start,
            f"mask it yourself (n & {wm1}) or bound it in a range loop to remove the cost",
        )

        b.emit()
    }

    /// `a / b`, `a % b`: the operands bound in order (which is their
    /// sequencing too), a zero divisor the runtime's crash, `MIN / -1` the
    /// wrapped `MIN` and `MIN % -1` zero. A constant divisor folds both
    /// checks away.
    priv fn _div_form(self, at: SourceRange, rem: bool, a: fn(), b: fn(), t: unsafe *Type) {
        var ts = self._spell._type(Speller::strip_ref(t))
        var u  = self._spell.wrap_carrier(t)
        var d  = self._bind_depth
        self._bind_depth += 1
        var        ta  = LowerTargets::wrap_tmp("a", d)
        var        tb  = LowerTargets::wrap_tmp("b", d)
        var unsafe *s  = self._cg->sink
        var        sym = if (rem) => ("%") else => "/"
        self._form_open(at)
        s->spell(at, ts + " " + ta + " = (")
        a()
        s->spell(at, "); ")
        s->spell(at, ts + " " + tb + " = (")
        b()
        s->spell(at, "); ")
        s->spell(
            at,
            "if (" + LowerTargets::clang_expect() + "(" + tb + " == 0, 0)) ::" + LowerTargets::div_zero_fn() + "(); ",
        )

        self._form_value(at)
        if self._signed_int(t) {
            if rem {
                s->spell(
                    at,
                    "(" + tb + " == -1) ? static_cast<" + ts + ">(0) : ",
                )
            } else {
                s->spell(
                    at,
                    "(" + tb + " == -1) ? static_cast<" + ts + ">(static_cast<" + u + ">(0) - static_cast<" + u + ">(" + ta + ")) : ",
                )
            }
        }

        s->spell(
            at,
            "static_cast<" + ts + ">(" + ta + " " + sym + " " + tb + ");",
        )

        self._form_close(at)
        self._bind_depth = d
    }

    /// f256 / f512 / f8e4m3 / f8e5m2: classes in C++ (num/f256_t.k,
    /// std/rt/Float8.k) that declare `+ - * /`
    /// only, Kairo deriving `+=` and the rest (operator-overloading.mdx),
    /// so C++ has no `+=` to call.
    prot fn _wide_float(self, t: unsafe *Type) -> bool {
        var unsafe *c = Speller::strip_ref(t)
        if c == &null || !isa<BuiltinType>(c) {
            return false
        }

        var b = cast<BuiltinType>(c)->builtin
        return b == BuiltinKind::F256
            || b == BuiltinKind::F512
            || b == BuiltinKind::F8E4M3
            || b == BuiltinKind::F8E5M2
    }

    /// `place OP= v` on an f256 / f512: `place = place OP v`, the place
    /// evaluated once (bound, `auto&`, unless a local), then v.
    prot fn _wide_compound(self, n: unsafe *AssignOperatorExpr, k: TokenKind) {
        var unsafe *s  = self._cg->sink
        var        at  = n->range
        var        sym = "+"
        if k == TokenKind::OpMinus {
            sym = "-"
        } else if k == TokenKind::OpStar {
            sym = "*"
        } else if k == TokenKind::OpSlash {
            sym = "/"
        } else if k != TokenKind::OpPlus {
            self._ice(
                at,
                "EmitIR: an f256 / f512 compound assignment with no class operator",
            )
        }

        if self._is_local_place(n->lhs) {
            s->spell(at, "(")
            self.emit(n->lhs)
            s->spell(at, " = ")
            self.emit(n->lhs)
            s->spell(at, " " + sym + " (")
            self._value(n->rhs, n->lhs->type_)
            s->spell(at, "))")
            return
        }

        var d = self._bind_depth
        self._bind_depth += 1
        var p = LowerTargets::wrap_tmp("p", d)
        self._form_open(at)
        s->spell(at, "auto& " + p + " = (")
        self.emit(n->lhs)
        s->spell(at, "); " + p + " = " + p + " " + sym + " (")
        self._value(n->rhs, n->lhs->type_)
        s->spell(at, ");")
        if self._stmt_node != n {
            s->spell(at, " ")
            self._form_value(at)
            s->spell(at, p + ";")
        }

        self._form_close(at)
        self._bind_depth = d
    }

    /// `place OP= v` with OP a wrap-form op (_compound_op). A local place
    /// is `(x = <x OP v>)`; any other is bound once, `auto&` so its cv
    /// stays: `({ auto& p = (place); p = <p OP v>; p; })`, the trailing
    /// value dropped in statement position and its address taken where the
    /// node is used as a place. The place is evaluated before the value.
    prot fn _compound_form(self, n: unsafe *AssignOperatorExpr, k: TokenKind) {
        var unsafe *t    = n->lhs->type_
        var        at    = n->range
        var unsafe *s    = self._cg->sink
        var        shift = k == TokenKind::OpLessLess || k == TokenKind::OpGreaterGreater
        if self._is_local_place(n->lhs) {
            s->spell(at, "(")
            self.emit(n->lhs)
            s->spell(at, " = ")
            if shift {
                self._shift_form(
                    at,
                    k,
                    fn () { self.emit(n->lhs) },
                    fn () { self.emit(n->rhs) },
                    t,
                    n->no_wrap,
                )
            } else {
                self._op_form(
                    at,
                    k,
                    fn () { self.emit(n->lhs) },
                    fn () { self._value(n->rhs, t) },
                    t,
                )
            }

            s->spell(at, ")")
            return
        }

        var unsafe *bf = self._bitfield_chain(self._strip(n->lhs))
        if bf != &null {
            self._bitfield_form(
                n,
                bf,
                k,
                fn () {
                    if shift {
                        self.emit(n->rhs)
                    } else {
                        self._value(n->rhs, t)
                    }
                },
                t,
                false,
            )

            return
        }

        var d = self._bind_depth
        self._bind_depth += 1
        var p        = LowerTargets::wrap_tmp("p", d)
        var as_place = n->value_category == Expr::ValueCategory::LValue && self._stmt_node != n
        if as_place {
            s->spell(at, "(*")
        }

        self._form_open(at)
        s->spell(at, "auto& " + p + " = (")
        self.emit(n->lhs)
        s->spell(at, "); " + p + " = ")
        if shift {
            self._shift_form(
                at,
                k,
                fn () { s->spell(at, p) },
                fn () { self.emit(n->rhs) },
                t,
                n->no_wrap,
            )
        } else {
            self._op_form(
                at,
                k,
                fn () { s->spell(at, p) },
                fn () { self._value(n->rhs, t) },
                t,
            )
        }

        s->spell(at, ";")
        if self._stmt_node != n {
            s->spell(at, " ")
            self._form_value(at)
            s->spell(at, (if (as_place) => ("&") else => "") + p + ";")
        }

        self._form_close(at)
        if as_place {
            s->spell(at, ")")
        }

        self._bind_depth = d
    }

    /// `++` / `--` on an integer place. A local's prefix form (and its
    /// postfix one in statement position) is `(i = <i + 1>)`; a postfix
    /// whose value is read keeps the old value in a temporary; any other
    /// place is bound once, as _compound_form binds it.
    prot fn _incdec_form(self, n: unsafe *UnaryOperatorExpr) {
        var unsafe *t = n->operand->type_
        var        at = n->range
        var unsafe *s = self._cg->sink
        var k = if (n->op_token.kind == TokenKind::OpPlusPlus) => (TokenKind::OpPlus)
                else => TokenKind::OpMinus
        var ts   = self._spell._type(Speller::strip_ref(t))
        var stmt = self._stmt_node == n
        var old  = n->is_postfix() && !stmt
        var u    = self._spell.wrap_carrier(t)
        if self._is_local_place(n->operand) && !old {
            s->spell(at, "(")
            self.emit(n->operand)
            s->spell(at, " = ")
            self._op_form(
                at,
                k,
                fn () { self.emit(n->operand) },
                fn () { s->spell(at, "1") },
                t,
            )

            s->spell(at, ")")
            return
        }

        var unsafe *bf = self._bitfield_chain(self._strip(n->operand))
        if bf != &null {
            self._bitfield_form(
                n,
                bf,
                k,
                fn () { s->spell(at, "1") },
                t,
                n->is_postfix(),
            )

            return
        }

        var d = self._bind_depth
        self._bind_depth += 1
        var o        = LowerTargets::wrap_tmp("o", d)
        var as_place = !old && !stmt && n->value_category == Expr::ValueCategory::LValue
        if as_place {
            s->spell(at, "(*")
        }

        self._form_open(at)
        var p = LowerTargets::wrap_tmp("p", d)
        if self._is_local_place(n->operand) {
            // A local's postfix whose value is read: no place to bind.
            s->spell(at, ts + " " + o + " = ")
            self.emit(n->operand)
            s->spell(at, "; ")
            self.emit(n->operand)
            s->spell(at, " = ")
            self._op_form(
                at,
                k,
                fn () { self.emit(n->operand) },
                fn () { s->spell(at, "1") },
                t,
            )

            s->spell(at, "; ")
            self._form_value(at)
            s->spell(at, o + ";")
        } else {
            s->spell(at, "auto& " + p + " = (")
            self.emit(n->operand)
            s->spell(at, "); ")
            if old {
                s->spell(at, ts + " " + o + " = " + p + "; ")
            }

            s->spell(at, p + " = ")
            self._op_form(
                at,
                k,
                fn () { s->spell(at, p) },
                fn () { s->spell(at, "1") },
                t,
            )

            s->spell(at, ";")
            if !stmt {
                s->spell(at, " ")
                self._form_value(at)
                if old {
                    s->spell(at, o + ";")
                } else {
                    s->spell(at, (if (as_place) => ("&") else => "") + p + ";")
                }
            }
        }

        self._form_close(at)
        if as_place {
            s->spell(at, ")")
        }

        self._bind_depth = d
    }
}
