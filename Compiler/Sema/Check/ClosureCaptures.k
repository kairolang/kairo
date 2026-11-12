/// --- The Kairo Project ----------------- Sema/Check/ClosureCaptures.k --- ///
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
///     One exception: a script's top-level `var`, used by a closure written
///     in the top-level code with a list that copies it (no list, `|x|`),
///     is captured by copy as a local is; EmitIR spells the copy
///     from the global (`x = ::ns::x`).
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
///     A NAMED function declared in a body -- a local `fn`, or a method of
///     a local class, struct or union -- captures nothing (closures.mdx,
///     Closures vs Inner Functions): a local or a parameter of an enclosing
///     function (`self` included) used in it is an error, and so is a
///     `static` local, which codegen could not reach either -- the local
///     declaration is emitted at namespace scope (Compiler/Spec/Codegen.md#emitir, Local
///     declarations). Each use is reported once, by the innermost such
///     function.
///
///   SC001E is the placeholder until the monthly sweep gives the error a code.
///
///   Phase: CHECK, after ExprTyper and ClassLifecycle (MOVE types), before
///   MoveCheck, which reads the result.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "vector"

import AST::ASTSupport::FrozenList
import AST::Context::DeclContext::DeclContextKind
import AST::Node::Base::{
    Decl,
    Type,
}
import AST::Node::CanonicalNodes::canon_has_const
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    ClassDecl,
    FunctionDecl,
    ParamDecl,
    StructDecl,
    UnionDecl,
    VariableDecl,
}
import AST::Node::Expressions::{
    CaptureMode,
    ClosureExpr,
}
import AST::Node::PrimaryExpressions::NamedIdentExpr
import AST::Node::Program::TopLevelKind
import AST::Node::Statements::DeclStmt
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Sema::Check::CaptureAnalysis::{
    FreeVarScan,
    copies_script_var,
    script_top_var,
}
import Sema::Check::ClassLifecycle::moves_on_pass
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::TypeUtil::TypeUtil

pub class ClosureCaptures derives RecursiveASTVisitor<ClosureCaptures> {
    pub var  sc:  unsafe *SemaContext
    priv var _tu: TypeUtil
    /// The closures around the one being resolved, innermost last; each is
    /// resolved before anything nested in it.
    priv var _open:     cxx::std::vector<unsafe *ClosureExpr>
    pub var  n_errored: usize                                 = 0
    /// Uses already reported by an inner function's scan: an enclosing
    /// local function's scan sees them free too.
    priv var _reported: cxx::std::vector<unsafe *NamedIdentExpr>
    /// Functions around the walk: 0 is a script's top-level code, where its
    /// top-level `var`s read as locals.
    priv var _fn_depth: usize = 0

    fn ClosureCaptures(self, sc: unsafe *SemaContext) {
        self.sc  = sc
        self._tu = TypeUtil(sc)
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

    fn traverse_closure_expr(self, n: unsafe *ClosureExpr) -> unsafe *ClosureExpr {
        if n == &null {
            return n
        }

        self._resolve(n)
        self._open.push_back(n)
        var unsafe *out = RecursiveASTVisitor<ClosureCaptures>::traverse_closure_expr(
            self,
            n,
        )

        self._open.pop_back()
        return out
    }

    fn traverse_function_decl(self, n: unsafe *FunctionDecl) -> unsafe *FunctionDecl {
        self._fn_depth += 1
        var unsafe *out = RecursiveASTVisitor<ClosureCaptures>::traverse_function_decl(
            self,
            n,
        )

        self._fn_depth -= 1
        return out
    }

    /// # named functions in a body

    /// After what the declaration holds: a function nested in this one is
    /// scanned first, so a use is reported by the innermost function that
    /// makes it, and this scan skips it (_reported).
    fn traverse_decl_stmt(self, n: unsafe *DeclStmt) -> unsafe *DeclStmt {
        if n == &null {
            return n
        }

        var unsafe *out = RecursiveASTVisitor<ClosureCaptures>::traverse_decl_stmt(
            self,
            n,
        )

        var unsafe *d = n->decl
        if d == &null {
            return out
        }

        var unsafe *f = dyn_cast<FunctionDecl>(d)
        if f != &null {
            self._inner_fn(f)
            return out
        }

        var methods: unsafe *FrozenList<unsafe *FunctionDecl> = &null
        if isa<ClassDecl>(d) {
            methods = unsafe &cast<ClassDecl>(d)->methods
        } else if isa<StructDecl>(d) {
            methods = unsafe &cast<StructDecl>(d)->methods
        } else if isa<UnionDecl>(d) {
            methods = unsafe &cast<UnionDecl>(d)->methods
        }

        if methods == &null {
            return out
        }

        for var i: usize = 0; i < methods->size(); ++i {
            var unsafe *m = (*methods)[i]
            if m != &null {
                self._inner_fn(m)
            }
        }

        return out
    }

    /// \p f's free locals: every one belongs to a function around it.
    priv fn _inner_fn(self, f: unsafe *FunctionDecl) {
        if f->is_poisoned() || f->is_implicit {
            return
        }

        var inner = FreeVarScan()
        inner.dispatch_decl(unsafe (f as unsafe *Decl))
        for var i: usize = 0; i < inner.free.size(); ++i {
            var unsafe *d  = inner.free[i]
            var unsafe *at = inner.free_at[i]
            if !self._outer_local(d) {
                continue
            }

            var seen = false
            for var k: usize = 0; k < self._reported.size(); ++k {
                if self._reported[k] == at {
                    seen = true
                    break
                }
            }

            if seen {
                continue
            }

            self._reported.push_back(at)
            var nm  = self._tu.decl_name(d)
            var fnm = self._tu.decl_name(unsafe (f as unsafe *Decl))
            var b = self.sc->diag->report(
                DiagID::SC151E,
                at->range.start,
                f"'{fnm}' is a named function declared in a body, and cannot use '{nm}' from the function around it",
            )

            b.first(at->range, "declared outside it")
            b.note(
                d->range.start,
                f"'{nm}' is declared here; a named function captures nothing -- pass it as a parameter, or use a closure",
            )

            b.emit()
            self.n_errored += 1
        }
    }

    /// A local or a parameter of some function: never a global, a field or
    /// a namespace-scope static.
    priv fn _outer_local(self, d: unsafe *Decl) -> bool {
        if isa<ParamDecl>(d) {
            return true
        }

        var unsafe *v = dyn_cast<VariableDecl>(d)
        if v == &null {
            return false
        }

        var unsafe *dc = v->semantic_dc
        if dc == &null {
            return true
        }

        return dc->is_function()
            || dc->dc_kind == DeclContextKind::Block
            || dc->dc_kind == DeclContextKind::Lambda
    }

    /// # the decision

    priv fn _resolve(self, n: unsafe *ClosureExpr) {
        var scan = FreeVarScan()
        scan.run_closure(n)

        var all_ptr   = false
        var all_const = false
        var named     = false
        for var i: usize = 0; i < n->captures.size(); ++i {
            var unsafe *c = n->captures.get(i)
            if c->name == &null {
                if c->by_ptr {
                    all_ptr   = true
                    all_const = c->is_const
                }
            } else {
                named = true
            }
        }

        var decls = cxx::std::vector<unsafe *Decl>()
        var modes = cxx::std::vector<CaptureMode>()
        var via   = cxx::std::vector<u8>()
        var uses  = cxx::std::vector<unsafe *NamedIdentExpr>()
        for var i: usize = 0; i < scan.free.size(); ++i {
            var unsafe *d      = scan.free[i]
            var unsafe *at_use = scan.free_at[i]
            // A script's top-level `var` from its top-level code: a copy
            // when the list asks for one; any other form names the global
            // in place.
            var script_copy = self._fn_depth == 0
                && script_top_var(self.sc->script_root, d)
                && self._open_copy(n, d)
            // Inside a closure that copied it, the name is that closure's
            // copy, a local of the closure: an inner closure captures it as
            // nested closures in a function capture a local, by its own list
            // An inner `|*|` must write the outer closure's copy, not the
            // script's variable.
            var script_local = self._fn_depth == 0
                && script_top_var(self.sc->script_root, d)
                && self._open.size() > 0
                && copies_script_var(self._open[0], d)
            if (!self._automatic(d)) && (!script_copy) && (!script_local) {
                continue
            }

            var        mode = CaptureMode::Copy
            var unsafe *p   = dyn_cast<ParamDecl>(d)
            if p != &null && p->is_self {
                if n->explicit_no_capture {
                    self._not_captured(n, d, at_use)
                    continue
                }

                mode = CaptureMode::Receiver
            } else {
                var k = self._named_index(n, d)
                if k != usize::MAX {
                    var unsafe *c = n->captures.get(k)
                    if c->by_ptr {
                        mode = if (c->is_const) => (CaptureMode::ConstPtr) else => CaptureMode::Ptr
                    }
                } else if all_ptr {
                    mode = if (all_const) => (CaptureMode::ConstPtr) else => CaptureMode::Ptr
                } else if named || n->explicit_no_capture {
                    self._not_captured(n, d, at_use)
                    continue
                }

                if mode == CaptureMode::Copy && self._moves(d) {
                    mode = CaptureMode::Move
                }
            }

            var vp = mode != CaptureMode::Receiver && self._via_ptr(d)
            // The name is a pointer already: copying it is the capture,
            // whether the list asked for a copy, a move or a pointer.
            if vp && (mode == CaptureMode::Move || mode == CaptureMode::Ptr) {
                mode = CaptureMode::Copy
            }

            decls.push_back(d)
            modes.push_back(mode)
            via.push_back(vp as u8)
            uses.push_back(at_use)
        }

        n->cap_decls.from_vec(unsafe &decls, self.sc->ctx)
        n->cap_modes.from_vec(unsafe &modes, self.sc->ctx)
        n->cap_via_ptr.from_buf(
            unsafe (via.data() as unsafe *bool),
            via.size(),
            self.sc->ctx,
        )

        n->cap_uses.from_vec(unsafe &uses, self.sc->ctx)
        n->caps_resolved = true
    }

    /// \p n and every closure around it copy the script variable \p d:
    /// under a `|*|` one the name is that closure's pointer view
    /// (ExprTyper::_capture_view), which the inner closure reads in place.
    priv fn _open_copy(self, n: unsafe *ClosureExpr, d: unsafe *Decl) -> bool {
        if !copies_script_var(n, d) {
            return false
        }

        for var i: usize = 0; i < self._open.size(); ++i {
            if !copies_script_var(self._open[i], d) {
                return false
            }
        }

        return true
    }

    /// A local or a parameter: what a lambda can capture. A static or a
    /// namespace-scope variable is named directly (FinallyLowering's test).
    priv fn _automatic(self, d: unsafe *Decl) -> bool {
        if isa<ParamDecl>(d) {
            return true
        }

        var unsafe *v = dyn_cast<VariableDecl>(d)
        if v == &null {
            return false
        }

        if v->is_static() {
            return false
        }

        var unsafe *dc = v->semantic_dc
        if dc == &null {
            return true
        }

        return dc->is_function()
            || dc->dc_kind == DeclContextKind::Block
            || dc->dc_kind == DeclContextKind::Lambda
    }

    /// The capture-list entry naming \p d, or usize(-1).
    priv fn _named_index(self, n: unsafe *ClosureExpr, d: unsafe *Decl) -> usize {
        for var i: usize = 0; i < n->captures.size(); ++i {
            var unsafe *c = n->captures.get(i)
            if c->name != &null && c->name->resolved_decl == d {
                return i
            }
        }

        return usize::MAX
    }

    /// A MOVE value captured by copy is moved in (ownership.md): unless the
    /// binding is const, which cannot be moved from (MoveCheck::_const_place).
    priv fn _moves(self, d: unsafe *Decl) -> bool {
        var        t:       unsafe *Type = &null
        var        is_const              = false
        var unsafe *p                    = dyn_cast<ParamDecl>(d)
        if p != &null {
            t        = if (p->is_pack && p->pack_type != &null) => (p->pack_type) else => p->type_
            is_const = p->is_const
        } else {
            var unsafe *v = cast<VariableDecl>(d)
            t        = v->type_
            is_const = v->is_const()
        }

        if t == &null || t->canonical == &null || is_const {
            return false
        }

        if canon_has_const(t->canonical) {
            return false
        }

        return moves_on_pass(self.sc, t->canonical)
    }

    /// The nearest enclosing closure that captures \p d holds it by pointer,
    /// or sees it as one: then \p d's name in this closure is that pointer.
    priv fn _via_ptr(self, d: unsafe *Decl) -> bool {
        var i = self._open.size()
        while i > 0 {
            i = i - 1
            var unsafe *c = self._open[i]
            for var k: usize = 0; k < c->cap_decls.size(); ++k {
                if c->cap_decls[k] != d {
                    continue
                }

                var m = c->cap_modes[k]
                return m == CaptureMode::Ptr || m == CaptureMode::ConstPtr || c->cap_via_ptr[k]
            }
        }

        return false
    }

    /// # the error

    /// \p d is used in \p n, and \p n's list (`||` or a named one) does not
    /// capture it.
    priv fn _not_captured(self,
                          n:      unsafe *ClosureExpr,
                          d:      unsafe *Decl,
                          at_use: unsafe *NamedIdentExpr) {
        var        nm      = self._tu.decl_name(d)
        var unsafe *p      = dyn_cast<ParamDecl>(d)
        var        is_self = p != &null && p->is_self
        var why = if (n->explicit_no_capture) => ("its capture list is '||', which captures nothing")
                  else => "its capture list does not name it"
        var b = self.sc->diag->report(
            DiagID::SC152E,
            at_use->range.start,
            f"'{nm}' is not captured by this closure: {why}",
        )

        b.first(at_use->range)
        var at = self._name_range(d)
        if at.is_valid() {
            b.note(at.start, f"'{nm}' is declared here, outside the closure")->child_first(
                at,
            )
        }

        if n->explicit_no_capture {
            if n->capture_range.is_valid() {
                if is_self {
                    b.remove(
                        n->capture_range,
                        "capture by default, which takes 'self'",
                    )
                } else {
                    b.fix(
                        n->capture_range,
                        f"|{nm}|",
                        f"capture '{nm}' by copy",
                    )
                }
            }
        } else {
            var last: unsafe *NamedIdentExpr = &null
            for var i: usize = 0; i < n->captures.size(); ++i {
                var unsafe *c = n->captures.get(i)
                if c->name != &null {
                    last = c->name
                }
            }

            if last != &null {
                b.insert(
                    last->name.range.end,
                    f", {nm}",
                    f"capture '{nm}' by copy",
                )
            }
        }

        b.emit()
        at_use->poison()
        self.n_errored += 1
    }

    priv fn _name_range(self, d: unsafe *Decl) -> SourceRange {
        var unsafe *p = dyn_cast<ParamDecl>(d)
        if p != &null {
            return p->name.range
        }

        var unsafe *v = dyn_cast<VariableDecl>(d)
        if v != &null {
            return v->name.range
        }

        return d->range
    }
}
