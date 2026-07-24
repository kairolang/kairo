/// --- The Kairo Project ------------------------ Sema/Verify/ArmOrderCheck.k --- ///
///
///   \brief Verify match / try-catch arm ordering.
///          an arm lexically after a catch-all arm can never fire, and two
///          catch-all arms can never both be meaningful.
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

    /// Irrefutable pattern: `_`, a bare un-ascribed binding (`case x`), or
    /// an alternation containing either.
    priv fn _is_irrefutable(self, p: *Pattern) -> bool {
        if p == &null { return false; }
        switch p->kind {
            case PatternKind::WildcardPattern { return true; }
            case PatternKind::BindingPattern {
                return cast::<BindingPattern>(p)->type_ == &null;
            } case PatternKind::AlternationPattern {
                var n = cast::<AlternationPattern>(p);
                for var i: usize = 0; i < n->alternatives.size(); i++ {
                    if self._is_irrefutable(*(n->alternatives.get(i))) { return true; }
                }

                return false;
            } default {
                return false;
            }
        }
    }

    /// Guardless `default`, or a guardless irrefutable alternative.
    priv fn _is_catch_all_case(self, mc: *MatchCase) -> bool {
        if mc->guard != &null { return false; }
        if mc->is_default { return true; }
        for var i: usize = 0; i < mc->patterns.size(); i++ {
            var p = *(mc->patterns.get(i));
            if self._is_irrefutable(p) {
                return true;
            }
        }

        return false;
    }

    priv fn _check_cases(self, cases: *FrozenList::<MatchCase>) {
        var catch_all_seen: bool = false;
        for var i: usize = 0; i < cases->size(); i++ {
            var mc = cases->get(i);
            if catch_all_seen {
                if self._is_catch_all_case(mc) {
                    self.sc->diag->report(DiagID::SC001E, mc->range.start,
                        "duplicate catch-all arm; a previous `default`/`_` arm "
                        "already matches everything"
                    ).first(mc->range).emit();
                } else {
                    self.sc->diag->report(DiagID::SC001W, mc->range.start,
                        "unreachable match arm; a previous `default`/`_` arm "
                        "matches everything first"
                    ).first(mc->range).emit();
                }

                continue;
            }

            if self._is_catch_all_case(mc) {
                catch_all_seen = true;
            }
        }
    }

    fn visit_match_stmt(self, n: *MatchStmt) -> bool {
        self._check_cases(&(n->cases));
        return true;
    }

    fn visit_match_expr(self, n: *MatchExpr) -> bool {
        self._check_cases(&(n->cases));
        return true;
    }

    fn visit_try_catch_stmt(self, n: *TryCatchStmt) -> bool {
        var catch_all_seen: bool = false;
        for var i: usize = 0; i < n->arms.size(); i++ {
            var arm = n->arms.get(i);
            if catch_all_seen {
                if arm->filter == &null {
                    self.sc->diag->report(DiagID::SC001E, arm->range.start,
                        "duplicate bare `catch`; a previous bare `catch` "
                        "already handles everything"
                    ).first(arm->range).emit();
                } else {
                    self.sc->diag->report(DiagID::SC001W, arm->range.start,
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
                    self.sc->diag->report(DiagID::SC001E, arm->range.start,
                        "duplicate bare `catch`; a previous bare `catch` "
                        "already handles everything"
                    ).first(arm->range).emit();
                } else {
                    self.sc->diag->report(DiagID::SC001W, arm->range.start,
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
