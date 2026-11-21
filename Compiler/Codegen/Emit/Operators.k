/// --- The Kairo Project --------------------- Codegen/Emit/Operators.k --- ///
///
///   EmitIR, part: operators. Unary, binary and assignment operators on
///   primitive operands, the operand forms only an instance can type (dependent
///   and duck-typed), and the compound spellings. A record operand is a call
///   OperatorLowering wrote, never an operator here.
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

import AST::DeclFacts::decl_generic_params
import AST::Kind::TypeKind::TypeKind
import AST::LangItems::LowerTargets
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    AssocType,
    BuiltinKind,
    BuiltinType,
    RecordType,
    builtin_info,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    EnumDecl,
    GenericParamKindBound,
    InterfaceDecl,
}
import AST::Node::Expressions::{
    AssignOperatorExpr,
    BinaryOperatorExpr,
    ParenExpr,
    REMAKE_DEAD,
    REMAKE_MAYBE,
    SubscriptExpr,
    UnaryOperatorExpr,
}
import AST::Node::PrimaryExpressions::IntegerLiteralExpr
import AST::Node::Types::{
    CXXLValueRefType,
    GenericParamType,
    PointerType,
}
import AST::OperatorFacts::OperatorFacts
import Codegen::Emit::Convert
import Codegen::Emit::Ctors
import Codegen::Emit::Decls
import Codegen::Emit::EmitIR::EmitIR
import Codegen::Emit::Exprs
import Codegen::Emit::Forms
import Codegen::Emit::Literals
import Codegen::Emit::Locals
import Codegen::Emit::Stmts
import Codegen::Spell::Spell::Speller
import Codegen::WrapForms::WrapForms
import Location::SourceRange::SourceRange
import Token::TokenKind::TokenKind

extend EmitIR {
    /// `e` has a `<T: type>` parameter's type: an operator on it is
    /// whatever the instance's type declares, a panicking user operator
    /// included, which the duck body cannot handle (as for a
    /// member call).
    prot fn _duck_operand(self, e: unsafe *Expr) -> bool {
        if e == &null || e->type_ == &null {
            return false
        }

        var unsafe *c = canon_unqual(e->type_)
        if c == &null || !isa<GenericParamType>(c) {
            return false
        }

        var unsafe *g = cast<GenericParamType>(c)
        if g->owner == &null {
            return false
        }

        var gps = decl_generic_params(g->owner)
        if (g->param_index as usize) >= gps.size() {
            return false
        }

        var unsafe *gp = gps[g->param_index as usize]
        return gp != &null && gp->kind_bound == GenericParamKindBound::Duck
    }

    /// A unary operator on a duck operand that is an operator call in the
    /// instance: not `&` / `*` (C++'s own on any T), not a mode marker or a
    /// materialized temporary, and not `++` / `--`, whose dependent form
    /// wraps T's own operator inside its lambda (_dep_update).
    prot fn _duck_unary(self, n: unsafe *UnaryOperatorExpr) -> bool {
        if n->is_mode_marker || n->materialize {
            return false
        }

        var k = n->op_token.kind
        if k == TokenKind::OpAmp || k == TokenKind::OpStar {
            return false
        }

        if k == TokenKind::OpPlusPlus || k == TokenKind::OpMinusMinus {
            return false
        }

        return self._duck_operand(n->operand)
    }

    /// A compound assignment on a duck operand that is not _dep_update's,
    /// which wraps T's own operator inside its lambda: `n += t` with an
    /// integer place. Plain `=` is a copy or a move, which never panics.
    prot fn _duck_compound(self, n: unsafe *AssignOperatorExpr) -> bool {
        if n->op_token.kind == TokenKind::OpEqual {
            return false
        }

        if self._dependent_arith(n->lhs->type_) {
            return false
        }

        return self._duck_operand(n->rhs)
    }

    /// A class, struct or union operand: a user operator that OperatorLowering
    /// must have rewritten. A plain enum is a RecordType too, and is NOT one:
    /// `==`, `<` and `as` on an `enum class` are C++'s own.
    /// An operator Sema deferred to the instance (OperatorTyping's
    /// dependent deferral: no resolved_op) on a DEPENDENT record operand --
    /// `self == other` on `Q<T>` inside `Q`'s own body. Which `operator==`
    /// it is depends on T, so clang picks it in each instantiation, as it
    /// does for a duck operand; the record's operators are emitted as C++
    /// operator members, so the plain spelling finds them.
    priv fn _deferred_record_op(self, rop: unsafe *Decl, a: unsafe *Expr, b: unsafe *Expr) -> bool {
        if rop != &null {
            return false
        }

        // An operand with no type at all is a duck-typed one (`self.dyn()->
        // prev().range` under a `<T: type>` mixin): the other side's
        // operator is chosen by clang per instance, the same as for a
        // dependent type.
        if a != &null && a->type_ == &null {
            return true
        }

        if b != &null && b->type_ == &null {
            return true
        }

        return self._dep_typed(a) || self._dep_typed(b)
    }

    priv fn _dep_typed(self, e: unsafe *Expr) -> bool {
        if e == &null || e->type_ == &null {
            return false
        }

        return e->type_->is_dependent() || e->type_->is_instantiation_dependent()
    }

    prot fn _record_operand(self, e: unsafe *Expr) -> bool {
        if e == &null || e->type_ == &null {
            return false
        }

        var unsafe *c = canon_unqual(e->type_)
        if c == &null || c->kind != TypeKind::RecordType {
            return false
        }

        var unsafe *d  = cast<RecordType>(c)->decl
        var unsafe *en = dyn_cast<EnumDecl>(d)
        if en != &null {
            return en->is_adt
        }

        return !isa<InterfaceDecl>(d)
    }

    /// `t` is a generic parameter (or a witness's member type) of the body:
    /// its arithmetic is decided per instance.
    priv fn _dependent_arith(self, t: unsafe *Type) -> bool {
        if t == &null || t->canonical == &null {
            return false
        }

        var unsafe *c = canon_unqual(t->canonical)
        return c != &null
            && (c->kind == TypeKind::GenericParamType || c->kind == TypeKind::AssocType)
    }

    /// `a OP b` on dependent operands: both bound, then the lambda.
    priv fn _dep_binary(self, at: SourceRange, k: TokenKind, a: fn(), b: fn()) {
        var d = self._bind_depth
        self._bind_depth += 1
        var        ta = LowerTargets::wrap_tmp("a", d)
        var        tb = LowerTargets::wrap_tmp("b", d)
        var unsafe *s = self._cg->sink
        self._form_open(at)
        s->spell(at, "auto&& " + ta + " = (")
        a()
        s->spell(at, "); ")
        s->spell(at, "auto&& " + tb + " = (")
        b()
        s->spell(at, "); ")
        self._form_value(at)
        s->spell(at, "[&]() { ")
        WrapForms::open(self._cg->sink, at, ta, d)
        WrapForms::int_arm(self._cg->sink, at, k, ta, tb, d)
        s->spell(at, "} else { return ")
        WrapForms::native(self._cg->sink, at, k, ta, tb)
        s->spell(at, "; } }();")
        self._form_close(at)
        self._bind_depth = d
    }

    /// A dependent place written by op `k` (`+=`, or `++`/`--` with `v`
    /// null): `({ auto& p = (place); [&]() { <int: p = wrap(p OP v)> else
    /// <p OP= v> }(); p; })`, the old value kept for a postfix that is read.
    priv fn _dep_update(self,
                        at:      SourceRange,
                        n:       unsafe *Expr,
                        place:   unsafe *Expr,
                        k:       TokenKind,
                        v:       unsafe *Expr,
                        incdec:  bool,
                        postfix: bool) {
        var d = self._bind_depth
        self._bind_depth += 1
        var        p        = LowerTargets::wrap_tmp("p", d)
        var        tb       = LowerTargets::wrap_tmp("b", d)
        var        o        = LowerTargets::wrap_tmp("o", d)
        var unsafe *s       = self._cg->sink
        var        stmt     = self._stmt_node == n
        var        old      = postfix && !stmt
        var        as_place = !old && !stmt && n->value_category == Expr::ValueCategory::LValue
        // T's own operator in the non-integer arm is a duck instance's
        // user operator when T is `: type`, and its result is discarded
        // here: wrapped as a duck member call is.
        var duck = self._duck_operand(place) || v != &null && self._duck_operand(v)
        if as_place {
            s->spell(at, "(*")
        }

        self._form_open(at)
        s->spell(at, "auto& " + p + " = (")
        self.emit(place)
        s->spell(at, "); ")
        if !incdec {
            s->spell(at, "auto&& " + tb + " = (")
            self.emit(v)
            s->spell(at, "); ")
        }

        if old {
            s->spell(at, "auto " + o + " = " + p + "; ")
        }

        s->spell(at, "[&]() { ")
        WrapForms::open(self._cg->sink, at, p, d)
        var uu  = LowerTargets::wrap_tmp("U", d)
        var one = "static_cast<" + uu + ">(1)"
        if incdec {
            var sym = if (k == TokenKind::OpPlus) => ("+") else => "-"
            s->spell(
                at,
                p.copy() + " = static_cast<" + LowerTargets::wrap_tmp(
                    "T",
                    d,
                ) + ">(static_cast<" + uu + ">(" + p + ") " + sym + " " + one + "); } else { ",
            )

            var incop = (if (k == TokenKind::OpPlus) => ("++") else => "--") + p
            if duck {
                incop = "(::" + LowerTargets::nopanic_call() + "(), " + incop + ")"
            }

            s->spell(at, incop + "; } }();")
        } else {
            // The integer arm returns the new value; the lambda stores it.
            s->spell(at, p.copy() + " = [&]() { ")
            WrapForms::int_arm(self._cg->sink, at, k, p, tb, d)
            s->spell(at, "}(); } else { ")
            var cop = p.copy() + " " + OperatorFacts::cxx_symbol(
                OperatorFacts::compound_of(k),
            ) + " " + tb
            if duck {
                cop = "(::" + LowerTargets::nopanic_call() + "(), " + cop + ")"
            }

            s->spell(at, cop + "; } }();")
        }

        if !stmt {
            s->spell(at, " ")
            self._form_value(at)
            if old {
                s->spell(at, o + ";")
            } else {
                s->spell(at, (if (as_place) => ("&") else => "") + p + ";")
            }
        }

        self._form_close(at)
        if as_place {
            s->spell(at, ")")
        }

        self._bind_depth = d
    }

    prot fn _unary(self, n: unsafe *UnaryOperatorExpr) {
        if n->is_mode_marker {
            self.emit(n->operand)
            return
        }

        if n->materialize {
            self._cg->sink->spell(
                n->range,
                "::" + LowerTargets::tmp_addr() + "(",
            )

            self.emit(n->operand)
            self._cg->sink->spell(n->range, ")")
            return
        }

        var unsafe *neg_lit = self._negated_int_lit(n)
        if neg_lit != &null {
            self._cg->sink->spell(
                n->range,
                self._int_text(
                    neg_lit->type_,
                    neg_lit->get_value_hi(),
                    neg_lit->get_value_lo(),
                    true,
                ),
            )

            return
        }

        var k             = n->op_token.kind
        var addr_or_deref = k == TokenKind::OpAmp || k == TokenKind::OpStar
        if self._record_operand(n->operand)
            && !addr_or_deref
            && !self._deferred_record_op(n->resolved_op, n->operand, &null) {
            self._ice(
                n->range,
                "EmitIR: user operator; OperatorLowering must rewrite it into a call",
            )
        }

        var incdec = k == TokenKind::OpPlusPlus || k == TokenKind::OpMinusMinus
        var negnot = n->is_prefix() && (k == TokenKind::OpMinus || k == TokenKind::OpTilde)
        if n->no_wrap && (!(incdec || negnot) || !self._wraps(n->operand->type_)) {
            self._ice(
                n->range,
                "EmitIR: no_wrap on an operator that has no wrap form",
            )
        }

        if !n->no_wrap && incdec && self._wraps(n->operand->type_) {
            self._incdec_form(n)
            return
        }

        if !n->no_wrap && incdec && self._dependent_arith(n->operand->type_) {
            self._dep_update(
                n->range,
                unsafe (n as unsafe *Expr),
                n->operand,
                if (k == TokenKind::OpPlusPlus) => (TokenKind::OpPlus) else => TokenKind::OpMinus,
                &null,
                true,
                n->is_postfix(),
            )

            return
        }

        // `-L` on a literal cannot overflow (the one that could, the minimum,
        // was _negated_int_lit's): C++'s own `-`.
        var unsafe *lit_opnd = n->operand
        while lit_opnd != &null && isa<ParenExpr>(lit_opnd) {
            lit_opnd = cast<ParenExpr>(lit_opnd)->inner
        }

        var neg_of_lit = k == TokenKind::OpMinus
            && lit_opnd != &null
            && isa<IntegerLiteralExpr>(lit_opnd)
        if !n->no_wrap && negnot && self._dependent_arith(n->operand->type_) {
            // `-a` is `0 - a` on the carrier; `~a` is its own (an integer's
            // `~` promotes, so the arm casts it back).
            var d = self._bind_depth
            self._bind_depth += 1
            var        ta = LowerTargets::wrap_tmp("a", d)
            var        tt = LowerTargets::wrap_tmp("T", d)
            var        uu = LowerTargets::wrap_tmp("U", d)
            var unsafe *s = self._cg->sink
            self._form_open(n->range)
            s->spell(n->range, "auto&& " + ta + " = (")
            self.emit(n->operand)
            s->spell(n->range, "); ")
            self._form_value(n->range)
            s->spell(n->range, "[&]() { ")
            WrapForms::open(self._cg->sink, n->range, ta, d)
            if k == TokenKind::OpMinus {
                s->spell(
                    n->range,
                    "return static_cast<" + tt + ">(static_cast<" + uu + ">(0) - static_cast<" + uu + ">(" + ta + ")); } else { return -" + ta + "; } }();",
                )
            } else {
                s->spell(
                    n->range,
                    "return static_cast<" + tt + ">(~static_cast<" + uu + ">(" + ta + ")); } else { return ~" + ta + "; } }();",
                )
            }

            self._form_close(n->range)
            self._bind_depth = d
            return
        }

        if !n->no_wrap
            && negnot
            && !neg_of_lit
            && self._wraps(n->type_)
            && self._wraps(n->operand->type_) {
            var ts = self._spell._type(Speller::strip_ref(n->type_))
            var u  = self._spell.wrap_carrier(n->type_)
            self._sc(n->range, ts)
            if k == TokenKind::OpMinus {
                self._sc(n->range, u)
                self._cg->sink->spell(n->range, "0) - ")
            } else {
                self._cg->sink->spell(n->range, "~")
            }

            self._sc(n->range, u)
            self.emit(n->operand)
            self._cg->sink->spell(n->range, "))")
            return
        }

        // `const &x` is `const T*` in C++ too: a bare `&x` is a `T*`, and
        // clang would pick a C++ overload on `T*` over the `const T*` one
        // Sema chose.
        var as_const = n->const_addr && n->type_ != &null
        if as_const {
            self._sc(n->range, self._spell._type(Speller::strip_ref(n->type_)))
        }

        self._cg->sink->spell(n->range, "(")
        if n->is_prefix() {
            self._cg->sink->create(n->op_token)
        }

        self.emit(n->operand)
        if n->is_postfix() {
            self._cg->sink->create(n->op_token)
        }

        self._cg->sink->spell(n->range, ")")
        if as_const {
            self._cg->sink->spell(n->range, ")")
        }
    }

    prot fn _binary(self, n: unsafe *BinaryOperatorExpr) {
        // `typeof T == U`: the operands are types, never values; clang
        // answers the comparison, per instance in a template.
        if n->type_cmp_lhs != &null {
            var neg = if (n->op_token.kind != TokenKind::OpEqualEqual) => ("!") else => ""
            var ls  = self._spell._type(n->type_cmp_lhs)
            var rs  = self._spell._type(n->type_cmp_rhs)
            self._cg->sink->spell(
                n->range,
                "(" + neg + "__is_same(" + ls + ", " + rs + "))",
            )

            return
        }

        if n->op_token.kind == TokenKind::OpEqualEqualEqual {
            self._ice(n->range, "EmitIR: `===`; CoalesceLowering owns it")
        }

        if (self._record_operand(n->lhs) || self._record_operand(n->rhs))
            && !self._deferred_record_op(n->resolved_op, n->lhs, n->rhs) {
            self._ice(
                n->range,
                "EmitIR: user operator; OperatorLowering must rewrite it into a call",
            )
        }

        var k     = n->op_token.kind
        var shift = k == TokenKind::OpLessLess || k == TokenKind::OpGreaterGreater
        var ints = if (shift) => (self._wraps_shift(n->type_) && self._wraps_shift(n->lhs->type_))
                   else => (self._wraps(n->type_)
                       && self._wraps(n->lhs->type_)
                       && self._wraps(n->rhs->type_))
        if n->no_wrap && ints && shift {
            // A count proven in [0, W) (SHIFT spec §4): no mask. A constant
            // count past the width is Sema's error, so reaching here with
            // one is a setter's bug.
            var unsafe *cnt = dyn_cast<IntegerLiteralExpr>(self._strip(n->rhs))
            if cnt != &null
                && (cnt->get_value_hi() != (0 as u64)
                    || cnt->get_value_lo() >= (Speller::int_width(n->type_) as u64)) {
                self._ice(
                    n->range,
                    "EmitIR: no_wrap on a shift with an out-of-range constant count",
                )
            }

            self._shift_form(
                n->range,
                k,
                fn () { self.emit(n->lhs) },
                fn () { self.emit(n->rhs) },
                n->type_,
                true,
            )

            return
        }

        if n->no_wrap {
            var nw_ok = ints
                && (k == TokenKind::OpPlus || k == TokenKind::OpMinus || k == TokenKind::OpStar)
            if !nw_ok {
                self._ice(
                    n->range,
                    "EmitIR: no_wrap on an operator that has no wrap form",
                )
            }
        } else if ints && self._has_wrap_form(k, n->type_) {
            self._op_form(
                n->range,
                k,
                fn () { self.emit(n->lhs) },
                fn () { self.emit(n->rhs) },
                n->type_,
            )

            return
        } else if self._dependent_arith(n->lhs->type_)
            && (shift || self._dependent_arith(n->rhs->type_))
            && (k == TokenKind::OpPlus
                || k == TokenKind::OpMinus
                || k == TokenKind::OpStar
                || k == TokenKind::OpSlash
                || k == TokenKind::OpPercent
                || shift) {
            self._dep_binary(
                n->range,
                k,
                fn () { self.emit(n->lhs) },
                fn () { self.emit(n->rhs) },
            )

            return
        }

        if self._derived_dependent_op(
            n->resolved_op,
            n->lhs,
            n->rhs,
            self._compound_op_of_binary(k),
        ) {
            // `a + b` where an operand is the instance's: its type may define
            // only `op +=`, which OperatorLowering would have derived `+`
            // from, and C++ has no such `operator+`. The result is built
            // from `a` as it was passed: a temporary moves, so a MOVE type,
            // which has no copy, is not copied.
            var unsafe *s = self._cg->sink
            // Parenthesized: as a subscript index, `v[[](...)]` opens a C++ attribute.
            s->spell(
                n->range,
                "([](auto&& __ka, auto&& __kb) { if constexpr (requires { __ka ",
            )

            s->create(n->op_token)
            s->spell(n->range, " __kb; }) { return (__ka ")
            s->create(n->op_token)
            s->spell(
                n->range,
                " __kb); } else { auto __kt = static_cast<decltype(__ka)&&>(__ka); __kt " + OperatorFacts::cxx_symbol(
                    self._compound_op_of_binary(k),
                ) + " __kb; return __kt; } }(",
            )

            self.emit(n->lhs)
            s->spell(n->range, ", ")
            self.emit(n->rhs)
            s->spell(n->range, "))")
            return
        }

        if k == TokenKind::OpLessEqualGreater
            && self._cmp3_scalar(n->lhs->type_)
            && self._cmp3_scalar(n->rhs->type_) {
            // A primitive `<=>` is the Ordering lang item (OperatorTyping),
            // but C++'s answers a `std::strong_ordering`, which converts to no
            // enum. The sign of that one result picks the variant
            // (-1 / 0 / 1, Lib/builtin/base/ordering.k): each operand is
            // evaluated once and the lambda stays constant-evaluable.
            // Parenthesized: as a subscript index, `v[[](...)]` opens a C++ attribute.
            var unsafe *s = self._cg->sink
            s->spell(
                n->range,
                "([](auto __kr) { return static_cast<" + self._spell._type(
                    n->type_,
                ) + ">((__kr > 0) - (__kr < 0)); }((",
            )

            self._operand(n->lhs, n->rhs)
            s->create(n->op_token)
            self._operand(n->rhs, n->lhs)
            s->spell(n->range, ")))")
            return
        }

        self._cg->sink->spell(n->range, "(")
        self._operand(n->lhs, n->rhs)
        self._cg->sink->create(n->op_token)
        self._operand(n->rhs, n->lhs)
        self._cg->sink->spell(n->range, ")")
    }

    /// Operand `e` of a builtin binary operator whose other operand is
    /// `other`. An f8e4m3 / f8e5m2 beside a wider float is widened to it
    /// (the conversion lattice's W) in so many words: the f8 formats are
    /// classes in C++, where `a + w` would weigh the class's `operator+`
    /// against the built-in one and find the call ambiguous. Every other
    /// pair of operands is C++'s own promotion, the same one.
    priv fn _operand(self, e: unsafe *Expr, other: unsafe *Expr) {
        if other != &null && self._f8(e->type_) && !self._f8(other->type_) {
            var unsafe *o = Speller::strip_ref(other->type_)
            if o != &null
                && isa<BuiltinType>(o)
                && builtin_info(cast<BuiltinType>(o)->builtin)->is_float() {
                self._value(e, o)
                return
            }
        }

        self.emit(e)
    }

    priv fn _f8(self, t: unsafe *Type) -> bool {
        var unsafe *c = Speller::strip_ref(t)
        if c == &null || !isa<BuiltinType>(c) {
            return false
        }

        var b = cast<BuiltinType>(c)->builtin
        return b == BuiltinKind::F8E4M3 || b == BuiltinKind::F8E5M2
    }

    /// An arithmetic or bitwise binary operator `k` as its compound form's
    /// kind, or TkUnknown for any other (a comparison, a logical operator).
    priv fn _compound_op_of_binary(self, k: TokenKind) -> TokenKind {
        match k {
            case TokenKind::OpLessLess, TokenKind::OpGreaterGreater, TokenKind::KwXor,
                 TokenKind::KwBitand,   TokenKind::KwBitor {
                return TokenKind::TkUnknown
            } default {
                return OperatorFacts::compound_of(k)
            }
        }
    }

    /// An operator no Sema rule bound (`ro` null) whose operand the instance
    /// types: left as written, it needs the C++ operator its type may not
    /// declare, the second of the pair OperatorLowering derives from. `ck`
    /// is the compound twin, TkUnknown for an operator with none.
    priv fn _derived_dependent_op(self,
                                  ro: unsafe *Decl,
                                  a:  unsafe *Expr,
                                  b:  unsafe *Expr,
                                  ck: TokenKind) -> bool {
        if ro != &null || ck == TokenKind::TkUnknown {
            return false
        }

        return self._unknown_typed(a) || self._unknown_typed(b)
    }

    priv fn _unknown_typed(self, e: unsafe *Expr) -> bool {
        if e == &null {
            return false
        }

        var unsafe *t = e->type_
        return t == &null || t->is_dependent() || t->is_instantiation_dependent()
    }

    prot fn _assign(self, n: unsafe *AssignOperatorExpr) {
        if (n->remake & (REMAKE_DEAD | REMAKE_MAYBE)) != 0 {
            self._remake(n)
            return
        }

        // S_pre's `self.x = e` fills x's slot: `init` for a const field (its
        // one assignment, CtorInitCheck), `put` for a `var` one, which S_pre
        // may assign again.
        if self._ci_pre && n->op_token.kind == TokenKind::OpEqual && n->ci_elem_init {
            // `self.f[k] = e` that builds element k of an array field built
            // element by element (CtorInitCheck): the element does not exist
            // yet, so it is constructed in the slot, not assigned. In place,
            // so e runs exactly where it is written.
            var unsafe *sub = dyn_cast<SubscriptExpr>(n->lhs)
            var        esi  = usize::MAX
            if sub != &null {
                var unsafe *ef = self._self_field(sub->base)
                if ef != &null {
                    esi = self._slot_of(ef, true)
                }
            }

            if esi == usize::MAX {
                self._ice(
                    n->range,
                    "EmitIR: an element write that builds a field with no slot; CtorInitCheck gate failure",
                )

                return
            }

            self._cg->sink->spell(
                n->range,
                LowerTargets::ctor_slot_arg() + "." + self._slot_name(
                    esi,
                ) + "." + LowerTargets::ctor_slot_init_at() + "(",
            )

            self.emit(sub->index)
            self._cg->sink->spell(n->range, ", ")
            self._value(n->rhs, n->lhs->type_)
            self._cg->sink->spell(n->range, ")")
            return
        }

        if self._ci_pre && n->op_token.kind == TokenKind::OpEqual {
            var unsafe *f = self._self_field(n->lhs)
            // A base's field exists in S_pre (the base is built first): it
            // is assigned in place.
            if f != &null && self._inherited_field(f) {
                f = &null
            }

            if f != &null {
                var si = self._slot_of(f, true)
                if si == usize::MAX {
                    self._ice(
                        n->range,
                        "EmitIR: S_pre assigns a field with no slot; CtorInitCheck gate failure",
                    )
                }

                // An array is written once (CtorInitCheck), and its slot has
                // no `put`: an array has no `=`.
                var once = f->is_const() || self._array_extent(f->type_) != usize::MAX
                var put_fn = "." + (if (once) => (LowerTargets::ctor_slot_init())
                                    else => LowerTargets::ctor_slot_put()) + "("
                self._cg->sink->spell(
                    n->range,
                    LowerTargets::ctor_slot_arg() + "." + self._slot_name(si) + put_fn,
                )

                // A base's field is declared in the base's terms (a generic
                // base's `T`); the target's own type is the one to convert to.
                var unsafe *vt = f->type_
                if n->lhs->type_ != &null && self._inherited_field(f) {
                    vt = n->lhs->type_
                }

                self._value(n->rhs, vt)
                self._cg->sink->spell(n->range, ")")
                return
            }
        }

        // Plain `=` on records is copy/move assignment; CopyMoveLowering
        // decides which. Compound assignment on a record is a user operator.
        if n->op_token.kind != TokenKind::OpEqual {
            if self._record_operand(n->lhs) || self._record_operand(n->rhs) {
                self._ice(
                    n->range,
                    "EmitIR: compound assignment on a record; OperatorLowering owns it",
                )
            }

            var ck     = self._compound_op(n->op_token.kind)
            var cshift = ck == TokenKind::OpLessLess || ck == TokenKind::OpGreaterGreater
            if ck != TokenKind::TkUnknown
                && (if (cshift) => (self._wraps_shift(n->lhs->type_))
                    else => (self._wraps(n->lhs->type_) && self._wraps(n->rhs->type_))) {
                self._compound_form(n, ck)
                return
            }

            if ck != TokenKind::TkUnknown && self._wide_float(n->lhs->type_) {
                self._wide_compound(n, ck)
                return
            }

            if ck != TokenKind::TkUnknown
                && self._dependent_arith(n->lhs->type_)
                && (cshift || self._dependent_arith(n->rhs->type_)) {
                self._dep_update(
                    n->range,
                    unsafe (n as unsafe *Expr),
                    n->lhs,
                    ck,
                    n->rhs,
                    false,
                    false,
                )

                return
            }
        }

        // Through a C++ reference (`v[0] = x` of an imported container,
        // whose `operator[]` returns `T&`) the value written is a T: a
        // converted right side is cast to the referee, never to the
        // reference, which a temporary cannot bind.
        var unsafe *want = n->lhs->type_
        if want != &null && want->canonical != &null && isa<CXXLValueRefType>(want->canonical) {
            want = cast<CXXLValueRefType>(want->canonical)->referee
        }

        // `p += n` on a pointer: n is the integer offset C++ scales by
        // sizeof T (OperatorTyping::_type_pointer_op), never a value of the
        // pointer's type, so it is not converted to it.
        if n->op_token.kind != TokenKind::OpEqual
            && want != &null
            && want->canonical != &null
            && isa<PointerType>(canon_unqual(want->canonical)) {
            self._cg->sink->spell(n->range, "(")
            self.emit(n->lhs)
            self._cg->sink->create(n->op_token)
            self.emit(n->rhs)
            self._cg->sink->spell(n->range, ")")
            return
        }

        var ck2 = n->op_token.kind
        var arith_eq = ck2 == TokenKind::OpPlusEqual
            || ck2 == TokenKind::OpMinusEqual
            || ck2 == TokenKind::OpStarEqual
            || ck2 == TokenKind::OpSlashEqual
            || ck2 == TokenKind::OpPercentEqual
            || ck2 == TokenKind::OpAmpEqual
            || ck2 == TokenKind::OpPipeEqual
            || ck2 == TokenKind::OpCaretEqual
        if arith_eq && n->resolved_op == &null && self._unknown_typed(n->lhs) {
            // `a |= b` on the instance's type: C++ has the compound operator
            // only if the type declares it (an enum never does), and Kairo
            // takes `a = a | b` from the plain one.
            var unsafe *s = self._cg->sink
            s->spell(
                n->range,
                "([](auto& __ka, auto&& __kb) -> decltype(auto) { if constexpr (requires { __ka ",
            )

            s->create(n->op_token)
            s->spell(n->range, " __kb; }) { return (__ka ")
            s->create(n->op_token)
            s->spell(
                n->range,
                " __kb); } else { __ka = __ka " + OperatorFacts::cxx_symbol(
                    OperatorFacts::compound_base(ck2),
                ) + " __kb; return (__ka); } }(",
            )

            self.emit(n->lhs)
            s->spell(n->range, ", ")
            self._value(n->rhs, want)
            s->spell(n->range, "))")
            return
        }

        self._cg->sink->spell(n->range, "(")
        self.emit(n->lhs)
        self._cg->sink->create(n->op_token)
        self._value(n->rhs, want)
        self._cg->sink->spell(n->range, ")")
    }
}
