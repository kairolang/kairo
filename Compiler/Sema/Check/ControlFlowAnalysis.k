/// --- The Kairo Project ------------- Sema/Check/ControlFlowAnalysis.k --- ///
///
///   \brief Divergence facts (FallThrough) and the unreachable-code warning
///          (ControlFlowAnalysis, SC003W).
///
///   \detail
///     No CFG object: every question here is asked of the statement tree,
///     once per block. Missing-return (ReturnPathCheck) asks FallThrough
///     about a whole body; the unreachable-code warning asks it about each
///     statement of each block. Match-arm reachability is PatternChecking's
///     (SC121E), not this file's. The nullness analysis's early-exit rule
///     (if !x? { return } -> x non-null below) does not wait for either: it
///     runs during typing and tracks divergence itself (Sema/Type/
///     NullnessFlow.k).
///
///   \par FallThrough
///     The one answer to "can control leave this statement at its bottom
///     and continue with the next one?", shared by every pass that asks it.
///     A block falls through unless some statement in it does not (a
///     `label!` revives it); a statement does not fall through when it is
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
///   Phase: CHECK (after ExprTyper and PatternChecking; see the pass).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

import AST::Kind::StmtKind::StmtKind
import AST::Node::Base::{
    Expr,
    Stmt,
}
import AST::Node::Casting::{
    cast,
    isa,
}
import AST::Node::Declarations::FunctionDecl
import AST::Node::Expressions::{
    CallExpr,
    ClosureExpr,
}
import AST::Node::PrimaryExpressions::BooleanLiteralExpr
import AST::Node::Program::{
    TopLevelItem,
    TopLevelKind,
}
import AST::Node::Statements
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Memory::ArenaList::ArenaList
import Sema::Check::ScriptRules::ScriptRules
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::TypeUtil::TypeUtil
import Token::Token::Token

/// Does a statement contain a `break` that exits the loop under inspection
/// (FallThrough::_loop_falls_through)? A visitor rather than a statement
/// switch because a `break` can sit inside an expression: the arm of
/// `var v = try p() catch => break` is a jump StmtExpr inside a TryCatchExpr
/// inside a DeclStmt, and so is an `if`/`match` expression arm.
/// Missing one is a false SC003W whose fix-it deletes live code.
///
/// \c depth counts loops entered below the one under inspection: an
/// unlabeled break at depth 0 is ours, a labeled one is ours at any depth
/// when it names us. `match` and `try` are not loops (a `break` in them
/// targets the enclosing loop). A closure or a nested function is a
/// barrier: no `break` in it can leave a loop outside it.
class LoopExitFinder derives RecursiveASTVisitor<LoopExitFinder> {
    var sc:    unsafe *SemaContext
    var label: u32  ///< imm of the inspected loop's label, or u32::MAX.
    var depth: u32  = 0
    var found: bool = false

    fn LoopExitFinder(self, sc: unsafe *SemaContext, label: u32) {
        self.sc    = sc
        self.label = label
    }

    fn visit_break_stmt(self, n: *Statements::BreakStmt) -> bool {
        var ours = self.depth == 0
        if n->has_label {
            ours = self.label != u32::MAX && self.sc->ctx->get_ident_imm(n->label) == self.label
        }

        if ours {
            self.found = true
            self.stop  = true
        }

        return true
    }

    fn traverse_loop_stmt(self, n: *Statements::LoopStmt) -> *Statements::LoopStmt {
        self.depth += 1
        RecursiveASTVisitor<LoopExitFinder>::traverse_loop_stmt(self, n)
        self.depth -= 1
        return n
    }

    fn traverse_while_loop_stmt(self, n: *Statements::WhileLoopStmt) -> *Statements::WhileLoopStmt {
        self.depth += 1
        RecursiveASTVisitor<LoopExitFinder>::traverse_while_loop_stmt(self, n)
        self.depth -= 1
        return n
    }

    fn traverse_indexed_for_stmt(self,
                                 n: *Statements::IndexedForStmt) -> *Statements::IndexedForStmt {
        self.depth += 1
        RecursiveASTVisitor<LoopExitFinder>::traverse_indexed_for_stmt(self, n)
        self.depth -= 1
        return n
    }

    fn traverse_ranged_for_stmt(self,
                                n: unsafe *Statements::RangedForStmt) -> unsafe *Statements::RangedForStmt {
        self.depth += 1
        RecursiveASTVisitor<LoopExitFinder>::traverse_ranged_for_stmt(self, n)
        self.depth -= 1
        return n
    }

    fn traverse_closure_expr(self, n: unsafe *ClosureExpr) -> unsafe *ClosureExpr {
        return n
    }

    fn traverse_function_decl(self, n: unsafe *FunctionDecl) -> unsafe *FunctionDecl {
        return n
    }
}

pub class FallThrough {
    priv var sc:            unsafe *SemaContext
    priv var _tu:           TypeUtil
    priv var _unknown_ends: bool

    fn FallThrough(self) {
        self.sc            = &null
        self._unknown_ends = true
    }

    /// \p unknown_ends_path: see "Unknowns" in the file header.
    fn FallThrough(self, sc: unsafe *SemaContext, unknown_ends_path: bool) {
        self.sc            = sc
        self._tu           = TypeUtil(sc)
        self._unknown_ends = unknown_ends_path
    }

    /// Can control leave \p s at its bottom and continue with the next
    /// statement? See the file header for the rule per statement.
    fn falls_through(self, s: unsafe *Stmt) -> bool {
        if s == &null {
            return true
        }

        match s->kind {
            case StmtKind::RecoveryStmt {
                return !self._unknown_ends
            } case StmtKind::InlineBlockStmt {
                return !self._unknown_ends
            } case StmtKind::ReturnStmt {
                return false
            } case StmtKind::PanicStmt {
                return false
            } case StmtKind::BreakStmt {
                return false
            } case StmtKind::ContinueStmt {
                return false
            } case StmtKind::JumpIntrinsicStmt {
                return false
            } case StmtKind::CompoundStmt {
                return self.block_falls_through(cast<Statements::CompoundStmt>(s))
            } case StmtKind::UnsafeBlockStmt {
                return self.block_falls_through(cast<Statements::UnsafeBlockStmt>(s)->body)
            } case StmtKind::ContextBindingStmt {
                return self.block_falls_through(cast<Statements::ContextBindingStmt>(s)->body)
            } case StmtKind::ExpressionStmt {
                return !self.diverges(cast<Statements::ExpressionStmt>(s)->expr)
            } case StmtKind::ConditionalStmt {
                var unsafe *c = cast<Statements::ConditionalStmt>(s)
                // A decided `eval if typeof T == U`: only the taken
                // side ever runs; the other is emptied, not a path.
                if c->eval_taken == Statements::EvalTaken::Then {
                    return self.block_falls_through(c->then_)
                }

                if c->eval_taken == Statements::EvalTaken::Else {
                    return self.falls_through(c->else_)
                }

                // No `else`: the false edge falls through regardless of `then`.
                if c->else_ == &null {
                    return true
                }

                if self.block_falls_through(c->then_) {
                    return true
                }

                return self.falls_through(c->else_)
            } case StmtKind::MatchStmt {
                return self._match_falls_through(cast<Statements::MatchStmt>(s))
            } case StmtKind::TryCatchStmt {
                var unsafe *t = cast<Statements::TryCatchStmt>(s)
                if self.block_falls_through(t->try_body) {
                    return true
                }

                for var i: usize = 0; i < t->arms.size(); ++i {
                    var unsafe *arm = t->arms.get(i)
                    if self.block_falls_through(arm->body) {
                        return true
                    }
                }

                return false
            } case StmtKind::LabeledStmt {
                var unsafe *l = cast<Statements::LabeledStmt>(s)
                return self._loop_falls_through(l->inner, self._imm(l->label))
            } case StmtKind::LoopStmt {
                return self._loop_falls_through(s, u32::MAX)
            } case StmtKind::WhileLoopStmt {
                return self._loop_falls_through(s, u32::MAX)
            } case StmtKind::IndexedForStmt {
                return self._loop_falls_through(s, u32::MAX)
            } default {
                return true
            }
        }
    }

    fn block_falls_through(self, b: unsafe *Statements::CompoundStmt) -> bool {
        if b == &null {
            return true
        }

        var dead = false
        for var i: usize = 0; i < b->body.size(); ++i {
            var unsafe *s = b->body[i]
            if s == &null {
                continue
            }

            // A `label!` is a `jump!` target: whatever precedes it, control
            // can arrive here, so the block is live again from this point.
            if s->kind == StmtKind::LabelIntrinsicStmt {
                dead = false
                continue
            }

            if !self.falls_through(s) {
                dead = true
            }
        }

        return !dead
    }

    /// An expression whose type is `!` -- a call to a `-> !` function is the
    /// case that matters. Unknown type is "may return".
    fn diverges(self, e: unsafe *Expr) -> bool {
        if e == &null {
            return false
        }

        if e->type_ == &null {
            return false
        }

        return self._tu.is_never(e->type_)
    }

    /// # loops

    /// \p label is the imm of a LabeledStmt wrapping \p s, or -1.
    priv fn _loop_falls_through(self, s: unsafe *Stmt, label: u32) -> bool {
        if s == &null {
            return true
        }

        var body: unsafe *Statements::CompoundStmt = &null
        match s->kind {
            case StmtKind::LoopStmt {
                body = cast<Statements::LoopStmt>(s)->body
            } case StmtKind::WhileLoopStmt {
                var unsafe *w = cast<Statements::WhileLoopStmt>(s)
                if !self.is_true_literal(w->cond) {
                    return true
                }

                body = w->body
            } case StmtKind::IndexedForStmt {
                var unsafe *f = cast<Statements::IndexedForStmt>(s)
                if f->cond != &null && !self.is_true_literal(f->cond) {
                    return true
                }

                body = f->body
            }

            // A label on a finite loop (a ranged `for`, say): the loop
            // exhausts and falls through like the unlabeled form.
            default {
                return self.falls_through(s)
            }
        }

        // Infinite: the only way past it is a `break` that targets it.
        var finder = LoopExitFinder(self.sc, label)
        finder.dispatch_stmt(body)
        return finder.found
    }

    fn is_true_literal(self, e: unsafe *Expr) -> bool {
        if e == &null {
            return false
        }

        if !isa<BooleanLiteralExpr>(e) {
            return false
        }

        return cast<BooleanLiteralExpr>(e)->value
    }

    /// # match

    /// A non-exhaustive match is already PatternChecking's SC120E: whether
    /// it "ends the path" is the caller's unknown policy.
    priv fn _match_falls_through(self, m: unsafe *Statements::MatchStmt) -> bool {
        if !m->is_exhaustive {
            return !self._unknown_ends
        }

        for var i: usize = 0; i < m->cases.size(); ++i {
            var unsafe *mc = m->cases.get(i)
            if mc->body != &null {
                if self.block_falls_through(mc->body) {
                    return true
                }
            } else if !self.diverges(mc->expression) {
                return true
            }
        }

        return false
    }

    priv fn _imm(self, tok: Token) -> u32 {
        return self.sc->ctx->get_ident_imm(tok)
    }
}


/// The unreachable-code warning (SC003W), over every block of every body.
///
/// A region is the run of statements after one that does not fall through
/// (FallThrough, unknowns falling through), up to the end of the block or the
/// next `label!` at the same level: a `label!` is a `jump!` target, so it and
/// what follows are live again. A label anywhere INSIDE a statement of the
/// run ends the run before that statement too: control can arrive there by
/// `jump!`, and a warning on code that runs is worse than a missed one.
///
/// One warning per region, at its first statement; the statements of the
/// region are then NOT walked, so dead code nested in dead code is not
/// reported again, and neither is a closure written there.
///
/// Not a CFG: each block is asked once, in order, and each statement's
/// "does it end the path" is FallThrough's structural answer. A `return`
/// inside a closure ends the closure, never the block holding the closure
/// (a closure expression's type is a function, not `!`), and a dependent
/// call has no type yet, so it may return: a generic body warns only on
/// what diverges for every instance.
///
/// Match arms are PatternChecking's: an arm that can never match is its
/// SC121E, at the arm head. This pass never decides an arm is dead; it
/// only sees statements after a transfer INSIDE an arm body, so the two
/// cannot report the same thing.
///
/// Phase: CHECK, after ReturnPathCheck (REQUIRES ExprTyper: a call ends a
/// path when its type is `!`; REQUIRES PatternChecking: a match ends one
/// only when it is exhaustive). Before every lowering, so every statement it
/// sees was written by the user.
pub class ControlFlowAnalysis derives RecursiveASTVisitor<ControlFlowAnalysis> {
    pub var  sc:  unsafe *SemaContext
    priv var _ft: FallThrough

    fn ControlFlowAnalysis(self, sc: unsafe *SemaContext) {
        self.sc  = sc
        self._ft = FallThrough(sc, false)
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
        var rules  = ScriptRules(self.sc)
        if rules.is_script() {
            self._script_top_level(items, &rules)
            return
        }

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

    /// A script's top level is its main's body (Compiler/Spec/ScriptMode.md), so it gets the
    /// block rule: after an item that does not fall through, the code up to
    /// the next `label!` is dead. Unlike a block's, the top level holds
    /// declarations between the statements -- a function, a type, a binding
    /// whose initializer is constant and so is no line of main -- and those
    /// are never dead: a region is a CONTIGUOUS run of code items, ended by
    /// a declaration as much as by a label, so the fix-it that deletes it
    /// cannot delete one. A declaration does not revive the path: the code
    /// after it is a new region of the same dead path. A deferred binding is
    /// a line of main, and dead like any statement.
    priv fn _script_top_level(self, items: *ArenaList<TopLevelItem>, rules: *ScriptRules) {
        var cut     = SourceRange::invalid() ///< the item that ended the path.
        var cut_why = ""
        var fold    = SourceRange::invalid() ///< the folded `eval if` that ended it, if one did.
        var first   = SourceRange::invalid() ///< the open dead region.
        var last    = SourceRange::invalid()
        for var i: usize = 0; i < items->size(); ++i {
            if self.stop {
                break
            }

            var        item = *items->get(i)
            var unsafe *v   = rules->binding_of(item)
            var        code = item.get_kind() != TopLevelKind::Decl && v == &null
            if v != &null && rules->defers(v) {
                code = true
            }

            if !code {
                if first.is_valid() {
                    self._report_at(cut, cut_why, first, last)
                    first = SourceRange::invalid()
                }

                if item.get_kind() == TopLevelKind::Decl {
                    self.dyn()->dispatch_decl(item.as_decl())
                } else {
                    self.dyn()->dispatch_stmt(item.as_stmt())
                }

                continue
            }

            var st: unsafe *Stmt = &null
            if item.get_kind() == TopLevelKind::Stmt {
                st = item.as_stmt()
            }

            var r = item.get_range()
            if cut.is_valid() {
                // A label revives the path: control can arrive by `jump!`.
                var revives = st != &null
                    && (st->kind == StmtKind::LabelIntrinsicStmt || self._contains_label(st))
                if fold.is_valid() && r.start.is_valid() && !fold.contains(r.start) {
                    revives = true
                }

                if !revives {
                    if !first.is_valid() {
                        first = r
                    }

                    last = r
                    continue // dead: not walked, as in a block.
                }

                if first.is_valid() {
                    self._report_at(cut, cut_why, first, last)
                    first = SourceRange::invalid()
                }

                cut  = SourceRange::invalid()
                fold = SourceRange::invalid()
            }

            if st != &null {
                self.dyn()->dispatch_stmt(st) // discard
                if !self._ft.falls_through(st) {
                    cut     = st->range
                    cut_why = self._why(st)
                    fold    = self._fold_of(st)
                }
            } else {
                var unsafe *e = item.as_expr()
                self.dyn()->dispatch_expr(e) // discard
                if self._ft.diverges(e) {
                    cut = e->range
                    cut_why = "this expression never completes (its type is '!'), so any code after it is never run"
                    if isa<CallExpr>(e) {
                        cut_why = "this call never returns (its type is '!'), so any code after it is never run"
                    }
                }
            }
        }

        if first.is_valid() {
            self._report_at(cut, cut_why, first, last)
        }
    }

    fn traverse_compound_stmt(self,
                              n: unsafe *Statements::CompoundStmt) -> unsafe *Statements::CompoundStmt {
        if n == &null {
            return n
        }

        if self.dyn()->walkup_compound_stmt(n) == false {
            return n
        }

        var cut: unsafe *Stmt = &null ///< the statement that ended the path.
        var i:   usize        = 0
        while i < n->body.size() {
            if self.stop {
                break
            }

            var unsafe *s = n->body[i]
            if s == &null {
                ++i
                continue
            }

            if cut != &null {
                // Dead from here: find the end of the region. A path that a
                // folded `eval if` ended (its taken branch spliced into this
                // block) ends only on this target, so the region stops where
                // that branch does: the code after it runs on every other.
                var fold               = self._fold_of(cut)
                var j                  = i
                var last: unsafe *Stmt = &null
                while j < n->body.size() {
                    var unsafe *d = n->body[j]
                    if d != &null {
                        if d->kind == StmtKind::LabelIntrinsicStmt {
                            break
                        }

                        if self._contains_label(d) {
                            break
                        }

                        if fold.is_valid() && !fold.contains(d->range.start) {
                            break
                        }

                        last = d
                    }

                    ++j
                }

                if last != &null {
                    self._report(cut, s, last)
                }

                cut = &null
                // `j` is the reviving label (or the end): walk on from it.
                i = j
                continue
            }

            self.dyn()->dispatch_stmt(s) // discard
            if !self._ft.falls_through(s) {
                cut = s
            }

            ++i
        }

        return n
    }

    /// The innermost folded function-body `eval if` holding `s`, or invalid.
    priv fn _fold_of(self, s: unsafe *Stmt) -> SourceRange {
        var best = SourceRange::invalid()
        if !s->range.start.is_valid() {
            return best
        }

        for var i: usize = 0; i < self.sc->folded_eval_ifs.size(); ++i {
            var r = self.sc->folded_eval_ifs[i]
            if !r.contains(s->range.start) {
                continue
            }

            if !best.is_valid() || r.size() < best.size() {
                best = r
            }
        }

        return best
    }

    priv fn _report(self, cut: unsafe *Stmt, first: unsafe *Stmt, last: unsafe *Stmt) {
        self._report_at(cut->range, self._why(cut), first->range, last->range)
    }

    /// The warning over the region \p first .. \p last, its note at \p cut.
    priv fn _report_at(self,
                       cut:       SourceRange,
                       const why: string,
                       first:     SourceRange,
                       last:      SourceRange) {
        if !first.start.is_valid() {
            return
        }

        var region = SourceRange(first.start, last.end)
        if !last.end.is_valid() || last.end <= first.start {
            region = first
        }

        var b = self.sc->diag->report(
            DiagID::SC003W,
            first.start,
            "unreachable code; the statement above always transfers control out of this block",
        )

        b.first(region)
        if cut.start.is_valid() {
            b.note(cut.start, why)
        }

        // Only a range that is the region itself, in one file: the fallback
        // above is one statement of a region whose end could not be placed,
        // and deleting part of the dead code is not the fix. A statement's
        // range stops before its `;`, which the deletion takes too, or the
        // edit leaves a stray empty statement behind.
        var unsafe *sm = self.sc->ctx->sm
        if region.end == last.end && sm != &null && sm->same_file(region.start, region.end) {
            var stop = region.end
            if sm->get_char_at(stop) == (';' as u8) {
                stop = stop.with_offset(1)
            }

            b.remove(SourceRange(region.start, stop), "remove the unreachable code")
        }

        b.emit()
    }

    /// The note at the statement that ended the path.
    priv fn _why(self, s: unsafe *Stmt) -> string {
        match s->kind {
            case StmtKind::ReturnStmt {
                return "any code after this 'return' is never run"
            } case StmtKind::BreakStmt {
                return "any code after this 'break' is never run"
            } case StmtKind::ContinueStmt {
                return "any code after this 'continue' is never run"
            } case StmtKind::PanicStmt {
                return "any code after this 'panic' is never run"
            } case StmtKind::JumpIntrinsicStmt {
                return "any code after this 'jump!' is never run"
            } case StmtKind::ExpressionStmt {
                var unsafe *e = cast<Statements::ExpressionStmt>(s)->expr
                if e != &null && isa<CallExpr>(e) {
                    return "this call never returns (its type is '!'), so any code after it is never run"
                }

                return "this expression never completes (its type is '!'), so any code after it is never run"
            } case StmtKind::ConditionalStmt {
                return "every branch of this 'if' leaves the block, so any code after it is never run"
            } case StmtKind::MatchStmt {
                return "every arm of this 'match' leaves the block, so any code after it is never run"
            } case StmtKind::TryCatchStmt {
                return "the 'try' body and every 'catch' leave the block, so any code after it is never run"
            } case StmtKind::LoopStmt {
                return "this loop never exits (no 'break' leaves it), so any code after it is never run"
            } case StmtKind::WhileLoopStmt {
                return "this loop never exits (no 'break' leaves it), so any code after it is never run"
            } case StmtKind::IndexedForStmt {
                return "this loop never exits (no 'break' leaves it), so any code after it is never run"
            } case StmtKind::LabeledStmt {
                return "this loop never exits (no 'break' leaves it), so any code after it is never run"
            } default {
                return "this block never completes, so any code after it is never run"
            }
        }
    }

    /// Is there a `label!` anywhere in \p s? Only asked of dead statements,
    /// which are rare, so the walk is not worth caching.
    priv fn _contains_label(self, s: unsafe *Stmt) -> bool {
        if s == &null {
            return false
        }

        match s->kind {
            case StmtKind::LabelIntrinsicStmt {
                return true
            } case StmtKind::CompoundStmt {
                return self._block_contains_label(cast<Statements::CompoundStmt>(s))
            } case StmtKind::UnsafeBlockStmt {
                return self._block_contains_label(cast<Statements::UnsafeBlockStmt>(s)->body)
            } case StmtKind::ContextBindingStmt {
                return self._block_contains_label(cast<Statements::ContextBindingStmt>(s)->body)
            } case StmtKind::ConditionalStmt {
                var unsafe *c = cast<Statements::ConditionalStmt>(s)
                if self._block_contains_label(c->then_) {
                    return true
                }

                return self._contains_label(c->else_)
            } case StmtKind::MatchStmt {
                var unsafe *m = cast<Statements::MatchStmt>(s)
                for var i: usize = 0; i < m->cases.size(); ++i {
                    if self._block_contains_label(m->cases.get(i)->body) {
                        return true
                    }
                }

                return false
            } case StmtKind::TryCatchStmt {
                var unsafe *t = cast<Statements::TryCatchStmt>(s)
                if self._block_contains_label(t->try_body) {
                    return true
                }

                for var i: usize = 0; i < t->arms.size(); ++i {
                    if self._block_contains_label(t->arms.get(i)->body) {
                        return true
                    }
                }

                return false
            } case StmtKind::LabeledStmt {
                return self._contains_label(cast<Statements::LabeledStmt>(s)->inner)
            } case StmtKind::LoopStmt {
                return self._block_contains_label(cast<Statements::LoopStmt>(s)->body)
            } case StmtKind::WhileLoopStmt {
                return self._block_contains_label(cast<Statements::WhileLoopStmt>(s)->body)
            } case StmtKind::IndexedForStmt {
                return self._block_contains_label(cast<Statements::IndexedForStmt>(s)->body)
            } case StmtKind::RangedForStmt {
                return self._block_contains_label(cast<Statements::RangedForStmt>(s)->body)
            } default {
                return false
            }
        }
    }

    priv fn _block_contains_label(self, b: unsafe *Statements::CompoundStmt) -> bool {
        if b == &null {
            return false
        }

        for var i: usize = 0; i < b->body.size(); ++i {
            if self._contains_label(b->body[i]) {
                return true
            }
        }

        return false
    }
}
