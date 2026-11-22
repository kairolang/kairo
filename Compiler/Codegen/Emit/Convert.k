/// --- The Kairo Project ----------------------- Codegen/Emit/Convert.k --- ///
///
///   EmitIR, part: conversions. A value written where a type is wanted (an
///   argument, an initializer, a returned value) with the cast, view or adapter
///   that makes it that type exactly, and the `as` casts.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/Shims.hh"
ffi "c++" import "clang/Basic/TokenKinds.h"
ffi "c++" import "vector"

import AST::Context::InstantiationRegistry::InstanceEntry
import AST::DeclFacts
import AST::DeclFacts::decl_pattern
import AST::Kind::TypeKind::TypeKind
import AST::LangItems::{
    LangMembers,
    LowerTargets,
    WellKnownType,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind, BuiltinType, RecordType, builtin_info, canon_has_const, canon_quals, canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    EnumDecl,
    FunctionDecl,
    ModuleDecl,
}
import AST::Node::Expressions::{
    CastMode,
    ParenExpr,
    TypeCastExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
    NullLiteralExpr,
}
import AST::Node::Types::{
    CXXLValueRefType, CXXRValueRefType, FixedArrayType, FunctionPointerType, GenericParamType,
    NullableType,     PointerType,
}
import AST::ParamMode::ParamMode
import Codegen::Emit::Calls
import Codegen::Emit::Decls
import Codegen::Emit::EmitIR::EmitIR
import Codegen::Emit::Exprs
import Codegen::Emit::Operators
import Codegen::Emit::Stmts
import Codegen::Spell::Spell::Speller

extend EmitIR {
    /// Emit `e` where a value of `want` is required: the exactness cast
    /// if the canonicals differ. Initializers, returns and arguments all go
    /// through here.
    prot fn _value(self,
                   e:     unsafe *Expr,
                   want:  unsafe *Type,
                   subst: unsafe *InstanceEntry = &null) {
        if self._array_view(e, want, subst) || self._const_slice_view(e, want, subst) {
            return
        }

        if self._fn_ref_adapter(e, want) {
            return
        }

        if self._fn_effect_value(e, want) {
            return
        }

        if self._fn_spec_value(e, want) {
            return
        }

        if self._needs_cast(e, want, subst) {
            if self._nullable_convert(e, want, subst) {
                return
            }

            self._cast_to(want, e, "static_cast", subst)
            return
        }

        self.emit(e)
    }

    /// `T? -> U?` with different inners that convert (`*D? -> *B?`,
    /// `*B? -> *const B?`, `i32? -> i64?`). Null has no
    /// converting constructor, so the static_cast every other exactness
    /// conversion gets is ill-formed C++ here. A parameter lambda (no
    /// capture-default, so it is valid in a global's initializer too)
    /// tests the source once, keeps its null, and converts only the value:
    ///
    ///   [](auto&& __kairo_h) noexcept -> N { if (__kairo_h.is_null()) { return N(); }
    ///       return N(static_cast<U>(__kairo_h.__value())); }(e)
    ///
    /// A nested `T??` is left alone: which level a null belongs to is not
    /// this conversion's to decide. True when it emitted.
    priv fn _nullable_convert(self,
                              e:     unsafe *Expr,
                              want:  unsafe *Type,
                              subst: unsafe *InstanceEntry) -> bool {
        if e == &null || want == &null || e->type_ == &null || want->canonical == &null {
            return false
        }

        var unsafe *wn = canon_unqual(want->canonical)
        var unsafe *hn = canon_unqual(e->type_)
        if wn == &null || hn == &null || (!isa<NullableType>(wn)) || (!isa<NullableType>(hn)) {
            return false
        }

        var unsafe *wt = self._nullable_inner(wn)
        var unsafe *ht = self._nullable_inner(hn)
        if wt == &null || ht == &null || wt == ht {
            return false
        }

        if isa<NullableType>(wt) || isa<NullableType>(ht) {
            return false
        }

        var nt = self._spell._type(want, subst)
        var it = self._spell._type(cast<NullableType>(wn)->inner, subst)
        var hv = LowerTargets::panic_wrap_src()
        var nx = if (self._cg->opts.unwind) => ("") else => " noexcept"
        self._cg->sink->spell(
            e->range,
            "[](auto&& " + hv + ")" + nx + " -> " + nt + " { if (" + hv + "." + LowerTargets::nullable_is_null() + "()) { return " + nt + "(); } return " + nt + "(static_cast<" + it + ">(" + hv + "." + LowerTargets::nullable_value() + "())); }(",
        )

        self.emit(e)
        self._cg->sink->spell(e->range, ")")
        return true
    }

    /// True when clang would see a conversion Kairo already decided. Both
    /// sides concrete; identity is by canonical with top-level cv ignored. A
    /// parameter that IS one of `subst`'s generic parameters is read as the
    /// instance's argument for it; any other dependent parameter is left to
    /// the instantiation.
    prot fn _needs_cast(self,
                        e:     unsafe *Expr,
                        want:  unsafe *Type,
                        subst: unsafe *InstanceEntry) -> bool {
        if e == &null || want == &null {
            return false
        }

        var unsafe *have = e->type_
        var unsafe *w    = want->canonical
        if have == &null || w == &null {
            return false
        }

        if subst != &null
            && canon_unqual(w) != &null
            && canon_unqual(w)->kind == TypeKind::GenericParamType {
            var unsafe *s = self._spell.subst_for(
                cast<GenericParamType>(canon_unqual(w)),
                subst,
            )

            if s != &null {
                w = s
            }
        }

        if have->is_dependent() || w->is_dependent() {
            return false
        }

        if have->is_instantiation_dependent() || w->is_instantiation_dependent() {
            return false
        }

        // A reference bound to its own referee (`const T& x = path`): no conversion.
        var unsafe *wu = canon_unqual(w)
        if wu != &null && isa<CXXLValueRefType>(wu) {
            if canon_unqual(have) == canon_unqual(
                cast<CXXLValueRefType>(wu)->referee,
            ) {
                return false
            }
        }

        // `T&&` from a prvalue of T binds as it is. Only an lvalue Sema let
        // bind there (a MOVE value: CallTyping::arg_info) needs the cast.
        if wu != &null
            && isa<CXXRValueRefType>(wu)
            && e->value_category == Expr::ValueCategory::RValue {
            if canon_unqual(have) == canon_unqual(
                cast<CXXRValueRefType>(wu)->referee,
            ) {
                return false
            }
        }

        // A record by value is copy-constructed; `static_cast<Rec>(x)` is a
        // temporary and changes value category. Records go as they are.
        if canon_unqual(w)->kind == TypeKind::RecordType {
            return false
        }

        // A C++ type Kairo cannot read (`fmt::format_string<T...>`, opaque
        // until clang substitutes the callee's pack) reached from a C string
        // or a C++ object: Sema let it through only because clang said C++
        // converts it implicitly, so C++ performs the conversion and
        // the value goes as written. A cast would spell the
        // parameter's UNSUBSTITUTED type -- `static_cast<fs<T ...>>` names a
        // T that does not exist at the call -- and would also move fmt's
        // consteval format check off the literal it inspects.
        // So is a scalar handed to one: in a generic body a C++ member of an
        // instance over the body's parameters (`unordered_map<K, V>::reserve`)
        // takes a member type of the C++ template (`size_type`) that only
        // the template's own parameters spell (`unordered_map<_Key, ...>`).
        if canon_unqual(w)->kind == TypeKind::OpaqueFFIType {
            var unsafe *hu = canon_unqual(have)
            if hu != &null
                && (hu->kind == TypeKind::RecordType
                    || hu->kind == TypeKind::PointerType
                    || hu->kind == TypeKind::OpaqueFFIType
                    || hu->kind == TypeKind::BuiltinType) {
                return false
            }
        }

        return canon_unqual(have) != canon_unqual(w)
    }

    /// A `fn` value converted to a `fn` type with a wider panic effect (a set S into S' with S a subset, or no set into one; Compiler/Spec/Panic.md
    /// §2.10). The two C++ results differ, so the value is wrapped: a
    /// lambda holding it, whose result is `__kairo_pcall<R'>` of the call
    /// (the panic result forwarded, or the plain value as Ok). True when it
    /// emitted.
    ///
    ///   ::__kairo_fn<R'(A)>::own(new auto([__kairo_w = ::__kairo_fn<R(A)>(e)]
    ///       (A __kairo_a0) noexcept -> R' { return ::__kairo_pcall<R'>(__kairo_w, a0); }))
    ///
    /// A `(fn ...)?` target is looked through: the wrapper is the
    /// `T` whose non-explicit `Null(T&&)` makes the Null at every
    /// copy-initialization site. A `(fn ...)?` SOURCE as well keeps its
    /// null: a parameter lambda (one with no capture-default, so it is valid
    /// in a global's initializer too) tests it once and wraps only the
    /// value, `__kairo_h.__value()`.
    priv fn _fn_effect_value(self, e: unsafe *Expr, want: unsafe *Type) -> bool {
        if e == &null || want == &null || e->type_ == &null || want->canonical == &null {
            return false
        }

        var unsafe *wt = self._nullable_inner(canon_unqual(want->canonical))
        var unsafe *ht = self._nullable_inner(canon_unqual(e->type_))
        var unsafe *w = dyn_cast<FunctionPointerType>(
            if (wt != &null) => (wt) else => canon_unqual(want->canonical),
        )

        var unsafe *h = dyn_cast<FunctionPointerType>(
            if (ht != &null) => (ht) else => canon_unqual(e->type_),
        )

        if w == &null || h == &null || w == h || w->panic_result == &null {
            return false
        }

        // A nullable source needs a nullable target to keep its null in;
        // anything else is not this conversion.
        if ht != &null && wt == &null {
            return false
        }

        // A raw target holds no lambda to wrap the value in (a raw
        // panicking `fn` is left to plain conversion).
        if w->is_raw {
            return false
        }

        if h->panic_result == w->panic_result {
            return false
        }

        var nx = if (self._cg->opts.unwind) => ("") else => " noexcept"
        if ht != &null {
            var nt = self._spell._type(want)
            var hv = LowerTargets::panic_wrap_src()
            self._cg->sink->spell(
                e->range,
                "[](auto&& " + hv + ")" + nx + " -> " + nt + " { if (" + hv + "." + LowerTargets::nullable_is_null() + "()) { return " + nt + "(); } return ",
            )

            self._fn_effect_wrap(
                e,
                w,
                h,
                hv + "." + LowerTargets::nullable_value() + "()",
            )

            self._cg->sink->spell(e->range, "; }(")
            self.emit(e)
            self._cg->sink->spell(e->range, ")")
            return true
        }

        self._fn_effect_wrap(e, w, h, "")
        return true
    }

    /// A function NAMED as a `fn` value whose C++ declaration takes a
    /// by-value parameter as `const T&` (Speller::by_ref_value_param: a
    /// written `const s: string`, or one ParamPassInference inferred).
    /// Its `fn` type says `string`, and `R(const string&)` converts to no
    /// `__kairo_fn<R(string)>`, so the value is a captureless adapter with the
    /// type's own parameters, calling the function:
    ///
    ///   static_cast<W>(::__kairo_fn<R(A)>(+[](A __kairo_a0) noexcept -> R {
    ///       return ::ns::f(static_cast<decltype(__kairo_a0)&&>(__kairo_a0)); }))
    ///
    /// (a raw target takes the lambda's own pointer; an effect-widening
    /// target wraps the adapter as _fn_effect_value wraps a name). The
    /// adapter is at the use, so the function's signature stays a fact of
    /// its own body whoever takes its address, in whatever run (the
    /// cross-TU rule). The one cost is the argument's copy into the adapter,
    /// which a by-value call through a `fn` value always made. True when it
    /// emitted.
    priv fn _fn_ref_adapter(self, e: unsafe *Expr, want: unsafe *Type) -> bool {
        if e == &null || want == &null || e->type_ == &null || want->canonical == &null {
            return false
        }

        // A generic function named with its arguments (`f<C>`) is one
        // too: `targs` spells them after its name.
        var unsafe *d    = self._fn_ref_decl(e)
        var        targs = ""
        if d == &null {
            d = self._fn_ref_generic(e)
            if d == &null {
                return false
            }

            var unsafe *x = e
            while x != &null && isa<ParenExpr>(x) {
                x = cast<ParenExpr>(x)->inner
            }

            targs = self._spell.args_str(self._written_targs(x))
        }

        var unsafe *h  = dyn_cast<FunctionPointerType>(canon_unqual(e->type_))
        var unsafe *wt = self._nullable_inner(canon_unqual(want->canonical))
        var unsafe *w = dyn_cast<FunctionPointerType>(
            if (wt != &null) => (wt) else => canon_unqual(want->canonical),
        )

        if h == &null || w == &null {
            return false
        }

        if h->params.size() != d->params.size() || h->modes.size() < h->params.size() {
            return false
        }

        // Or one whose `fn` type passes a by-value parameter as `T&&`
        // (Speller::value_param_form: a destructive class) while the
        // function declares its own by value: a function that keeps its
        // by-value parameters, or a generic one whose parameter names its
        // own type parameter (DeclFacts::value_param_rule).
        var any = false
        for var i: usize = 0; i < d->params.size(); ++i {
            if Speller::by_ref_value_param(d->params[i]) {
                any = true
            }

            // A generic function's parameter of a type an instance
            // decides differs only at a destructive instance, which
            // `::__kairo_fn_of` tells apart.
            var form = Speller::value_param_form(*h->params.get(i))
            if DeclFacts::param_is_plain_value(d->params[i])
                && (form == 1 || form == 2 && targs.size() > 0)
                && !Speller::value_param_passed_rref(d, d->params[i]) {
                any = true
            }
        }

        if !any {
            return false
        }

        // The target is the parameter's type as the callee writes it when
        // that names the callee's own type parameters: the value's own
        // type is then the one this scope can spell.
        var unsafe *wc = canon_unqual(want->canonical)
        if wc != &null && (wc->is_dependent() || wc->is_instantiation_dependent()) {
            w    = h
            want = e->type_
        }

        var nx = if (self._cg->opts.unwind) => ("") else => " noexcept"
        var unsafe *ret_t = if (h->panic_result != &null) => (h->panic_result)
                            else => h->return_type
        var ps = ""
        var fa = ""
        for var i: usize = 0; i < h->params.size(); ++i {
            var an = LowerTargets::panic_wrap_arg(i)
            if i > 0 {
                ps += ", "
                fa += ", "
            }

            ps += self._spell.param_named(h->params[i], h->modes[i], an)
            fa += "static_cast<decltype(" + an + ")&&>(" + an + ")"
        }

        var adapt = "+[](" + ps + ")" + nx + " -> " + self._spell.decl(
            ret_t,
            "",
        ) + " { return " + self._spell.qual_name(d) + targs + "(" + fa + "); }"
        if targs.size() > 0 {
            adapt = "::" + LowerTargets::fn_value_of() + "<&" + self._spell.qual_name(
                d,
            ) + targs + ", " + self._spell.fn_signature(h) + nx + ">::get()"
        }

        // The widening conversion _fn_effect_value makes of a name, of the adapter.
        var widen = w != h
            && w->panic_result != &null
            && !w->is_raw
            && h->panic_result != w->panic_result
        if widen {
            self._fn_effect_wrap(e, w, h, adapt)
            return true
        }

        var wspell = self._spell._type(want)
        if w->is_raw {
            self._cg->sink->spell(
                e->range,
                "static_cast<" + wspell + ">(" + adapt + ")",
            )

            return true
        }

        self._cg->sink->spell(
            e->range,
            "static_cast<" + wspell + ">(::" + LowerTargets::fn_value() + "<" + self._spell.fn_signature(
                h,
            ) + ">(" + adapt + "))",
        )

        return true
    }

    /// A speculatable function (FunctionDecl::speculatable) NAMED as a `fn`
    /// value: the value says so, for `__builtin_fn_speculatable` to read
    /// back wherever the value is copied to:
    ///
    ///   ::__kairo_fn<R(A)>(::ns::f, ::__kairo_spec{})
    ///
    /// Only a predicate (a `bool` result): that is what a scan evaluates
    /// ahead of the element that ends it. And only where a `fn` value of
    /// the function's own shape is wanted (a nullable one is looked
    /// through, and a parameter type that depends on its callee's generic
    /// parameters is that type once instantiated, or the plain name would
    /// not convert either). Every other route to a `fn` value keeps its
    /// spelling and makes a value that says no, which is always a correct
    /// answer. True when it emitted.
    priv fn _fn_spec_value(self, e: unsafe *Expr, want: unsafe *Type) -> bool {
        if e == &null || want == &null || e->type_ == &null || want->canonical == &null {
            return false
        }

        var unsafe *d = self._fn_ref_decl(e)
        if d == &null {
            return false
        }

        var unsafe *c = d->canonical_decl()
        if !(d->speculatable || c != &null && c->speculatable) {
            return false
        }

        if e->type_->is_dependent() || e->type_->is_instantiation_dependent() {
            return false
        }

        // The name's own type is the raw function's; the value wanted holds it.
        var unsafe *h = dyn_cast<FunctionPointerType>(canon_unqual(e->type_))
        if h == &null || h->panic_result != &null || h->call_conv != 0 || h->is_unprototyped {
            return false
        }

        var unsafe *rb = self._builtin_of(h->return_type)
        if rb == &null || rb->builtin != BuiltinKind::Bool {
            return false
        }

        var unsafe *wc = canon_unqual(want->canonical)
        var unsafe *wt = self._nullable_inner(wc)
        if wt != &null {
            wc = wt
        }

        var unsafe *w = dyn_cast<FunctionPointerType>(wc)
        if w == &null || w->is_raw {
            return false
        }

        var open = wc->is_dependent() || wc->is_instantiation_dependent()
        if !open && !self._fn_same_shape(h, w) {
            return false
        }

        self._cg->sink->spell(
            e->range,
            "::" + LowerTargets::fn_value() + "<" + self._spell.fn_signature(
                if (open) => (h) else => w,
            ) + ">(",
        )

        self.emit(e)
        self._cg->sink->spell(
            e->range,
            ", ::" + LowerTargets::fn_value_spec() + "{})",
        )

        return true
    }

    /// `h` and `w` take the same parameters the same way and return the
    /// same type, with no panic set: they differ at most in being raw.
    priv fn _fn_same_shape(self,
                           h: unsafe *FunctionPointerType,
                           w: unsafe *FunctionPointerType) -> bool {
        if h->params.size() != w->params.size()
            || h->modes.size() != w->modes.size()
            || w->panic_result != &null
            || w->call_conv != h->call_conv
            || h->canon_panics != w->canon_panics {
            return false
        }

        for var i: usize = 0; i < h->params.size(); ++i {
            if h->params[i] == &null || w->params[i] == &null {
                return false
            }

            if h->params[i]->canonical != w->params[i]->canonical {
                return false
            }
        }

        for var i: usize = 0; i < h->modes.size(); ++i {
            if h->modes[i] != w->modes[i] {
                return false
            }
        }

        if h->return_type == &null || w->return_type == &null {
            return h->return_type == w->return_type
        }

        return h->return_type->canonical == w->return_type->canonical
    }

    /// The generic free function or static member `e` names as a value
    /// with its type arguments written (`f<C>`, `ns::f<C>`), or null. Its
    /// arguments are the last name's; a qualifier that takes arguments, or
    /// goes through a value or a witness, is not one.
    priv fn _fn_ref_generic(self, e: unsafe *Expr) -> unsafe *FunctionDecl {
        var unsafe *x = e
        while x != &null && isa<ParenExpr>(x) {
            x = cast<ParenExpr>(x)->inner
        }

        if x == &null {
            return &null
        }

        var d: unsafe *Decl = &null
        if isa<NamedIdentExpr>(x) {
            var unsafe *ni = cast<NamedIdentExpr>(x)
            if ni->generic_args.size() == 0 {
                return &null
            }

            d = ni->resolved_decl
            if d != &null && self._is_local(d) {
                return &null
            }
        } else if isa<ChainExpr>(x) {
            var unsafe *ce = cast<ChainExpr>(x)
            if ce->steps.size() == 0 {
                return &null
            }

            if ce->base != &null {
                var unsafe *hb = dyn_cast<NamedIdentExpr>(ce->base)
                if hb == &null || hb->resolved_decl == &null || hb->generic_args.size() > 0 {
                    return &null
                }

                if !isa<ModuleDecl>(hb->resolved_decl) {
                    return &null
                }
            }

            for var i: usize = 0; i < ce->steps.size(); ++i {
                var unsafe *st = ce->steps.get(i)
                if st->access_kind != ChainExpr::AccessKind::ColonColon
                    || st->through != &null
                    || st->witness_iface != &null {
                    return &null
                }

                if (st->generic_args.size() > 0) != (i + 1 == ce->steps.size()) {
                    return &null
                }
            }

            d = ce->steps.get(ce->steps.size() - 1)->resolved_decl
        } else {
            return &null
        }

        var unsafe *f = dyn_cast<FunctionDecl>(d)
        if f == &null || f->generic_params.size() == 0 || f->is_method() {
            return &null
        }

        return f
    }

    /// The non-generic free function or static member `e` names as a
    /// value (`f`, `ns::f`, `T::make`), or null.
    priv fn _fn_ref_decl(self, e: unsafe *Expr) -> unsafe *FunctionDecl {
        var unsafe *x = e
        while x != &null && isa<ParenExpr>(x) {
            x = cast<ParenExpr>(x)->inner
        }

        if x == &null {
            return &null
        }

        var d: unsafe *Decl = &null
        if isa<NamedIdentExpr>(x) {
            var unsafe *ni = cast<NamedIdentExpr>(x)
            if ni->generic_args.size() > 0 {
                return &null
            }

            d = ni->resolved_decl
            if d != &null && self._is_local(d) {
                return &null
            }
        } else if isa<ChainExpr>(x) {
            var unsafe *ce = cast<ChainExpr>(x)
            if ce->steps.size() == 0 {
                return &null
            }

            // `ns::f` / `T::make`: the head names a module or a type, never a value.
            if ce->base != &null {
                var unsafe *hb = dyn_cast<NamedIdentExpr>(ce->base)
                if hb == &null || hb->resolved_decl == &null {
                    return &null
                }

                if !(isa<ModuleDecl>(hb->resolved_decl) || self._is_type_decl(hb->resolved_decl)) {
                    return &null
                }
            }

            for var i: usize = 0; i < ce->steps.size(); ++i {
                var unsafe *st = ce->steps.get(i)
                if st->access_kind != ChainExpr::AccessKind::ColonColon {
                    return &null
                }

                if st->generic_args.size() > 0
                    || st->through != &null
                    || st->witness_iface != &null {
                    return &null
                }
            }

            d = ce->steps.get(ce->steps.size() - 1)->resolved_decl
        } else {
            return &null
        }

        var unsafe *f = dyn_cast<FunctionDecl>(d)
        if f == &null || f->generic_params.size() > 0 {
            return &null
        }

        for var i: usize = 0; i < f->params.size(); ++i {
            if f->params[i] != &null && f->params[i]->is_self {
                return &null
            }
        }

        return f
    }

    /// `t`'s inner canonical when `t` is a `T?`, else null.
    priv fn _nullable_inner(self, t: unsafe *Type) -> unsafe *Type {
        if t == &null || !isa<NullableType>(t) {
            return &null
        }

        var unsafe *inn = cast<NullableType>(t)->inner
        if inn == &null {
            return &null
        }

        if inn->canonical != &null {
            inn = inn->canonical
        }

        return canon_unqual(inn)
    }

    /// _fn_effect_value's owned wrapper lambda of `h` as `w`, holding
    /// `e` -- or, when `src` is not empty, that C++ text in its place.
    priv fn _fn_effect_wrap(self,
                            e:         unsafe *Expr,
                            w:         unsafe *FunctionPointerType,
                            h:         unsafe *FunctionPointerType,
                            const src: string) {
        var rw = self._spell._type(w->panic_result)
        var ps = ""
        var fa = ""
        for var i: usize = 0; i < w->params.size(); ++i {
            var m = if (i < w->modes.size()) => (w->modes[i]) else => ParamMode::Value
            var an = LowerTargets::panic_wrap_arg(i)
            if i > 0 {
                ps += ", "
            }

            ps += self._spell.param_named(w->params[i], m, an)
            fa += ", static_cast<decltype(" + an + ")&&>(" + an + ")"
        }

        var nx = if (self._cg->opts.unwind) => ("") else => " noexcept"
        var fv = "::" + LowerTargets::fn_value()
        var wn = LowerTargets::panic_wrapped()
        self._cg->sink->spell(
            e->range,
            fv.copy() + "<" + self._spell.fn_signature(
                w,
            ) + ">::" + LowerTargets::fn_value_own() + "(new auto([" + wn + " = " + fv + "<" + self._spell.fn_signature(
                h,
            ) + ">(",
        )

        if src.size() > 0 {
            self._cg->sink->spell(e->range, src)
        } else {
            self.emit(e)
        }

        self._cg->sink->spell(
            e->range,
            ")](" + ps + ") mutable" + nx + " -> " + rw + " { return ::" + LowerTargets::panic_call_as() + "<" + rw + ">(" + wn + fa + "); }))",
        )
    }

    /// `[T; N]` where a record is wanted: Sema's array -> slice view
    /// (Conversion::array_views_as), the only way an array meets a record.
    /// Spelled as the record's `(data, len)` construction over the array's
    /// own storage; `&(a)[0]` is the first element whichever way the array
    /// was declared. A slice parameter of a generic callee (`[const T;]` of
    /// an `extend <T> Slice<T>` member) is spelled through the call's
    /// instance `subst` (_slice_in): C++ deduces no template argument
    /// through the conversion. True when it emitted.
    prot fn _array_view(self,
                        e:     unsafe *Expr,
                        want:  unsafe *Type,
                        subst: unsafe *InstanceEntry) -> bool {
        if e == &null || want == &null || e->type_ == &null || want->canonical == &null {
            return false
        }

        var unsafe *have = canon_unqual(e->type_)
        var unsafe *w    = canon_unqual(want->canonical)
        if have == &null || w == &null {
            return false
        }

        if have->kind != TypeKind::FixedArrayType || w->kind != TypeKind::RecordType {
            return false
        }

        if have->is_dependent() || (w->is_dependent() && !self._slice_in(w, subst)) {
            return false
        }

        self._cg->sink->spell(e->range, self._spell._type(want, subst) + "(&(")
        self.emit(e)
        self._cg->sink->spell(e->range, ")[0], " + f"{have->size_bits}" + ")")
        return true
    }

    /// `w` is a Slice instance over a callee's parameters, spelled through
    /// the call's instance `subst`.
    priv fn _slice_in(self, w: unsafe *Type, subst: unsafe *InstanceEntry) -> bool {
        var unsafe *rt = dyn_cast<RecordType>(w)
        var        *gs = self._cg->tu->global_scope
        if subst == &null || rt == &null || gs == &null {
            return false
        }

        var unsafe *sd = gs->well_known()->get(WellKnownType::Slice)
        return sd != &null && Speller::rep(decl_pattern(rt->decl)) == Speller::rep(sd)
    }

    /// `[T;]` or `[T]` where `[const T;]` is wanted: Sema's const view
    /// (Conversion::views_as_const_slice). C++ has no conversion between
    /// two Slice instances, so it is spelled as the target's `(data, len)`
    /// construction over the source's storage, inside a lambda so the
    /// source is evaluated once. True when it emitted.
    priv fn _const_slice_view(self,
                              e:     unsafe *Expr,
                              want:  unsafe *Type,
                              subst: unsafe *InstanceEntry) -> bool {
        if e == &null || want == &null || e->type_ == &null || want->canonical == &null {
            return false
        }

        var unsafe *have = dyn_cast<RecordType>(canon_unqual(e->type_))
        var unsafe *w    = dyn_cast<RecordType>(canon_unqual(want->canonical))
        if have == &null || w == &null || have == w || have->is_dependent() || w->is_dependent() {
            return false
        }

        if have->args.size() != 1 || w->args.size() != 1 || !canon_has_const(*w->args.get(0)) {
            return false
        }

        var *gs = self._cg->tu->global_scope
        if gs == &null {
            return false
        }

        var unsafe *sd = gs->well_known()->get(WellKnownType::Slice)
        var unsafe *vd = gs->well_known()->get(WellKnownType::Vector)
        if sd == &null || Speller::rep(decl_pattern(w->decl)) != Speller::rep(sd) {
            return false
        }

        var unsafe *hp = Speller::rep(decl_pattern(have->decl))
        var        s   = LowerTargets::forward_param()
        var        acc = ""
        if hp == Speller::rep(sd) {
            var two = gs->well_known()->two_word()
            // The two-word slice's are accessors, not fields.
            var call = if (two) => ("()") else => ""
            acc = s.copy() + "." + LangMembers::slice_data(
                two,
            ) + call + ", " + s + "." + LangMembers::slice_count(two) + call
        } else if vd != &null && hp == Speller::rep(vd) {
            // The two-word Vector converts through its own `op as`.
            if gs->well_known()->two_word() {
                return false
            }

            acc = s.copy() + ".data(), " + s + ".size()"
        } else {
            return false
        }

        self._cg->sink->spell(
            e->range,
            "([](auto const& " + s + ") noexcept { return " + self._spell._type(
                want,
                subst,
            ) + "(" + acc + "); }(",
        )

        self.emit(e)
        self._cg->sink->spell(e->range, "))")
        return true
    }

    prot fn _cast_to(self,
                     t:          unsafe *Type,
                     e:          unsafe *Expr,
                     const kind: string,
                     subst:      unsafe *InstanceEntry = &null) {
        // A target that names a C++ class's private/protected member type
        // (the iterator `find()` returns, compared through a free
        // `operator==`) cannot be spelled: clang refuses the name. Its cast
        // only restates a conversion C++ makes itself, except a lowering's
        // move, said here with a clang builtin and no name (no <utility> needed).
        if kind == "static_cast" && self._spell.names_hidden_member(t) {
            var unsafe *tc = canon_unqual(t->canonical)
            if tc != &null && isa<CXXRValueRefType>(tc) && e->is_lvalue() {
                self._cg->sink->spell(
                    e->range,
                    "([]<class T>(T& " + LowerTargets::forward_param() + ") -> T&& { return static_cast<T&&>(" + LowerTargets::forward_param() + "); }(",
                )

                self.emit(e)
                self._cg->sink->spell(e->range, "))")
            } else {
                self.emit(e)
            }

            return
        }

        self._cg->sink->spell(
            e->range,
            kind.copy() + "<" + self._spell._type(t, subst) + ">(",
        )

        self.emit(e)
        self._cg->sink->spell(e->range, ")")
    }

    priv fn _type_is_builtin_int(self, t: unsafe *Type) -> bool {
        if t == &null {
            return false
        }

        var unsafe *c = t->canonical
        if c == &null {
            c = t
        }

        var unsafe *u = canon_unqual(c)
        if u == &null || !isa<BuiltinType>(u) {
            return false
        }

        return cast<BuiltinType>(u)->info()->is_integer()
    }

    /// `e` is the `&null` literal, through parentheses or an implicit retyping.
    priv fn _is_null_literal(self, e: unsafe *Expr) -> bool {
        var unsafe *x = e
        while x != &null {
            var unsafe *pe = dyn_cast<ParenExpr>(x)
            if pe != &null {
                x = pe->inner
                continue
            }

            // Sema's own implicit retyping of the literal to the target.
            var unsafe *tc = dyn_cast<TypeCastExpr>(x)
            if tc != &null && tc->operand != &null && isa<NullLiteralExpr>(tc->operand) {
                return true
            }

            break
        }

        return x != &null && isa<NullLiteralExpr>(x)
    }

    /// The written target is the result type (invariant 15). Which C++ cast:
    /// `as const` -> const_cast, `as unsafe` -> reinterpret_cast (a C-style
    /// cast when it drops a pointee qualifier), otherwise static_cast. The
    /// checked downcast is _checked_downcast's; the asserting one arrives
    /// expanded by OperatorLowering (Compiler/Spec/Panic.md#crashes-are-not-panics) around a `dynamic_only`
    /// cast, spelled `dynamic_cast` as is; a user `op as` or a converting
    /// ctor is OperatorLowering's.
    prot fn _cast(self, n: unsafe *TypeCastExpr) {
        if n->checked_downcast {
            self._checked_downcast(n)
            return
        }

        if n->asserting_downcast {
            self._ice(
                n->range,
                "EmitIR: an asserting downcast reached codegen unexpanded; OperatorLowering owns its check",
            )

            return
        }

        if n->dynamic_only {
            self._cast_to(n->target, n->operand, "dynamic_cast")
            return
        }

        // A prvalue CopyMoveLowering wrapped to carry the parameter it is
        // passed to (TypeCastExpr::hand): the value itself wherever it is
        // not that parameter's argument (EmitIR::_value_arg).
        if n->hand != &null
            && n->target != &null
            && n->target->canonical != &null
            && !isa<CXXRValueRefType>(n->target->canonical) {
            self.emit(n->operand)
            return
        }

        // A lowering's move: `x as T&&`. Never written by the user (Kairo has
        // no reference types), always a record, always static_cast.
        if n->target != &null
            && n->target->canonical != &null
            && isa<CXXRValueRefType>(n->target->canonical) {
            if n->instance_move {
                self._cg->sink->spell(
                    n->range,
                    "::" + LowerTargets::instance_move() + "(",
                )

                self.emit(n->operand)
                self._cg->sink->spell(n->range, ")")
                return
            }

            self._cast_to(n->target, n->operand, "static_cast")
            return
        }

        // `a as [T;]` on an array: the same view an implicit site gets.
        if self._array_view(n->operand, n->target, &null)
            || self._const_slice_view(n->operand, n->target, &null) {
            return
        }

        // `f as fn(...)`: CastTyping's rung 5b'' accepted it as the implicit
        // conversion, so it lowers as one -- an effect-widening wrap where
        // the panic results differ, the exactness static_cast otherwise.
        if n->mode != CastMode::Unsafe
            && n->target != &null
            && n->target->canonical != &null
            && n->operand->type_ != &null
            && isa<FunctionPointerType>(canon_unqual(n->operand->type_)) {
            var unsafe *tfn = self._nullable_inner(
                canon_unqual(n->target->canonical),
            )

            if tfn == &null {
                tfn = canon_unqual(n->target->canonical)
            }

            if isa<FunctionPointerType>(tfn) {
                self._value(n->operand, n->target)
                return
            }
        }

        var src_rec = self._record_operand(n->operand)
        if src_rec && !self._type_is_pointer(n->operand->type_) {
            self._ice(
                n->range,
                "EmitIR: `as` on a record value; OperatorLowering owns op as / ctor casts",
            )
        }

        var kind = "static_cast"
        if n->mode == CastMode::Const {
            kind = "const_cast"
        }

        if n->mode == CastMode::Unsafe {
            kind = "reinterpret_cast"
        }

        // `p as usize` reads the address (casting.mdx). static_cast from a
        // pointer to an integer is ill-formed C++; reinterpret_cast is the
        // one cast that takes it, whatever the pointee's cv (CastTyping lets
        // only usize through, so the target always holds the whole address).
        if self._type_is_pointer(n->operand->type_) && self._type_is_builtin_int(n->target) {
            kind = "reinterpret_cast"
        }

        // `as unsafe *B` between a class and its base (CastTyping's
        // base_adjust): the base subobject's address, which only
        // static_cast computes. A reinterpret is right for a first base at
        // offset 0 and silently wrong for every other one.
        if n->base_adjust {
            kind = "static_cast"
        }

        // A pointer retyped to a pointer to an unrelated NON-class pointee
        // (`*const u8` as `*const c_char`) is no static_cast in C++: only
        // void* and class-hierarchy pointers convert that way.
        if kind == "static_cast"
            && !n->base_adjust
            && self._type_is_pointer(n->operand->type_)
            && self._type_is_pointer(n->target)
            && self._scalar_pointee(n->operand->type_)
            && self._scalar_pointee(n->target) {
            kind = "reinterpret_cast"
        }

        // The same cast on an operand typed only per instance (a duck call's
        // result, `self.dyn()->x`): Sema cannot see a pointer, so the scalar
        // pair above is missed and static_cast would be ill-formed in the
        // instance that retypes `const u8 *` as `const char *`. A C-style cast
        // picks the right one per instance.
        var dep_opnd = n->operand->type_ == &null
            || n->operand->type_->is_dependent()
            || n->operand->type_->is_instantiation_dependent()
        if kind == "static_cast"
            && !n->base_adjust
            && dep_opnd
            && self._type_is_pointer(n->target)
            && self._scalar_pointee(n->target)
            && !self._is_null_literal(n->operand) {
            self._cg->sink->spell(
                n->operand->range,
                "(" + self._spell._type(n->target, &null) + ")(",
            )

            self.emit(n->operand)
            self._cg->sink->spell(n->operand->range, ")")
            return
        }

        // `as unsafe *R` with the operand or the target typed only per
        // instance (a duck call's result, a CRTP `(unsafe &self) as unsafe
        // *T`): CastTyping cannot see whether the records are related, so no
        // base_adjust, and reinterpret_cast is silently wrong in every
        // instance where they are -- a non-first base is at an offset (a
        // DeclContext inside a ClassDecl, a mixin inside a parser). A C-style
        // cast is static_cast where the instance's classes are related and
        // reinterpret_cast where not: what base_adjust gives a non-dependent
        // cast.
        var dep_tgt = n->target != &null
            && (n->target->is_dependent() || n->target->is_instantiation_dependent())
        if kind == "reinterpret_cast"
            && n->mode == CastMode::Unsafe
            && !n->base_adjust
            && (dep_opnd || dep_tgt)
            && self._type_is_pointer(n->target)
            && !self._scalar_pointee(n->target)
            && !self._is_null_literal(n->operand) {
            self._cg->sink->spell(
                n->operand->range,
                "(" + self._spell._type(n->target, &null) + ")(",
            )

            self.emit(n->operand)
            self._cg->sink->spell(n->operand->range, ")")
            return
        }

        // `&null as unsafe *T` (O28d): `nullptr` is a std::nullptr_t, which
        // reinterpret_cast refuses to retype as a pointer; static_cast is the
        // null pointer conversion.
        if n->mode == CastMode::Unsafe && self._is_null_literal(n->operand) {
            kind = "static_cast"
        }

        // reinterpret_cast cannot cast away qualifiers, and `as unsafe *` is
        // the one Kairo spelling that drops them (the written cast already
        // passed the unsafe-context check). A C-style cast is the one C++
        // cast that both retypes and drops cv. Between two UNRELATED classes
        // it would pick reinterpret_cast anyway, but the pair still goes
        // through `const volatile void *` first so the bits are all that
        // survive whatever clang decides relates them.
        if n->mode == CastMode::Unsafe && self._drops_quals(n->operand->type_, n->target) {
            // Unless the two are related (base_adjust): then the C-style
            // cast's static_cast is exactly the adjustment wanted.
            var bridge = self._record_pointee(n->operand->type_)
                && self._record_pointee(n->target)
                && !n->base_adjust
            self._cg->sink->spell(
                n->operand->range,
                "(" + self._spell._type(n->target, &null) + ")(",
            )

            if bridge {
                self._cg->sink->spell(
                    n->operand->range,
                    "(const volatile void *)(",
                )
            }

            self.emit(n->operand)
            if bridge {
                self._cg->sink->spell(n->operand->range, ")")
            }

            self._cg->sink->spell(n->operand->range, ")")
            return
        }

        // `pd as *B?` from a `*D?`: the implicit conversion written out,
        // so the same null-keeping wrap.
        if kind == "static_cast"
            && (n->mode == CastMode::Default || n->mode == CastMode::Static)
            && self._nullable_convert(n->operand, n->target, &null) {
            return
        }

        // `v as E?` from an integer, `e as u8?` from a plain enum: the cast
        // is to the inner type, which then converts to the nullable.
        // Null<E> has no constructor from E's underlying integer (nor
        // Null<u8> from an enum class), so the one-step static_cast
        // into it is a C++ error. A closed enum's check has already
        // wrapped the operand (OperatorLowering), so it still runs first.
        if kind == "static_cast" && n->target != &null && n->target->canonical != &null {
            var unsafe *inner = self._nullable_inner(
                canon_unqual(n->target->canonical),
            )

            var into_enum = inner != &null
                && self._is_plain_enum(inner)
                && self._type_is_builtin_int(n->operand->type_)
            var from_enum = inner != &null
                && self._is_plain_enum(n->operand->type_)
                && self._type_is_builtin_int(inner)
            if into_enum || from_enum {
                self._cg->sink->spell(
                    n->operand->range,
                    "static_cast<" + self._spell._type(
                        n->target,
                        &null,
                    ) + ">(static_cast<" + self._spell._type(inner, &null) + ">(",
                )

                self.emit(n->operand)
                self._cg->sink->spell(n->operand->range, "))")
                return
            }
        }

        if kind == "static_cast" && self._fp_to_int(n) {
            return
        }

        self._cast_to(n->target, n->operand, kind)
    }

    /// A float `as` an integer truncates toward zero and saturates: NaN is
    /// 0, a value at or past a bound is that bound's extreme (casting.mdx,
    /// "Float to integer"). A C++ static_cast is undefined there, so the
    /// cast is a lambda called on the operand, which evaluates it once and
    /// is a constant expression, so a constant operand folds and an eval
    /// cast gets the same answer:
    ///
    ///     [](F x) noexcept -> I { return x != x ? 0 : x >= HI ? MAX
    ///                                    : x <= LO ? MIN : static_cast<I>(x); }(e)
    ///
    /// `HI` is 2^(N-1) for a signed N-bit target and 2^N for an unsigned
    /// one, `LO` -2^(N-1) or 0, each exact in `F`; a bound past `F`'s
    /// largest finite value is its infinity, which only the infinity
    /// reaches. A signed `MIN` is the double -2^(N-1) converted (exact and
    /// in range for every builtin width) and `MAX` its complement; an
    /// unsigned `MAX` is -1 converted. A nullable target (`x as i32?`)
    /// clamps to its inner type and converts that. True when the cast was spelled;
    /// false for any other pair (a corelib float, a dependent or a
    /// non-builtin type), which keeps the plain cast.
    ///
    /// ### Parameters
    /// - `n`: an `as` whose kind is static_cast.
    ///
    /// ### Returns
    /// Whether the cast was emitted here.
    priv fn _fp_to_int(self, n: unsafe *TypeCastExpr) -> bool {
        if n->mode != CastMode::Default && n->mode != CastMode::Static {
            return false
        }

        // `x as i32?` clamps to the inner type, then converts.
        var unsafe *src   = self._builtin_of(n->operand->type_)
        var unsafe *dst   = self._builtin_of(n->target)
        var unsafe *inner = n->target
        if dst == &null && n->target != &null && n->target->canonical != &null {
            inner = self._nullable_inner(canon_unqual(n->target->canonical))
            dst   = self._builtin_of(inner)
        }

        if src == &null || dst == &null {
            return false
        }

        // The float's exponent bound: every finite value is below 2^emax
        // (the IEEE formats' bias + 1; x87's is binary128's). A half-width
        // float is widened to f32 first, which is exact and keeps every
        // answer: the lambda's parameter is then a float, and the x86
        // backend at -O0 passes a `__bf16` call result as an argument wrong.
        var emax: usize = 0
        var wide        = false
        match src->builtin {
            case BuiltinKind::F16, BuiltinKind::BF16 {
                emax = 128
                wide = true
            } case BuiltinKind::F32 {
                emax = 128
            } case BuiltinKind::F64 {
                emax = 1024
            } case BuiltinKind::F80, BuiltinKind::F128 {
                emax = 16384
            } default {
                return false
            }
        }

        match dst->builtin {
            case BuiltinKind::I8,   BuiltinKind::I16,  BuiltinKind::I32,   BuiltinKind::I64,
                 BuiltinKind::I128, BuiltinKind::I256, BuiltinKind::I512,  BuiltinKind::U8,
                 BuiltinKind::U16,  BuiltinKind::U32,  BuiltinKind::U64,   BuiltinKind::U128,
                 BuiltinKind::U256, BuiltinKind::U512, BuiltinKind::USize, BuiltinKind::ISize {
                if dst->size_bits == 0 {
                    return false
                }
            } default {
                return false
            }
        }

        var sgn = dst->info()->is_signed()
        var k   = if (sgn) => (dst->size_bits - 1) else => dst->size_bits
        var ft = if (wide) => (builtin_info(BuiltinKind::F32)->cxx.copy())
                 else => src->cxx_emission()
        var it = self._spell._type(inner, &null)
        var x  = LowerTargets::fp_to_int_param()
        var hi = if (k >= emax) => ("static_cast<" + ft + ">(" + LowerTargets::float_inf(
                     "",
                 ) + "())")
                 else => "static_cast<" + ft + ">(0x1p" + f"{k}" + ")"
        var lo = if (sgn) => ("-" + hi) else => "static_cast<" + ft + ">(0)"
        var mn = if (sgn) => ("static_cast<" + it + ">(-0x1p" + f"{k}" + ")")
                 else => "static_cast<" + it + ">(0)"
        var mx = if (sgn) => ("static_cast<" + it + ">(~" + mn + ")")
                 else => "static_cast<" + it + ">(-1)"
        var wrap = inner != n->target
        if wrap {
            self._cg->sink->spell(
                n->operand->range,
                "static_cast<" + self._spell._type(n->target, &null) + ">(",
            )
        }

        self._cg->sink->spell(
            n->operand->range,
            "[](" + ft + " " + x + ") noexcept -> " + it + " { return " + x + " != " + x + " ? static_cast<" + it + ">(0) : " + x + " >= " + hi + " ? " + mx + " : " + x + " <= " + lo + " ? " + mn + " : static_cast<" + it + ">(" + x + "); }(",
        )

        if wide {
            self._cg->sink->spell(n->operand->range, "static_cast<" + ft + ">(")
        }

        self.emit(n->operand)
        if wide {
            self._cg->sink->spell(n->operand->range, ")")
        }

        self._cg->sink->spell(n->operand->range, ")")
        if wrap {
            self._cg->sink->spell(n->operand->range, ")")
        }

        return true
    }

    /// The builtin `t` is, through sugar and cv, or null.
    priv fn _builtin_of(self, t: unsafe *Type) -> unsafe *BuiltinType {
        if t == &null || t->is_dependent() || t->is_instantiation_dependent() {
            return &null
        }

        var unsafe *c = if (t->canonical != &null) => (t->canonical) else => t
        var unsafe *u = canon_unqual(c)
        if u == &null || !isa<BuiltinType>(u) {
            return &null
        }

        return cast<BuiltinType>(u)
    }

    /// `t` is a plain (non-ADT) enum, Kairo's or a C/C++ one.
    priv fn _is_plain_enum(self, t: unsafe *Type) -> bool {
        if t == &null {
            return false
        }

        var unsafe *c = canon_unqual(
            if (t->canonical != &null) => (t->canonical) else => t,
        )

        if c == &null || c->kind != TypeKind::RecordType {
            return false
        }

        var unsafe *en = dyn_cast<EnumDecl>(cast<RecordType>(c)->decl)
        return en != &null && !en->is_adt
    }

    /// `p as (*D)?` (casting.md, the checked downcast): `dynamic_cast<D*>`,
    /// and its null pointer is the NULL nullable, not a present one holding
    /// nullptr (Stage 1 storage is tagged, Compiler/Spec/Nullables.md#the-library-type). A lambda called
    /// on the spot binds the result once and is an expression everywhere a
    /// cast is, a namespace-scope initializer included:
    ///
    ///   [](D* __kairo_dc) noexcept -> N { return __kairo_dc ? N(__kairo_dc) : N(); }(dynamic_cast<D*>(p))
    ///
    /// `N()` is Null's null (AdtRole::NullDefault). With the pointer
    /// niche (G2b) this becomes the dynamic_cast alone.
    priv fn _checked_downcast(self, n: unsafe *TypeCastExpr) {
        var unsafe *tc = n->target->canonical
        var unsafe *nt = if (tc != &null
                             && canon_unqual(tc) != &null
                             && isa<NullableType>(canon_unqual(tc))) => (cast<NullableType>(
                             canon_unqual(tc),
                         ))
                         else => &null
        if nt == &null {
            self._ice(
                n->range,
                "EmitIR: a checked downcast whose target is no nullable; CastTyping gate failure",
            )

            return
        }

        var big = self._spell._type(n->target, &null)
        var ptr = self._spell._type(nt->inner, &null)
        var v   = LowerTargets::checked_downcast_value()
        var nx  = if (self._cg->opts.unwind) => ("") else => " noexcept"
        self._cg->sink->spell(
            n->range,
            "[](" + ptr + " " + v + ")" + nx + " -> " + big + " { return " + v + " ? " + big + "(" + v + ") : " + big + "(); }(dynamic_cast<" + ptr + ">(",
        )

        self.emit(n->operand)
        self._cg->sink->spell(n->range, "))")
    }

    /// True when some pointee level of `src` carries a qualifier the same
    /// level of `dst` lacks. Walks while both sides are pointers, so
    /// `*const u8 -> *void` is a drop at the first level although the
    /// pointees differ, and an integer source never is.
    priv fn _drops_quals(self, src: unsafe *Type, dst: unsafe *Type) -> bool {
        if src == &null || dst == &null {
            return false
        }

        var unsafe *s       = if (src->canonical != &null) => (src->canonical) else => src
        var unsafe *d       = if (dst->canonical != &null) => (dst->canonical) else => dst
        var        lvl: i32 = 0
        while true {
            var unsafe *su = canon_unqual(s)
            var unsafe *du = canon_unqual(d)
            if su == &null || du == &null {
                return false
            }

            if su->kind != TypeKind::PointerType || du->kind != TypeKind::PointerType {
                return false
            }

            s = cast<PointerType>(su)->pointee
            d = cast<PointerType>(du)->pointee
            if (canon_quals(s) & ~canon_quals(d)) != 0 {
                return true
            }

            // Adding a qualifier two or more pointers deep (`char**` ->
            // `const char**`) is "casting away" to reinterpret_cast too: a
            // qualification conversion needs const at every level between
            // (SI2).
            lvl = lvl + 1
            if lvl >= 2 && (canon_quals(d) & ~canon_quals(s)) != 0 {
                return true
            }
        }
    }

    /// `t` is a pointer whose pointee is a record.
    /// True when `t` is a pointer whose pointee is a non-void builtin
    /// scalar (`*const u8`, `*c_char`).
    priv fn _scalar_pointee(self, t: unsafe *Type) -> bool {
        if t == &null {
            return false
        }

        var unsafe *c = canon_unqual(
            if (t->canonical != &null) => (t->canonical) else => t,
        )

        if c == &null || c->kind != TypeKind::PointerType {
            return false
        }

        var unsafe *p = canon_unqual(cast<PointerType>(c)->pointee)
        if p != &null && p->kind == TypeKind::OpaqueFFIType { // a C++ vector type (`__m128i`)
            return true
        }

        if p == &null || p->kind != TypeKind::BuiltinType {
            return false
        }

        return cast<BuiltinType>(p)->builtin != BuiltinKind::Void
    }

    priv fn _record_pointee(self, t: unsafe *Type) -> bool {
        if t == &null {
            return false
        }

        var unsafe *c = canon_unqual(
            if (t->canonical != &null) => (t->canonical) else => t,
        )

        if c == &null || c->kind != TypeKind::PointerType {
            return false
        }

        var unsafe *p = canon_unqual(cast<PointerType>(c)->pointee)
        return p != &null && p->kind == TypeKind::RecordType
    }
}
