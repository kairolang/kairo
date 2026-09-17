/// --- The Kairo Project ----------------- Sema/Type/ArgumentDeduction.k --- ///
///
///   \brief Structural unification of a parameter's canonical against an
///          argument's canonical, binding the generic parameters of ONE owner,
///          and substitution of those bindings back into a type.
///
///   \detail
///     A parameter type like `[T]` canonicalizes to `vector(generic_param(f,
///     0))`; an argument `[i32]` to `vector(i32)`. unify walks the two in
///     lockstep and binds (f, 0) := i32. Every binding must agree; a second
///     binding of the same slot to a different type is a deduction failure,
///     not a conversion opportunity -- there is no "common type" search.
///
///     At the TOP level only, a non-generic mismatch may still succeed through
///     the implicit relation (`fn f(x: i64)` called with an i32) and the
///     unification reports Converted; inside a structure it is exact or
///     nothing (aggregates never convert, lattice §4).
///
///     Deduction is a COMPONENT: one instance per candidate, discarded after
///     ranking. It reads the canonical store and writes nothing to the AST.
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
import Sema::Resolve::NameLookup::*;
import Sema::Type::TypeUtil::*;
import Sema::Type::Conversion::*;
import AST::Context::DeclContext::*;
import AST::Context::InstantiationRegistry::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::TypeKind::*;
import AST::ParamMode::*;

class DeducedBinding {
    pub var owner: *Decl = &null;
    pub var index: u32   = 0;
    pub var ty:    *Type = &null;
    fn DeducedBinding(self) { }
}

class Deduction {
    pub var sc:       *SemaContext;
    pub var conv:     *Conversion;
    pub var tu:       TypeUtil;
    pub var bindings: vec::<DeducedBinding>;

    fn Deduction(self) { self.sc = &null; self.conv = &null; }
    fn Deduction(self, sc: *SemaContext, conv: *Conversion) {
        self.sc   = sc;
        self.conv = conv;
        self.tu   = TypeUtil(sc);
    }

    fn lookup(self, owner: *Decl, index: u32) -> *Type {
        for var i: usize = 0; i < self.bindings.size(); ++i {
            var b = &(self.bindings[i]);
            if (b->owner == owner) && (b->index == index) { return b->ty; }
        }
        return &null;
    }

    /// False on a conflicting rebind.
    fn bind(self, owner: *Decl, index: u32, ty: *Type) -> bool {
        if ty == &null { return false; }
        var prev = self.lookup(owner, index);
        if prev != &null { return prev == ty; }
        var b = DeducedBinding{};
        b.owner = owner; b.index = index; b.ty = ty;
        self.bindings.push_back(b);
        return true;
    }

    /// Seed from an instance: `Foo<i32>` binds Foo's params positionally.
    fn bind_from_record(self, rec: *Type) {
        var d = self.tu.record_decl(rec);
        if d == &null { return; }
        var pat  = NameLookup::representative(self.tu.pattern_of(d));
        var args = self.tu.record_args(rec);
        for var i: usize = 0; i < args.size(); ++i {
            self.bind(pat, static_cast::<u32>(i), args[i]);
        }
    }

    /// Every param of \p owner has a binding.
    fn is_complete(self, owner: *Decl) -> bool {
        var gps = self.tu.generic_params_of(owner);
        for var i: usize = 0; i < gps.size(); ++i {
            var gp = gps[i];
            if gp == &null { continue; }
            if gp->is_pack { continue; }   // packs deduce to "whatever arrived"; see OverloadResolution.
            if self.lookup(owner, gp->index) == &null { return false; }
        }
        return true;
    }

    // === unify ==============================================================

    /// \return the rank of the match, None on failure.
    fn unify(self, param: *Type, arg: *Type, top: bool) -> ImplicitRank {
        if (param == &null) || (arg == &null) { return ImplicitRank::None; }

        // Top-level cv is not deduced from and not deduced into
        // ([temp.deduct.call]/2): by-value `const T` against a const lvalue
        // is T := the unqualified type on both counts. A reference P looks
        // through itself first (below), so `const T&` still sees the const.
        if top && (!isa::<CXXLValueRefType>(param)) && (!isa::<CXXRValueRefType>(param)) {
            param = canon_unqual(param);
            arg   = canon_unqual(arg);
            if param == arg { return ImplicitRank::Exact; }
        }

        if isa::<GenericParamType>(param) {
            var g = cast::<GenericParamType>(param);
            if g->owner == &null { return ImplicitRank::None; }
            return (ImplicitRank::Exact) if (self.bind(g->owner, g->param_index, arg)) else (ImplicitRank::None);
        }

        if !param->is_dependent() {
            // Concrete parameter: the ordinary relation.
            if param == arg { return ImplicitRank::Exact; }
            if !top { return ImplicitRank::None; }
            return self.conv->implicit(arg, param);
        }

        // P = cv T': A must carry every qualifier P does, and T' deduces
        // from A minus them. `const T&` against `const int` is T := int;
        // `const T*` against `const volatile int*` is T := volatile int.
        if isa::<QualifiedType>(param) {
            var pq = cast::<QualifiedType>(param)->quals;
            var aq = canon_quals(arg);
            if (aq & pq) != pq { return ImplicitRank::None; }
            var rest = self.sc->types->qualified(canon_unqual(arg), static_cast::<u8>(aq & (~pq)));
            return self.unify(cast::<QualifiedType>(param)->inner, rest, false);
        }

        // A dependent C++ reference parameter (only imported signatures have
        // one): deduction looks THROUGH it -- [temp.deduct.call]/3, "if P is
        // a reference type, the type referred to by P is used" -- so
        // `push(const T&)` with an i32 deduces T := i32. Binding then ranks
        // as Conversion::_bind_ref does: lvalue refs as the referee's match,
        // rvalue refs never better than Converted. Concrete refs never reach
        // here; the branch above sends them through Conversion.
        if isa::<CXXLValueRefType>(param) || isa::<CXXRValueRefType>(param) {
            var a = arg;
            if isa::<CXXLValueRefType>(a) { a = cast::<CXXLValueRefType>(a)->referee; }
            if isa::<CXXRValueRefType>(a) { a = cast::<CXXRValueRefType>(a)->referee; }
            if isa::<CXXLValueRefType>(param) {
                return self._unify_referee(cast::<CXXLValueRefType>(param)->referee, a);
            }
            var rr = self._unify_referee(cast::<CXXRValueRefType>(param)->referee, a);
            return (ImplicitRank::Converted) if (rr != ImplicitRank::None) else (ImplicitRank::None);
        }

        // Dependent composite: same shape, recurse exact.
        if param->kind != arg->kind {
            // *Derived -> *Base<T>: allow the top-level pointer case through
            // the base's own record when the shapes are both pointers.
            return ImplicitRank::None;
        }

        switch param->kind {
            case TypeKind::PointerType {
                if self.tu.is_unsafe_ptr(param) != self.tu.is_unsafe_ptr(arg) { return ImplicitRank::None; }
                return self._inner(self.unify(cast::<PointerType>(param)->pointee, cast::<PointerType>(arg)->pointee, false));
            } case TypeKind::NullableType {
                return self._inner(self.unify(cast::<NullableType>(param)->inner, cast::<NullableType>(arg)->inner, false));
            } case TypeKind::VectorType {
                return self._inner(self.unify(cast::<VectorType>(param)->element, cast::<VectorType>(arg)->element, false));
            } case TypeKind::SetType {
                return self._inner(self.unify(cast::<SetType>(param)->element, cast::<SetType>(arg)->element, false));
            } case TypeKind::FixedArrayType {
                var pa = cast::<FixedArrayType>(param); var aa = cast::<FixedArrayType>(arg);
                if pa->size_bits != aa->size_bits { return ImplicitRank::None; }
                return self._inner(self.unify(pa->element, aa->element, false));
            } case TypeKind::MapType {
                var pm = cast::<MapType>(param); var am = cast::<MapType>(arg);
                if self.unify(pm->key, am->key, false) == ImplicitRank::None { return ImplicitRank::None; }
                return self._inner(self.unify(pm->value, am->value, false));
            } case TypeKind::TupleType {
                var pt = cast::<TupleType>(param); var at = cast::<TupleType>(arg);
                if pt->elements.size() != at->elements.size() { return ImplicitRank::None; }
                for var i: usize = 0; i < pt->elements.size(); ++i {
                    if self.unify(pt->elements[i], at->elements[i], false) == ImplicitRank::None { return ImplicitRank::None; }
                }
                return ImplicitRank::Exact;
            } case TypeKind::FunctionPointerType {
                var pf = cast::<FunctionPointerType>(param); var af = cast::<FunctionPointerType>(arg);
                if pf->params.size() != af->params.size() { return ImplicitRank::None; }
                for var i: usize = 0; i < pf->params.size(); ++i {
                    if self.unify(pf->params[i], af->params[i], false) == ImplicitRank::None { return ImplicitRank::None; }
                }
                if (pf->return_type == &null) != (af->return_type == &null) { return ImplicitRank::None; }
                if pf->return_type == &null { return ImplicitRank::Exact; }
                return self._inner(self.unify(pf->return_type, af->return_type, false));
            } case TypeKind::RecordType {
                var pr = cast::<RecordType>(param); var ar = cast::<RecordType>(arg);
                // `Foo<T>` against `Foo<i32>`: the arg's decl is an instance of
                // the param's pattern (or the pattern itself for a dependent arg).
                var ppat = NameLookup::representative(self.tu.pattern_of(pr->decl));
                var apat = NameLookup::representative(self.tu.pattern_of(ar->decl));
                if ppat != apat { return ImplicitRank::None; }
                if pr->args.size() != ar->args.size() { return ImplicitRank::None; }
                for var i: usize = 0; i < pr->args.size(); ++i {
                    if self.unify(pr->args[i], ar->args[i], false) == ImplicitRank::None { return ImplicitRank::None; }
                }
                return ImplicitRank::Exact;
            } default { return ImplicitRank::None; }
        }
    }

    /// A reference parameter's referee against the argument's value type
    /// ([temp.deduct.call]/3). The argument's cv is NOT stripped here -- it
    /// is the referee's, not a top-level cv -- so `T&` against a `const i32`
    /// is T := const i32, the only way it binds. The referee's own cv is
    /// matched off first, and binding may ADD it: `const T&` against a
    /// `const i32` or an `i32` is T := i32 either way.
    priv fn _unify_referee(self, referee: *Type, a: *Type) -> ImplicitRank {
        if (referee == &null) || (a == &null) { return ImplicitRank::None; }
        if isa::<QualifiedType>(referee) {
            var pq = cast::<QualifiedType>(referee)->quals;
            var aq = canon_quals(a);
            var rest = self.sc->types->qualified(canon_unqual(a), static_cast::<u8>(aq & (~pq)));
            return self.unify(cast::<QualifiedType>(referee)->inner, rest, false);
        }
        return self.unify(referee, a, false);
    }

    priv fn _inner(self, r: ImplicitRank) -> ImplicitRank {
        return (ImplicitRank::None) if (r == ImplicitRank::None) else (ImplicitRank::Exact);
    }

    // === substitute =========================================================

    /// \p t with every bound generic param replaced. Null when a param is
    /// still unbound or a component is not canonical. A concrete record
    /// result goes through the registry so `Foo<i32>` is the instance decl.
    fn substitute(self, t: *Type) -> *Type {
        if t == &null { return &null; }
        if !t->is_dependent() { return t; }

        switch t->kind {
            case TypeKind::GenericParamType {
                var g = cast::<GenericParamType>(t);
                var b = self.lookup(g->owner, g->param_index);
                return b;   // null = unbound, stays dependent for the caller to notice.
            } case TypeKind::PointerType {
                var p = self.substitute(cast::<PointerType>(t)->pointee);
                if p == &null { return &null; }
                return self.sc->types->pointer(p, cast::<PointerType>(t)->is_unsafe);
            } case TypeKind::NullableType {
                var i = self.substitute(cast::<NullableType>(t)->inner);
                if i == &null { return &null; }
                return self.sc->types->nullable(i);
            } case TypeKind::VectorType {
                var e = self.substitute(cast::<VectorType>(t)->element);
                if e == &null { return &null; }
                // null when the lang item is unbound: a poisoned component,
                // which reads here as no-match, exactly like any other.
                return self.tu.vector_of(e);
            } case TypeKind::SetType {
                var e = self.substitute(cast::<SetType>(t)->element);
                if e == &null { return &null; }
                return self.tu.set_of(e);
            } case TypeKind::MapType {
                var k = self.substitute(cast::<MapType>(t)->key);
                var v = self.substitute(cast::<MapType>(t)->value);
                if (k == &null) || (v == &null) { return &null; }
                return self.tu.map_of(k, v);
            } case TypeKind::FixedArrayType {
                var a = cast::<FixedArrayType>(t);
                var e = self.substitute(a->element);
                if e == &null { return &null; }
                return self.sc->types->array(e, static_cast::<u64>(a->size_bits));
            } case TypeKind::TupleType {
                var tt = cast::<TupleType>(t);
                var elems = vec::<*Type>();
                for var i: usize = 0; i < tt->elements.size(); ++i {
                    var e = self.substitute(tt->elements[i]);
                    if e == &null { return &null; }
                    elems.push_back(e);
                }
                return self.sc->types->tuple(&elems);
            } case TypeKind::FunctionPointerType {
                var f = cast::<FunctionPointerType>(t);
                var ps = vec::<*Type>();
                var ms = vec::<ParamMode>();
                for var i: usize = 0; i < f->params.size(); ++i {
                    var p = self.substitute(f->params[i]);
                    if p == &null { return &null; }
                    ps.push_back(p);
                    ms.push_back(f->modes[i]);      // modes survive substitution unchanged.
                }
                var r: *Type = &null;
                if f->return_type != &null {
                    r = self.substitute(f->return_type);
                    if r == &null { return &null; }
                }
                return self.sc->types->func(&ps, &ms, r);
            } case TypeKind::QualifiedType {
                var q = cast::<QualifiedType>(t);
                var i = self.substitute(q->inner);
                if i == &null { return &null; }
                return self.sc->types->qualified(i, q->quals);
            } case TypeKind::RecordType {
                var r = cast::<RecordType>(t);
                var args = vec::<*Type>();
                var dep  = false;
                for var i: usize = 0; i < r->args.size(); ++i {
                    var a = self.substitute(r->args[i]);
                    if a == &null { return &null; }
                    if a->is_dependent() { dep = true; }
                    args.push_back(a);
                }
                var primary = NameLookup::representative(self.tu.pattern_of(r->decl));
                if dep || (args.size() == 0) { return self.sc->types->record(primary, &args); }
                var e = self.sc->instances->instance_for(primary, &args, self.sc->ctx->fid,
                                                         NameLookup::ctx_of(primary));
                var inst = (e->decl) if (e != &null) else (primary);
                return self.sc->types->record(inst, &args);
            } default { return &null; }
        }
    }

    /// Member type \p mt as seen through receiver \p recv (`Foo<i32>`'s
    /// field `var x: T` reads as i32). Non-dependent members pass through.
    fn member_through(self, recv: *Type, mt: *Type) -> *Type {
        if mt == &null { return &null; }
        if !mt->is_dependent() { return mt; }
        self.bind_from_record(recv);
        var s = self.substitute(mt);
        return (s) if (s != &null) else (mt);
    }

    // === Self through a bound ===============================================

    /// An interface's members are declared against the INTERFACE's own `Self`
    /// -- `fn combine(const self, other: Self) -> Self` canonicalizes to
    /// `record(I)` in both positions. Reached through a bound `T impl I`,
    /// every one of those `record(I)` is really the parameter: the method is
    /// being called on a `T`, so what it takes and returns is a `T`.
    ///
    /// A structural rewrite through the store, and nothing else in \p t
    /// changes. Deliberately NOT folded into substitute(): that one maps
    /// generic params to deduced arguments and is driven by `is_dependent`,
    /// while `record(I)` for a non-generic I is not dependent at all. Two
    /// different substitutions, two functions.
    ///
    /// Only a BARE `record(I)` is the receiver. `I<X>` names a different
    /// entity and its arguments are rewritten in place instead.
    /// \p t -- a parameter or return type of member \p f -- as the call site
    /// sees it, given the value \p receiver it was reached through. THE home
    /// of the Self rule: overload resolution needs it to judge viability
    /// (`fn merge(self, other: Self)` reached through a `T impl Drawable`
    /// takes a T, and ranking the argument against `Drawable` would reject
    /// the call outright) and CallTyping needs it again on the winner, so
    /// neither owns it.
    ///
    /// A no-op unless \p f is declared in an interface: `Self` in a class body
    /// already means that class, and the receiver IS that class.
    fn through_receiver(self, f: *FunctionDecl, receiver: *Type, t: *Type) -> *Type {
        if (t == &null) || (receiver == &null) || (f == &null) { return t; }
        if f->semantic_dc == &null { return t; }
        var home = reinterpret_cast::<*DeclContext>(f->semantic_dc)->owner_decl();
        if (home == &null) || (!isa::<InterfaceDecl>(home)) { return t; }
        return self.replace_self(t, home, receiver);
    }

    fn replace_self(self, t: *Type, iface: *Decl, with: *Type) -> *Type {
        if (t == &null) || (iface == &null) || (with == &null) { return t; }
        var rep = NameLookup::representative(iface);
        switch t->kind {
            case TypeKind::RecordType {
                var r = cast::<RecordType>(t);
                if (NameLookup::representative(self.tu.pattern_of(r->decl)) == rep)
                && (r->args.size() == 0) { return with; }
                var args    = vec::<*Type>();
                var changed = false;
                for var i: usize = 0; i < r->args.size(); ++i {
                    var a = self.replace_self(r->args[i], iface, with);
                    if a != r->args[i] { changed = true; }
                    args.push_back(a);
                }
                if !changed { return t; }
                return self.sc->types->record(r->decl, &args);
            } case TypeKind::PointerType {
                var p = cast::<PointerType>(t);
                var i = self.replace_self(p->pointee, iface, with);
                return (t) if (i == p->pointee) else (self.sc->types->pointer(i, p->is_unsafe));
            } case TypeKind::NullableType {
                var nt = cast::<NullableType>(t);
                var i  = self.replace_self(nt->inner, iface, with);
                return (t) if (i == nt->inner) else (self.sc->types->nullable(i));
            } case TypeKind::VectorType {
                var vt = cast::<VectorType>(t);
                var i  = self.replace_self(vt->element, iface, with);
                return (t) if (i == vt->element) else (self.tu.vector_of(i));
            } case TypeKind::SetType {
                var st = cast::<SetType>(t);
                var i  = self.replace_self(st->element, iface, with);
                return (t) if (i == st->element) else (self.tu.set_of(i));
            } case TypeKind::MapType {
                var mt = cast::<MapType>(t);
                var k  = self.replace_self(mt->key, iface, with);
                var v  = self.replace_self(mt->value, iface, with);
                if (k == mt->key) && (v == mt->value) { return t; }
                return self.tu.map_of(k, v);
            } case TypeKind::TupleType {
                var tt      = cast::<TupleType>(t);
                var elems   = vec::<*Type>();
                var changed = false;
                for var i: usize = 0; i < tt->elements.size(); ++i {
                    var e = self.replace_self(tt->elements[i], iface, with);
                    if e != tt->elements[i] { changed = true; }
                    elems.push_back(e);
                }
                return (t) if (!changed) else (self.sc->types->tuple(&elems));
            } case TypeKind::QualifiedType {
                  var q = cast::<QualifiedType>(t);
                  var i = self.replace_self(q->inner, iface, with);
                  return (t) if (i == q->inner) else (self.sc->types->qualified(i, q->quals));
            } case TypeKind::FunctionPointerType {
                var f       = cast::<FunctionPointerType>(t);
                var ps      = vec::<*Type>();
                var ms      = vec::<ParamMode>();
                var changed = false;
                for var i: usize = 0; i < f->params.size(); ++i {
                    var p = self.replace_self(f->params[i], iface, with);
                    if p != f->params[i] { changed = true; }
                    ps.push_back(p);
                    ms.push_back(f->modes[i]);
                }
                var r: *Type = &null;
                if f->return_type != &null {
                    r = self.replace_self(f->return_type, iface, with);
                    if r != f->return_type { changed = true; }
                }
                return (t) if (!changed) else (self.sc->types->func(&ps, &ms, r));
            } default { return t; }
        }
    }
}