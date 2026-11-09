/// --- The Kairo Project ------------------ Sema/Verify/ArmOrderCheck.k --- ///
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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

import AST::Node::Expressions::TryCatchExpr
import AST::Node::Program::TopLevelKind
import AST::Node::Statements::TryCatchStmt
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Sema::SemaContext::SemaContext

pub class ArmOrderCheck derives RecursiveASTVisitor<ArmOrderCheck> {
    pub var sc: *SemaContext

    fn ArmOrderCheck(self, sc: *SemaContext) {
        self.sc = sc
    }

    fn run(self) {
        var unsafe *tu = self.sc->tu

        if tu == &null {
            return
        }

        if tu->program == &null {
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

    fn visit_try_catch_stmt(self, n: *TryCatchStmt) -> bool {
        var catch_all_seen: bool = false
        var bare_at              = SourceRange::invalid()
        for var i: usize = 0; i < n->arms.size(); i++ {
            var unsafe *arm = n->arms.get(i)
            if catch_all_seen {
                if arm->filter == &null {
                    self.sc->diag->report(
                        DiagID::SC008E,
                        arm->range.start,
                        "duplicate bare `catch`; a previous bare `catch` "
                        "already handles everything",
                    ).first(arm->range)->emit()
                } else {
                    // An error, not SC009W's warning (Compiler/Spec/Panic.md#try-and-arms): the
                    // bare `catch` already handled everything, so the typed
                    // arm can only be a mistake. Placeholder code until the
                    // sweep (SC009 has only a warning).
                    var b = self.sc->diag->report(
                        DiagID::SC240E,
                        arm->range.start,
                        "no 'catch' arm may follow a bare 'catch': it already handles everything",
                    )

                    b.first(arm->range)
                    b.note(
                        DiagCode(DiagID::SC240N),
                        bare_at.start,
                        "the bare 'catch' is here",
                    )->first(bare_at)
                    b.remove(arm->range, "remove the arm")
                    b.emit()
                }

                continue
            }

            if arm->filter == &null {
                catch_all_seen = true
                bare_at        = arm->range
            }
        }

        return true
    }

    fn visit_try_catch_expr(self, n: *TryCatchExpr) -> bool {
        var catch_all_seen: bool = false
        for var i: usize = 0; i < n->catch_arms.size(); i++ {
            var unsafe *arm = n->catch_arms.get(i)
            if catch_all_seen {
                if arm->filter == &null {
                    self.sc->diag->report(
                        DiagID::SC008E,
                        arm->range.start,
                        "duplicate bare `catch`; a previous bare `catch` "
                        "already handles everything",
                    ).first(arm->range)->emit()
                } else {
                    self.sc->diag->report(
                        DiagID::SC009W,
                        arm->range.start,
                        "unreachable catch arm; a previous bare `catch` "
                        "handles everything first",
                    ).first(arm->range)->emit()
                }

                continue
            }

            if arm->filter == &null {
                catch_all_seen = true
            }
        }

        return true
    }
}
