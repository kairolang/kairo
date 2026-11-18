/// --- The Kairo Project --------------------- Sema/Check/TestDisarm.k --- ///
///
/// --test-disarm-moved-locals: a TEST HARNESS for the plumbing that
/// lets a provider skip a moved-from local's destructor.
///
///   \detail
///     Not the feature. Skipping the destructor of a moved-from local needs
///     an analysis that proves the local is definitely moved at every exit
///     that follows, and that analysis is not this file. This provider
///     exists so the plumbing it would use runs and is tested without one:
///     MoveCheck's real-transfer record (is_real_transfer), the one API
///     (disarm_local_at), CopyMoveLowering's mark on the cast, and EmitIR's
///     disarmed move. Every test that passes the switch says so.
///
///     It disarms a whole local whose move is a real transfer of it and its
///     only move, in straight-line code at the top level of the block that
///     declares it, decided by the shape of the code alone:
///
///       - every statement after the declaration is a declaration, an
///         expression or a `return` (no branch, loop, `try`, `match`,
///         jump, `panic` or `finally` block);
///       - the move is in one of them, not under the right operand of
///         `&&` / `||`, an `if` or `match` expression, a `try` or a
///         closure;
///       - nothing names the local after the move: no read, no store, no
///         `&`, no `finally()` (that statement names it once, at the move).
///
///     Whether the local's cleanup is then elided or flagged is the exit
///     check MoveCheck runs for `finally()` (LocalEnds::settle_disarms):
///     an exit before the move, a panic from a call there, is reached with
///     the object alive.
///
///   Phase: CHECK (MoveCheck, at each block's end and each body's end).
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
import AST::Kind::StmtKind::StmtKind
import AST::Node::Base::{
    Decl,
    Expr,
    Stmt,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
}
import AST::Node::Expressions::BinaryOperatorExpr
import AST::Node::PrimaryExpressions::NamedIdentExpr
import AST::Node::Statements::{
    CompoundStmt,
    DeclStmt,
}
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Sema::Check::LocalDisposition::LocalEnds
import Token::TokenKind::TokenKind

/// One statement's names of `target`, and where the move `site` is in it:
/// `depth` counts the constructs that run their operand on some paths
/// only (the right of `&&` / `||`, `if` / `match` / `try` expressions, a
/// closure body).
pub class DisarmScan derives RecursiveASTVisitor<DisarmScan> {
    pub var target:      unsafe *Decl = &null
    pub var site:        unsafe *Expr = &null
    pub var refs:        usize        = 0
    pub var found:       bool         = false
    pub var found_depth: usize        = 0
    pub var depth:       usize        = 0
    fn DisarmScan(self) { }

    fn dispatch_expr(self, e: unsafe *Expr) -> unsafe *Expr {
        if e == &null {
            return e
        }

        if e == self.site {
            self.found       = true
            self.found_depth = self.depth
        }

        if e->kind == ExprKind::NamedIdentExpr
            && cast<NamedIdentExpr>(e)->resolved_decl == self.target {
            self.refs += 1
        }

        if e->kind == ExprKind::BinaryOperatorExpr {
            var unsafe *bo = cast<BinaryOperatorExpr>(e)
            var        k   = bo->op_token.kind
            if k == TokenKind::OpAmpAmp || k == TokenKind::OpPipePipe {
                self.dispatch_expr(bo->lhs)
                self.depth += 1
                self.dispatch_expr(bo->rhs)
                self.depth -= 1
                return e
            }
        }

        var some_paths = e->kind == ExprKind::IfExpr
            || e->kind == ExprKind::MatchExpr
            || e->kind == ExprKind::TryCatchExpr
            || e->kind == ExprKind::ClosureExpr
        if some_paths {
            self.depth += 1
        }

        var unsafe *out = RecursiveASTVisitor<DisarmScan>::dispatch_expr(
            self,
            e,
        )

        if some_paths {
            self.depth -= 1
        }

        return out
    }
}

/// The statements the provider accepts after a declaration: no branch,
/// loop, `try`, `match`, jump, `panic` or `finally` block.
fn _straight(s: unsafe *Stmt) -> bool {
    return s != &null
        && (s->kind == StmtKind::DeclStmt
            || s->kind == StmtKind::ExpressionStmt
            || s->kind == StmtKind::ReturnStmt)
}

/// The block `b` ends: each candidate of `ends` that `b` declares is
/// accepted (LocalEndRow::disarm_ok) when the shape in the file header
/// holds, and ruled out otherwise.
pub fn test_disarm_scan(ends: unsafe *LocalEnds, b: unsafe *CompoundStmt) {
    for var r: usize = 0; r < ends->rows.size(); ++r {
        var *row = &ends->rows[r]
        if row->disarm_site == &null || row->disarm_bad || row->disarm_ok {
            continue
        }

        var unsafe *d = unsafe (row->d as unsafe *Decl)
        var        at = usize::MAX
        for var i: usize = 0; i < b->body.size(); ++i {
            var unsafe *ds = dyn_cast<DeclStmt>(b->body[i])
            if ds != &null && ds->decl == d {
                at = i
            }
        }

        if at == usize::MAX {
            continue
        }

        var ok   = true
        var seen = false
        for var i: usize = at + 1; i < b->body.size() && ok; ++i {
            if !_straight(b->body[i]) {
                ok = false
                break
            }

            var sc = DisarmScan()
            sc.target = d
            sc.site   = row->disarm_site
            sc.dispatch_stmt(b->body[i])
            if sc.found {
                // The move's own statement names the local once, at the move.
                ok   = !seen && sc.found_depth == 0 && sc.refs == 1
                seen = true
            } else if seen && sc.refs > 0 {
                ok = false
            }
        }

        ends->rows[r].disarm_ok  = ok && seen
        ends->rows[r].disarm_bad = !(ok && seen)
    }
}
