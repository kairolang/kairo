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
///     before Typed, an undefined bare-`panic` prototype, a generator or
///     `async` `panic` function, one with a `<T: type>` parameter (each
///     gated where it is declared). A call to it adds nothing and is never
///     reported unhandled. A `where` group's set is the union of its
///     members' (§2.8).
///
///     Generics (P10, MONO.md D0/D5): a generic body's set is computed once,
///     at its definition, like any other -- what it raises, its concrete
///     callees' sets, and the DECLARED sets of the bound requirements it
///     calls -- and may name its own type parameters. A call reads its
///     callee's set AT THE CALL (panic_call_set): a requirement's at the
///     bound's arguments (G7's declaring instance), a generic function's at
///     the call's arguments, a generic record's method at its receiver's.
///     Nothing is inferred per instance. A recursion at ever-larger type
///     arguments would grow a set forever; past a nesting depth it stops,
///     Diverged, and is reported.
///
///     The canonical ORDER is P1's (§1.3): by type id, as PanicTypeIds
///     orders a formed `Panic<...>`, so the set a body is checked against
///     and the result type PanicLowering forms from it are one list. Stable
///     run to run, so every message naming a set reads the same.
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
import Sema::Type::PanicSets::*;
import Sema::Type::ArgumentDeduction::*;
import Sema::Type::Substitution::*;
import AST::OperatorFacts::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::InstantiationRegistry::*;
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

/// \p a before \p b in the canonical order (PANIC.md §1.3): by type id,
/// ties (a collision, itself an error where the set is formed) by the
/// spelling key -- PanicTypeIds::order, so a set here and the `Panic<...>`
/// PanicLowering forms from it list their types alike. A type with no id
/// (dependent, a reference: never in a formed set) orders by spelling, then
/// by address.
fn pset_before(tu: *TypeUtil, a: *Type, b: *Type) -> bool {
    if tu->sc != &null {
        var ps = PanicSets(tu->sc);
        var ia = ps.type_id(a);
        var ib = ps.type_id(b);
        if (ia != u32(0)) && (ib != u32(0)) {
            if ia != ib { return ia < ib; }
            var ka = ps.type_key(a);
            var kb = ps.type_key(b);
            if ka != kb { return ka < kb; }
        }
    }
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
    /// Its set names a generic parameter this call does not bind (no bound
    /// declares the requirement, no argument fills the parameter): the set
    /// at the call is not known. Reported at the call (SC116E), never read
    /// as a set.
    Unbound,
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
/// a member of one, or an extension of one): its set may name a type
/// parameter, and C++ orders it per instance (P10).
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

/// A function some enclosing declaration of which has a `<T: type>`
/// parameter: the C++-checked regime (MONO.md D1), whose body is typed as
/// written and checked by clang per instance. A set there cannot be closed
/// at the definition -- a call through `T` is unresolved, so it would add
/// nothing whatever it panics with -- so a panic in one stays SC116E.
fn panic_in_duck(d_in: *Decl) -> bool {
    var d = d_in;
    for var depth: u32 = 0; (d != &null) && (depth < 64); ++depth {
        var gps = decl_generic_params(d);
        for var i: usize = 0; i < gps.size(); ++i {
            if (gps[i] != &null) && (gps[i]->kind_bound == GenericParamKindBound::Duck) { return true; }
        }
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

/// One function's own set, a `where` member's included (its body's).
fn panic_set_of_member(tu: *TypeUtil, f_in: *FunctionDecl, out: *vec::<*Type>) -> PanicKnown {
    if f_in == &null { return PanicKnown::Unknown; }
    // A `where` group is one redeclaration chain whose links are distinct
    // bodies: a member's facts are its own, never the chain's.
    var f = (f_in) if (f_in->where_lead != &null) else (panic_home(f_in));
    if (!f->is_panic()) && (!f_in->is_panic()) { return PanicKnown::No; }
    if panic_lifecycle_fn(tu, f) { return PanicKnown::No; }
    if f->panic_state == PanicSetState::Final {
        for var i: usize = 0; i < f->panic_eff.size(); ++i { out->push_back(f->panic_eff[i]); }
        return (PanicKnown::Set) if (out->size() > 0) else (PanicKnown::No);
    }
    if (f->panic_state == PanicSetState::Unknown) || (f->panic_state == PanicSetState::Diverged) { return PanicKnown::Unknown; }
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

/// The final set of \p f_in into \p out. A `where` group is one function
/// to its callers, bound to its lead: its set is the union of its members'
/// (PANIC.md §2.8), each member's its own body's.
fn panic_set_of_fn(tu: *TypeUtil, f_in: *FunctionDecl, out: *vec::<*Type>) -> PanicKnown {
    if f_in == &null { return PanicKnown::Unknown; }
    var lead = f_in->where_lead;
    if (lead != &null) && (lead->where_group.size() > 0) {
        var any = false;
        for var i: usize = 0; i < lead->where_group.size(); ++i {
            var s = vec::<*Type>();
            var k = panic_set_of_member(tu, lead->where_group[i], &s);
            if k == PanicKnown::Unknown { return PanicKnown::Unknown; }
            for var j: usize = 0; j < s.size(); ++j {
                pset_add(tu, out, s[j]);
                any = true;
            }
        }
        return (PanicKnown::Set) if (any) else (PanicKnown::No);
    }
    return panic_set_of_member(tu, f_in, out);
}


// === a callee's set at the call (P10) ========================================

/// \p t has a component that names a type parameter.
fn panic_dep(t: *Type) -> bool {
    return (t != &null) && (t->is_dependent() || t->is_instantiation_dependent());
}

/// \p t's value type: a pointer, a reference and a nullable stripped (a
/// receiver read through `->`, `?.`).
fn panic_recv_value(tu: *TypeUtil, t_in: *Type) -> *Type {
    if t_in == &null { return &null; }
    var t = canon_unqual(t_in);
    for var guard: u32 = 0; (t != &null) && (guard < 8); ++guard {
        if isa::<PointerType>(t) { t = canon_unqual(cast::<PointerType>(t)->pointee); continue; }
        if isa::<CXXLValueRefType>(t) { t = canon_unqual(cast::<CXXLValueRefType>(t)->referee); continue; }
        if isa::<CXXRValueRefType>(t) { t = canon_unqual(cast::<CXXRValueRefType>(t)->referee); continue; }
        if isa::<NullableType>(t) { t = canon_unqual(cast::<NullableType>(t)->inner); continue; }
        break;
    }
    return t;
}

/// The receiver a call is made through: `r` of `r.m()` / `r->m()`, or the
/// first argument of a `::`-qualified method call (`I::m(x)`). Null for a
/// free call.
fn panic_call_receiver(tu: *TypeUtil, c: *CallExpr, f: *FunctionDecl) -> *Type {
    if c == &null { return &null; }
    var e = tu->strip_parens(c->callee);
    if (e != &null) && isa::<ChainExpr>(e) {
        var ch = cast::<ChainExpr>(e);
        var n = ch->steps.size();
        if n > 0 {
            var last = ch->steps.get(n - 1);
            if last->access_kind != ChainExpr::AccessKind::ColonColon {
                if n >= 2 { return panic_recv_value(tu, ch->steps.get(n - 2)->resolved_type); }
                if (ch->base != &null) { return panic_recv_value(tu, ch->base->type_); }
                return &null;
            }
        }
    }
    // `I::m(x)` / `Box::m(b)`: `self` is the first argument.
    if (f != &null) && (f->params.size() > 0) && (f->params[0] != &null) && f->params[0]->is_self && (c->args.size() > 0) {
        var a = c->args[0];
        if (a != &null) { return panic_recv_value(tu, a->type_); }
    }
    return &null;
}

/// The record \p r is, or derives, whose pattern is \p owner, read through
/// \p r's arguments hop by hop (`class D derives Box<i32>`: a `d.get()`
/// reaches Box's method at `Box<i32>`); null when none is.
fn panic_base_at(tu: *TypeUtil, r_in: *Type, owner: *Decl, depth: u32) -> *Type {
    if (r_in == &null) || (depth > 32) { return &null; }
    var r = canon_unqual(r_in);
    if (r == &null) || (!isa::<RecordType>(r)) { return &null; }
    var rd = tu->record_decl(r);
    if rd == &null { return &null; }
    if NameLookup::representative(tu->pattern_of(rd)) == owner { return r; }
    var body = tu->sc->record_body(r);
    if (body == &null) || (!isa::<ClassDecl>(NameLookup::representative(body))) { return &null; }
    var cd = cast::<ClassDecl>(NameLookup::representative(body));
    for var i: usize = 0; i < cd->derives_list.size(); ++i {
        var e = cd->derives_list.get(i);
        if (e == &null) || (e->base == &null) || (e->base->canonical == &null) { continue; }
        var b = canon_unqual(e->base->canonical);
        if panic_dep(b) {
            var sub = Substitution(tu->sc);
            sub.bind_from_record(r);
            var x = sub.substitute(b);
            if x != &null { b = canon_unqual(x); }
        }
        var hit = panic_base_at(tu, b, owner, depth + 1);
        if hit != &null { return hit; }
    }
    return &null;
}

/// \p owner's type parameters, each still unbound in \p d, bound to
/// itself: a call inside the generic that names its own members at its own
/// parameters (`self.m()` in `Box<T>`, `f(x)` recursing at `T`) reads the
/// callee's set as written.
fn panic_bind_self(tu: *TypeUtil, d: *Deduction, owner_in: *Decl) {
    if owner_in == &null { return; }
    var owner = NameLookup::representative(owner_in);
    var gps = decl_generic_params(owner);
    for var i: usize = 0; i < gps.size(); ++i {
        var gp = gps[i];
        if gp == &null { continue; }
        if gp->is_pack {
            if !d->pack_open(owner, gp->index) { d->push_pack(owner, gp->index, tu->sc->types->generic_param(owner, gp->index, true)); }
            continue;
        }
        if d->lookup(owner, gp->index) == &null { d->bind(owner, gp->index, tu->sc->types->generic_param(owner, gp->index, false)); }
    }
}

/// \p f's own (and its extension's) type parameters from what the call
/// chose: the instance's arguments, or the dependent arguments a call in a
/// generic body records -- ConformanceChecking::_bind_instance's order (an
/// extension's parameters first).
fn panic_bind_args(tu: *TypeUtil, d: *Deduction, f: *FunctionDecl, c: *CallExpr) {
    if c == &null { return; }
    var args = vec::<*Type>();
    var ie = reinterpret_cast::<*InstanceEntry>(c->instance);
    if ie != &null {
        for var i: usize = 0; i < ie->args.size(); ++i { args.push_back(ie->args[i]); }
    } else {
        for var i: usize = 0; i < c->dep_args.size(); ++i { args.push_back(c->dep_args[i]); }
    }
    if args.size() == 0 { return; }
    var k: usize = 0;
    var x = decl_extension_of(static_cast::<*Decl>(f));
    if x != &null {
        var eps = decl_generic_params(static_cast::<*Decl>(x));
        var xr = NameLookup::representative(static_cast::<*Decl>(x));
        for var i: usize = 0; (i < eps.size()) && (k < args.size()); ++i {
            if eps[i] != &null { d->bind(xr, eps[i]->index, args[k]); }
            k += 1;
        }
    }
    var gps = decl_generic_params(static_cast::<*Decl>(f));
    var pr = NameLookup::representative(static_cast::<*Decl>(f));
    for var i: usize = 0; (i < gps.size()) && (k < args.size()); ++i {
        var gp = gps[i];
        if gp == &null { k += 1; continue; }
        if gp->is_pack {
            d->open_pack(pr, gp->index);
            while k < args.size() { d->push_pack(pr, gp->index, args[k]); k += 1; }
            break;
        }
        d->bind(pr, gp->index, args[k]);
        k += 1;
    }
}

/// Bind what \p f's set may name, for the call \p c through receiver \p recv
/// (either may be null): false when a requirement's declaring interface
/// is not found (no bound, no qualifier declares it).
fn panic_bind_call(tu: *TypeUtil, d: *Deduction, f: *FunctionDecl, c: *CallExpr, recv: *Type) -> bool {
    var dc = reinterpret_cast::<*DeclContext>(f->semantic_dc);
    var owner = (NameLookup::representative(dc->owner_decl())) if ((dc != &null) && (dc->owner_decl() != &null)) else (&null);
    if (owner != &null) && isa::<InterfaceDecl>(owner) {
        // A requirement means its declared set at the interface's arguments
        // the call goes through (MONO.md G7): a written qualifier, or the
        // receiver's first bound that declares it.
        var di: *Type = &null;
        if (c != &null) && (c->witness_iface != &null) { di = d->declaring_instance(f, c->witness_iface); }
        if (di == &null) && (recv != &null) {
            var bs = tu->bound_ifaces(recv);
            for var i: usize = 0; (i < bs.size()) && (di == &null); ++i { di = d->declaring_instance(f, bs[i]); }
            // A concrete receiver conforming to a generic interface is the
            // row's instance: the bound list of a concrete type is empty.
        }
        if di != &null { d->bind_from_record(di); }
        else if decl_generic_params(owner).size() > 0 { return false; }
        panic_bind_args(tu, d, f, c);
        panic_bind_self(tu, d, static_cast::<*Decl>(f));
        return true;
    }
    if (owner != &null) && (decl_generic_params(owner).size() > 0) {
        var r = panic_base_at(tu, panic_recv_value(tu, recv), owner, 0);
        if r != &null { d->bind_from_record(r); }
        panic_bind_self(tu, d, owner);
    }
    var x = decl_extension_of(static_cast::<*Decl>(f));
    panic_bind_args(tu, d, f, c);
    if x != &null { panic_bind_self(tu, d, static_cast::<*Decl>(x)); }
    panic_bind_self(tu, d, static_cast::<*Decl>(f));
    return true;
}

/// \p f's set as the call \p c (through receiver \p recv) sees it: \p f's
/// final set with every type parameter it names read at the call's
/// arguments (P10). A concrete set is \p f's own. Unbound when a parameter
/// it names is not bound here.
fn panic_call_set(tu: *TypeUtil, f: *FunctionDecl, c: *CallExpr, recv: *Type, out: *vec::<*Type>) -> PanicKnown {
    var raw = vec::<*Type>();
    var k = panic_set_of_fn(tu, f, &raw);
    if k != PanicKnown::Set { return k; }
    var dep = false;
    for var i: usize = 0; i < raw.size(); ++i { if panic_dep(raw[i]) { dep = true; } }
    if !dep {
        for var i: usize = 0; i < raw.size(); ++i { pset_add(tu, out, raw[i]); }
        return PanicKnown::Set;
    }
    var d = Deduction(tu->sc, &null);
    if !panic_bind_call(tu, &d, f, c, recv) { return PanicKnown::Unbound; }
    for var i: usize = 0; i < raw.size(); ++i {
        var s = d.substitute(raw[i]);
        if s == &null { return PanicKnown::Unbound; }
        pset_add(tu, out, s);
    }
    return PanicKnown::Set;
}

/// \p t read through \p f's call \p c (panic_call_set's bindings): a
/// callee's dependent panic result as this call receives it, or null when
/// a parameter it names is not bound here.
fn panic_call_type(tu: *TypeUtil, f: *FunctionDecl, c: *CallExpr, recv: *Type, t: *Type) -> *Type {
    if (t == &null) || (!panic_dep(t)) { return t; }
    var d = Deduction(tu->sc, &null);
    if !panic_bind_call(tu, &d, f, c, recv) { return &null; }
    return d.substitute(t);
}

/// How deeply \p t nests types (a record's arguments, a pointee): the
/// solve's guard against a recursion at ever-larger arguments.
fn panic_type_depth(t: *Type, budget: u32) -> u32 {
    if (t == &null) || (budget == 0) { return 0; }
    var c = canon_unqual(t);
    if c == &null { return 0; }
    if isa::<PointerType>(c) { return 1 + panic_type_depth(cast::<PointerType>(c)->pointee, budget - 1); }
    if isa::<NullableType>(c) { return 1 + panic_type_depth(cast::<NullableType>(c)->inner, budget - 1); }
    if isa::<RecordType>(c) {
        var r = cast::<RecordType>(c);
        var m: u32 = 0;
        for var i: usize = 0; i < r->args.size(); ++i {
            var x = panic_type_depth(r->args[i], budget - 1);
            if x > m { m = x; }
        }
        return 1 + m;
    }
    return 1;
}

/// panic_overridden, and the base record it was found in, \p out_base, as
/// \p cd derives it (`B<i32>` for `class D derives B<i32>`): a generic
/// base's method is read through it (its parameters, its panic set, P10).
/// A generic base is walked as its pattern (an instance shell holds no
/// methods), each hop's bases read through the hop's arguments.
fn panic_overridden_at(tu: *TypeUtil, cd: *ClassDecl, m: *FunctionDecl, out_base: * *Type) -> *FunctionDecl {
    // An operator has no name to spell (FunctionDecl::name): it is
    // matched by its symbol.
    var nm = (OperatorFacts::symbol(m)) if (m->is_operator) else (tu->decl_name(static_cast::<*Decl>(m)));
    var seen = vec::<*Decl>();
    var todo = vec::<*Type>();
    for var i: usize = 0; i < cd->derives_list.size(); ++i {
        var e = cd->derives_list.get(i);
        if (e == &null) || (e->base == &null) || (e->base->canonical == &null) { continue; }
        todo.push_back(canon_unqual(e->base->canonical));
    }
    var k: usize = 0;
    while k < todo.size() {
        var bt = todo[k];
        k += 1;
        var bd0 = tu->record_decl(bt);
        if bd0 == &null { continue; }
        var d = NameLookup::representative(tu->pattern_of(bd0));
        var dup = false;
        for var i: usize = 0; i < seen.size(); ++i { if seen[i] == d { dup = true; break; } }
        if dup { continue; }
        seen.push_back(d);
        var bc = dyn_cast::<ClassDecl>(d);
        if bc == &null { continue; }
        var sub = Substitution(tu->sc);
        var generic = decl_generic_params(d).size() > 0;
        if generic { sub.bind_from_record(bt); }
        for var i: usize = 0; i < bc->methods.size(); ++i {
            var b = bc->methods[i];
            if (b == &null) || ((b->abi != AbiKind::Virtual) && (b->abi != AbiKind::Override)) { continue; }
            if b->is_operator != m->is_operator { continue; }
            var bn = (OperatorFacts::symbol(b)) if (b->is_operator) else (tu->decl_name(static_cast::<*Decl>(b)));
            if bn != nm { continue; }
            if b->params.size() != m->params.size() { continue; }
            var same = true;
            for var p: usize = 0; p < m->params.size(); ++p {
                var x = m->params[p];
                var y = b->params[p];
                if (x == &null) || (y == &null) { same = false; break; }
                if x->is_self || y->is_self { continue; }
                if (x->type_ == &null) || (y->type_ == &null) || (y->type_->canonical == &null) { same = false; break; }
                var yt = y->type_->canonical;
                if generic && panic_dep(yt) {
                    var ys = sub.substitute(yt);
                    if ys != &null { yt = ys; }
                }
                if x->type_->canonical != yt { same = false; break; }
            }
            if same {
                (*out_base) = bt;
                return b;
            }
        }
        for var i: usize = 0; i < bc->derives_list.size(); ++i {
            var e = bc->derives_list.get(i);
            if (e == &null) || (e->base == &null) || (e->base->canonical == &null) { continue; }
            var nb = canon_unqual(e->base->canonical);
            if generic && panic_dep(nb) {
                var x = sub.substitute(nb);
                if x != &null { nb = canon_unqual(x); }
            }
            todo.push_back(nb);
        }
    }
    return &null;
}

/// The method \p m overrides: the nearest base's virtual or override
/// method of its name, arity and parameter types.
fn panic_overridden(tu: *TypeUtil, cd: *ClassDecl, m: *FunctionDecl) -> *FunctionDecl {
    var bt: *Type = &null;
    return panic_overridden_at(tu, cd, m, &bt);
}

/// \p sup's final set read through \p at (a base record `B<i32>`, an
/// interface instance `Src<IOError>`): what a subset rule holds an
/// override or a conformer to (P10). \p at null, or a concrete set: the
/// set as it is. Unknown when a parameter it names is not bound by \p at.
fn panic_set_through(tu: *TypeUtil, sup: *FunctionDecl, at: *Type, out: *vec::<*Type>) -> PanicKnown {
    var raw = vec::<*Type>();
    var k = panic_set_of_fn(tu, sup, &raw);
    if k != PanicKnown::Set { return k; }
    var sub = Substitution(tu->sc);
    if at != &null { sub.bind_from_record(at); }
    for var i: usize = 0; i < raw.size(); ++i {
        var t = raw[i];
        if panic_dep(t) && (at != &null) {
            var x = sub.substitute(t);
            if x == &null { return PanicKnown::Unknown; }
            t = x;
        }
        pset_add(tu, out, t);
    }
    return PanicKnown::Set;
}

/// Write \p s as the final set of \p f's whole redeclaration chain.
fn panic_store_fn(ctx: *ASTContext, f: *FunctionDecl, s: *vec::<*Type>, st: PanicSetState) {
    if f == &null { return; }
    // A `where` member's chain links its siblings, each its own body.
    if f->where_lead != &null {
        f->panic_eff.from_vec(s, ctx);
        f->panic_state = st;
        return;
    }
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
    /// Calls whose callee's set names a type parameter they do not bind
    /// (PanicKnown::Unbound), and the callee: they add nothing.
    pub var unbound_at: vec::<SourceRange>;
    pub var unbound_fn: vec::<*FunctionDecl>;

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
            // A dependent type is an element like any other: a generic
            // body's set names its parameters (P10), and C++ orders it at
            // each instance.
            s.push_back(c);
        }
        self._site(n->range, &null, n, &s);
        return true;
    }

    fn visit_call_expr(self, n: *CallExpr) -> bool {
        if n->is_poisoned() { return true; }
        var f = self._callee_fn(n);
        if f != &null {
            self._call(n->range, f, n, panic_call_receiver(&(self.tu), n, f));
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
        self._op(n->range, n->resolved_op, self._type_of(n->operand));
        return true;
    }
    fn visit_binary_operator_expr(self, n: *BinaryOperatorExpr) -> bool {
        self._op(n->range, n->resolved_op, self._type_of(n->lhs));
        return true;
    }
    fn visit_assign_operator_expr(self, n: *AssignOperatorExpr) -> bool {
        self._op(n->range, n->resolved_op, self._type_of(n->lhs));
        return true;
    }
    fn visit_subscript_expr(self, n: *SubscriptExpr) -> bool {
        self._op(n->range, n->resolved_op, self._type_of(n->base));
        return true;
    }
    fn visit_type_cast_expr(self, n: *TypeCastExpr) -> bool {
        self._op(n->range, n->resolved_op, self._type_of(n->operand));
        return true;
    }

    /// `for x in r` over a record's `op in`: the operator is called.
    fn visit_ranged_for_stmt(self, n: *RangedForStmt) -> bool {
        if (n->iter_op != &null) && isa::<FunctionDecl>(n->iter_op) {
            var r = (n->iterable->range) if (n->iterable != &null) else (n->range);
            self._call(r, cast::<FunctionDecl>(n->iter_op), &null, self._type_of(n->iterable));
        }
        return true;
    }

    priv fn _type_of(self, e: *Expr) -> *Type {
        if e == &null { return &null; }
        return panic_recv_value(&(self.tu), e->type_);
    }

    priv fn _op(self, at: SourceRange, d: *Decl, recv: *Type) {
        if (d == &null) || (!isa::<FunctionDecl>(d)) { return; }
        self._call(at, cast::<FunctionDecl>(d), &null, recv);
    }

    /// One call of \p f: its set as this call reads it (P10). A set naming
    /// a parameter the call does not bind adds nothing and is kept for
    /// PanicEffectChecking to report.
    priv fn _call(self, at: SourceRange, f: *FunctionDecl, c: *CallExpr, recv: *Type) {
        var s = vec::<*Type>();
        var k = panic_call_set(&(self.tu), f, c, recv, &s);
        if k == PanicKnown::Unbound {
            self.unbound_at.push_back(at);
            self.unbound_fn.push_back(f);
            return;
        }
        if k != PanicKnown::Set { return; }
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

/// How deeply a type in an inferred set may nest before the set is called
/// Diverged (EffectTable::solve). Far past anything a program names: only a
/// recursion that builds a deeper type each round gets there.
fn PANIC_SET_DEPTH_MAX() -> u32 { return u32(48); }

/// One body the solve infers: a bare-`panic` function or closure, and the
/// context of the TU it is in.
class EffectEntry {
    pub var fd: *FunctionDecl = &null;
    pub var ce: *ClosureExpr  = &null;
    pub var sc: *SemaContext  = &null;
    fn EffectEntry(self) { }
}

/// A bare-`panic` function whose set can be inferred: it has a body, and
/// it is not a generator, `async` or under a `<T: type>` parameter (each
/// gated at its declaration by PanicEffectChecking). A generic one is
/// inferred like any other, at its definition (P10). A `where` member is its own body;
/// its group's set is the union (panic_set_of_fn).
fn panic_inferable_fn(f: *FunctionDecl) -> bool {
    if (f == &null) || f->is_poisoned() { return false; }
    if (!f->is_panic()) || f->has_panic_set() { return false; }
    if (f->body_block == &null) && (f->body_expr == &null) { return false; }
    if f->is_generator || f->is_async() { return false; }
    if panic_in_duck(static_cast::<*Decl>(f)) { return false; }
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
                if (e.fd != &null) && (e.fd->panic_state == PanicSetState::Diverged) { continue; }
                var grew = false;
                var deep = false;
                for var k: usize = 0; k < w.escape.size(); ++k {
                    if pset_add(&(w.tu), &cur, w.escape[k]) {
                        grew = true;
                        if panic_type_depth(w.escape[k], PANIC_SET_DEPTH_MAX() + u32(1)) > PANIC_SET_DEPTH_MAX() { deep = true; }
                    }
                }
                if !grew { continue; }
                // A recursion at ever-larger type arguments (`f<Box<T>>`
                // inside `f<T>`, P10) adds a deeper type every round and
                // would never stop (§2.5's argument assumes the types are
                // the ones the bodies name). Past the limit the function's
                // set is Diverged: reported at it, read as unknown.
                if deep && (e.fd != &null) {
                    panic_store_fn(e.sc->ctx, e.fd, &cur, PanicSetState::Diverged);
                    changed = true;
                    continue;
                }
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
