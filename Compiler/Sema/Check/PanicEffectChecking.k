/// --- The Kairo Project ------------- Sema/Check/PanicEffectChecking.k --- ///
///
///   \brief Every panic is handled or propagated (Compiler/Spec/Panic.md#effect-sets, §1.5, §4.5).
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
///     Generics (Compiler/Spec/Generics.md#decisions/D5): a generic body is checked once, at
///     its definition, like any other: its set may name its parameters, a
///     call through a bound adds the requirement's DECLARED set at the
///     bound's arguments, and a call of a generic function its set at the
///     call's (EffectPropagation::panic_call_set). Two `catch` arms that
///     name different types can name one at an instance (`catch e: T`,
///     `catch e: A` at T = A): §3.1's duplicate-arm error, reported at the
///     instance's use with its chain (_check_instances).
///
///     Gates (SC116E): a `panic` function, or a panicking site, under a
///     `<T: type>` parameter (Compiler/Spec/Generics.md#duck-regime: the C++-checked regime has no set
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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

ffi "c++" import "vector"
ffi "c++" import "llvm/ADT/DenseSet.h"

import AST::ASTSupport::{
    FrozenList,
    create_empty_frozen_list,
}
import AST::Context::InstantiationRegistry::{
    ConformanceRow,
    InstanceEntry,
    InstanceLatch,
}
import AST::DeclFacts::{
    decl_extension_of,
    decl_generic_params,
    decl_is_imported,
}
import AST::Kind::TypeKind::TypeKind
import AST::LangItems::LangAttrs
import AST::Mixin::TypeQual::TypeQual
import AST::Node::Base::{
    Decl,
    Expr,
    Stmt,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Expressions::{
    BinaryOperatorExpr,
    CallExpr,
    ClosureExpr,
    TryCatchExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Program::TopLevelKind
import AST::Node::Statements::{
    CompoundStmt,
    FinallyStmt,
    PanicStmt,
    TryCatchStmt,
}
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    FunctionPointerType,
    PointerType,
}
import AST::OperatorFacts::OperatorFacts
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Config::ResourceLayout::ResourceLayout
import Diagnostic::Code::DiagCode
import Diagnostic::DiagBuilder::DiagBuilder
import Diagnostic::Registry::DiagID
import Diagnostic::NoteText::named_declared_here
import Location::SourceLocation::SourceLocation
import Location::SourceRange::SourceRange
import Sema::Check::ClassLifecycle::{
    LifecycleTri,
    lifecycle_of,
}
import Sema::Check::ConformanceChecking::ConformanceChecking
import Sema::Check::EffectPropagation::{
    EffectTable,      PanicKnown,          PanicSite,       PanicTry,          PanicWalk,
    canonical_set,    effects_of,          panic_dep,       panic_home,        panic_in_duck,
    panic_in_generic, panic_overridden_at, panic_set_of_fn, panic_set_through, pset_has,
    pset_names,       pset_spelling,
}
import Sema::Check::ScriptRules::ScriptRules
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::ArgumentDeduction::Deduction
import Sema::Type::PanicSets::PanicSets
import Sema::Type::TypeUtil::TypeUtil
import Token::TokenKind::TokenKind

/// Which body a walk is over: decides what may leave it and how a site
/// that breaks the rule is reported.
pub enum PanicBody derives u8 {
    Fn,      ///< a function's body.
    Closure, ///< a closure's body.
    Main,    ///< `main`'s body.
    Script,  ///< a script's top level (main's body, Compiler/Spec/ScriptMode.md).
    Field,   ///< a field's default.
    Param,   ///< a parameter's default.
    Global,  ///< a global's or a static field's initializer.
    Ctor,    ///< a constructor's body: nothing may leave it.
    Dtor,    ///< a destructor's body: nothing may leave it.
}

pub class PanicEffectChecking derives RecursiveASTVisitor<PanicEffectChecking> {
    pub var  sc:      unsafe *SemaContext
    priv var _tu:     TypeUtil
    priv var _sr:     ScriptRules
    priv var _script: bool                = false
    /// Functions already judged: a method in a visibility group is reached
    /// through the group and through the method list.
    priv var _seen: llvm::DenseSet<u64>
    /// The table this TU's sets come from when the driver set none up.
    priv var _local: EffectTable
    /// Every catch arm's binding met so far (an arm is visited before its
    /// body): what a re-panic `panic e` names.
    priv var _arm_decls: llvm::DenseSet<u64>
    /// The bare arms' bindings among them.
    priv var _bare_decls: llvm::DenseSet<u64>
    /// The bare bindings given their `Panic<void, L...>` type.
    priv var _bare_types: llvm::DenseSet<u64>
    /// Every call's callee expression met so far (a call is visited before
    /// its callee): a function named there is called, not used as a value.
    priv var _callees: llvm::DenseSet<u64>
    /// Every (method, base method or requirement, where it is met) pair
    /// held so far (_met): a method can be reached through a visibility
    /// group and the list, and can meet several.
    priv var _met_fn:  cxx::std::vector<unsafe *Declarations::FunctionDecl>
    priv var _met_sup: cxx::std::vector<unsafe *Declarations::FunctionDecl>
    priv var _met_at:  cxx::std::vector<unsafe *Type>
    /// Methods already reported meeting two different sets.
    priv var _two_done: llvm::DenseSet<u64>
    priv var _scratch:  cxx::std::vector<unsafe *Type>
    /// The functions whose bodies the traversal is inside, innermost last:
    /// a closure's enclosing function (a `<T: type>` gate reaches it).
    priv var _fn_stack: cxx::std::vector<unsafe *Declarations::FunctionDecl>
    /// Structural conformance rows already held to their requirements' sets.
    priv var _rows_done: llvm::DenseSet<u64>

    fn PanicEffectChecking(self, sc: unsafe *SemaContext) {
        self.sc  = sc
        self._tu = TypeUtil(sc)
        self._sr = ScriptRules(sc)
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Typed)
        var unsafe *tu = self.sc->tu
        if tu == &null || tu->program == &null {
            return
        }

        // No barrier above us: this TU's sets are solved here, alone. A
        // callee in another TU is read as that TU left it.
        var unsafe *tab = effects_of(self.sc)
        if tab == &null || !tab->solved {
            self._local.add_tu(self.sc)
            self._local.solve()
        }

        self._script = self._sr.is_script()
        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); ++i {
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

        self._check_instances()

        // A script's top level is main's body: its statements, and its
        // bindings' initializers (each deferred one runs at its line in main;
        // a constant one cannot panic).
        if self._script {
            for var i: usize = 0; i < items->size(); ++i {
                var item = *items->get(i)
                var w    = PanicWalk(self.sc)
                w.keep_sites = true
                if item.get_kind() == TopLevelKind::Stmt {
                    var unsafe *b = self._sr.binding_of(item)
                    if b != &null {
                        if b->init != &null {
                            w.walk_expr(b->init)
                        }
                    } else {
                        w.walk_stmt(item.as_stmt())
                    }
                } else if item.get_kind() == TopLevelKind::Expr {
                    w.walk_expr(item.as_expr())
                } else {
                    var unsafe *vd = dyn_cast<Declarations::VariableDecl>(item.as_decl())
                    if vd != &null && vd->init != &null {
                        w.walk_expr(vd->init)
                    }
                }

                self._judge(&w, PanicBody::Script, &null, &null, &null)
            }
        }
    }

    /// # §3.1 at an instance

    /// Two typed arms of one `try` in a generic body that name ONE type at
    /// an instance's arguments (`catch e: T` beside `catch e: A`, at T = A):
    /// §3.1's duplicate arm. Only the instance can tell, so it is reported
    /// at the instance's use with its chain (Compiler/Spec/Generics.md#instance-diagnostics), as a lifecycle
    /// fact that fails there is; the arms are the definition's
    /// (FunctionDecl::panic_arms). Every live entry no TU checked yet, once
    /// for the build: its primary's TU judged its body before this one, or
    /// is this one. A generic record's instance checks its methods.
    priv fn _check_instances(self) {
        if self.sc->instances == &null {
            return
        }

        var all = cxx::std::vector<unsafe *InstanceEntry>()
        self.sc->instances->collect(&all)
        for var i: usize = 0; i < all.size(); ++i {
            var unsafe *e = all[i]
            if e == &null || e->depth == 0 || e->primary == &null {
                continue
            }

            var dep = false
            for var k: usize = 0; k < e->args.size(); ++k {
                if panic_dep(e->args[k]) {
                    dep = true
                }
            }

            // Claimed after the dependence test: a dependent entry is never
            // checked, and must stay unclaimed for no one.
            if dep || !self.sc->instances->claim(e, InstanceLatch::PanicChecked) {
                continue
            }

            self._structural_rows(e)
            var unsafe *prim = e->primary
            if isa<Declarations::FunctionDecl>(prim) {
                var unsafe *h = panic_home(cast<Declarations::FunctionDecl>(prim))
                if h->panic_arms.size() == 0 {
                    continue
                }

                var d = Deduction(self.sc, &null)
                self._bind_instance(&d, e, prim)
                self._instance_arms(e, h, &d)
                continue
            }

            var ms = self._methods_of(prim)
            var unsafe *rt = if (e->decl != &null) => (self.sc->types->record(
                                 e->decl,
                                 unsafe &e->args,
                             ))
                             else => &null
            for var k: usize = 0; k < ms.size(); ++k {
                if ms[k] == &null {
                    continue
                }

                var unsafe *h = panic_home(ms[k])
                if h->panic_arms.size() == 0 {
                    continue
                }

                var d = Deduction(self.sc, &null)
                if rt != &null {
                    d.bind_from_record(rt)
                }

                self._instance_arms(e, h, &d)
            }
        }
    }

    /// A STRUCTURAL conformance an instance's bound found (`T impl Src<A>`
    /// met by a class that declares no `impl`, ConformanceRow::declared
    /// null): §2.2's conformer subset, which a declared conformance gets at
    /// its declaration (_conformances), held here, at the instance's use
    /// with its chain. Each row once per TU.
    priv fn _structural_rows(self, e: unsafe *InstanceEntry) {
        for var r: usize = 0; r < e->rows.size(); ++r {
            var unsafe *row = e->rows[r]
            if row == &null || row->declared != &null || !row->ok {
                continue
            }

            var key = (row as usize as u64)
            if self._rows_done.contains(key) {
                continue
            }

            self._rows_done.insert(key)
            for var i: usize = 0; i < row->witnesses.size() && i < row->reqs.size(); ++i {
                var unsafe *w = dyn_cast<Declarations::FunctionDecl>(row->witnesses[i])
                var unsafe *q = dyn_cast<Declarations::FunctionDecl>(row->reqs[i])
                if w == &null || q == &null || w == q {
                    continue
                }

                var unsafe *through = if (i < row->sources.size()
                                          && row->sources[i] != &null) => (row->sources[i])
                                      else => row->iface
                var a = cxx::std::vector<unsafe *Type>()
                var b = cxx::std::vector<unsafe *Type>()
                if panic_set_of_fn(unsafe &self._tu, w, unsafe &a) != PanicKnown::Set {
                    continue
                }

                var kb = panic_set_through(unsafe &self._tu, q, through, unsafe &b)
                if kb == PanicKnown::Unknown {
                    continue
                }

                var out = cxx::std::vector<unsafe *Type>()
                for var k: usize = 0; k < a.size(); ++k {
                    if !pset_has(unsafe &b, a[k]) {
                        out.push_back(a[k])
                    }
                }

                if out.size() == 0 {
                    continue
                }

                var names = pset_names(&self._tu, unsafe &out)
                var verb  = if (out.size() == 1) => ("is") else => "are"
                var xs    = self._tu.str(row->conformer)
                var is    = self._tu.str(row->iface)
                var qn    = self._qual_name(q)
                var at    = if (e->use_at.start.is_valid()) => (e->use_at) else => w->range
                var bld = self.sc->diag->report(
                    DiagID::SC208E,
                    at.start,
                    f"'{xs}' does not meet '{is}' here: {names} {verb} not in the panic set of '{qn}', which '{self._qual_name(w)}' implements",
                )

                bld.first(at, f"'{self._inst_name(e)}' needs '{xs}' to implement '{is}'")
                var wat = if (w->panic_range.is_valid()) => (w->panic_range)
                          else => self._name_range(w)
                bld.note(
                    DiagCode(DiagID::SC208N),
                    w->range.start,
                    f"'{self._qual_name(w)}' may panic with {names}",
                )->first(wat)
                var qat = if (q->panic_range.is_valid()) => (q->panic_range)
                          else => self._name_range(q)
                bld.note(
                    DiagCode(DiagID::SC208N),
                    q->range.start,
                    named_declared_here(qn),
                )->first(qat)
                ConformanceChecking(self.sc).chain_notes(unsafe &bld, e)
                bld.emit()
            }
        }
    }

    /// \p e's arguments bound to \p prim's parameters (an extension
    /// member's extension's first), ConformanceChecking's order.
    priv fn _bind_instance(self, d: *Deduction, e: unsafe *InstanceEntry, prim: unsafe *Decl) {
        var        k: usize = 0
        var unsafe *x       = decl_extension_of(prim)
        if x != &null {
            var        eps = decl_generic_params(x)
            var unsafe *xr = NameLookup::representative(x)
            for var i: usize = 0; i < eps.size() && k < e->args.size(); ++i {
                if eps[i] != &null {
                    d->bind(xr, eps[i]->index, e->args[k])
                }

                k += 1
            }
        }

        var        gps = decl_generic_params(prim)
        var unsafe *pr = NameLookup::representative(prim)
        for var i: usize = 0; i < gps.size() && k < e->args.size(); ++i {
            var unsafe *gp = gps[i]
            if gp == &null {
                k += 1
                continue
            }

            if gp->is_pack {
                d->open_pack(pr, gp->index)
                while k < e->args.size() {
                    d->push_pack(pr, gp->index, e->args[k])
                    k += 1
                }

                break
            }

            d->bind(pr, gp->index, e->args[k])
            k += 1
        }
    }

    priv fn _methods_of(self, d: unsafe *Decl) -> FrozenList<unsafe *Declarations::FunctionDecl> {
        if isa<Declarations::ClassDecl>(d) {
            return cast<Declarations::ClassDecl>(d)->methods
        }

        if isa<Declarations::StructDecl>(d) {
            return cast<Declarations::StructDecl>(d)->methods
        }

        if isa<Declarations::UnionDecl>(d) {
            return cast<Declarations::UnionDecl>(d)->methods
        }

        return create_empty_frozen_list<unsafe *Declarations::FunctionDecl>()
    }

    /// Each `try` of \p h's (panic_arms: its arm types, null-separated):
    /// the first pair of arms naming one type at \p d's bindings.
    priv fn _instance_arms(self,
                           e: unsafe *InstanceEntry,
                           h: unsafe *Declarations::FunctionDecl,
                           d: *Deduction) {
        var start: usize = 0
        var n            = h->panic_arms.size()
        for var i: usize = 0; i <= n; ++i {
            if i < n && h->panic_arms[i] != &null {
                continue
            }

            var done = false
            for var a: usize = start; a < i && !done; ++a {
                var unsafe *ta = self._arm_at(h->panic_arms[a], d)
                if ta == &null {
                    continue
                }

                for var b: usize = a + 1; b < i && !done; ++b {
                    var unsafe *tb = self._arm_at(h->panic_arms[b], d)
                    if tb == &null || ta != tb {
                        continue
                    }

                    self._instance_dup(e, ta, h->panic_arm_at[a], h->panic_arm_at[b])
                    done = true
                }
            }

            start = i + 1
        }
    }

    priv fn _arm_at(self, t: unsafe *Type, d: *Deduction) -> unsafe *Type {
        if t == &null {
            return &null
        }

        if !panic_dep(t) {
            return canon_unqual(t)
        }

        var unsafe *x = d->substitute(t)
        return if (x != &null) => (canon_unqual(x)) else => &null
    }

    priv fn _instance_dup(self,
                          e:      unsafe *InstanceEntry,
                          t:      unsafe *Type,
                          first:  SourceRange,
                          second: SourceRange) {
        var nm   = self._tu.str(t)
        var inst = self._inst_name(e)
        var at   = if (e->use_at.start.is_valid()) => (e->use_at) else => second
        var b = self.sc->diag->report(
            DiagID::SC209E,
            at.start,
            f"two 'catch' arms of one 'try' catch '{nm}' in '{inst}': the first takes every '{nm}', and the second never runs",
        )

        b.first(at, f"'{inst}' is instantiated here")
        b.note(
            DiagCode(DiagID::SC209N),
            first.start,
            f"this arm catches '{nm}' at these arguments",
        )->first(first)
        b.note(DiagCode(DiagID::SC209N), second.start, "and so does this one")->first(second)
        ConformanceChecking(self.sc).chain_notes(unsafe &b, e)
        b.emit()
    }

    priv fn _inst_name(self, e: unsafe *InstanceEntry) -> string {
        if e->decl != &null && !isa<Declarations::FunctionDecl>(e->primary) {
            var unsafe *t = self.sc->types->record(e->decl, unsafe &e->args)
            if t != &null {
                return self._tu.str(t)
            }
        }

        var s = self._tu.decl_name(e->primary) + "<"
        for var i: usize = 0; i < e->args.size(); ++i {
            if i > 0 {
                s += ", "
            }

            s += self._tu.str(e->args[i])
        }

        return s + ">"
    }

    /// # bodies

    fn traverse_function_decl(self,
                              f: unsafe *Declarations::FunctionDecl) -> unsafe *Declarations::FunctionDecl {
        self._fn_stack.push_back(f)
        var unsafe *r = RecursiveASTVisitor<PanicEffectChecking>::traverse_function_decl(self, f)
        self._fn_stack.pop_back()
        return r
    }

    fn visit_function_decl(self, f: unsafe *Declarations::FunctionDecl) -> bool {
        if f == &null || f->is_poisoned() {
            return true
        }

        var key = (f as usize as u64)
        if self._seen.contains(key) {
            return true
        }

        self._seen.insert(key)
        if decl_is_imported(unsafe (f as unsafe *Decl)) {
            return true
        }

        self._check_fn_decl(f)
        if f->body_block == &null && f->body_expr == &null {
            return true
        }

        var w = PanicWalk(self.sc)
        w.keep_sites = true
        w.walk_fn(f)
        var kind = if (self._sr.is_main(unsafe (f as unsafe *Decl))) => (PanicBody::Main)
                   else => PanicBody::Fn
        var life = self._lifecycle_fn(f)
        if life.size() > 0 {
            if f->is_panic() { // the specifier is the error; one per function.
                return true
            }

            kind = if (life == "a destructor") => (PanicBody::Dtor) else => PanicBody::Ctor
        }

        self._judge(&w, kind, f, &null, &null)
        return true
    }

    fn visit_closure_expr(self, c: unsafe *ClosureExpr) -> bool {
        if c == &null || c->is_poisoned() {
            return true
        }

        self._check_closure_decl(c)
        var w = PanicWalk(self.sc)
        w.keep_sites = true
        w.walk_closure(c)
        self._judge(&w, PanicBody::Closure, &null, c, &null)
        return true
    }

    /// A global's initializer (§4.5); a local's is its function's.
    fn visit_variable_decl(self, v: unsafe *Declarations::VariableDecl) -> bool {
        if v == &null || v->is_poisoned() {
            return true
        }

        // A panic result held in a variable (`var c = e`, e a bare `catch`
        // binding): §1.1 keeps that for a later `var p: panic`. The arm's
        // own binding is not one.
        if !self.sc->opts.test_panic_type
            && !self._arm_decls.contains(v as usize as u64)
            && v->type_ != &null
            && v->type_->canonical != &null {
            var unsafe *rd = self._tu.record_decl(canon_unqual(v->type_->canonical))
            if rd != &null && PanicSets(self.sc).is_panic(rd) {
                self._gate(v->name.range, "a stored panic result")
                return true
            }
        }

        if v->init == &null {
            return true
        }

        if self._script { // main's body; walked in run().
            return true
        }

        if !self._is_global(v) {
            return true
        }

        var w = PanicWalk(self.sc)
        w.keep_sites = true
        w.walk_expr(v->init)
        self._judge(&w, PanicBody::Global, &null, &null, v)
        return true
    }

    fn visit_field_decl(self, fd: unsafe *Declarations::FieldDecl) -> bool {
        if fd == &null || fd->is_poisoned() || fd->init == &null {
            return true
        }

        var w = PanicWalk(self.sc)
        w.keep_sites = true
        w.walk_expr(fd->init)
        var kind = if (fd->is_static()) => (PanicBody::Global) else => PanicBody::Field
        self._judge(&w, kind, &null, &null, unsafe (fd as unsafe *Decl))
        return true
    }

    fn visit_param_decl(self, p: unsafe *Declarations::ParamDecl) -> bool {
        if p == &null || p->is_poisoned() || p->default_val == &null {
            return true
        }

        var w = PanicWalk(self.sc)
        w.keep_sites = true
        w.walk_expr(p->default_val)
        self._judge(&w, PanicBody::Param, &null, &null, unsafe (p as unsafe *Decl))
        return true
    }

    /// # payload types

    fn visit_panic_stmt(self, n: *PanicStmt) -> bool {
        if n->payload == &null || n->payload->is_poisoned() {
            return true
        }

        // `panic e` of a catch arm's binding re-panics the caught error: its
        // type was judged where it was raised (and a bare arm's binding has
        // no single type).
        var unsafe *rp = self._repanic_of(n)
        if rp != &null {
            n->repanic = rp
            return true
        }

        if n->payload->type_ != &null {
            self._check_payload(n->payload->type_, n->payload->range, "panicked")
        }

        return true
    }

    fn visit_try_catch_stmt(self, n: *TryCatchStmt) -> bool {
        for var i: usize = 0; i < n->arms.size(); ++i {
            var unsafe *arm = n->arms.get(i)
            if arm->decl != &null {
                self._arm_decls.insert(arm->decl as usize as u64)
            }

            if arm->decl != &null && arm->filter == &null {
                self._bare_decls.insert(arm->decl as usize as u64)
            }

            if arm->filter != &null
                && arm->filter->canonical != &null
                && !self._is_cxx_type(arm->filter->canonical) {
                self._check_payload(arm->filter->canonical, arm->filter->range, "caught")
            }
        }

        return true
    }

    /// # `finally` after a `try`

    /// A `finally` written right after a `try` / `catch` is the standalone
    /// `finally` (Compiler/Spec/Panic.md#try-and-arms, USER 2026-10-27): it is registered when
    /// control reaches it and runs when its block is left, not when the
    /// `try` finishes, and a `return`, `break` or uncaught panic out of the
    /// `try` skips it. Readers from Java, C# or Python expect the opposite
    /// on every count, so it is a warning. `} finally {` on the try's line
    /// and `finally` on the next are one shape: the parser never makes a
    /// `finally` part of a `try` (TryCatchStmt).
    fn visit_compound_stmt(self, n: *CompoundStmt) -> bool {
        for var i: usize = 1; i < n->body.size(); ++i {
            var end = n->range.end.with_offset(-1)
            self._finally_after_try(n->body[i - 1], n->body[i], end)
        }

        return true
    }

    /// \p end: the closing brace of the block \p cur sits in. (A script's
    /// top level cannot hold a `finally`: LoopContextCheck rejects it.)
    priv fn _finally_after_try(self, prev: unsafe *Stmt, cur: unsafe *Stmt, end: SourceLocation) {
        if prev == &null || cur == &null {
            return
        }

        if (!isa<TryCatchStmt>(prev)) || !isa<FinallyStmt>(cur) {
            return
        }

        var fin = cur->range.start
        var kw  = SourceRange::from_bounds(fin, 7 as u32)
        var w = self.sc->diag->report(
            DiagID::SC211W,
            fin,
            "'finally' runs when the enclosing block exits, like any 'finally', not when the 'try' before it finishes",
        )

        w.first(kw, "registered here, after the 'try'")
        w.note(DiagCode(DiagID::SC211N), end, "it runs here, when this block is left")->first(
            SourceRange::from_bounds(end, 1 as u32),
        )

        w.note(
            DiagCode(DiagID::SC211N),
            prev->range.start,
            "a 'return', 'break' or uncaught panic leaving this 'try' never reaches the 'finally', so it does not run on that path",
        )->first(SourceRange::from_bounds(prev->range.start, 3 as u32))
        w.note(
            DiagCode(DiagID::SC211N),
            "to run it as soon as the 'try' is done, and on every way out of it, put it first in a block of its own: '{ finally { ... } try { ... } catch { ... } }'",
        )

        w.emit()
    }

    fn visit_try_catch_expr(self, n: *TryCatchExpr) -> bool {
        for var i: usize = 0; i < n->catch_arms.size(); ++i {
            var unsafe *arm = n->catch_arms.get(i)
            if arm->decl != &null {
                self._arm_decls.insert(arm->decl as usize as u64)
            }

            if arm->decl != &null && arm->filter == &null {
                self._bare_decls.insert(arm->decl as usize as u64)
            }

            if arm->filter != &null
                && arm->filter->canonical != &null
                && !self._is_cxx_type(arm->filter->canonical) {
                self._check_payload(arm->filter->canonical, arm->filter->range, "caught")
            }
        }

        return true
    }

    /// The arm whose binding a `panic e` names, or null.
    priv fn _repanic_of(self, n: *PanicStmt) -> unsafe *Decl {
        var unsafe *e = self._tu.strip_parens(n->payload)
        if e == &null || !isa<NamedIdentExpr>(e) {
            return &null
        }

        var unsafe *d = cast<NamedIdentExpr>(e)->resolved_decl
        if d == &null {
            return &null
        }

        if self._arm_decls.contains(d as usize as u64) {
            return d
        }

        return &null
    }

    /// A C++ type in a `catch`: a C++ exception arm unless the set holds it
    /// (§3.5), so it is never held to the payload rules here.
    priv fn _is_cxx_type(self, t: unsafe *Type) -> bool {
        var unsafe *d = self._tu.record_decl(canon_unqual(t))
        return d != &null && decl_is_imported(d)
    }

    /// §1.5: movable, complete, a value; not a reference, not `void`.
    priv fn _check_payload(self, t_in: unsafe *Type, at: SourceRange, const how: string) {
        if t_in == &null {
            return
        }

        var unsafe *t = canon_unqual(t_in)
        if t == &null || t->is_dependent() || t->is_instantiation_dependent() {
            return
        }

        if self._tu.is_never(t) {
            return
        }

        var nm  = self._tu.str(t)
        var why = ""
        if isa<CXXLValueRefType>(t) || isa<CXXRValueRefType>(t) {
            why = "it is a reference; an error is held by value"
        } else if self._tu.is_void(t) {
            why = "'void' is not a value"
        }

        var unsafe *d = self._tu.record_decl(t)
        if why.size() == 0 && d != &null && !decl_is_imported(d) && !self._complete(d) {
            why = "it is incomplete; an error is held by value, so its size must be known"
        }

        if why.size() == 0 {
            var facts = lifecycle_of(self.sc)->facts_of_type(t)
            if facts.movable == LifecycleTri::No {
                why = "it is not movable; an error is returned and propagated by value"
                if facts.why_not_movable.size() > 0 {
                    why = why + " (" + facts.why_not_movable + ")"
                }
            }
        }

        if why.size() == 0 {
            return
        }

        var b = self.sc->diag->report(
            DiagID::SC212E,
            at.start,
            f"type '{nm}' cannot be {how}: {why}",
        )

        b.first(at)
        if d != &null && d->range.is_valid() {
            b.note(DiagCode(DiagID::SC212N), d->range.start, named_declared_here(nm))->first(
                d->range,
            )
        }

        b.emit()
    }

    priv fn _complete(self, d: unsafe *Decl) -> bool {
        if isa<Declarations::ClassDecl>(d) {
            return cast<Declarations::ClassDecl>(d)->has_definition()
        }

        if isa<Declarations::StructDecl>(d) {
            return cast<Declarations::StructDecl>(d)->has_definition()
        }

        if isa<Declarations::UnionDecl>(d) {
            return cast<Declarations::UnionDecl>(d)->has_definition()
        }

        return true
    }

    /// # declaration rules

    priv fn _check_fn_decl(self, f: unsafe *Declarations::FunctionDecl) {
        if !f->is_panic() {
            return
        }

        var at = if (f->panic_range.is_valid()) => (f->panic_range) else => f->range
        var nm = self._fn_name(f)

        if self._sr.is_main(unsafe (f as unsafe *Decl)) {
            var b = self.sc->diag->report(
                DiagID::SC213E,
                at.start,
                "'main' cannot panic: nothing above it could handle the error",
            )

            b.first(at)
            b.note(
                DiagCode(DiagID::SC213N),
                f->range.start,
                "handle every error in 'main', or stop the program with 'crash!()'",
            )->first(self._name_range(f))
            b.remove(f->panic_range, "remove 'panic'")
            b.emit()
            return
        }

        if f->is_noreturn {
            var b = self.sc->diag->report(
                DiagID::SC214E,
                at.start,
                f"'{nm}' cannot be both 'panic' and '-> !': a panic returns its error, and '!' never returns",
            )

            b.first(at)
            b.note(DiagCode(DiagID::SC214N), f->range.start, named_declared_here(nm))->first(
                self._name_range(f),
            )

            b.remove(f->panic_range, "remove 'panic'")
            b.emit()
            return
        }

        // A constructor or a destructor never panics (USER 2026-10-27): an
        // object is either built whole or not at all, and a destructor runs
        // on every exit, where nothing could take an error.
        var life = self._lifecycle_fn(f)
        if life.size() > 0 {
            var why = if (life == "a destructor") => ("it runs on every exit from the object's scope, where nothing could take an error")
                      else => "an object is either built whole or not at all"
            var b = self.sc->diag->report(DiagID::SC215E, at.start, f"{life} cannot panic: " + why)
            b.first(at)
            b.note(DiagCode(DiagID::SC215N), f->range.start, named_declared_here(nm))->first(
                self._name_range(f),
            )

            if self._is_ctor(f) {
                b.note(
                    DiagCode(DiagID::SC215N),
                    f->range.start,
                    "construction that can fail belongs in a static factory function that may panic and returns the object",
                )
            }

            b.remove(f->panic_range, "remove 'panic'")
            b.emit()
            return
        }

        // Called where no call is written: nothing could handle the error.
        var hidden = self._hidden_call(f)
        if hidden.size() > 0 {
            var b = self.sc->diag->report(
                DiagID::SC215E,
                at.start,
                f"{hidden} cannot panic: it runs where no call is written, so nothing could handle the error",
            )

            b.first(at)
            b.note(DiagCode(DiagID::SC215N), f->range.start, named_declared_here(nm))->first(
                self._name_range(f),
            )

            b.remove(f->panic_range, "remove 'panic'")
            b.emit()
            return
        }

        if panic_in_duck(f) {
            self._gate(
                at,
                "a 'panic' function under a '<T: type>' parameter (C++-checked generics)",
            )

            return
        }

        if f->panic_state == Declarations::PanicSetState::Diverged {
            var b = self.sc->diag->report(
                DiagID::SC216E,
                at.start,
                f"the panic set of '{nm}' grows without bound: it calls itself (or a function that calls it) at ever-larger type arguments",
            )

            b.first(at)
            b.note(
                DiagCode(DiagID::SC216N),
                f->range.start,
                "a declared set, 'panic(E1, E2)', bounds it: what the recursive call panics with must then be in it or caught",
            )->first(self._name_range(f))
            b.emit()
            return
        }

        if f->is_generator {
            self._gate(at, "a 'panic' generator")
            return
        }

        if f->is_async() {
            self._gate(at, "an 'async' 'panic' function")
            return
        }

        // A requirement's panic result is spelled outside the witness (its
        // conformers return it, PanicLowering::_result_of), where `Self` has
        // no C++ type: codegen stops on the interface (I003E). Reported at
        // the declaration, which every conformer and every call through a
        // bound -- operator form or method form -- goes through.
        if self._in_interface(f) && self._result_names_self(f) {
            var b = self.sc->diag->report(
                DiagID::SC116E,
                at.start,
                f"a panicking interface requirement whose result names 'Self' ('{nm}') is not yet supported",
            )

            b.first(at)
            var rt = if (f->return_type != &null) => (f->return_type->range)
                     else => self._name_range(f)
            b.note(DiagCode(DiagID::SC116N), rt.start, "its result names 'Self' here")->first(rt)
            b.emit()
            return
        }

        for var i: usize = 0; i < f->panic_set.size(); ++i {
            var unsafe *t = f->panic_set[i]
            if t != &null && t->canonical != &null {
                self._check_payload(t->canonical, t->range, "panicked")
            }
        }

        // Two elements with one type id cannot share the set (Compiler/Spec/Panic.md
        // §1.3): two builtins that are one C++ type (`usize` and `u64` where
        // size_t is uint64_t), or a hash collision. Here, so the error stops
        // the schedule before PanicLowering forms the result it cannot.
        var fs = cxx::std::vector<unsafe *Type>()
        if panic_set_of_fn(unsafe &self._tu, f, unsafe &fs) == PanicKnown::Set {
            var args = cxx::std::vector<unsafe *Type>()
            args.push_back(self.sc->builtin(BuiltinKind::Void))
            for var i: usize = 0; i < fs.size(); ++i {
                args.push_back(fs[i])
            }

            var ps = PanicSets(self.sc)
            if ps.canonicalize(unsafe &args) && !ps.check_collisions(at, args) {
                return
            }
        }

        if f->has_panic_set() {
            return
        }

        // A bare `panic` where the set is a contract (§2.2): an interface
        // requirement, and a virtual method of a base. The edit writes the
        // inferred set when there is a body to infer it from.
        if self._in_interface(f) {
            self._needs_set(
                f->panic_range,
                f->range,
                f"the panic set of interface requirement '{nm}' must be declared: it is the contract every conformer is held to",
                self._fn_inferred(f),
            )

            return
        }

        if f->abi == Declarations::AbiKind::Virtual {
            self._needs_set(
                f->panic_range,
                f->range,
                f"the panic set of virtual method '{nm}' must be declared: it is the contract every override is held to",
                self._fn_inferred(f),
            )

            return
        }

        // An inferred set on a `pub` function is API surface that changes
        // with the body: in a library build, say so (a warning, §2.2).
        if self.sc->opts.library_build
            && f->is_public()
            && !self._library_tu()
            && f->panic_state == Declarations::PanicSetState::Final {
            var s = cxx::std::vector<unsafe *Type>()
            for var i: usize = 0; i < f->panic_eff.size(); ++i {
                s.push_back(f->panic_eff[i])
            }

            var what = if (s.size() > 0) => (pset_names(&self._tu, unsafe &s)) else => "nothing"
            var b = self.sc->diag->report(
                DiagID::SC217W,
                at.start,
                f"the panic set of public function '{nm}' is inferred ({what}); declare it, or a change to the body changes its callers' contract",
            )

            b.first(at)
            self._write_set_fix(&b, f->panic_range, unsafe &s)
            b.emit()
        }
    }

    /// A bare `panic` in a position that needs the set written: the error,
    /// and the edit writing \p inferred (or removing `panic` when nothing
    /// panics; none when there is no body to infer from).
    priv fn _needs_set(self,
                       pr:        SourceRange,
                       fallback:  SourceRange,
                       const msg: string,
                       inferred:  unsafe *cxx::std::vector<unsafe *Type>) {
        var at = if (pr.is_valid()) => (pr) else => fallback
        var b  = self.sc->diag->report(DiagID::SC218E, at.start, msg)
        b.first(at, "write the set: 'panic(E1, E2)'")
        if inferred != &null {
            self._write_set_fix(&b, pr, inferred)
        } else {
            b.note(DiagCode(DiagID::SC218N), at.start, "there is no body to infer it from")
        }

        b.emit()
    }

    /// The edit that writes \p s in place of the specifier \p pr: `panic(A,
    /// B)`, or no `panic` at all for the empty set (`panic()` is not a set).
    priv fn _write_set_fix(self,
                           b:  *DiagBuilder,
                           pr: SourceRange,
                           s:  unsafe *cxx::std::vector<unsafe *Type>) {
        if !pr.is_valid() {
            return
        }

        if s->size() == 0 {
            b->remove(pr, "nothing in the body panics: remove 'panic'")
            return
        }

        var txt = "panic(" + pset_spelling(&self._tu, s) + ")"
        b->fix(pr, txt, f"declare the inferred set: '{txt}'")
    }

    /// \p f's inferred set, when it has a body that was solved; else null.
    priv fn _fn_inferred(self,
                         f: unsafe *Declarations::FunctionDecl) -> unsafe *cxx::std::vector<unsafe *Type> {
        var unsafe *h = panic_home(f)
        if h->panic_state != Declarations::PanicSetState::Final
            || h->body_block == &null && h->body_expr == &null {
            return &null
        }

        self._scratch.clear()
        for var i: usize = 0; i < h->panic_eff.size(); ++i {
            self._scratch.push_back(h->panic_eff[i])
        }

        return unsafe &self._scratch
    }

    priv fn _in_interface(self, f: unsafe *Declarations::FunctionDecl) -> bool {
        var unsafe *dc = f->semantic_dc
        if dc == &null {
            return false
        }

        var unsafe *o = dc->owner_decl()
        return o != &null && isa<Declarations::InterfaceDecl>(o)
    }

    /// The program's own file, not the builtin root or std (FlagGates'
    /// test): a library the user cannot edit is not linted.
    priv fn _library_tu(self) -> bool {
        var fid = self.sc->ctx->fid
        if self.sc->g != &null && self.sc->g->is_builtin_fid(fid) {
            return true
        }

        var unsafe *ci = self.sc->ctx->ci
        if ci == &null || self.sc->ctx->sm == &null {
            return false
        }

        return ResourceLayout::is_std_file(ci, self.sc->ctx->sm->get_filename(fid))
    }

    /// # subset rules (§2.2)

    /// An override's set is a subset of the base method's: a caller through
    /// the base handles only the base's set.
    fn visit_class_decl(self, cd: unsafe *Declarations::ClassDecl) -> bool {
        if cd == &null || cd->is_poisoned() || decl_is_imported(unsafe (cd as unsafe *Decl)) {
            return true
        }

        for var i: usize = 0; i < cd->methods.size(); ++i {
            var unsafe *m = cd->methods[i]
            // Every override, a non-panicking one too: it may also meet a
            // requirement whose set differs from its base's (_met).
            if m == &null || m->is_poisoned() || m->abi != Declarations::AbiKind::Override {
                continue
            }

            var        bt:   unsafe *Type = &null
            var unsafe *base              = panic_overridden_at(unsafe &self._tu, cd, m, unsafe &bt)
            if base == &null {
                continue
            }

            self._met(m, base, bt, "overrides", "an override")
        }

        self._conformances(cd)
        return true
    }

    fn visit_struct_decl(self, sd: unsafe *Declarations::StructDecl) -> bool {
        if sd != &null && !sd->is_poisoned() {
            self._conformances(unsafe (sd as unsafe *Decl))
        }

        return true
    }

    fn visit_extension_decl(self, x: unsafe *Declarations::ExtensionDecl) -> bool {
        if x != &null && !x->is_poisoned() {
            self._conformances(unsafe (x as unsafe *Decl))
        }

        return true
    }

    /// A conforming method's set is a subset of the requirement's, for each
    /// conformance \p by declares (`class X impl I`, `extend X impl I`).
    priv fn _conformances(self, by: unsafe *Decl) {
        if self.sc->instances == &null {
            return
        }

        var rows = cxx::std::vector<unsafe *ConformanceRow>()
        self.sc->instances->declared_rows(by, unsafe &rows)
        for var r: usize = 0; r < rows.size(); ++r {
            var unsafe *row = rows[r]
            if row == &null {
                continue
            }

            for var i: usize = 0; i < row->witnesses.size() && i < row->reqs.size(); ++i {
                var unsafe *w = dyn_cast<Declarations::FunctionDecl>(row->witnesses[i])
                var unsafe *q = dyn_cast<Declarations::FunctionDecl>(row->reqs[i])
                if w == &null || q == &null || w == q {
                    continue
                }

                if decl_is_imported(w) {
                    continue
                }

                // Only where the conformer is written: its own TU reports it.
                if self._tu.fid_of(w) != self.sc->ctx->fid {
                    continue
                }

                self._met(w, q, row->iface, "implements", "a conforming method")
            }
        }
    }

    /// \p sub's set within \p sup's; an error naming each type outside,
    /// at \p sub, with a note at \p sup and the edit adding the types to
    /// \p sup's declared set. \p through is where \p sup is met (the base
    /// record, the interface instance): a generic base's or interface's
    /// set is read at its arguments, `B<i32>`'s `panic(T)` is
    /// `panic(i32)`.
    priv fn _subset(self,
                    sub:        unsafe *Declarations::FunctionDecl,
                    sup:        unsafe *Declarations::FunctionDecl,
                    through:    unsafe *Type,
                    const verb: string,
                    const what: string) {
        var a  = cxx::std::vector<unsafe *Type>()
        var b  = cxx::std::vector<unsafe *Type>()
        var ka = panic_set_of_fn(unsafe &self._tu, sub, unsafe &a)
        if ka != PanicKnown::Set {
            return
        }

        var kb = panic_set_through(unsafe &self._tu, sup, through, unsafe &b)
        if kb == PanicKnown::Unknown {
            return
        }

        var out = cxx::std::vector<unsafe *Type>()
        for var i: usize = 0; i < a.size(); ++i {
            if !pset_has(unsafe &b, a[i]) {
                out.push_back(a[i])
            }
        }

        if out.size() == 0 {
            return
        }

        var names = pset_names(&self._tu, unsafe &out)
        var sn    = self._qual_name(sup)
        var at = if (sub->panic_range.is_valid()) => (sub->panic_range)
                 else => self._name_range(sub)
        var msg = ""
        if kb == PanicKnown::No {
            msg = f"{what} cannot panic when '{sn}', which it {verb}, does not: it panics with {names}"
        } else {
            var verb2 = if (out.size() == 1) => ("is") else => "are"
            msg = f"{names} {verb2} not in the panic set of '{sn}', which this {verb}; {what}'s set must be a subset of it"
        }

        var d = self.sc->diag->report(DiagID::SC208E, at.start, msg)
        d.first(at)
        var sat = if (sup->panic_range.is_valid()) => (sup->panic_range)
                  else => self._name_range(sup)
        d.note(DiagCode(DiagID::SC208N), sup->range.start, named_declared_here(sn))->first(sat)
        // A set naming its own parameters, read at arguments, has no
        // spelling to add to: the base's or interface's list is written in
        // its parameters, not in these arguments.
        var generic_sup = false
        for var i: usize = 0; i < sup->panic_set.size(); ++i {
            var unsafe *st = sup->panic_set[i]
            if st != &null && st->canonical != &null && panic_dep(st->canonical) {
                generic_sup = true
            }
        }

        if sup->has_panic_set()
            && sup->panic_range.is_valid()
            && !decl_is_imported(unsafe (sup as unsafe *Decl))
            && !generic_sup {
            d.insert(
                sup->panic_range.end.with_offset(-1),
                ", " + pset_spelling(&self._tu, unsafe &out),
                f"add it to the set of '{sn}'",
            )
        }

        d.emit()
    }

    /// \p w overrides or implements \p sup, met through \p through: its set
    /// is held to \p sup's, once per pair (a method meeting two -- two
    /// interfaces, or an override that is also a conformer -- is held to
    /// each), and against every other it meets (_two_sets).
    priv fn _met(self,
                 w:          unsafe *Declarations::FunctionDecl,
                 sup:        unsafe *Declarations::FunctionDecl,
                 through:    unsafe *Type,
                 const verb: string,
                 const what: string) {
        for var i: usize = 0; i < self._met_fn.size(); ++i {
            if self._met_fn[i] == w
                && self._met_sup[i] == sup
                && self._same_at(self._met_at[i], through) {
                return
            }
        }

        for var i: usize = 0; i < self._met_fn.size(); ++i {
            if self._met_fn[i] == w {
                self._two_sets(w, self._met_sup[i], self._met_at[i], sup, through)
            }
        }

        self._met_fn.push_back(w)
        self._met_sup.push_back(sup)
        self._met_at.push_back(through)
        self._subset(w, sup, through, verb, what)
    }

    /// \p f's result or a type in its declared set names `Self` (the type,
    /// a pointer to it, an argument of a record).
    priv fn _result_names_self(self, f: unsafe *Declarations::FunctionDecl) -> bool {
        if f->return_type != &null && self._names_self(f->return_type->canonical, 0) {
            return true
        }

        for var i: usize = 0; i < f->panic_set.size(); ++i {
            var unsafe *t = f->panic_set[i]
            if t != &null && self._names_self(t->canonical, 0) {
                return true
            }
        }

        return false
    }

    priv fn _names_self(self, t: unsafe *Type, depth: u32) -> bool {
        if t == &null || depth > 16 {
            return false
        }

        var unsafe *c = canon_unqual(t)
        if c == &null {
            return false
        }

        if c->kind == TypeKind::SelfType {
            return true
        }

        if c->kind == TypeKind::PointerType {
            return self._names_self(cast<PointerType>(c)->pointee, depth + 1)
        }

        if c->kind != TypeKind::RecordType {
            return false
        }

        var unsafe *d = self._tu.record_decl(c)
        if d != &null && isa<Declarations::InterfaceDecl>(d) {
            return true
        }

        var args = self._tu.record_args(c)
        for var i: usize = 0; i < args.size(); ++i {
            if self._names_self(args[i], depth + 1) {
                return true
            }
        }

        return false
    }

    /// One record a requirement is met through (`Src<A>`), or both none.
    priv fn _same_at(self, x: unsafe *Type, y: unsafe *Type) -> bool {
        if x == &null || y == &null {
            return x == y
        }

        return canon_unqual(x) == canon_unqual(y)
    }

    /// A method returns ONE C++ type, and PanicLowering gives one that
    /// meets a panicking requirement or base method that one's result
    /// (`Panic<T, E...>` over ITS set; plain T when it does not panic): the
    /// witness and the vtable name it exactly. Meeting two whose sets differ
    /// needs a result per requirement -- a thunk -- which does not exist
    /// yet, so it is reported here rather than failing in C++. Equal sets
    /// form one result, and are fine.
    priv fn _two_sets(self,
                      w:    unsafe *Declarations::FunctionDecl,
                      a_fn: unsafe *Declarations::FunctionDecl,
                      a_at: unsafe *Type,
                      b_fn: unsafe *Declarations::FunctionDecl,
                      b_at: unsafe *Type) {
        var key = (w as usize as u64)
        if self._two_done.contains(key) {
            return
        }

        var a  = cxx::std::vector<unsafe *Type>()
        var b  = cxx::std::vector<unsafe *Type>()
        var ka = panic_set_through(unsafe &self._tu, a_fn, a_at, unsafe &a)
        var kb = panic_set_through(unsafe &self._tu, b_fn, b_at, unsafe &b)
        if ka == PanicKnown::Unknown
            || ka == PanicKnown::Unbound
            || kb == PanicKnown::Unknown
            || kb == PanicKnown::Unbound {
            return
        }

        var same = a.size() == b.size()
        for var i: usize = 0; same && i < a.size(); ++i {
            if !pset_has(unsafe &b, a[i]) {
                same = false
            }
        }

        if same {
            return
        }

        self._two_done.insert(key)
        var an = self._qual_name(a_fn)
        var bn = self._qual_name(b_fn)
        var at = self._name_range(w)
        var d = self.sc->diag->report(
            DiagID::SC116E,
            at.start,
            f"a method meeting both '{an}' and '{bn}', whose panic sets differ, is not yet supported",
        )

        d.first(at)
        var ad = if (a.size() == 0) => ("does not panic")
                 else => "panics with " + pset_names(&self._tu, unsafe &a)
        var bd = if (b.size() == 0) => ("does not panic")
                 else => "panics with " + pset_names(&self._tu, unsafe &b)
        d.note(DiagCode(DiagID::SC116N), a_fn->range.start, f"'{an}' {ad}")->first(
            self._name_range(a_fn),
        )

        d.note(DiagCode(DiagID::SC116N), b_fn->range.start, f"'{bn}' {bd}")->first(
            self._name_range(b_fn),
        )

        d.emit()
    }

    /// `Base::m` / `I::m`: a method as a message names it.
    priv fn _qual_name(self, f: unsafe *Declarations::FunctionDecl) -> string {
        var unsafe *dc = f->semantic_dc
        var unsafe *o  = if (dc != &null) => (dc->owner_decl()) else => &null
        if o != &null
            && (isa<Declarations::ClassDecl>(o)
                || isa<Declarations::StructDecl>(o)
                || isa<Declarations::InterfaceDecl>(o)) {
            return self._tu.decl_name(o) + "::" + self._fn_name(f)
        }

        return self._fn_name(f)
    }

    /// # a function as a value (§2.2)

    /// A `fn` value's type carries its set, and a bare `panic` function's
    /// set is inferred only after its type was given: the function must
    /// declare it to be used as a value. The edit writes it.
    fn visit_call_expr(self, n: *CallExpr) -> bool {
        var unsafe *c = self._tu.strip_parens(n->callee)
        if c != &null {
            self._callees.insert(c as usize as u64)
        }

        return true
    }

    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        // A bare `catch e`'s binding: typed `Panic<void, L...>` once its
        // `try` was judged (_type_bare_binder, which ran with the body's
        // walk, before this use is visited). Its uses follow.
        if n->resolved_decl != &null
            && self._bare_types.contains(n->resolved_decl as usize as u64) {
            n->type_ = cast<Declarations::VariableDecl>(n->resolved_decl)->type_
            return true
        }

        if n->resolved_decl != &null
            && self._bare_decls.contains(n->resolved_decl as usize as u64) {
            return true
        }

        if self._callees.contains((unsafe (n as unsafe *Expr)) as usize as u64) {
            return true
        }

        self._value_use(n->range, n->resolved_decl)
        return true
    }

    fn visit_chain_expr(self, n: *ChainExpr) -> bool {
        if self._callees.contains((unsafe (n as unsafe *Expr)) as usize as u64) {
            return true
        }

        if n->steps.size() == 0 {
            return true
        }

        var unsafe *st = n->steps.get(n->steps.size() - 1)
        self._value_use(n->range, st->resolved_decl)
        return true
    }

    priv fn _value_use(self, at: SourceRange, d: unsafe *Decl) {
        var unsafe *f = dyn_cast<Declarations::FunctionDecl>(d)
        if f == &null || !f->is_panic() {
            return
        }

        var unsafe *h = panic_home(f)
        if h->has_panic_set() || f->has_panic_set() {
            return
        }

        var nm = self._fn_name(f)
        var b = self.sc->diag->report(
            DiagID::SC219E,
            at.start,
            f"'{nm}' is used as a value, but its panic set is inferred: a 'fn' value's type carries the set, so '{nm}' must declare it",
        )

        b.first(at)
        var pr  = if (h->panic_range.is_valid()) => (h->panic_range) else => f->panic_range
        var nat = if (pr.is_valid()) => (pr) else => self._name_range(f)
        b.note(DiagCode(DiagID::SC219N), f->range.start, named_declared_here(nm))->first(nat)
        var unsafe *inf = self._fn_inferred(f)
        if inf != &null {
            self._write_set_fix(&b, pr, inf)
        }

        b.emit()
    }

    priv fn _check_closure_decl(self, c: unsafe *ClosureExpr) {
        if !self._closure_panics(c) {
            return
        }

        var at = if (c->panic_range.is_valid()) => (c->panic_range) else => c->range
        if c->generic_params.size() > 0 {
            self._gate(at, "a generic 'panic' closure")
            return
        }

        if ((c->modifiers as u16) & (Declarations::FnModifier::IsAsync as u16)) != 0 {
            self._gate(at, "an 'async' 'panic' closure")
            return
        }

        if c->is_noreturn {
            var b = self.sc->diag->report(
                DiagID::SC214E,
                at.start,
                "a closure cannot be both 'panic' and '-> !': a panic returns its error, and '!' never returns",
            )

            b.first(at)
            b.note(DiagCode(DiagID::SC214N), c->range.start, "the closure is here")->first(c->range)
            b.remove(c->panic_range, "remove 'panic'")
            b.emit()
            return
        }

        for var i: usize = 0; i < c->panic_set.size(); ++i {
            var unsafe *t = c->panic_set[i]
            if t != &null && t->canonical != &null {
                self._check_payload(t->canonical, t->range, "panicked")
            }
        }

        if c->panic_set.size() > 0 {
            return
        }

        // A closure writes its set (§2.2): a readability rule, the set is
        // visible where the closure is. It was inferred anyway, for the edit.
        var inf: unsafe *cxx::std::vector<unsafe *Type> = &null
        if c->panic_state == Declarations::PanicSetState::Final {
            self._scratch.clear()
            for var i: usize = 0; i < c->panic_eff.size(); ++i {
                self._scratch.push_back(c->panic_eff[i])
            }

            inf = unsafe &self._scratch
        }

        self._needs_set(
            c->panic_range,
            c->range,
            "a closure's panic set must be declared: 'fn () panic(E) -> T'",
            inf,
        )
    }

    /// A `fn` type has no body to infer from: its set is written (§2.2).
    fn visit_function_pointer_type(self, n: *FunctionPointerType) -> bool {
        // A set naming a generic parameter (`fn <E> run(f: fn() panic(E))`)
        // stays gated: deduction never reads a `fn` type's effect
        // (E would only come from an explicit argument), and substitution
        // keeps a `fn` type's set as written (Substitution::substitute).
        for var i: usize = 0; i < n->panic_set.size(); ++i {
            var unsafe *t = n->panic_set[i]
            if t == &null || t->canonical == &null {
                continue
            }

            if t->canonical->is_dependent() || t->canonical->is_instantiation_dependent() {
                self._gate(t->range, "a 'fn' type's panic set that depends on a generic parameter")
                return true
            }
        }

        if !n->is_panic() || n->panic_set.size() > 0 {
            return true
        }

        var pr = n->qual_range(TypeQual<Type>::Flags::IsPanic)
        self._needs_set(
            pr,
            n->range,
            "the panic set of a 'fn' type must be declared: 'fn(T) panic(E) -> U'",
            &null,
        )

        return true
    }

    /// What \p f is when the language calls it without a call being
    /// written, for the message; empty when it is called only explicitly.
    /// "a constructor" / "a destructor" for any constructor (with or
    /// without parameters, a transfer one included) or the destructor;
    /// "" for every other function.
    priv fn _lifecycle_fn(self, f: unsafe *Declarations::FunctionDecl) -> string {
        if f->transfer != Declarations::TransferKind::NotTransfer {
            return "a transfer constructor"
        }

        if f->is_operator && f->op_token.size() > 0 && f->op_token[0].kind == TokenKind::KwFinally {
            return "a destructor"
        }

        if self._is_ctor(f) {
            return "a constructor"
        }

        return ""
    }

    /// Called where no call is written (constructors and the destructor are
    /// _lifecycle_fn's, which runs first).
    priv fn _hidden_call(self, f: unsafe *Declarations::FunctionDecl) -> string {
        if f->is_operator && f->op_token.size() > 0 {
            var k = f->op_token[0].kind
            if k == TokenKind::KwPanic {
                return "'op panic'"
            }

            if OperatorFacts::is_implicit_conv(f) {
                return "an " + LangAttrs::quoted(LangAttrs::implicit_conversion()) + " conversion"
            }
        }

        return ""
    }

    priv fn _is_ctor(self, f: unsafe *Declarations::FunctionDecl) -> bool {
        if f->is_operator || !f->is_method() {
            return false
        }

        var unsafe *dc = f->semantic_dc
        if dc == &null || !dc->is_type_scope() || dc->dc_owner == &null {
            return false
        }

        return self._tu.decl_name(unsafe (f as unsafe *Decl)) == self._tu.decl_name(dc->dc_owner)
    }

    priv fn _gate(self, at: SourceRange, const what: string) {
        var b = self.sc->diag->report(DiagID::SC116E, at.start, f"{what} is not yet supported")
        b.first(at)
        b.emit()
    }

    /// # judging one body

    /// Every site of \p w against what \p kind lets leave the body.
    priv fn _judge(self,
                   w:      *PanicWalk,
                   kind:   PanicBody,
                   f:      unsafe *Declarations::FunctionDecl,
                   c:      unsafe *ClosureExpr,
                   holder: unsafe *Decl) {
        if w->sites.size() == 0 && w->tries.size() == 0 && w->unbound_at.size() == 0 {
            return
        }

        // Gated bodies: every panicking site is unsupported, caught or not.
        var gate = ""
        if f != &null {
            if panic_in_duck(f) {
                gate = "a function under a '<T: type>' parameter (C++-checked generics)"
            } else if f->is_generator {
                gate = "a generator"
            } else if f->is_async() {
                gate = "an 'async' function"
            }
        }

        if c != &null {
            if c->generic_params.size() > 0 {
                gate = "a generic closure"
            } else if ((c->modifiers as u16) & (Declarations::FnModifier::IsAsync as u16)) != 0 {
                gate = "an 'async' closure"
            } else if self._fn_stack.size() > 0
                && panic_in_duck(
                    unsafe (self._fn_stack[self._fn_stack.size() - 1] as unsafe *Decl),
                ) {
                gate = "a closure under a '<T: type>' parameter (C++-checked generics)"
            }
        }

        if gate.size() > 0 {
            for var i: usize = 0; i < w->sites.size(); ++i {
                var *s   = &w->sites[i]
                var what = if (s->raise != &null) => ("a 'panic'") else => "a call that may panic"
                self._gate(s->range, f"{what} inside {gate}")
            }

            return
        }

        // A callee whose set names a type parameter this call does not bind
        // (no bound declares the requirement it calls): its set here is not
        // known, so nothing could be checked about it.
        for var i: usize = 0; i < w->unbound_at.size(); ++i {
            self._gate(
                w->unbound_at[i],
                f"a call of '{self._fn_name(w->unbound_fn[i])}', whose panic set names a generic parameter this call does not bind,",
            )
        }

        // A panicking operator written as an operator is lowered to its held
        // call by PanicLowering, derived forms included. Not yet: the call a
        // `for` loop makes of `op in`, a place operator (`op []` giving a
        // `*T`, which C++ declares returning `T&`, not a panic result), an
        // `op as` (a C++ conversion function, whose result is its target
        // type), and `===`'s `==` (CoalesceLowering's).
        for var i: usize = 0; i < w->sites.size(); ++i {
            var        *s  = &w->sites[i]
            var unsafe *cf = dyn_cast<Declarations::FunctionDecl>(s->callee)
            if cf == &null || !cf->is_operator {
                continue
            }

            if s->via_for {
                self._gate(s->range, "a 'for' loop over a panicking 'op in'")
            } else if OperatorFacts::is_place(cf) {
                self._gate(
                    s->range,
                    "a call of a panicking place operator ('op []' returning a pointer)",
                )
            } else if OperatorFacts::op_kind(cf) == TokenKind::KwAs {
                self._gate(s->range, "a call of a panicking 'op as'")
            } else if s->op_node != &null
                && isa<BinaryOperatorExpr>(s->op_node)
                && cast<BinaryOperatorExpr>(
                    s->op_node,
                )->op_token.kind == TokenKind::OpEqualEqualEqual {
                self._gate(s->range, "'===' through a panicking 'op =='")
            }
        }

        if kind == PanicBody::Global {
            for var i: usize = 0; i < w->sites.size(); ++i {
                self._global_site(&w->sites[i], holder)
            }

            for var i: usize = 0; i < w->tries.size(); ++i {
                self._global_try(&w->tries[i], holder)
            }

            return
        }

        // The arms of every `try` against what reached it (§3.1). What
        // leaves a `try` was routed to the enclosing one or to the body by
        // the walk, and is judged with the sites below.
        for var i: usize = 0; i < w->tries.size(); ++i {
            self._judge_try(&w->tries[i])
        }

        if f != &null && panic_in_generic(f) {
            self._record_arms(w, f)
        }

        if w->sites.size() == 0 {
            return
        }

        // What may leave: the declared set, the inferred one, or nothing.
        var allowed  = cxx::std::vector<unsafe *Type>()
        var inferred = false
        var declared = false
        if f != &null && f->is_panic() && kind == PanicBody::Fn {
            if f->has_panic_set() {
                declared = true
                if !canonical_set(unsafe &self._tu, &f->panic_set, unsafe &allowed) {
                    return
                }
            } else {
                inferred = true
            }
        }

        if c != &null && self._closure_panics(c) {
            if c->panic_set.size() > 0 {
                declared = true
                if !canonical_set(unsafe &self._tu, &c->panic_set, unsafe &allowed) {
                    return
                }
            } else {
                inferred = true
            }
        }

        if inferred { // the inferred set holds every leftover.
            return
        }

        for var i: usize = 0; i < w->sites.size(); ++i {
            var *s      = &w->sites[i]
            var missing = cxx::std::vector<unsafe *Type>()
            for var k: usize = 0; k < s->left.size(); ++k {
                if !pset_has(unsafe &allowed, s->left[k]) {
                    missing.push_back(s->left[k])
                }
            }

            if missing.size() == 0 {
                continue
            }

            if declared {
                self._outside_declared(s, unsafe &missing, f, c)
            } else {
                self._unhandled(s, unsafe &missing, kind, f, c, holder)
            }
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
        var n = if (t->stmt != &null) => (t->stmt->arms.size()) else => t->expr->catch_arms.size()
        if t->stmt != &null {
            t->stmt->reach.from_vec(unsafe &t->reach, self.sc->ctx)
        } else {
            t->expr->reach.from_vec(unsafe &t->reach, self.sc->ctx)
        }

        self._type_bare_binder(t)
        for var i: usize = 0; i < n; ++i {
            var unsafe *filt = self._arm_filter(t, i)
            if filt == &null || filt->canonical == &null {
                continue
            }

            var unsafe *c  = canon_unqual(filt->canonical)
            var        ar  = self._arm_range(t, i)
            var        dup = false
            for var j: usize = 0; j < i; ++j {
                var unsafe *fj = self._arm_filter(t, j)
                if fj == &null || fj->canonical == &null || canon_unqual(fj->canonical) != c {
                    continue
                }

                var b = self.sc->diag->report(
                    DiagID::SC209E,
                    ar.start,
                    f"a second 'catch' arm for '{self._tu.str(c)}': the first one already catches it",
                )

                b.first(filt->range)
                var rj = self._arm_range(t, j)
                b.note(DiagCode(DiagID::SC209N), rj.start, "the first arm is here")->first(rj)
                b.remove(ar, "remove this arm")
                b.emit()
                dup = true
                break
            }

            if dup {
                continue
            }

            if pset_has(unsafe &t->reach, c) {
                continue
            }

            if self._is_cxx_type(c) {
                self._cxx_arm(t, i, c, filt, ar)
                continue
            }

            if t->stmt != &null {
                t->stmt->arms.get(i)->is_dead = true
            } else {
                t->expr->catch_arms.get(i)->is_dead = true
            }

            var why = "nothing in this 'try' can panic"
            if t->reach.size() > 0 {
                why = "this 'try' may panic only with " + pset_names(&self._tu, unsafe &t->reach)
            }

            var w = self.sc->diag->report(
                DiagID::SC210W,
                ar.start,
                f"this arm never runs: '{self._tu.str(c)}' is not in the panic set of its 'try' ({why})",
            )

            w.first(filt->range)
            w.remove(ar, "remove the arm")
            w.emit()
        }
    }

    /// A generic body's `try`s whose live typed arms could name one type at
    /// an instance -- two or more, at least one dependent -- onto \p f
    /// (FunctionDecl::panic_arms) for the instance check: §3.1's duplicate
    /// arm is an error, and at `catch e: T` beside `catch e: A` only an
    /// instance can say whether T is A (PanicInstances).
    priv fn _record_arms(self, w: *PanicWalk, f: unsafe *Declarations::FunctionDecl) {
        var ts = cxx::std::vector<unsafe *Type>()
        var rs = cxx::std::vector<SourceRange>()
        for var i: usize = 0; i < w->tries.size(); ++i {
            var *t = &w->tries[i]
            var n = if (t->stmt != &null) => (t->stmt->arms.size())
                    else => t->expr->catch_arms.size()
            var mine = cxx::std::vector<unsafe *Type>()
            var mat  = cxx::std::vector<SourceRange>()
            var dep  = false
            for var k: usize = 0; k < n; ++k {
                var unsafe *filt = self._arm_filter(t, k)
                if filt == &null || filt->canonical == &null {
                    continue
                }

                var dead = if (t->stmt != &null) => (t->stmt->arms.get(k)->is_dead)
                           else => t->expr->catch_arms.get(k)->is_dead
                var cx = if (t->stmt != &null) => (t->stmt->arms.get(k)->is_cxx)
                         else => t->expr->catch_arms.get(k)->is_cxx
                if dead || cx {
                    continue
                }

                var unsafe *c = canon_unqual(filt->canonical)
                if panic_dep(c) {
                    dep = true
                }

                mine.push_back(c)
                mat.push_back(filt->range)
            }

            if mine.size() < 2 || !dep {
                continue
            }

            for var k: usize = 0; k < mine.size(); ++k {
                ts.push_back(mine[k])
                rs.push_back(mat[k])
            }

            ts.push_back(&null)
            rs.push_back(SourceRange::invalid())
        }

        if ts.size() == 0 {
            return
        }

        var unsafe *home = panic_home(f)
        home->panic_arms.from_vec(unsafe &ts, self.sc->ctx)
        home->panic_arm_at.from_vec(unsafe &rs, self.sc->ctx)
    }

    /// A C++ exception arm (§3.5): marked for PanicLowering, which keeps it
    /// as a C++ `catch` around the lowered body. It needs C++ exceptions: a
    /// build without them (-fno-exceptions, a freestanding target) cannot
    /// catch one, and clang would reject the `try` it lowers to.
    priv fn _cxx_arm(self,
                     t:    *PanicTry,
                     i:    usize,
                     c:    unsafe *Type,
                     filt: unsafe *Type,
                     ar:   SourceRange) {
        if t->stmt != &null {
            t->stmt->arms.get(i)->is_cxx = true
        } else {
            t->expr->catch_arms.get(i)->is_cxx = true
        }

        if self.sc->opts.cxx_exceptions {
            return
        }

        var nm = self._tu.str(c)
        var b = self.sc->diag->report(
            DiagID::SC220E,
            ar.start,
            f"'catch' of the C++ exception '{nm}' in a build without C++ exceptions (-fno-exceptions, or a target with no OS)",
        )

        b.first(filt->range, "a C++ type outside the panic set: this arm catches a C++ exception")
        var unsafe *d = self._tu.record_decl(c)
        if d != &null && d->range.is_valid() {
            b.note(
                DiagCode(DiagID::SC220N),
                d->range.start,
                f"'{nm}' is declared here, in C++",
            )->first(d->range)
        }

        b.remove(ar, "remove the arm")
        b.emit()
    }

    /// A bare `catch e`'s binding holds whatever the arm catches: one of
    /// the types the `try` leaves after its typed arms. X typed it before
    /// any set was known (the `Panic` lang item with no arguments); here it
    /// becomes `Panic<void, L...>` over that leftover L (Compiler/Spec/Panic.md#try-and-arms),
    /// formed like every panic result (PanicSets::form), and its uses are
    /// retyped as they are visited (visit_named_ident_expr). Nothing is
    /// caught when L is empty: the arm never runs, and keeps X's type.
    priv fn _type_bare_binder(self, t: *PanicTry) {
        var n = if (t->stmt != &null) => (t->stmt->arms.size()) else => t->expr->catch_arms.size()
        for var i: usize = 0; i < n; ++i {
            var filt: unsafe *Type = &null
            var d:    unsafe *Decl = &null
            var r                  = self._arm_range(t, i)
            if t->stmt != &null {
                filt = t->stmt->arms.get(i)->filter
                d    = t->stmt->arms.get(i)->decl
            } else {
                filt = t->expr->catch_arms.get(i)->filter
                d    = t->expr->catch_arms.get(i)->decl
            }

            if filt != &null || d == &null || !isa<Declarations::VariableDecl>(d) {
                continue
            }

            var left = cxx::std::vector<unsafe *Type>()
            for var k: usize = 0; k < t->reach.size(); ++k {
                if !pset_has(unsafe &t->types, t->reach[k]) {
                    left.push_back(t->reach[k])
                }
            }

            if left.size() == 0 {
                continue
            }

            var unsafe *pt = PanicSets(self.sc).form(
                r,
                self.sc->builtin(BuiltinKind::Void),
                unsafe &left,
            )

            if pt == &null {
                continue
            }

            cast<Declarations::VariableDecl>(d)->type_ = pt
            self._bare_types.insert(d as usize as u64)
        }
    }

    priv fn _arm_filter(self, t: *PanicTry, i: usize) -> unsafe *Type {
        if t->stmt != &null {
            return t->stmt->arms.get(i)->filter
        }

        return t->expr->catch_arms.get(i)->filter
    }

    priv fn _arm_range(self, t: *PanicTry, i: usize) -> SourceRange {
        if t->stmt != &null {
            return t->stmt->arms.get(i)->range
        }

        return t->expr->catch_arms.get(i)->range
    }

    /// A site whose leftover is outside the body's declared set.
    priv fn _outside_declared(self,
                              s:       *PanicSite,
                              missing: unsafe *cxx::std::vector<unsafe *Type>,
                              f:       unsafe *Declarations::FunctionDecl,
                              c:       unsafe *ClosureExpr) {
        var names = pset_names(&self._tu, missing)
        var owner = if (c != &null) => ("the closure") else => f"'{self._fn_name(f)}'"
        var verb  = if (missing->size() == 1) => ("is") else => "are"
        var b = self.sc->diag->report(
            DiagID::SC221E,
            s->range.start,
            f"{names} {verb} not in the declared panic set of {owner}",
        )

        b.first(s->range, self._site_label(s, names))
        self._origin_note(&b, s)
        var pr = if (c != &null) => (c->panic_range) else => f->panic_range
        if pr.is_valid() {
            b.insert(
                pr.end.with_offset(-1),
                ", " + pset_spelling(&self._tu, missing),
                "add it to the declared set",
            )
        }

        b.emit()
    }

    /// A site whose leftover reaches a body that lets nothing leave.
    priv fn _unhandled(self,
                       s:       *PanicSite,
                       missing: unsafe *cxx::std::vector<unsafe *Type>,
                       kind:    PanicBody,
                       f:       unsafe *Declarations::FunctionDecl,
                       c:       unsafe *ClosureExpr,
                       holder:  unsafe *Decl) {
        var names = pset_names(&self._tu, missing)
        var head  = ""
        var what  = self._site_what(s)
        var nh    = if (missing->size() == 1) => ("is not handled") else => "are not handled"
        if kind == PanicBody::Main {
            head = f"a panic cannot reach 'main': {what} {names}, which {nh}"
        } else if kind == PanicBody::Script {
            head = f"a panic cannot reach a script's top level: {what} {names}, which {nh}"
        } else if kind == PanicBody::Field {
            head = f"a field's default cannot panic: {what} {names}, which {nh}"
        } else if kind == PanicBody::Param {
            head = f"a parameter's default cannot panic: {what} {names}, which {nh}"
        } else if kind == PanicBody::Ctor {
            head = f"a constructor cannot panic: {what} {names}, which {nh}"
        } else if kind == PanicBody::Dtor {
            head = f"a destructor cannot panic: {what} {names}, which {nh}"
        } else if c != &null {
            head = f"unhandled panic: {what} {names}, and the closure is not marked 'panic'"
        } else {
            head = f"unhandled panic: {what} {names}, and '{self._fn_name(f)}' is not marked 'panic'"
        }

        var b = self.sc->diag->report(DiagID::SC221E, s->range.start, head)
        b.first(s->range, self._site_label(s, names))
        self._origin_note(&b, s)
        // Propagate: mark the body `panic` (never main, a script or a default).
        if kind == PanicBody::Fn && f != &null && f->params_end.is_valid() {
            b.insert(
                f->params_end.end,
                " panic",
                f"mark '{self._fn_name(f)}' 'panic' to propagate it",
            )
        } else if kind == PanicBody::Closure && c != &null && c->params_end.is_valid() {
            b.insert(c->params_end.end, " panic", "mark the closure 'panic' to propagate it")
        }

        // Handle it here: a call becomes `try call catch => crash!()`. Only a
        // call, an expression; a `panic` statement has no value to wrap.
        if kind == PanicBody::Ctor {
            b.note(
                DiagCode(DiagID::SC221N),
                s->range.start,
                "construction that can fail belongs in a static factory function that may panic and returns the object",
            )
        }

        if s->raise == &null {
            var msg = if (kind == PanicBody::Main
                          || kind == PanicBody::Script
                          || kind == PanicBody::Ctor
                          || kind == PanicBody::Dtor) => ("or handle it here, or stop the program with 'crash!()'")
                      else => "or handle it here"
            b.note(DiagCode(DiagID::SC221N), s->range.start, msg)
            b.child_fix(
                SourceRange(s->range.start, s->range.start),
                "try ",
                "wrap the call in 'try'",
            )

            b.child_fix(
                SourceRange(s->range.end, s->range.end),
                " catch => crash!()",
                "catch everything it may panic with",
            )
        }

        if holder != &null
            && holder->range.is_valid()
            && (kind == PanicBody::Field || kind == PanicBody::Param) {
            b.note(
                DiagCode(DiagID::SC221N),
                holder->range.start,
                "the default is declared here",
            )->first(holder->range)
        }

        b.emit()
    }

    /// §4.5: nothing in a global's initializer may panic.
    priv fn _global_site(self, s: *PanicSite, holder: unsafe *Decl) {
        var names = pset_names(&self._tu, unsafe &s->all)
        var b = self.sc->diag->report(
            DiagID::SC222E,
            s->range.start,
            f"a global's initializer cannot panic: {self._site_what(s)} {names}, and there is no function to propagate to",
        )

        b.first(s->range)
        self._origin_note(&b, s)
        if holder != &null && holder->range.is_valid() {
            b.note(
                DiagCode(DiagID::SC222N),
                holder->range.start,
                "initialize it in a function instead",
            )->first(holder->range)
        }

        b.emit()
    }

    priv fn _global_try(self, t: *PanicTry, holder: unsafe *Decl) {
        var r = if (t->stmt != &null) => (t->stmt->range) else => t->expr->range
        var b = self.sc->diag->report(
            DiagID::SC222E,
            r.start,
            "a global's initializer cannot hold a 'try': it runs at file scope, outside every function",
        )

        b.first(r)
        if holder != &null && holder->range.is_valid() {
            b.note(
                DiagCode(DiagID::SC222N),
                holder->range.start,
                "initialize it in a function instead",
            )->first(holder->range)
        }

        b.emit()
    }

    /// `'f' may panic with` / `this 'panic' raises` / `this call may panic with`.
    priv fn _site_what(self, s: *PanicSite) -> string {
        if s->raise != &null {
            return "this 'panic' raises"
        }

        if s->callee != &null && isa<Declarations::FunctionDecl>(s->callee) {
            var unsafe *cf = cast<Declarations::FunctionDecl>(s->callee)
            if cf->is_operator {
                return "this operator may panic with"
            }

            return f"'{self._fn_name(cf)}' may panic with"
        }

        return "this call may panic with"
    }

    priv fn _site_label(self, s: *PanicSite, const names: string) -> string {
        if s->raise != &null {
            return f"raises {names}"
        }

        return f"may panic with {names}"
    }

    /// The note at where the set came from: the callee's declaration.
    priv fn _origin_note(self, b: *DiagBuilder, s: *PanicSite) {
        if s->callee == &null || !isa<Declarations::FunctionDecl>(s->callee) {
            return
        }

        var unsafe *cf = cast<Declarations::FunctionDecl>(s->callee)
        if !cf->range.is_valid() {
            return
        }

        var r = if (cf->panic_range.is_valid()) => (cf->panic_range) else => self._name_range(cf)
        b->note(
            DiagCode(DiagID::SC222N),
            cf->range.start,
            f"'{self._fn_name(cf)}' is declared 'panic' here",
        )->first(r)
    }

    /// # helpers

    priv fn _closure_panics(self, c: unsafe *ClosureExpr) -> bool {
        return ((c->modifiers as u16) & (Declarations::FnModifier::IsPanic as u16)) != 0
    }

    priv fn _fn_name(self, f: unsafe *Declarations::FunctionDecl) -> string {
        if f == &null {
            return "<fn>"
        }

        if f->is_operator {
            return "op " + OperatorFacts::symbol(f)
        }

        return self._tu.decl_name(unsafe (f as unsafe *Decl))
    }

    priv fn _name_range(self, f: unsafe *Declarations::FunctionDecl) -> SourceRange {
        if !f->is_operator && f->name.range.is_valid() {
            return f->name.range
        }

        return f->range
    }

    /// At file or module scope. A local `static` is not one: C++ runs its
    /// initializer inside the function, which handles or propagates it.
    priv fn _is_global(self, vd: unsafe *Declarations::VariableDecl) -> bool {
        var unsafe *dc = vd->semantic_dc
        if dc == &null {
            return false
        }

        if dc->is_translation_unit() {
            return true
        }

        var unsafe *o = dc->owner_decl()
        return o != &null && isa<Declarations::ModuleDecl>(o)
    }
}
