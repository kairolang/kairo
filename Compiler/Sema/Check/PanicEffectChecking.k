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
///     Declaration rules: `fn main() panic`; `panic` with `-> !` (§2.8);
///     `panic` on ANY constructor or the destructor (USER 2026-10-27: an
///     object is built whole or not at all; fallible construction is a
///     static factory), and a panic escaping one's body; a `panic` on what
///     is called where no call is written -- an `@implicit` conversion,
///     `op panic` itself -- since nothing could handle it there. Every type a
///     `panic` raises, a set declares or a `catch` names must be a movable,
///     complete value type: not a reference, not `void` (§1.5).
///
///     Declared sets (§2.2): a bare `panic` where the set is a contract or
///     has no body to infer from -- a `fn` type, an interface requirement,
///     a virtual base method, a closure -- is an error, the edit writing
///     the inferred set where there is one. An override's set is within the
///     base method's, a conformer's within the requirement's (edit: add the
///     types to the declared set). A bare-`panic` function cannot be used as
///     a value: a `fn` value's type carries the set (the `fn` type rung in
///     Conversion checks the subset), and an inferred one is known only
///     past the barrier. Building a library, an inferred set on a `pub`
///     function is a warning.
///
///     `try` arms (§3.1): the body's set is recorded on the `try` for
///     PanicLowering; an arm for a type outside it never runs (a warning,
///     the arm marked dead); two arms for one type are an error. Arms match
///     exact types. A C++ type outside the set is a C++ exception arm
///     (§3.5). What the arms leave goes to the enclosing `try` or the body.
///
///     Generics (P10, MONO.md D0/D5): a generic body is checked once, at
///     its definition, like any other: its set may name its parameters, a
///     call through a bound adds the requirement's DECLARED set at the
///     bound's arguments, and a call of a generic function its set at the
///     call's (EffectPropagation::panic_call_set). Two `catch` arms that
///     name different types can name one at an instance (`catch e: T`,
///     `catch e: A` at T = A): §3.1's duplicate-arm error, reported at the
///     instance's use with its chain (_check_instances).
///
///     Gates (SC116E): a `panic` function, or a panicking site, under a
///     `<T: type>` parameter (MONO.md D1: the C++-checked regime has no set
///     to close), a generic closure, a generator or `async` (§2.7: the
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
import Sema::Type::PanicSets::*;
import Sema::Check::ClassLifecycle::*;
import Sema::Check::ScriptRules::*;
import Sema::Check::ConformanceChecking::*;
import Sema::Type::ArgumentDeduction::*;
import AST::OperatorFacts::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::InstantiationRegistry::*;
import AST::Mixin::TypeQual::*;
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
    Ctor,       ///< a constructor's body: nothing may leave it.
    Dtor,       ///< a destructor's body: nothing may leave it.
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
    /// The bare arms' bindings among them.
    priv var _bare_decls:    llvm::DenseSet::<u64>;
    /// The bare bindings given their `Panic<void, L...>` type.
    priv var _bare_types:    llvm::DenseSet::<u64>;
    /// Every call's callee expression met so far (a call is visited before
    /// its callee): a function named there is called, not used as a value.
    priv var _callees: llvm::DenseSet::<u64>;
    /// Overrides and conformers already held to their base's set: a
    /// method can be reached through a visibility group and the list.
    priv var _subset_done: llvm::DenseSet::<u64>;
    priv var _scratch: vec::<*Type>;
    /// The functions whose bodies the traversal is inside, innermost last:
    /// a closure's enclosing function (a `<T: type>` gate reaches it).
    priv var _fn_stack: vec::<*FunctionDecl>;
    /// Structural conformance rows already held to their requirements' sets.
    priv var _rows_done: llvm::DenseSet::<u64>;

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

        self._check_instances();

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

    // === §3.1 at an instance (P10) =============================================

    /// Two typed arms of one `try` in a generic body that name ONE type at
    /// an instance's arguments (`catch e: T` beside `catch e: A`, at T = A):
    /// §3.1's duplicate arm. Only the instance can tell, so it is reported
    /// at the instance's use with its chain (MONO.md D6), as a lifecycle
    /// fact that fails there is; the arms are the definition's
    /// (FunctionDecl::panic_arms). Every live entry no TU checked yet, once
    /// for the build: its primary's TU judged its body before this one, or
    /// is this one. A generic record's instance checks its methods.
    priv fn _check_instances(self) {
        if self.sc->instances == &null { return; }
        var all = vec::<*InstanceEntry>();
        self.sc->instances->collect(all);
        for var i: usize = 0; i < all.size(); ++i {
            var e = all[i];
            if (e == &null) || (e->depth == 0) || e->panic_checked || (e->primary == &null) { continue; }
            var dep = false;
            for var k: usize = 0; k < e->args.size(); ++k { if panic_dep(e->args[k]) { dep = true; } }
            if dep { continue; }
            e->panic_checked = true;
            self._structural_rows(e);
            var prim = e->primary;
            if isa::<FunctionDecl>(prim) {
                var h = panic_home(cast::<FunctionDecl>(prim));
                if h->panic_arms.size() == 0 { continue; }
                var d = Deduction(self.sc, &null);
                self._bind_instance(&d, e, prim);
                self._instance_arms(e, h, &d);
                continue;
            }
            var ms = self._methods_of(prim);
            var rt = (self.sc->types->record(e->decl, &(e->args))) if (e->decl != &null) else (&null);
            for var k: usize = 0; k < ms.size(); ++k {
                if ms[k] == &null { continue; }
                var h = panic_home(ms[k]);
                if h->panic_arms.size() == 0 { continue; }
                var d = Deduction(self.sc, &null);
                if rt != &null { d.bind_from_record(rt); }
                self._instance_arms(e, h, &d);
            }
        }
    }

    /// A STRUCTURAL conformance an instance's bound found (`T impl Src<A>`
    /// met by a class that declares no `impl`, ConformanceRow::declared
    /// null): §2.2's conformer subset, which a declared conformance gets at
    /// its declaration (_conformances), held here, at the instance's use
    /// with its chain. Each row once per TU.
    priv fn _structural_rows(self, e: *InstanceEntry) {
        for var r: usize = 0; r < e->rows.size(); ++r {
            var row = e->rows[r];
            if (row == &null) || (row->declared != &null) || (!row->ok) { continue; }
            var key = reinterpret_cast::<u64>(row);
            if self._rows_done.contains(key) { continue; }
            self._rows_done.insert(key);
            for var i: usize = 0; (i < row->witnesses.size()) && (i < row->reqs.size()); ++i {
                var w = dyn_cast::<FunctionDecl>(row->witnesses[i]);
                var q = dyn_cast::<FunctionDecl>(row->reqs[i]);
                if (w == &null) || (q == &null) || (w == q) { continue; }
                var through = (row->sources[i]) if ((i < row->sources.size()) && (row->sources[i] != &null)) else (row->iface);
                var a = vec::<*Type>();
                var b = vec::<*Type>();
                if panic_set_of_fn(&(self._tu), w, &a) != PanicKnown::Set { continue; }
                var kb = panic_set_through(&(self._tu), q, through, &b);
                if kb == PanicKnown::Unknown { continue; }
                var out = vec::<*Type>();
                for var k: usize = 0; k < a.size(); ++k { if !pset_has(&b, a[k]) { out.push_back(a[k]); } }
                if out.size() == 0 { continue; }
                var names = pset_names(&(self._tu), &out);
                var verb = ("is") if (out.size() == 1) else ("are");
                var xs = self._tu.str(row->conformer);
                var is = self._tu.str(row->iface);
                var qn = self._qual_name(q);
                var at = (e->use_at) if (e->use_at.start.is_valid()) else (w->range);
                var bld = self.sc->diag->report(DiagID::SC001E, at.start,
                    f"'{xs}' does not meet '{is}' here: {names} {verb} not in the panic set of '{qn}', which '{self._qual_name(w)}' implements");
                bld.first(at, f"'{self._inst_name(e)}' needs '{xs}' to implement '{is}\x27");
                var wat = (w->panic_range) if (w->panic_range.is_valid()) else (self._name_range(w));
                bld.note(DiagID::SC001N, w->range.start, f"'{self._qual_name(w)}' may panic with {names}").first(wat);
                var qat = (q->panic_range) if (q->panic_range.is_valid()) else (self._name_range(q));
                bld.note(DiagID::SC001N, q->range.start, f"'{qn}' is declared here").first(qat);
                ConformanceChecking(self.sc).chain_notes(&bld, e);
                bld.emit();
            }
        }
    }

    /// \p e's arguments bound to \p prim's parameters (an extension
    /// member's extension's first), ConformanceChecking's order.
    priv fn _bind_instance(self, d: *Deduction, e: *InstanceEntry, prim: *Decl) {
        var k: usize = 0;
        var x = decl_extension_of(prim);
        if x != &null {
            var eps = decl_generic_params(static_cast::<*Decl>(x));
            var xr = NameLookup::representative(static_cast::<*Decl>(x));
            for var i: usize = 0; (i < eps.size()) && (k < e->args.size()); ++i {
                if eps[i] != &null { d->bind(xr, eps[i]->index, e->args[k]); }
                k += 1;
            }
        }
        var gps = decl_generic_params(prim);
        var pr = NameLookup::representative(prim);
        for var i: usize = 0; (i < gps.size()) && (k < e->args.size()); ++i {
            var gp = gps[i];
            if gp == &null { k += 1; continue; }
            if gp->is_pack {
                d->open_pack(pr, gp->index);
                while k < e->args.size() { d->push_pack(pr, gp->index, e->args[k]); k += 1; }
                break;
            }
            d->bind(pr, gp->index, e->args[k]);
            k += 1;
        }
    }

    priv fn _methods_of(self, d: *Decl) -> FrozenList::<*FunctionDecl> {
        if isa::<ClassDecl>(d)  { return cast::<ClassDecl>(d)->methods; }
        if isa::<StructDecl>(d) { return cast::<StructDecl>(d)->methods; }
        if isa::<UnionDecl>(d)  { return cast::<UnionDecl>(d)->methods; }
        return create_empty_frozen_list::<*FunctionDecl>();
    }

    /// Each `try` of \p h's (panic_arms: its arm types, null-separated):
    /// the first pair of arms naming one type at \p d's bindings.
    priv fn _instance_arms(self, e: *InstanceEntry, h: *FunctionDecl, d: *Deduction) {
        var start: usize = 0;
        var n = h->panic_arms.size();
        for var i: usize = 0; i <= n; ++i {
            if (i < n) && (h->panic_arms[i] != &null) { continue; }
            var done = false;
            for var a: usize = start; (a < i) && (!done); ++a {
                var ta = self._arm_at(h->panic_arms[a], d);
                if ta == &null { continue; }
                for var b: usize = a + 1; (b < i) && (!done); ++b {
                    var tb = self._arm_at(h->panic_arms[b], d);
                    if (tb == &null) || (ta != tb) { continue; }
                    self._instance_dup(e, ta, h->panic_arm_at[a], h->panic_arm_at[b]);
                    done = true;
                }
            }
            start = i + 1;
        }
    }

    priv fn _arm_at(self, t: *Type, d: *Deduction) -> *Type {
        if t == &null { return &null; }
        if !panic_dep(t) { return canon_unqual(t); }
        var x = d->substitute(t);
        return (canon_unqual(x)) if (x != &null) else (&null);
    }

    priv fn _instance_dup(self, e: *InstanceEntry, t: *Type, first: SourceRange, second: SourceRange) {
        var nm = self._tu.str(t);
        var inst = self._inst_name(e);
        var at = (e->use_at) if (e->use_at.start.is_valid()) else (second);
        var b = self.sc->diag->report(DiagID::SC001E, at.start,
            f"two 'catch' arms of one 'try' catch '{nm}' in '{inst}': the first takes every '{nm}', and the second never runs");
        b.first(at, f"'{inst}' is instantiated here");
        b.note(DiagID::SC001N, first.start, f"this arm catches '{nm}' at these arguments").first(first);
        b.note(DiagID::SC001N, second.start, "and so does this one").first(second);
        ConformanceChecking(self.sc).chain_notes(&b, e);
        b.emit();
    }

    priv fn _inst_name(self, e: *InstanceEntry) -> string {
        if (e->decl != &null) && (!isa::<FunctionDecl>(e->primary)) {
            var t = self.sc->types->record(e->decl, &(e->args));
            if t != &null { return self._tu.str(t); }
        }
        var s = self._tu.decl_name(e->primary) + "<";
        for var i: usize = 0; i < e->args.size(); ++i {
            if i > 0 { s += ", "; }
            s += self._tu.str(e->args[i]);
        }
        return s + ">";
    }

    // === bodies ===============================================================

    fn traverse_function_decl(self, f: *FunctionDecl) -> *FunctionDecl {
        self._fn_stack.push_back(f);
        var r = RecursiveASTVisitor::<PanicEffectChecking>::traverse_function_decl(f);
        self._fn_stack.pop_back();
        return r;
    }

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
        var life = self._lifecycle_fn(f);
        if life.size() > 0 {
            if f->is_panic() { return true; }   // the specifier is the error; one per function.
            kind = (PanicBody::Dtor) if (life == "a destructor") else (PanicBody::Ctor);
        }
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
        if (v == &null) || v->is_poisoned() { return true; }
        // A panic result held in a variable (`var c = e`, e a bare `catch`
        // binding): §1.1 keeps that for a later `var p: panic`. The arm's
        // own binding is not one.
        if (!self.sc->opts.test_panic_type) && (!self._arm_decls.contains(reinterpret_cast::<u64>(v))) && (v->type_ != &null) && (v->type_->canonical != &null) {
            var rd = self._tu.record_decl(canon_unqual(v->type_->canonical));
            if (rd != &null) && PanicSets(self.sc).is_panic(rd) {
                self._gate(v->name.range, "a stored panic result");
                return true;
            }
        }
        if v->init == &null { return true; }
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
            if (arm->decl != &null) && (arm->filter == &null) { self._bare_decls.insert(reinterpret_cast::<u64>(arm->decl)); }
            if (arm->filter != &null) && (arm->filter->canonical != &null) && (!self._is_cxx_type(arm->filter->canonical)) {
                self._check_payload(arm->filter->canonical, arm->filter->range, "caught");
            }
        }
        return true;
    }

    // === `finally` after a `try` ==============================================

    /// A `finally` written right after a `try` / `catch` is the standalone
    /// `finally` (PANIC.md §3.3, USER 2026-10-27): it is registered when
    /// control reaches it and runs when its block is left, not when the
    /// `try` finishes, and a `return`, `break` or uncaught panic out of the
    /// `try` skips it. Readers from Java, C# or Python expect the opposite
    /// on every count, so it is a warning. `} finally {` on the try's line
    /// and `finally` on the next are one shape: the parser never makes a
    /// `finally` part of a `try` (TryCatchStmt).
    fn visit_compound_stmt(self, n: *CompoundStmt) -> bool {
        for var i: usize = 1; i < n->body.size(); ++i {
            var end = n->range.end.with_offset(-1);
            self._finally_after_try(n->body[i - 1], n->body[i], end);
        }
        return true;
    }

    /// \p end: the closing brace of the block \p cur sits in. (A script's
    /// top level cannot hold a `finally`: LoopContextCheck rejects it.)
    priv fn _finally_after_try(self, prev: *Stmt, cur: *Stmt, end: SourceLocation) {
        if (prev == &null) || (cur == &null) { return; }
        if (!isa::<TryCatchStmt>(prev)) || (!isa::<FinallyStmt>(cur)) { return; }
        var fin = cur->range.start;
        var kw  = SourceRange::from_bounds(fin, u32(7));
        var w = self.sc->diag->report(DiagID::SC001W, fin,
            "'finally' runs when the enclosing block exits, like any 'finally', not when the 'try' before it finishes");
        w.first(kw, "registered here, after the 'try\x27");
        w.note(DiagID::SC001N, end, "it runs here, when this block is left").first(SourceRange::from_bounds(end, u32(1)));
        w.note(DiagID::SC001N, prev->range.start, "a 'return', 'break' or uncaught panic leaving this 'try' never reaches the 'finally', so it does not run on that path").first(SourceRange::from_bounds(prev->range.start, u32(3)));
        w.note(DiagID::SC001N, "to run it as soon as the 'try' is done, and on every way out of it, put it first in a block of its own: '{ finally { ... } try { ... } catch { ... } }\x27");
        w.emit();
    }

    fn visit_try_catch_expr(self, n: *TryCatchExpr) -> bool {
        for var i: usize = 0; i < n->catch_arms.size(); ++i {
            var arm = n->catch_arms.get(i);
            if arm->decl != &null { self._arm_decls.insert(reinterpret_cast::<u64>(arm->decl)); }
            if (arm->decl != &null) && (arm->filter == &null) { self._bare_decls.insert(reinterpret_cast::<u64>(arm->decl)); }
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
        // A constructor or a destructor never panics (USER 2026-10-27): an
        // object is either built whole or not at all, and a destructor runs
        // on every exit, where nothing could take an error.
        var life = self._lifecycle_fn(f);
        if life.size() > 0 {
            var why = ("it runs on every exit from the object's scope, where nothing could take an error") if (life == "a destructor") else ("an object is either built whole or not at all");
            var b = self.sc->diag->report(DiagID::SC001E, at.start, f"{life} cannot panic: " + why);
            b.first(at);
            b.note(DiagID::SC001N, f->range.start, f"'{nm}' is declared here").first(self._name_range(f));
            if self._is_ctor(f) {
                b.note(DiagID::SC001N, f->range.start, "construction that can fail belongs in a static factory function that may panic and returns the object");
            }
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
        if panic_in_duck(static_cast::<*Decl>(f)) {
            self._gate(at, "a 'panic' function under a '<T: type>' parameter (C++-checked generics)");
            return;
        }
        if f->panic_state == PanicSetState::Diverged {
            var b = self.sc->diag->report(DiagID::SC001E, at.start,
                f"the panic set of '{nm}' grows without bound: it calls itself (or a function that calls it) at ever-larger type arguments");
            b.first(at);
            b.note(DiagID::SC001N, f->range.start, "a declared set, 'panic(E1, E2)', bounds it: what the recursive call panics with must then be in it or caught").first(self._name_range(f));
            b.emit();
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
        if f->has_panic_set() { return; }

        // A bare `panic` where the set is a contract (§2.2): an interface
        // requirement, and a virtual method of a base. The edit writes the
        // inferred set when there is a body to infer it from.
        if self._in_interface(f) {
            self._needs_set(f->panic_range, f->range, f"the panic set of interface requirement '{nm}' must be declared: it is the contract every conformer is held to", self._fn_inferred(f));
            return;
        }
        if f->abi == AbiKind::Virtual {
            self._needs_set(f->panic_range, f->range, f"the panic set of virtual method '{nm}' must be declared: it is the contract every override is held to", self._fn_inferred(f));
            return;
        }
        // An inferred set on a `pub` function is API surface that changes
        // with the body: in a library build, say so (a warning, §2.2).
        if self.sc->opts.library_build && f->is_public() && (!self._library_tu()) && (f->panic_state == PanicSetState::Final) {
            var s = vec::<*Type>();
            for var i: usize = 0; i < f->panic_eff.size(); ++i { s.push_back(f->panic_eff[i]); }
            var what = (pset_names(&(self._tu), &s)) if (s.size() > 0) else ("nothing");
            var b = self.sc->diag->report(DiagID::SC001W, at.start,
                f"the panic set of public function '{nm}' is inferred ({what}); declare it, or a change to the body changes its callers' contract");
            b.first(at);
            self._write_set_fix(&b, f->panic_range, &s);
            b.emit();
        }
    }

    /// A bare `panic` in a position that needs the set written: the error,
    /// and the edit writing \p inferred (or removing `panic` when nothing
    /// panics; none when there is no body to infer from).
    priv fn _needs_set(self, pr: SourceRange, fallback: SourceRange, msg: string, inferred: *vec::<*Type>) {
        var at = (pr) if (pr.is_valid()) else (fallback);
        var b = self.sc->diag->report(DiagID::SC001E, at.start, msg);
        b.first(at, "write the set: 'panic(E1, E2)\x27");
        if inferred != &null {
            self._write_set_fix(&b, pr, inferred);
        } else {
            b.note(DiagID::SC001N, at.start, "there is no body to infer it from");
        }
        b.emit();
    }

    /// The edit that writes \p s in place of the specifier \p pr: `panic(A,
    /// B)`, or no `panic` at all for the empty set (`panic()` is not a set).
    priv fn _write_set_fix(self, b: *DiagBuilder, pr: SourceRange, s: *vec::<*Type>) {
        if !pr.is_valid() { return; }
        if s->size() == 0 {
            b->remove(pr, "nothing in the body panics: remove 'panic\x27");
            return;
        }
        var txt = "panic(" + pset_spelling(&(self._tu), s) + ")";
        b->fix(pr, txt, f"declare the inferred set: '{txt}\x27");
    }

    /// \p f's inferred set, when it has a body that was solved; else null.
    priv fn _fn_inferred(self, f: *FunctionDecl) -> *vec::<*Type> {
        var h = panic_home(f);
        if (h->panic_state != PanicSetState::Final) || ((h->body_block == &null) && (h->body_expr == &null)) { return &null; }
        self._scratch.clear();
        for var i: usize = 0; i < h->panic_eff.size(); ++i { self._scratch.push_back(h->panic_eff[i]); }
        return &(self._scratch);
    }

    priv fn _in_interface(self, f: *FunctionDecl) -> bool {
        var dc = reinterpret_cast::<*DeclContext>(f->semantic_dc);
        if dc == &null { return false; }
        var o = dc->owner_decl();
        return (o != &null) && isa::<InterfaceDecl>(o);
    }

    /// The program's own file, not the builtin root or std (FlagGates'
    /// test): a library the user cannot edit is not linted.
    priv fn _library_tu(self) -> bool {
        var fid = self.sc->ctx->fid;
        if (self.sc->g != &null) && self.sc->g->is_builtin_fid(fid) { return true; }
        var ci = self.sc->ctx->ci;
        if (ci == &null) || (self.sc->ctx->sm == &null) { return false; }
        var root = ci->pp.std_dir;
        if root.empty() && (!ci->target.resource_dir.empty()) { root = ci->target.resource_dir + "/std"; }
        if root.empty() { return false; }
        if !root.ends_with("/") { root += "/"; }
        return self.sc->ctx->sm->get_filename(fid).starts_with(root);
    }

    // === subset rules (§2.2) ===================================================

    /// An override's set is a subset of the base method's: a caller through
    /// the base handles only the base's set.
    fn visit_class_decl(self, cd: *ClassDecl) -> bool {
        if (cd == &null) || cd->is_poisoned() || decl_is_imported(static_cast::<*Decl>(cd)) { return true; }
        for var i: usize = 0; i < cd->methods.size(); ++i {
            var m = cd->methods[i];
            if (m == &null) || m->is_poisoned() || (m->abi != AbiKind::Override) || (!m->is_panic()) { continue; }
            var bt: *Type = &null;
            var base = panic_overridden_at(&(self._tu), cd, m, &bt);
            if base == &null { continue; }
            self._subset(m, base, bt, "overrides", "an override");
        }
        self._conformances(static_cast::<*Decl>(cd));
        return true;
    }

    fn visit_struct_decl(self, sd: *StructDecl) -> bool {
        if (sd != &null) && (!sd->is_poisoned()) { self._conformances(static_cast::<*Decl>(sd)); }
        return true;
    }

    fn visit_extension_decl(self, x: *ExtensionDecl) -> bool {
        if (x != &null) && (!x->is_poisoned()) { self._conformances(static_cast::<*Decl>(x)); }
        return true;
    }

    /// A conforming method's set is a subset of the requirement's, for each
    /// conformance \p by declares (`class X impl I`, `extend X impl I`).
    priv fn _conformances(self, by: *Decl) {
        if self.sc->instances == &null { return; }
        var rows = vec::<*ConformanceRow>();
        self.sc->instances->declared_rows(by, &rows);
        for var r: usize = 0; r < rows.size(); ++r {
            var row = rows[r];
            if row == &null { continue; }
            for var i: usize = 0; (i < row->witnesses.size()) && (i < row->reqs.size()); ++i {
                var w = dyn_cast::<FunctionDecl>(row->witnesses[i]);
                var q = dyn_cast::<FunctionDecl>(row->reqs[i]);
                if (w == &null) || (q == &null) || (w == q) { continue; }
                if decl_is_imported(static_cast::<*Decl>(w)) { continue; }
                // Only where the conformer is written: its own TU reports it.
                if self._tu.fid_of(static_cast::<*Decl>(w)) != self.sc->ctx->fid { continue; }
                self._subset(w, q, row->iface, "implements", "a conforming method");
            }
        }
    }

    /// \p sub's set within \p sup's; an error naming each type outside,
    /// at \p sub, with a note at \p sup and the edit adding the types to
    /// \p sup's declared set. \p through is where \p sup is met (the base
    /// record, the interface instance): a generic base's or interface's
    /// set is read at its arguments (P10), `B<i32>`'s `panic(T)` is
    /// `panic(i32)`.
    priv fn _subset(self, sub: *FunctionDecl, sup: *FunctionDecl, through: *Type, verb: string, what: string) {
        var key = reinterpret_cast::<u64>(sub);
        if self._subset_done.contains(key) { return; }
        self._subset_done.insert(key);
        var a = vec::<*Type>();
        var b = vec::<*Type>();
        var ka = panic_set_of_fn(&(self._tu), sub, &a);
        if ka != PanicKnown::Set { return; }
        var kb = panic_set_through(&(self._tu), sup, through, &b);
        if kb == PanicKnown::Unknown { return; }
        var out = vec::<*Type>();
        for var i: usize = 0; i < a.size(); ++i { if !pset_has(&b, a[i]) { out.push_back(a[i]); } }
        if out.size() == 0 { return; }
        var names = pset_names(&(self._tu), &out);
        var sn = self._qual_name(sup);
        var at = (sub->panic_range) if (sub->panic_range.is_valid()) else (self._name_range(sub));
        var msg = "";
        if kb == PanicKnown::No {
            msg = f"{what} cannot panic when '{sn}', which it {verb}, does not: it panics with {names}";
        } else {
            var verb2 = ("is") if (out.size() == 1) else ("are");
            msg = f"{names} {verb2} not in the panic set of '{sn}', which this {verb}; {what}'s set must be a subset of it";
        }
        var d = self.sc->diag->report(DiagID::SC001E, at.start, msg);
        d.first(at);
        var sat = (sup->panic_range) if (sup->panic_range.is_valid()) else (self._name_range(sup));
        d.note(DiagID::SC001N, sup->range.start, f"'{sn}' is declared here").first(sat);
        // A set naming its own parameters, read at arguments, has no
        // spelling to add to: the base's or interface's list is written in
        // its parameters, not in these arguments.
        var generic_sup = false;
        for var i: usize = 0; i < sup->panic_set.size(); ++i {
            var st = sup->panic_set[i];
            if (st != &null) && (st->canonical != &null) && panic_dep(st->canonical) { generic_sup = true; }
        }
        if sup->has_panic_set() && sup->panic_range.is_valid() && (!decl_is_imported(static_cast::<*Decl>(sup))) && (!generic_sup) {
            d.insert(sup->panic_range.end.with_offset(-1), ", " + pset_spelling(&(self._tu), &out), f"add it to the set of '{sn}\x27");
        }
        d.emit();
    }

    /// `Base::m` / `I::m`: a method as a message names it.
    priv fn _qual_name(self, f: *FunctionDecl) -> string {
        var dc = reinterpret_cast::<*DeclContext>(f->semantic_dc);
        var o = (dc->owner_decl()) if (dc != &null) else (&null);
        if (o != &null) && (isa::<ClassDecl>(o) || isa::<StructDecl>(o) || isa::<InterfaceDecl>(o)) {
            return self._tu.decl_name(o) + "::" + self._fn_name(f);
        }
        return self._fn_name(f);
    }

    // === a function as a value (§2.2) ==========================================

    /// A `fn` value's type carries its set, and a bare `panic` function's
    /// set is inferred only after its type was given: the function must
    /// declare it to be used as a value. The edit writes it.
    fn visit_call_expr(self, n: *CallExpr) -> bool {
        var c = self._tu.strip_parens(n->callee);
        if c != &null { self._callees.insert(reinterpret_cast::<u64>(c)); }
        return true;
    }

    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        // A bare `catch e`'s binding: typed `Panic<void, L...>` once its
        // `try` was judged (_type_bare_binder, which ran with the body's
        // walk, before this use is visited). Its uses follow.
        if (n->resolved_decl != &null) && self._bare_types.contains(reinterpret_cast::<u64>(n->resolved_decl)) {
            n->type_ = cast::<VariableDecl>(n->resolved_decl)->type_;
            return true;
        }
        if (n->resolved_decl != &null) && self._bare_decls.contains(reinterpret_cast::<u64>(n->resolved_decl)) { return true; }
        if self._callees.contains(reinterpret_cast::<u64>(static_cast::<*Expr>(n))) { return true; }
        self._value_use(n->range, n->resolved_decl);
        return true;
    }

    fn visit_chain_expr(self, n: *ChainExpr) -> bool {
        if self._callees.contains(reinterpret_cast::<u64>(static_cast::<*Expr>(n))) { return true; }
        if n->steps.size() == 0 { return true; }
        var st = n->steps.get(n->steps.size() - 1);
        self._value_use(n->range, st->resolved_decl);
        return true;
    }

    priv fn _value_use(self, at: SourceRange, d: *Decl) {
        var f = dyn_cast::<FunctionDecl>(d);
        if (f == &null) || (!f->is_panic()) { return; }
        var h = panic_home(f);
        if h->has_panic_set() || f->has_panic_set() { return; }
        var nm = self._fn_name(f);
        var b = self.sc->diag->report(DiagID::SC001E, at.start,
            f"'{nm}' is used as a value, but its panic set is inferred: a 'fn' value's type carries the set, so '{nm}' must declare it");
        b.first(at);
        var pr = (h->panic_range) if (h->panic_range.is_valid()) else (f->panic_range);
        var nat = (pr) if (pr.is_valid()) else (self._name_range(f));
        b.note(DiagID::SC001N, f->range.start, f"'{nm}' is declared here").first(nat);
        var inf = self._fn_inferred(f);
        if inf != &null { self._write_set_fix(&b, pr, inf); }
        b.emit();
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
        if c->panic_set.size() > 0 { return; }
        // A closure writes its set (§2.2): a readability rule, the set is
        // visible where the closure is. It was inferred anyway, for the edit.
        var inf: *vec::<*Type> = &null;
        if c->panic_state == PanicSetState::Final {
            self._scratch.clear();
            for var i: usize = 0; i < c->panic_eff.size(); ++i { self._scratch.push_back(c->panic_eff[i]); }
            inf = &(self._scratch);
        }
        self._needs_set(c->panic_range, c->range, "a closure's panic set must be declared: 'fn () panic(E) -> T\x27", inf);
    }

    /// A `fn` type has no body to infer from: its set is written (§2.2).
    fn visit_function_pointer_type(self, n: *FunctionPointerType) -> bool {
        // A set naming a generic parameter (`fn <E> run(f: fn() panic(E))`)
        // stays gated past P10: deduction never reads a `fn` type's effect
        // (E would only come from an explicit argument), and substitution
        // keeps a `fn` type's set as written (Substitution::substitute).
        for var i: usize = 0; i < n->panic_set.size(); ++i {
            var t = n->panic_set[i];
            if (t == &null) || (t->canonical == &null) { continue; }
            if t->canonical->is_dependent() || t->canonical->is_instantiation_dependent() {
                self._gate(t->range, "a 'fn' type's panic set that depends on a generic parameter");
                return true;
            }
        }
        if (!n->is_panic()) || (n->panic_set.size() > 0) { return true; }
        var pr = n->qual_range(TypeQual::<Type>::Flags::IsPanic);
        self._needs_set(pr, n->range, "the panic set of a 'fn' type must be declared: 'fn(T) panic(E) -> U\x27", &null);
        return true;
    }

    /// What \p f is when the language calls it without a call being
    /// written, for the message; empty when it is called only explicitly.
    /// "a constructor" / "a destructor" for any constructor (with or
    /// without parameters, a transfer one included) or the destructor;
    /// "" for every other function.
    priv fn _lifecycle_fn(self, f: *FunctionDecl) -> string {
        if f->transfer != TransferKind::NotTransfer { return "a transfer constructor"; }
        if f->is_operator && (f->op_token.size() > 0) && (f->op_token[0].kind == TokenKind::KwDelete) { return "a destructor"; }
        if self._is_ctor(f) { return "a constructor"; }
        return "";
    }

    /// Called where no call is written (constructors and the destructor are
    /// _lifecycle_fn's, which runs first).
    priv fn _hidden_call(self, f: *FunctionDecl) -> string {
        if f->is_operator && (f->op_token.size() > 0) {
            var k = f->op_token[0].kind;
            if k == TokenKind::KwPanic  { return "'op panic\x27"; }
            if OperatorFacts::is_implicit_conv(f) { return "an '@implicit' conversion"; }
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
        if (w->sites.size() == 0) && (w->tries.size() == 0) && (w->unbound_at.size() == 0) { return; }

        // Gated bodies: every panicking site is unsupported, caught or not.
        var gate = "";
        if f != &null {
            if panic_in_duck(static_cast::<*Decl>(f)) { gate = "a function under a '<T: type>' parameter (C++-checked generics)"; }
            else if f->is_generator { gate = "a generator"; }
            else if f->is_async() { gate = "an 'async' function"; }
        }
        if c != &null {
            if c->generic_params.size() > 0 { gate = "a generic closure"; }
            else if (static_cast::<u16>(c->modifiers) & static_cast::<u16>(FnModifier::IsAsync)) != 0 { gate = "an 'async' closure"; }
            else if (self._fn_stack.size() > 0) && panic_in_duck(static_cast::<*Decl>(self._fn_stack[self._fn_stack.size() - 1])) {
                gate = "a closure under a '<T: type>' parameter (C++-checked generics)";
            }
        }
        if gate.size() > 0 {
            for var i: usize = 0; i < w->sites.size(); ++i {
                var s = &(w->sites[i]);
                var what = ("a 'panic\x27") if (s->raise != &null) else ("a call that may panic");
                self._gate(s->range, f"{what} inside {gate}");
            }
            return;
        }
        // A callee whose set names a type parameter this call does not bind
        // (no bound declares the requirement it calls): its set here is not
        // known, so nothing could be checked about it.
        for var i: usize = 0; i < w->unbound_at.size(); ++i {
            self._gate(w->unbound_at[i], f"a call of '{self._fn_name(w->unbound_fn[i])}', whose panic set names a generic parameter this call does not bind,");
        }

        // A panicking operator is called through the operator's own syntax,
        // which OperatorLowering derives other operators from (`!=` from
        // `==`, `+=` from `+`) with the declared result: not lowered yet.
        for var i: usize = 0; i < w->sites.size(); ++i {
            var s = &(w->sites[i]);
            var cf = dyn_cast::<FunctionDecl>(s->callee);
            if (cf != &null) && cf->is_operator { self._gate(s->range, "a call of a panicking operator"); }
        }

        if kind == PanicBody::Global {
            for var i: usize = 0; i < w->sites.size(); ++i { self._global_site(&(w->sites[i]), holder); }
            for var i: usize = 0; i < w->tries.size(); ++i { self._global_try(&(w->tries[i]), holder); }
            return;
        }

        // The arms of every `try` against what reached it (§3.1). What
        // leaves a `try` was routed to the enclosing one or to the body by
        // the walk, and is judged with the sites below.
        for var i: usize = 0; i < w->tries.size(); ++i { self._judge_try(&(w->tries[i])); }
        if (f != &null) && panic_in_generic(static_cast::<*Decl>(f)) { self._record_arms(w, f); }
        if w->sites.size() == 0 { return; }

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

    /// One `try`'s arms (§3.1): its body's set is recorded on the node for
    /// PanicLowering; a second arm for one type is an error; an arm whose
    /// type is not in the set never runs -- a WARNING, with an edit removing
    /// it, since a callee shrinking its set must not break its callers. A
    /// C++ type outside the set is a C++ exception arm (§3.5): never dead.
    /// No subtyping: an arm catches its exact type, so `catch e: Base` is
    /// dead against a set holding only `Derived`.
    priv fn _judge_try(self, t: *PanicTry) {
        var n = (t->stmt->arms.size()) if (t->stmt != &null) else (t->expr->catch_arms.size());
        if t->stmt != &null { t->stmt->reach.from_vec(&(t->reach), self.sc->ctx); }
        else { t->expr->reach.from_vec(&(t->reach), self.sc->ctx); }
        self._type_bare_binder(t);
        for var i: usize = 0; i < n; ++i {
            var filt = self._arm_filter(t, i);
            if (filt == &null) || (filt->canonical == &null) { continue; }
            var c = canon_unqual(filt->canonical);
            var ar = self._arm_range(t, i);
            var dup = false;
            for var j: usize = 0; j < i; ++j {
                var fj = self._arm_filter(t, j);
                if (fj == &null) || (fj->canonical == &null) || (canon_unqual(fj->canonical) != c) { continue; }
                var b = self.sc->diag->report(DiagID::SC001E, ar.start, f"a second 'catch' arm for '{self._tu.str(c)}': the first one already catches it");
                b.first(filt->range);
                var rj = self._arm_range(t, j);
                b.note(DiagID::SC001N, rj.start, "the first arm is here").first(rj);
                b.remove(ar, "remove this arm");
                b.emit();
                dup = true;
                break;
            }
            if dup { continue; }
            if pset_has(&(t->reach), c) { continue; }
            if self._is_cxx_type(c) {
                self._cxx_arm(t, i, c, filt, ar);
                continue;
            }
            if t->stmt != &null { t->stmt->arms.get(i)->is_dead = true; }
            else { t->expr->catch_arms.get(i)->is_dead = true; }
            var why = "nothing in this 'try' can panic";
            if t->reach.size() > 0 { why = "this 'try' may panic only with " + pset_names(&(self._tu), &(t->reach)); }
            var w = self.sc->diag->report(DiagID::SC001W, ar.start, f"this arm never runs: '{self._tu.str(c)}' is not in the panic set of its 'try' ({why})");
            w.first(filt->range);
            w.remove(ar, "remove the arm");
            w.emit();
        }
    }

    /// A generic body's `try`s whose live typed arms could name one type at
    /// an instance -- two or more, at least one dependent -- onto \p f
    /// (FunctionDecl::panic_arms) for the instance check: §3.1's duplicate
    /// arm is an error, and at `catch e: T` beside `catch e: A` only an
    /// instance can say whether T is A (PanicInstances).
    priv fn _record_arms(self, w: *PanicWalk, f: *FunctionDecl) {
        var ts = vec::<*Type>();
        var rs = vec::<SourceRange>();
        for var i: usize = 0; i < w->tries.size(); ++i {
            var t = &(w->tries[i]);
            var n = (t->stmt->arms.size()) if (t->stmt != &null) else (t->expr->catch_arms.size());
            var mine = vec::<*Type>();
            var mat  = vec::<SourceRange>();
            var dep = false;
            for var k: usize = 0; k < n; ++k {
                var filt = self._arm_filter(t, k);
                if (filt == &null) || (filt->canonical == &null) { continue; }
                var dead = (t->stmt->arms.get(k)->is_dead) if (t->stmt != &null) else (t->expr->catch_arms.get(k)->is_dead);
                var cx   = (t->stmt->arms.get(k)->is_cxx) if (t->stmt != &null) else (t->expr->catch_arms.get(k)->is_cxx);
                if dead || cx { continue; }
                var c = canon_unqual(filt->canonical);
                if panic_dep(c) { dep = true; }
                mine.push_back(c);
                mat.push_back(filt->range);
            }
            if (mine.size() < 2) || (!dep) { continue; }
            for var k: usize = 0; k < mine.size(); ++k { ts.push_back(mine[k]); rs.push_back(mat[k]); }
            ts.push_back(&null);
            rs.push_back(SourceRange::invalid());
        }
        if ts.size() == 0 { return; }
        var home = panic_home(f);
        home->panic_arms.from_vec(&ts, self.sc->ctx);
        home->panic_arm_at.from_vec(&rs, self.sc->ctx);
    }

    /// A C++ exception arm (§3.5): marked for PanicLowering, which keeps it
    /// as a C++ `catch` around the lowered body. It needs C++ exceptions: a
    /// build without them (-fno-exceptions, a freestanding target) cannot
    /// catch one, and clang would reject the `try` it lowers to.
    priv fn _cxx_arm(self, t: *PanicTry, i: usize, c: *Type, filt: *Type, ar: SourceRange) {
        if t->stmt != &null { t->stmt->arms.get(i)->is_cxx = true; }
        else { t->expr->catch_arms.get(i)->is_cxx = true; }
        if self.sc->opts.cxx_exceptions { return; }
        var nm = self._tu.str(c);
        var b = self.sc->diag->report(DiagID::SC001E, ar.start,
            f"'catch' of the C++ exception '{nm}' in a build without C++ exceptions (-fno-exceptions, or a target with no OS)");
        b.first(filt->range, "a C++ type outside the panic set: this arm catches a C++ exception");
        var d = self._tu.record_decl(c);
        if (d != &null) && d->range.is_valid() { b.note(DiagID::SC001N, d->range.start, f"'{nm}' is declared here, in C++").first(d->range); }
        b.remove(ar, "remove the arm");
        b.emit();
    }

    /// A bare `catch e`'s binding holds whatever the arm catches: one of
    /// the types the `try` leaves after its typed arms. X typed it before
    /// any set was known (the `Panic` lang item with no arguments); here it
    /// becomes `Panic<void, L...>` over that leftover L (PANIC.md §3.6),
    /// formed like every panic result (PanicSets::form), and its uses are
    /// retyped as they are visited (visit_named_ident_expr). Nothing is
    /// caught when L is empty: the arm never runs, and keeps X's type.
    priv fn _type_bare_binder(self, t: *PanicTry) {
        var n = (t->stmt->arms.size()) if (t->stmt != &null) else (t->expr->catch_arms.size());
        for var i: usize = 0; i < n; ++i {
            var filt: *Type = &null;
            var d: *Decl = &null;
            var r = self._arm_range(t, i);
            if t->stmt != &null { filt = t->stmt->arms.get(i)->filter; d = t->stmt->arms.get(i)->decl; }
            else { filt = t->expr->catch_arms.get(i)->filter; d = t->expr->catch_arms.get(i)->decl; }
            if (filt != &null) || (d == &null) || (!isa::<VariableDecl>(d)) { continue; }
            var left = vec::<*Type>();
            for var k: usize = 0; k < t->reach.size(); ++k {
                if !pset_has(&(t->types), t->reach[k]) { left.push_back(t->reach[k]); }
            }
            if left.size() == 0 { continue; }
            var pt = PanicSets(self.sc).form(r, self.sc->builtin(BuiltinKind::Void), &left);
            if pt == &null { continue; }
            cast::<VariableDecl>(d)->type_ = pt;
            self._bare_types.insert(reinterpret_cast::<u64>(d));
        }
    }

    priv fn _arm_filter(self, t: *PanicTry, i: usize) -> *Type {
        if t->stmt != &null { return t->stmt->arms.get(i)->filter; }
        return t->expr->catch_arms.get(i)->filter;
    }

    priv fn _arm_range(self, t: *PanicTry, i: usize) -> SourceRange {
        if t->stmt != &null { return t->stmt->arms.get(i)->range; }
        return t->expr->catch_arms.get(i)->range;
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
        } else if kind == PanicBody::Ctor {
            head = f"a constructor cannot panic: {what} {names}, which {nh}";
        } else if kind == PanicBody::Dtor {
            head = f"a destructor cannot panic: {what} {names}, which {nh}";
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
        if kind == PanicBody::Ctor {
            b.note(DiagID::SC001N, s->range.start, "construction that can fail belongs in a static factory function that may panic and returns the object");
        }
        if s->raise == &null {
            var msg = ("or handle it here, or stop the program with 'crash!()\x27") if ((kind == PanicBody::Main) || (kind == PanicBody::Script) || (kind == PanicBody::Ctor) || (kind == PanicBody::Dtor)) else ("or handle it here");
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
