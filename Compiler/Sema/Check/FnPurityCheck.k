/// --- The Kairo Project -------------------- Sema/Check/FnPurityCheck.k --- ///
///
///   \brief Enforces `const fn` and `@pure`: what a function that promises to
///          be a function of its inputs may touch.
///
///   \detail
///     Both promises become C++ attributes (`[[gnu::const]]`, `[[gnu::pure]]`),
///     and clang optimizes on them without looking: it merges, hoists and
///     deletes calls. A body that breaks the promise therefore miscompiles
///     silently, so the promise is checked here, in the Kairo body, where the
///     user can be pointed at the offending line.
///
///       const fn   reads strictly its inputs. Error: reading or writing a
///                  global or static variable (an `eval` constant is a value,
///                  not memory, and is fine), any dereference (`*p`, `p->x`,
///                  `p[i]` on a pointer), a call to a function that is not
///                  itself `const fn`, `eval fn` or a compiler intrinsic.
///       @pure      may read memory, never write it. Error: writing a global
///                  or static, assigning through a pointer, a call to a
///                  function that is not `const fn`, `@pure`, `eval fn` or an
///                  intrinsic.
///
///     Both are free functions (a method cannot be `const fn`; the parser
///     says so). `@pure` on a method is checked like any other.
///
///   \par What is NOT checked
///     User operators (a resolved `op` is a call the operator expression hides
///     until OperatorLowering), writes through an `@inout` parameter, and
///     reads of a field of `self`. Each is a hole to close by teaching this
///     pass the rule, not by loosening what it already reports.
///
///   Phase: CHECK (after ExprTyper: reads resolved declarations and types;
///          before every lowering, so it sees only what the user wrote)
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
import AST::Context::ASTContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::DeclContext::*;
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
import Token::TokenKind::*;
import Diagnostic::Registry::*;

class FnPurityCheck derives RecursiveASTVisitor::<FnPurityCheck> {
    pub var sc: *SemaContext;
    priv var _tu: TypeUtil;
    /// The function whose body is being walked and the promise it made:
    /// 0 none, 1 `const fn`, 2 `@pure`. A nested function swaps both for its
    /// own for the length of its body (visit_function_decl).
    priv var _f:    *FunctionDecl = &null;
    priv var _mode: u32 = 0;

    fn FnPurityCheck(self, sc: *SemaContext) {
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

    // === entry point ======================================================

    /// The body is walked here rather than left to the default traversal so
    /// the promise in force can be restored afterwards: a local function
    /// inside a `const fn` makes its own promise (or none), not its parent's.
    fn visit_function_decl(self, n: *FunctionDecl) -> bool {
        if n == &null { return true; }
        if n->is_poisoned() { return true; }

        var saved_f = self._f;
        var saved_m = self._mode;
        self._f    = n;
        self._mode = 0;
        if n->is_const_fn { self._mode = 1; }
        else if n->is_pure { self._mode = 2; }

        if n->body_block != &null {
            self.dyn()->traverse_block(n->body_block);
        } else if n->body_expr != &null {
            self.dyn()->dispatch_expr(n->body_expr);
        }

        self._f    = saved_f;
        self._mode = saved_m;
        return false;
    }

    // === the rules ========================================================

    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        if (self._mode != 1) || (n == &null) { return true; }
        var v = dyn_cast::<VariableDecl>(n->resolved_decl);
        if (v != &null) && self._is_global(v) { self._global(n->range, v, "read"); }
        return true;
    }

    fn visit_chain_expr(self, n: *ChainExpr) -> bool {
        if (self._mode == 0) || (n == &null) { return true; }
        for var i: usize = 0; i < n->steps.size(); ++i {
            var st = n->steps.get(i);
            if (st->access_kind == ChainExpr::AccessKind::Arrow)
            || (st->access_kind == ChainExpr::AccessKind::QuestionArrow) {
                // `p->x` reads through the pointer; as the target of an
                // assignment it is a write, which visit_assign_operator_expr
                // reports instead (a write is not also a read).
                if self._mode == 1 { self._deref(st->range, "read through a pointer"); }
            }
            if self._mode == 1 {
                var v = dyn_cast::<VariableDecl>(st->resolved_decl);
                if (v != &null) && self._is_global(v) { self._global(st->range, v, "read"); }
            }
        }
        return true;
    }

    fn visit_subscript_expr(self, n: *SubscriptExpr) -> bool {
        if (self._mode != 1) || (n == &null) { return true; }
        if self._tu.pointee(self._expr_type(n->base)) != &null {
            self._deref(n->range, "index through a pointer");
        }
        return true;
    }

    fn visit_unary_operator_expr(self, n: *UnaryOperatorExpr) -> bool {
        if (self._mode == 0) || (n == &null) { return true; }
        var k = n->op_token.kind;
        if (k == TokenKind::OpStar) && (n->fix == UnaryOperatorExpr::Fix::Prefix) {
            if self._mode == 1 { self._deref(n->range, "dereference a pointer"); }
            return true;
        }
        if (self._mode == 2) && ((k == TokenKind::OpPlusPlus) || (k == TokenKind::OpMinusMinus)) {
            self._write(n->operand, n->range);
        }
        return true;
    }

    fn visit_assign_operator_expr(self, n: *AssignOperatorExpr) -> bool {
        if (self._mode != 2) || (n == &null) { return true; }
        self._write(n->lhs, n->range);
        return true;
    }

    fn visit_call_expr(self, n: *CallExpr) -> bool {
        if (self._mode == 0) || (n == &null) { return true; }
        if n->is_poisoned() { return true; }

        var d = self._callee_decl(n);
        if n->ctor_decl != &null { d = n->ctor_decl; }
        if d == &null {
            // A function value or a closure: nothing says what it does.
            // A callee the typer already rejected is its own error.
            var ce = self._tu.strip_parens(n->callee);
            if (ce != &null) && (!ce->is_poisoned()) { self._call(n->range, "a function value"); }
            return true;
        }
        var f = dyn_cast::<FunctionDecl>(d);
        if f == &null { return true; }          // a type's construction without a user constructor.
        if self._callable(f) { return true; }
        self._call(n->range, "\x27" + self._tu.decl_name(static_cast::<*Decl>(f)) + "\x27");
        return true;
    }

    // === queries ==========================================================

    priv fn _expr_type(self, e: *Expr) -> *Type {
        var x = self._tu.strip_parens(e);
        if x == &null { return &null; }
        return x->type_;
    }

    /// A variable with static storage: a file or module variable, a static
    /// member, a `static` local. An `eval` constant is a compile-time value
    /// and is not memory. A local was never indexed into a scope table, so
    /// it has no semantic_dc.
    priv fn _is_global(self, v: *VariableDecl) -> bool {
        if v->storage == StorageClass::Eval { return false; }
        if v->storage == StorageClass::Static { return true; }
        var dc = reinterpret_cast::<*DeclContext>(v->semantic_dc);
        if dc == &null { return false; }
        return (dc->dc_kind == DeclContextKind::TranslationUnit)
            || (dc->dc_kind == DeclContextKind::Module)
            || dc->is_type_scope();
    }

    /// What `n` calls, or null (a function value, an unresolved name).
    priv fn _callee_decl(self, n: *CallExpr) -> *Decl {
        var c = self._tu.strip_parens(n->callee);
        if c == &null { return &null; }
        if isa::<NamedIdentExpr>(c) { return cast::<NamedIdentExpr>(c)->resolved_decl; }
        if isa::<ChainExpr>(c) {
            var ch = cast::<ChainExpr>(c);
            if ch->steps.size() == 0 { return &null; }
            return ch->steps.get(ch->steps.size() - 1)->resolved_decl;
        }
        return &null;
    }

    /// May the current function call \p f? Either redecl may carry the
    /// attribute (`fn` declared in one place, defined in another), so the
    /// chain's canonical is asked too.
    priv fn _callable(self, f: *FunctionDecl) -> bool {
        var c = f->canonical_decl();
        if f->is_eval() || f->is_const_fn { return true; }
        if (c != &null) && (c->is_eval() || c->is_const_fn) { return true; }
        if (self._mode == 2) && (f->is_pure || ((c != &null) && c->is_pure)) { return true; }
        return self._is_intrinsic(f);
    }

    /// A compiler intrinsic: `__builtin_*` out of the builtin subtree
    /// (Lib/builtin/base/intrinsics.k). Each is clang's own builtin or a
    /// runtime hook with no state of its own.
    priv fn _is_intrinsic(self, f: *FunctionDecl) -> bool {
        if self.sc->g == &null { return false; }
        if !self.sc->g->is_builtin_fid(self._tu.fid_of(static_cast::<*Decl>(f))) { return false; }
        var nm  = self._tu.decl_name(static_cast::<*Decl>(f));
        var pre = "__builtin_";
        if nm.size() < pre.size() { return false; }
        for var i: usize = 0; i < pre.size(); ++i {
            if nm[i] != pre[i] { return false; }
        }
        return true;
    }

    // === writes (@pure) ===================================================

    /// \p target is assigned (or incremented): a write to a global or
    /// through a pointer breaks `@pure`; a write to a local does not.
    priv fn _write(self, target: *Expr, at: SourceRange) {
        var e = self._tu.strip_parens(target);
        if e == &null { return; }
        if isa::<UnaryOperatorExpr>(e) {
            var u = cast::<UnaryOperatorExpr>(e);
            if (u->op_token.kind == TokenKind::OpStar) && (u->fix == UnaryOperatorExpr::Fix::Prefix) {
                self._deref(at, "assign through a pointer");
            }
            return;
        }
        if isa::<SubscriptExpr>(e) {
            var s = cast::<SubscriptExpr>(e);
            if self._tu.pointee(self._expr_type(s->base)) != &null {
                self._deref(at, "assign through a pointer");
                return;
            }
            self._write(s->base, at);
            return;
        }
        if isa::<NamedIdentExpr>(e) {
            var v = dyn_cast::<VariableDecl>(cast::<NamedIdentExpr>(e)->resolved_decl);
            if (v != &null) && self._is_global(v) { self._global(at, v, "write"); }
            return;
        }
        if isa::<ChainExpr>(e) {
            var ch = cast::<ChainExpr>(e);
            for var i: usize = 0; i < ch->steps.size(); ++i {
                var st = ch->steps.get(i);
                if (st->access_kind == ChainExpr::AccessKind::Arrow)
                || (st->access_kind == ChainExpr::AccessKind::QuestionArrow) {
                    self._deref(at, "assign through a pointer");
                    return;
                }
                var v = dyn_cast::<VariableDecl>(st->resolved_decl);
                if (v != &null) && self._is_global(v) {
                    self._global(at, v, "write");
                    return;
                }
            }
            if ch->base != &null { self._write(ch->base, at); }
        }
    }

    // === reporting ========================================================

    priv fn _who(self) -> string {
        return "\x27" + self._tu.decl_name(static_cast::<*Decl>(self._f)) + "\x27";
    }

    priv fn _promise(self) -> string {
        return ("const") if (self._mode == 1) else ("@pure");
    }

    /// The error, with a note on the function's head that says what it
    /// promised. \p what: the sentence after "<f> is const, so it cannot".
    priv fn _report(self, at: SourceRange, what: string) {
        var f = self._f;
        var head = (f->range) if (f->is_operator) else (f->name.range);
        var b = self.sc->diag->report(DiagID::SC001E, at.start,
            self._who() + " is " + self._promise() + ", so it cannot " + what);
        b.first(at);
        if self._mode == 1 {
            b.note(head.start, self._who() + " is const: it may read only its own inputs");
        } else {
            b.note(head.start, self._who() + " is @pure: it may read memory but never write it");
        }
        b.emit();
    }

    priv fn _global(self, at: SourceRange, v: *VariableDecl, verb: string) {
        self._report(at, verb + " the global \x27" + self._tu.decl_name(static_cast::<*Decl>(v)) + "\x27");
    }

    priv fn _deref(self, at: SourceRange, what: string) {
        self._report(at, what);
    }

    priv fn _call(self, at: SourceRange, callee: string) {
        var ok = ("a const fn, an eval fn or an intrinsic") if (self._mode == 1) else ("a const fn, a @pure fn, an eval fn or an intrinsic");
        self._report(at, "call " + callee + ", which is not " + ok);
    }
}
