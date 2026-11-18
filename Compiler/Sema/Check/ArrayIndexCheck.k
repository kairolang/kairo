/// --- The Kairo Project ----------------- Sema/Check/ArrayIndexCheck.k --- ///
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
import AST::Node::Expressions::{
    RangeExpr,
    SubscriptExpr,
}
import AST::Node::PrimaryExpressions::NamedIdentExpr
import AST::Node::Statements::{
    IterKind,
    RangedForStmt,
}
import AST::Node::Types::FixedArrayType
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Registry::DiagID
import Sema::Check::ConstEval::ConstEval
import Sema::Check::MoveCheck::BinderWriteScan
import Sema::SemaContext::SemaContext
import Sema::Type::TypeUtil::TypeUtil

pub class ArrayIndexCheck derives RecursiveASTVisitor<ArrayIndexCheck> {
    pub var  sc:  unsafe *SemaContext
    priv var _ce: ConstEval
    priv var _tu: TypeUtil
    /// The binders of the bounded range loops seen so far, with the bound
    /// each stays below (`hi`, or `hi + 1` for `..=`), parallel. A binder
    /// is used only inside its own loop's body, so nothing is removed.
    priv var _loop_binder: cxx::std::vector<unsafe *Decl>
    priv var _loop_hi:     cxx::std::vector<u64>

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

        self._loop_binder.push_back(unsafe (vd as unsafe *Decl))
        self._loop_hi.push_back(
            if (r->is_inclusive) => (hi.mag + 1) else => hi.mag,
        )

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
