/// --- The Kairo Project ------------------- Sema/ControlFlowAnalysis.k --- ///
///
///   \brief Build per-fn CFG; reachability + divergence facts.
///
///   \detail
///     Feeds: `!` (no-return) verification, unreachable-code, missing-return,
///     match-arm reachability. The nullness analysis's early-exit rule
///     (if !x? { return } -> x non-null below) does not wait for it: it
///     runs during typing and tracks divergence itself (Sema/Type/
///     NullnessFlow.k).
///
///   \par FallThrough
///     The one answer to "can control leave this statement at its bottom
///     and continue with the next one?", shared by every pass that asks it
///     (ReturnPathCheck today). Structural, not a CFG: one question asked
///     of the statement tree. A block falls through unless some statement
///     in it does not (a `label!` revives it); a statement does not fall
///     through when it is
///
///         return / panic / break / continue / jump!
///         a call (or any expression) whose type is `!`
///         `if` WITH an `else`, both arms not falling through
///         `match` that is exhaustive, every arm not falling through
///         `try` whose body and every catch arm do not fall through
///         `loop {}`, `while true {}`, `for ;; {}` with no `break` out
///         a block / `unsafe` / context binding / label whose body doesn't
///
///     `break` and `continue` count as "does not fall through" because they
///     leave the BLOCK, not the function; the loop that owns them is what
///     decides whether the function can continue past it, and the loop rule
///     above asks exactly that.
///
///     Unknowns are the caller's call (\c unknown_ends_path): a recovery
///     node, an `inline` foreign block, and a match that is not exhaustive
///     (already SC120E) hide control flow this helper cannot see. A
///     missing-return check wants them to END the path (an error on top of
///     an error is noise); a reachability check wants them to FALL THROUGH
///     (a warning on code that may well run is a false positive). `jump!`
///     is not an unknown: it always leaves, and the `label!` rule is what
///     makes its target live.
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
import Sema::Type::TypeUtil::*;
import AST::Context::ASTContext::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Statements::*;
import AST::Node::Casting::*;
import AST::Kind::StmtKind::*;
import Token::Token::*;

class FallThrough {
    priv var sc: *SemaContext;
    priv var _tu: TypeUtil;
    priv var _unknown_ends: bool;

    fn FallThrough(self) {
        self.sc            = &null;
        self._unknown_ends = true;
    }

    /// \p unknown_ends_path: see "Unknowns" in the file header.
    fn FallThrough(self, sc: *SemaContext, unknown_ends_path: bool) {
        self.sc            = sc;
        self._tu           = TypeUtil(sc);
        self._unknown_ends = unknown_ends_path;
    }

    /// Can control leave \p s at its bottom and continue with the next
    /// statement? See the file header for the rule per statement.
    fn falls_through(self, s: *Stmt) -> bool {
        if s == &null { return true; }
        switch s->kind {
            case StmtKind::RecoveryStmt       { return !self._unknown_ends; }
            case StmtKind::InlineBlockStmt    { return !self._unknown_ends; }
            case StmtKind::ReturnStmt         { return false; }
            case StmtKind::PanicStmt          { return false; }
            case StmtKind::BreakStmt          { return false; }
            case StmtKind::ContinueStmt       { return false; }
            case StmtKind::JumpIntrinsicStmt  { return false; }

            case StmtKind::CompoundStmt {
                return self.block_falls_through(cast::<CompoundStmt>(s));
            }
            case StmtKind::UnsafeBlockStmt {
                return self.block_falls_through(cast::<UnsafeBlockStmt>(s)->body);
            }
            case StmtKind::ContextBindingStmt {
                return self.block_falls_through(cast::<ContextBindingStmt>(s)->body);
            }
            case StmtKind::ExpressionStmt {
                return !self.diverges(cast::<ExpressionStmt>(s)->expr);
            }
            case StmtKind::ConditionalStmt {
                var c = cast::<ConditionalStmt>(s);
                // No `else`: the false edge falls through regardless of `then`.
                if c->else_ == &null { return true; }
                if self.block_falls_through(c->then_) { return true; }
                return self.falls_through(c->else_);
            }
            case StmtKind::MatchStmt {
                return self._match_falls_through(cast::<MatchStmt>(s));
            }
            case StmtKind::TryCatchStmt {
                var t = cast::<TryCatchStmt>(s);
                if self.block_falls_through(t->try_body) { return true; }
                for var i: usize = 0; i < t->arms.size(); ++i {
                    var arm = t->arms.get(i);
                    if self.block_falls_through(arm->body) { return true; }
                }
                return false;
            }
            case StmtKind::LabeledStmt {
                var l = cast::<LabeledStmt>(s);
                return self._loop_falls_through(l->inner, self._imm(l->label));
            }
            case StmtKind::LoopStmt       { return self._loop_falls_through(s, u32(-1)); }
            case StmtKind::WhileLoopStmt  { return self._loop_falls_through(s, u32(-1)); }
            case StmtKind::IndexedForStmt { return self._loop_falls_through(s, u32(-1)); }
            default { return true; }
        }
    }

    fn block_falls_through(self, b: *CompoundStmt) -> bool {
        if b == &null { return true; }
        var dead = false;
        for var i: usize = 0; i < b->body.size(); ++i {
            var s = b->body[i];
            if s == &null { continue; }
            // A `label!` is a `jump!` target: whatever precedes it, control
            // can arrive here, so the block is live again from this point.
            if s->kind == StmtKind::LabelIntrinsicStmt { dead = false; continue; }
            if !self.falls_through(s) { dead = true; }
        }
        return !dead;
    }

    /// An expression whose type is `!` -- a call to a `-> !` function is the
    /// case that matters. Unknown type is "may return".
    fn diverges(self, e: *Expr) -> bool {
        if e == &null { return false; }
        if e->type_ == &null { return false; }
        return self._tu.is_never(e->type_);
    }

    // --- loops ------------------------------------------------------------

    /// \p label is the imm of a LabeledStmt wrapping \p s, or -1.
    priv fn _loop_falls_through(self, s: *Stmt, label: u32) -> bool {
        if s == &null { return true; }
        var body: *CompoundStmt = &null;
        switch s->kind {
            case StmtKind::LoopStmt { body = cast::<LoopStmt>(s)->body; }
            case StmtKind::WhileLoopStmt {
                var w = cast::<WhileLoopStmt>(s);
                if !self.is_true_literal(w->cond) { return true; }
                body = w->body;
            }
            case StmtKind::IndexedForStmt {
                var f = cast::<IndexedForStmt>(s);
                if (f->cond != &null) && (!self.is_true_literal(f->cond)) { return true; }
                body = f->body;
            }
            // A label on a finite loop (a ranged `for`, say): the loop
            // exhausts and falls through like the unlabeled form.
            default { return self.falls_through(s); }
        }
        // Infinite: the only way past it is a `break` that targets it.
        return self._breaks_out(static_cast::<*Stmt>(body), 0, label);
    }

    /// Does \p s contain a `break` that exits the loop under inspection?
    /// \p depth counts loops entered below that one: an unlabeled break at
    /// depth 0 is ours, a labeled one is ours at any depth when it names us.
    priv fn _breaks_out(self, s: *Stmt, depth: u32, label: u32) -> bool {
        if s == &null { return false; }
        switch s->kind {
            case StmtKind::BreakStmt {
                var b = cast::<BreakStmt>(s);
                if (!b->has_label) { return depth == 0; }
                return (label != u32(-1)) && (self._imm(b->label) == label);
            }
            case StmtKind::CompoundStmt {
                var c = cast::<CompoundStmt>(s);
                for var i: usize = 0; i < c->body.size(); ++i {
                    if self._breaks_out(c->body[i], depth, label) { return true; }
                }
                return false;
            }
            case StmtKind::UnsafeBlockStmt {
                return self._breaks_out(static_cast::<*Stmt>(cast::<UnsafeBlockStmt>(s)->body), depth, label);
            }
            case StmtKind::ContextBindingStmt {
                return self._breaks_out(static_cast::<*Stmt>(cast::<ContextBindingStmt>(s)->body), depth, label);
            }
            case StmtKind::ConditionalStmt {
                var c = cast::<ConditionalStmt>(s);
                if self._breaks_out(static_cast::<*Stmt>(c->then_), depth, label) { return true; }
                return self._breaks_out(c->else_, depth, label);
            }
            case StmtKind::MatchStmt {
                // `break` inside a match targets the enclosing loop (StmtKind
                // doc), so a match is not a depth step.
                var m = cast::<MatchStmt>(s);
                for var i: usize = 0; i < m->cases.size(); ++i {
                    var mc = m->cases.get(i);
                    if self._breaks_out(static_cast::<*Stmt>(mc->body), depth, label) { return true; }
                }
                return false;
            }
            case StmtKind::TryCatchStmt {
                var t = cast::<TryCatchStmt>(s);
                if self._breaks_out(static_cast::<*Stmt>(t->try_body), depth, label) { return true; }
                for var i: usize = 0; i < t->arms.size(); ++i {
                    var arm = t->arms.get(i);
                    if self._breaks_out(static_cast::<*Stmt>(arm->body), depth, label) { return true; }
                }
                return false;
            }
            case StmtKind::LabeledStmt {
                return self._breaks_out(cast::<LabeledStmt>(s)->inner, depth, label);
            }
            case StmtKind::LoopStmt {
                return self._breaks_out(static_cast::<*Stmt>(cast::<LoopStmt>(s)->body), depth + 1, label);
            }
            case StmtKind::WhileLoopStmt {
                return self._breaks_out(static_cast::<*Stmt>(cast::<WhileLoopStmt>(s)->body), depth + 1, label);
            }
            case StmtKind::IndexedForStmt {
                return self._breaks_out(static_cast::<*Stmt>(cast::<IndexedForStmt>(s)->body), depth + 1, label);
            }
            case StmtKind::RangedForStmt {
                return self._breaks_out(static_cast::<*Stmt>(cast::<RangedForStmt>(s)->body), depth + 1, label);
            }
            default { return false; }
        }
    }

    fn is_true_literal(self, e: *Expr) -> bool {
        if e == &null { return false; }
        if !isa::<BooleanLiteralExpr>(e) { return false; }
        return cast::<BooleanLiteralExpr>(e)->value;
    }

    // --- match ------------------------------------------------------------

    /// A non-exhaustive match is already PatternChecking's SC120E: whether
    /// it "ends the path" is the caller's unknown policy.
    priv fn _match_falls_through(self, m: *MatchStmt) -> bool {
        if !m->is_exhaustive { return !self._unknown_ends; }
        for var i: usize = 0; i < m->cases.size(); ++i {
            var mc = m->cases.get(i);
            if mc->body != &null {
                if self.block_falls_through(mc->body) { return true; }
            } else if !self.diverges(mc->expression) {
                return true;
            }
        }
        return false;
    }

    priv fn _imm(self, tok: Token) -> u32 {
        return self.sc->ctx->get_ident_imm(tok);
    }
}

class ControlFlowAnalysis {
    // TODO: implement ControlFlowAnalysis
}
