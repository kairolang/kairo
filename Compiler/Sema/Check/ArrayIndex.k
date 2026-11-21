/// --- The Kairo Project ---------------------- Sema/Check/ArrayIndex.k --- ///
///
/// A constant index past the end of a fixed array (SC291E).
///
///   \detail
///     `var a: [i32; 2]` then `a[5] = 1` or `return a[7]`: the extent and
///     the index are both known here, and the access can only fail, so it
///     is an error at the index. Left to C++ it would be clang's C047W
///     at best, and the program read or wrote past the array.
///
///     Only a builtin subscript (no `op []`) on a canonical FixedArrayType
///     with a known extent, whose index ConstEval folds to an integer: a
///     generic extent (`[T; N]`), an index that is not a constant and a
///     slice (`a[1..9]`, a RangeExpr) are not this check's.
///
///     Runs after CtorInitCheck, which reports the same mistake in its own
///     terms (SC176E) for an element write that builds an array field and
///     poisons that subscript: a poisoned subscript is skipped here, so the
///     index is reported once.
///
///     Every other builtin subscript of a fixed array is checked at run
///     time (EmitIR::_subscript). This pass marks the ones it proves in
///     range, which need no check (SubscriptExpr::in_bounds): a constant
///     index below the extent, and the binder of an enclosing
///     `for i in lo..hi` / `lo..=hi` whose bounds are constants inside
///     `0..N`, when the body never writes the binder (BinderWriteScan:
///     an assignment, `++` / `--`, a mutable `&`, a mutating method).
///
///     SC363E is the same mistake made with a safe pointer: `p + k` or
///     `p - k` with a constant `k`, where `p` is `&a[c]` for a constant `c`
///     (in place, or the initializer of a local nothing assigns to, takes
///     the mutable address of, or steps), landing before `a[0]` or past one
///     past its end. Uses of a local are judged at the end of the pass,
///     once every write to it in the TU has been seen.
///
///   Phase: CHECK (after ExprTyper and CtorInitCheck).
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

import AST::DeclFacts::is_global_storage
import AST::Kind::ExprKind::ExprKind
import AST::Node::Base::{
    Decl,
    Expr,
    Stmt,
}
import AST::Node::CanonicalNodes::canon_unqual
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    IntConst,
    VariableDecl,
}
import AST::Node::Expressions::{
    AssignOperatorExpr,
    BinaryOperatorExpr,
    RangeExpr,
    SubscriptExpr,
    UnaryOperatorExpr,
}
import AST::Node::PrimaryExpressions::NamedIdentExpr
import AST::Node::Statements::{
    IterKind,
    RangedForStmt,
}
import AST::Node::Types::{
    FixedArrayType,
    PointerType,
}
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Registry::DiagID
import Sema::Check::ConstEval::ConstEval
import Sema::Check::Move::BinderWriteScan
import Sema::SemaContext::SemaContext
import Sema::Type::TypeUtil::TypeUtil
import Token::TokenKind::TokenKind

pub class ArrayIndexCheck derives RecursiveASTVisitor<ArrayIndexCheck> {
    pub var  sc:  unsafe *SemaContext
    priv var _ce: ConstEval
    priv var _tu: TypeUtil
    /// The binders of the bounded range loops seen so far, with the bound
    /// each stays below (`hi`, or `hi + 1` for `..=`), parallel. A binder
    /// is used only inside its own loop's body, so nothing is removed.
    priv var _loop_binder: [unsafe *Decl]
    priv var _loop_hi:     [u64]
    /// `p + k` on a local `p` (SC363E), judged once the pass has seen every
    /// write: the locals assigned, stepped or taken `&` of (_ptr_written).
    priv var _ptr_site:    [unsafe *BinaryOperatorExpr]
    priv var _ptr_written: [unsafe *Decl]

    fn ArrayIndexCheck(self, sc: unsafe *SemaContext) {
        self.sc  = sc
        self._ce = ConstEval(sc)
        self._tu = TypeUtil(sc)
    }

    fn run(self) {
        var unsafe *tu = self.sc->tu
        if tu == &null || tu->program == &null {
            return
        }

        self.run(tu)
        for var i: usize = 0; i < self._ptr_site.size(); ++i {
            self._check_offset(self._ptr_site[i], true)
        }
    }

    /// The fixed array of known extent `e` points into when it is `&a[c]`
    /// with a constant `c` in range, with `c` in `*at`; else null.
    priv fn _array_element(self, e: unsafe *Expr, at: unsafe *u64) -> unsafe *FixedArrayType {
        var unsafe *u = dyn_cast<UnaryOperatorExpr>(self._tu.strip_parens(e))
        if u == &null || u->op_token.kind != TokenKind::OpAmp || u->operand == &null {
            return &null
        }

        var unsafe *s = dyn_cast<SubscriptExpr>(
            self._tu.strip_parens(u->operand),
        )

        if s == &null || s->resolved_op != &null || s->base == &null || s->index == &null {
            return &null
        }

        if s->base->type_ == &null || s->index->kind == ExprKind::RangeExpr {
            return &null
        }

        var unsafe *bt = s->base->type_->canonical
        if bt == &null {
            bt = s->base->type_
        }

        var unsafe *a = dyn_cast<FixedArrayType>(canon_unqual(bt))
        if a == &null || a->is_incomplete || a->extent_param != &null {
            return &null
        }

        var c = self._ce.eval_int(s->index)
        if !c.ok || c.overflow || c.neg || c.mag >= (a->size_bits as u64) {
            return &null
        }

        *at = c.mag
        return a
    }

    /// The local variable `e` names, when it is one this check can follow:
    /// not a global or static, with an initializer.
    priv fn _local_pointer(self, e: unsafe *Expr) -> unsafe *VariableDecl {
        var unsafe *x = dyn_cast<NamedIdentExpr>(self._tu.strip_parens(e))
        if x == &null {
            return &null
        }

        var unsafe *v = dyn_cast<VariableDecl>(x->resolved_decl)
        if v == &null || v->init == &null || is_global_storage(v) {
            return &null
        }

        return v
    }

    /// The pointer operand of `n`, a builtin `p + k`, `k + p` or `p - k` on
    /// a safe pointer, else null.
    priv fn _pointer_operand(self, n: unsafe *BinaryOperatorExpr) -> unsafe *Expr {
        var k = n->op_token.kind
        if n->resolved_op != &null || n->lhs == &null || n->rhs == &null {
            return &null
        }

        if k != TokenKind::OpPlus && k != TokenKind::OpMinus {
            return &null
        }

        if self._safe_pointer(n->lhs) {
            return n->lhs
        }

        if k == TokenKind::OpPlus && self._safe_pointer(n->rhs) {
            return n->rhs
        }

        return &null
    }

    priv fn _safe_pointer(self, e: unsafe *Expr) -> bool {
        if e == &null || e->type_ == &null || e->type_->canonical == &null {
            return false
        }

        var unsafe *p = dyn_cast<PointerType>(canon_unqual(e->type_->canonical))
        return p != &null && !p->is_unsafe
    }

    /// Reports `n` when its constant offset leaves the array its pointer is
    /// an element of. `through_local`: the pointer may be a local whose
    /// initializer is the element (only once its writes are known).
    priv fn _check_offset(self, n: unsafe *BinaryOperatorExpr, through_local: bool) {
        var unsafe *p = self._pointer_operand(n)
        if p == &null {
            return
        }

        var unsafe *ke = if (p == n->lhs) => (n->rhs) else => n->lhs
        var        kc  = self._ce.eval_int(ke)
        if !kc.ok || kc.overflow {
            return
        }

        var        at:     u64 = 0
        var unsafe *origin     = p
        var unsafe *a          = self._array_element(p, unsafe &at)
        if a == &null && through_local {
            var unsafe *v = self._local_pointer(p)
            if v == &null {
                return
            }

            for var i: usize = 0; i < self._ptr_written.size(); ++i {
                if self._ptr_written[i] == unsafe (v as unsafe *Decl) {
                    return
                }
            }

            origin = v->init
            a      = self._array_element(v->init, unsafe &at)
        }

        if a == &null {
            return
        }

        var len = a->size_bits as u64
        var k   = kc.mag as i128
        if kc.neg != (n->op_token.kind == TokenKind::OpMinus) {
            k = -k
        }

        var r = (at as i128) + k
        if r >= 0 && r <= (len as i128) {
            return
        }

        var rc = IntConst()
        rc.ok  = true
        rc.neg = r < 0
        var m = if (rc.neg) => (-r) else => r
        rc.mag = if (m > (u64::MAX as i128)) => (u64::MAX) else => (m as u64)
        var b = self.sc->diag->report(
            DiagID::SC363E,
            n->range.start,
            f"offset {self._ce.str(rc)} is outside '{self._tu.str(a)}', which allows 0 to {len}",
        )

        b.first(n->range)
        b.note(
            origin->range.start,
            f"the pointer is element {at} of the array, here",
        )->child_first(origin->range)
        b.emit()
    }

    /// `p + k` on a safe pointer: judged now when the pointer is written in
    /// place, at the end of the pass when it is a local.
    fn visit_binary_operator_expr(self, n: *BinaryOperatorExpr) -> bool {
        var unsafe *p = self._pointer_operand(
            unsafe (n as unsafe *BinaryOperatorExpr),
        )

        if p == &null {
            return true
        }

        var at: u64 = 0
        if self._array_element(p, unsafe &at) != &null {
            self._check_offset(unsafe (n as unsafe *BinaryOperatorExpr), false)
        } else if self._local_pointer(p) != &null {
            self._ptr_site.push(unsafe (n as unsafe *BinaryOperatorExpr))
        }

        return true
    }

    /// A local written after its initializer, which then says nothing of
    /// where it points.
    priv fn _written(self, place: unsafe *Expr) {
        var unsafe *x = dyn_cast<NamedIdentExpr>(self._tu.strip_parens(place))
        if x != &null && x->resolved_decl != &null && self._safe_pointer(place) {
            self._ptr_written.push(x->resolved_decl)
        }
    }

    fn visit_assign_operator_expr(self, n: *AssignOperatorExpr) -> bool {
        self._written(n->lhs)
        return true
    }

    fn visit_unary_operator_expr(self, n: *UnaryOperatorExpr) -> bool {
        var k = n->op_token.kind
        if k == TokenKind::OpPlusPlus
            || k == TokenKind::OpMinusMinus
            || k == TokenKind::OpAmp && !n->const_addr {
            self._written(n->operand)
        }

        return true
    }

    /// Records `for i in lo..hi` whose binder stays inside `lo..hi`: both
    /// bounds constants, `lo` not negative, and the body never writes `i`.
    fn visit_ranged_for_stmt(self, n: *RangedForStmt) -> bool {
        if n->iter_kind != IterKind::RangeLit || n->bindings.size() != 1 || n->body == &null {
            return true
        }

        var unsafe *vd = n->bindings.get(0)->decl
        var unsafe *r  = dyn_cast<RangeExpr>(self._tu.strip_parens(n->iterable))
        if vd == &null || r == &null || r->begin == &null || r->end == &null {
            return true
        }

        var lo = self._ce.eval_int(r->begin)
        if !lo.ok || lo.overflow || lo.neg {
            return true
        }

        var hi = self._ce.eval_int(r->end)
        if !hi.ok || hi.overflow || hi.neg || (r->is_inclusive && hi.mag == u64::MAX) {
            return true
        }

        var scan = BinderWriteScan()
        scan.binders.push_back(unsafe (vd as unsafe *Decl))
        scan.dyn()->dispatch_stmt(unsafe (n->body as unsafe *Stmt))
        if scan.sites.size() > 0 {
            return true
        }

        self._loop_binder.push(unsafe (vd as unsafe *Decl))
        self._loop_hi.push(if (r->is_inclusive) => (hi.mag + 1) else => hi.mag)

        return true
    }

    /// The bound `e` stays below when it names a recorded loop binder,
    /// else u64::MAX.
    priv fn _binder_bound(self, e: unsafe *Expr) -> u64 {
        var unsafe *x = dyn_cast<NamedIdentExpr>(self._tu.strip_parens(e))
        if x == &null || x->resolved_decl == &null {
            return u64::MAX
        }

        for var i: usize = 0; i < self._loop_binder.size(); ++i {
            if self._loop_binder[i] == x->resolved_decl {
                return self._loop_hi[i]
            }
        }

        return u64::MAX
    }

    fn visit_subscript_expr(self, n: *SubscriptExpr) -> bool {
        if n->resolved_op != &null || n->is_poisoned() || n->index == &null || n->base == &null {
            return true
        }

        if n->base->type_ == &null || n->index->kind == ExprKind::RangeExpr {
            return true
        }

        var unsafe *bt = n->base->type_->canonical
        if bt == &null {
            bt = n->base->type_
        }

        bt = canon_unqual(bt)
        if bt == &null || !isa<FixedArrayType>(bt) {
            return true
        }

        var unsafe *a = cast<FixedArrayType>(bt)
        if a->is_incomplete || a->extent_param != &null {
            return true
        }

        var len = a->size_bits
        var c   = self._ce.eval_int(n->index)
        if !c.ok || c.overflow {
            if self._binder_bound(n->index) <= (len as u64) {
                n->in_bounds = true
            }

            return true
        }

        if (!c.neg) && c.mag < (len as u64) {
            n->in_bounds = true
            return true
        }

        var b = self.sc->diag->report(
            DiagID::SC291E,
            n->index->range.start,
            f"index {self._ce.str(c)} is out of range for '{self._tu.str(bt)}', which has {len} elements",
        )

        b.first(n->index->range)
        b.emit()
        return true
    }
}
