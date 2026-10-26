/// --- The Kairo Project ------------------- Sema/Check/ClosureCaptures.k --- ///
///
///   \brief What every closure captures, and how: the decision EmitIR renders
///          as the lambda's capture list.
///
///   \detail
///     closures.md, Capture Modes. A closure's FREE bindings (FreeVarScan,
///     CaptureAnalysis.k: used in it, declared outside it) that are
///     automatic -- a local or a parameter of an enclosing function or
///     closure -- are its captures. A static or a namespace-scope variable
///     is not captured: the lambda names it directly, as any function does.
///
///         no list        every capture by copy (a MOVE type: moved in,
///                        ownership.md "Default capture")
///         `|*|`          every capture by pointer (`|const *|`: const)
///         `|a, *b|`      exactly the names written, each in its own mode
///         `||`           nothing
///
///     With a named list or `||`, a free binding the list does not name is
///     an error (closures.md: "any reference to an outer variable is a
///     compile error"), with a fix-it that names it. `self` cannot be
///     written in a list (it is a keyword there); it is captured implicitly
///     by every form but `||`, as the pointer it already is (Self).
///
///     Each closure records the result on itself (ClosureExpr::cap_decls /
///     cap_modes / cap_via_ptr / cap_uses, caps_resolved). An inner closure
///     sees a binding an enclosing closure holds by pointer AS that pointer
///     (ExprTyper::_capture_view), so its capture copies or converts the
///     pointer (`cap_via_ptr`) instead of taking an address again.
///
///     The free walk of a closure includes the closures nested in it: a
///     binding an inner closure uses is captured by every closure between
///     it and its declaration, each in its own mode, which is what C++
///     requires of nested lambdas as well.
///
///   \par Readers
///     MoveCheck (a capture is a read of the binding where the closure is
///     made; a Move capture moves it), FinallyLowering (a guard inside a
///     closure reaches a pointer capture through the pointer), EmitIR (the
///     capture list).
///
///   SC001E is the placeholder until the monthly sweep gives the error a code.
///
///   Phase: CHECK, after ExprTyper and ClassLifecycle (MOVE types), before
///   MoveCheck, which reads the result.
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
import Sema::Check::CaptureAnalysis::*;
import Sema::Check::ClassLifecycle::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Location::SourceRange::*;
import Token::Token::*;
import Diagnostic::Registry::*;

class ClosureCaptures derives RecursiveASTVisitor::<ClosureCaptures> {
    pub var sc: *SemaContext;
    priv var _tu: TypeUtil;
    /// The closures around the one being resolved, innermost last; each is
    /// resolved before anything nested in it.
    priv var _open: vec::<*ClosureExpr>;
    pub var n_errored: usize = 0;

    fn ClosureCaptures(self, sc: *SemaContext) {
        self.sc  = sc;
        self._tu = TypeUtil(sc);
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

    fn traverse_closure_expr(self, n: *ClosureExpr) -> *ClosureExpr {
        if n == &null { return n; }
        self._resolve(n);
        self._open.push_back(n);
        var out = RecursiveASTVisitor::<ClosureCaptures>::traverse_closure_expr(n);
        self._open.pop_back();
        return out;
    }

    // --- the decision ---------------------------------------------------------------

    priv fn _resolve(self, n: *ClosureExpr) {
        var scan = FreeVarScan();
        scan.run_closure(n);

        var all_ptr   = false;
        var all_const = false;
        var named     = false;
        for var i: usize = 0; i < n->captures.size(); ++i {
            var c = n->captures.get(i);
            if c->name == &null {
                if c->by_ptr { all_ptr = true; all_const = c->is_const; }
            } else {
                named = true;
            }
        }

        var decls = vec::<*Decl>();
        var modes = vec::<CaptureMode>();
        var via   = vec::<bool>();
        var uses  = vec::<*NamedIdentExpr>();
        for var i: usize = 0; i < scan.free.size(); ++i {
            var d   = scan.free[i];
            var at_use = scan.free_at[i];
            if !self._automatic(d) { continue; }
            var mode = CaptureMode::Copy;
            var p = dyn_cast::<ParamDecl>(d);
            if (p != &null) && p->is_self {
                if n->explicit_no_capture { self._not_captured(n, d, at_use); continue; }
                mode = CaptureMode::Self;
            } else {
                var k = self._named_index(n, d);
                if k != usize(-1) {
                    var c = n->captures.get(k);
                    if c->by_ptr { mode = (CaptureMode::ConstPtr) if (c->is_const) else (CaptureMode::Ptr); }
                } else if all_ptr {
                    mode = (CaptureMode::ConstPtr) if (all_const) else (CaptureMode::Ptr);
                } else if named || n->explicit_no_capture {
                    self._not_captured(n, d, at_use);
                    continue;
                }
                if (mode == CaptureMode::Copy) && self._moves(d) { mode = CaptureMode::Move; }
            }
            var vp = (mode != CaptureMode::Self) && self._via_ptr(d);
            // The name is a pointer already: copying it is the capture,
            // whether the list asked for a copy, a move or a pointer.
            if vp && ((mode == CaptureMode::Move) || (mode == CaptureMode::Ptr)) { mode = CaptureMode::Copy; }
            decls.push_back(d);
            modes.push_back(mode);
            via.push_back(vp);
            uses.push_back(at_use);
        }
        n->cap_decls.from_vec(&decls, self.sc->ctx);
        n->cap_modes.from_vec(&modes, self.sc->ctx);
        n->cap_via_ptr.from_vec(&via, self.sc->ctx);
        n->cap_uses.from_vec(&uses, self.sc->ctx);
        n->caps_resolved = true;
    }

    /// A local or a parameter: what a lambda can capture. A static or a
    /// namespace-scope variable is named directly (FinallyLowering's test).
    priv fn _automatic(self, d: *Decl) -> bool {
        if isa::<ParamDecl>(d) { return true; }
        var v = dyn_cast::<VariableDecl>(d);
        if v == &null { return false; }
        if v->is_static() { return false; }
        var dc = reinterpret_cast::<*DeclContext>(v->semantic_dc);
        if dc == &null { return true; }
        return dc->is_function() || (dc->dc_kind == DeclContextKind::Block) || (dc->dc_kind == DeclContextKind::Lambda);
    }

    /// The capture-list entry naming \p d, or usize(-1).
    priv fn _named_index(self, n: *ClosureExpr, d: *Decl) -> usize {
        for var i: usize = 0; i < n->captures.size(); ++i {
            var c = n->captures.get(i);
            if (c->name != &null) && (c->name->resolved_decl == d) { return i; }
        }
        return usize(-1);
    }

    /// A MOVE value captured by copy is moved in (ownership.md): unless the
    /// binding is const, which cannot be moved from (MoveCheck::_const_place).
    priv fn _moves(self, d: *Decl) -> bool {
        var t: *Type = &null;
        var is_const = false;
        var p = dyn_cast::<ParamDecl>(d);
        if p != &null {
            t = (p->pack_type) if (p->is_pack && (p->pack_type != &null)) else (p->type_);
            is_const = p->is_const;
        } else {
            var v = cast::<VariableDecl>(d);
            t = v->type_;
            is_const = v->is_const();
        }
        if (t == &null) || (t->canonical == &null) || is_const { return false; }
        if canon_has_const(t->canonical) { return false; }
        return moves_on_pass(self.sc, t->canonical);
    }

    /// The nearest enclosing closure that captures \p d holds it by pointer,
    /// or sees it as one: then \p d's name in this closure is that pointer.
    priv fn _via_ptr(self, d: *Decl) -> bool {
        var i = self._open.size();
        while i > 0 {
            i = i - 1;
            var c = self._open[i];
            for var k: usize = 0; k < c->cap_decls.size(); ++k {
                if c->cap_decls[k] != d { continue; }
                var m = c->cap_modes[k];
                return (m == CaptureMode::Ptr) || (m == CaptureMode::ConstPtr) || c->cap_via_ptr[k];
            }
        }
        return false;
    }

    // --- the error -----------------------------------------------------------------

    /// \p d is used in \p n, and \p n's list (`||` or a named one) does not
    /// capture it.
    priv fn _not_captured(self, n: *ClosureExpr, d: *Decl, at_use: *NamedIdentExpr) {
        var nm = self._tu.decl_name(d);
        var p = dyn_cast::<ParamDecl>(d);
        var is_self = (p != &null) && p->is_self;
        var why = ("its capture list is '||', which captures nothing") if (n->explicit_no_capture) else ("its capture list does not name it");
        var b = self.sc->diag->report(DiagID::SC001E, at_use->range.start,
            f"'{nm}' is not captured by this closure: {why}"
        );
        b.first(at_use->range);
        var at = self._name_range(d);
        if at.is_valid() { b.note(at.start, f"'{nm}' is declared here, outside the closure").first(at); }
        if n->explicit_no_capture {
            if n->capture_range.is_valid() {
                if is_self { b.remove(n->capture_range, "capture by default, which takes 'self\x27"); }
                else       { b.fix(n->capture_range, f"|{nm}|", f"capture '{nm}' by copy"); }
            }
        } else {
            var last: *NamedIdentExpr = &null;
            for var i: usize = 0; i < n->captures.size(); ++i {
                var c = n->captures.get(i);
                if c->name != &null { last = c->name; }
            }
            if last != &null { b.insert(last->name.range.end, f", {nm}", f"capture '{nm}' by copy"); }
        }
        b.emit();
        at_use->poison();
        self.n_errored += 1;
    }

    priv fn _name_range(self, d: *Decl) -> SourceRange {
        var p = dyn_cast::<ParamDecl>(d);
        if p != &null { return p->name.range; }
        var v = dyn_cast::<VariableDecl>(d);
        if v != &null { return v->name.range; }
        return d->range;
    }
}
