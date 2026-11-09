/// --- The Kairo Project --------------- Sema/Check/EffectPropagation.k --- ///
///
///   \brief Infer the panic set of every function and closure (Compiler/Spec/Panic.md#effect-sets).
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
///         PanicEffectChecking (Compiler/Spec/Pipeline.md, "The Typed barrier"). With
///         no driver table, PanicEffectChecking builds one for its own TU.
///
///     A set that cannot be known says nothing: a callee whose TU stopped
///     before Typed, an undefined bare-`panic` prototype, a generator or
///     `async` `panic` function, one with a `<T: type>` parameter (each
///     gated where it is declared). A call to it adds nothing and is never
///     reported unhandled. A `where` group's set is the union of its
///     members' (§2.8).
///
///     Generics (Compiler/Spec/Generics.md#decisions/D5): a generic body's set is computed once,
///     at its definition, like any other -- what it raises, its concrete
///     callees' sets, and the DECLARED sets of the bound requirements it
///     calls -- and may name its own type parameters. A call reads its
///     callee's set AT THE CALL (panic_call_set): a requirement's at the
///     bound's arguments (the declaring instance), a generic function's at
///     the call's arguments, a generic record's method at its receiver's.
///     Nothing is inferred per instance. A recursion at ever-larger type
///     arguments would grow a set forever; past a nesting depth it stops,
///     Diverged, and is reported.
///
///     The canonical ORDER is the type-id order (§1.3): by type id, as PanicTypeIds
///     orders a formed `Panic<...>`, so the set a body is checked against
///     and the result type PanicLowering forms from it are one list. Stable
///     run to run, so every message naming a set reads the same.
///
///   Phase: CHECK (the solve runs at the Typed barrier; see Sema.k)
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
ffi "c++" import "llvm/ADT/DenseSet.h"

import AST::ASTSupport::FrozenList
import AST::Context::ASTContext::ASTContext
import AST::DeclFacts::{
    decl_extension_of,
    decl_generic_params,
}
import AST::Kind::TypeKind::TypeKind
import AST::Node::Base::{
    Decl,
    Expr,
    Stmt,
    Type,
}
import AST::Node::CanonicalNodes::{
    RecordType,
    canon_has_const,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Expressions::{
    AssignOperatorExpr, BinaryOperatorExpr, CallExpr, ClosureExpr, SubscriptExpr, TryCatchExpr,
    TypeCastExpr,       UnaryOperatorExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Program::TopLevelKind
import AST::Node::Statements::{
    PanicStmt,
    RangedForStmt,
    TryCatchStmt,
}
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    FunctionPointerType,
    NullableType,
    PointerType,
}
import AST::OperatorFacts::OperatorFacts
import AST::ParamMode::ParamMode
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Location::SourceRange::SourceRange
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::SemaContext
import Sema::Type::ArgumentDeduction::Deduction
import Sema::Type::PanicSets::PanicSets
import Sema::Type::Substitution::Substitution
import Sema::Type::TypeUtil::TypeUtil
import Token::TokenKind::TokenKind

/// # sets

/// \p a before \p b in the canonical order (Compiler/Spec/Panic.md#canonical-sets): by type id,
/// ties (a collision, itself an error where the set is formed) by the
/// spelling key -- PanicTypeIds::order, so a set here and the `Panic<...>`
/// PanicLowering forms from it list their types alike. A type with no id
/// (dependent, a reference: never in a formed set) orders by spelling, then
/// by address.
pub fn pset_before(tu: unsafe *TypeUtil, a: unsafe *Type, b: unsafe *Type) -> bool {
    if tu->sc != &null {
        var ps = PanicSets(tu->sc)
        var ia = ps.type_id(a)
        var ib = ps.type_id(b)
        if ia != (0 as u32) && ib != (0 as u32) {
            if ia != ib {
                return ia < ib
            }

            var ka = ps.type_key(a)
            var kb = ps.type_key(b)
            if ka != kb {
                return ka < kb
            }
        }
    }

    var sa = tu->str(a)
    var sb = tu->str(b)
    if sa != sb {
        return sa < sb
    }

    return (a as usize as u64) < (b as usize as u64)
}

/// \p t is in \p s (canonical, unqualified on both sides).
pub fn pset_has(s: unsafe *cxx::std::vector<unsafe *Type>, t: unsafe *Type) -> bool {
    for var i: usize = 0; i < s->size(); ++i {
        if (*s)[i] == t {
            return true
        }
    }

    return false
}

/// Insert \p t into \p s where the order puts it; false when it was there.
pub fn pset_add(tu:   unsafe *TypeUtil,
                s:    unsafe *cxx::std::vector<unsafe *Type>,
                t_in: unsafe *Type) -> bool {
    if t_in == &null {
        return false
    }

    var unsafe *t = canon_unqual(t_in)
    if t == &null {
        return false
    }

    if pset_has(s, t) {
        return false
    }

    var at: usize = s->size()
    for var i: usize = 0; i < s->size(); ++i {
        if pset_before(tu, t, (*s)[i]) {
            at = i
            break
        }
    }

    s->push_back(t)
    var j = s->size() - 1
    while j > at {
        (*s)[j] = (*s)[j - 1]
        j -= 1
    }

    (*s)[at] = t
    return true
}

/// The canonical set of a written list (`panic(E1, E2)`): false when an
/// element did not resolve, so the set is not known.
pub fn canonical_set(tu:      unsafe *TypeUtil,
                     written: *FrozenList<unsafe *Type>,
                     out:     unsafe *cxx::std::vector<unsafe *Type>) -> bool {
    for var i: usize = 0; i < written->size(); ++i {
        var unsafe *w = (*written)[i]
        if w == &null || w->canonical == &null || w->is_poisoned() {
            return false
        }

        pset_add(tu, out, w->canonical)
    }

    return true
}

/// `'A', 'B' and 'C'`: a set as a message names it.
pub fn pset_names(tu: *TypeUtil, s: unsafe *cxx::std::vector<unsafe *Type>) -> string {
    var out = ""
    for var i: usize = 0; i < s->size(); ++i {
        if i > 0 {
            if i + 1 == s->size() {
                out += " and "
            } else {
                out += ", "
            }
        }

        out += "'" + tu->str((*s)[i]) + "'"
    }

    return out
}

/// `A, B`: a set as the source spells it, for a fix-it.
pub fn pset_spelling(tu: *TypeUtil, s: unsafe *cxx::std::vector<unsafe *Type>) -> string {
    var out = ""
    for var i: usize = 0; i < s->size(); ++i {
        if i > 0 {
            out += ", "
        }

        out += tu->str((*s)[i])
    }

    return out
}

/// # what a callee may panic with

/// What a set query found.
pub enum PanicKnown derives u8 {
    No = 0,  ///< it does not panic.
    Set,     ///< it panics with the set written to `out`.
    Unknown, ///< nobody can tell (file header): say nothing.
    /// Its set names a generic parameter this call does not bind (no bound
    /// declares the requirement, no argument fills the parameter): the set
    /// at the call is not known. Reported at the call (SC116E), never read
    /// as a set.
    Unbound,
}

/// The function a redeclaration chain's facts are read from: its
/// definition when it has one, else \p f itself.
pub fn panic_home(f: unsafe *Declarations::FunctionDecl) -> unsafe *Declarations::FunctionDecl {
    if f == &null {
        return f
    }

    var unsafe *d = f->definition()
    if d != &null {
        return d
    }

    return f
}

/// A function some enclosing declaration of which is generic (a template,
/// a member of one, or an extension of one): its set may name a type
/// parameter, and C++ orders it per instance.
pub fn panic_in_generic(d_in: unsafe *Decl) -> bool {
    var unsafe *d = d_in
    for var depth: u32 = 0; d != &null && depth < 64; ++depth {
        if decl_generic_params(d).size() > 0 {
            return true
        }

        var unsafe *dc = d->semantic_dc
        if dc == &null {
            return false
        }

        d = dc->owner_decl()
    }

    return false
}

/// A function some enclosing declaration of which has a `<T: type>`
/// parameter: the C++-checked regime (Compiler/Spec/Generics.md#duck-regime), whose body is typed as
/// written and checked by clang per instance. A set there cannot be closed
/// at the definition -- a call through `T` is unresolved, so it would add
/// nothing whatever it panics with -- so a panic in one stays SC116E.
pub fn panic_in_duck(d_in: unsafe *Decl) -> bool {
    var unsafe *d = d_in
    for var depth: u32 = 0; d != &null && depth < 64; ++depth {
        var gps = decl_generic_params(d)
        for var i: usize = 0; i < gps.size(); ++i {
            if gps[i] != &null && gps[i]->kind_bound == Declarations::GenericParamKindBound::Duck {
                return true
            }
        }

        var unsafe *dc = d->semantic_dc
        if dc == &null {
            return false
        }

        d = dc->owner_decl()
    }

    return false
}

/// Any constructor (a transfer one included) or the destructor: they never
/// panic (USER 2026-10-27; PanicEffectChecking reports a `panic` on one), so
/// a call of one adds nothing, whatever it was marked.
pub fn panic_lifecycle_fn(tu: unsafe *TypeUtil, f: unsafe *Declarations::FunctionDecl) -> bool {
    if f == &null {
        return false
    }

    if f->transfer != Declarations::TransferKind::NotTransfer {
        return true
    }

    if f->is_operator {
        return f->op_token.size() > 0 && f->op_token[0].kind == TokenKind::KwFinally
    }

    if !f->is_method() {
        return false
    }

    var unsafe *dc = f->semantic_dc
    if dc == &null || !dc->is_type_scope() || dc->dc_owner == &null {
        return false
    }

    return tu->decl_name(unsafe (f as unsafe *Decl)) == tu->decl_name(dc->dc_owner)
}

/// One function's own set, a `where` member's included (its body's).
pub fn panic_set_of_member(tu:         unsafe *TypeUtil,
                           f_in:       unsafe *Declarations::FunctionDecl,
                           @inout out: cxx::std::vector<unsafe *Type>) -> PanicKnown {
    if f_in == &null {
        return PanicKnown::Unknown
    }

    // A `where` group is one redeclaration chain whose links are distinct
    // bodies: a member's facts are its own, never the chain's.
    var unsafe *f = if (f_in->where_lead != &null) => (f_in) else => panic_home(f_in)
    if !f->is_panic() && !f_in->is_panic() {
        return PanicKnown::No
    }

    if panic_lifecycle_fn(tu, f) {
        return PanicKnown::No
    }

    if f->panic_state == Declarations::PanicSetState::Final {
        for var i: usize = 0; i < f->panic_eff.size(); ++i {
            out.push_back(f->panic_eff[i])
        }

        return if (out.size() > 0) => (PanicKnown::Set) else => PanicKnown::No
    }

    if f->panic_state == Declarations::PanicSetState::Unknown
        || f->panic_state == Declarations::PanicSetState::Diverged {
        return PanicKnown::Unknown
    }

    // Declared: the set is the declaration, whatever the body does (a body
    // breaking it is reported at the body).
    if f->has_panic_set() {
        var s = cxx::std::vector<unsafe *Type>()
        if !canonical_set(tu, &f->panic_set, unsafe &s) {
            return PanicKnown::Unknown
        }

        for var i: usize = 0; i < s.size(); ++i {
            out.push_back(s[i])
        }

        return PanicKnown::Set
    }

    // A bare `panic` nobody solved: no body here, or a TU that stopped.
    return PanicKnown::Unknown
}

/// The final set of \p f_in into \p out. A `where` group is one function
/// to its callers, bound to its lead: its set is the union of its members'
/// (Compiler/Spec/Panic.md#crashes-are-not-panics), each member's its own body's.
pub fn panic_set_of_fn(tu:   unsafe *TypeUtil,
                       f_in: unsafe *Declarations::FunctionDecl,
                       out:  unsafe *cxx::std::vector<unsafe *Type>) -> PanicKnown {
    if f_in == &null {
        return PanicKnown::Unknown
    }

    var unsafe *lead = f_in->where_lead
    if lead != &null && lead->where_group.size() > 0 {
        var any = false
        for var i: usize = 0; i < lead->where_group.size(); ++i {
            var s = cxx::std::vector<unsafe *Type>()
            var k = panic_set_of_member(tu, lead->where_group[i], &s)
            if k == PanicKnown::Unknown {
                return PanicKnown::Unknown
            }

            for var j: usize = 0; j < s.size(); ++j {
                pset_add(tu, out, s[j])
                any = true
            }
        }

        return if (any) => (PanicKnown::Set) else => PanicKnown::No
    }

    return panic_set_of_member(tu, f_in, &*out)
}


/// # a callee's set at the call

/// \p t has a component that names a type parameter.
pub fn panic_dep(t: unsafe *Type) -> bool {
    return t != &null && (t->is_dependent() || t->is_instantiation_dependent())
}

/// \p t's value type: a pointer, a reference and a nullable stripped (a
/// receiver read through `->`, `?.`).
pub fn panic_recv_value(tu: unsafe *TypeUtil, t_in: unsafe *Type) -> unsafe *Type {
    if t_in == &null {
        return &null
    }

    var unsafe *t = canon_unqual(t_in)
    for var guard: u32 = 0; t != &null && guard < 8; ++guard {
        if isa<PointerType>(t) {
            t = canon_unqual(cast<PointerType>(t)->pointee)
            continue
        }

        if isa<CXXLValueRefType>(t) {
            t = canon_unqual(cast<CXXLValueRefType>(t)->referee)
            continue
        }

        if isa<CXXRValueRefType>(t) {
            t = canon_unqual(cast<CXXRValueRefType>(t)->referee)
            continue
        }

        if isa<NullableType>(t) {
            t = canon_unqual(cast<NullableType>(t)->inner)
            continue
        }

        break
    }

    return t
}

/// The receiver a call is made through: `r` of `r.m()` / `r->m()`, or the
/// first argument of a `::`-qualified method call (`I::m(x)`). Null for a
/// free call.
pub fn panic_call_receiver(tu: unsafe *TypeUtil,
                           c:  unsafe *CallExpr,
                           f:  unsafe *Declarations::FunctionDecl) -> unsafe *Type {
    if c == &null {
        return &null
    }

    var unsafe *e = tu->strip_parens(c->callee)
    if e != &null && isa<ChainExpr>(e) {
        var unsafe *ch = cast<ChainExpr>(e)
        var        n   = ch->steps.size()
        if n > 0 {
            var unsafe *last = ch->steps.get(n - 1)
            if last->access_kind != ChainExpr::AccessKind::ColonColon {
                if n >= 2 {
                    return panic_recv_value(tu, ch->steps.get(n - 2)->resolved_type)
                }

                if ch->base != &null {
                    return panic_recv_value(tu, ch->base->type_)
                }

                return &null
            }
        }
    }

    // `I::m(x)` / `Box::m(b)`: `self` is the first argument.
    if f != &null
        && f->params.size() > 0
        && f->params[0] != &null
        && f->params[0]->is_self
        && c->args.size() > 0 {
        var unsafe *a = c->args[0]
        if a != &null {
            return panic_recv_value(tu, a->type_)
        }
    }

    return &null
}

/// The record \p r is, or derives, whose pattern is \p owner, read through
/// \p r's arguments hop by hop (`class D derives Box<i32>`: a `d.get()`
/// reaches Box's method at `Box<i32>`); null when none is.
pub fn panic_base_at(tu:    unsafe *TypeUtil,
                     r_in:  unsafe *Type,
                     owner: unsafe *Decl,
                     depth: u32) -> unsafe *Type {
    if r_in == &null || depth > 32 {
        return &null
    }

    var unsafe *r = canon_unqual(r_in)
    if r == &null || !isa<RecordType>(r) {
        return &null
    }

    var unsafe *rd = tu->record_decl(r)
    if rd == &null {
        return &null
    }

    if NameLookup::representative(tu->pattern_of(rd)) == owner {
        return r
    }

    var unsafe *body = tu->sc->record_body(r)
    if body == &null || !isa<Declarations::ClassDecl>(NameLookup::representative(body)) {
        return &null
    }

    var unsafe *cd = cast<Declarations::ClassDecl>(NameLookup::representative(body))
    for var i: usize = 0; i < cd->derives_list.size(); ++i {
        var unsafe *e = cd->derives_list.get(i)
        if e == &null || e->base == &null || e->base->canonical == &null {
            continue
        }

        var unsafe *b = canon_unqual(e->base->canonical)
        if panic_dep(b) {
            var sub = Substitution(tu->sc)
            sub.bind_from_record(r)
            var unsafe *x = sub.substitute(b)
            if x != &null {
                b = canon_unqual(x)
            }
        }

        var unsafe *hit = panic_base_at(tu, b, owner, depth + 1)
        if hit != &null {
            return hit
        }
    }

    return &null
}

/// \p owner's type parameters, each still unbound in \p d, bound to
/// itself: a call inside the generic that names its own members at its own
/// parameters (`self.m()` in `Box<T>`, `f(x)` recursing at `T`) reads the
/// callee's set as written.
pub fn panic_bind_self(tu: unsafe *TypeUtil, d: unsafe *Deduction, owner_in: unsafe *Decl) {
    if owner_in == &null {
        return
    }

    var unsafe *owner = NameLookup::representative(owner_in)
    var        gps    = decl_generic_params(owner)
    for var i: usize = 0; i < gps.size(); ++i {
        var unsafe *gp = gps[i]
        if gp == &null {
            continue
        }

        if gp->is_pack {
            if !d->pack_open(owner, gp->index) {
                d->push_pack(owner, gp->index, tu->sc->types->generic_param(owner, gp->index, true))
            }

            continue
        }

        if d->lookup(owner, gp->index) == &null {
            d->bind(owner, gp->index, tu->sc->types->generic_param(owner, gp->index, false))
        }
    }
}

/// \p f's own (and its extension's) type parameters from what the call
/// chose: the instance's arguments, or the dependent arguments a call in a
/// generic body records -- ConformanceChecking::_bind_instance's order (an
/// extension's parameters first).
pub fn panic_bind_args(tu: unsafe *TypeUtil,
                       d:  unsafe *Deduction,
                       f:  unsafe *Declarations::FunctionDecl,
                       c:  unsafe *CallExpr) {
    if c == &null {
        return
    }

    var        args = cxx::std::vector<unsafe *Type>()
    var unsafe *ie  = c->instance
    if ie != &null {
        for var i: usize = 0; i < ie->args.size(); ++i {
            args.push_back(ie->args[i])
        }
    } else {
        for var i: usize = 0; i < c->dep_args.size(); ++i {
            args.push_back(c->dep_args[i])
        }
    }

    if args.size() == 0 {
        return
    }

    var        k: usize = 0
    var unsafe *x       = decl_extension_of(f)
    if x != &null {
        var        eps = decl_generic_params(x)
        var unsafe *xr = NameLookup::representative(x)
        for var i: usize = 0; i < eps.size() && k < args.size(); ++i {
            if eps[i] != &null {
                d->bind(xr, eps[i]->index, args[k])
            }

            k += 1
        }
    }

    var        gps = decl_generic_params(f)
    var unsafe *pr = NameLookup::representative(f)
    for var i: usize = 0; i < gps.size() && k < args.size(); ++i {
        var unsafe *gp = gps[i]
        if gp == &null {
            k += 1
            continue
        }

        if gp->is_pack {
            d->open_pack(pr, gp->index)
            while k < args.size() {
                d->push_pack(pr, gp->index, args[k])
                k += 1
            }

            break
        }

        d->bind(pr, gp->index, args[k])
        k += 1
    }
}

/// Bind what \p f's set may name, for the call \p c through receiver \p recv
/// (either may be null): false when a requirement's declaring interface
/// is not found (no bound, no qualifier declares it).
pub fn panic_bind_call(tu:   unsafe *TypeUtil,
                       d:    unsafe *Deduction,
                       f:    unsafe *Declarations::FunctionDecl,
                       c:    unsafe *CallExpr,
                       recv: unsafe *Type) -> bool {
    var unsafe *dc = f->semantic_dc
    var unsafe *owner = if (dc != &null
                            && dc->owner_decl() != &null) => (NameLookup::representative(
                            dc->owner_decl(),
                        ))
                        else => &null
    if owner != &null && isa<Declarations::InterfaceDecl>(owner) {
        // A requirement means its declared set at the interface's arguments
        // the call goes through (Compiler/Spec/Generics.md#substitution): a written qualifier, or the
        // receiver's first bound that declares it.
        var di: unsafe *Type = &null
        if c != &null && c->witness_iface != &null {
            di = d->declaring_instance(f, c->witness_iface)
        }

        if di == &null && recv != &null {
            var bs = Substitution(tu->sc).bound_ifaces(recv)
            for var i: usize = 0; i < bs.size() && di == &null; ++i {
                di = d->declaring_instance(f, bs[i])
            }

            // A concrete receiver conforming to a generic interface is the
            // row's instance: the bound list of a concrete type is empty.
        }

        if di != &null {
            d->bind_from_record(di)
        } else if decl_generic_params(owner).size() > 0 {
            return false
        }

        panic_bind_args(tu, d, f, c)
        panic_bind_self(tu, d, f)
        return true
    }

    if owner != &null && decl_generic_params(owner).size() > 0 {
        var unsafe *r = panic_base_at(tu, panic_recv_value(tu, recv), owner, 0)
        if r != &null {
            d->bind_from_record(r)
        }

        panic_bind_self(tu, d, owner)
    }

    var unsafe *x = decl_extension_of(unsafe (f as unsafe *Decl))
    panic_bind_args(tu, d, f, c)
    if x != &null {
        panic_bind_self(tu, d, x)
    }

    panic_bind_self(tu, d, f)
    return true
}

/// \p f's set as the call \p c (through receiver \p recv) sees it: \p f's
/// final set with every type parameter it names read at the call's
/// arguments. A concrete set is \p f's own. Unbound when a parameter
/// it names is not bound here.
pub fn panic_call_set(tu:   unsafe *TypeUtil,
                      f:    unsafe *Declarations::FunctionDecl,
                      c:    unsafe *CallExpr,
                      recv: unsafe *Type,
                      out:  unsafe *cxx::std::vector<unsafe *Type>) -> PanicKnown {
    var raw = cxx::std::vector<unsafe *Type>()
    var k   = panic_set_of_fn(tu, f, unsafe &raw)
    if k != PanicKnown::Set {
        return k
    }

    var dep = false
    for var i: usize = 0; i < raw.size(); ++i {
        if panic_dep(raw[i]) {
            dep = true
        }
    }

    if !dep {
        for var i: usize = 0; i < raw.size(); ++i {
            pset_add(tu, out, raw[i])
        }

        return PanicKnown::Set
    }

    var d = Deduction(tu->sc, &null)
    if !panic_bind_call(tu, unsafe &d, f, c, recv) {
        return PanicKnown::Unbound
    }

    for var i: usize = 0; i < raw.size(); ++i {
        var unsafe *s = d.substitute(raw[i])
        if s == &null {
            return PanicKnown::Unbound
        }

        pset_add(tu, out, s)
    }

    return PanicKnown::Set
}

/// \p t read through \p f's call \p c (panic_call_set's bindings): a
/// callee's dependent panic result as this call receives it, or null when
/// a parameter it names is not bound here.
pub fn panic_call_type(tu:   unsafe *TypeUtil,
                       f:    unsafe *Declarations::FunctionDecl,
                       c:    unsafe *CallExpr,
                       recv: unsafe *Type,
                       t:    unsafe *Type) -> unsafe *Type {
    if t == &null || !panic_dep(t) {
        return t
    }

    var d = Deduction(tu->sc, &null)
    if !panic_bind_call(tu, unsafe &d, f, c, recv) {
        return &null
    }

    return d.substitute(t)
}

/// How deeply \p t nests types (a record's arguments, a pointee): the
/// solve's guard against a recursion at ever-larger arguments.
pub fn panic_type_depth(t: unsafe *Type, budget: u32) -> u32 {
    if t == &null || budget == 0 {
        return 0
    }

    var unsafe *c = canon_unqual(t)
    if c == &null {
        return 0
    }

    if isa<PointerType>(c) {
        return 1 + panic_type_depth(cast<PointerType>(c)->pointee, budget - 1)
    }

    if isa<NullableType>(c) {
        return 1 + panic_type_depth(cast<NullableType>(c)->inner, budget - 1)
    }

    if isa<RecordType>(c) {
        var unsafe *r     = cast<RecordType>(c)
        var        m: u32 = 0
        for var i: usize = 0; i < r->args.size(); ++i {
            var x = panic_type_depth(r->args[i], budget - 1)
            if x > m {
                m = x
            }
        }

        return 1 + m
    }

    return 1
}

/// How a parameter reaches C++, for matching an override against the method
/// it overrides: C++ compares the declared parameter types (top-level cv
/// dropped), so a Kairo `x: D` (by value; ParamPassInference leaves an
/// override alone) does not override a C++ `const D&` (SI8), while a Kairo
/// `const x: D` (CXXSpell::_param_type: `const D&`) does. 0 by value, 1
/// `T&`, 2 `T&&`; \p inner_const is the referee's const.
pub fn override_param_shape(p:           unsafe *Declarations::ParamDecl,
                            t:           unsafe *Type,
                            inner_const: unsafe *bool) -> u8 {
    *inner_const = false
    var unsafe *c = canon_unqual(t)
    if c != &null && isa<CXXLValueRefType>(c) {
        var unsafe *r = cast<CXXLValueRefType>(c)->referee
        *inner_const = r != &null
            && (canon_has_const(r) || r->canonical != &null && canon_has_const(r->canonical))
        return 1
    }

    if c != &null && isa<CXXRValueRefType>(c) {
        return 2
    }

    if p->mode == ParamMode::Inout {
        *inner_const = p->is_const
        return 1
    }

    if p->mode == ParamMode::Move {
        return 2
    }

    if p->is_const
        && c != &null
        && (c->kind == TypeKind::RecordType || c->kind == TypeKind::GenericParamType) {
        *inner_const = true
        return 1
    }

    return 0
}

/// The type a parameter's C++ type is about: the referee of a C++ reference,
/// else the parameter's own type, unqualified either way.
pub fn override_param_core(t: unsafe *Type) -> unsafe *Type {
    var unsafe *c = canon_unqual(t)
    if c != &null && isa<CXXLValueRefType>(c) {
        return canon_unqual(cast<CXXLValueRefType>(c)->referee)
    }

    if c != &null && isa<CXXRValueRefType>(c) {
        return canon_unqual(cast<CXXRValueRefType>(c)->referee)
    }

    return c
}

/// \p x (the override's) and \p y (the base's, typed \p yt after the base's
/// arguments) are the same C++ parameter type.
pub fn override_param_same(x:  unsafe *Declarations::ParamDecl,
                           y:  unsafe *Declarations::ParamDecl,
                           yt: unsafe *Type) -> bool {
    var xc = false
    var yc = false
    var xs = override_param_shape(x, x->type_->canonical, unsafe &xc)
    var ys = override_param_shape(y, yt, unsafe &yc)
    if xs != ys || xc != yc {
        return false
    }

    var unsafe *a = override_param_core(x->type_->canonical)
    var unsafe *b = override_param_core(yt)
    return a != &null && a == b
}

/// \p loose: name and arity only, the parameter types unread -- the base
/// method an `override` was meant for when no parameter list matches (SI8).
pub fn overridden_at(tu:       unsafe *TypeUtil,
                     cd:       unsafe *Declarations::ClassDecl,
                     m:        unsafe *Declarations::FunctionDecl,
                     out_base: unsafe * unsafe *Type,
                     loose:    bool) -> unsafe *Declarations::FunctionDecl {
    // An operator has no name to spell (FunctionDecl::name): it is
    // matched by its symbol.
    var nm = if (m->is_operator) => (OperatorFacts::symbol(m))
             else => tu->decl_name(unsafe (m as unsafe *Decl))
    var seen = cxx::std::vector<unsafe *Decl>()
    var todo = cxx::std::vector<unsafe *Type>()
    for var i: usize = 0; i < cd->derives_list.size(); ++i {
        var unsafe *e = cd->derives_list.get(i)
        if e == &null || e->base == &null || e->base->canonical == &null {
            continue
        }

        todo.push_back(canon_unqual(e->base->canonical))
    }

    var k: usize = 0
    while k < todo.size() {
        var unsafe *bt = todo[k]
        k += 1
        var unsafe *bd0 = tu->record_decl(bt)
        if bd0 == &null {
            continue
        }

        var unsafe *d  = NameLookup::representative(tu->pattern_of(bd0))
        var        dup = false
        for var i: usize = 0; i < seen.size(); ++i {
            if seen[i] == d {
                dup = true
                break
            }
        }

        if dup {
            continue
        }

        seen.push_back(d)
        var unsafe *bc = dyn_cast<Declarations::ClassDecl>(d)
        if bc == &null {
            continue
        }

        var sub     = Substitution(tu->sc)
        var generic = decl_generic_params(d).size() > 0
        if generic {
            sub.bind_from_record(bt)
        }

        for var i: usize = 0; i < bc->methods.size(); ++i {
            var unsafe *b = bc->methods[i]
            if b == &null
                || b->abi != Declarations::AbiKind::Virtual
                    && b->abi != Declarations::AbiKind::Override {
                continue
            }

            if b->is_operator != m->is_operator {
                continue
            }

            var bn = if (b->is_operator) => (OperatorFacts::symbol(b))
                     else => tu->decl_name(unsafe (b as unsafe *Decl))
            if bn != nm {
                continue
            }

            if b->params.size() != m->params.size() {
                continue
            }

            var same = true
            for var p: usize = 0; !loose && p < m->params.size(); ++p {
                var unsafe *x = m->params[p]
                var unsafe *y = b->params[p]
                if x == &null || y == &null {
                    same = false
                    break
                }

                if x->is_self || y->is_self {
                    continue
                }

                if x->type_ == &null || y->type_ == &null || y->type_->canonical == &null {
                    same = false
                    break
                }

                var unsafe *yt = y->type_->canonical
                if generic && panic_dep(yt) {
                    var unsafe *ys = sub.substitute(yt)
                    if ys != &null {
                        yt = ys
                    }
                }

                if !override_param_same(x, y, yt) {
                    same = false
                    break
                }
            }

            if same {
                *out_base = bt
                return b
            }
        }

        for var i: usize = 0; i < bc->derives_list.size(); ++i {
            var unsafe *e = bc->derives_list.get(i)
            if e == &null || e->base == &null || e->base->canonical == &null {
                continue
            }

            var unsafe *nb = canon_unqual(e->base->canonical)
            if generic && panic_dep(nb) {
                var unsafe *x = sub.substitute(nb)
                if x != &null {
                    nb = canon_unqual(x)
                }
            }

            todo.push_back(nb)
        }
    }

    return &null
}

/// panic_overridden, and the base record it was found in, \p out_base, as
/// \p cd derives it (`B<i32>` for `class D derives B<i32>`): a generic
/// base's method is read through it (its parameters, its panic set).
/// A generic base is walked as its pattern (an instance shell holds no
/// methods), each hop's bases read through the hop's arguments.
pub fn panic_overridden_at(tu:       unsafe *TypeUtil,
                           cd:       unsafe *Declarations::ClassDecl,
                           m:        unsafe *Declarations::FunctionDecl,
                           out_base: unsafe * unsafe *Type) -> unsafe *Declarations::FunctionDecl {
    return overridden_at(tu, cd, m, out_base, false)
}

/// The method \p m overrides: the nearest base's virtual or override
/// method of its name, arity and parameter types.
pub fn panic_overridden(tu: unsafe *TypeUtil,
                        cd: unsafe *Declarations::ClassDecl,
                        m:  unsafe *Declarations::FunctionDecl) -> unsafe *Declarations::FunctionDecl {
    var bt: unsafe *Type = &null
    return panic_overridden_at(tu, cd, m, unsafe &bt)
}

/// \p sup's final set read through \p at (a base record `B<i32>`, an
/// interface instance `Src<IOError>`): what a subset rule holds an
/// override or a conformer to. \p at null, or a concrete set: the
/// set as it is. Unknown when a parameter it names is not bound by \p at.
pub fn panic_set_through(tu:  unsafe *TypeUtil,
                         sup: unsafe *Declarations::FunctionDecl,
                         at:  unsafe *Type,
                         out: unsafe *cxx::std::vector<unsafe *Type>) -> PanicKnown {
    var raw = cxx::std::vector<unsafe *Type>()
    var k   = panic_set_of_fn(tu, sup, unsafe &raw)
    if k != PanicKnown::Set {
        return k
    }

    var sub = Substitution(tu->sc)
    if at != &null {
        sub.bind_from_record(at)
    }

    for var i: usize = 0; i < raw.size(); ++i {
        var unsafe *t = raw[i]
        if panic_dep(t) && at != &null {
            var unsafe *x = sub.substitute(t)
            if x == &null {
                return PanicKnown::Unknown
            }

            t = x
        }

        pset_add(tu, out, t)
    }

    return PanicKnown::Set
}

/// Write \p s as the final set of \p f's whole redeclaration chain.
pub fn panic_store_fn(ctx: unsafe *ASTContext,
                      f:   unsafe *Declarations::FunctionDecl,
                      s:   unsafe *cxx::std::vector<unsafe *Type>,
                      st:  Declarations::PanicSetState) {
    if f == &null {
        return
    }

    // A `where` member's chain links its siblings, each its own body.
    if f->where_lead != &null {
        f->panic_eff.from_vec(s, ctx)
        f->panic_state = st
        return
    }

    var unsafe *cur = f
    for var guard: u32 = 0; guard < 4096; ++guard {
        cur->panic_eff.from_vec(s, ctx)
        cur->panic_state = st
        cur              = cur->next_in_chain()
        if cur == f || cur == &null {
            break
        }
    }
}

/// The set a `fn` value of type \p t_in panics with: the effect is part of
/// the `fn` type's canonical (CanonicalTypeStore::func), so the value's
/// type says it. A bare `panic` with no set is a closure or function value
/// whose set was never declared, which PanicEffectChecking reports where
/// it is written: unknown here.
pub fn panic_set_of_fn_type(tu:         *TypeUtil,
                            t_in:       unsafe *Type,
                            @inout out: cxx::std::vector<unsafe *Type>) -> PanicKnown {
    if t_in == &null {
        return PanicKnown::No
    }

    var unsafe *t = canon_unqual(tu->strip_nullable(canon_unqual(t_in)))
    if t == &null || !isa<FunctionPointerType>(t) {
        return PanicKnown::No
    }

    var unsafe *f = cast<FunctionPointerType>(t)
    if !f->canon_panics {
        return PanicKnown::No
    }

    if f->panic_set.size() == 0 {
        return PanicKnown::Unknown
    }

    for var i: usize = 0; i < f->panic_set.size(); ++i {
        out.push_back(f->panic_set[i])
    }

    return PanicKnown::Set
}

/// # the walk over one body

/// One site that may panic: a `panic` statement, or a call (any form X
/// resolved to a function) whose callee's set is not empty.
pub class PanicSite {
    pub var range:  SourceRange
    pub var callee: unsafe *Decl                   = &null ///< the FunctionDecl called; null for a `panic`.
    pub var raise:  unsafe *PanicStmt              = &null ///< the `panic` statement; null for a call.
    pub var all:    cxx::std::vector<unsafe *Type> ///< everything it may panic with.
    pub var left:   cxx::std::vector<unsafe *Type> ///< what no enclosing `try` discharges.
    /// The operator node the call is written as (`a + b`, `-a`, `a[i]`,
    /// `a as T`), or null; PanicLowering lowers it, and PanicEffectChecking
    /// reports the forms it cannot.
    pub var op_node: unsafe *Expr = &null
    /// The call of `op in` a `for` loop makes over a record.
    pub var via_for: bool = false
    fn PanicSite(self) { }
}

/// One `try`, as the walk saw it: what reached it from its body, and the
/// arms. `node` is the TryCatchStmt or TryCatchExpr.
pub class PanicTry {
    pub var stmt:  unsafe *TryCatchStmt           = &null
    pub var expr:  unsafe *TryCatchExpr           = &null
    pub var reach: cxx::std::vector<unsafe *Type> ///< the body's set (§3.1).
    pub var types: cxx::std::vector<unsafe *Type> ///< each typed arm's filter, canonical; null for an unresolved or bare one.
    pub var bare:  bool                           = false ///< it has a bare `catch`.
    fn PanicTry(self) { }
}

/// The walk over ONE body (a function's, a closure's, an initializer's):
/// nested functions and closures are their own bodies and are not entered.
pub class PanicWalk derives RecursiveASTVisitor<PanicWalk> {
    pub var sc: unsafe *SemaContext
    pub var tu: TypeUtil

    /// Every site, in walk order. Only kept when `keep_sites`.
    pub var sites:      cxx::std::vector<PanicSite>
    pub var keep_sites: bool                        = false
    /// What leaves the body: the union of every site's `left`.
    pub var escape: cxx::std::vector<unsafe *Type>
    /// Every `try` met, in walk order (a nested one after its parent).
    pub var tries: cxx::std::vector<PanicTry>
    /// Calls whose callee's set names a type parameter they do not bind
    /// (PanicKnown::Unbound), and the callee: they add nothing.
    pub var unbound_at: cxx::std::vector<SourceRange>
    pub var unbound_fn: cxx::std::vector<unsafe *Declarations::FunctionDecl>

    /// The `try`s around the walk, innermost last: indices into `tries`.
    priv var _open: cxx::std::vector<usize>
    /// The catch arm being walked, innermost last: its binding's decl, and
    /// the `try` it belongs to. A `panic e` of a bare arm's binding re-panics
    /// whatever that arm caught.
    priv var _arm_decl: cxx::std::vector<unsafe *Decl>
    priv var _arm_try:  cxx::std::vector<usize>
    priv var _arm_bare: cxx::std::vector<u8>
    priv var _depth:    u32                            = 0
    /// What the call being recorded is written as (PanicSite::op_node,
    /// via_for); set around one _call.
    priv var _op_node: unsafe *Expr = &null
    priv var _via_for: bool         = false

    fn PanicWalk(self, sc: unsafe *SemaContext) {
        self.sc = sc
        self.tu = TypeUtil(sc)
    }

    /// ## entry points

    fn walk_fn(self, f: unsafe *Declarations::FunctionDecl) {
        if f == &null {
            return
        }

        if f->body_block != &null {
            self._root_stmt(f->body_block)
        }

        if f->body_expr != &null {
            self._root_expr(f->body_expr)
        }
    }

    fn walk_closure(self, c: unsafe *ClosureExpr) {
        if c == &null {
            return
        }

        if c->body_block != &null {
            self._root_stmt(c->body_block)
        }

        if c->body_expr != &null {
            self._root_expr(c->body_expr)
        }
    }

    fn walk_expr(self, e: unsafe *Expr) {
        if e != &null {
            self._root_expr(e)
        }
    }

    fn walk_stmt(self, s: unsafe *Stmt) {
        if s != &null {
            self._root_stmt(s)
        }
    }

    priv fn _root_stmt(self, s: unsafe *Stmt) {
        self._depth += 1
        self.dyn()->dispatch_stmt(s)
        self._depth -= 1
    }

    priv fn _root_expr(self, e: unsafe *Expr) {
        self._depth += 1
        self.dyn()->dispatch_expr(e)
        self._depth -= 1
    }

    /// ## nested bodies are their own

    fn traverse_function_decl(self, n: *Declarations::FunctionDecl) -> *Declarations::FunctionDecl {
        return n
    }

    fn traverse_closure_expr(self, n: *ClosureExpr) -> *ClosureExpr {
        return n
    }

    fn traverse_class_decl(self, n: *Declarations::ClassDecl) -> *Declarations::ClassDecl {
        return n
    }

    fn traverse_struct_decl(self, n: *Declarations::StructDecl) -> *Declarations::StructDecl {
        return n
    }

    fn traverse_enum_decl(self, n: *Declarations::EnumDecl) -> *Declarations::EnumDecl {
        return n
    }

    fn traverse_union_decl(self, n: *Declarations::UnionDecl) -> *Declarations::UnionDecl {
        return n
    }

    fn traverse_interface_decl(self,
                               n: *Declarations::InterfaceDecl) -> *Declarations::InterfaceDecl {
        return n
    }

    fn traverse_extension_decl(self,
                               n: *Declarations::ExtensionDecl) -> *Declarations::ExtensionDecl {
        return n
    }

    /// ## sites

    fn visit_panic_stmt(self, n: unsafe *PanicStmt) -> bool {
        if n->payload == &null {
            return true
        }

        var s = cxx::std::vector<unsafe *Type>()
        // `panic e` of a bare arm's binding re-panics what that arm caught:
        // everything its `try` left after the typed arms before it.
        var rp = self._bare_repanic(n->payload)
        if rp >= 0 {
            var *t = &self.tries[rp as usize]
            for var i: usize = 0; i < t->reach.size(); ++i {
                var unsafe *x = t->reach[i]
                if !pset_has(unsafe &t->types, x) {
                    s.push_back(x)
                }
            }
        } else {
            var unsafe *pt = n->payload->type_
            if pt == &null || n->payload->is_poisoned() {
                return true
            }

            var unsafe *c = canon_unqual(pt)
            if c == &null || self.tu.is_never(c) {
                return true
            }

            // A dependent type is an element like any other: a generic
            // body's set names its parameters, and C++ orders it at
            // each instance.
            s.push_back(c)
        }

        self._site(n->range, &null, n, unsafe &s)
        return true
    }

    fn visit_call_expr(self, n: unsafe *CallExpr) -> bool {
        if n->is_poisoned() {
            return true
        }

        var unsafe *f = self._callee_fn(n)
        if f != &null {
            self._call(n->range, f, n, panic_call_receiver(unsafe &self.tu, n, f))
            return true
        }

        // Through a `fn` value.
        var unsafe *ce = self.tu.strip_parens(n->callee)
        if ce == &null || ce->type_ == &null {
            return true
        }

        var s = cxx::std::vector<unsafe *Type>()
        if panic_set_of_fn_type(&self.tu, ce->type_, &s) == PanicKnown::Set {
            self._site(n->range, &null, &null, unsafe &s)
        }

        return true
    }

    fn visit_unary_operator_expr(self, n: *UnaryOperatorExpr) -> bool {
        self._op(unsafe (n as unsafe *Expr), n->resolved_op, self._type_of(n->operand))
        return true
    }

    fn visit_binary_operator_expr(self, n: *BinaryOperatorExpr) -> bool {
        self._op(unsafe (n as unsafe *Expr), n->resolved_op, self._type_of(n->lhs))
        return true
    }

    fn visit_assign_operator_expr(self, n: *AssignOperatorExpr) -> bool {
        self._op(unsafe (n as unsafe *Expr), n->resolved_op, self._type_of(n->lhs))
        return true
    }

    fn visit_subscript_expr(self, n: *SubscriptExpr) -> bool {
        self._op(unsafe (n as unsafe *Expr), n->resolved_op, self._type_of(n->base))
        return true
    }

    fn visit_type_cast_expr(self, n: *TypeCastExpr) -> bool {
        self._op(unsafe (n as unsafe *Expr), n->resolved_op, self._type_of(n->operand))
        return true
    }

    /// `for x in r` over a record's `op in`: the operator is called.
    fn visit_ranged_for_stmt(self, n: *RangedForStmt) -> bool {
        if n->iter_op != &null && isa<Declarations::FunctionDecl>(n->iter_op) {
            var r = if (n->iterable != &null) => (n->iterable->range) else => n->range
            self._via_for = true
            self._call(
                r,
                cast<Declarations::FunctionDecl>(n->iter_op),
                &null,
                self._type_of(n->iterable),
            )

            self._via_for = false
        }

        return true
    }

    priv fn _type_of(self, e: unsafe *Expr) -> unsafe *Type {
        if e == &null {
            return &null
        }

        return panic_recv_value(unsafe &self.tu, e->type_)
    }

    priv fn _op(self, n: unsafe *Expr, d: unsafe *Decl, recv: unsafe *Type) {
        if d == &null || !isa<Declarations::FunctionDecl>(d) {
            return
        }

        self._op_node = n
        self._call(n->range, cast<Declarations::FunctionDecl>(d), &null, recv)
        self._op_node = &null
    }

    /// One call of \p f: its set as this call reads it. A set naming
    /// a parameter the call does not bind adds nothing and is kept for
    /// PanicEffectChecking to report.
    priv fn _call(self,
                  at:   SourceRange,
                  f:    unsafe *Declarations::FunctionDecl,
                  c:    unsafe *CallExpr,
                  recv: unsafe *Type) {
        var s = cxx::std::vector<unsafe *Type>()
        var k = panic_call_set(unsafe &self.tu, f, c, recv, unsafe &s)
        if k == PanicKnown::Unbound {
            self.unbound_at.push_back(at)
            self.unbound_fn.push_back(f)
            return
        }

        if k != PanicKnown::Set {
            return
        }

        self._site(at, unsafe (f as unsafe *Decl), &null, unsafe &s)
    }

    /// The function a call selected, or null (CallLowering's rule).
    priv fn _callee_fn(self, c: unsafe *CallExpr) -> unsafe *Declarations::FunctionDecl {
        if c->ctor_decl != &null && isa<Declarations::FunctionDecl>(c->ctor_decl) {
            return cast<Declarations::FunctionDecl>(c->ctor_decl)
        }

        var unsafe *e = self.tu.strip_parens(c->callee)
        if e == &null {
            return &null
        }

        var d: unsafe *Decl = &null
        if isa<NamedIdentExpr>(e) {
            d = cast<NamedIdentExpr>(e)->resolved_decl
        } else if isa<ChainExpr>(e) {
            var unsafe *ch = cast<ChainExpr>(e)
            if ch->steps.size() > 0 {
                var unsafe *st = ch->steps.get(ch->steps.size() - 1)
                d = st->resolved_decl
                if d == &null && st->name != &null {
                    d = st->name->resolved_decl
                }
            }
        }

        return dyn_cast<Declarations::FunctionDecl>(d)
    }

    /// Route one site's set through the open `try`s, innermost first: each
    /// sees what is left, keeps it as reached, and discharges its arms.
    priv fn _site(self,
                  at:     SourceRange,
                  callee: unsafe *Decl,
                  raise:  unsafe *PanicStmt,
                  s:      unsafe *cxx::std::vector<unsafe *Type>) {
        if s->size() == 0 {
            return
        }

        var left = cxx::std::vector<unsafe *Type>()
        for var i: usize = 0; i < s->size(); ++i {
            pset_add(unsafe &self.tu, unsafe &left, (*s)[i])
        }

        var all = left
        var k   = self._open.size()
        while k > 0 && left.size() > 0 {
            k -= 1
            var *t   = &self.tries[self._open[k]]
            var next = cxx::std::vector<unsafe *Type>()
            for var i: usize = 0; i < left.size(); ++i {
                pset_add(unsafe &self.tu, unsafe &t->reach, left[i])
                if t->bare {
                    continue
                }

                if pset_has(unsafe &t->types, left[i]) {
                    continue
                }

                next.push_back(left[i])
            }

            left = next
        }

        for var i: usize = 0; i < left.size(); ++i {
            pset_add(unsafe &self.tu, unsafe &self.escape, left[i])
        }

        if self.keep_sites {
            var ps = PanicSite()
            ps.range  = at
            ps.callee = callee
            ps.raise  = raise
            ps.all    = all
            ps.left   = left
            if callee != &null {
                ps.op_node = self._op_node
                ps.via_for = self._via_for
            }

            self.sites.push_back(ps)
        }
    }

    /// The `try` index of the bare arm whose binding \p e names, or -1.
    priv fn _bare_repanic(self, e_in: unsafe *Expr) -> i64 {
        var unsafe *e = self.tu.strip_parens(e_in)
        if e == &null || !isa<NamedIdentExpr>(e) {
            return -1
        }

        var unsafe *d = cast<NamedIdentExpr>(e)->resolved_decl
        if d == &null {
            return -1
        }

        var k = self._arm_decl.size()
        while k > 0 {
            k -= 1
            if self._arm_decl[k] == d {
                if self._arm_bare[k] == 0 {
                    return -1
                }

                return self._arm_try[k] as i64
            }
        }

        return -1
    }

    /// ## try / catch

    /// The body under the `try`; each arm with the `try` closed, so a panic
    /// in an arm goes to the enclosing one, never to a sibling arm.
    fn traverse_try_catch_stmt(self, n: unsafe *TryCatchStmt) -> unsafe *TryCatchStmt {
        if n == &null {
            return n
        }

        var t = PanicTry()
        t.stmt = n
        for var i: usize = 0; i < n->arms.size(); ++i {
            var unsafe *arm = n->arms.get(i)
            if arm->filter == &null {
                t.bare = true
                continue
            }

            var unsafe *c = arm->filter->canonical
            if c != &null {
                pset_add(unsafe &self.tu, unsafe &t.types, c)
            }
        }

        var idx = self.tries.size()
        self.tries.push_back(t)
        self._open.push_back(idx)
        if n->try_body != &null {
            self.dyn()->dispatch_stmt(n->try_body)
        }

        self._open.pop_back()
        for var i: usize = 0; i < n->arms.size(); ++i {
            var unsafe *arm = n->arms.get(i)
            self._arm_decl.push_back(arm->decl)
            self._arm_try.push_back(idx)
            self._arm_bare.push_back((arm->filter == &null) as u8)
            if arm->body != &null {
                self.dyn()->dispatch_stmt(arm->body)
            }

            self._arm_decl.pop_back()
            self._arm_try.pop_back()
            self._arm_bare.pop_back()
        }

        return n
    }

    fn traverse_try_catch_expr(self, n: unsafe *TryCatchExpr) -> unsafe *TryCatchExpr {
        if n == &null {
            return n
        }

        var t = PanicTry()
        t.expr = n
        for var i: usize = 0; i < n->catch_arms.size(); ++i {
            var unsafe *arm = n->catch_arms.get(i)
            if arm->filter == &null {
                t.bare = true
                continue
            }

            var unsafe *c = arm->filter->canonical
            if c != &null {
                pset_add(unsafe &self.tu, unsafe &t.types, c)
            }
        }

        var idx = self.tries.size()
        self.tries.push_back(t)
        self._open.push_back(idx)
        if n->try_expr != &null {
            self.dyn()->dispatch_expr(n->try_expr)
        }

        self._open.pop_back()
        for var i: usize = 0; i < n->catch_arms.size(); ++i {
            var unsafe *arm = n->catch_arms.get(i)
            self._arm_decl.push_back(arm->decl)
            self._arm_try.push_back(idx)
            self._arm_bare.push_back((arm->filter == &null) as u8)
            if arm->body != &null {
                self.dyn()->dispatch_expr(arm->body)
            }

            self._arm_decl.pop_back()
            self._arm_try.pop_back()
            self._arm_bare.pop_back()
        }

        return n
    }
}

/// # the solve

/// How deeply a type in an inferred set may nest before the set is called
/// Diverged (EffectTable::solve). Far past anything a program names: only a
/// recursion that builds a deeper type each round gets there.
pub
const PANIC_SET_DEPTH_MAX: u32 = 48

/// One body the solve infers: a bare-`panic` function or closure, and the
/// context of the TU it is in.
pub class EffectEntry {
    pub var fd: unsafe *Declarations::FunctionDecl = &null
    pub var ce: unsafe *ClosureExpr                = &null
    pub var sc: unsafe *SemaContext                = &null
    fn EffectEntry(self) { }
}

/// A bare-`panic` function whose set can be inferred: it has a body, and
/// it is not a generator, `async` or under a `<T: type>` parameter (each
/// gated at its declaration by PanicEffectChecking). A generic one is
/// inferred like any other, at its definition. A `where` member is its own body;
/// its group's set is the union (panic_set_of_fn).
pub fn panic_inferable_fn(f: unsafe *Declarations::FunctionDecl) -> bool {
    if f == &null || f->is_poisoned() {
        return false
    }

    if !f->is_panic() || f->has_panic_set() {
        return false
    }

    if f->body_block == &null && f->body_expr == &null {
        return false
    }

    if f->is_generator || f->is_async() {
        return false
    }

    if panic_in_duck(unsafe (f as unsafe *Decl)) {
        return false
    }

    return true
}

pub fn panic_inferable_closure(c: unsafe *ClosureExpr) -> bool {
    if c == &null || c->is_poisoned() {
        return false
    }

    var panics = ((c->modifiers as u16) & (Declarations::FnModifier::IsPanic as u16)) != 0
    if !panics || c->panic_set.size() > 0 {
        return false
    }

    if c->generic_params.size() > 0 {
        return false
    }

    var asy = ((c->modifiers as u16) & (Declarations::FnModifier::IsAsync as u16)) != 0
    return !asy
}

/// Finds every inferable body in one TU.
pub class EffectCollect derives RecursiveASTVisitor<EffectCollect> {
    pub var  sc:    unsafe *SemaContext
    pub var  out:   unsafe *cxx::std::vector<EffectEntry>
    priv var _seen: llvm::DenseSet<u64>

    fn EffectCollect(self, sc: unsafe *SemaContext, out: unsafe *cxx::std::vector<EffectEntry>) {
        self.sc  = sc
        self.out = out
    }

    fn run(self) {
        var unsafe *tu = self.sc->tu
        if tu == &null || tu->program == &null {
            return
        }

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
    }

    fn visit_function_decl(self, n: unsafe *Declarations::FunctionDecl) -> bool {
        if !panic_inferable_fn(n) {
            return true
        }

        var key = (n as usize as u64)
        if self._seen.contains(key) {
            return true
        }

        self._seen.insert(key)
        var e = EffectEntry()
        e.fd = n
        e.sc = self.sc
        self.out->push_back(e)
        return true
    }

    fn visit_closure_expr(self, n: unsafe *ClosureExpr) -> bool {
        if !panic_inferable_closure(n) {
            return true
        }

        var key = (n as usize as u64)
        if self._seen.contains(key) {
            return true
        }

        self._seen.insert(key)
        var e = EffectEntry()
        e.ce = n
        e.sc = self.sc
        self.out->push_back(e)
        return true
    }
}

/// The build-wide table: every inferable body of the graph, solved at once.
pub class EffectTable {
    pub var entries: cxx::std::vector<EffectEntry>
    pub var solved:  bool                          = false
    pub var rounds:  u32                           = 0

    fn EffectTable(self) { }

    /// Empty, for the next group of the graph (the driver solves one import
    /// cycle at a time; every set it solved before stays on its decls).
    pub fn reset(self) {
        self.entries.clear()
        self.solved = false
        self.rounds = 0
    }

    /// Register \p sc's TU. Its bodies start from the empty set, Final, so a
    /// query during the solve reads the set as it grows.
    pub fn add_tu(self, sc: unsafe *SemaContext) {
        if sc == &null || sc->tu == &null {
            return
        }

        var from = self.entries.size()
        var col  = EffectCollect(sc, unsafe &self.entries)
        col.run()
        var empty = cxx::std::vector<unsafe *Type>()
        for var i: usize = from; i < self.entries.size(); ++i {
            var e = self.entries[i]
            if e.fd != &null {
                panic_store_fn(sc->ctx, e.fd, unsafe &empty, Declarations::PanicSetState::Final)
            }

            if e.ce != &null {
                e.ce->panic_eff.from_vec(unsafe &empty, sc->ctx)
                e.ce->panic_state = Declarations::PanicSetState::Final
            }
        }
    }

    /// Iterate every entry's walk until no set grows (§2.5).
    pub fn solve(self) {
        var changed = true
        while changed {
            changed = false
            self.rounds += 1
            for var i: usize = 0; i < self.entries.size(); ++i {
                var e   = self.entries[i]
                var w   = PanicWalk(e.sc)
                var cur = cxx::std::vector<unsafe *Type>()
                if e.fd != &null {
                    w.walk_fn(e.fd)
                    for var k: usize = 0; k < e.fd->panic_eff.size(); ++k {
                        cur.push_back(e.fd->panic_eff[k])
                    }
                } else {
                    w.walk_closure(e.ce)
                    for var k: usize = 0; k < e.ce->panic_eff.size(); ++k {
                        cur.push_back(e.ce->panic_eff[k])
                    }
                }

                if e.fd != &null && e.fd->panic_state == Declarations::PanicSetState::Diverged {
                    continue
                }

                var grew = false
                var deep = false
                for var k: usize = 0; k < w.escape.size(); ++k {
                    if pset_add(unsafe &w.tu, unsafe &cur, w.escape[k]) {
                        grew = true
                        if panic_type_depth(
                            w.escape[k],
                            PANIC_SET_DEPTH_MAX + (1 as u32),
                        ) > PANIC_SET_DEPTH_MAX {
                            deep = true
                        }
                    }
                }

                if !grew {
                    continue
                }

                // A recursion at ever-larger type arguments (`f<Box<T>>`
                // inside `f<T>`) adds a deeper type every round and
                // would never stop (§2.5's argument assumes the types are
                // the ones the bodies name). Past the limit the function's
                // set is Diverged: reported at it, read as unknown.
                if deep && e.fd != &null {
                    panic_store_fn(
                        e.sc->ctx,
                        e.fd,
                        unsafe &cur,
                        Declarations::PanicSetState::Diverged,
                    )

                    changed = true
                    continue
                }

                changed = true
                if e.fd != &null {
                    panic_store_fn(e.sc->ctx, e.fd, unsafe &cur, Declarations::PanicSetState::Final)
                } else {
                    e.ce->panic_eff.from_vec(unsafe &cur, e.sc->ctx)
                }
            }
        }

        self.solved = true
    }
}

/// The table \p sc's driver solved, or null.
pub fn effects_of(sc: unsafe *SemaContext) -> unsafe *EffectTable {
    if sc == &null {
        return &null
    }

    return unsafe (sc->effects as unsafe *EffectTable)
}
