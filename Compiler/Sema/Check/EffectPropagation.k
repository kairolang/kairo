/// --- The Kairo Project --------------- Sema/Check/EffectPropagation.k --- ///
///
///   \brief Infer the panic set of every function and closure (PANIC.md §2).
///
///   \detail
///     A panicking body's set is the union of what it raises (`panic X`
///     adds X's type) and what its callees' sets leave after the `try`
///     arms around the call discharge them (§2.1). A body declared with
///     `panic(E1, E2)` has its set fixed; one with a bare `panic` has it
///     inferred here; a body with no specifier has the empty set.
///
///     Three pieces, one per job:
///       - the set helpers: a set is canonical (§1.3) -- each type its
///         canonical, unqualified, once, in canonical_set's order;
///       - PanicWalk, the walker over ONE body: every site that may panic,
///         what reaches each enclosing `try`, and what leaves the body.
///         PanicEffectChecking reads the same walk to report;
///       - EffectTable, the solve: every bare-`panic` body of a group of
///         TUs, iterated to a fixpoint (§2.5). Sets only grow and are
///         bounded by the types the bodies name, so it terminates. It is
///         the barrier (§2.2): a callee is always in its caller's import
///         closure, so the driver groups the graph by import cycle (one TU
///         where there is none), registers a group once every TU of it is
///         Typed, solves, and only then lets any of them go on to
///         PanicEffectChecking (RESOLUTION.md, "The Typed barrier"). With
///         no driver table, PanicEffectChecking builds one for its own TU.
///
///     A set that cannot be known says nothing: a callee whose TU stopped
///     before Typed, an undefined bare-`panic` prototype, a generic or
///     generator `panic` function (each gated where it is declared). A
///     call to it adds nothing and is never reported unhandled.
///
///     The canonical ORDER is by spelling (TypeUtil::str), with the pointer
///     breaking ties between equal spellings. It is a placeholder for the
///     type-id order P1 introduces (§1.3): stable run to run, which a
///     pointer order is not, so every message naming a set reads the same.
///
///   Phase: CHECK (the solve runs at the Typed barrier; see Sema.k)
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
import Sema::Resolve::NameLookup::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Kind::StmtKind::*;
import AST::Kind::TypeKind::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Token::TokenKind::*;
import Location::SourceRange::*;

// === sets ===================================================================

/// \p a before \p b in the canonical order: by spelling, then by address.
fn pset_before(tu: *TypeUtil, a: *Type, b: *Type) -> bool {
    var sa = tu->str(a);
    var sb = tu->str(b);
    if sa != sb { return sa < sb; }
    return reinterpret_cast::<u64>(a) < reinterpret_cast::<u64>(b);
}

/// \p t is in \p s (canonical, unqualified on both sides).
fn pset_has(s: *vec::<*Type>, t: *Type) -> bool {
    for var i: usize = 0; i < s->size(); ++i {
        if (*s)[i] == t { return true; }
    }
    return false;
}

/// Insert \p t into \p s where the order puts it; false when it was there.
fn pset_add(tu: *TypeUtil, s: *vec::<*Type>, t_in: *Type) -> bool {
    if t_in == &null { return false; }
    var t = canon_unqual(t_in);
    if t == &null { return false; }
    if pset_has(s, t) { return false; }
    var at: usize = s->size();
    for var i: usize = 0; i < s->size(); ++i {
        if pset_before(tu, t, (*s)[i]) { at = i; break; }
    }
    s->push_back(t);
    var j = s->size() - 1;
    while j > at {
        (*s)[j] = (*s)[j - 1];
        j -= 1;
    }
    (*s)[at] = t;
    return true;
}

/// The canonical set of a written list (`panic(E1, E2)`): false when an
/// element did not resolve, so the set is not known.
fn canonical_set(tu: *TypeUtil, written: *FrozenList::<*Type>, out: *vec::<*Type>) -> bool {
    for var i: usize = 0; i < written->size(); ++i {
        var w = (*written)[i];
        if (w == &null) || (w->canonical == &null) || w->is_poisoned() { return false; }
        pset_add(tu, out, w->canonical);
    }
    return true;
}

/// `'A', 'B' and 'C'`: a set as a message names it.
fn pset_names(tu: *TypeUtil, s: *vec::<*Type>) -> string {
    var out = "";
    for var i: usize = 0; i < s->size(); ++i {
        if i > 0 {
            if i + 1 == s->size() { out += " and "; } else { out += ", "; }
        }
        out += "\x27" + tu->str((*s)[i]) + "\x27";
    }
    return out;
}

/// `A, B`: a set as the source spells it, for a fix-it.
fn pset_spelling(tu: *TypeUtil, s: *vec::<*Type>) -> string {
    var out = "";
    for var i: usize = 0; i < s->size(); ++i {
        if i > 0 { out += ", "; }
        out += tu->str((*s)[i]);
    }
    return out;
}

// === what a callee may panic with ============================================

/// What a set query found.
enum PanicKnown derives u8 {
    No = 0,     ///< it does not panic.
    Set,        ///< it panics with the set written to `out`.
    Unknown,    ///< nobody can tell (file header): say nothing.
}

/// The function a redeclaration chain's facts are read from: its
/// definition when it has one, else \p f itself.
fn panic_home(f: *FunctionDecl) -> *FunctionDecl {
    if f == &null { return f; }
    var d = f->definition();
    if d != &null { return d; }
    return f;
}

/// A function some enclosing declaration of which is generic (a template,
/// a member of one, or an extension of one): its body is checked per
/// instance, which needs M2 (§2.6).
fn panic_in_generic(d_in: *Decl) -> bool {
    var d = d_in;
    for var depth: u32 = 0; (d != &null) && (depth < 64); ++depth {
        if decl_generic_params(d).size() > 0 { return true; }
        var dc = reinterpret_cast::<*DeclContext>(d->semantic_dc);
        if dc == &null { return false; }
        d = dc->owner_decl();
    }
    return false;
}

/// Any constructor (a transfer one included) or the destructor: they never
/// panic (USER 2026-10-27; PanicEffectChecking reports a `panic` on one), so
/// a call of one adds nothing, whatever it was marked.
fn panic_lifecycle_fn(tu: *TypeUtil, f: *FunctionDecl) -> bool {
    if f == &null { return false; }
    if f->transfer != TransferKind::NotTransfer { return true; }
    if f->is_operator {
        return (f->op_token.size() > 0) && (f->op_token[0].kind == TokenKind::KwDelete);
    }
    if !f->is_method() { return false; }
    var dc = reinterpret_cast::<*DeclContext>(f->semantic_dc);
    if (dc == &null) || (!dc->is_type_scope()) || (dc->dc_owner == &null) { return false; }
    return tu->decl_name(static_cast::<*Decl>(f)) == tu->decl_name(dc->dc_owner);
}

/// The final set of \p f_in into \p out.
fn panic_set_of_fn(tu: *TypeUtil, f_in: *FunctionDecl, out: *vec::<*Type>) -> PanicKnown {
    if f_in == &null { return PanicKnown::Unknown; }
    var f = panic_home(f_in);
    if (!f->is_panic()) && (!f_in->is_panic()) { return PanicKnown::No; }
    if panic_lifecycle_fn(tu, f) { return PanicKnown::No; }
    // A `where` group is one function to its callers; a `panic` member is
    // WhereGuardCheck's SC116E until the dispatcher's set (the union) is
    // built with P6.
    if f->where_lead != &null { return PanicKnown::Unknown; }
    if f->panic_state == PanicSetState::Final {
        for var i: usize = 0; i < f->panic_eff.size(); ++i { out->push_back(f->panic_eff[i]); }
        return (PanicKnown::Set) if (out->size() > 0) else (PanicKnown::No);
    }
    if f->panic_state == PanicSetState::Unknown { return PanicKnown::Unknown; }
    // Declared: the set is the declaration, whatever the body does (a body
    // breaking it is reported at the body).
    if f->has_panic_set() {
        var s = vec::<*Type>();
        if !canonical_set(tu, &(f->panic_set), &s) { return PanicKnown::Unknown; }
        for var i: usize = 0; i < s.size(); ++i { out->push_back(s[i]); }
        return PanicKnown::Set;
    }
    // A bare `panic` nobody solved: no body here, or a TU that stopped.
    return PanicKnown::Unknown;
}

/// Write \p s as the final set of \p f's whole redeclaration chain.
fn panic_store_fn(ctx: *ASTContext, f: *FunctionDecl, s: *vec::<*Type>, st: PanicSetState) {
    if f == &null { return; }
    var cur = f;
    for var guard: u32 = 0; guard < 4096; ++guard {
        cur->panic_eff.from_vec(s, ctx);
        cur->panic_state = st;
        cur = cur->next_in_chain();
        if (cur == f) || (cur == &null) { break; }
    }
}

/// The set a `fn` value of type \p t_in panics with: the effect is part of
/// the `fn` type's canonical (CanonicalTypeStore::func), so the value's
/// type says it. A bare `panic` with no set is a closure or function value
/// whose set was never declared, which PanicEffectChecking reports where
/// it is written: unknown here.
fn panic_set_of_fn_type(tu: *TypeUtil, t_in: *Type, out: *vec::<*Type>) -> PanicKnown {
    if t_in == &null { return PanicKnown::No; }
    var t = canon_unqual(tu->strip_nullable(canon_unqual(t_in)));
    if (t == &null) || (!isa::<FunctionPointerType>(t)) { return PanicKnown::No; }
    var f = cast::<FunctionPointerType>(t);
    if !f->canon_panics { return PanicKnown::No; }
    if f->panic_set.size() == 0 { return PanicKnown::Unknown; }
    for var i: usize = 0; i < f->panic_set.size(); ++i { out->push_back(f->panic_set[i]); }
    return PanicKnown::Set;
}

// === the walk over one body ==================================================

/// One site that may panic: a `panic` statement, or a call (any form X
/// resolved to a function) whose callee's set is not empty.
class PanicSite {
    pub var range:  SourceRange;
    pub var callee: *Decl = &null;          ///< the FunctionDecl called; null for a `panic`.
    pub var raise:  *PanicStmt = &null;     ///< the `panic` statement; null for a call.
    pub var all:    vec::<*Type>;           ///< everything it may panic with.
    pub var left:   vec::<*Type>;           ///< what no enclosing `try` discharges.
    fn PanicSite(self) { }
}

/// One `try`, as the walk saw it: what reached it from its body, and the
/// arms. `node` is the TryCatchStmt or TryCatchExpr.
class PanicTry {
    pub var stmt:  *TryCatchStmt = &null;
    pub var expr:  *TryCatchExpr = &null;
    pub var reach: vec::<*Type>;            ///< the body's set (§3.1).
    pub var types: vec::<*Type>;            ///< each typed arm's filter, canonical; null for an unresolved or bare one.
    pub var bare:  bool = false;            ///< it has a bare `catch`.
    fn PanicTry(self) { }
}

/// The walk over ONE body (a function's, a closure's, an initializer's):
/// nested functions and closures are their own bodies and are not entered.
class PanicWalk derives RecursiveASTVisitor::<PanicWalk> {
    pub var sc: *SemaContext;
    pub var tu: TypeUtil;

    /// Every site, in walk order. Only kept when `keep_sites`.
    pub var sites: vec::<PanicSite>;
    pub var keep_sites: bool = false;
    /// What leaves the body: the union of every site's `left`.
    pub var escape: vec::<*Type>;
    /// Every `try` met, in walk order (a nested one after its parent).
    pub var tries: vec::<PanicTry>;

    /// The `try`s around the walk, innermost last: indices into `tries`.
    priv var _open: vec::<usize>;
    /// The catch arm being walked, innermost last: its binding's decl, and
    /// the `try` it belongs to. A `panic e` of a bare arm's binding re-panics
    /// whatever that arm caught.
    priv var _arm_decl: vec::<*Decl>;
    priv var _arm_try:  vec::<usize>;
    priv var _arm_bare: vec::<bool>;
    priv var _depth: u32 = 0;

    fn PanicWalk(self, sc: *SemaContext) {
        self.sc = sc;
        self.tu = TypeUtil(sc);
    }

    // --- entry points --------------------------------------------------------

    fn walk_fn(self, f: *FunctionDecl) {
        if f == &null { return; }
        if f->body_block != &null { self._root_stmt(static_cast::<*Stmt>(f->body_block)); }
        if f->body_expr  != &null { self._root_expr(f->body_expr); }
    }

    fn walk_closure(self, c: *ClosureExpr) {
        if c == &null { return; }
        if c->body_block != &null { self._root_stmt(static_cast::<*Stmt>(c->body_block)); }
        if c->body_expr  != &null { self._root_expr(c->body_expr); }
    }

    fn walk_expr(self, e: *Expr) { if e != &null { self._root_expr(e); } }
    fn walk_stmt(self, s: *Stmt) { if s != &null { self._root_stmt(s); } }

    priv fn _root_stmt(self, s: *Stmt) {
        self._depth += 1;
        self.dyn()->dispatch_stmt(s);
        self._depth -= 1;
    }

    priv fn _root_expr(self, e: *Expr) {
        self._depth += 1;
        self.dyn()->dispatch_expr(e);
        self._depth -= 1;
    }

    // --- nested bodies are their own ---------------------------------------

    fn traverse_function_decl(self, n: *FunctionDecl) -> *FunctionDecl { return n; }
    fn traverse_closure_expr(self, n: *ClosureExpr) -> *ClosureExpr { return n; }
    fn traverse_class_decl(self, n: *ClassDecl) -> *ClassDecl { return n; }
    fn traverse_struct_decl(self, n: *StructDecl) -> *StructDecl { return n; }
    fn traverse_enum_decl(self, n: *EnumDecl) -> *EnumDecl { return n; }
    fn traverse_union_decl(self, n: *UnionDecl) -> *UnionDecl { return n; }
    fn traverse_interface_decl(self, n: *InterfaceDecl) -> *InterfaceDecl { return n; }
    fn traverse_extension_decl(self, n: *ExtensionDecl) -> *ExtensionDecl { return n; }

    // --- sites ----------------------------------------------------------------

    fn visit_panic_stmt(self, n: *PanicStmt) -> bool {
        if n->payload == &null { return true; }
        var s = vec::<*Type>();
        // `panic e` of a bare arm's binding re-panics what that arm caught:
        // everything its `try` left after the typed arms before it.
        var rp = self._bare_repanic(n->payload);
        if rp >= 0 {
            var t = &(self.tries[static_cast::<usize>(rp)]);
            for var i: usize = 0; i < t->reach.size(); ++i {
                var x = t->reach[i];
                if !pset_has(&(t->types), x) { s.push_back(x); }
            }
        } else {
            var pt = n->payload->type_;
            if (pt == &null) || n->payload->is_poisoned() { return true; }
            var c = canon_unqual(pt);
            if (c == &null) || self.tu.is_never(c) { return true; }
            if c->is_dependent() || c->is_instantiation_dependent() { return true; }
            s.push_back(c);
        }
        self._site(n->range, &null, n, &s);
        return true;
    }

    fn visit_call_expr(self, n: *CallExpr) -> bool {
        if n->is_poisoned() { return true; }
        var f = self._callee_fn(n);
        if f != &null {
            self._call(n->range, f);
            return true;
        }
        // Through a `fn` value.
        var ce = self.tu.strip_parens(n->callee);
        if (ce == &null) || (ce->type_ == &null) { return true; }
        var s = vec::<*Type>();
        if panic_set_of_fn_type(&(self.tu), ce->type_, &s) == PanicKnown::Set {
            self._site(n->range, &null, &null, &s);
        }
        return true;
    }

    fn visit_unary_operator_expr(self, n: *UnaryOperatorExpr) -> bool {
        self._op(n->range, n->resolved_op);
        return true;
    }
    fn visit_binary_operator_expr(self, n: *BinaryOperatorExpr) -> bool {
        self._op(n->range, n->resolved_op);
        return true;
    }
    fn visit_assign_operator_expr(self, n: *AssignOperatorExpr) -> bool {
        self._op(n->range, n->resolved_op);
        return true;
    }
    fn visit_subscript_expr(self, n: *SubscriptExpr) -> bool {
        self._op(n->range, n->resolved_op);
        return true;
    }
    fn visit_type_cast_expr(self, n: *TypeCastExpr) -> bool {
        self._op(n->range, n->resolved_op);
        return true;
    }

    /// `for x in r` over a record's `op in`: the operator is called.
    fn visit_ranged_for_stmt(self, n: *RangedForStmt) -> bool {
        if (n->iter_op != &null) && isa::<FunctionDecl>(n->iter_op) {
            var r = (n->iterable->range) if (n->iterable != &null) else (n->range);
            self._call(r, cast::<FunctionDecl>(n->iter_op));
        }
        return true;
    }

    priv fn _op(self, at: SourceRange, d: *Decl) {
        if (d == &null) || (!isa::<FunctionDecl>(d)) { return; }
        self._call(at, cast::<FunctionDecl>(d));
    }

    priv fn _call(self, at: SourceRange, f: *FunctionDecl) {
        var s = vec::<*Type>();
        if panic_set_of_fn(&(self.tu), f, &s) != PanicKnown::Set { return; }
        self._site(at, static_cast::<*Decl>(f), &null, &s);
    }

    /// The function a call selected, or null (CallLowering's rule).
    priv fn _callee_fn(self, c: *CallExpr) -> *FunctionDecl {
        if (c->ctor_decl != &null) && isa::<FunctionDecl>(c->ctor_decl) { return cast::<FunctionDecl>(c->ctor_decl); }
        var e = self.tu.strip_parens(c->callee);
        if e == &null { return &null; }
        var d: *Decl = &null;
        if isa::<NamedIdentExpr>(e) { d = cast::<NamedIdentExpr>(e)->resolved_decl; }
        else if isa::<ChainExpr>(e) {
            var ch = cast::<ChainExpr>(e);
            if ch->steps.size() > 0 {
                var st = ch->steps.get(ch->steps.size() - 1);
                d = st->resolved_decl;
                if (d == &null) && (st->name != &null) { d = st->name->resolved_decl; }
            }
        }
        return dyn_cast::<FunctionDecl>(d);
    }

    /// Route one site's set through the open `try`s, innermost first: each
    /// sees what is left, keeps it as reached, and discharges its arms.
    priv fn _site(self, at: SourceRange, callee: *Decl, raise: *PanicStmt, s: *vec::<*Type>) {
        if s->size() == 0 { return; }
        var left = vec::<*Type>();
        for var i: usize = 0; i < s->size(); ++i { pset_add(&(self.tu), &left, (*s)[i]); }
        var all = left;
        var k = self._open.size();
        while (k > 0) && (left.size() > 0) {
            k -= 1;
            var t = &(self.tries[self._open[k]]);
            var next = vec::<*Type>();
            for var i: usize = 0; i < left.size(); ++i {
                pset_add(&(self.tu), &(t->reach), left[i]);
                if t->bare { continue; }
                if pset_has(&(t->types), left[i]) { continue; }
                next.push_back(left[i]);
            }
            left = next;
        }
        for var i: usize = 0; i < left.size(); ++i { pset_add(&(self.tu), &(self.escape), left[i]); }
        if self.keep_sites {
            var ps = PanicSite();
            ps.range  = at;
            ps.callee = callee;
            ps.raise  = raise;
            ps.all    = all;
            ps.left   = left;
            self.sites.push_back(ps);
        }
    }

    /// The `try` index of the bare arm whose binding \p e names, or -1.
    priv fn _bare_repanic(self, e_in: *Expr) -> i64 {
        var e = self.tu.strip_parens(e_in);
        if (e == &null) || (!isa::<NamedIdentExpr>(e)) { return -1; }
        var d = cast::<NamedIdentExpr>(e)->resolved_decl;
        if d == &null { return -1; }
        var k = self._arm_decl.size();
        while k > 0 {
            k -= 1;
            if self._arm_decl[k] == d {
                if !self._arm_bare[k] { return -1; }
                return static_cast::<i64>(self._arm_try[k]);
            }
        }
        return -1;
    }

    // --- try / catch ----------------------------------------------------------

    /// The body under the `try`; each arm with the `try` closed, so a panic
    /// in an arm goes to the enclosing one, never to a sibling arm.
    fn traverse_try_catch_stmt(self, n: *TryCatchStmt) -> *TryCatchStmt {
        if n == &null { return n; }
        var t = PanicTry();
        t.stmt = n;
        for var i: usize = 0; i < n->arms.size(); ++i {
            var arm = n->arms.get(i);
            if arm->filter == &null { t.bare = true; continue; }
            var c = arm->filter->canonical;
            if c != &null { pset_add(&(self.tu), &(t.types), c); }
        }
        var idx = self.tries.size();
        self.tries.push_back(t);
        self._open.push_back(idx);
        if n->try_body != &null { self.dyn()->dispatch_stmt(static_cast::<*Stmt>(n->try_body)); }
        self._open.pop_back();
        for var i: usize = 0; i < n->arms.size(); ++i {
            var arm = n->arms.get(i);
            self._arm_decl.push_back(arm->decl);
            self._arm_try.push_back(idx);
            self._arm_bare.push_back(arm->filter == &null);
            if arm->body != &null { self.dyn()->dispatch_stmt(static_cast::<*Stmt>(arm->body)); }
            self._arm_decl.pop_back();
            self._arm_try.pop_back();
            self._arm_bare.pop_back();
        }
        return n;
    }

    fn traverse_try_catch_expr(self, n: *TryCatchExpr) -> *TryCatchExpr {
        if n == &null { return n; }
        var t = PanicTry();
        t.expr = n;
        for var i: usize = 0; i < n->catch_arms.size(); ++i {
            var arm = n->catch_arms.get(i);
            if arm->filter == &null { t.bare = true; continue; }
            var c = arm->filter->canonical;
            if c != &null { pset_add(&(self.tu), &(t.types), c); }
        }
        var idx = self.tries.size();
        self.tries.push_back(t);
        self._open.push_back(idx);
        if n->try_expr != &null { self.dyn()->dispatch_expr(n->try_expr); }
        self._open.pop_back();
        for var i: usize = 0; i < n->catch_arms.size(); ++i {
            var arm = n->catch_arms.get(i);
            self._arm_decl.push_back(arm->decl);
            self._arm_try.push_back(idx);
            self._arm_bare.push_back(arm->filter == &null);
            if arm->body != &null { self.dyn()->dispatch_expr(arm->body); }
            self._arm_decl.pop_back();
            self._arm_try.pop_back();
            self._arm_bare.pop_back();
        }
        return n;
    }
}

// === the solve ==============================================================

/// One body the solve infers: a bare-`panic` function or closure, and the
/// context of the TU it is in.
class EffectEntry {
    pub var fd: *FunctionDecl = &null;
    pub var ce: *ClosureExpr  = &null;
    pub var sc: *SemaContext  = &null;
    fn EffectEntry(self) { }
}

/// A bare-`panic` function whose set can be inferred: it has a body, and
/// it is not generic, a generator, `async`, or a `where` candidate (each
/// gated at its declaration by PanicEffectChecking).
fn panic_inferable_fn(f: *FunctionDecl) -> bool {
    if (f == &null) || f->is_poisoned() { return false; }
    if (!f->is_panic()) || f->has_panic_set() { return false; }
    if (f->body_block == &null) && (f->body_expr == &null) { return false; }
    if f->is_generator || f->is_async() || (f->where_lead != &null) { return false; }
    if panic_in_generic(static_cast::<*Decl>(f)) { return false; }
    return true;
}

fn panic_inferable_closure(c: *ClosureExpr) -> bool {
    if (c == &null) || c->is_poisoned() { return false; }
    var panics = (static_cast::<u16>(c->modifiers) & static_cast::<u16>(FnModifier::IsPanic)) != 0;
    if (!panics) || (c->panic_set.size() > 0) { return false; }
    if c->generic_params.size() > 0 { return false; }
    var asy = (static_cast::<u16>(c->modifiers) & static_cast::<u16>(FnModifier::IsAsync)) != 0;
    return !asy;
}

/// Finds every inferable body in one TU.
class EffectCollect derives RecursiveASTVisitor::<EffectCollect> {
    pub var sc: *SemaContext;
    pub var out: *vec::<EffectEntry>;
    priv var _seen: llvm::DenseSet::<u64>;

    fn EffectCollect(self, sc: *SemaContext, out: *vec::<EffectEntry>) {
        self.sc  = sc;
        self.out = out;
    }

    fn run(self) {
        var tu = self.sc->tu;
        if (tu == &null) || (tu->program == &null) { return; }
        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); ++i {
            var item = *(items->get(i));
            switch item.get_kind() {
                case TopLevelKind::Decl { self.dyn()->dispatch_decl(item.as_decl()); }
                case TopLevelKind::Stmt { self.dyn()->dispatch_stmt(item.as_stmt()); }
                case TopLevelKind::Expr { self.dyn()->dispatch_expr(item.as_expr()); }
            }
        }
    }

    fn visit_function_decl(self, n: *FunctionDecl) -> bool {
        if !panic_inferable_fn(n) { return true; }
        var key = reinterpret_cast::<u64>(n);
        if self._seen.contains(key) { return true; }
        self._seen.insert(key);
        var e = EffectEntry();
        e.fd = n;
        e.sc = self.sc;
        self.out->push_back(e);
        return true;
    }

    fn visit_closure_expr(self, n: *ClosureExpr) -> bool {
        if !panic_inferable_closure(n) { return true; }
        var key = reinterpret_cast::<u64>(n);
        if self._seen.contains(key) { return true; }
        self._seen.insert(key);
        var e = EffectEntry();
        e.ce = n;
        e.sc = self.sc;
        self.out->push_back(e);
        return true;
    }
}

/// The build-wide table: every inferable body of the graph, solved at once.
class EffectTable {
    pub var entries: vec::<EffectEntry>;
    pub var solved:  bool = false;
    pub var rounds:  u32  = 0;

    fn EffectTable(self) { }

    /// Empty, for the next group of the graph (the driver solves one import
    /// cycle at a time; every set it solved before stays on its decls).
    fn reset(self) {
        self.entries.clear();
        self.solved = false;
        self.rounds = 0;
    }

    /// Register \p sc's TU. Its bodies start from the empty set, Final, so a
    /// query during the solve reads the set as it grows.
    fn add_tu(self, sc: *SemaContext) {
        if (sc == &null) || (sc->tu == &null) { return; }
        var from = self.entries.size();
        var col = EffectCollect(sc, &(self.entries));
        col.run();
        var empty = vec::<*Type>();
        for var i: usize = from; i < self.entries.size(); ++i {
            var e = self.entries[i];
            if e.fd != &null { panic_store_fn(sc->ctx, e.fd, &empty, PanicSetState::Final); }
            if e.ce != &null {
                e.ce->panic_eff.from_vec(&empty, sc->ctx);
                e.ce->panic_state = PanicSetState::Final;
            }
        }
    }

    /// Iterate every entry's walk until no set grows (§2.5).
    fn solve(self) {
        var changed = true;
        while changed {
            changed = false;
            self.rounds += 1;
            for var i: usize = 0; i < self.entries.size(); ++i {
                var e = self.entries[i];
                var w = PanicWalk(e.sc);
                var cur = vec::<*Type>();
                if e.fd != &null {
                    w.walk_fn(e.fd);
                    for var k: usize = 0; k < e.fd->panic_eff.size(); ++k { cur.push_back(e.fd->panic_eff[k]); }
                } else {
                    w.walk_closure(e.ce);
                    for var k: usize = 0; k < e.ce->panic_eff.size(); ++k { cur.push_back(e.ce->panic_eff[k]); }
                }
                var grew = false;
                for var k: usize = 0; k < w.escape.size(); ++k {
                    if pset_add(&(w.tu), &cur, w.escape[k]) { grew = true; }
                }
                if !grew { continue; }
                changed = true;
                if e.fd != &null { panic_store_fn(e.sc->ctx, e.fd, &cur, PanicSetState::Final); }
                else { e.ce->panic_eff.from_vec(&cur, e.sc->ctx); }
            }
        }
        self.solved = true;
    }
}

/// The table \p sc's driver solved, or null.
fn effects_of(sc: *SemaContext) -> *EffectTable {
    if sc == &null { return &null; }
    return reinterpret_cast::<*EffectTable>(sc->effects);
}
