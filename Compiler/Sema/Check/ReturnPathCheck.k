/// --- The Kairo Project ------------------- Sema/Check/ReturnPathCheck.k --- ///
///
///   \brief Error when a value-returning function can reach its closing
///          brace, or a `-> !` function can.
///
///   \detail
///     Structural, not a CFG: one question asked of the statement tree,
///     "can control fall out of the bottom of this statement?". The answer
///     is FallThrough's (Sema/Check/ControlFlowAnalysis.k), which has the
///     rule per statement; the unreachable-code warning asks it too, so the
///     two can never disagree about what ends a path.
///
///   \par match counts only when it is exhaustive
///     Coverage is `MatchStmt::is_exhaustive`, written by PatternChecking,
///     which runs first. An exhaustive match falls through only when one of
///     its arms does. A non-exhaustive one is treated as NOT falling
///     through: it is already SC120E, and a missing return on top of it is
///     noise (the "conservative on unknowns" rule below).
///
///   \par Conservative on unknowns
///     A recovery node, an `inline` foreign block, `jump!`, and a match on a
///     scrutinee whose type is unknown are all treated as NOT falling
///     through (FallThrough with `unknown_ends_path`). Each of those either
///     already produced an error or hides control flow this pass cannot
///     see, and a missing-return on top of either is noise. Missing a real
///     bug there is the chosen trade.
///
///   \par Generators
///     `-> yield T` names what each `yield` produces; falling off the bottom
///     ends the sequence, so a generator body is never checked. Only the
///     written qualifier counts: a spelled-out `-> Yield<T>` is an ordinary
///     record return and is checked like any other.
///
///   \par What this is NOT
///     Unreachable-code warnings (ControlFlowAnalysis), definite
///     initialization, or an exhaustiveness diagnostic (PatternChecking).
///     This pass reads the match facts; it reports nothing about the match
///     itself.
///
///   Phase: CHECK (after ExprTyper: reads expression types; after
///          PatternChecking: reads MatchStmt::is_exhaustive)
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sema::SemaContext::*;
import Sema::Type::TypeUtil::*;
import Sema::Check::ControlFlowAnalysis::*;
import AST::Context::ASTContext::*;
import AST::Context::TranslationUnit::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Patterns::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Kind::StmtKind::*;
import AST::Kind::PatternKind::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Location::SourceRange::*;
import Token::Token::*;
import Diagnostic::Registry::*;

class ReturnPathCheck derives RecursiveASTVisitor::<ReturnPathCheck> {
    pub var sc: *SemaContext;
    priv var _tu: TypeUtil;
    priv var _ft: FallThrough;

    fn ReturnPathCheck(self, sc: *SemaContext) {
        self.sc  = sc;
        self._tu = TypeUtil(sc);
        self._ft = FallThrough(sc, true);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved);
        var tu = self.sc->tu;
        if tu == &null { return; }
        if tu->program == &null { return; }

        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); ++i {
            if self.stop { break; }
            var item = *(items->get(i));
            switch item.get_kind() {
                case TopLevelKind::Decl { self.dyn()->dispatch_decl(item.as_decl()); }
                case TopLevelKind::Stmt { self.dyn()->dispatch_stmt(item.as_stmt()); }
                case TopLevelKind::Expr { self.dyn()->dispatch_expr(item.as_expr()); }
            }
        }
    }

    // === entry points =====================================================

    fn visit_function_decl(self, n: *FunctionDecl) -> bool {
        if n == &null { return true; }
        if n->is_poisoned() { return true; }
        // A generator's `-> yield T` declares each YIELDED value, not a
        // returned one: falling off the end of a coroutine is how it ends.
        // X's fact, not a re-read of the return type.
        if n->is_generator { return true; }
        // An expression body IS its value; there is no bottom to fall off.
        if n->body_kind != FnBodyKind::Block { return true; }
        if n->body_block == &null { return true; }

        if n->is_noreturn {
            self._check(n->body_block, &null, true, (n->range) if (n->is_operator) else (n->name.range), n);
            return true;
        }
        // No annotation on a block body is `void` (StmtTyping), and a ctor /
        // dtor never carries one.
        if n->return_type == &null { return true; }
        self._check(n->body_block, n->return_type, false, n->return_type->range, n);
        return true;
    }

    fn visit_closure_expr(self, n: *ClosureExpr) -> bool {
        if n == &null { return true; }
        if n->body_kind != FnBodyKind::Block { return true; }
        if n->body_block == &null { return true; }
        if n->is_noreturn {
            self._check(n->body_block, &null, true, n->range, &null);
            return true;
        }
        // Inferred: the returns seen define the type, so there is nothing
        // declared for the bottom of the body to disagree with.
        if n->return_type == &null { return true; }
        if self._tu.is_generator_return(n->return_type) { return true; }    // see visit_function_decl.
        self._check(n->body_block, n->return_type, false, n->return_type->range, &null);
        return true;
    }

    /// Spelled only on the error path: an operator's `name` token is a
    /// sentinel, and resolving it asserts in TokenText.
    priv fn _subject(self, f: *FunctionDecl) -> string {
        if f == &null { return "this closure"; }
        if f->is_operator { return "this operator"; }
        return f"'{self._tu.decl_name(static_cast::<*Decl>(f))}\x27";
    }

    /// \p f is the function, or null for a closure; it names the subject.
    priv fn _check(self, body: *CompoundStmt, ret: *Type, noreturn: bool,
                   decl_at: SourceRange, f: *FunctionDecl) {
        var never = noreturn;
        if (!never) {
            var rc = ret->canonical;
            // Unresolved return type: T already reported it. A DEPENDENT one
            // with no canonical (`Foo<T>::Inner`) is still a value type --
            // never void, never `!` -- so falling off its end is reported.
            if (rc == &null) && (ret->is_poisoned() || (!ret->is_dependent())) { return; }
            if (rc != &null) && self._tu.is_void(rc) { return; }
            if (rc != &null) && self._tu.is_never(rc) { never = true; }
        }
        if !self._ft.falls_through(static_cast::<*Stmt>(body)) { return; }

        // `end` is exclusive; the closing brace is the byte before it.
        var brace = SourceRange::from_bounds(body->range.end.with_offset(-1), u32(1));
        var what  = self._subject(f);

        if never {
            var b = self.sc->diag->report(DiagID::SC105E, brace.start,
                f"{what} is declared to never return, but control can reach the end of its body");
            b.first(brace);
            b.note(DiagID::SC105N, decl_at.start,
                "declared '-> !' here; end the body with a 'panic', a call to another '-> !' function, or an infinite loop"
            ).first(decl_at);
            b.emit();
            return;
        }

        // A dependent type with no canonical has no spelling of its own.
        var ty = (f"'{self._tu.str(ret->canonical)}\x27") if (ret->canonical != &null) else ("a value");
        var b = self.sc->diag->report(DiagID::SC104E, brace.start,
            f"{what} does not return a value on all control paths");
        b.first(brace);
        b.note(DiagID::SC104N, decl_at.start,
            f"declared to return {ty} here; every path must end in 'return', 'panic', or a call that does not return"
        ).first(decl_at);
        b.emit();
    }
}
