/// --- The Kairo Project ------------------ Sema/Verify/ArmOrderCheck.k --- ///
///
///   \brief Verify try-catch arm ordering.
///          an arm lexically after a bare `catch` can never fire, and two
///          bare `catch` arms can never both be meaningful.
///
///   \detail
///     The statement form only. In a try EXPRESSION a default arm is
///     terminal in the grammar: the parser rejects any arm after it
///     (S054E), and Sema never runs on a file with a syntax error.
///
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
        self.run(self.sc->tu)
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
                    // An error, not a dead-arm warning (Compiler/Spec/Panic.md#try-and-arms):
                    // the bare `catch` already handled everything, so the
                    // typed arm can only be a mistake.
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
                    )->child_first(bare_at)
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
}
