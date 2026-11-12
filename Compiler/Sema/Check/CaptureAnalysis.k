/// --- The Kairo Project ----------------- Sema/Check/CaptureAnalysis.k --- ///
///
///   \brief Free-variable analysis: the bindings a subtree USES but does not
///          DECLARE. What a `finally` body captures (FinallyLowering) and
///          what a closure captures (ClosureCaptures).
///
///   \detail
///     A binding is a VariableDecl or a ParamDecl. One walk: every
///     declaration met is recorded (a `var`, a parameter of a nested
///     function or closure, every binder -- a `for`'s, a destructuring's, a
///     context binding's, a catch arm's, a pattern's); every NamedIdentExpr
///     bound to a binding not recorded is free. A declaration precedes its
///     uses lexically, and a binder is recorded when its statement is
///     entered, before the body that reads it, so one pass in source order
///     is enough. Free bindings come out in order of first use, which is
///     source order and so the same in every TU that lowers the body.
///
///     What the free set MEANS is the caller's. FinallyLowering captures
///     automatic variables and the enclosing function's parameters by
///     address and leaves statics and globals, which a local class may name.
///
///   Phase: a utility over a checked tree (resolved_decl set). Imports no pass.
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

import AST::Context::DeclContext::DeclContextKind
import AST::Node::Base::{
    Decl,
    Expr,
    Stmt,
}
import AST::Node::Casting::{
    cast,
    isa,
}
import AST::Node::Declarations::{
    ParamDecl,
    VariableDecl,
}
import AST::Node::Expressions::{
    ClosureExpr,
    TryCatchExpr,
}
import AST::Node::Patterns::BindingPattern
import AST::Node::PrimaryExpressions::NamedIdentExpr
import AST::Node::Statements::{
    ContextBindingStmt,
    DestructuringDeclStmt,
    RangedForStmt,
    TryCatchStmt,
}
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor

/// \p d is a top-level `var` of a script (\p script_root: the TU is one):
/// a global in C++, but the script's local to the reader. `static`,
/// `thread` and `eval` bindings are globals in every sense. Where the use
/// sits (the top-level code, or a function of the script) is the caller's
/// half: ExprTyper reads its frames, ClosureCaptures its walk.
pub fn script_top_var(script_root: bool, d: unsafe *Decl) -> bool {
    if (!script_root) || d == &null || (!isa<VariableDecl>(d)) {
        return false
    }

    var unsafe *v = cast<VariableDecl>(d)
    if v->is_static() || v->is_thread || v->is_eval() {
        return false
    }

    var unsafe *dc = d->semantic_dc
    return dc != &null && dc->dc_kind == DeclContextKind::TranslationUnit
}

/// Closure \p n's list asks for \p d BY COPY: no list, or a list naming `d`
/// without `*`. Read for a script's top-level `var` used from the top-level
/// code: there the default capture copies it, as it copies a local
/// (closures.mdx, Capture Modes), and C++ needs the copy spelled, since a
/// lambda captures no global. `|*|`, `|*d|`, `||` and a list
/// that does not name it keep the global named in place.
pub fn copies_script_var(n: unsafe *ClosureExpr, d: unsafe *Decl) -> bool {
    if n == &null || n->explicit_no_capture {
        return false
    }

    var named = false
    for var i: usize = 0; i < n->captures.size(); ++i {
        var unsafe *c = n->captures.get(i)
        if c->name == &null {
            if c->by_ptr {
                return false
            }

            continue
        }

        if c->name->resolved_decl == d {
            return !c->by_ptr
        }

        named = true
    }

    return !named
}

pub class FreeVarScan derives RecursiveASTVisitor<FreeVarScan> {
    /// Bindings used in the walked tree and declared outside it, first use
    /// first. Statics and globals included: the caller decides what a free
    /// binding means.
    pub var free: cxx::std::vector<unsafe *Decl>
    /// The first use of each `free[i]`, parallel: where a diagnostic about
    /// the capture points.
    pub var  free_at:   cxx::std::vector<unsafe *NamedIdentExpr>
    priv var _declared: cxx::std::vector<unsafe *Decl>

    fn FreeVarScan(self) { }

    fn run(self, s: unsafe *Stmt) {
        if s == &null {
            return
        }

        self.dispatch_stmt(s)
    }

    /// A whole closure: its parameters are declared before its body is
    /// walked, and a named capture (`|x|`, `|*x|`) is a use of the outer
    /// binding, so it is free and comes first, in list order.
    fn run_closure(self, c: unsafe *ClosureExpr) {
        if c == &null {
            return
        }

        self.dispatch_expr(unsafe (c as unsafe *Expr))
    }

    priv fn _has(self, const v: cxx::std::vector<unsafe *Decl>, d: unsafe *Decl) -> bool {
        for var i: usize = 0; i < v.size(); ++i {
            if (v)[i] == d {
                return true
            }
        }

        return false
    }

    priv fn _declare(self, d: unsafe *Decl) {
        if d != &null && !self._has(self._declared, d) {
            self._declared.push_back(d)
        }
    }

    /// # declarations

    fn visit_variable_decl(self, n: *VariableDecl) -> bool {
        self._declare(unsafe (n as unsafe *Decl))
        return true
    }

    fn visit_param_decl(self, n: *ParamDecl) -> bool {
        self._declare(unsafe (n as unsafe *Decl))
        return true
    }

    // Binders are not dispatched by the RAV (Binding::decl); each statement
    // that introduces them records them here, in walkup, before its body.
    fn visit_ranged_for_stmt(self, n: *RangedForStmt) -> bool {
        for var i: usize = 0; i < n->bindings.size(); ++i {
            self._declare(n->bindings.get(i)->decl)
        }

        return true
    }

    fn visit_destructuring_decl_stmt(self, n: *DestructuringDeclStmt) -> bool {
        for var i: usize = 0; i < n->bindings.size(); ++i {
            self._declare(n->bindings.get(i)->decl)
        }

        return true
    }

    fn visit_context_binding_stmt(self, n: *ContextBindingStmt) -> bool {
        for var i: usize = 0; i < n->bindings.size(); ++i {
            self._declare(n->bindings.get(i)->decl)
        }

        return true
    }

    fn visit_try_catch_stmt(self, n: *TryCatchStmt) -> bool {
        for var i: usize = 0; i < n->arms.size(); ++i {
            self._declare(n->arms.get(i)->decl)
        }

        return true
    }

    fn visit_try_catch_expr(self, n: *TryCatchExpr) -> bool {
        for var i: usize = 0; i < n->catch_arms.size(); ++i {
            self._declare(n->catch_arms.get(i)->decl)
        }

        return true
    }

    fn visit_binding_pattern(self, n: *BindingPattern) -> bool {
        self._declare(n->decl)
        return true
    }

    /// # uses

    fn visit_named_ident_expr(self, n: unsafe *NamedIdentExpr) -> bool {
        var unsafe *d = n->resolved_decl
        if d == &null {
            return true
        }

        if (!isa<VariableDecl>(d)) && !isa<ParamDecl>(d) {
            return true
        }

        if self._has(self._declared, d) {
            return true
        }

        if !self._has(self.free, d) {
            self.free.push_back(d)
            self.free_at.push_back(n)
        }

        return true
    }
}
