/// --- The Kairo Project ----------------- Sema/Check/ReturnPathCheck.k --- ///
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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Kind::StmtKind::StmtKind
import AST::Node::Base::{
    Decl,
    Stmt,
    Type,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    FnBodyKind,
    FunctionDecl,
}
import AST::Node::Expressions::{
    CallExpr,
    ClosureExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Program::TopLevelKind
import AST::Node::Statements::{
    CompoundStmt,
    ExpressionStmt,
}
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Sema::Check::ControlFlowAnalysis::FallThrough
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::TypeUtil::TypeUtil

pub class ReturnPathCheck derives RecursiveASTVisitor<ReturnPathCheck> {
    pub var  sc:  unsafe *SemaContext
    priv var _tu: TypeUtil
    priv var _ft: FallThrough

    fn ReturnPathCheck(self, sc: unsafe *SemaContext) {
        self.sc  = sc
        self._tu = TypeUtil(sc)
        self._ft = FallThrough(sc, true)
    }

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

    /// # entry points

    fn visit_function_decl(self, n: unsafe *FunctionDecl) -> bool {
        if n == &null {
            return true
        }

        if n->is_poisoned() {
            return true
        }

        // A generator's `-> yield T` declares each YIELDED value, not a
        // returned one: falling off the end of a coroutine is how it ends.
        // X's fact, not a re-read of the return type.
        if n->is_generator {
            return true
        }

        // An expression body IS its value; there is no bottom to fall off.
        if n->body_kind != FnBodyKind::Block {
            return true
        }

        if n->body_block == &null {
            return true
        }

        if n->is_noreturn {
            self._check(
                n->body_block,
                &null,
                true,
                if (n->is_operator) => (n->range) else => n->name.range,
                n,
            )

            return true
        }

        // No annotation on a block body is `void` (StmtTyping), and a ctor /
        // dtor never carries one.
        if n->return_type == &null {
            return true
        }

        self._check(
            n->body_block,
            n->return_type,
            false,
            n->return_type->range,
            n,
        )

        return true
    }

    fn visit_closure_expr(self, n: unsafe *ClosureExpr) -> bool {
        if n == &null {
            return true
        }

        if n->body_kind != FnBodyKind::Block {
            return true
        }

        if n->body_block == &null {
            return true
        }

        if n->is_noreturn {
            self._check(n->body_block, &null, true, n->range, &null)
            return true
        }

        // Inferred: the returns seen define the type, so there is nothing
        // declared for the bottom of the body to disagree with.
        if n->return_type == &null {
            return true
        }

        if self._tu.is_generator_return(n->return_type) { // see visit_function_decl.
            return true
        }

        self._check(
            n->body_block,
            n->return_type,
            false,
            n->return_type->range,
            &null,
        )

        return true
    }

    /// Spelled only on the error path: an operator's `name` token is a
    /// sentinel, and resolving it asserts in TokenText.
    priv fn _subject(self, f: unsafe *FunctionDecl) -> string {
        if f == &null {
            return "this closure"
        }

        if f->is_operator {
            return "this operator"
        }

        return f"'{self._tu.decl_name((unsafe (f as unsafe *Decl)))}'"
    }

    /// The call a block ends in (`f(x)` as its last statement, through nested
    /// blocks); null when its last statement is anything else.
    priv fn _tail_call(self, body: unsafe *CompoundStmt) -> unsafe *CallExpr {
        var unsafe *b = body
        while b != &null {
            var s: unsafe *Stmt = &null
            for var i: usize = b->body.size(); i > 0; --i {
                if b->body[i - 1] != &null {
                    s = b->body[i - 1]
                    break
                }
            }

            if s == &null {
                return &null
            }

            if s->kind == StmtKind::CompoundStmt {
                b = cast<CompoundStmt>(s)
                continue
            }

            if s->kind != StmtKind::ExpressionStmt {
                return &null
            }

            var unsafe *e = self._tu.strip_parens(cast<ExpressionStmt>(s)->expr)
            return dyn_cast<CallExpr>(e)
        }

        return &null
    }

    /// The function a call names directly (`f(x)`, `a::f(x)`, `o.f(x)`);
    /// null for a call through a value.
    priv fn _callee_decl(self, call: unsafe *CallExpr) -> unsafe *FunctionDecl {
        if call == &null {
            return &null
        }

        var unsafe *c = self._tu.strip_parens(call->callee)
        if c == &null {
            return &null
        }

        if isa<NamedIdentExpr>(c) {
            return dyn_cast<FunctionDecl>(
                cast<NamedIdentExpr>(c)->resolved_decl,
            )
        }

        if isa<ChainExpr>(c) {
            var unsafe *ce = cast<ChainExpr>(c)
            if ce->steps.size() == 0 {
                return &null
            }

            return dyn_cast<FunctionDecl>(
                ce->steps.get(ce->steps.size() - 1)->resolved_decl,
            )
        }

        return &null
    }

    /// \p f is the function, or null for a closure; it names the subject.
    priv fn _check(self,
                   body:     unsafe *CompoundStmt,
                   ret:      unsafe *Type,
                   noreturn: bool,
                   decl_at:  SourceRange,
                   f:        unsafe *FunctionDecl) {
        var never = noreturn
        if !never {
            var unsafe *rc = ret->canonical
            // Unresolved return type: T already reported it. A DEPENDENT one
            // with no canonical (`Foo<T>::Inner`) is still a value type --
            // never void, never `!` -- so falling off its end is reported.
            if rc == &null && (ret->is_poisoned() || !ret->is_dependent()) {
                return
            }

            if rc != &null && self._tu.is_void(rc) {
                return
            }

            if rc != &null && self._tu.is_never(rc) {
                never = true
            }
        }

        if !self._ft.falls_through(body) {
            return
        }

        // `end` is exclusive; the closing brace is the byte before it.
        var brace = SourceRange::from_bounds(
            body->range.end.with_offset(-1),
            1 as u32,
        )

        var what = self._subject(f)

        if never {
            var b = self.sc->diag->report(
                DiagID::SC105E,
                brace.start,
                f"{what} is declared to never return, but control can reach the end of its body",
            )

            b.first(brace)
            b.note(
                DiagCode(DiagID::SC105N),
                decl_at.start,
                "declared '-> !' here; end the body with a 'panic', a call to another '-> !' function, or an infinite loop",
            )->child_first(decl_at)
            // A body that ENDS in a call to a header function reads as if it
            // ended the path; it does not, because the header never said the
            // function does not return (an imported decl is `-> !` only when
            // clang's isNoReturn() says so, DeclImport). Name that, in
            // Kairo's terms, rather than leave the user to wonder why the
            // call is not '!', or reach for the C++ to find out.
            var unsafe *call = self._tail_call(body)
            var unsafe *ff   = self._callee_decl(call)
            if ff != &null && ff->is_imported() && !ff->is_noreturn {
                var nm = self._tu.decl_name(ff)
                b.note(
                    DiagCode(DiagID::SC105N),
                    call->range.start,
                    f"'{nm}' is a C/C++ function its header does not declare '[[noreturn]]', so in Kairo this call returns and does not end the path",
                )->child_first(call->range)
                b.note(
                    DiagCode(DiagID::SC105N),
                    ff->range.start,
                    f"'{nm}' declared here; only a '-> !' function or a C/C++ function declared '[[noreturn]]' (or '_Noreturn') has type '!'",
                )->child_first(ff->range)
            }

            b.emit()
            return
        }

        // A dependent type with no canonical has no spelling of its own.
        var ty = if (ret->canonical != &null) => (f"'{self._tu.str(ret->canonical)}'")
                 else => "a value"
        var b = self.sc->diag->report(
            DiagID::SC104E,
            brace.start,
            f"{what} does not return a value on all control paths",
        )

        b.first(brace)
        b.note(
            DiagCode(DiagID::SC104N),
            decl_at.start,
            f"declared to return {ty} here; every path must end in 'return', 'panic', or a call that does not return",
        )->child_first(decl_at)
        b.emit()
    }
}
