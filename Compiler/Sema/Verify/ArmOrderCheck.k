/// --- The Kairo Project ------------------------ Sema/Verify/ArmOrderCheck.k --- ///
///
///   \brief Verify try-catch arm ordering.
///          an arm lexically after a bare `catch` can never fire, and two
///          bare `catch` arms can never both be meaningful.
///
///   \detail
///     `match` arms are not checked here: an arm that can never match is
///     PatternChecking's SC121E, which sees what every arm covers, not just
///     whether an earlier one is a catch-all.
///
///   Phase: VERIFY (pre-N)
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

import Sema::SemaContext::*;
import AST::Context::ASTContext::*;
import AST::Context::TranslationUnit::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::Statements::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Patterns::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::PatternKind::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Diagnostic::Registry::*;

class ArmOrderCheck derives RecursiveASTVisitor::<ArmOrderCheck> {
    pub var sc: *SemaContext;

    fn ArmOrderCheck(self, sc: *SemaContext) {
        self.sc = sc;
    }

    fn run(self) {
        var tu = self.sc->tu;
        
        if tu == &null { return; }
        if tu->program == &null { return; }
        
        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); i++ {
            var item = *(items->get(i));
            switch item.kind {
                case TopLevelKind::Decl { self.dispatch_decl(item.as_decl()); }
                case TopLevelKind::Stmt { self.dispatch_stmt(item.as_stmt()); }
                case TopLevelKind::Expr { self.dispatch_expr(item.as_expr()); }
                default { 0; }
            }
        }
    }

    fn visit_try_catch_stmt(self, n: *TryCatchStmt) -> bool {
        var catch_all_seen: bool = false;
        for var i: usize = 0; i < n->arms.size(); i++ {
            var arm = n->arms.get(i);
            if catch_all_seen {
                if arm->filter == &null {
                    self.sc->diag->report(DiagID::SC008E, arm->range.start,
                        "duplicate bare `catch`; a previous bare `catch` "
                        "already handles everything"
                    ).first(arm->range).emit();
                } else {
                    self.sc->diag->report(DiagID::SC009W, arm->range.start,
                        "unreachable catch arm; a previous bare `catch` "
                        "handles everything first"
                    ).first(arm->range).emit();
                }

                continue;
            }

            if arm->filter == &null {
                catch_all_seen = true;
            }
        }

        return true;
    }

    fn visit_try_catch_expr(self, n: *TryCatchExpr) -> bool {
        var catch_all_seen: bool = false;
        for var i: usize = 0; i < n->catch_arms.size(); i++ {
            var arm = n->catch_arms.get(i);
            if catch_all_seen {
                if arm->filter == &null {
                    self.sc->diag->report(DiagID::SC008E, arm->range.start,
                        "duplicate bare `catch`; a previous bare `catch` "
                        "already handles everything"
                    ).first(arm->range).emit();
                } else {
                    self.sc->diag->report(DiagID::SC009W, arm->range.start,
                        "unreachable catch arm; a previous bare `catch` "
                        "handles everything first"
                    ).first(arm->range).emit();
                }

                continue;
            }

            if arm->filter == &null {
                catch_all_seen = true;
            }
        }

        return true;
    }
}
