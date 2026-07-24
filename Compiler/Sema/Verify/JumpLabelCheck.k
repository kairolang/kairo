/// --- The Kairo Project ----------------------- Sema/Verify/JumpLabelCheck.k --- ///
///
///   \brief Verify jump!/label! intrinsics: every jump! names a label!
///          declared in the SAME function, and no function declares the
///          same label! twice.
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
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Token::Token::*;
import Diagnostic::Registry::*;

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
                self.sc->diag->report(DiagID::SC001E, jn->range.start,
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
                self.sc->diag->report(DiagID::SC001E, n->range.start,
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
