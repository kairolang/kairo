/// --- The Kairo Project ----------------------- Sema/Check/MoveCheck.k --- ///
///
///   \brief `@move` arguments: the type must be movable, and the moved-from
///          binding may not be read again until it is reassigned.
///
///   \detail
///     (a) At a call whose parameter is `@move`, the argument's type must be
///         movable (ClassLifecycle::facts_of). Error naming the type and why.
///
///     (b) Use after move. When the `@move` argument is a bare local or
///         parameter, that binding is MOVED-FROM from that point: any later
///         READ in the same function body is an error; a plain assignment
///         `x = e` clears it; at a join, moved on either path means moved.
///
///     Intraprocedural only, bindings only: a move through a pointer, a
///     field, a capture, or into another function is out of scope and stays
///     AMT's (Stage 2). A `@move` of `self`, of a field, or of a temporary
///     records nothing.
///
///   \par Flow
///     The walk is the RAV's, with dispatch_expr / dispatch_stmt overridden
///     for the constructs that fork or end a path: if/match/try (stmt and
///     expr forms), `&&`/`||`, loops, return/break/continue/panic. Everything
///     else falls through to the base traversal, whose children route back
///     here. A loop body is walked TWICE, the second time with the back edge
///     joined in, so a move on iteration one that is read on iteration two
///     is seen; diagnostics are deduplicated by (binding, use). A path that
///     has returned is `dead` and contributes nothing to a join.
///
///   \par Which parameter is `@move`
///     The callee is the promoted decl (CallTyping wrote it) or a
///     fn-pointer type. Arguments map positionally, skipping a bound
///     receiver, by name for named arguments; a pack tail is by value.
///
///   Phase: CHECK, after ClassLifecycle, which it reads.
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
import Sema::Resolve::NameLookup::*;
import Sema::Type::TypeUtil::*;
import Sema::Check::ClassLifecycle::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::ASTSupport::*;
import AST::ParamMode::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Kind::ExprKind::*;
import AST::Kind::StmtKind::*;
import AST::Kind::TypeKind::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Location::SourceRange::*;
import Token::TokenKind::*;
import Diagnostic::Registry::*;

__inline_cpp("
#define RecursiveASTVisitor_MoveCheck RecursiveASTVisitor<MoveCheck>
");

/// The moved-from set on one path. `dead` after return/break/continue/panic:
/// the path has left the block and contributes nothing to a join.
class MoveState {
    pub var moved: vec::<*Decl>;
    pub var at:    vec::<SourceRange>;   ///< parallel: where each was moved.
    pub var dead:  bool = false;
    /// Bindings already reported used-after-move on this path. One error per
    /// BINDING, not per read: three reads of one moved `e` in a loop are one
    /// mistake, and three errors for it is the cascade the poison rule exists
    /// to prevent. Travels with the flow state -- so a reassignment (clear)
    /// re-arms it, a join unions it, and a loop's back edge carries it.
    pub var reported: vec::<*Decl>;
    fn MoveState(self) { }

    fn was_reported(self, d: *Decl) -> bool {
        for var i: usize = 0; i < self.reported.size(); ++i {
            if self.reported[i] == d { return true; }
        }
        return false;
    }

    fn index_of(self, d: *Decl) -> usize {
        for var i: usize = 0; i < self.moved.size(); ++i {
            if self.moved[i] == d { return i; }
        }
        return usize(-1);
    }

    /// First move wins: the note points at where it happened first.
    fn mark(self, d: *Decl, where_: SourceRange) {
        if self.index_of(d) != usize(-1) { return; }
        self.moved.push_back(d);
        self.at.push_back(where_);
    }

    /// A reassignment: \p d holds a live value again, and a later move-then-use
    /// of it is a NEW mistake that must be reported, so its report is dropped
    /// along with the move.
    fn clear(self, d: *Decl) {
        for var r: usize = 0; r < self.reported.size(); ++r {
            if self.reported[r] == d { self.reported.erase(self.reported.begin() + r); break; }
        }
        var i = self.index_of(d);
        if i == usize(-1) { return; }
        self.moved.erase(self.moved.begin() + i);
        self.at.erase(self.at.begin() + i);
    }
}

/// Moved on either path means moved. A dead path defers to the live one.
fn move_join(a: MoveState, b: MoveState) -> MoveState {
    if a.dead { return b; }
    if b.dead { return a; }
    var out = a;
    for var i: usize = 0; i < b.moved.size(); ++i {
        if out.index_of(b.moved[i]) == usize(-1) {
            out.moved.push_back(b.moved[i]);
            out.at.push_back(b.at[i]);
        }
    }
    // Reported on either path stays reported: re-reporting after the join
    // would be the second error for the mistake one branch already named.
    for var i: usize = 0; i < b.reported.size(); ++i {
        if !out.was_reported(b.reported[i]) { out.reported.push_back(b.reported[i]); }
    }
    return out;
}

/// One enclosing loop: the states at each `break` / `continue` inside it.
class LoopFrame {
    pub var breaks:    vec::<MoveState>;
    pub var continues: vec::<MoveState>;
    fn LoopFrame(self) { }
}

class MoveCheck derives RecursiveASTVisitor::<MoveCheck> {
    pub var sc: *SemaContext;
    pub var lc: *ClassLifecycle;
    priv var _tu:    TypeUtil;
    priv var _st:    MoveState;
    priv var _loops: vec::<LoopFrame>;
    pub var n_moves:   usize = 0;
    pub var n_errored: usize = 0;

    fn MoveCheck(self, sc: *SemaContext, lc: *ClassLifecycle) {
        self.sc  = sc;
        self.lc  = lc;
        self._tu = TypeUtil(sc);
    }

    /// PRE: TypesResolved (ExprTyper has run in this stage: callees promoted,
    /// arguments typed).
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
                case TopLevelKind::Expr { self.dispatch_expr(item.as_expr()); }
            }
        }
    }

    // === bodies ==============================================================

    /// A function body starts clean and leaves nothing behind.
    fn traverse_function_decl(self, n: *FunctionDecl) -> *FunctionDecl {
        if n == &null { return n; }
        var saved_st    = self._st;
        var saved_loops = self._loops;
        self._st    = MoveState{};
        self._loops = vec::<LoopFrame>();
        var out = RecursiveASTVisitor_MoveCheck::traverse_function_decl(n);
        self._st    = saved_st;
        self._loops = saved_loops;
        return out;
    }

    /// Captures are reads in the ENCLOSING body (a moved-from binding cannot
    /// be captured); the closure body is its own body.
    fn traverse_closure_expr(self, n: *ClosureExpr) -> *ClosureExpr {
        if n == &null { return n; }
        if self.dyn()->walkup_closure_expr(n) == false { return n; }
        for var i: usize = 0; i < n->captures.size(); ++i {
            var cap = n->captures.get(i);
            if cap->name != &null { self.dispatch_expr(cap->name); }
        }
        var saved_st    = self._st;
        var saved_loops = self._loops;
        self._st    = MoveState{};
        self._loops = vec::<LoopFrame>();
        for var i: usize = 0; i < n->params.size(); ++i { self.dyn()->dispatch_decl(*(n->params.get(i))); }
        if n->body_block != &null { self.dyn()->traverse_block(n->body_block); }
        if n->body_expr  != &null { self.dispatch_expr(n->body_expr); }
        self._st    = saved_st;
        self._loops = saved_loops;
        return n;
    }

    // === expressions =========================================================

    fn dispatch_expr(self, e: *Expr) -> *Expr {
        if e == &null { return e; }
        if self.stop  { return e; }

        switch e->kind {
            case ExprKind::NamedIdentExpr {
                self._read(cast::<NamedIdentExpr>(e));
                return RecursiveASTVisitor_MoveCheck::dispatch_expr(e);
            }
            case ExprKind::AssignOperatorExpr {
                var asn = cast::<AssignOperatorExpr>(e);
                // `x = e`: the value first (it may read x), then x is whole again.
                if (asn->op_token.kind == TokenKind::OpEqual) && (asn->lhs != &null) {
                    var lhs = self._tu.strip_parens(asn->lhs);
                    if (lhs != &null) && isa::<NamedIdentExpr>(lhs) {
                        var d = cast::<NamedIdentExpr>(lhs)->resolved_decl;
                        if (d != &null) && self._tracked(d) {
                            if asn->rhs != &null { self.dispatch_expr(asn->rhs); }
                            self._st.clear(d);
                            return e;
                        }
                    }
                }
                return RecursiveASTVisitor_MoveCheck::dispatch_expr(e);
            }
            case ExprKind::BinaryOperatorExpr {
                var bo = cast::<BinaryOperatorExpr>(e);
                var k  = bo->op_token.kind;
                if (k == TokenKind::OpAmpAmp) || (k == TokenKind::OpPipePipe) {
                    // The right operand runs on one path only.
                    if bo->lhs != &null { self.dispatch_expr(bo->lhs); }
                    var before = self._st;
                    if bo->rhs != &null { self.dispatch_expr(bo->rhs); }
                    self._st = move_join(before, self._st);
                    return e;
                }
                return RecursiveASTVisitor_MoveCheck::dispatch_expr(e);
            }
            case ExprKind::CallExpr { self._call(cast::<CallExpr>(e)); return e; }
            case ExprKind::IfExpr   { self._if_expr(cast::<IfExpr>(e)); return e; }
            case ExprKind::MatchExpr {
                var m = cast::<MatchExpr>(e);
                if m->scrutinee != &null { self.dispatch_expr(m->scrutinee); }
                self._arms_start();
                for var i: usize = 0; i < m->cases.size(); ++i {
                    self._arm_begin();
                    self.dyn()->traverse_match_case(m->cases.get(i));
                    self._arm_end();
                }
                self._arms_finish(false);
                return e;
            }
            case ExprKind::TryCatchExpr {
                var t = cast::<TryCatchExpr>(e);
                var before = self._st;
                if t->try_expr != &null { self.dispatch_expr(t->try_expr); }
                var after_try = self._st;
                // A catch arm may run after any prefix of the try: its entry
                // is the join of before and after.
                var entry = move_join(before, after_try);
                var acc = after_try;
                for var i: usize = 0; i < t->catch_arms.size(); ++i {
                    var arm = t->catch_arms.get(i);
                    self._st = entry;
                    if arm->body != &null { self.dispatch_expr(arm->body); }
                    acc = move_join(acc, self._st);
                }
                self._st = acc;
                return e;
            }
            default { return RecursiveASTVisitor_MoveCheck::dispatch_expr(e); }
        }
    }

    priv fn _if_expr(self, n: *IfExpr) {
        if n->condition != &null { self.dispatch_expr(n->condition); }
        self._arms_start();
        self._arm_begin();
        if n->then_expr != &null { self.dispatch_expr(n->then_expr); }
        self._arm_end();
        for var i: usize = 0; i < n->else_ifs.size(); ++i {
            var arm = n->else_ifs.get(i);
            self._arm_begin();
            if arm->condition != &null { self.dispatch_expr(arm->condition); }
            if arm->body      != &null { self.dispatch_expr(arm->body); }
            self._arm_end();
        }
        var has_else = n->else_expr != &null;
        if has_else {
            self._arm_begin();
            self.dispatch_expr(n->else_expr);
            self._arm_end();
        }
        self._arms_finish(!has_else);
    }

    // --- arm bookkeeping: N alternatives from one entry state ---------------

    priv var _arm_entry: vec::<MoveState>;   ///< stack: entry state per open arm set.
    priv var _arm_acc:   vec::<MoveState>;   ///< stack: accumulated exit per open arm set.
    priv var _arm_any:   vec::<bool>;

    priv fn _arms_start(self) {
        self._arm_entry.push_back(self._st);
        var dead = MoveState{};
        dead.dead = true;
        self._arm_acc.push_back(dead);
        self._arm_any.push_back(false);
    }

    priv fn _arm_begin(self) {
        self._st = self._arm_entry[self._arm_entry.size() - 1];
    }

    priv fn _arm_end(self) {
        var top = self._arm_acc.size() - 1;
        self._arm_acc[top] = move_join(self._arm_acc[top], self._st);
        self._arm_any[top] = true;
    }

    /// \p fallthrough: the construct may run no arm at all (an `if` with no
    /// `else`), so the entry state is one of the paths.
    priv fn _arms_finish(self, fallthrough: bool) {
        var top   = self._arm_acc.size() - 1;
        var acc   = self._arm_acc[top];
        var entry = self._arm_entry[top];
        var any   = self._arm_any[top];
        self._arm_acc.pop_back();
        self._arm_entry.pop_back();
        self._arm_any.pop_back();
        if fallthrough || (!any) { acc = move_join(acc, entry); }
        self._st = acc;
    }

    // === statements ==========================================================

    fn dispatch_stmt(self, s: *Stmt) -> *Stmt {
        if s == &null { return s; }
        if self.stop  { return s; }

        switch s->kind {
            case StmtKind::ConditionalStmt {
                var n = cast::<ConditionalStmt>(s);
                if n->cond != &null { self.dispatch_expr(n->cond); }
                self._arms_start();
                self._arm_begin();
                self.dyn()->traverse_block(n->then_);
                self._arm_end();
                var has_else = n->else_ != &null;
                if has_else {
                    self._arm_begin();
                    self.dispatch_stmt(n->else_);
                    self._arm_end();
                }
                self._arms_finish(!has_else);
                return s;
            }
            case StmtKind::WhileLoopStmt {
                var n = cast::<WhileLoopStmt>(s);
                self._loop(n->cond, n->body, &null);
                return s;
            }
            case StmtKind::LoopStmt {
                var n = cast::<LoopStmt>(s);
                self._loop(&null, n->body, &null);
                return s;
            }
            case StmtKind::RangedForStmt {
                var n = cast::<RangedForStmt>(s);
                if n->iterable != &null { self.dispatch_expr(n->iterable); }
                self._loop(&null, n->body, &null);
                return s;
            }
            case StmtKind::IndexedForStmt {
                var n = cast::<IndexedForStmt>(s);
                if n->init != &null { self.dispatch_stmt(n->init); }
                self._loop(n->cond, n->body, n->update);
                return s;
            }
            case StmtKind::MatchStmt {
                var n = cast::<MatchStmt>(s);
                if n->scrutinee != &null { self.dispatch_expr(n->scrutinee); }
                self._arms_start();
                for var i: usize = 0; i < n->cases.size(); ++i {
                    self._arm_begin();
                    self.dyn()->traverse_match_case(n->cases.get(i));
                    self._arm_end();
                }
                self._arms_finish(false);
                return s;
            }
            case StmtKind::TryCatchStmt {
                var n = cast::<TryCatchStmt>(s);
                var before = self._st;
                self.dyn()->traverse_block(n->try_body);
                var after_try = self._st;
                var entry = move_join(before, after_try);
                var acc = after_try;
                for var i: usize = 0; i < n->arms.size(); ++i {
                    var arm = n->arms.get(i);
                    self._st = entry;
                    if arm->body != &null { self.dispatch_stmt(arm->body); }
                    acc = move_join(acc, self._st);
                }
                self._st = acc;
                return s;
            }
            case StmtKind::ReturnStmt {
                var n = cast::<ReturnStmt>(s);
                if n->value != &null { self.dispatch_expr(n->value); }
                self._st.dead = true;
                return s;
            }
            case StmtKind::PanicStmt {
                var n = cast::<PanicStmt>(s);
                if n->payload != &null { self.dispatch_expr(n->payload); }
                self._st.dead = true;
                return s;
            }
            case StmtKind::BreakStmt {
                if !self._loops.empty() { self._loops[self._loops.size() - 1].breaks.push_back(self._st); }
                self._st.dead = true;
                return s;
            }
            case StmtKind::ContinueStmt {
                if !self._loops.empty() { self._loops[self._loops.size() - 1].continues.push_back(self._st); }
                self._st.dead = true;
                return s;
            }
            default { return RecursiveASTVisitor_MoveCheck::dispatch_stmt(s); }
        }
    }

    /// Two passes over the body: the second starts from the join of the
    /// entry state and the first pass's exit, so a move on iteration one is
    /// visible to a read on iteration two. `continue` states join the back
    /// edge; `break` states join the exit. The exit is reachable without
    /// entering the body at all (a false condition), so the entry state is
    /// a path too.
    priv fn _loop(self, cond: *Expr, body: *CompoundStmt, update: *Expr) {
        var entry = self._st;
        self._loops.push_back(LoopFrame{});

        var exit1 = self._loop_pass(cond, body, update);
        self._st = move_join(entry, exit1);
        var head = self._st;
        var exit2 = self._loop_pass(cond, body, update);

        var fr = self._loops[self._loops.size() - 1];
        self._loops.pop_back();

        var out = move_join(head, exit2);
        out = move_join(out, entry);
        for var i: usize = 0; i < fr.breaks.size(); ++i { out = move_join(out, fr.breaks[i]); }
        self._st = out;
    }

    /// One walk of cond -> body -> update, from the current state; returns
    /// the back-edge state (body exit joined with every `continue`).
    priv fn _loop_pass(self, cond: *Expr, body: *CompoundStmt, update: *Expr) -> MoveState {
        var top = self._loops.size() - 1;
        self._loops[top].continues.clear();
        if cond != &null { self.dispatch_expr(cond); }
        self.dyn()->traverse_block(body);
        var back = self._st;
        for var i: usize = 0; i < self._loops[top].continues.size(); ++i {
            back = move_join(back, self._loops[top].continues[i]);
        }
        self._st = back;
        if update != &null { self.dispatch_expr(update); }
        return self._st;
    }

    // === calls ===============================================================

    priv fn _call(self, n: *CallExpr) {
        if n->callee != &null { self.dispatch_expr(n->callee); }

        var f  = self._callee_decl(n->callee);
        var fp: *FunctionPointerType = &null;
        if (f == &null) && (n->callee != &null) && (n->callee->type_ != &null) {
            var t = canon_unqual(self._tu.strip_nullable(n->callee->type_));
            if (t != &null) && isa::<FunctionPointerType>(t) { fp = cast::<FunctionPointerType>(t); }
        }

        // The parameter view a positional argument indexes: the declared
        // params minus a receiver bound through `obj.m(...)`.
        var view = vec::<*ParamDecl>();
        if f != &null {
            var bound_recv = f->is_method() && self._callee_binds_receiver(n->callee);
            for var i: usize = 0; i < f->params.size(); ++i {
                var p = f->params[i];
                if p == &null { continue; }
                if p->is_self && bound_recv { continue; }
                view.push_back(p);
            }
        }

        var pos: usize = 0;
        for var i: usize = 0; i < n->args.size(); ++i {
            var a = n->args[i];
            if a == &null { continue; }
            var value = named_call_arg_value(a);
            var e     = (value) if (value != &null) else (a);

            var mode = ParamMode::Value;
            var p: *ParamDecl = &null;
            if f != &null {
                if value != &null {
                    var nm = self.sc->ctx->get_spelling(cast::<NamedIdentExpr>(cast::<AssignOperatorExpr>(a)->lhs)->name);
                    for var j: usize = 0; j < view.size(); ++j {
                        if self._tu.param_name(view[j]) == nm { p = view[j]; break; }
                    }
                } else if pos < view.size() {
                    p = view[pos];
                    pos += 1;
                } else if f->is_variadic && (view.size() > 0) {
                    p = &null;                              // a pack tail is by value.
                }
                if p != &null { mode = p->mode; }
            } else if fp != &null {
                if i < fp->modes.size() { mode = fp->modes[i]; }
            }

            self.dispatch_expr(e);                          // reads inside the argument, in order.
            if mode == ParamMode::Move { self._move_arg(e); }
        }
    }

    /// The FunctionDecl a callee denotes after CallTyping's promotion, or null.
    priv fn _callee_decl(self, callee: *Expr) -> *FunctionDecl {
        var c = self._tu.strip_parens(callee);
        if c == &null { return &null; }
        if isa::<NamedIdentExpr>(c) {
            return dyn_cast::<FunctionDecl>(cast::<NamedIdentExpr>(c)->resolved_decl);
        }
        if isa::<ChainExpr>(c) {
            var ce = cast::<ChainExpr>(c);
            if ce->steps.size() == 0 { return &null; }
            var last = ce->steps.get(ce->steps.size() - 1);
            return dyn_cast::<FunctionDecl>(last->resolved_decl);
        }
        return &null;
    }

    /// `obj.m(...)` / `p->m(...)` bind the receiver; `Type::m(obj, ...)` does not.
    priv fn _callee_binds_receiver(self, callee: *Expr) -> bool {
        var c = self._tu.strip_parens(callee);
        if (c == &null) || (!isa::<ChainExpr>(c)) { return false; }
        var ce = cast::<ChainExpr>(c);
        if ce->steps.size() == 0 { return false; }
        var last = ce->steps.get(ce->steps.size() - 1);
        return last->access_kind != ChainExpr::AccessKind::ColonColon;
    }

    /// (a) movability of the type; (b) the binding becomes moved-from.
    priv fn _move_arg(self, e: *Expr) {
        if e->is_poisoned() { return; }
        self.n_moves += 1;

        if e->type_ != &null {
            var c  = canon_unqual(e->type_);
            var rd = self._tu.record_decl(c);
            if rd != &null {
                var facts = self.lc->facts_of(rd);
                if !facts->movable {
                    var b = self.sc->diag->report(DiagID::SC001E, e->range.start,
                        f"cannot move a value of type '{self._tu.str(c)}': {facts->why_not_movable}"
                    );
                    b.first(e->range);
                    b.note(rd->range.start, "type declared here").first(rd->range);
                    b.emit();
                    e->poison();
                    self.n_errored += 1;
                    return;
                }
            }
        }

        var x = self._tu.strip_parens(e);
        if (x == &null) || (!isa::<NamedIdentExpr>(x)) { return; }
        var d = cast::<NamedIdentExpr>(x)->resolved_decl;
        if (d == &null) || (!self._tracked(d)) { return; }
        self._st.mark(d, e->range);
    }

    /// Locals and value parameters. Not `self`, not fields, not statics.
    priv fn _tracked(self, d: *Decl) -> bool {
        if isa::<ParamDecl>(d) { return !cast::<ParamDecl>(d)->is_self; }
        if isa::<VariableDecl>(d) { return !cast::<VariableDecl>(d)->is_static(); }
        return false;
    }

    // === reads ===============================================================

    priv fn _read(self, n: *NamedIdentExpr) {
        if self._st.dead { return; }                         // unreachable: nothing to say.
        var d = n->resolved_decl;
        if d == &null { return; }
        var i = self._st.index_of(d);
        if i == usize(-1) { return; }

        // Keyed on the BINDING alone (MoveState::reported): the first read
        // after the move is the error; later reads stay quiet until a
        // reassignment clears it.
        if self._st.was_reported(d) { return; }
        self._st.reported.push_back(d);

        var nm = self.sc->ctx->get_spelling(n->name);
        var b = self.sc->diag->report(DiagID::SC001E, n->range.start,
            f"'{nm}' is used after being moved"
        );
        b.first(n->range);
        b.note(self._st.at[i].start, f"'{nm}' was moved here, into a '@move' parameter").first(self._st.at[i]);
        b.note(n->range.start, f"assign a new value to '{nm}' before using it again");
        b.emit();
        n->poison();
        self.n_errored += 1;
    }
}