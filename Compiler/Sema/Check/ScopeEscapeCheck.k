/// --- The Kairo Project ----------------- Sema/Check/ScopeEscapeCheck.k --- ///
///
///   \brief A pointer from an open AllocatorScope that outlives it (P226):
///          the intraprocedural check that stands in until Tether.
///
///   \detail
///     `var s = AllocatorScope<A>()` routes every allocation in the rest of
///     its block to A, and closing the scope gives all of it back at once
///     (Lib/builtin/base/alloc.k). A pointer from it that is still reachable
///     after the block dangles. This pass warns when one visibly gets out:
///
///       returned from the function;
///       stored to a static or `thread` variable (or used to initialize a
///         static local);
///       stored to a variable declared outside the scope's block, or
///         through a pointer, field or index whose base is one (or a
///         parameter, `self` included).
///
///     "From the scope" is direct only: a local initialized (or assigned,
///     inside the block) by a call of create / try_create / create_slice /
///     alloc_raw / resize_raw while a scope is open, or that call itself,
///     or a local copied from one. A pointer that goes INTO a call is not
///     followed, nor one that comes back out of one -- that is Tether's
///     whole-program job, and so is pairing an `_in<.., A>` allocation with
///     the free that must match it. Closures are not entered: a capture
///     that escapes is not reported yet.
///
///     Conservative by construction: it warns only on the shapes above, so
///     every warning is a real escape of a scoped pointer. A warning, not an
///     error, while the rule beds in (the spec: warning first).
///
///   Phase: CHECK (after ExprTyper: reads resolved callees and the types of
///          initializers; before every lowering, so it sees only what the
///          user wrote, and `@create` is already the call it stands for)
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
import AST::LangItems::*;
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

class ScopeEscapeCheck derives RecursiveASTVisitor::<ScopeEscapeCheck> {
    pub var sc: *SemaContext;
    priv var _tu: TypeUtil;

    /// Block nesting inside the current function body (the body is 1; 0
    /// outside any function).
    priv var _depth: u32 = 0;
    /// The innermost block that owns a live scope guard, and the guard; 0 /
    /// null when no scope is open. Restored when a block closes, which is
    /// when its guard closes the scope.
    priv var _scope_depth: u32 = 0;
    priv var _scope_var: *VariableDecl = &null;
    /// The current function's locals, each with the depth of the block that
    /// declares it, and the ones holding a pointer from the open scope.
    priv var _locals: vec::<*Decl>;
    priv var _local_depth: vec::<u32>;
    priv var _tainted: vec::<*Decl>;

    fn ScopeEscapeCheck(self, sc: *SemaContext) {
        self.sc  = sc;
        self._tu = TypeUtil(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved);
        var tu = self.sc->tu;
        if tu == &null { return; }
        if tu->program == &null { return; }
        // Nothing can open a scope where alloc.k was never loaded.
        if self.sc->g == &null { return; }

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

    // === structure ========================================================

    /// Each function starts clean: a scope, a local or a taint never
    /// crosses into a nested function's body, and comes back after it.
    fn visit_function_decl(self, n: *FunctionDecl) -> bool {
        if (n == &null) || n->is_poisoned() { return false; }
        var s_depth  = self._depth;
        var s_sdepth = self._scope_depth;
        var s_svar   = self._scope_var;
        var s_locals = self._locals;
        var s_ldepth = self._local_depth;
        var s_taint  = self._tainted;
        self._depth = 0;
        self._scope_depth = 0;
        self._scope_var = &null;
        self._locals.clear();
        self._local_depth.clear();
        self._tainted.clear();

        if n->body_block != &null { self.dyn()->traverse_block(n->body_block); }

        self._depth       = s_depth;
        self._scope_depth = s_sdepth;
        self._scope_var   = s_svar;
        self._locals      = s_locals;
        self._local_depth = s_ldepth;
        self._tainted     = s_taint;
        return false;
    }

    /// A closure's body is its own function, and where the closure goes is
    /// not followed (see the file header).
    fn visit_closure_expr(self, n: *ClosureExpr) -> bool { return false; }

    fn traverse_compound_stmt(self, n: *CompoundStmt) -> *CompoundStmt {
        if n == &null { return n; }
        var s_sdepth = self._scope_depth;
        var s_svar   = self._scope_var;
        self._depth += 1;
        var out = RecursiveASTVisitor::<ScopeEscapeCheck>::traverse_compound_stmt(n);
        // The block's locals die with it; so does a scope it opened.
        while (self._local_depth.size() > 0) && (self._local_depth[self._local_depth.size() - 1] >= self._depth) {
            self._locals.pop_back();
            self._local_depth.pop_back();
        }
        self._depth -= 1;
        self._scope_depth = s_sdepth;
        self._scope_var   = s_svar;
        return out;
    }

    /// The initializer is walked first: `var p = create<T>()` is a use of
    /// the scope in force before p exists.
    fn traverse_variable_decl(self, n: *VariableDecl) -> *VariableDecl {
        if n == &null { return n; }
        var out = RecursiveASTVisitor::<ScopeEscapeCheck>::traverse_variable_decl(n);
        if self._depth == 0 { return out; }    // a global: no block owns it.
        var d = static_cast::<*Decl>(n);

        if (n->storage == StorageClass::Static) || n->is_thread {
            if (self._scope_depth > 0) && self._escapes(n->init) {
                self._warn(n->init, "initializes the static variable \x27" + self._tu.decl_name(d) + "\x27");
            }
            return out;
        }

        self._locals.push_back(d);
        self._local_depth.push_back(self._depth);
        if self._is_scope_guard(n) {
            self._scope_depth = self._depth;
            self._scope_var   = n;
            return out;
        }
        if (self._scope_depth > 0) && self._escapes(n->init) { self._tainted.push_back(d); }
        return out;
    }

    // === the rules ========================================================

    fn visit_return_stmt(self, n: *ReturnStmt) -> bool {
        if (n == &null) || (self._scope_depth == 0) { return true; }
        if self._escapes(n->value) { self._warn(n->value, "is returned from the function"); }
        return true;
    }

    fn visit_assign_operator_expr(self, n: *AssignOperatorExpr) -> bool {
        if (n == &null) || (self._scope_depth == 0) { return true; }
        if n->op_token.kind != TokenKind::OpEqual { return true; }
        if !self._escapes(n->rhs) { return true; }

        var why = self._outlives(n->lhs);
        if why != "" { self._warn(n->rhs, why); return true; }

        // `q = p` into a local of the scope's own block (or deeper): q
        // holds a scoped pointer from here on.
        var lhs = self._tu.strip_parens(n->lhs);
        if (lhs != &null) && isa::<NamedIdentExpr>(lhs) {
            var v = cast::<NamedIdentExpr>(lhs)->resolved_decl;
            if (v != &null) && isa::<VariableDecl>(v) && (!self._is_tainted(v)) { self._tainted.push_back(v); }
        }
        return true;
    }

    // === queries ==========================================================

    /// \p e is a pointer from the open scope: a producer call itself, or a
    /// local holding one.
    priv fn _escapes(self, e_in: *Expr) -> bool {
        if e_in == &null { return false; }
        var e = self._tu.strip_parens(e_in);
        if e == &null { return false; }
        if isa::<TypeCastExpr>(e) { return self._escapes(cast::<TypeCastExpr>(e)->operand); }
        if isa::<CallExpr>(e) { return self._is_producer(cast::<CallExpr>(e)); }
        if isa::<NamedIdentExpr>(e) {
            var d = cast::<NamedIdentExpr>(e)->resolved_decl;
            return (d != &null) && self._is_tainted(d);
        }
        return false;
    }

    /// Where a store to \p target lands, if that outlives the scope: the
    /// phrase for the warning, or "" when the target dies with the scope
    /// (or cannot be told).
    priv fn _outlives(self, target: *Expr) -> string {
        if target == &null { return ""; }
        var e = self._tu.strip_parens(target);
        if e == &null { return ""; }
        if isa::<NamedIdentExpr>(e) {
            var d = cast::<NamedIdentExpr>(e)->resolved_decl;
            if (d == &null) || (!isa::<VariableDecl>(d)) { return ""; }
            var v = cast::<VariableDecl>(d);
            var nm = "\x27" + self._tu.decl_name(d) + "\x27";
            if self._is_global(v) { return "is stored to the static variable " + nm; }
            if self._outer_local(d) { return "is stored to " + nm + ", which is declared outside the scope's block"; }
            return "";
        }
        if isa::<UnaryOperatorExpr>(e) {
            var u = cast::<UnaryOperatorExpr>(e);
            if (u->op_token.kind == TokenKind::OpStar) && (u->fix == UnaryOperatorExpr::Fix::Prefix) { return self._base_outlives(u->operand); }
            return "";
        }
        if isa::<SubscriptExpr>(e) { return self._base_outlives(cast::<SubscriptExpr>(e)->base); }
        if isa::<ChainExpr>(e) {
            var ch = cast::<ChainExpr>(e);
            // A static member (`T::cache`) is a global like any other.
            if ch->steps.size() > 0 {
                var last = dyn_cast::<VariableDecl>(ch->steps.get(ch->steps.size() - 1)->resolved_decl);
                if (last != &null) && self._is_global(last) {
                    return "is stored to the static variable \x27" + self._tu.decl_name(static_cast::<*Decl>(last)) + "\x27";
                }
            }
            return self._base_outlives(ch->base);
        }
        return "";
    }

    /// A store through \p base (`*b = p`, `b->f = p`, `b.f = p`, `b[i] =
    /// p`) outlives the scope when b does: a global, a parameter, or a
    /// local of an outer block.
    priv fn _base_outlives(self, base_in: *Expr) -> string {
        if base_in == &null { return ""; }
        var b = self._tu.strip_parens(base_in);
        if b == &null { return ""; }
        if isa::<ChainExpr>(b) { return self._outlives(b); }
        if !isa::<NamedIdentExpr>(b) { return ""; }
        var d = cast::<NamedIdentExpr>(b)->resolved_decl;
        if d == &null { return ""; }
        var nm = "\x27" + self._tu.decl_name(d) + "\x27";
        if isa::<ParamDecl>(d) { return "is stored through the parameter " + nm + ", which outlives the scope"; }
        if !isa::<VariableDecl>(d) { return ""; }
        if self._is_global(cast::<VariableDecl>(d)) { return "is stored through the static variable " + nm; }
        if self._outer_local(d) { return "is stored through " + nm + ", which is declared outside the scope's block"; }
        return "";
    }

    /// A local of this function declared in a block outside the open
    /// scope's (the scope's own block, and deeper, die with it).
    priv fn _outer_local(self, d: *Decl) -> bool {
        for var i: usize = 0; i < self._locals.size(); ++i {
            if self._locals[i] == d { return self._local_depth[i] < self._scope_depth; }
        }
        return false;
    }

    priv fn _is_tainted(self, d: *Decl) -> bool {
        for var i: usize = 0; i < self._tainted.size(); ++i {
            if self._tainted[i] == d { return true; }
        }
        return false;
    }

    /// Static storage: a file or module variable, a static member, a
    /// `static` / `thread` local. A local was never indexed into a scope
    /// table, so it has no semantic_dc.
    priv fn _is_global(self, v: *VariableDecl) -> bool {
        if v->storage == StorageClass::Eval { return false; }
        if (v->storage == StorageClass::Static) || v->is_thread { return true; }
        var dc = reinterpret_cast::<*DeclContext>(v->semantic_dc);
        if dc == &null { return false; }
        return (dc->dc_kind == DeclContextKind::TranslationUnit)
            || (dc->dc_kind == DeclContextKind::Module)
            || dc->is_type_scope();
    }

    /// A call whose result comes from the allocator in effect.
    priv fn _is_producer(self, c: *CallExpr) -> bool {
        var d = self._callee_decl(c);
        if (d == &null) || (!isa::<FunctionDecl>(d)) || (!self._from_builtin(d)) { return false; }
        var nm = self._tu.decl_name(d);
        return (nm == AllocNames::create()) || (nm == AllocNames::try_create())
            || (nm == AllocNames::create_slice()) || (nm == AllocNames::alloc_raw())
            || (nm == AllocNames::resize_raw());
    }

    /// `var s = AllocatorScope<A>()`: by its type, written or inferred.
    priv fn _is_scope_guard(self, v: *VariableDecl) -> bool {
        var t: *Type = &null;
        if (v->type_ != &null) && (v->type_->canonical != &null) { t = v->type_->canonical; }
        else if v->init != &null { t = v->init->type_; }
        var u = canon_unqual(t);
        if (u == &null) || (!isa::<RecordType>(u)) { return false; }
        var rd = cast::<RecordType>(u)->decl;
        if (rd == &null) || (!self._from_builtin(rd)) { return false; }
        return self._tu.decl_name(self._tu.pattern_of(rd)) == AllocNames::scope_guard();
    }

    priv fn _from_builtin(self, d: *Decl) -> bool {
        return self.sc->g->is_builtin_fid(self._tu.fid_of(d));
    }

    /// What \p n calls, or null (a function value, an unresolved name).
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

    // === reporting ========================================================

    /// \p what: the rest of "a pointer from the allocator scope <what>".
    priv fn _warn(self, at_e: *Expr, what: string) {
        if at_e == &null { return; }
        var at = at_e->range;
        var b = self.sc->diag->report(DiagID::SC001W, at.start,
            "a pointer from the allocator scope " + what + "; it dangles once the scope closes");
        b.first(at);
        if self._scope_var != &null {
            b.note(self._scope_var->range.start,
                "the scope is opened here, and closing it at the end of this block frees everything allocated in it"
            ).first(self._scope_var->range);
        }
        b.emit();
    }
}
