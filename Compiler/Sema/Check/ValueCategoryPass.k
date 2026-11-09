/// --- The Kairo Project --------------- Sema/Check/ValueCategoryPass.k --- ///
///
///   \brief VERIFY that every typed expression carries a value category.
///
///   \detail
///     The categories are ASSIGNED inline, by ExprTyper, as it types, and not
///     here. The reason is the one consumer that exists: overload resolution
///     reads each argument's category (does it bind `T&&` or `const T&`?)
///     while ExprTyper is still typing the call around it. A pass after
///     typing would hand the category to nobody who needs it in time.
///
///     Where ExprTyper assigns them:
///       the arm    identifiers, chains, subscripts, parens, assignments --
///                  the kinds whose category is whatever they NAME.
///       finish()   everything else (ExprTyper::_default_category): a C++
///                  reference-typed expression is its referent (`T&` an
///                  lvalue, `T&&` an xvalue), and every other kind only ever
///                  makes a new value, a prvalue.
///
///     This pass checks the first row is total: a typed, unpoisoned
///     expression still Unknown is an arm that returned a type without
///     deciding. ICE, not a diagnostic -- nothing the user wrote causes it,
///     and a category silently defaulted to prvalue is a wrong overload
///     picked with no error anywhere.
///
///   Phase: CHECK, straight after ExprTyper.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

ffi "c++" import "Native/Types.hh"

import AST::Node::Base::Expr
import AST::Node::Program::TopLevelKind
import AST::Printer::ASTPrinter::expr_kind_name
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}

pub class ValueCategoryPass derives RecursiveASTVisitor<ValueCategoryPass> {
    pub var sc:        *SemaContext
    pub var n_checked: usize        = 0

    fn ValueCategoryPass(self, sc: *SemaContext) {
        self.sc = sc
    }

    /// PRE: ExprTyper ran (its phase is TypesResolved: Checked is advanced
    /// only when the whole check stage returns).
    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved)
        var unsafe *tu = self.sc->tu
        if tu == &null {
            return
        }

        if tu->program == &null {
            return
        }

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); ++i {
            if self.stop {
                break
            }

            var item = *items->get(i)
            match item.get_kind() {
                case TopLevelKind::Decl {
                    self.dyn()->dispatch_decl(item.as_decl())
                } case TopLevelKind::Stmt {
                    self.dyn()->dispatch_stmt(item.as_stmt())
                } case TopLevelKind::Expr {
                    self.dyn()->dispatch_expr(item.as_expr())
                }
            }
        }
    }

    fn visit_expr(self, n: unsafe *Expr) -> bool {
        if n == &null {
            return true
        }

        if n->type_ == &null || n->is_poisoned() { // untyped / unknown / diagnosed: nothing to classify.
            return true
        }

        self.n_checked += 1
        if n->value_category != Expr::ValueCategory::Unknown {
            return true
        }

        var msg = f"ValueCategoryPass: a typed {expr_kind_name(n->kind)} has no value category; its ExprTyper arm returned a type without deciding one"
        kairo::std::ice_fail(msg)
    }
}
