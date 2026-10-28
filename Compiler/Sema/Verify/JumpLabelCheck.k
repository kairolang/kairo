/// --- The Kairo Project ----------------------- Sema/Verify/JumpLabelCheck.k --- ///
///
///   \brief Verify jump!/label! intrinsics: every jump! names a label!
///          declared in the SAME function, and no function declares the
///          same label! twice. In a script, no top-level jump! crosses the
///          line of a deferred script variable.
///
///   \detail
///     A script's top level is the body of its synthesized main
///     (SCRIPT.md), and a deferred binding's initializer runs at its line
///     there. A forward jump past that line would skip it while every read
///     after the label is compiled unchecked (main's order is what proves
///     it ran); a jump back over it would run statements again around a line
///     the order counts once. Either is an error at the jump, with notes at
///     the binding and the label (SCRIPT.md 2.7, decided). Which lines are
///     deferred is ScriptRules::defers, the predicate ScriptLowering moves
///     them by, so the two cannot disagree.
///
///   Phase: VERIFY (pre-N) for the frame rules, `run()`. The script rule,
///   `run_script_jumps()`, is scheduled in the checks after ExprTyper: a
///   constant initializer is a typed, ConstEval-folded fact.
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
import AST::Visitor::RecursiveASTVisitor::*;
import Token::Token::*;
import Diagnostic::Registry::*;
import Sema::Check::ScriptRules::*;
import Sema::Type::TypeUtil::*;
import Location::SourceRange::*;

/// The `label!` and `jump!` statements of one top-level item that belong to
/// the top-level frame: none inside a closure, a function or a `finally`
/// body, each its own frame (JumpLabelCheck::run's rule).
class ScriptJumpScan derives RecursiveASTVisitor::<ScriptJumpScan> {
    pub var labels: vec::<*LabelIntrinsicStmt>;
    pub var jumps:  vec::<*JumpIntrinsicStmt>;

    fn ScriptJumpScan(self) { }

    fn visit_label_intrinsic_stmt(self, n: *LabelIntrinsicStmt) -> bool {
        self.labels.push_back(n);
        return true;
    }

    fn visit_jump_intrinsic_stmt(self, n: *JumpIntrinsicStmt) -> bool {
        self.jumps.push_back(n);
        return true;
    }

    fn traverse_closure_expr(self, n: *ClosureExpr) -> *ClosureExpr   { return n; }
    fn traverse_function_decl(self, n: *FunctionDecl) -> *FunctionDecl { return n; }
    fn traverse_finally_stmt(self, n: *FinallyStmt) -> *FinallyStmt   { return n; }
}

class JumpLabelCheck derives RecursiveASTVisitor::<JumpLabelCheck> {
    pub var sc: *SemaContext;

    var labels: vec::<Token>;               ///< label! decls, frame-stacked.
    var jumps:  vec::<*JumpIntrinsicStmt>;  ///< jump! uses, frame-stacked.
    var label_floor: usize = 0;             ///< current frame start in labels.
    var jump_floor:  usize = 0;             ///< current frame start in jumps.

    fn JumpLabelCheck(self, sc: *SemaContext) {
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
                default { }
            }
        }
        // top-level code is its own frame.
        self._validate_and_pop_frame(0, 0);
    }

    /// SCRIPT.md 2.7: a top-level `jump!` of a script that crosses the line
    /// of a deferred binding, either way. Positions are top-level item
    /// indices: a jump or label nested in a statement (`if c { jump!(L) }`)
    /// is at that statement's line, and a line strictly between the two is
    /// crossed. A jump with no top-level label was SC006E in Verify.
    fn run_script_jumps(self) {
        var rules = ScriptRules(self.sc);
        if !rules.is_script() { return; }
        var items = &(self.sc->tu->program->items);

        var deferred = vec::<usize>();
        var dvars    = vec::<*VariableDecl>();
        var labels   = vec::<*LabelIntrinsicStmt>();
        var lpos     = vec::<usize>();
        var jumps    = vec::<*JumpIntrinsicStmt>();
        var jpos     = vec::<usize>();
        for var i: usize = 0; i < items->size(); i++ {
            var item = *(items->get(i));
            if item.kind == TopLevelKind::Decl {
                var dv = rules.binding_of(item);
                if (dv != &null) && rules.defers(dv) { deferred.push_back(i); dvars.push_back(dv); }
                continue;
            }
            var v = rules.binding_of(item);
            if v != &null {
                if rules.defers(v) { deferred.push_back(i); dvars.push_back(v); }
                continue;
            }
            var scan = ScriptJumpScan();
            if item.kind == TopLevelKind::Stmt { scan.dispatch_stmt(item.as_stmt()); }
            else                               { scan.dispatch_expr(item.as_expr()); }
            for var k: usize = 0; k < scan.labels.size(); k++ { labels.push_back(scan.labels[k]); lpos.push_back(i); }
            for var k: usize = 0; k < scan.jumps.size(); k++  { jumps.push_back(scan.jumps[k]);  jpos.push_back(i); }
        }
        if deferred.empty() { return; }

        for var j: usize = 0; j < jumps.size(); j++ {
            var jn = jumps[j];
            var li: isize = -1;
            for var l: usize = 0; l < labels.size(); l++ {
                if labels[l]->name.imm == jn->target.imm { li = static_cast::<isize>(l); break; }
            }
            if li < 0 { continue; }
            var lab = labels[static_cast::<usize>(li)];
            var from = jpos[j];
            var to   = lpos[static_cast::<usize>(li)];
            // The crossed line nearest the jump: the one its path meets first.
            var hit: isize = -1;
            for var d: usize = 0; d < deferred.size(); d++ {
                var at = deferred[d];
                if (from < at) && (at < to) {
                    if hit < 0 { hit = static_cast::<isize>(d); }
                } else if (to < at) && (at < from) {
                    hit = static_cast::<isize>(d);
                }
            }
            if hit < 0 { continue; }
            self._crossing(jn, lab, dvars[static_cast::<usize>(hit)], to < from);
        }
    }

    priv fn _crossing(self, jn: *JumpIntrinsicStmt, lab: *LabelIntrinsicStmt, v: *VariableDecl, back: bool) {
        var name = TypeUtil(self.sc).decl_name(static_cast::<*Decl>(v));
        var b = self.sc->diag->report(DiagID::SC001E, jn->range.start,
            f"this 'jump!' crosses the line that gives script variable '{name}' its value");
        b.first(jn->range);
        var why = "a jump past it would skip it, and reads after the label are not checked";
        if back { why = "a jump back over it would run it again"; }
        b.note(DiagID::SC001N, v->range.start, f"'{name}' is given its value here; " + why).first(v->range);
        b.note(DiagID::SC001N, lab->range.start, "the jump lands here").first(lab->range);
        b.emit();
    }

    /// Validate every jump collected in the current frame against the
    /// frame's labels, then truncate both stacks back to the given floors.
    priv fn _validate_and_pop_frame(self, lf: usize, jf: usize) {
        for var j: usize = jf; j < self.jumps.size(); j++ {
            var jn = self.jumps[j];
            var found: bool = false;
            for var l: usize = lf; l < self.labels.size(); l++ {
                if self.labels[l].imm == jn->target.imm { found = true; break; }
            }
            if !found {
                self.sc->diag->report(DiagID::SC006E, jn->range.start,
                    "`jump!` target is not declared by any `label!` in this "
                    "function"
                ).first(jn->range).emit();
            }
        }
        while self.labels.size() > lf { self.labels.pop_back(); }
        while self.jumps.size()  > jf { self.jumps.pop_back();  }
    }

    fn visit_label_intrinsic_stmt(self, n: *LabelIntrinsicStmt) -> bool {
        for var l: usize = self.label_floor; l < self.labels.size(); l++ {
            if self.labels[l].imm == n->name.imm {
                self.sc->diag->report(DiagID::SC007E, n->range.start,
                    "duplicate `label!` name in this function"
                ).first(n->range).emit();
                return true; // don't push the duplicate.
            }
        }
        self.labels.push_back(n->name);
        return true;
    }

    fn visit_jump_intrinsic_stmt(self, n: *JumpIntrinsicStmt) -> bool {
        self.jumps.push_back(n);
        return true;
    }

    /// finally body = frame: post-desugar it is a separate function (the
    /// deferred cleanup lambda), so a jump! out of it can never codegen.
    /// The "jump bypasses finally blocks" contract covers jumping OVER a
    /// finally in normal code, not escaping one.
    fn traverse_finally_stmt(self, n: *FinallyStmt) -> *FinallyStmt {
        if self.dyn()->walkup_finally_stmt(n) == false { return n; }
        var saved_lf = self.label_floor;
        var saved_jf = self.jump_floor;
        self.label_floor = self.labels.size();
        self.jump_floor  = self.jumps.size();
        n->body = self.dyn()->traverse_block(n->body);
        self._validate_and_pop_frame(self.label_floor, self.jump_floor);
        self.label_floor = saved_lf;
        self.jump_floor  = saved_jf;
        return n;
    }

    fn traverse_function_decl(self, n: *FunctionDecl) -> *FunctionDecl {
        var saved_lf = self.label_floor;
        var saved_jf = self.jump_floor;
        self.label_floor = self.labels.size();
        self.jump_floor  = self.jumps.size();

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

        self._validate_and_pop_frame(self.label_floor, self.jump_floor);
        self.label_floor = saved_lf;
        self.jump_floor  = saved_jf;
        return n;
    }

    fn traverse_closure_expr(self, n: *ClosureExpr) -> *ClosureExpr {
        var saved_lf = self.label_floor;
        var saved_jf = self.jump_floor;
        self.label_floor = self.labels.size();
        self.jump_floor  = self.jumps.size();

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

        self._validate_and_pop_frame(self.label_floor, self.jump_floor);
        self.label_floor = saved_lf;
        self.jump_floor  = saved_jf;
        return n;
    }
}
