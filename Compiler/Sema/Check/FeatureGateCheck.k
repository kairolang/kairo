/// --- The Kairo Project --------------------- Sema/Check/FeatureGateCheck.k --- ///
///
///   \brief Reports constructs that type-check but have no lowering yet,
///          as one error each: "<construct> is not yet supported" (SC116E).
///
///   \detail
///     A lowering pass has no diagnostics of its own: by the time it runs,
///     every rejection has been made, and what it cannot render it ICEs on.
///     That is right for an invariant and wrong for a feature that is
///     simply unfinished, because lowering also runs under
///     --type-check-only and a well-typed program then aborts the compiler.
///     This pass is where "unfinished" is said to the user. An error here
///     stops the schedule before the lowerings, so the ICE in the lowering
///     stays an invariant: reaching it means this gate has a hole.
///
///     Gated:
///       - `for x in e` where X classified `e` as Vector, Set, Map or
///         String (RangedForStmt::iter_kind). IterLowering renders the
///         other kinds.
///
///     Reads the same guard IterLowering does: a poisoned or untyped
///     iterable is already diagnosed or dependent, and is not reported.
///
///     A gate is removed in the commit that lands its lowering.
///
///   Phase: CHECKS (last; needs X's iter_kind)
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
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::StmtKind::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Token::Token::*;
import Diagnostic::Registry::*;

class FeatureGateCheck derives RecursiveASTVisitor::<FeatureGateCheck> {
    pub var sc: *SemaContext;

    fn FeatureGateCheck(self, sc: *SemaContext) {
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

    fn visit_ranged_for_stmt(self, n: *RangedForStmt) -> bool {
        if n->iterable == &null { return true; }
        if n->iterable->is_poisoned() || (n->iterable->type_ == &null) { return true; }

        var what = "";
        switch n->iter_kind {
            case IterKind::Vector { what = "iterating a vector"; }
            case IterKind::Set    { what = "iterating a set"; }
            case IterKind::Map    { what = "iterating a map"; }
            case IterKind::String { what = "iterating a string"; }
            default               { return true; }
        }

        var b = self.sc->diag->report(DiagID::SC116E, n->iterable->range.start,
            f"{what} is not yet supported");
        b.first(n->iterable->range);
        b.emit();
        return true;
    }
}
