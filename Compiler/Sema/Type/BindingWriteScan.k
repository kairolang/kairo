/// --- The Kairo Project ---------------- Sema/Type/BindingWriteScan.k --- ///
///
/// Whether a variable can hold another value than its initializer.
///
///   \detail
///     A call through a local initialized with a closure literal takes the
///     literal's default arguments (CallTyping::_closure_defaults). They
///     belong to that literal, so they apply only while the variable cannot
///     hold another function: once it may, a short call is an arity error
///     rather than a call of some other function with the literal's values.
///
///     A write is an assignment whose target is the variable (or `*x`
///     where a closure holds it by pointer), `&x` (a pointer that can
///     write it, the `@inout` marker included; `const &x` cannot), and a
///     closure that holds it by pointer: `|*x|`, or `|*|` and the closure
///     names it. The scan runs over the whole region the variable is
///     visible in, so a write after the call counts too.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::ExprFacts::strip_parens
import AST::Node::Base::{
    Decl,
    Expr,
}
import AST::Node::Casting::dyn_cast
import AST::Node::Expressions::{
    AssignOperatorExpr,
    ClosureExpr,
    UnaryOperatorExpr,
}
import AST::Node::PrimaryExpressions::NamedIdentExpr
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Token::TokenKind::TokenKind

pub class BindingWriteScan derives RecursiveASTVisitor<BindingWriteScan> {
    pub var target:  unsafe *Decl = &null
    pub var written: bool         = false
    /// Token ids [start, end) of each `|*|` closure seen: a use of the
    /// target inside one is through a pointer that can write it.
    priv var _ptr_all: [u32]

    fn BindingWriteScan(self, d: unsafe *Decl) {
        self.target = d
    }

    /// `e` names the target, through parentheses and at most one `*`.
    priv fn _names(self, e: unsafe *Expr) -> bool {
        var unsafe *x = strip_parens(e)
        if x == &null {
            return false
        }

        var unsafe *u = dyn_cast<UnaryOperatorExpr>(x)
        if u != &null && u->op_token.kind == TokenKind::OpStar {
            x = strip_parens(u->operand)
        }

        var unsafe *ni = dyn_cast<NamedIdentExpr>(x)
        return ni != &null && ni->resolved_decl == self.target
    }

    fn visit_assign_operator_expr(self, n: *AssignOperatorExpr) -> bool {
        if self._names(n->lhs) {
            self.written = true
            self.stop    = true
        }

        return !self.written
    }

    fn visit_unary_operator_expr(self, n: *UnaryOperatorExpr) -> bool {
        if n->op_token.kind != TokenKind::OpAmp || n->const_addr {
            return true
        }

        var unsafe *ni = dyn_cast<NamedIdentExpr>(strip_parens(n->operand))
        if ni != &null && ni->resolved_decl == self.target {
            self.written = true
            self.stop    = true
        }

        return !self.written
    }

    fn visit_closure_expr(self, n: *ClosureExpr) -> bool {
        for var i: usize = 0; i < n->captures.size(); ++i {
            var unsafe *c = n->captures.get(i)
            if !c->by_ptr || c->is_const {
                continue
            }

            if c->name == &null {
                self._ptr_all.push(n->range.start.id)
                self._ptr_all.push(n->range.end.id)
            } else if c->name->resolved_decl == self.target {
                self.written = true
                self.stop    = true
            }
        }

        return !self.written
    }

    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        if n->resolved_decl != self.target {
            return true
        }

        var at = n->range.start.id
        for var i: usize = 0; i + 1 < self._ptr_all.size(); i += 2 {
            if at >= self._ptr_all[i] && at < self._ptr_all[i + 1] {
                self.written = true
                self.stop    = true
            }
        }

        return !self.written
    }
}
