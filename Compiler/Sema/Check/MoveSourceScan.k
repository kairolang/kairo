/// --- The Kairo Project ------------------ Sema/Check/MoveSourceScan.k --- ///
///
/// Whether the body of a move constructor ever changes its source parameter.
///
///   \detail
///     A move constructor of a class with a destructor that only reads
///     `other` (`self.p = other.p`) leaves two live owners: C++ containers
///     destroy the moved-from element too. The scan counts what it can
///     prove is a read (a field path of `other` that is neither assigned,
///     indexed into for a write, nor called through) and treats every other
///     mention of `other` as a possible write, so a body that hands `other`
///     to a call, takes its address or captures it never warns.
///
///   Phase: CHECK (after ExprTyper; reads resolved declarations)
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
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::FieldDecl
import AST::Node::Expressions::{
    AssignOperatorExpr,
    SubscriptExpr,
    UnaryOperatorExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Statements::CompoundStmt
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Token::TokenKind::TokenKind

/// The identifier a place expression is rooted at (`x`, `x.a`, `x.a[i]`,
/// `*x.p`, parentheses allowed); null for anything else.
fn place_root(e: unsafe *Expr) -> unsafe *Decl {
    var unsafe *x = strip_parens(e)
    while x != &null {
        var unsafe *ni = dyn_cast<NamedIdentExpr>(x)
        if ni != &null {
            return ni->resolved_decl
        }

        var unsafe *c = dyn_cast<ChainExpr>(x)
        if c != &null {
            x = strip_parens(c->base)
            continue
        }

        var unsafe *s = dyn_cast<SubscriptExpr>(x)
        if s != &null {
            x = strip_parens(s->base)
            continue
        }

        var unsafe *u = dyn_cast<UnaryOperatorExpr>(x)
        if u != &null {
            x = strip_parens(u->operand)
            continue
        }

        return &null
    }

    return &null
}

pub class MoveSourceScan derives RecursiveASTVisitor<MoveSourceScan> {
    pub var target: unsafe *Decl = &null
    /// An assignment whose target is rooted at the parameter.
    pub var wrote: bool = false
    /// Mentions of the parameter that are not a plain field read.
    pub var other_uses: u32 = 0

    fn MoveSourceScan(self, d: unsafe *Decl) {
        self.target = d
    }

    pub fn scan(self, body: unsafe *CompoundStmt) {
        self.dyn()->traverse_block(body)
    }

    /// True when the body may change the parameter.
    pub fn may_write(self) -> bool {
        return self.wrote || self.other_uses > 0
    }

    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        if n->resolved_decl == self.target {
            ++self.other_uses
        }

        return true
    }

    fn traverse_chain_expr(self, n: unsafe *ChainExpr) -> unsafe *ChainExpr {
        var unsafe *head = dyn_cast<NamedIdentExpr>(n->base)
        if head != &null && head->resolved_decl == self.target {
            var plain = true
            for var i: usize = 0; i < n->steps.size(); ++i {
                var unsafe *st = n->steps.get(i)
                if (st->access_kind != ChainExpr::AccessKind::Dot
                    && st->access_kind != ChainExpr::AccessKind::Arrow)
                    || st->resolved_decl == &null
                    || !isa<FieldDecl>(st->resolved_decl) {
                    plain = false
                }
            }

            if plain {
                return n
            }
        }

        return RecursiveASTVisitor<MoveSourceScan>::traverse_chain_expr(self, n)
    }

    fn traverse_assign_operator_expr(self, n: *AssignOperatorExpr) -> *AssignOperatorExpr {
        if place_root(n->lhs) != self.target {
            return RecursiveASTVisitor<MoveSourceScan>::traverse_assign_operator_expr(
                self,
                n,
            )
        }

        self.wrote = true
        return n
    }

    /// `&other.f` hands the field to a callee that may write it.
    fn traverse_unary_operator_expr(self, n: *UnaryOperatorExpr) -> *UnaryOperatorExpr {
        if n->op_token.kind == TokenKind::OpAmp && place_root(n->operand) == self.target {
            ++self.other_uses
            return n
        }

        return RecursiveASTVisitor<MoveSourceScan>::traverse_unary_operator_expr(
            self,
            n,
        )
    }
}
