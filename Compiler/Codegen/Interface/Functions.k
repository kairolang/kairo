/// --- The Kairo Project ---------------- Codegen/Interface/Functions.k --- ///
///
///   InterfaceEmitter, part: functions and instances. Method, free function
///   and namespace-scope variable declarations, extension scopes and their
///   forwarders, parameter lists, and the explicit instantiations of tier 3
///   (`template class X<A>;` in the home TU, `extern template` elsewhere) with
///   the asserts that check an instance's layout.
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

import AST::ASTSupport::FrozenList
import AST::Context::InstantiationRegistry::{
    AdtShape,
    InstanceEntry,
}
import AST::DeclFacts
import AST::EnumNiche::adt_niche_payload_variant
import AST::Kind::DeclKind::DeclKind
import AST::LangItems::{
    LowerTargets,
    hex32,
}
import AST::Node::Base::{
    Decl,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    BuiltinType,
    builtin_info,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Types::{
    FixedArrayType,
    FunctionPointerType,
    PointerType,
    TypeExpr,
}
import Codegen::Interface::InterfaceEmitter::InterfaceEmitter
import Codegen::Plan::EmitPlan::{
    ExtScope,
    PlanEntry,
    PlanMode,
    plan_under_duck,
}
import Codegen::Plan::Visitors::{
    generator_elem,
    generator_push_form,
}
import Codegen::Spell::Spell::Speller
import Location::SourceRange::SourceRange
import Token::TokenKind::TokenKind

extend InterfaceEmitter {
    /// # Functions

    /// A method declaration inside its class. `self` is dropped (it is
    /// `this`); a function without `self` is `static`.
    prot fn _method_decl(self,
                         m:     unsafe *Declarations::FunctionDecl,
                         owner: unsafe *Decl) -> string {
        var s       = self._spell->template_head(m)
        var is_ctor = self._is_ctor(m, owner)
        // One spelling, computed once. `op delete` comes back from leaf() as
        // `~Owner` already, so the leading `~` IS the destructor test -- there
        // is no second place that knows how a destructor is named.
        var nm      = self._spell->leaf(m)
        var is_dtor = m->is_operator && nm.data()[0] == ('~' as u8)
        // `op as` spells `operator T`; C++ gives a conversion no return type.
        // An extension's is a named static member with an ordinary one.
        var is_conv = m->is_operator
            && m->op_token[0].kind == TokenKind::KwAs
            && DeclFacts::decl_extension_of(m) == &null
        var is_method = m->is_method()

        // Standard attributes before every decl-specifier, as _free_fn_text:
        // `virtual [[noreturn]]` appertains to the type and clang rejects it.
        if m->panic_result != &null { // Compiler/Spec/Panic.md#the-c-view, as _free_fn_text.
            s += "[[nodiscard]] "
        }

        if m->is_noreturn {
            s += "[[noreturn]] "
        }

        // An explicit specialization takes no storage class: it is static
        // as its primary is ([temp.expl.spec]/2).
        if !is_method && !is_ctor && !is_dtor && !Speller::is_fn_spec(m) {
            s += "static "
        }

        if m->abi == Declarations::AbiKind::Virtual
            || m->abi == Declarations::AbiKind::Override
            || m->body_kind == Declarations::FnBodyKind::Virtual {
            s += "virtual "
        }

        s += Speller::fn_attrs(m)
        // Compiler/Spec/Eval.md#eval-fn: an eval fn runs at compile time only. `consteval` is
        // implicitly inline, so EmitPlan makes its body visible as it does
        // an `inline` one's.
        if m->is_eval() {
            s += "consteval "
        } else if m->is_constexpr() {
            s += "constexpr "
        }

        if is_ctor {
            s += self._spell->leaf(owner)
        } else if is_dtor || is_conv {
            s += nm
        } else {
            s += self._spell->declared_return(m, owner)
            s += " "
            s += nm + self._spell->spec_suffix(m)
        }

        s += "("
        s += self._params(m, false, &null, owner, true)
        s += ")"
        if is_method && m->is_const() {
            s += " const"
        }

        if m->no_unwind {
            s += " noexcept"
        }

        // A generic record's member `requires`, so the record's
        // explicit instantiation leaves the member out where it fails.
        s += self._spell->member_requires(m, owner)
        if m->abi == Declarations::AbiKind::Override || m->overrides_virtual {
            s += " override"
        }

        s += self._body_suffix(m)
        s += ";"
        s += self._push_method_decl(m, owner)
        return s
    }

    /// The push form of generator method `m` (generator_push_form),
    /// declared beside it in the class: the same name and parameters, then
    /// the loop body, returning whether the sequence ran to its end.
    /// Always inlined: it exists to become its caller's loop.
    priv fn _push_method_decl(self,
                              m:     unsafe *Declarations::FunctionDecl,
                              owner: unsafe *Decl) -> string {
        if !generator_push_form(m, self._cg->instances) {
            return ""
        }

        var s = self._spell->template_head(m) + LowerTargets::attr_always_inline()
        if !m->is_method() {
            s += "static "
        }

        s += "inline bool " + self._spell->leaf(m) + "("
        var ps = self._params(m, false, &null, owner, false)
        if ps.size() > 0 {
            ps += ", "
        }

        s += ps + self._push_sink(m, owner) + ")"
        if m->is_method() && m->is_const() {
            s += " const"
        }

        s += " noexcept" + self._spell->member_requires(m, owner) + ";"
        return s
    }

    /// The push form's last parameter, `::__kairo_each<T> __kairo_f`.
    prot fn _push_sink(self, f: unsafe *Declarations::FunctionDecl, scope: unsafe *Decl) -> string {
        return "::" + LowerTargets::gen_each() + "<" + self._spell->_type(
            generator_elem(f),
            &null,
            scope,
        ) + "> " + LowerTargets::gen_sink()
    }

    /// The push form of free generator `f`, or of an extension's, declared
    /// after `f`'s own declaration (_push_method_decl).
    priv fn _push_free_decl(self,
                            f:   unsafe *Declarations::FunctionDecl,
                            ext: unsafe *Declarations::ExtensionDecl) -> string {
        if !generator_push_form(f, self._cg->instances) {
            return ""
        }

        var s = self._spell->template_head(f) + LowerTargets::attr_always_inline()
        if ext != &null {
            s += "static "
        }

        s += "inline bool " + self._fn_name(f) + "("
        var ps = self._params(f, ext != &null, ext, &null, false)
        if ps.size() > 0 {
            ps += ", "
        }

        return s + ps + self._push_sink(f, &null) + ") noexcept;"
    }

    /// The `operator[]` forwarders C++ code reaches a split subscript's named
    /// forms through (Speller::subscript_forwarded decides which forms get
    /// one), declared beside them; EmitIR::_subscript_forwarder_def defines
    /// each beside its form's definition, where every type the signature
    /// names is complete.
    prot fn _subscript_forwarders(self,
                                  d:          unsafe *Decl,
                                  methods:    FrozenList<unsafe *Declarations::FunctionDecl>,
                                  cur_access: u8,
                                  at:         SourceRange) -> u8 {
        var acc = cur_access
        for var i: usize = 0; i < methods.size(); ++i {
            var unsafe *m = methods[i]
            if m == &null || !self._spell->subscript_forwarded(m) {
                continue
            }

            var s = ""
            if m->is_constexpr() {
                s += "constexpr "
            }

            s += self._spell->declared_return(m, d) + " operator[]("
            s += self._params(m, false, &null, d, false)
            s += ")"
            if m->is_const() {
                s += " const"
            }

            if m->no_unwind {
                s += " noexcept"
            }

            s += self._spell->member_requires(m, d)
            s += ";"
            acc = self._access(
                acc,
                self._cxx_vis(unsafe (m as unsafe *Decl)),
                false,
                at,
            )

            self._cg->sink->spell(at, s)
        }

        return acc
    }

    /// `extern T const x;`. Always `extern`, own globals included: a
    /// namespace-scope `const` has external linkage in C++ only when an
    /// `extern` declaration precedes its definition, and a `pub const` has to
    /// be reachable from every module that imports it.
    prot fn _global_var_decl(self, v: unsafe *Declarations::VariableDecl) {
        self._cg->sink->spell(
            self._at(v),
            "extern " + self._spell->global_var(v) + ";",
        )
    }

    prot fn _free_fn_decl(self,
                          f:   unsafe *Declarations::FunctionDecl,
                          ext: unsafe *Declarations::ExtensionDecl) {
        // A definition of a C++-declared function: the header declares it.
        if Speller::defines_foreign(f) {
            return
        }

        // A namespace-scope default argument names its thunk at the point of
        // declaration, and the thunk is placed after `f`: declare it first.
        if ext == &null && Speller::template_params(unsafe (f as unsafe *Decl)).size() == 0 {
            for var i: usize = 0; i < f->params.size(); ++i {
                var unsafe *p = f->params[i]
                if p == &null || self._default_arg(f, i).size() == 0 {
                    continue
                }

                var unsafe *th = cast<Declarations::FunctionDecl>(
                    p->default_thunk,
                )

                self._cg->sink->spell(
                    self._at(f),
                    self._free_fn_text(th, &null),
                )
            }
        }

        self._cg->sink->spell(self._at(f), self._free_fn_text(f, ext))
    }

    /// A function declaration. With `ext`, an extension member: a static
    /// member of its scope, its receiver an explicit first parameter
    /// (`Self*` / `const Self*`), its template head the merged one (the
    /// extension's, then its own).
    priv fn _free_fn_text(self,
                          f:   unsafe *Declarations::FunctionDecl,
                          ext: unsafe *Declarations::ExtensionDecl) -> string {
        var s = self._spell->template_head(f)
        // An extension member is a static member of its scope struct, and a
        // class member cannot have a language linkage.
        if ext == &null {
            s += Speller::c_linkage(f)
        }

        // The standard attributes lead the decl-specifiers: after `static`,
        // or after a GNU `__attribute__((noinline))` from fn_attrs, clang
        // reads one as appertaining to the type and rejects it ("'nodiscard'
        // attribute cannot be applied to types").
        if f->is_noreturn {
            s += "[[noreturn]] "
        }

        // A panic result is the error (Compiler/Spec/Panic.md#the-c-view): a C++ caller that drops
        // it drops the error with it.
        if f->panic_result != &null {
            s += "[[nodiscard]] "
        }

        s += Speller::fn_attrs(f)

        if ext != &null && !Speller::is_fn_spec(f) { // a specialization is static as its primary is.
            s += "static "
        }

        if f->is_eval() { // Compiler/Spec/Eval.md#eval-fn
            s += "consteval "
        }

        s += self._spell->declared_return(f)
        s += " "
        s += self._fn_name(f) + self._spell->spec_suffix(f)
        s += "("
        s += self._params(
            f,
            ext != &null,
            ext,
            &null,
            ext == &null && Speller::template_params(unsafe (f as unsafe *Decl)).size() == 0,
        )

        s += ")"
        if f->no_unwind {
            s += " noexcept"
        }

        s += ";"
        s += self._push_free_decl(f, ext)
        return s
    }

    /// # Extension scopes

    /// `struct __kairo_ext_X { static ...; };`, every member declared, then
    /// the operator forwarders. Inside the scope's namespace wrapper. All
    /// members are public: Kairo's visibility is AccessCheck's, not C++
    /// access control's, and the struct must be one text everywhere.
    prot fn _scope_def(self, sc: unsafe *ExtScope) {
        var at = self._at(sc->anchor)
        self._cg->sink->spell(at, "struct " + sc->name + " {")
        // Specializations after every primary (as _record_def's members).
        var n = sc->members.size()
        for var k: usize = 0; k < n * 2; ++k {
            var unsafe *m = sc->members[k % n]
            if Speller::is_fn_spec(unsafe (m as unsafe *Decl)) != (k >= n) {
                continue
            }

            self._cg->sink->spell(
                self._at(m),
                self._free_fn_text(m, sc->exts[k % n]),
            )
        }

        self._cg->sink->spell(at, "};")
        self._cg->sink->brk()
        for var i: usize = 0; i < sc->members.size(); ++i {
            var unsafe *m = sc->members[i]
            if !m->is_operator {
                continue
            }

            self._forwarder(sc, m, sc->exts[i])
        }
    }

    /// `t` may be an operand of a C++ operator overload: anything but a
    /// builtin number/bool/char, a pointer, a raw function pointer, or an
    /// array of those. Unknown or dependent types count as yes, as before.
    priv fn _forwardable_operand(self, t: unsafe *Type) -> bool {
        if t == &null || t->canonical == &null {
            return true
        }

        var unsafe *c = canon_unqual(t->canonical)
        while c != &null && isa<FixedArrayType>(c) {
            c = canon_unqual(cast<FixedArrayType>(c)->element)
        }

        if c == &null || c->is_dependent() || c->is_instantiation_dependent() {
            return true
        }

        if isa<BuiltinType>(c) {
            return cast<BuiltinType>(c)->lang_decl != &null
        }

        if isa<PointerType>(c) {
            return false
        }

        if isa<FunctionPointerType>(c) {
            return !(cast<FunctionPointerType>(c)->is_raw
                || cast<FunctionPointerType>(c)->is_unprototyped)
        }

        return true
    }

    /// Operand `p` of `f`, an operator of the generic extension `ext`
    /// with no parameters of its own, names the extension's parameters.
    /// They are the receiver's (Deduction::bind_from_extension), so the
    /// forwarder must not deduce them from `p` as well: `op ==(const self,
    /// const o: View<const T>)` on a `View<const i32>` is T := const i32 by
    /// the receiver and T := i32 by `o`, a conflict to C++ alone. A generic
    /// body's infix use of the operator is compiled through the forwarder.
    priv fn _receiver_decides(self,
                              f:   unsafe *Declarations::FunctionDecl,
                              ext: unsafe *Declarations::ExtensionDecl,
                              p:   unsafe *Declarations::ParamDecl) -> bool {
        if f->generic_params.size() > 0
            || p->is_pack
            || DeclFacts::decl_generic_params(unsafe (ext as unsafe *Decl)).size() == 0 {
            return false
        }

        return p->type_ != &null
            && p->type_->canonical != &null
            && p->type_->canonical->is_dependent()
    }

    /// `inline RET operator+(X& __kairo_a0, Y __kairo_a1) { return
    /// ::N::__kairo_ext_X::__kairo_op_plus(__kairo_a0, ...); }`: the C++
    /// operator an extension operator is, for C++ callers. Kairo calls the
    /// static member directly. Every operand is forwarded as its own
    /// declared type (`static_cast<decltype(a)&&>`), so a by-value or
    /// `@move` operand moves on and an `@inout` one stays an lvalue; the
    /// postfix dummy is passed as is.
    priv fn _forwarder(self,
                       sc:  unsafe *ExtScope,
                       f:   unsafe *Declarations::FunctionDecl,
                       ext: unsafe *Declarations::ExtensionDecl) {
        var _op = self._spell->ext_forwarder_name(f)
        if _op.size() == 0 { // `in`, `^^`, ...: no C++ operator to forward from.
            return
        }

        // C++ overloads an operator only with an operand of class or enum
        // type ([over.oper]): `extend i64 { fn op < ... }` as `operator<(
        // long, long)` is CL001E at the extension. Kairo never
        // calls the forwarder (it calls the static member, and a bound
        // generic the witness), and no C++ caller could reach one either.
        if !self._forwardable_operand(ext->target) {
            var any = false
            for var i: usize = 0; i < f->params.size(); ++i {
                var unsafe *p = f->params[i]
                if p != &null && (!p->is_self) && self._forwardable_operand(p->type_) {
                    any = true
                    break
                }
            }

            if !any {
                return
            }
        }

        var fid = Speller::fid_of(unsafe (f as unsafe *Decl))
        var s   = self._spell->template_head(unsafe (f as unsafe *Decl))
        // A forwarder of an eval operator is one too: an `inline` one could
        // not pass its parameters on to a consteval call.
        s += (if (f->is_eval()) => ("consteval ") else => "inline ")
        s += self._spell->declared_return(f)
        s += " "
        s += _op
        s += "("
        var call       = ""
        var k:   usize = 0
        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if p == &null {
                continue
            }

            var nm = LowerTargets::forwarder_arg(k)
            if k > 0 {
                s += ", "
                call += ", "
            }

            if p->is_self {
                s += self._spell->ext_receiver(f, ext) + " " + nm
                call += nm
            } else if self._receiver_decides(f, ext, p) {
                s += "typename ::" + LowerTargets::nondeduced() + "<" + self._spell->param_decl(
                    p,
                    "",
                ) + ">::type " + nm
                call += "static_cast<decltype(" + nm + ")&&>(" + nm + ")"
            } else {
                s += self._spell->param_decl(p, nm)
                call += "static_cast<decltype(" + nm + ")&&>(" + nm + ")"
            }

            k += 1
        }

        if Speller::op_is_postfix(f) {
            var nm = LowerTargets::forwarder_arg(k)
            if k > 0 {
                s += ", "
                call += ", "
            }

            s += "int " + nm
            call += nm
        }

        // Explicit template arguments: the forwarder's own parameters are the
        // static member's, so nothing is left for deduction to choose.
        var targs = ""
        var tps   = Speller::template_params(unsafe (f as unsafe *Decl))
        for var i: usize = 0; i < tps.size(); ++i {
            targs += (if (i == 0) => ("<") else => ", ")
            targs += self._spell->tok_name(tps[i]->name, fid)
            if tps[i]->is_pack {
                targs += "..."
            }
        }

        if tps.size() > 0 {
            targs += ">"
        }

        s += ")"
        if f->no_unwind {
            s += " noexcept"
        }

        s += " { return " + self._scope_qual(sc) + "::" + self._spell->leaf(
            unsafe (f as unsafe *Decl),
        ) + targs + "(" + call + "); }"
        self._cg->sink->spell(self._at(f), s)
    }

    /// `scope`: the record whose body the declaration is in, or null
    /// (Speller::_type).
    ///
    /// `defaults`: also write each Kairo default as a C++ default argument
    /// calling its thunk. Kairo fills a default at every call it types, but a
    /// call through a `: type` parameter (`self.dyn()->sc->diag->report(..)
    /// .first(r)`) has no callee to fill from; clang resolves it per instance
    /// and needs the C++ declaration to carry the default.
    prot fn _params(self,
                    f:         unsafe *Declarations::FunctionDecl,
                    with_self: bool,
                    ext:       unsafe *Declarations::ExtensionDecl,
                    scope:     unsafe *Decl = &null,
                    defaults:  bool = false) -> string {
        var s     = ""
        var first = true
        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if p == &null {
                continue
            }

            if p->is_self {
                if !with_self {
                    continue
                }

                if ext == &null {
                    self._ice(
                        p->range,
                        "InterfaceEmitter: `self` outside a type or extension",
                    )
                }

                if !first {
                    s += ", "
                }

                first = false
                // An extension operator is a real non-member C++ operator, and
                // [over.oper]/7 wants a class-typed parameter: the receiver is
                // `X&`. Unnamed here; EmitIR's definition names it.
                s += self._spell->ext_receiver(f, ext)
                if !f->is_operator { // just the type for an operator; EmitIR names it.
                    s += " " + LowerTargets::ext_receiver_name()
                }

                continue
            }

            if !first {
                s += ", "
            }

            first = false
            var nm = ""
            if !p->unname {
                nm = self._spell->tok_name(
                    p->name,
                    Speller::fid_of(unsafe (f as unsafe *Decl)),
                )
            }

            s += self._spell->param_decl(p, nm, &null, scope)
            if defaults {
                s += self._default_arg(f, i)
            }
        }

        // C++ distinguishes postfix `++`/`--` from prefix by an unnamed `int`
        // parameter. Kairo says `op r++`, so the dummy is invented here.
        if Speller::op_is_postfix(f) {
            if !first {
                s += ", "
            }

            s += "int"
        }

        return s
    }

    /// ` = __kairo_default_f_x()` for parameter `i` of `f` when it is the
    /// declaration that wrote a Kairo default (a redeclaration repeating a C++
    /// default is an error, so only the writer's link carries it). Empty
    /// when a later parameter has none: C++ rejects a gap, and a call that
    /// fills it is Kairo's, as before.
    priv fn _default_arg(self, f: unsafe *Declarations::FunctionDecl, i: usize) -> string {
        var unsafe *p = f->params[i]
        if p->default_thunk == &null || !p->default_thunk_home || p->is_pack {
            return ""
        }

        for var k: usize = i + 1; k < f->params.size(); ++k {
            var unsafe *q = f->params[k]
            if q == &null || q->is_pack {
                continue
            }

            if q->default_thunk == &null && !q->has_default {
                return ""
            }
        }

        var unsafe *th   = cast<Declarations::FunctionDecl>(p->default_thunk)
        var        fid   = Speller::fid_of(unsafe (f as unsafe *Decl))
        var        targs = ""
        var        tps   = Speller::template_params(th)
        for var j: usize = 0; j < tps.size(); ++j {
            targs += (if (j == 0) => ("<") else => ", ")
            targs += self._spell->tok_name(tps[j]->name, fid)
            if tps[j]->is_pack {
                targs += "..."
            }
        }

        if tps.size() > 0 {
            targs += ">"
        }

        return " = " + self._spell->leaf(th) + targs + "()"
    }

    prot fn _fn_name(self, f: unsafe *Declarations::FunctionDecl) -> string {
        return self._spell->leaf(unsafe (f as unsafe *Decl))
    }

    priv fn _body_suffix(self, f: unsafe *Declarations::FunctionDecl) -> string {
        match f->body_kind {
            case Declarations::FnBodyKind::Virtual {
                return " = 0"
            } case Declarations::FnBodyKind::Delete {
                return " = delete"
            } case Declarations::FnBodyKind::Default {
                return " = default"
            } default {
                return ""
            }
        }
    }

    /// # Tier 3

    /// `template class X<A>;` in the home TU, `extern template ...` elsewhere.
    /// A function instance spells its signature with the args substituted.
    prot fn _instantiation(self, e: *PlanEntry) {
        var unsafe *d  = e->decl
        var unsafe *ie = e->inst
        // An instance over a value C++ computes (`Buf<twice(1)>`, Compiler/Spec/Eval.md
        // 0.2) may be the very specialization another spelling names
        // (`Buf<2>`), and C++ rejects two explicit instantiations of one: no
        // line; it is instantiated implicitly where used (its bodies are
        // visible, as every template's are).
        for var i: usize = 0; i < ie->args.size(); ++i {
            var unsafe *v = dyn_cast<TypeExpr>(ie->args[i])
            if v != &null && v->is_value && !v->is_exact() {
                return
            }
        }

        // A record under a `<T: type>` parameter is C++-checked per instance:
        // a member body may use an operator T lacks and be an error only for
        // an instance that calls it. `template class X<A>;` instantiates
        // EVERY member, so it would reject (FrozenList<NoEq>::find, never
        // called) what C++ implicit instantiation accepts; its bodies are
        // visible in every TU, so the instance is instantiated implicitly,
        // member by member as used. No `extern template` either: it would
        // suppress that.
        if !isa<Declarations::FunctionDecl>(d) && plan_under_duck(d) {
            return
        }

        var s = if (e->is_home) => ("") else => "extern "
        s += "template "
        if isa<Declarations::FunctionDecl>(d) {
            var unsafe *f = cast<Declarations::FunctionDecl>(d)
            // A result whose set names a type parameter (Compiler/Spec/Panic.md#generic-bodies): C++
            // orders it at this instance through the alias; Sema predicted
            // the canonical result (InstanceEntry::panic_result), which the
            // line below spells. The assert says it in words before the
            // instantiation's own mismatch would.
            if ie->panic_result != &null
                && f->panic_result != &null
                && (f->panic_result->is_dependent()
                    || f->panic_result->is_instantiation_dependent()) {
                self._cg->sink->spell(
                    self._at(d),
                    "static_assert(__is_same(" + self._spell->_type(
                        f->panic_result,
                        ie,
                    ) + ", " + self._spell->_type(
                        ie->panic_result,
                    ) + "), \"C++ ordered this instance's panic set differently from Kairo\");",
                )
            }

            s += self._ret_subst(f, ie)
            // The declarator-id is parenthesized, always: after a
            // class-template return, `Cell<double> ::test::f<...>` lexes as
            // ONE nested-name-specifier, so clang looks for a member `test`
            // inside Cell<double> ("no member named 'test'", "does not refer
            // to a function template"). `long (::test::get<long>)(...)` is
            // equally valid, so there is no case to special.
            s += " ("
            s += self._spell->qual_name(d)
            s += self._spell->args_str(ie->args)
            s += ")("
            // An extension member's receiver is a real first parameter; a
            // method's `self` is `this` and has no slot.
            var unsafe *ext  = DeclFacts::decl_extension_of(d)
            var        first = true
            for var i: usize = 0; i < f->params.size(); ++i {
                var unsafe *p = f->params[i]
                if p == &null {
                    continue
                }

                if p->is_self && ext == &null {
                    continue
                }

                // A pack this instance binds to no element spells no
                // parameter, and takes no separator.
                var one = if (p->is_self) => (self._spell->ext_receiver(
                              f,
                              ext,
                              ie,
                          ))
                          else => self._spell->param_decl(p, "", ie)
                if one.size() == 0 {
                    continue
                }

                if !first {
                    s += ", "
                }

                first = false
                s += one
            }

            s += ")"
            // A const member template's instantiation names the const member:
            // without the qualifier it matches no declaration ("does not refer
            // to a function template"). An extension member is static.
            if ext == &null && f->is_method() && f->is_const() {
                s += " const"
            }

            s += ";"
        } else {
            var kw: string = "struct "
            if d->kind == DeclKind::ClassDecl {
                kw = "class "
            }

            if d->kind == DeclKind::UnionDecl {
                kw = "union "
            }

            s += kw
            s += self._spell->qual_name(d)
            s += self._spell->args_str(ie->args)
            s += ";"
        }

        self._cg->sink->spell(self._at(d), s)
        self._cg->sink->brk()
        self._instance_layout_asserts(d, ie)
        self._instance_spec_assert(d, ie, e->is_home)
        var mas = self._spell->mixin_bound_asserts(d, ie)
        for var i: usize = 0; i < mas.size(); ++i {
            self._cg->sink->spell(self._at(d), mas[i])
            self._cg->sink->brk()
        }

        if e->is_home && !isa<Declarations::FunctionDecl>(d) {
            var bas = self._spell->bound_asserts(d, ie)
            for var i: usize = 0; i < bas.size(); ++i {
                self._cg->sink->spell(self._at(d), bas[i])
                self._cg->sink->brk()
            }
        }
    }

    /// The tag of record `d`'s body when its template has a partial
    /// specialization selected by `requires` (LowerTargets::spec_tag): 0 for
    /// the primary, 1 + the partial's registration index; -1 when no tag is
    /// written. Only such templates carry one: a pattern-only partial is
    /// selected by the same structural match on both sides.
    prot fn _spec_tag(self, d: unsafe *Decl) -> i64 {
        if !(isa<Declarations::ClassDecl>(d)
            || isa<Declarations::StructDecl>(d)
            || isa<Declarations::UnionDecl>(d)) {
            return -1
        }

        if DeclFacts::decl_generic_params(d).size() == 0 {
            return -1
        }

        var unsafe *primary = Speller::rep(d)
        var        k        = DeclFacts::decl_spec_kind(d)
        if k == Declarations::SpecKind::Partial {
            primary = DeclFacts::decl_instantiated_from(d)
            if primary == &null {
                return -1
            }
        } else if k != Declarations::SpecKind::Primary && k != Declarations::SpecKind::None {
            return -1
        }

        var unsafe *ps = self._cg->instances->partials_of(primary)
        if ps == &null {
            return -1
        }

        var any     = false
        var at: i64 = -1
        for var i: usize = 0; i < ps->size(); ++i {
            if DeclFacts::decl_requires_clause((*ps)[i]) != &null {
                any = true
            }

            if Speller::rep((*ps)[i]) == Speller::rep(d) {
                at = (i as i64) + 1
            }
        }

        if !any {
            return -1
        }

        if k == Declarations::SpecKind::Partial {
            return at
        }

        return 0
    }

    /// Beside an instance's explicit instantiation in its home: the body
    /// Sema selected (InstanceEntry::pattern) is the one C++ selected.
    priv fn _instance_spec_assert(self, d: unsafe *Decl, ie: unsafe *InstanceEntry, home: bool) {
        if !home || ie == &null || isa<Declarations::FunctionDecl>(d) {
            return
        }

        var want = self._spec_tag(d)
        if want < 0 {
            return
        }

        if ie->pattern != &null {
            want = self._spec_tag(ie->pattern)
            if want < 0 {
                return
            }
        }

        var x = self._spell->qual_name(d) + self._spell->args_str(ie->args)
        self._cg->sink->spell(
            self._at(d),
            "static_assert(" + x + "::" + LowerTargets::spec_tag() + " == " + f"{want}" + "u, \"C++ selected another specialization than Kairo\");",
        )

        self._cg->sink->brk()
    }

    /// A type-id-tagged instance's elements (the Panic lang item, Compiler/Spec/Panic.md
    /// §1.3): `__kairo_tid<E>` specialized with the id Sema computed
    /// (InstanceEntry::type_ids). Written after tier 0, before anything can
    /// use one: a specialization after a use would be ill-formed. Each is
    /// written once per C++ TU (tid_seen; a header's guarded by its
    /// spelling's key): several instances, and a kcc include chain, share
    /// an element.
    prot fn _type_id_specs(self, d: unsafe *Decl, ie: unsafe *InstanceEntry) {
        var unsafe *en = dyn_cast<Declarations::EnumDecl>(d)
        if en == &null || !en->adt_explicit_tags {
            return
        }

        var p = DeclFacts::adt_pack_param(en)
        if ie == &null {
            return
        }

        if p == usize::MAX || ie->type_ids.size() + p != ie->args.size() {
            self._ice(
                self._at(d),
                "InterfaceEmitter: a type-id-tagged instance without an id per element; EnumLayoutQuery::sweep records them",
            )
        }

        var u      = builtin_info(BuiltinKind::U32)->cxx.copy()
        var header = self._plan->mode() == PlanMode::Header
        for var i: usize = 0; i < ie->type_ids.size(); ++i {
            var key  = ie->type_keys[i]
            var seen = false
            for var j: usize = 0; j < self.tid_seen.size(); ++j {
                if self.tid_seen[j] == key {
                    seen = true
                    break
                }
            }

            if seen {
                continue
            }

            self.tid_seen.push_back(key)
            var g = LowerTargets::type_id_guard(key)
            if header {
                self._cg->sink->directive(self._at(d), "#ifndef " + g)
            }

            if header {
                self._cg->sink->directive(self._at(d), "#define " + g)
            }

            // Its Kairo name too, what the C++ view's what() prints (Compiler/Spec/Panic.md
            // §4.6): one text per element, so every TU's specialization agrees.
            var nm = if (i >= ie->type_names.size()) => ("") else => ie->type_names[i].copy()
            self._cg->sink->spell(
                self._at(d),
                "template <> struct " + LowerTargets::type_id_trait() + "<" + self._spell->_type(
                    ie->args[p + i],
                ) + "> { static constexpr " + u + " value = 0x" + hex32(
                    ie->type_ids[i],
                ) + "u; " + "static constexpr const char* " + LowerTargets::type_id_name() + " = " + Speller::c_string(
                    nm,
                ) + "; };",
            )

            if header {
                self._cg->sink->directive(self._at(d), "#endif")
            }
        }
    }

    /// The layout Sema predicted for a generic ADT's instance
    /// (InstanceEntry::adt_shape / adt_size; EnumLayoutQuery::sweep), pinned
    /// where the instance is named: C++ picks the layout itself (the
    /// specialization's constraint), so a disagreement is a hard error here
    /// instead of Sema reading a field that is not where it thinks. A
    /// niche-filled instance is its payload struct and nothing else, and is
    /// standard-layout, so it is passed and returned as its one field is.
    priv fn _instance_layout_asserts(self, d: unsafe *Decl, ie: unsafe *InstanceEntry) {
        var unsafe *en = dyn_cast<Declarations::EnumDecl>(d)
        if en == &null || !en->is_adt || ie->adt_shape == (AdtShape::Unknown as u8) {
            return
        }

        var x = self._spell->qual_name(d) + self._spell->args_str(ie->args)
        if ie->adt_size != 0 {
            self._cg->sink->spell(
                self._at(d),
                "static_assert(sizeof(" + x + ") == " + f"{ie->adt_size}" + ");",
            )

            self._cg->sink->brk()
        }

        if ie->adt_shape != (AdtShape::NicheFilled as u8) {
            return
        }

        var unsafe *pv = en->variants[adt_niche_payload_variant(en) as usize]
        var ps = x.copy() + "::" + LowerTargets::adt_payload_type(
            self._spell->leaf(pv),
        )

        self._cg->sink->spell(
            self._at(d),
            "static_assert(sizeof(" + x + ") == sizeof(" + ps + ") && __is_standard_layout(" + x + "));",
        )

        self._cg->sink->brk()
    }

    priv fn _ret_subst(self,
                       f:  unsafe *Declarations::FunctionDecl,
                       ie: unsafe *InstanceEntry) -> string {
        if ie != &null && ie->panic_result != &null { // its set at the instance.
            return self._spell->_type(ie->panic_result)
        }

        if f->panic_result != &null { // PanicLowering's result (Compiler/Spec/Panic.md#paniclowering).
            return self._spell->_type(f->panic_result, ie)
        }

        if f->is_noreturn || f->return_type == &null {
            return "void"
        }

        return self._spell->return_spelling(f, ie)
    }
}
