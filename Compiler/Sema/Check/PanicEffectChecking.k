/// --- The Kairo Project ------------------- Sema/PanicEffectChecking.k --- ///
///
///   \brief Every panic is handled or propagated (PANIC.md §2, §1.5, §4.5).
///
///   \detail
///     Reads the sets EffectPropagation solved at the Typed barrier and
///     walks each body again with PanicWalk, now keeping its sites. Each
///     site's leftover -- what no enclosing `try` discharges -- must be in
///     the set of the body it is in:
///       - a function or closure with no `panic`: the empty set. An
///         unhandled site is an error naming every unhandled type, with
///         two edits: mark the body `panic`, or handle it at the site;
///       - a declared `panic(E1, E2)`: a type outside it is an error at the
///         site, with an edit adding it to the list;
///       - a bare `panic`: its inferred set, which holds every leftover by
///         construction;
///       - `main` and a script's top level: nothing may reach them; the
///         edit at the site handles it or stops with `crash!()` (§2.4);
///       - a field's or parameter's default: the empty set;
///       - a global's (or static field's) initializer holds no `panic`, no
///         `try` and no panicking call at all: it runs at file scope, with
///         no function to propagate to and no statement expression to put
///         a `try` in (§4.5).
///     A set that is not known says nothing (EffectPropagation).
///
///     Declaration rules: `fn main() panic`; `panic` with `-> !` (§2.8); a
///     `panic` on what is called where no call is written -- a destructor,
///     a transfer or default constructor, an `@implicit` conversion, `op
///     panic` itself -- since nothing could handle it there. Every type a
///     `panic` raises, a set declares or a `catch` names must be a movable,
///     complete value type: not a reference, not `void` (§1.5).
///
///     Gates (SC116E): a `panic` function or closure that is generic or
///     inside a generic (§2.6: needs M2), a generator or `async` (§2.7: the
///     coroutine frame does not exist yet); a panicking site in any of
///     those bodies.
///
///     `unwrap!`, `assert`, `crash!` and the asserting downcast add nothing:
///     they crash, and are in no set (§2.8).
///
///   Phase: CHECK, after the Typed barrier (reads every solved set).
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
import Sema::Type::TypeUtil::*;
import Sema::Resolve::NameLookup::*;
import Sema::Check::EffectPropagation::*;
import Sema::Check::ClassLifecycle::*;
import Sema::Check::ScriptRules::*;
import AST::OperatorFacts::*;
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
import Token::Token::*;
import Token::TokenKind::*;
import Location::SourceRange::*;
import Location::SourceLocation::*;
import Diagnostic::Registry::*;

/// Which body a walk is over: decides what may leave it and how a site
/// that breaks the rule is reported.
enum PanicBody derives u8 {
    Fn,         ///< a function's body.
    Closure,    ///< a closure's body.
    Main,       ///< `main`'s body.
    Script,     ///< a script's top level (main's body, SCRIPT.md).
    Field,      ///< a field's default.
    Param,      ///< a parameter's default.
    Global,     ///< a global's or a static field's initializer.
}

class PanicEffectChecking derives RecursiveASTVisitor::<PanicEffectChecking> {
    pub var sc: *SemaContext;
    priv var _tu: TypeUtil;
    priv var _sr: ScriptRules;
    priv var _script: bool = false;
    /// Functions already judged: a method in a visibility group is reached
    /// through the group and through the method list.
    priv var _seen: llvm::DenseSet::<u64>;
    /// The table this TU's sets come from when the driver set none up.
    priv var _local: EffectTable;
    /// Every catch arm's binding met so far (an arm is visited before its
    /// body): what a re-panic `panic e` names.
    priv var _arm_decls: llvm::DenseSet::<u64>;

    fn PanicEffectChecking(self, sc: *SemaContext) {
        self.sc  = sc;
        self._tu = TypeUtil(sc);
        self._sr = ScriptRules(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Typed);
        var tu = self.sc->tu;
        if (tu == &null) || (tu->program == &null) { return; }

        // No barrier above us: this TU's sets are solved here, alone. A
        // callee in another TU is read as that TU left it.
        var tab = effects_of(self.sc);
        if (tab == &null) || (!tab->solved) {
            self._local.add_tu(self.sc);
            self._local.solve();
        }

        self._script = self._sr.is_script();
        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); ++i {
            var item = *(items->get(i));
            switch item.get_kind() {
                case TopLevelKind::Decl { self.dyn()->dispatch_decl(item.as_decl()); }
                case TopLevelKind::Stmt { self.dyn()->dispatch_stmt(item.as_stmt()); }
                case TopLevelKind::Expr { self.dyn()->dispatch_expr(item.as_expr()); }
            }
        }

        // A script's top level is main's body: its statements, and its
        // bindings' initializers (each deferred one runs at its line in main;
        // a constant one cannot panic).
        if self._script {
            for var i: usize = 0; i < items->size(); ++i {
                var item = *(items->get(i));
                var w = PanicWalk(self.sc);
                w.keep_sites = true;
                if item.get_kind() == TopLevelKind::Stmt {
                    var b = self._sr.binding_of(item);
                    if b != &null {
                        if b->init != &null { w.walk_expr(b->init); }
                    } else {
                        w.walk_stmt(item.as_stmt());
                    }
                } else if item.get_kind() == TopLevelKind::Expr {
                    w.walk_expr(item.as_expr());
                } else {
                    var vd = dyn_cast::<VariableDecl>(item.as_decl());
                    if (vd != &null) && (vd->init != &null) { w.walk_expr(vd->init); }
                }
                self._judge(&w, PanicBody::Script, &null, &null, &null);
            }
        }
    }

    // === bodies ===============================================================

    fn visit_function_decl(self, f: *FunctionDecl) -> bool {
        if (f == &null) || f->is_poisoned() { return true; }
        var key = reinterpret_cast::<u64>(f);
        if self._seen.contains(key) { return true; }
        self._seen.insert(key);
        if decl_is_imported(static_cast::<*Decl>(f)) { return true; }

        self._check_fn_decl(f);
        if (f->body_block == &null) && (f->body_expr == &null) { return true; }
        var w = PanicWalk(self.sc);
        w.keep_sites = true;
        w.walk_fn(f);
        var kind = (PanicBody::Main) if (self._sr.is_main(static_cast::<*Decl>(f))) else (PanicBody::Fn);
        self._judge(&w, kind, f, &null, &null);
        return true;
    }

    fn visit_closure_expr(self, c: *ClosureExpr) -> bool {
        if (c == &null) || c->is_poisoned() { return true; }
        self._check_closure_decl(c);
        var w = PanicWalk(self.sc);
        w.keep_sites = true;
        w.walk_closure(c);
        self._judge(&w, PanicBody::Closure, &null, c, &null);
        return true;
    }

    /// A global's initializer (§4.5); a local's is its function's.
    fn visit_variable_decl(self, v: *VariableDecl) -> bool {
        if (v == &null) || v->is_poisoned() || (v->init == &null) { return true; }
        if self._script { return true; }   // main's body; walked in run().
        if !self._is_global(v) { return true; }
        var w = PanicWalk(self.sc);
        w.keep_sites = true;
        w.walk_expr(v->init);
        self._judge(&w, PanicBody::Global, &null, &null, static_cast::<*Decl>(v));
        return true;
    }

    fn visit_field_decl(self, fd: *FieldDecl) -> bool {
        if (fd == &null) || fd->is_poisoned() || (fd->init == &null) { return true; }
        var w = PanicWalk(self.sc);
        w.keep_sites = true;
        w.walk_expr(fd->init);
        var kind = (PanicBody::Global) if (fd->is_static()) else (PanicBody::Field);
        self._judge(&w, kind, &null, &null, static_cast::<*Decl>(fd));
        return true;
    }

    fn visit_param_decl(self, p: *ParamDecl) -> bool {
        if (p == &null) || p->is_poisoned() || (p->default_val == &null) { return true; }
        var w = PanicWalk(self.sc);
        w.keep_sites = true;
        w.walk_expr(p->default_val);
        self._judge(&w, PanicBody::Param, &null, &null, static_cast::<*Decl>(p));
        return true;
    }

    // === payload types ========================================================

    fn visit_panic_stmt(self, n: *PanicStmt) -> bool {
        if (n->payload == &null) || n->payload->is_poisoned() { return true; }
        // `panic e` of a catch arm's binding re-panics the caught error: its
        // type was judged where it was raised (and a bare arm's binding has
        // no single type).
        var rp = self._repanic_of(n);
        if rp != &null {
            n->repanic = rp;
            return true;
        }
        if n->payload->type_ != &null {
            self._check_payload(n->payload->type_, n->payload->range, "panicked");
        }
        return true;
    }

    fn visit_try_catch_stmt(self, n: *TryCatchStmt) -> bool {
        for var i: usize = 0; i < n->arms.size(); ++i {
            var arm = n->arms.get(i);
            if arm->decl != &null { self._arm_decls.insert(reinterpret_cast::<u64>(arm->decl)); }
            if (arm->filter != &null) && (arm->filter->canonical != &null) && (!self._is_cxx_type(arm->filter->canonical)) {
                self._check_payload(arm->filter->canonical, arm->filter->range, "caught");
            }
        }
        return true;
    }

    fn visit_try_catch_expr(self, n: *TryCatchExpr) -> bool {
        for var i: usize = 0; i < n->catch_arms.size(); ++i {
            var arm = n->catch_arms.get(i);
            if arm->decl != &null { self._arm_decls.insert(reinterpret_cast::<u64>(arm->decl)); }
            if (arm->filter != &null) && (arm->filter->canonical != &null) && (!self._is_cxx_type(arm->filter->canonical)) {
                self._check_payload(arm->filter->canonical, arm->filter->range, "caught");
            }
        }
        return true;
    }

    /// The arm whose binding a `panic e` names, or null.
    priv fn _repanic_of(self, n: *PanicStmt) -> *Decl {
        var e = self._tu.strip_parens(n->payload);
        if (e == &null) || (!isa::<NamedIdentExpr>(e)) { return &null; }
        var d = cast::<NamedIdentExpr>(e)->resolved_decl;
        if d == &null { return &null; }
        if self._arm_decls.contains(reinterpret_cast::<u64>(d)) { return d; }
        return &null;
    }

    /// A C++ type in a `catch`: a C++ exception arm unless the set holds it
    /// (§3.5), so it is never held to the payload rules here.
    priv fn _is_cxx_type(self, t: *Type) -> bool {
        var d = self._tu.record_decl(canon_unqual(t));
        return (d != &null) && decl_is_imported(d);
    }

    /// §1.5: movable, complete, a value; not a reference, not `void`.
    priv fn _check_payload(self, t_in: *Type, at: SourceRange, how: string) {
        if t_in == &null { return; }
        var t = canon_unqual(t_in);
        if (t == &null) || t->is_dependent() || t->is_instantiation_dependent() { return; }
        if self._tu.is_never(t) { return; }
        var nm = self._tu.str(t);
        var why = "";
        if isa::<CXXLValueRefType>(t) || isa::<CXXRValueRefType>(t) { why = "it is a reference; an error is held by value"; }
        else if self._tu.is_void(t) { why = "'void' is not a value"; }
        var d = self._tu.record_decl(t);
        if (why.size() == 0) && (d != &null) && (!decl_is_imported(d)) && (!self._complete(d)) {
            why = "it is incomplete; an error is held by value, so its size must be known";
        }
        if why.size() == 0 {
            var facts = lifecycle_of(self.sc)->facts_of_type(t);
            if facts.movable == LifecycleTri::No {
                why = "it is not movable; an error is returned and propagated by value";
                if facts.why_not_movable.size() > 0 { why = why + " (" + facts.why_not_movable + ")"; }
            }
        }
        if why.size() == 0 { return; }
        var b = self.sc->diag->report(DiagID::SC001E, at.start, f"type '{nm}' cannot be {how}: {why}");
        b.first(at);
        if (d != &null) && d->range.is_valid() {
            b.note(DiagID::SC001N, d->range.start, f"'{nm}' is declared here").first(d->range);
        }
        b.emit();
    }

    priv fn _complete(self, d: *Decl) -> bool {
        if isa::<ClassDecl>(d)  { return cast::<ClassDecl>(d)->has_definition(); }
        if isa::<StructDecl>(d) { return cast::<StructDecl>(d)->has_definition(); }
        if isa::<UnionDecl>(d)  { return cast::<UnionDecl>(d)->has_definition(); }
        return true;
    }

    // === declaration rules ====================================================

    priv fn _check_fn_decl(self, f: *FunctionDecl) {
        if !f->is_panic() { return; }
        var at = (f->panic_range) if (f->panic_range.is_valid()) else (f->range);
        var nm = self._fn_name(f);

        if self._sr.is_main(static_cast::<*Decl>(f)) {
            var b = self.sc->diag->report(DiagID::SC001E, at.start,
                "'main' cannot panic: nothing above it could handle the error");
            b.first(at);
            b.note(DiagID::SC001N, f->range.start, "handle every error in 'main', or stop the program with 'crash!()\x27").first(self._name_range(f));
            b.remove(f->panic_range, "remove 'panic\x27");
            b.emit();
            return;
        }
        if f->is_noreturn {
            var b = self.sc->diag->report(DiagID::SC001E, at.start,
                f"'{nm}' cannot be both 'panic' and '-> !': a panic returns its error, and '!' never returns");
            b.first(at);
            b.note(DiagID::SC001N, f->range.start, f"'{nm}' is declared here").first(self._name_range(f));
            b.remove(f->panic_range, "remove 'panic\x27");
            b.emit();
            return;
        }
        // Called where no call is written: nothing could handle the error.
        var hidden = self._hidden_call(f);
        if hidden.size() > 0 {
            var b = self.sc->diag->report(DiagID::SC001E, at.start,
                f"{hidden} cannot panic: it runs where no call is written, so nothing could handle the error");
            b.first(at);
            b.note(DiagID::SC001N, f->range.start, f"'{nm}' is declared here").first(self._name_range(f));
            b.remove(f->panic_range, "remove 'panic\x27");
            b.emit();
            return;
        }
        if panic_in_generic(static_cast::<*Decl>(f)) {
            self._gate(at, "a generic 'panic' function (or one inside a generic type)");
            return;
        }
        if f->is_generator {
            self._gate(at, "a 'panic' generator");
            return;
        }
        if f->is_async() {
            self._gate(at, "an 'async' 'panic' function");
            return;
        }
        for var i: usize = 0; i < f->panic_set.size(); ++i {
            var t = f->panic_set[i];
            if (t != &null) && (t->canonical != &null) { self._check_payload(t->canonical, t->range, "panicked"); }
        }
    }

    priv fn _check_closure_decl(self, c: *ClosureExpr) {
        if !self._closure_panics(c) { return; }
        var at = (c->panic_range) if (c->panic_range.is_valid()) else (c->range);
        if c->generic_params.size() > 0 {
            self._gate(at, "a generic 'panic' closure");
            return;
        }
        if (static_cast::<u16>(c->modifiers) & static_cast::<u16>(FnModifier::IsAsync)) != 0 {
            self._gate(at, "an 'async' 'panic' closure");
            return;
        }
        if c->is_noreturn {
            var b = self.sc->diag->report(DiagID::SC001E, at.start,
                "a closure cannot be both 'panic' and '-> !': a panic returns its error, and '!' never returns");
            b.first(at);
            b.note(DiagID::SC001N, c->range.start, "the closure is here").first(c->range);
            b.remove(c->panic_range, "remove 'panic\x27");
            b.emit();
            return;
        }
        for var i: usize = 0; i < c->panic_set.size(); ++i {
            var t = c->panic_set[i];
            if (t != &null) && (t->canonical != &null) { self._check_payload(t->canonical, t->range, "panicked"); }
        }
    }

    /// What \p f is when the language calls it without a call being
    /// written, for the message; empty when it is called only explicitly.
    priv fn _hidden_call(self, f: *FunctionDecl) -> string {
        if f->transfer != TransferKind::NotTransfer { return "a transfer constructor"; }
        if f->is_operator && (f->op_token.size() > 0) {
            var k = f->op_token[0].kind;
            if k == TokenKind::KwDelete { return "a destructor"; }
            if k == TokenKind::KwPanic  { return "'op panic\x27"; }
            if OperatorFacts::is_implicit_conv(f) { return "an '@implicit' conversion"; }
            return "";
        }
        if self._is_ctor(f) {
            var n = 0;
            for var i: usize = 0; i < f->params.size(); ++i {
                if (f->params[i] != &null) && (!f->params[i]->is_self) { n += 1; }
            }
            if n == 0 { return "a default constructor"; }
        }
        return "";
    }

    priv fn _is_ctor(self, f: *FunctionDecl) -> bool {
        if f->is_operator || (!f->is_method()) { return false; }
        var dc = reinterpret_cast::<*DeclContext>(f->semantic_dc);
        if (dc == &null) || (!dc->is_type_scope()) || (dc->dc_owner == &null) { return false; }
        return self._tu.decl_name(static_cast::<*Decl>(f)) == self._tu.decl_name(dc->dc_owner);
    }

    priv fn _gate(self, at: SourceRange, what: string) {
        var b = self.sc->diag->report(DiagID::SC116E, at.start, f"{what} is not yet supported");
        b.first(at);
        b.emit();
    }

    // === judging one body =====================================================

    /// Every site of \p w against what \p kind lets leave the body.
    priv fn _judge(self, w: *PanicWalk, kind: PanicBody, f: *FunctionDecl, c: *ClosureExpr, holder: *Decl) {
        if w->sites.size() == 0 { return; }

        // Gated bodies: every panicking site is unsupported, caught or not.
        var gate = "";
        if f != &null {
            if panic_in_generic(static_cast::<*Decl>(f)) { gate = "a generic function (or one inside a generic type)"; }
            else if f->is_generator { gate = "a generator"; }
            else if f->is_async() { gate = "an 'async' function"; }
        }
        if c != &null {
            if c->generic_params.size() > 0 { gate = "a generic closure"; }
            else if (static_cast::<u16>(c->modifiers) & static_cast::<u16>(FnModifier::IsAsync)) != 0 { gate = "an 'async' closure"; }
        }
        if gate.size() > 0 {
            for var i: usize = 0; i < w->sites.size(); ++i {
                var s = &(w->sites[i]);
                var what = ("a 'panic\x27") if (s->raise != &null) else ("a call that may panic");
                self._gate(s->range, f"{what} inside {gate}");
            }
            return;
        }

        if kind == PanicBody::Global {
            for var i: usize = 0; i < w->sites.size(); ++i { self._global_site(&(w->sites[i]), holder); }
            for var i: usize = 0; i < w->tries.size(); ++i { self._global_try(&(w->tries[i]), holder); }
            return;
        }

        // What may leave: the declared set, the inferred one, or nothing.
        var allowed = vec::<*Type>();
        var inferred = false;
        var declared = false;
        if (f != &null) && f->is_panic() && (kind == PanicBody::Fn) {
            if f->has_panic_set() {
                declared = true;
                if !canonical_set(&(self._tu), &(f->panic_set), &allowed) { return; }
            } else {
                inferred = true;
            }
        }
        if (c != &null) && self._closure_panics(c) {
            if c->panic_set.size() > 0 {
                declared = true;
                if !canonical_set(&(self._tu), &(c->panic_set), &allowed) { return; }
            } else {
                inferred = true;
            }
        }
        if inferred { return; }   // the inferred set holds every leftover.

        for var i: usize = 0; i < w->sites.size(); ++i {
            var s = &(w->sites[i]);
            var missing = vec::<*Type>();
            for var k: usize = 0; k < s->left.size(); ++k {
                if !pset_has(&allowed, s->left[k]) { missing.push_back(s->left[k]); }
            }
            if missing.size() == 0 { continue; }
            if declared { self._outside_declared(s, &missing, f, c); }
            else { self._unhandled(s, &missing, kind, f, c, holder); }
        }
    }

    /// A site whose leftover is outside the body's declared set.
    priv fn _outside_declared(self, s: *PanicSite, missing: *vec::<*Type>, f: *FunctionDecl, c: *ClosureExpr) {
        var names = pset_names(&(self._tu), missing);
        var owner = ("the closure") if (c != &null) else (f"'{self._fn_name(f)}\x27");
        var verb = ("is") if (missing->size() == 1) else ("are");
        var b = self.sc->diag->report(DiagID::SC001E, s->range.start, f"{names} {verb} not in the declared panic set of {owner}");
        b.first(s->range, self._site_label(s, names));
        self._origin_note(&b, s);
        var pr = (c->panic_range) if (c != &null) else (f->panic_range);
        if pr.is_valid() {
            b.insert(pr.end.with_offset(-1), ", " + pset_spelling(&(self._tu), missing), "add it to the declared set");
        }
        b.emit();
    }

    /// A site whose leftover reaches a body that lets nothing leave.
    priv fn _unhandled(self, s: *PanicSite, missing: *vec::<*Type>, kind: PanicBody, f: *FunctionDecl, c: *ClosureExpr, holder: *Decl) {
        var names = pset_names(&(self._tu), missing);
        var head = "";
        var what = self._site_what(s);
        var nh = ("is not handled") if (missing->size() == 1) else ("are not handled");
        if kind == PanicBody::Main {
            head = f"a panic cannot reach 'main': {what} {names}, which {nh}";
        } else if kind == PanicBody::Script {
            head = f"a panic cannot reach a script's top level: {what} {names}, which {nh}";
        } else if kind == PanicBody::Field {
            head = f"a field's default cannot panic: {what} {names}, which {nh}";
        } else if kind == PanicBody::Param {
            head = f"a parameter's default cannot panic: {what} {names}, which {nh}";
        } else if c != &null {
            head = f"unhandled panic: {what} {names}, and the closure is not marked 'panic\x27";
        } else {
            head = f"unhandled panic: {what} {names}, and '{self._fn_name(f)}' is not marked 'panic\x27";
        }
        var b = self.sc->diag->report(DiagID::SC001E, s->range.start, head);
        b.first(s->range, self._site_label(s, names));
        self._origin_note(&b, s);
        // Propagate: mark the body `panic` (never main, a script or a default).
        if (kind == PanicBody::Fn) && (f != &null) && f->params_end.is_valid() {
            b.insert(f->params_end.end, " panic", f"mark '{self._fn_name(f)}' 'panic' to propagate it");
        } else if (kind == PanicBody::Closure) && (c != &null) && c->params_end.is_valid() {
            b.insert(c->params_end.end, " panic", "mark the closure 'panic' to propagate it");
        }
        // Handle it here: a call becomes `try call catch => crash!()`. Only a
        // call, an expression; a `panic` statement has no value to wrap.
        if s->raise == &null {
            var msg = ("or handle it here, or stop the program with 'crash!()\x27") if ((kind == PanicBody::Main) || (kind == PanicBody::Script)) else ("or handle it here");
            b.note(DiagID::SC001N, s->range.start, msg);
            b.child_fix(SourceRange(s->range.start, s->range.start), "try ", "wrap the call in 'try\x27");
            b.child_fix(SourceRange(s->range.end, s->range.end), " catch => crash!()", "catch everything it may panic with");
        }
        if (holder != &null) && holder->range.is_valid() && ((kind == PanicBody::Field) || (kind == PanicBody::Param)) {
            b.note(DiagID::SC001N, holder->range.start, "the default is declared here").first(holder->range);
        }
        b.emit();
    }

    /// §4.5: nothing in a global's initializer may panic.
    priv fn _global_site(self, s: *PanicSite, holder: *Decl) {
        var names = pset_names(&(self._tu), &(s->all));
        var b = self.sc->diag->report(DiagID::SC001E, s->range.start,
            f"a global's initializer cannot panic: {self._site_what(s)} {names}, and there is no function to propagate to");
        b.first(s->range);
        self._origin_note(&b, s);
        if (holder != &null) && holder->range.is_valid() {
            b.note(DiagID::SC001N, holder->range.start, "initialize it in a function instead").first(holder->range);
        }
        b.emit();
    }

    priv fn _global_try(self, t: *PanicTry, holder: *Decl) {
        var r = (t->stmt->range) if (t->stmt != &null) else (t->expr->range);
        var b = self.sc->diag->report(DiagID::SC001E, r.start,
            "a global's initializer cannot hold a 'try': it runs at file scope, outside every function");
        b.first(r);
        if (holder != &null) && holder->range.is_valid() {
            b.note(DiagID::SC001N, holder->range.start, "initialize it in a function instead").first(holder->range);
        }
        b.emit();
    }

    /// `'f' may panic with` / `this 'panic' raises` / `this call may panic with`.
    priv fn _site_what(self, s: *PanicSite) -> string {
        if s->raise != &null { return "this 'panic' raises"; }
        if (s->callee != &null) && isa::<FunctionDecl>(s->callee) {
            var cf = cast::<FunctionDecl>(s->callee);
            if cf->is_operator { return "this operator may panic with"; }
            return f"'{self._fn_name(cf)}' may panic with";
        }
        return "this call may panic with";
    }

    priv fn _site_label(self, s: *PanicSite, names: string) -> string {
        if s->raise != &null { return f"raises {names}"; }
        return f"may panic with {names}";
    }

    /// The note at where the set came from: the callee's declaration.
    priv fn _origin_note(self, b: *DiagBuilder, s: *PanicSite) {
        if (s->callee == &null) || (!isa::<FunctionDecl>(s->callee)) { return; }
        var cf = cast::<FunctionDecl>(s->callee);
        if !cf->range.is_valid() { return; }
        var r = (cf->panic_range) if (cf->panic_range.is_valid()) else (self._name_range(cf));
        b->note(DiagID::SC001N, cf->range.start, f"'{self._fn_name(cf)}' is declared 'panic' here").first(r);
    }

    // === helpers ===============================================================

    priv fn _closure_panics(self, c: *ClosureExpr) -> bool {
        return (static_cast::<u16>(c->modifiers) & static_cast::<u16>(FnModifier::IsPanic)) != 0;
    }

    priv fn _fn_name(self, f: *FunctionDecl) -> string {
        if f == &null { return "<fn>"; }
        if f->is_operator { return "op " + OperatorFacts::symbol(f); }
        return self._tu.decl_name(static_cast::<*Decl>(f));
    }

    priv fn _name_range(self, f: *FunctionDecl) -> SourceRange {
        if (!f->is_operator) && f->name.range.is_valid() { return f->name.range; }
        return f->range;
    }

    /// At file or module scope. A local `static` is not one: C++ runs its
    /// initializer inside the function, which handles or propagates it.
    priv fn _is_global(self, vd: *VariableDecl) -> bool {
        var dc = reinterpret_cast::<*DeclContext>(vd->semantic_dc);
        if dc == &null { return false; }
        if dc->is_translation_unit() { return true; }
        var o = dc->owner_decl();
        return (o != &null) && isa::<ModuleDecl>(o);
    }
}
