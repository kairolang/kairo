/// --- The Kairo Project ----------------- Sema/Check/ArrayIndexCheck.k --- ///
///
///   \brief A constant index past the end of a fixed array (SC291E).
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

import AST::Kind::ExprKind::ExprKind
import AST::Node::CanonicalNodes::canon_unqual
import AST::Node::Casting::{
    cast,
    isa,
}
import AST::Node::Expressions::SubscriptExpr
import AST::Node::Program::TopLevelKind
import AST::Node::Types::FixedArrayType
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Registry::DiagID
import Sema::Check::ConstEval::ConstEval
import Sema::SemaContext::SemaContext
import Sema::Type::TypeUtil::TypeUtil

pub class ArrayIndexCheck derives RecursiveASTVisitor<ArrayIndexCheck> {
    pub var  sc:  unsafe *SemaContext
    priv var _ce: ConstEval
    priv var _tu: TypeUtil

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

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); i++ {
            var item = *items->get(i)
            match item.kind {
                case TopLevelKind::Decl {
                    self.dispatch_decl(item.as_decl())
                } case TopLevelKind::Stmt {
                    self.dispatch_stmt(item.as_stmt())
                } case TopLevelKind::Expr {
                    self.dispatch_expr(item.as_expr())
                }
            }
        }
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
            return true
        }

        if (!c.neg) && c.mag < (len as u64) {
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
