/// --- The Kairo Project ---------------- Sema/Type/ArgumentDeduction.k --- ///
///
///   \brief Structural unification of a parameter's canonical against an
///          argument's canonical, binding the generic parameters of ONE owner.
///          Substituting the bindings back into a type is Substitution's
///          (Sema/Type/Substitution.k), which Deduction derives.
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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "vector"

import AST::DeclFacts::decl_extension_of
import AST::Kind::TypeKind::TypeKind
import AST::Node::Base::{
    Decl,
    Type,
}
import AST::Node::CanonicalNodes::{
    AssocType,
    QualifiedType,
    RecordType,
    canon_quals,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    FunctionDecl,
    InterfaceDecl,
}
import AST::Node::Types::{
    CXXLValueRefType, CXXRValueRefType, FixedArrayType, FunctionPointerType, GenericParamType,
    MapType,          NullableType,     PointerType,    SetType,             TypeExpr,
    VectorType,
}
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::SemaContext
import Sema::Type::Conversion::{
    Conversion,
    ImplicitRank,
}
import Sema::Type::Substitution::Substitution
import Sema::Type::TypeUtil::TypeUtil

/// Unification on top of Substitution: what the bindings are deduced
/// FROM. Substitution (Sema/Type/Substitution.k) owns the bindings and
/// the rewrite; this adds the argument side.
pub class Deduction derives Substitution {
    pub var conv: unsafe *Conversion
    /// Some bindings came from the receiver (bind_from_extension), not from
    /// an argument. OverloadResolution then ranks an argument against its
    /// parameter with them substituted in.
    pub var seeded: bool = false

    fn Deduction(self) {
        self.sc   = &null
        self.conv = &null
    }

    fn Deduction(self, sc: unsafe *SemaContext, conv: unsafe *Conversion) {
        self.sc   = sc
        self.conv = conv
        self.tu   = TypeUtil(sc)
    }

    /// `extend <T> Vec<T>` reached through a `Vec<i64>`: T := i64, before any
    /// argument is ranked. The target is UNIFIED with the receiver, so a
    /// non-identity target (`extend <T> Vec<Box<T>>`) binds what it names and
    /// rejects a receiver it does not match (false). No receiver, or a
    /// dependent one, binds nothing: `Vec::m(v)` deduces from its `self`
    /// argument like any other parameter.
    fn bind_from_extension(self, f: unsafe *FunctionDecl, receiver: unsafe *Type) -> bool {
        var unsafe *ext = decl_extension_of(f)
        if ext == &null || self.tu.generic_params_of(unsafe (ext as unsafe *Decl)).size() == 0 {
            return true
        }

        if receiver == &null || ext->target == &null || ext->target->canonical == &null {
            return true
        }

        var unsafe *r = canon_unqual(receiver)
        if r->is_dependent() || r->is_instantiation_dependent() {
            return true
        }

        if self.unify(canon_unqual(ext->target->canonical), r, false) == ImplicitRank::None {
            return false
        }

        self.seeded = true
        return true
    }

    /// An imported function template's defaulted TYPE parameter that no
    /// argument deduced takes its default, as C++ does ([temp.deduct]/5):
    /// `template <class S, class R = string_view> R sref(const S&)` called
    /// with a string is sref<string, string_view>. Without the binding the
    /// call typed as unknown (the return type stayed dependent) and the
    /// callee reached codegen unbound. In order, so a default naming an
    /// earlier parameter reads its binding; a default still dependent after
    /// that, and every value parameter (`enable_if_t<...> = 0`), stays
    /// clang's to fill (is_complete).
    fn fill_ffi_defaults(self, owner: unsafe *Decl) {
        var gps = self.tu.generic_params_of(owner)
        for var i: usize = 0; i < gps.size(); ++i {
            var unsafe *gp = gps[i]
            if gp == &null || gp->is_pack || gp->is_const_param || !gp->ffi_has_default {
                continue
            }

            if gp->default_type == &null || gp->default_type->canonical == &null {
                continue
            }

            if self.lookup(owner, gp->index) != &null {
                continue
            }

            var unsafe *d = self.substitute(gp->default_type->canonical)
            if d == &null || d->is_dependent() {
                continue
            }

            self.bind(owner, gp->index, d)
        }
    }

    /// Every param of \p owner has a binding.
    fn is_complete(self, owner: unsafe *Decl) -> bool {
        var gps = self.tu.generic_params_of(owner)
        for var i: usize = 0; i < gps.size(); ++i {
            var unsafe *gp = gps[i]
            if gp == &null {
                continue
            }

            if gp->is_pack { // packs deduce to "whatever arrived"; see OverloadResolution.
                continue
            }

            // An imported template's defaulted parameter is not deduced in C++
            // either: `make_unique`'s `enable_if_t<!is_array_v<T>, int> = 0`
            // is clang's to fill when it instantiates the call.
            if self.lookup(owner, gp->index) == &null {
                if gp->ffi_has_default {
                    continue
                }

                return false
            }
        }

        return true
    }

    /// # unify

    /// \return the rank of the match, None on failure.
    fn unify(self, param: unsafe *Type, arg: unsafe *Type, top: bool) -> ImplicitRank {
        if param == &null || arg == &null {
            return ImplicitRank::None
        }

        // Top-level cv is not deduced from and not deduced into
        // ([temp.deduct.call]/2): by-value `const T` against a const lvalue
        // is T := the unqualified type on both counts. A reference P looks
        // through itself first (below), so `const T&` still sees the const.
        if top && (!isa<CXXLValueRefType>(param)) && !isa<CXXRValueRefType>(param) {
            param = canon_unqual(param)
            arg   = canon_unqual(arg)
            // An argument typed by an imported `T&` result (`v[i]` on a
            // `vector<*N>`) is an lvalue of T: an expression has no reference
            // type in C++ ([expr.type]/1), so a by-value or pointer P deduces
            // from the referee. `destroy(v[i])` against `T*` is T := N.
            if arg != &null && isa<CXXLValueRefType>(arg) {
                arg = canon_unqual(cast<CXXLValueRefType>(arg)->referee)
            }

            if arg != &null && isa<CXXRValueRefType>(arg) {
                arg = canon_unqual(cast<CXXRValueRefType>(arg)->referee)
            }

            if param == arg {
                return ImplicitRank::Exact
            }
        }

        if isa<GenericParamType>(param) {
            var unsafe *g = cast<GenericParamType>(param)
            if g->owner == &null {
                return ImplicitRank::None
            }

            return if (self.bind(g->owner, g->param_index, arg)) => (ImplicitRank::Exact)
                   else => ImplicitRank::None
        }

        if !param->is_dependent() {
            // Concrete parameter: the ordinary relation.
            if param == arg {
                return ImplicitRank::Exact
            }

            if !top {
                return ImplicitRank::None
            }

            return self.conv->implicit(arg, param)
        }

        // P = cv T': A must carry every qualifier P does, and T' deduces
        // from A minus them. `const T&` against `const int` is T := int;
        // `const T*` against `const volatile int*` is T := volatile int.
        if isa<QualifiedType>(param) {
            var pq = cast<QualifiedType>(param)->quals
            var aq = canon_quals(arg)
            if (aq & pq) != pq {
                return ImplicitRank::None
            }

            var unsafe *rest = self.sc->types->qualified(canon_unqual(arg), (aq & ~pq))
            return self.unify(cast<QualifiedType>(param)->inner, rest, false)
        }

        // A dependent C++ reference parameter (only imported signatures have
        // one): deduction looks THROUGH it -- [temp.deduct.call]/3, "if P is
        // a reference type, the type referred to by P is used" -- so
        // `push(const T&)` with an i32 deduces T := i32. Binding then ranks
        // as Conversion::_bind_ref does: lvalue refs as the referee's match,
        // rvalue refs never better than Converted. Concrete refs never reach
        // here; the branch above sends them through Conversion.
        if isa<CXXLValueRefType>(param) || isa<CXXRValueRefType>(param) {
            var unsafe *a = arg
            if isa<CXXLValueRefType>(a) {
                a = cast<CXXLValueRefType>(a)->referee
            }

            if isa<CXXRValueRefType>(a) {
                a = cast<CXXRValueRefType>(a)->referee
            }

            if isa<CXXLValueRefType>(param) {
                return self._unify_referee(
                    cast<CXXLValueRefType>(param)->referee,
                    a,
                )
            }

            var rr = self._unify_referee(
                cast<CXXRValueRefType>(param)->referee,
                a,
            )

            return if (rr != ImplicitRank::None) => (ImplicitRank::Converted)
                   else => ImplicitRank::None
        }

        // A computed value argument (`Buf<N + 1>`, Compiler/Spec/Eval.md#value-nodes) is a
        // non-deduced context: it binds nothing; the substituted type is
        // compared after deduction.
        if isa<TypeExpr>(param) && cast<TypeExpr>(param)->is_value {
            return ImplicitRank::Exact
        }

        // Dependent composite: same shape, recurse exact.
        if param->kind != arg->kind {
            // *Derived -> *Base<T>: allow the top-level pointer case through
            // the base's own record when the shapes are both pointers.
            return ImplicitRank::None
        }

        match param->kind {
            case TypeKind::PointerType {
                if self.tu.is_unsafe_ptr(param) != self.tu.is_unsafe_ptr(arg) {
                    return ImplicitRank::None
                }

                // A qualification conversion at the outermost pointer
                // ([temp.deduct.call]/4): `*const T` takes a `*i64`, T := i64,
                // as the concrete `*i64 -> *const i64` already converts. Only
                // here: deeper levels must match, or `**const T` would accept
                // a `**T` C++ refuses.
                var unsafe *ppe = cast<PointerType>(param)->pointee
                var unsafe *ape = cast<PointerType>(arg)->pointee
                if top && isa<QualifiedType>(ppe) {
                    var pq = cast<QualifiedType>(ppe)->quals
                    var aq = canon_quals(ape)
                    var unsafe *rest = self.sc->types->qualified(canon_unqual(ape), (aq & ~pq))
                    var r = self._inner(
                        self.unify(cast<QualifiedType>(ppe)->inner, rest, false),
                    )

                    if r == ImplicitRank::None {
                        return r
                    }

                    return if ((aq & pq) == pq) => (r) else => ImplicitRank::Converted
                }

                return self._inner(self.unify(ppe, ape, false))
            } case TypeKind::NullableType {
                return self._inner(
                    self.unify(
                        cast<NullableType>(param)->inner,
                        cast<NullableType>(arg)->inner,
                        false,
                    ),
                )
            } case TypeKind::VectorType {
                return self._inner(
                    self.unify(
                        cast<VectorType>(param)->element,
                        cast<VectorType>(arg)->element,
                        false,
                    ),
                )
            } case TypeKind::SetType {
                return self._inner(
                    self.unify(
                        cast<SetType>(param)->element,
                        cast<SetType>(arg)->element,
                        false,
                    ),
                )
            } case TypeKind::FixedArrayType {
                var unsafe *pa = cast<FixedArrayType>(param)
                var unsafe *aa = cast<FixedArrayType>(arg)
                // `[T; N]` against `[i32; 3]` deduces the value parameter
                // N := 3 (Compiler/Spec/Eval.md#generic-value-parameters).
                if pa->extent_param != &null && aa->extent_param == &null {
                    // A computed extent (`[T; N + 1]`) is a non-deduced
                    // context, as in C++: it binds nothing here; N comes
                    // from another argument, and the substituted parameter
                    // type is checked against this one after (Compiler/Spec/Eval.md#value-nodes).
                    if isa<TypeExpr>(pa->extent_param) {
                        return self._inner(
                            self.unify(pa->element, aa->element, false),
                        )
                    }

                    var unsafe *g = dyn_cast<GenericParamType>(pa->extent_param)
                    if g == &null || g->owner == &null {
                        return ImplicitRank::None
                    }

                    var unsafe *v = self.sc->types->value_arg(
                        false,
                        aa->size_bits as u64,
                    )

                    if !self.bind(g->owner, g->param_index, v) {
                        return ImplicitRank::None
                    }

                    return self._inner(
                        self.unify(pa->element, aa->element, false),
                    )
                }

                if pa->extent_param != aa->extent_param || pa->size_bits != aa->size_bits {
                    return ImplicitRank::None
                }

                return self._inner(self.unify(pa->element, aa->element, false))
            } case TypeKind::MapType {
                var unsafe *pm = cast<MapType>(param)
                var unsafe *am = cast<MapType>(arg)
                if self.unify(pm->key, am->key, false) == ImplicitRank::None {
                    return ImplicitRank::None
                }

                return self._inner(self.unify(pm->value, am->value, false))
            } case TypeKind::FunctionPointerType {
                var unsafe *pf = cast<FunctionPointerType>(param)
                var unsafe *af = cast<FunctionPointerType>(arg)
                if pf->params.size() != af->params.size() {
                    return ImplicitRank::None
                }

                // A `fn` value never narrows to a raw `unsafe fn` (Conversion).
                if pf->is_raw && !af->is_raw {
                    return ImplicitRank::None
                }

                if pf->call_conv != af->call_conv {
                    return ImplicitRank::None
                }

                for var i: usize = 0; i < pf->params.size(); ++i {
                    if self.unify(pf->params[i], af->params[i], false) == ImplicitRank::None {
                        return ImplicitRank::None
                    }
                }

                if pf->return_type == &null != (af->return_type == &null) {
                    return ImplicitRank::None
                }

                if pf->return_type == &null {
                    return ImplicitRank::Exact
                }

                return self._inner(
                    self.unify(pf->return_type, af->return_type, false),
                )
            } case TypeKind::RecordType {
                var unsafe *pr = cast<RecordType>(param)
                var unsafe *ar = cast<RecordType>(arg)
                // `Foo<T>` against `Foo<i32>`: the arg's decl is an instance of
                // the param's pattern (or the pattern itself for a dependent arg).
                var unsafe *ppat = NameLookup::representative(
                    self.tu.pattern_of(pr->decl),
                )

                var unsafe *apat = NameLookup::representative(
                    self.tu.pattern_of(ar->decl),
                )

                if ppat != apat {
                    return ImplicitRank::None
                }

                // `L<T>::P` against `L<i32>::P`: the enclosing instances
                // unify too (RecordType::outer), so T := i32.
                if pr->outer != &null || ar->outer != &null {
                    if pr->outer == &null || ar->outer == &null {
                        return ImplicitRank::None
                    }

                    if self.unify(pr->outer, ar->outer, false) == ImplicitRank::None {
                        return ImplicitRank::None
                    }
                }

                for var i: usize = 0; i < pr->args.size(); ++i {
                    // `Outcome<i32, E...>` against `Outcome<i32, f64, bool>`:
                    // a trailing pack takes every argument from here on, and
                    // one already deduced must be those exactly.
                    var unsafe *pg = dyn_cast<GenericParamType>(pr->args[i])
                    if pg != &null
                        && pg->is_pack
                        && i + 1 == pr->args.size()
                        && pg->owner != &null {
                        if i > ar->args.size() {
                            return ImplicitRank::None
                        }

                        var have = cxx::std::vector<unsafe *Type>()
                        if self.pack_elems(
                            pg->owner,
                            pg->param_index,
                            unsafe &have,
                        ) {
                            if have.size() != ar->args.size() - i {
                                return ImplicitRank::None
                            }

                            for var k: usize = 0; k < have.size(); ++k {
                                if have[k] != ar->args[i + k] {
                                    return ImplicitRank::None
                                }
                            }

                            return ImplicitRank::Exact
                        }

                        self.open_pack(pg->owner, pg->param_index)
                        for var k: usize = i; k < ar->args.size(); ++k {
                            self.push_pack(
                                pg->owner,
                                pg->param_index,
                                ar->args[k],
                            )
                        }

                        return ImplicitRank::Exact
                    }

                    if i >= ar->args.size() {
                        return ImplicitRank::None
                    }

                    if self.unify(pr->args[i], ar->args[i], false) == ImplicitRank::None {
                        return ImplicitRank::None
                    }
                }

                if pr->args.size() != ar->args.size() {
                    return ImplicitRank::None
                }

                return ImplicitRank::Exact
            } case TypeKind::AssocType {
                // `T::Map<K>` against `T::Map<i32>`: one associated type of
                // one head, so its arguments unify as a record's do (K :=
                // i32). The head and the interface are matched, not deduced
                // from: both are the caller's own already.
                var unsafe *pa = cast<AssocType>(param)
                var unsafe *aa = cast<AssocType>(arg)
                if NameLookup::representative(pa->assoc) != NameLookup::representative(
                    aa->assoc,
                ) {
                    return ImplicitRank::None
                }

                if pa->args.size() != aa->args.size() {
                    return ImplicitRank::None
                }

                if self.unify(pa->base, aa->base, false) == ImplicitRank::None {
                    return ImplicitRank::None
                }

                if self.unify(pa->iface, aa->iface, false) == ImplicitRank::None {
                    return ImplicitRank::None
                }

                for var i: usize = 0; i < pa->args.size(); ++i {
                    if self.unify(pa->args[i], aa->args[i], false) == ImplicitRank::None {
                        return ImplicitRank::None
                    }
                }

                return ImplicitRank::Exact
            } default {
                return ImplicitRank::None
            }
        }
    }

    /// A reference parameter's referee against the argument's value type
    /// ([temp.deduct.call]/3). The argument's cv is NOT stripped here -- it
    /// is the referee's, not a top-level cv -- so `T&` against a `const i32`
    /// is T := const i32, the only way it binds. The referee's own cv is
    /// matched off first, and binding may ADD it: `const T&` against a
    /// `const i32` or an `i32` is T := i32 either way.
    priv fn _unify_referee(self, referee: unsafe *Type, a: unsafe *Type) -> ImplicitRank {
        if referee == &null || a == &null {
            return ImplicitRank::None
        }

        var unsafe *p    = referee
        var unsafe *rest = a
        if isa<QualifiedType>(referee) {
            var pq = cast<QualifiedType>(referee)->quals
            var aq = canon_quals(a)
            rest = self.sc->types->qualified(canon_unqual(a), (aq & ~pq))
            p    = cast<QualifiedType>(referee)->inner
        }

        var mark = self.bindings.size()
        var r    = self.unify(p, rest, false)
        if r != ImplicitRank::None {
            return r
        }

        return self._unify_from_base(p, rest, mark)
    }

    /// [temp.deduct.call]/4.3: P a class template-id, A a class DERIVED from
    /// an instance of it -- deduce from that base. `getline(basic_istream<C,
    /// T>&, basic_string<C, T, A>&)` with an ifstream binds C and T from its
    /// `basic_istream<char, ...>` base; matched only against the arg's own
    /// record, every stream argument was SC063E. The first base that unifies
    /// wins, and the binding ranks as a conversion (derived-to-base).
    /// \p mark: the bindings to roll back to before each attempt.
    priv fn _unify_from_base(self, p: unsafe *Type, a: unsafe *Type, mark: usize) -> ImplicitRank {
        var unsafe *pc = canon_unqual(p)
        var unsafe *ac = canon_unqual(a)
        if pc == &null || ac == &null || (!isa<RecordType>(pc)) || !isa<RecordType>(ac) {
            return ImplicitRank::None
        }

        var unsafe *ppat = NameLookup::representative(
            self.tu.pattern_of(cast<RecordType>(pc)->decl),
        )

        var bases = cxx::std::vector<unsafe *Type>()
        self.base_records(ac, &bases)
        for var i: usize = 0; i < bases.size(); ++i {
            var unsafe *b = cast<RecordType>(bases[i])
            if NameLookup::representative(self.tu.pattern_of(b->decl)) != ppat {
                continue
            }

            while self.bindings.size() > mark {
                self.bindings.pop_back()
            }

            while self.bindings.size() > mark {
                self.bindings.pop_back()
            }

            if self.unify(pc, bases[i], false) != ImplicitRank::None {
                return ImplicitRank::Converted
            }
        }

        while self.bindings.size() > mark {
            self.bindings.pop_back()
        }

        return ImplicitRank::None
    }

    priv fn _inner(self, r: ImplicitRank) -> ImplicitRank {
        return if (r == ImplicitRank::None) => (ImplicitRank::None) else => ImplicitRank::Exact
    }

    /// # Self through a bound

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
    fn through_receiver(self,
                        f:        unsafe *FunctionDecl,
                        receiver: unsafe *Type,
                        t:        unsafe *Type) -> unsafe *Type {
        if t == &null || receiver == &null || f == &null {
            return t
        }

        if f->semantic_dc == &null {
            return t
        }

        var unsafe *home = (f->semantic_dc)->owner_decl()
        if home == &null || !isa<InterfaceDecl>(home) {
            return t
        }

        return self.replace_self(t, home, receiver, true)
    }

    // replace_self / own_args: Substitution's (the base class), since an
    // associated type's default is read with Self := the conformer there.

    /// The instance of requirement \p f's DECLARING interface that a
    /// qualified call names through interface instance \p q: `Sub<i32>::get`,
    /// with `interface <T> Sub derives Container<T>`, calls Container<i32>'s
    /// `get`. The composed list says which instance a requirement came
    /// through (Requirement::source), over q's interface's parameters. Null
    /// when \p f is no requirement of q's interface.
    fn declaring_instance(self, f: unsafe *FunctionDecl, q: unsafe *Type) -> unsafe *Type {
        if f == &null || q == &null || f->semantic_dc == &null {
            return &null
        }

        var unsafe *qr = canon_unqual(q)
        var unsafe *qd = self.tu.record_decl(qr)
        if qd == &null {
            return &null
        }

        var unsafe *qi = dyn_cast<InterfaceDecl>(
            NameLookup::representative(self.tu.pattern_of(qd)),
        )

        if qi == &null {
            return &null
        }

        var unsafe *home = NameLookup::representative(
            (f->semantic_dc)->owner_decl(),
        )

        if home == qi {
            return qr
        }

        var unsafe *fr = NameLookup::representative(f)
        for var i: usize = 0; i < qi->requirements.size(); ++i {
            var unsafe *r = qi->requirements.get(i)
            if NameLookup::representative(r->decl) != fr || r->source == &null {
                continue
            }

            var unsafe *src = canon_unqual(
                if (r->source->canonical != &null) => (r->source->canonical) else => r->source,
            )

            if !src->is_dependent() {
                return src
            }

            var d = Deduction(self.sc, self.conv)
            d.bind_from_record(qr)
            var unsafe *s = d.substitute(src)
            return if (s != &null) => (canon_unqual(s)) else => &null
        }

        return &null
    }
}
