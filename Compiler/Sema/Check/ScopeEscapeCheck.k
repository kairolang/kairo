/// --- The Kairo Project ---------------- Sema/Check/ScopeEscapeCheck.k --- ///
///
///   \brief A pointer from an open AllocatorScope that outlives it:
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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "vector"

import AST::DeclFacts::is_global_storage
import AST::ExprFacts::callee_decl
import AST::LangItems::AllocNames
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    FunctionDecl,
    ParamDecl,
    StorageClass,
    VariableDecl,
}
import AST::Node::Expressions::{
    AssignOperatorExpr,
    CallExpr,
    ClosureExpr,
    SubscriptExpr,
    TypeCastExpr,
    UnaryOperatorExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Statements::{
    CompoundStmt,
    ReturnStmt,
}
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Registry::DiagID
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::TypeUtil::TypeUtil
import Token::TokenKind::TokenKind

/// An open allocator scope: its guard, and the depth of the block that
/// declares the guard and closes the scope when it ends.
struct OpenScope {
    pub var guard: unsafe *VariableDecl = &null
    pub var depth: u32                  = 0
}

/// A local of the function being walked. `depth` is the block that
/// declares it. `origin` is the depth of the scope whose pointer it holds,
/// 0 when it holds none.
struct ScopeLocal {
    pub var decl:   unsafe *Decl = &null
    pub var depth:  u32          = 0
    pub var origin: u32          = 0
}

pub class ScopeEscapeCheck derives RecursiveASTVisitor<ScopeEscapeCheck> {
    pub var  sc:  unsafe *SemaContext
    priv var _tu: TypeUtil

    /// Block nesting inside the current function body (the body is 1; 0
    /// outside any function).
    priv var _depth: u32 = 0
    /// The open scopes, outermost first. A scope closes with the block
    /// that declares its guard. A pointer belongs to the scope that was
    /// innermost when it was allocated, and an inner scope opening or
    /// closing changes nothing for a pointer of an outer one.
    priv var _scopes: cxx::std::vector<OpenScope>
    /// The current function's locals, in declaration order. A block's
    /// locals die with it, so the taint a local carries dies there too.
    priv var _locals: cxx::std::vector<ScopeLocal>

    fn ScopeEscapeCheck(self, sc: unsafe *SemaContext) {
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

        // Nothing can open a scope where alloc.k was never loaded.
        if self.sc->g == &null {
            return
        }

        self.run(tu)
    }

    /// # structure

    /// Each function starts clean: a scope, a local or a taint never
    /// crosses into a nested function's body, and comes back after it.
    fn visit_function_decl(self, n: unsafe *FunctionDecl) -> bool {
        if n == &null || n->is_poisoned() {
            return false
        }

        var s_depth  = self._depth
        var s_scopes = self._scopes
        var s_locals = self._locals
        self._depth = 0
        self._scopes.clear()
        self._locals.clear()

        if n->body_block != &null {
            self.dyn()->traverse_block(n->body_block)
        }

        self._depth  = s_depth
        self._scopes = s_scopes
        self._locals = s_locals
        return false
    }

    /// A closure's body is its own function, and where the closure goes is
    /// not followed (see the file header).
    fn visit_closure_expr(self, n: *ClosureExpr) -> bool {
        return false
    }

    fn traverse_compound_stmt(self, n: unsafe *CompoundStmt) -> unsafe *CompoundStmt {
        if n == &null {
            return n
        }

        self._depth += 1
        var unsafe *out = RecursiveASTVisitor<ScopeEscapeCheck>::traverse_compound_stmt(
            self,
            n,
        )

        // The block's locals die with it; so does a scope it opened. A
        // local of an outer block keeps the pointer it was given in here.
        while self._locals.size() > 0
            && self._locals[self._locals.size() - 1].depth >= self._depth {
            self._locals.pop_back()
        }

        while self._scopes.size() > 0
            && self._scopes[self._scopes.size() - 1].depth >= self._depth {
            self._scopes.pop_back()
        }

        self._depth -= 1
        return out
    }

    /// The initializer is walked first: `var p = create<T>()` is a use of
    /// the scope in force before p exists.
    fn traverse_variable_decl(self, n: unsafe *VariableDecl) -> unsafe *VariableDecl {
        if n == &null {
            return n
        }

        var unsafe *out = RecursiveASTVisitor<ScopeEscapeCheck>::traverse_variable_decl(
            self,
            n,
        )

        if self._depth == 0 { // a global: no block owns it.
            return out
        }

        var unsafe *d = unsafe (n as unsafe *Decl)

        var origin = self._escapes(n->init)
        if n->storage == StorageClass::Static || n->is_thread {
            if origin > 0 {
                self._warn(
                    n->init,
                    "initializes the static variable '" + self._tu.decl_name(d) + "'",
                    origin,
                )
            }

            return out
        }

        if self._is_scope_guard(n) {
            self._locals.push_back(
                ScopeLocal { decl: d, depth: self._depth, origin: 0 },
            )

            self._scopes.push_back(OpenScope { guard: n, depth: self._depth })
            return out
        }

        self._locals.push_back(
            ScopeLocal { decl: d, depth: self._depth, origin: origin },
        )

        return out
    }

    /// # the rules

    fn visit_return_stmt(self, n: unsafe *ReturnStmt) -> bool {
        if n == &null {
            return true
        }

        var origin = self._escapes(n->value)
        if origin > 0 {
            self._warn(n->value, "is returned from the function", origin)
        }

        return true
    }

    fn visit_assign_operator_expr(self, n: unsafe *AssignOperatorExpr) -> bool {
        if n == &null || self._scopes.size() == 0 {
            return true
        }

        if n->op_token.kind != TokenKind::OpEqual {
            return true
        }

        var origin = self._escapes(n->rhs)
        if origin == 0 {
            return true
        }

        var why = self._outlives(n->lhs, origin)
        if why != "" {
            self._warn(n->rhs, why, origin)
            return true
        }

        // `q = p` into a local of the scope's own block (or deeper): q
        // holds a scoped pointer from here on. Of two scopes it has held a
        // pointer of, the inner one closes first.
        var unsafe *lhs = self._tu.strip_parens(n->lhs)
        if lhs != &null && isa<NamedIdentExpr>(lhs) {
            var unsafe *v = cast<NamedIdentExpr>(lhs)->resolved_decl
            for var i: usize = 0; i < self._locals.size(); ++i {
                if self._locals[i].decl == v && self._locals[i].origin < origin {
                    self._locals[i].origin = origin
                }
            }
        }

        return true
    }

    /// # queries

    /// The depth of the open scope \p e is a pointer from, or 0 when it is
    /// not one: a producer call takes the innermost scope, a local holding
    /// a scoped pointer answers the scope that pointer came from.
    priv fn _escapes(self, e_in: unsafe *Expr) -> u32 {
        if e_in == &null || self._scopes.size() == 0 {
            return 0
        }

        var unsafe *e = self._tu.strip_parens(e_in)
        if e == &null {
            return 0
        }

        if isa<TypeCastExpr>(e) {
            return self._escapes(cast<TypeCastExpr>(e)->operand)
        }

        if isa<CallExpr>(e) {
            if !self._is_producer(cast<CallExpr>(e)) {
                return 0
            }

            return self._scopes[self._scopes.size() - 1].depth
        }

        if isa<NamedIdentExpr>(e) {
            var unsafe *d = cast<NamedIdentExpr>(e)->resolved_decl
            for var i: usize = 0; i < self._locals.size(); ++i {
                if self._locals[i].decl == d {
                    return self._locals[i].origin
                }
            }
        }

        return 0
    }

    /// Where a store to \p target lands, if that outlives the scope at
    /// depth \p origin: the phrase for the warning, or "" when the target
    /// dies with the scope (or cannot be told).
    priv fn _outlives(self, target: unsafe *Expr, origin: u32) -> string {
        if target == &null {
            return ""
        }

        var unsafe *e = self._tu.strip_parens(target)
        if e == &null {
            return ""
        }

        if isa<NamedIdentExpr>(e) {
            var unsafe *d = cast<NamedIdentExpr>(e)->resolved_decl
            if d == &null || !isa<VariableDecl>(d) {
                return ""
            }

            var unsafe *v = cast<VariableDecl>(d)
            var        nm = "'" + self._tu.decl_name(d) + "'"
            if is_global_storage(v) {
                return "is stored to the static variable " + nm
            }

            if self._outer_local(d, origin) {
                return "is stored to " + nm + ", which is declared outside the scope's block"
            }

            return ""
        }

        if isa<UnaryOperatorExpr>(e) {
            var unsafe *u = cast<UnaryOperatorExpr>(e)
            if u->op_token.kind == TokenKind::OpStar && u->fix == UnaryOperatorExpr::Fix::Prefix {
                return self._base_outlives(u->operand, origin)
            }

            return ""
        }

        if isa<SubscriptExpr>(e) {
            return self._base_outlives(cast<SubscriptExpr>(e)->base, origin)
        }

        if isa<ChainExpr>(e) {
            var unsafe *ch = cast<ChainExpr>(e)
            // A static member (`T::cache`) is a global like any other.
            if ch->steps.size() > 0 {
                var unsafe *last = dyn_cast<VariableDecl>(
                    ch->steps.get(ch->steps.size() - 1)->resolved_decl,
                )

                if last != &null && is_global_storage(last) {
                    return "is stored to the static variable '" + self._tu.decl_name(
                        last,
                    ) + "'"
                }
            }

            return self._base_outlives(ch->base, origin)
        }

        return ""
    }

    /// A store through \p base (`*b = p`, `b->f = p`, `b.f = p`, `b[i] =
    /// p`) outlives the scope at depth \p origin when b does: a global, a
    /// parameter, or a local of an outer block.
    priv fn _base_outlives(self, base_in: unsafe *Expr, origin: u32) -> string {
        if base_in == &null {
            return ""
        }

        var unsafe *b = self._tu.strip_parens(base_in)
        if b == &null {
            return ""
        }

        if isa<ChainExpr>(b) {
            return self._outlives(b, origin)
        }

        if !isa<NamedIdentExpr>(b) {
            return ""
        }

        var unsafe *d = cast<NamedIdentExpr>(b)->resolved_decl
        if d == &null {
            return ""
        }

        var nm = "'" + self._tu.decl_name(d) + "'"
        if isa<ParamDecl>(d) {
            return "is stored through the parameter " + nm + ", which outlives the scope"
        }

        if !isa<VariableDecl>(d) {
            return ""
        }

        if is_global_storage(cast<VariableDecl>(d)) {
            return "is stored through the static variable " + nm
        }

        if self._outer_local(d, origin) {
            return "is stored through " + nm + ", which is declared outside the scope's block"
        }

        return ""
    }

    /// A local of this function declared in a block outside the one of the
    /// scope at depth \p origin (that scope's own block, and deeper, die with
    /// it).
    priv fn _outer_local(self, d: unsafe *Decl, origin: u32) -> bool {
        for var i: usize = 0; i < self._locals.size(); ++i {
            if self._locals[i].decl == d {
                return self._locals[i].depth < origin
            }
        }

        return false
    }

    /// A call whose result comes from the allocator in effect.
    priv fn _is_producer(self, c: unsafe *CallExpr) -> bool {
        var unsafe *d = callee_decl(c)
        if d == &null || !isa<FunctionDecl>(d) || !self._from_builtin(d) {
            return false
        }

        var nm = self._tu.decl_name(d)
        return nm == AllocNames::create()
            || nm == AllocNames::try_create()
            || nm == AllocNames::create_slice()
            || nm == AllocNames::alloc_raw()
            || nm == AllocNames::resize_raw()
    }

    /// `var s = AllocatorScope<A>()`: by its type, written or inferred.
    priv fn _is_scope_guard(self, v: unsafe *VariableDecl) -> bool {
        var t: unsafe *Type = &null
        if v->type_ != &null && v->type_->canonical != &null {
            t = v->type_->canonical
        } else if v->init != &null {
            t = v->init->type_
        }

        var unsafe *u = canon_unqual(t)
        if u == &null || !isa<RecordType>(u) {
            return false
        }

        var unsafe *rd = cast<RecordType>(u)->decl
        if rd == &null || !self._from_builtin(rd) {
            return false
        }

        return self._tu.decl_name(self._tu.pattern_of(rd)) == AllocNames::scope_guard()
    }

    priv fn _from_builtin(self, d: unsafe *Decl) -> bool {
        return self.sc->g->is_builtin_fid(self._tu.fid_of(d))
    }

    /// # reporting

    /// \p what: the rest of "a pointer from the allocator scope <what>".
    /// \p origin: the depth of the scope the pointer is from.
    priv fn _warn(self, at_e: unsafe *Expr, const what: string, origin: u32) {
        if at_e == &null {
            return
        }

        var at = at_e->range
        var b = self.sc->diag->report(
            DiagID::SC225W,
            at.start,
            "a pointer from the allocator scope " + what + "; it dangles once the scope closes",
        )

        b.first(at)
        // The last guard of that block: a second guard in one block is the
        // scope in force from its declaration on.
        var guard: unsafe *VariableDecl = &null
        for var i: usize = 0; i < self._scopes.size(); ++i {
            if self._scopes[i].depth == origin {
                guard = self._scopes[i].guard
            }
        }

        if guard != &null {
            b.note(
                guard->range.start,
                "the scope is opened here, and closing it at the end of this block frees everything allocated in it",
            )->child_first(guard->range)
        }

        b.emit()
    }
}
