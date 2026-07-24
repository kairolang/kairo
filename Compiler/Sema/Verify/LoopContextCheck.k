/// --- The Kairo Project --------------------- Sema/Verify/LoopContextCheck.k --- ///
///
///   \brief Verify break/continue appear in a legal context. Pure
///          structural check: no names, no types, no symbol tables.
///
///   \detail
///     Stage1 semantics: `match` has no fallthrough, so `break` inside a
///     match arm targets the ENCLOSING LOOP -- MatchStmt is transparent
///     to this check and contributes nothing to loop depth. Only the
///     four loop statements do: WhileLoopStmt, LoopStmt, RangedForStmt,
///     IndexedForStmt.
///
///     Checks owned here (sole home for all three):
///       1. bare `break` / `continue` with loop_depth == 0  -> error.
///       2. labeled `break foo` / `continue foo` where no lexically
///          enclosing LabeledStmt (this side of the nearest function/
///          closure boundary) is named `foo`                -> error.
///       3. nested LabeledStmt reusing an enclosing label   -> warning
///          (shadowing makes the outer label unreachable from inside).
///
///     Function and closure bodies are BARRIERS: a break inside a nested
///     fn/closure cannot target a loop outside it, so both reset depth
///     and the label floor on entry and restore on exit.
///
///     Labels compare by Token.imm (per-TU interned immediates): same
///     spelling <=> same imm. No string trips.
///
///     Read-only walk. The traverse_* overrides below MIRROR the base
///     RAV bodies verbatim (there is no proven base-call idiom in the
///     tree yet) wrapped with depth/floor bookkeeping; if the RAV's
///     traverse for these nodes changes shape, update the mirrors.
///
///   Phase: VERIFY (pre-N; needs only a parsed + expanded tree)
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

class LoopContextCheck derives RecursiveASTVisitor::<LoopContextCheck> {
    pub var sc: *SemaContext;

    var loop_depth:  u32   = 0;       ///< enclosing loops this side of the barrier.
    var labels:      vec::<Token>;    ///< enclosing loop labels, stack order.
    var label_floor: usize = 0;       ///< labels below this index are behind a fn/closure barrier.
    var finally_depth: u32 = 0;       ///< enclosing finally bodies this side of the barrier.

    fn LoopContextCheck(self, sc: *SemaContext) {
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

    /// Is \p label the name of any enclosing loop label above the barrier?
    priv fn _label_visible(self, label: Token) -> bool {
        var i: usize = self.labels.size();
        while i > self.label_floor {
            i = i - 1;
            if self.labels[i].imm == label.imm { return true; }
        }

        return false;
    }

    fn visit_break_stmt(self, n: *BreakStmt) -> bool {
        if n->has_label {
            if !self._label_visible(n->label) {
                self.sc->diag->report(DiagID::SC001E, n->range.start,
                    "`break` label does not name an enclosing loop"
                ).first(n->range).emit();
            }
            return true;
        }

        if self.loop_depth == 0 {
            if self.finally_depth > 0 {
                self.sc->diag->report(DiagID::SC001E, n->range.start,
                    "`break` cannot escape a `finally` block; the body runs "
                    "as a deferred lambda at scope exit, when no enclosing "
                    "loop is live"
                ).first(n->range).emit();
            } else {
                self.sc->diag->report(DiagID::SC001E, n->range.start,
                    "`break` outside of a loop"
                ).first(n->range).emit();
            }
        }

        return true;
    }

    fn visit_continue_stmt(self, n: *ContinueStmt) -> bool {
        if n->has_label {
            if !self._label_visible(n->label) {
                self.sc->diag->report(DiagID::SC001E, n->range.start,
                    "`continue` label does not name an enclosing loop"
                ).first(n->range).emit();
            }
            return true;
        }

        if self.loop_depth == 0 {
            if self.finally_depth > 0 {
                self.sc->diag->report(DiagID::SC001E, n->range.start,
                    "`continue` cannot escape a `finally` block; the body "
                    "runs as a deferred lambda at scope exit, when no "
                    "enclosing loop is live"
                ).first(n->range).emit();
            } else {
                self.sc->diag->report(DiagID::SC001E, n->range.start,
                    "`continue` outside of a loop"
                ).first(n->range).emit();
            }
        }

        return true;
    }

    /// `return` in a finally body would return from the desugared cleanup
    /// lambda, not the enclosing function -- illegal outright. A closure
    /// INSIDE the finally resets finally_depth, so its returns stay legal.
    fn visit_return_stmt(self, n: *ReturnStmt) -> bool {
        if self.finally_depth > 0 {
            self.sc->diag->report(DiagID::SC001E, n->range.start,
                "`return` is not allowed inside a `finally` block; the body "
                "is cleanup code that runs at scope exit and cannot alter "
                "the function's control flow"
            ).first(n->range).emit();
        }

        return true;
    }

    /// finally body = barrier (deferred lambda scope): no outer loops, no
    /// outer labels visible inside.
    fn traverse_finally_stmt(self, n: *FinallyStmt) -> *FinallyStmt {
        if self.dyn()->walkup_finally_stmt(n) == false { return n; }
        var saved_depth = self.loop_depth;
        var saved_floor = self.label_floor;
        self.loop_depth    = 0;
        self.label_floor   = self.labels.size();
        self.finally_depth = self.finally_depth + 1;
        n->body = self.dyn()->traverse_block(n->body);
        self.finally_depth = self.finally_depth - 1;
        self.loop_depth    = saved_depth;
        self.label_floor   = saved_floor;
        return n;
    }

    fn traverse_while_loop_stmt(self, n: *WhileLoopStmt) -> *WhileLoopStmt {
        if self.dyn()->walkup_while_loop_stmt(n) == false { return n; }
        if n->cond != &null { n->cond = self.dyn()->dispatch_expr(n->cond); }
        
        self.loop_depth = self.loop_depth + 1;
        n->body = self.dyn()->traverse_block(n->body);
        
        self.loop_depth = self.loop_depth - 1;
        return n;
    }

    fn traverse_loop_stmt(self, n: *LoopStmt) -> *LoopStmt {
        if self.dyn()->walkup_loop_stmt(n) == false { return n; }
        
        self.loop_depth = self.loop_depth + 1;
        n->body = self.dyn()->traverse_block(n->body);
        
        self.loop_depth = self.loop_depth - 1;
        return n;
    }

    fn traverse_ranged_for_stmt(self, n: *RangedForStmt) -> *RangedForStmt {
        if self.dyn()->walkup_ranged_for_stmt(n) == false { return n; }
        if n->iterable != &null { n->iterable = self.dyn()->dispatch_expr(n->iterable); }
        
        self.loop_depth = self.loop_depth + 1;
        n->body = self.dyn()->traverse_block(n->body);
        
        self.loop_depth = self.loop_depth - 1;
        return n;
    }

    fn traverse_indexed_for_stmt(self, n: *IndexedForStmt) -> *IndexedForStmt {
        if self.dyn()->walkup_indexed_for_stmt(n) == false { return n; }
        if n->init   != &null { n->init   = self.dyn()->dispatch_stmt(n->init); }
        if n->cond   != &null { n->cond   = self.dyn()->dispatch_expr(n->cond); }
        if n->update != &null { n->update = self.dyn()->dispatch_expr(n->update); }
        
        self.loop_depth = self.loop_depth + 1;
        n->body = self.dyn()->traverse_block(n->body);
        
        self.loop_depth = self.loop_depth - 1;
        return n;
    }

    fn traverse_labeled_stmt(self, n: *LabeledStmt) -> *LabeledStmt {
        if self.dyn()->walkup_labeled_stmt(n) == false { return n; }
        if self._label_visible(n->label) {
            self.sc->diag->report(DiagID::SC001W, n->range.start,
                "label shadows an identical enclosing label; the outer "
                "label is unreachable from inside this loop"
            ).first(n->range).emit();
        }

        self.labels.push_back(n->label);
        if n->inner != &null { n->inner = self.dyn()->dispatch_stmt(n->inner); }
        
        self.labels.pop_back();
        return n;
    }

    fn traverse_function_decl(self, n: *FunctionDecl) -> *FunctionDecl {
        var saved_depth = self.loop_depth;
        var saved_floor = self.label_floor;
        var saved_fin   = self.finally_depth;
        self.loop_depth    = 0;
        self.label_floor   = self.labels.size();
        self.finally_depth = 0;

        if self.dyn()->walkup_function_decl(n) {
            for var i: usize = 0; i < n->generic_params.size(); i++ {
                if self.stop { break; }
                self.dyn()->dispatch_decl(*(n->generic_params.get(i)));  // discard
            }

            if !self.stop {
                for var i: usize = 0; i < n->spec_args.size(); i++ {
                    if self.stop { break; }
                    self.dyn()->dispatch_type(*(n->spec_args.get(i)));  // discard
                }
            }

            if !self.stop {
                if n->requires_clause != &null { n->requires_clause = self.dyn()->dispatch_expr(n->requires_clause); }
            }

            if !self.stop {
                if n->where_clause != &null { n->where_clause = self.dyn()->dispatch_expr(n->where_clause); }
                for var i: usize = 0; i < n->params.size(); i++ {
                    if self.stop { break; }
                    self.dyn()->dispatch_decl(*(n->params.get(i)));      // discard
                }
            }

            if !self.stop {
                if n->return_type != &null { n->return_type = self.dyn()->dispatch_type(n->return_type); }
                if n->qualifier   != &null { n->qualifier   = self.dyn()->dispatch_expr(n->qualifier); }
                if n->body_block  != &null { n->body_block  = self.dyn()->traverse_block(n->body_block); }
                if n->body_expr   != &null { n->body_expr   = self.dyn()->dispatch_expr(n->body_expr); }
            }
        }

        self.loop_depth    = saved_depth;
        self.label_floor   = saved_floor;
        self.finally_depth = saved_fin;
        return n;
    }

    fn traverse_closure_expr(self, n: *ClosureExpr) -> *ClosureExpr {
        var saved_depth = self.loop_depth;
        var saved_floor = self.label_floor;
        var saved_fin   = self.finally_depth;
        self.loop_depth    = 0;
        self.label_floor   = self.labels.size();
        self.finally_depth = 0;

        if self.dyn()->walkup_closure_expr(n) {
            for var i: usize = 0; i < n->generic_params.size(); i++ {
                if self.stop { break; }
                self.dyn()->dispatch_decl(*(n->generic_params.get(i)));  // discard
            }

            if !self.stop {
                for var i: usize = 0; i < n->params.size(); i++ {
                    if self.stop { break; }
                    self.dyn()->dispatch_decl(*(n->params.get(i)));      // discard
                }
            }

            if !self.stop {
                for var i: usize = 0; i < n->captures.size(); i++ {
                    if self.stop { break; }
                    var cap = n->captures.get(i);
                    if cap->name != &null { self.dyn()->dispatch_expr(cap->name); }  // discard
                }
            }

            if !self.stop {
                if n->return_type != &null { n->return_type = self.dyn()->dispatch_type(n->return_type); }
                if n->body_block  != &null { n->body_block  = self.dyn()->traverse_block(n->body_block); }
                if n->body_expr   != &null { n->body_expr   = self.dyn()->dispatch_expr(n->body_expr); }
            }
        }

        self.loop_depth    = saved_depth;
        self.label_floor   = saved_floor;
        self.finally_depth = saved_fin;
        return n;
    }
}
