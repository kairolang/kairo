/// --- The Kairo Project ----------------------- Sema/Check/MoveCheck.k --- ///
///
///   \brief Moves: the type must be movable, and a moved-from binding may
///          not be read again until it is reassigned.
///
///   \detail
///     (a) At a call whose parameter is `@move`, the argument's type must be
///         movable (lifecycle_of(sc)->facts_of). Error naming the type and why.
///
///     (b) What moves. An argument to a `@move` parameter, whatever its
///         type. And a MOVE value (moves_on_pass) wherever it is
///         transferred (Doc: Ownership, Function Parameters): passed to a
///         by-value parameter or a C++ `T&&`, initializing a variable,
///         assigned, or returned when it is not a bare local. A C++ `T&` or
///         `const T&` borrows; a const value cannot be moved from; a
///         temporary is moved by C++ on its own. Each transfer is recorded in
///         SemaContext::move_sites, and CopyMoveLowering casts exactly those
///         to `T&&`: what C++ moves is what this pass counts.
///
///     (c) Use after move. A moved bare local or parameter, or a part of one
///         (`p.a`, `p.a.b`), is MOVED-FROM from that point: a later READ that
///         touches it -- the part, something inside it, or the whole binding
///         -- in the same function body is an error; an assignment to it, or
///         to something enclosing it, clears it; at a join, moved on either
///         path means moved. A `var` declaration starts a new binding.
///
///     Intraprocedural only, bindings only: a move through a pointer, out
///     of `self`, a capture, or into another function is not tracked and
///     stays AMT's (Stage 2), though the cast is still made.
///
///     Path-insensitive by design: the right operand of `&&` moves on one
///     path only, so after `if a && f(x) { return }` x is maybe-moved, and a
///     read under `if !a` is reported. Proving it unreachable would need the
///     values of conditions, which this dataflow does not track.
///
///   \par Flow
///     The walk is the RAV's, with dispatch_expr / dispatch_stmt overridden
///     for the constructs that fork or end a path: if/match/try (stmt and
///     expr forms), `&&`/`||`, loops, return/break/continue/panic, and a
///     call typed `!` (`-> !`, `__builtin_trap()`, an imported
///     `[[noreturn]]`). Everything else falls through to the base
///     traversal, whose children route back here. A loop body is walked
///     TWICE, the second time with the back edge joined in, so a move on
///     iteration one that is read on iteration two is seen; diagnostics are
///     deduplicated by (binding, use). A path that has returned is `dead`
///     and contributes nothing to a join.
///
///     A `finally` body is NOT walked where it is written. It runs when its
///     block is LEFT, so it is recorded as pending on that block and walked
///     at every exit of it over the state at that exit: the block's end,
///     and each return, break, continue or panic that leaves it (return and
///     panic after their operand; every open block, innermost first; break
///     and continue down to the loop body's). A call that does not return
///     leaves no block -- the process ends and no destructor runs -- so no
///     body is walked on that path. The body's own moves and clears persist
///     past a fallthrough, break or continue, which is where they happen.
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
import Token::Token::*;
import Token::TokenKind::*;
import Diagnostic::Registry::*;

/// One moved part: a binding, and the field path under it that was moved
/// out ("" for the whole binding, "a.b" for `p.a.b`).
class MovedPart {
    pub var d:     *Decl;
    pub var path:  string = "";
    pub var at:    SourceRange;   ///< where it was moved.
    pub var how:   string = "";   ///< where it went, for the note.
    fn MovedPart(self) { }
}

/// \p inner is \p outer or a part of it.
fn path_within(inner: string, outer: string) -> bool {
    if (outer.size() == 0) || (inner == outer) { return true; }
    return inner.starts_with(outer + ".");
}

/// \p a and \p b name overlapping storage: one is the other or a part of it.
fn path_overlaps(a: string, b: string) -> bool {
    return path_within(a, b) || path_within(b, a);
}

/// The moved-from set on one path. `dead` after return/break/continue/panic
/// or a call that does not return: the path has left the block and
/// contributes nothing to a join.
class MoveState {
    pub var moved: vec::<MovedPart>;
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

    fn index_of(self, d: *Decl, path: string) -> usize {
        for var i: usize = 0; i < self.moved.size(); ++i {
            if (self.moved[i].d == d) && (self.moved[i].path == path) { return i; }
        }
        return usize(-1);
    }

    /// The first moved part a read of \p path under \p d touches.
    fn overlap_of(self, d: *Decl, path: string) -> usize {
        for var i: usize = 0; i < self.moved.size(); ++i {
            if (self.moved[i].d == d) && path_overlaps(self.moved[i].path, path) { return i; }
        }
        return usize(-1);
    }

    /// First move wins: the note points at where it happened first.
    fn mark(self, p: MovedPart) {
        if self.index_of(p.d, p.path) != usize(-1) { return; }
        self.moved.push_back(p);
    }

    /// An assignment to \p path under \p d: that storage, and every part
    /// of it, holds a live value again, and a later move-then-use of it is a
    /// NEW mistake that must be reported, so the binding's report is dropped
    /// along with the move.
    fn clear(self, d: *Decl, path: string) {
        for var r: usize = 0; r < self.reported.size(); ++r {
            if self.reported[r] == d { self.reported.erase(self.reported.begin() + r); break; }
        }
        var i: usize = 0;
        while i < self.moved.size() {
            if (self.moved[i].d == d) && path_within(self.moved[i].path, path) {
                self.moved.erase(self.moved.begin() + i);
                continue;
            }
            i += 1;
        }
    }
}

/// Moved on either path means moved. A dead path defers to the live one.
fn move_join(a: MoveState, b: MoveState) -> MoveState {
    if a.dead { return b; }
    if b.dead { return a; }
    var out = a;
    for var i: usize = 0; i < b.moved.size(); ++i { out.mark(b.moved[i]); }
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
    pub var block_depth: usize = 0;   ///< _blocks.size() when the loop was entered; its body's block sits at this index.
    pub var has_label: bool = false;  ///< written `label: loop`; a labeled break/continue finds its frame by it.
    pub var label:     Token;
    fn LoopFrame(self) { }
}

class MoveCheck derives RecursiveASTVisitor::<MoveCheck> {
    pub var sc: *SemaContext;
    priv var _tu:    TypeUtil;
    priv var _st:    MoveState;
    priv var _loops: vec::<LoopFrame>;
    /// Pending finally bodies per open block, innermost block last (file
    /// header, Flow). Per body: saved and cleared across a nested function
    /// or closure like _st is.
    priv var _blocks: vec::<vec::<*FinallyStmt>>;
    /// The label of the LabeledStmt being entered, for the loop it wraps
    /// to take onto its frame (_loop); cleared there.
    priv var _pending_has_label: bool = false;
    priv var _pending_label:     Token;
    pub var n_moves:   usize = 0;
    pub var n_errored: usize = 0;

    fn MoveCheck(self, sc: *SemaContext) {
        self.sc  = sc;
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
        var saved_blocks = self._blocks;
        self._st    = MoveState{};
        self._loops = vec::<LoopFrame>();
        self._blocks = vec::<vec::<*FinallyStmt>>();
        var out = RecursiveASTVisitor::<MoveCheck>::traverse_function_decl(n);
        ICE_IF(!self._blocks.empty(), "MoveCheck: a block frame outlived its body");
        self._st    = saved_st;
        self._loops = saved_loops;
        self._blocks = saved_blocks;
        return out;
    }

    /// Captures are reads in the ENCLOSING body (a moved-from binding cannot
    /// be captured); the closure body is its own body. The captures are
    /// ClosureCaptures' list, the implicit ones included, each read at its
    /// first use (a named one at its name in the list); a Move capture
    /// (ownership.md: a MOVE value captured by copy is moved in) then
    /// leaves the binding moved-from here.
    fn traverse_closure_expr(self, n: *ClosureExpr) -> *ClosureExpr {
        if n == &null { return n; }
        if self.dyn()->walkup_closure_expr(n) == false { return n; }
        if n->caps_resolved {
            for var i: usize = 0; i < n->cap_decls.size(); ++i {
                var m = n->cap_modes[i];
                var at = n->cap_uses[i];
                if (m == CaptureMode::Self) || (at == &null) { continue; }
                self._read(at);
            }
            for var i: usize = 0; i < n->cap_decls.size(); ++i {
                if n->cap_modes[i] != CaptureMode::Move { continue; }
                var d = n->cap_decls[i];
                if !self._tracked(d) { continue; }
                var mp  = MovedPart{};
                mp.d    = d;
                mp.path = "";
                mp.at   = (n->cap_uses[i])->range;
                mp.how  = "into the closure that captures it";
                self._st.mark(mp);
            }
        } else {
            for var i: usize = 0; i < n->captures.size(); ++i {
                var cap = n->captures.get(i);
                if cap->name != &null { self.dispatch_expr(cap->name); }
            }
        }
        var saved_st    = self._st;
        var saved_loops = self._loops;
        var saved_blocks = self._blocks;
        self._st    = MoveState{};
        self._loops = vec::<LoopFrame>();
        self._blocks = vec::<vec::<*FinallyStmt>>();
        for var i: usize = 0; i < n->params.size(); ++i { self.dyn()->dispatch_decl(*(n->params.get(i))); }
        if n->body_block != &null { self.dyn()->traverse_block(n->body_block); }
        if n->body_expr  != &null { self.dispatch_expr(n->body_expr); }
        ICE_IF(!self._blocks.empty(), "MoveCheck: a block frame outlived its body");
        self._st    = saved_st;
        self._loops = saved_loops;
        self._blocks = saved_blocks;
        return n;
    }

    /// `var b = a` moves a MOVE `a` into `b`. The declaration also makes `b`
    /// a new, live binding: in a loop body, last iteration's move of it
    /// says nothing about this one.
    fn traverse_variable_decl(self, n: *VariableDecl) -> *VariableDecl {
        if n == &null { return n; }
        var out = RecursiveASTVisitor::<MoveCheck>::traverse_variable_decl(n);
        if n->init != &null {
            self._transfer(n->init, f"into '{self.sc->ctx->get_spelling(n->name)}\x27");
        }
        self._st.clear(static_cast::<*Decl>(n), "");
        return out;
    }

    /// A field of a struct literal or a variant's payload is initialized
    /// from its value, as a variable is.
    fn traverse_named_initializer_expr(self, n: *NamedInitializerExpr) -> *NamedInitializerExpr {
        if n == &null { return n; }
        var out = RecursiveASTVisitor::<MoveCheck>::traverse_named_initializer_expr(n);
        for var i: usize = 0; i < n->fields.size(); ++i {
            var fl = n->fields.get(i);
            if fl->value != &null { self._transfer(fl->value, f"into the field '{self.sc->ctx->get_spelling(fl->name)}\x27"); }
        }
        return out;
    }

    fn traverse_anon_initializer_expr(self, n: *AnonInitializerExpr) -> *AnonInitializerExpr {
        if n == &null { return n; }
        var out = RecursiveASTVisitor::<MoveCheck>::traverse_anon_initializer_expr(n);
        for var i: usize = 0; i < n->fields.size(); ++i {
            var fl = n->fields.get(i);
            if fl->value != &null { self._transfer(fl->value, "into a field"); }
        }
        return out;
    }

    // === expressions =========================================================

    fn dispatch_expr(self, e: *Expr) -> *Expr {
        if e == &null { return e; }
        if self.stop  { return e; }

        switch e->kind {
            case ExprKind::NamedIdentExpr {
                self._read(cast::<NamedIdentExpr>(e));
                return RecursiveASTVisitor::<MoveCheck>::dispatch_expr(e);
            }
            case ExprKind::ChainExpr {
                // `p.a.b` reads the part `a.b` of `p`, not all of it: a moved
                // `p.c` leaves it readable. The root is checked here and not
                // walked again, or it would read as the whole binding. What
                // is left of the chain after the base is names and type
                // arguments, which read nothing.
                var c    = cast::<ChainExpr>(e);
                var path = "";
                var all  = false;
                var d    = self._chain_root(c, &path, &all);
                if d == &null { return RecursiveASTVisitor::<MoveCheck>::dispatch_expr(e); }
                self._read_part(cast::<NamedIdentExpr>(self._tu.strip_parens(c->base)), d, path);
                return e;
            }
            case ExprKind::AssignOperatorExpr {
                var asn = cast::<AssignOperatorExpr>(e);
                // `x = e` / `p.a = e`: the value first (it may read x, or move
                // it: `x = f(x)`), then that storage is whole again.
                if (asn->op_token.kind == TokenKind::OpEqual) && (asn->lhs != &null) && (asn->rhs != &null) {
                    var path = "";
                    var d    = self._place_root(asn->lhs, &path);
                    if d != &null {
                        self.dispatch_expr(asn->rhs);
                        self._transfer(asn->rhs, f"into '{self._spelled(asn->lhs)}\x27");
                        self._st.clear(d, path);
                        return e;
                    }
                    self.dispatch_expr(asn->lhs);
                    self.dispatch_expr(asn->rhs);
                    self._transfer(asn->rhs, f"into '{self._spelled(asn->lhs)}\x27");
                    return e;
                }
                return RecursiveASTVisitor::<MoveCheck>::dispatch_expr(e);
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
                var out = RecursiveASTVisitor::<MoveCheck>::dispatch_expr(e);
                if bo->resolved_op != &null { self._operator_operands(bo); }
                return out;
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
            default { return RecursiveASTVisitor::<MoveCheck>::dispatch_expr(e); }
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
            case StmtKind::CompoundStmt {
                var n = cast::<CompoundStmt>(s);
                self._blocks.push_back(vec::<*FinallyStmt>());
                for var i: usize = 0; i < n->body.size(); ++i {
                    if self.stop { break; }
                    self.dispatch_stmt(n->body[i]);
                }
                // Fallthrough off the end: the block's bodies run here. A
                // dead path left the block through a jump that ran them.
                if !self._st.dead { self._run_block_finallys(self._blocks.size() - 1); }
                self._blocks.pop_back();
                return s;
            }
            case StmtKind::FinallyStmt {
                // Recorded, not walked: the body runs when its block is left
                // (_run_block_finallys), never at its statement.
                ICE_IF(self._blocks.empty(), "MoveCheck: `finally` outside a block");
                self._blocks[self._blocks.size() - 1].push_back(cast::<FinallyStmt>(s));
                return s;
            }
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
                self._loop(n->cond, n->body, &null, !self._is_true_literal(n->cond));
                return s;
            }
            case StmtKind::LoopStmt {
                var n = cast::<LoopStmt>(s);
                self._loop(&null, n->body, &null, false);
                return s;
            }
            case StmtKind::RangedForStmt {
                var n = cast::<RangedForStmt>(s);
                if n->iterable != &null { self.dispatch_expr(n->iterable); }
                self._loop(&null, n->body, &null, true);
                return s;
            }
            case StmtKind::IndexedForStmt {
                var n = cast::<IndexedForStmt>(s);
                if n->init != &null { self.dispatch_stmt(n->init); }
                self._loop(n->cond, n->body, n->update, (n->cond != &null) && (!self._is_true_literal(n->cond)));
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
                if n->value != &null {
                    self.dispatch_expr(n->value);
                    // C++ already moves a returned local or parameter, and a
                    // cast there would cost it the elision. Anything else --
                    // a field, a dereference -- is a copy unless cast.
                    if !isa::<NamedIdentExpr>(self._tu.strip_parens(n->value)) { self._transfer(n->value, "out of the function"); }
                }
                self._run_finallys_to(0);
                self._st.dead = true;
                return s;
            }
            case StmtKind::PanicStmt {
                var n = cast::<PanicStmt>(s);
                if n->payload != &null { self.dispatch_expr(n->payload); }
                self._run_finallys_to(0);
                self._st.dead = true;
                return s;
            }
            case StmtKind::LabeledStmt {
                var n = cast::<LabeledStmt>(s);
                self._pending_has_label = true;
                self._pending_label     = n->label;
                if n->inner != &null { self.dispatch_stmt(n->inner); }
                self._pending_has_label = false;
                return s;
            }
            case StmtKind::BreakStmt {
                var n = cast::<BreakStmt>(s);
                var f = self._target_frame(n->has_label, n->label);
                if f != usize(-1) {
                    self._run_finallys_to(self._loops[f].block_depth);
                    self._loops[f].breaks.push_back(self._st);
                }
                self._st.dead = true;
                return s;
            }
            case StmtKind::ContinueStmt {
                var n = cast::<ContinueStmt>(s);
                var f = self._target_frame(n->has_label, n->label);
                if f != usize(-1) {
                    self._run_finallys_to(self._loops[f].block_depth);
                    self._loops[f].continues.push_back(self._st);
                }
                self._st.dead = true;
                return s;
            }
            default { return RecursiveASTVisitor::<MoveCheck>::dispatch_stmt(s); }
        }
    }

    /// Two passes over the body: the second starts from the join of the
    /// entry state and the first pass's exit, so a move on iteration one is
    /// visible to a read on iteration two. `continue` states join the back
    /// edge; `break` states join the exit. The exit is reachable without
    /// entering the body at all (a false condition), so the entry state is
    /// a path too -- when \p finite. An infinite loop (`loop`, `while
    /// true`, a C-style `for` with no condition; ReturnPathCheck's rule) is
    /// left only by a `break`, so its exit is the join of the breaks alone:
    /// neither the entry state nor the back edge reaches past it, and with
    /// no break the code after it is dead.
    priv fn _loop(self, cond: *Expr, body: *CompoundStmt, update: *Expr, finite: bool) {
        var entry = self._st;
        // The body CompoundStmt is dispatched next and lands at exactly this
        // index: cond and update are expressions, an IndexedForStmt init a
        // DeclStmt, and none opens a block.
        var frame = LoopFrame{};
        frame.block_depth = self._blocks.size();
        frame.has_label   = self._pending_has_label;
        frame.label       = self._pending_label;
        self._pending_has_label = false;
        self._loops.push_back(frame);

        var exit1 = self._loop_pass(cond, body, update);
        self._st = move_join(entry, exit1);
        var head = self._st;
        var exit2 = self._loop_pass(cond, body, update);

        var fr = self._loops[self._loops.size() - 1];
        self._loops.pop_back();

        var out = MoveState{};
        out.dead = true;
        if finite {
            out = move_join(head, exit2);
            out = move_join(out, entry);
        }
        for var i: usize = 0; i < fr.breaks.size(); ++i { out = move_join(out, fr.breaks[i]); }
        self._st = out;
    }

    /// Walk the pending bodies of block \p i, last declared first -- LIFO
    /// with the block's locals -- over the current state. Each body is a
    /// block of its own and opens its own frame on top; block \p i stays
    /// open, since the caller is still inside it structurally.
    priv fn _run_block_finallys(self, i: usize) {
        var k = self._blocks[i].size();
        while k > 0 {
            k = k - 1;
            var fin = self._blocks[i][k];
            if (fin != &null) && (fin->body != &null) { self.dispatch_stmt(static_cast::<*Stmt>(fin->body)); }
        }
    }

    /// A jump out of every block from the innermost down to index \p to:
    /// their pending bodies run, innermost block first.
    priv fn _run_finallys_to(self, to: usize) {
        var i = self._blocks.size();
        while i > to {
            i = i - 1;
            self._run_block_finallys(i);
        }
    }

    /// The frame a break/continue jumps to: the innermost loop, or the one
    /// its label names. A label that names none was LoopContextCheck's
    /// SC012E; usize(-1) then, and the jump only ends the path.
    priv fn _target_frame(self, has_label: bool, label: Token) -> usize {
        var i = self._loops.size();
        if !has_label { return (i - 1) if (i > 0) else (usize(-1)); }
        while i > 0 {
            i = i - 1;
            if self._loops[i].has_label && (self._loops[i].label.imm == label.imm) { return i; }
        }
        return usize(-1);
    }

    priv fn _is_true_literal(self, e: *Expr) -> bool {
        if e == &null { return false; }
        if !isa::<BooleanLiteralExpr>(e) { return false; }
        return cast::<BooleanLiteralExpr>(e)->value;
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
        // A constructor call's callee names the TYPE; the constructor X
        // selected is on the call. Its parameters are what `@move` (stamped
        // onto a transfer constructor's `other` by ClassLifecycle) is read
        // from, so without this `X(h)` through `@move fn X` never moves `h`.
        var is_ctor = (n->ctor_decl != &null) && isa::<FunctionDecl>(n->ctor_decl);
        if is_ctor { f = cast::<FunctionDecl>(n->ctor_decl); }
        var fp: *FunctionPointerType = &null;
        if (f == &null) && (n->callee != &null) && (n->callee->type_ != &null) {
            var t = canon_unqual(self._tu.strip_nullable(n->callee->type_));
            if (t != &null) && isa::<FunctionPointerType>(t) { fp = cast::<FunctionPointerType>(t); }
        }

        // The parameter view a positional argument indexes: the declared
        // params minus a receiver bound through `obj.m(...)`.
        var view = vec::<*ParamDecl>();
        if f != &null {
            // A constructor's `self` is the object being built, never an argument.
            var bound_recv = is_ctor || (f->is_method() && self._callee_binds_receiver(n->callee));
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
                    // The label is on the NamedArgExpr itself. This read
                    // predates that node -- a named argument was an
                    // AssignOperatorExpr whose operator was `:` -- and the
                    // stale cast was reinterpreting `name`'s bytes as an lhs
                    // pointer, which UBSan catches as a misaligned downcast.
                    var nm = self.sc->ctx->get_spelling(cast::<NamedArgExpr>(a)->name);
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
            self._pass(e, p, mode);
        }

        // `-> !`, `__builtin_trap()`, an imported `[[noreturn]]`: nothing
        // after the call runs, so whatever it moved is never read.
        if (n->type_ != &null) && self._tu.is_never(n->type_) { self._st.dead = true; }
    }

    /// \p e passed to \p p (null for a pack tail) in \p mode. By value
    /// means a Kairo `x: T`, a C++ `T`, a pack tail, or a C++ `T&&`, which a
    /// MOVE argument binds as an xvalue (CallTyping::arg_info). A C++
    /// `const T&` / `T&` borrows. A COPY argument is copied, or against a
    /// forwarding reference deduces `T&`; _transfer passes over it.
    priv fn _pass(self, e: *Expr, p: *ParamDecl, mode: ParamMode) {
        if mode == ParamMode::Move { self._move_arg(e); return; }
        if mode != ParamMode::Value { return; }
        if (p != &null) && self._lref_param(p) { return; }
        var rref = (p != &null) && self._rref_param(p);
        self._transfer(e, ("into a '@move' parameter") if (rref) else ("into a by-value parameter"));
    }

    /// A user binary operator is a call: its operands are its arguments,
    /// the left one the receiver when the operator is a member.
    priv fn _operator_operands(self, n: *BinaryOperatorExpr) {
        var f = dyn_cast::<FunctionDecl>(n->resolved_op);
        if f == &null { return; }
        var view = vec::<*ParamDecl>();
        for var i: usize = 0; i < f->params.size(); ++i {
            if (f->params[i] != &null) && (!f->params[i]->is_self) { view.push_back(f->params[i]); }
        }
        var ops = vec::<*Expr>();
        if n->op_via_free || (!f->is_method()) { ops.push_back(n->lhs); }
        ops.push_back(n->rhs);
        for var i: usize = 0; (i < ops.size()) && (i < view.size()); ++i {
            if ops[i] != &null { self._pass(ops[i], view[i], view[i]->mode); }
        }
    }

    /// \p p is a C++ `T&` or `const T&` parameter.
    priv fn _lref_param(self, p: *ParamDecl) -> bool {
        if p->type_ == &null { return false; }
        var t = (p->type_->canonical) if (p->type_->canonical != &null) else (p->type_);
        return isa::<CXXLValueRefType>(canon_unqual(t));
    }

    /// \p p is a C++ `T&&` parameter (a forwarding reference included).
    priv fn _rref_param(self, p: *ParamDecl) -> bool {
        if p->type_ == &null { return false; }
        var t = (p->type_->canonical) if (p->type_->canonical != &null) else (p->type_);
        return isa::<CXXRValueRefType>(canon_unqual(t));
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
                // A tuple's facts are its elements' folded (ClassLifecycle::
                // facts_of_type); its pattern's hang on the parameters.
                var is_tup = self._tu.is_tuple(c);
                var tf = lifecycle_of(self.sc)->facts_of_type(c);
                var facts = (&tf) if (is_tup) else (lifecycle_of(self.sc)->facts_of(rd));
                // A definite No only. An instance has facts of its own (ClassLifecycle, Instances); only a pattern reads Unknown.
                if facts->movable == LifecycleTri::No {
                    var b = self.sc->diag->report(DiagID::SC051E, e->range.start,
                        f"cannot move a value of type '{self._tu.str(c)}': {facts->why_not_movable}"
                    );
                    b.first(e->range);
                    if !is_tup { b.note(rd->range.start, "type declared here").first(rd->range); }   // a tuple is declared nowhere.
                    b.emit();
                    e->poison();
                    self.n_errored += 1;
                    return;
                }
            }
        }

        self._mark(e, "into a '@move' parameter");
    }

    /// A transfer of \p e (passed by value, initialized from, assigned,
    /// returned): a MOVE value moves (Doc: Ownership, Function Parameters).
    /// Only an lvalue is recorded -- C++ moves a temporary on its own --
    /// and not a const one, which cannot be moved from. The site goes to
    /// SemaContext::move_sites, where CopyMoveLowering casts it, and the
    /// binding, or the part of it, is moved-from.
    priv fn _transfer(self, e: *Expr, how: string) {
        if (e == &null) || e->is_poisoned() { return; }
        if !moves_on_pass(self.sc, e->type_) { return; }
        var x = self._tu.strip_parens(e);
        if (x == &null) || (x->value_category != Expr::ValueCategory::LValue) { return; }
        if self._const_place(x) { return; }
        self.sc->move_sites.insert(reinterpret_cast::<u64>(e));
        self.n_moves += 1;
        self._mark(e, how);
    }

    /// A const binding, or a place typed const.
    priv fn _const_place(self, x: *Expr) -> bool {
        if (x->type_ != &null) && canon_has_const(x->type_) { return true; }
        if !isa::<NamedIdentExpr>(x) { return false; }
        var d = cast::<NamedIdentExpr>(x)->resolved_decl;
        if d == &null { return false; }
        if isa::<VariableDecl>(d) { return cast::<VariableDecl>(d)->is_const(); }
        if isa::<ParamDecl>(d)    { return cast::<ParamDecl>(d)->is_const; }
        return false;
    }

    /// The binding \p e is, or the part of one (`p.a.b`), becomes moved-from.
    /// Anything else -- a temporary, `self`, a dereference -- records nothing.
    priv fn _mark(self, e: *Expr, how: string) {
        var path = "";
        var d    = self._place_root(e, &path);
        if d == &null { return; }
        var mp  = MovedPart{};
        mp.d    = d;
        mp.path = path;
        mp.at   = e->range;
        mp.how  = how;
        self._st.mark(mp);
    }

    /// The tracked binding \p e names, whole or by a field path written in
    /// full (`p.a.b`, path "a.b"), or null.
    priv fn _place_root(self, e: *Expr, path: *string) -> *Decl {
        var x = self._tu.strip_parens(e);
        if x == &null { return &null; }
        if isa::<NamedIdentExpr>(x) {
            var d = cast::<NamedIdentExpr>(x)->resolved_decl;
            if (d == &null) || (!self._tracked(d)) { return &null; }
            (*path) = "";
            return d;
        }
        if !isa::<ChainExpr>(x) { return &null; }
        var all = false;
        var d   = self._chain_root(cast::<ChainExpr>(x), path, &all);
        return (d) if (all) else (&null);
    }

    /// The tracked binding at the base of \p c and the field path of the
    /// `.field` steps that lead it (\p all: every step is one). Null when
    /// the base is not a tracked binding.
    priv fn _chain_root(self, c: *ChainExpr, path: *string, all: *bool) -> *Decl {
        if c->base == &null { return &null; }
        var b = self._tu.strip_parens(c->base);
        if (b == &null) || (!isa::<NamedIdentExpr>(b)) { return &null; }
        var d = cast::<NamedIdentExpr>(b)->resolved_decl;
        if (d == &null) || (!self._tracked(d)) { return &null; }
        var p = "";
        var i: usize = 0;
        while i < c->steps.size() {
            var st = c->steps.get(i);
            if st->access_kind != ChainExpr::AccessKind::Dot { break; }
            var fd = dyn_cast::<FieldDecl>(st->resolved_decl);
            if (fd == &null) || fd->is_static() { break; }
            if p.size() > 0 { p += "."; }
            // `t.1` is bound to the tuple's field `_1` but has no name node
            // (an ordinal is not an identifier): the path spells the ordinal.
            if st->is_tuple_index() { p += f"{st->index}"; } else { p += self.sc->ctx->get_spelling(st->name->name); }
            i += 1;
        }
        (*path) = p;
        (*all)  = i == c->steps.size();
        return d;
    }

    /// The source text of \p e, for a note.
    priv fn _spelled(self, e: *Expr) -> string {
        return self.sc->ctx->get_spelling(e->range);
    }

    /// Locals and value parameters. Not `self`, not fields, not statics.
    priv fn _tracked(self, d: *Decl) -> bool {
        if isa::<ParamDecl>(d) { return !cast::<ParamDecl>(d)->is_self; }
        if isa::<VariableDecl>(d) { return !cast::<VariableDecl>(d)->is_static(); }
        return false;
    }

    // === reads ===============================================================

    priv fn _read(self, n: *NamedIdentExpr) {
        var d = n->resolved_decl;
        if d == &null { return; }
        self._read_part(n, d, "");
    }

    /// A read of \p path under \p d, through the name \p n. An error when
    /// it touches a moved part: the part itself, something inside it, or the
    /// whole binding while a part of it is gone.
    priv fn _read_part(self, n: *NamedIdentExpr, d: *Decl, path: string) {
        if self._st.dead { return; }                         // unreachable: nothing to say.
        // One error per USE as well: a loop body's second pass, or a finally
        // body walked once per exit of its block, reaches the same node again
        // after a redeclaration re-armed the binding's report.
        if n->is_poisoned() { return; }
        var i = self._st.overlap_of(d, path);
        if i == usize(-1) { return; }

        // Keyed on the BINDING alone (MoveState::reported): the first read
        // after the move is the error; later reads stay quiet until a
        // reassignment clears it.
        if self._st.was_reported(d) { return; }
        self._st.reported.push_back(d);

        var mp   = self._st.moved[i];
        var root = self.sc->ctx->get_spelling(n->name);
        var gone = (root) if (mp.path.size() == 0) else (root + "." + mp.path);
        var read = (root) if (path.size() == 0) else (root + "." + path);
        var msg  = f"'{gone}' is used after being moved";
        if !path_within(path, mp.path) { msg = f"'{read}' is used after its part '{gone}' was moved"; }
        var b = self.sc->diag->report(DiagID::SC052E, n->range.start, msg);
        b.first(n->range);
        b.note(mp.at.start, f"'{gone}' was moved here, {mp.how}").first(mp.at);
        b.note(n->range.start, f"assign a new value to '{gone}' before using it again");
        b.emit();
        n->poison();
        self.n_errored += 1;
    }
}