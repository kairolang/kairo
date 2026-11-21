/// --- The Kairo Project ------------------------- Codegen/Emit/Names.k --- ///
///
///   EmitIR, part: names and member chains. A named use spelled from its
///   resolved declaration, and `a.b->c::d` step by step, including the steps
///   only an instance can bind (dependent and duck-typed receivers).
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

import AST::ASTSupport::FrozenList
import AST::DeclFacts::{
    decl_generic_params,
    decl_is_imported,
}
import AST::Kind::TypeKind::TypeKind
import AST::LangItems::LowerTargets
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    AbiKind,
    FieldDecl,
    FunctionDecl,
    GenericParamDecl,
    GenericParamKindBound,
    VariableDecl,
}
import AST::Node::Expressions::{
    BinaryOperatorExpr,
    CallExpr,
    IfExpr,
    ParenExpr,
    SubscriptExpr,
    TypeCastExpr,
    UnaryOperatorExpr,
    UnsafeExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Types::{
    CXXLValueRefType,
    ChainType,
    GenericParamType,
    PointerType,
}
import Codegen::Emit::Calls
import Codegen::Emit::Ctors
import Codegen::Emit::Decls
import Codegen::Emit::EmitIR::EmitIR
import Codegen::Emit::Exprs
import Codegen::Emit::Locals
import Codegen::Emit::Stmts
import Codegen::Spell::Spell
import Codegen::Spell::Spell::Speller
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Token::Token::Token
import Token::TokenKind::{
    TokenKind,
    is_annotation,
    token_kind_to_readable_string,
}
import Token::TokenText::TokenText

extend EmitIR {
    /// A local (param, body var, binder, generic param) is bare: unique by
    /// construction. `self` is the OBJECT in Kairo and `this` / the receiver
    /// parameter is a POINTER in C++, so a value use is `(*this)` /
    /// `(*self)`: bare, `return self` would not compile and `self * 2` in
    /// `extend i32` would be pointer arithmetic. Bare only where the tree
    /// asks for the pointer: a pointer-typed read (ExtensionLowering's
    /// receiver) here, and a chain base in _chain_prefix (`this->x`).
    /// Everything else is qualified from its decl; an overload set here is
    /// an X gate failure.
    prot fn _name(self, n: unsafe *NamedIdentExpr) {
        var unsafe *d = n->resolved_decl
        if d == &null && n->candidate_cell != &null {
            self._ice(
                n->range,
                "EmitIR: unpromoted overload set reached codegen; ExprTyper gate failure",
            )
        }

        if d == &null {
            self._ice(
                n->range,
                "EmitIR: unbound name reached codegen; NameResolution gate failure",
            )
        }

        // A slot of a split constructor: a carried local in either half, a
        // field (named bare) only in S_pre, where the object does not exist.
        var si = self._slot_of(d, self._ci_pre)
        if si != usize::MAX {
            self._cg->sink->spell(
                n->range,
                LowerTargets::ctor_slot_arg() + "." + self._slot_name(
                    si,
                ) + "." + LowerTargets::ctor_slot_get() + "()",
            )

            return
        }

        if self._ci_pre && self._is_self_decl(d) {
            self._ice(
                n->range,
                "EmitIR: `self` before every const field is initialized; CtorInitCheck gate failure",
            )
        }

        if self._is_self_decl(d) {
            if self._is_pointer(unsafe (n as unsafe *Expr)) {
                self._self_ptr(n)
                return
            }

            self._cg->sink->spell(n->range, "(*")
            self._self_ptr(n)
            self._cg->sink->spell(n->range, ")")
            return
        }

        var ur = self._ul_use(d)
        if ur != usize::MAX {
            var obj = self._ul_obj[ur].copy()
            if unsafe (n as unsafe *Expr) == self._ret_move {
                obj = "static_cast<decltype(" + obj + ")&&>(" + obj + ")"
            }

            self._cg->sink->spell(n->range, obj)
            return
        }

        if self._is_local(d) || self._captures_global(self._closure, d) {
            self._local_ref(d, n->name)
            return
        }

        // `|*count|` naming a global: ExprTyper::_capture_view types
        // the name as the `*T` pointer, but ClosureCaptures captures no
        // global (it is named in place), so the body would dereference the
        // global's own value. The pointer the body reads is its address.
        // `|*|` gives a script's top-level `var` the same view in the
        // top-level code. Read off the name the typer marked
        // (capture_ptr), not off the closure's list: a deferred global's
        // reads are rewritten by ScriptLowering into a checked place, whose
        // inner name is the value and must stay so.
        if n->capture_ptr {
            self._cg->sink->spell(
                n->range,
                "(&" + self._spell.qual_name(d) + ")",
            )

            return
        }

        // `f<A>` with no instance to spell (the call or value is dependent)
        // keeps the arguments it was written with: they are A
        // itself, and clang substitutes them per instance. Dropped, a
        // non-deducible `size_of_a<A>()` is "couldn't infer template
        // argument". A generic extension member's C++ arguments are not the
        // written ones (`<ext args..., member args...>`), so it is left out.
        var wa = ""
        if !self._is_extension_member(d) {
            var unsafe *gl = unsafe &n->generic_args
            wa = self._written_args_str(d, gl)
        }

        self._cg->sink->spell(n->range, self._spell.qual_name(d) + wa)
    }

    /// `<A, B>` from the generic arguments `gl` a reference to `d` was
    /// written with, or "" when `d` is no generic function or none were
    /// written. For a reference with no instance only: one with an instance
    /// is spelled from it (every argument, the deduced ones too).
    prot fn _written_args_str(self,
                              d:  unsafe *Decl,
                              gl: unsafe *FrozenList<ChainType::GenericArg>) -> string {
        var unsafe *f = dyn_cast<FunctionDecl>(d)
        if f == &null || f->generic_params.size() == 0 || gl == &null || gl->size() == 0 {
            return ""
        }

        var v = cxx::std::vector<unsafe *Type>()
        for var i: usize = 0; i < gl->size(); ++i {
            var unsafe *ga = gl->get(i)
            if ga->ty == &null || ga->ty->canonical == &null {
                self._ice(
                    f->range,
                    "EmitIR: a written generic argument with no type",
                )
            }

            v.push_back(ga->ty->canonical)
        }

        return self._spell.args_str(v)
    }

    /// The bound's qualifier (`::ns::Base::`), when step `st` on `self`
    /// names a field or non-virtual method Sema found through the bound of
    /// a class that derives its own type parameter (`class <A derives Base>
    /// Hooked derives A`). Unqualified, C++ would look the name up in the
    /// instance's argument first, and a member it declares again would hide
    /// the bound's one Sema chose; qualified, the bound's is the one called.
    /// A virtual method stays unqualified so it still dispatches. Empty for
    /// any other step.
    priv fn _bound_qual(self, st: unsafe *ChainExpr::Step) -> string {
        if st == &null
            || st->resolved_decl == &null
            || self._cur_ext != &null
            || self._cur_fn == &null {
            return ""
        }

        var unsafe *mf = dyn_cast<FunctionDecl>(st->resolved_decl)
        if mf != &null && (mf->abi == AbiKind::Virtual || mf->abi == AbiKind::Override) {
            return ""
        }

        if mf == &null && !isa<FieldDecl>(st->resolved_decl) {
            return ""
        }

        var unsafe *dc = self._cur_fn->semantic_dc
        if dc == &null || !dc->is_type_scope() || dc->dc_owner == &null {
            return ""
        }

        var unsafe *cls = Speller::rep(dc->dc_owner)
        var unsafe *b   = Speller::mixin_bound(cls)
        if b == &null {
            return ""
        }

        var unsafe *mdc = st->resolved_decl->semantic_dc
        if mdc == &null || !mdc->is_type_scope() || mdc->dc_owner == &null {
            return ""
        }

        if Speller::rep(mdc->dc_owner) == cls {
            return ""
        }

        return self._spell._type(b) + "::"
    }

    /// `self` as C++ has it: `this` in a method, the receiver parameter in an
    /// extension member. Always the pointer.
    priv fn _self_ptr(self, n: unsafe *NamedIdentExpr) {
        self._cg->sink->spell(n->range, (if (self._cur_ext != &null) => (LowerTargets::ext_receiver_name()) else => "this"))
    }

    /// `::` steps collapse to the qualified name of the last scope-resolved
    /// entity (aliases vanish); value steps emit `.`/`->` from the base's
    /// canonical. An extension member arrives as a plain call, receiver
    /// first; a step naming one here ICEs.
    prot fn _chain(self, n: unsafe *ChainExpr) {
        self._chain_prefix(n, n->steps.size())
    }

    /// Emit the chain up to (not including) step `upto`. Returns true when
    /// the emitted value is a pointer (the next step would be `->`).
    prot fn _chain_prefix(self, n: unsafe *ChainExpr, upto: usize) -> bool {
        var k            = self._last_scope_step(n, upto)
        var i:     usize = 0
        var is_ptr       = false
        if k != usize::MAX
            && n->base != &null
            && n->steps.get(k)->resolved_decl == &null
            && self._dependent_step(n, n->steps.get(k)) {
            // `T::classof(n)` under `<T: type>`: a static member of a type
            // only the instance knows, written through the parameter. As
            // written, `T::f`, and clang looks it up per instance.
            self.emit(n->base)
            for var j: usize = 0; j <= k; ++j {
                self._dependent_member_named(n->steps.get(j), "::")
            }

            i = k + 1
        } else if k != usize::MAX && self._foreign_dependent_scope(n, k) != &null {
            // `cxx::std::is_trivially_destructible<T>::value`: a member
            // MemberTyping left to each instance of a C++ class template over
            // a Kairo parameter. Spelled through the instance as written, and
            // clang looks it up per instantiation.
            self._cg->sink->spell(
                n->steps.get(k)->range,
                self._spell._type(self._foreign_dependent_scope(n, k), &null),
            )

            self._dependent_member_named(n->steps.get(k), "::")
            i = k + 1
        } else if k != usize::MAX {
            var unsafe *st = n->steps.get(k)
            if st->resolved_decl == &null {
                self._ice(
                    st->range,
                    "EmitIR: unbound `::` step reached codegen; ChainBinding gate failure",
                )
            }

            // A member of a type named through a generic instance
            // (`L<i32>::Color::Green`): qualified through that
            // type, since the plain qualified name `::ns::L::Color` names
            // the template without its arguments.
            // A static member named through an instance (`Box<i32>::count`)
            // has it on the step (ChainExpr::Step::through), which also
            // covers a head with no earlier step to read it from.
            var pt: unsafe *Type = &null
            if k > 0 {
                pt = n->steps.get(k - 1)->resolved_type
            }

            var unsafe *pr = if (pt != &null && pt->canonical != &null) => (dyn_cast<RecordType>(
                                 canon_unqual(pt->canonical),
                             ))
                             else => &null
            // `G<A>::f<B>` / `ns::f<B>` with no instance (a dependent call or
            // a function value): the written arguments, behind
            // `template` when the qualifier is dependent.
            var wa = ""
            if k + 1 == n->steps.size() {
                wa = self._written_args_str(
                    st->resolved_decl,
                    unsafe &st->generic_args,
                )
            }

            if st->witness_iface != &null {
                // `A::make` as a VALUE, A bounded: the witness's static
                // member, as a `::` call spells it (_call); the requirement
                // itself is no C++ function.
                self._cg->sink->spell(
                    st->range,
                    self._witness_member(
                        st->witness_iface,
                        st->witness_self,
                        cast<FunctionDecl>(st->resolved_decl),
                        wa,
                    ),
                )
            } else if st->through != &null {
                var tk = if (wa.size() > 0 && st->through->is_dependent()) => ("template ")
                         else => ""
                self._cg->sink->spell(
                    st->range,
                    self._spell._type(st->through, &null) + "::" + tk + self._spell.leaf(
                        st->resolved_decl,
                    ) + wa,
                )
            } else if pr != &null && pr->outer != &null {
                var tk = if (wa.size() > 0 && pt->is_dependent()) => ("template ") else => ""
                self._cg->sink->spell(
                    st->range,
                    self._spell._type(pt, &null) + "::" + tk + self._spell.leaf(
                        st->resolved_decl,
                    ) + wa,
                )
            } else {
                self._cg->sink->spell(
                    st->range,
                    self._spell.qual_name(st->resolved_decl) + wa,
                )
            }

            is_ptr = self._type_is_pointer(st->resolved_type)
            i      = k + 1
        } else {
            if n->base == &null {
                self._ice(
                    n->range,
                    "EmitIR: global-root chain with no `::` step",
                )
            }

            // `self.x` is `this->x`: the base is the pointer, not _name's
            // value form `(*this)`. In a split constructor's S_pre the object
            // is not built yet: `self.x` is x's slot (file header), and only
            // a base's field, built before S_pre runs, is `this->x`.
            var pre_slot = self._ci_pre
                && self._base_is_self(n->base)
                && !(upto > 0 && self._base_field_step(n->steps.get(0)))
            if pre_slot {
                if upto == 0 {
                    self._ice(
                        n->range,
                        "EmitIR: `self` before every const field is initialized; CtorInitCheck gate failure",
                    )
                }

                var unsafe *st0 = n->steps.get(0)
                var        s0   = self._slot_of(st0->resolved_decl, true)
                if s0 == usize::MAX {
                    self._ice(
                        st0->range,
                        "EmitIR: a field S_pre never assigns read before the object exists; CtorInitCheck gate failure",
                    )
                }

                self._cg->sink->spell(
                    st0->range,
                    LowerTargets::ctor_slot_arg() + "." + self._slot_name(
                        s0,
                    ) + "." + LowerTargets::ctor_slot_get() + "()",
                )

                is_ptr = self._type_is_pointer(st0->resolved_type)
                i      = 1
            } else {
                if self._base_is_self(n->base) {
                    self._self_ptr(cast<NamedIdentExpr>(n->base))
                } else if self._dot_on_unknown_call(n, i, upto) {
                    // `b.first(r).note(m)` in a duck body: `first`'s result
                    // is whatever the instance returns, a value or (Kairo's
                    // `.` derefs either) a pointer, and C++ needs `.` or
                    // `->` to match. The lambda yields the object either way.
                    self._cg->sink->spell(
                        n->base->range,
                        "([](auto&& __kv) -> decltype(auto) { if constexpr (__is_pointer(__remove_cvref(decltype(__kv)))) { return (*__kv); } else { return (__kv); } }(",
                    )

                    self.emit(n->base)
                    self._cg->sink->spell(n->base->range, "))")
                } else {
                    self.emit(n->base)
                }

                is_ptr = self._base_is_self(n->base)
                    || !self._dot_on_unknown_call(n, i, upto) && self._is_pointer(n->base)
            }
        }

        for var j: usize = i; j < upto; ++j {
            var unsafe *st = n->steps.get(j)
            if st->access_kind == ChainExpr::AccessKind::ColonColon {
                self._ice(st->range, "EmitIR: `::` after a value step")
            }

            if st->access_kind == ChainExpr::AccessKind::QuestionDot
                || st->access_kind == ChainExpr::AccessKind::QuestionArrow {
                self._ice(
                    st->range,
                    "EmitIR: optional chaining; CoalesceLowering owns it",
                )
            }

            if st->is_operator() {
                var onm = self._spell.leaf(st->resolved_decl)
                // A generic `op as -> T` called through an instance: the
                // target OperatorLowering bound (the template's `operator T`
                // has no T here).
                var unsafe *ocf = dyn_cast<FunctionDecl>(st->resolved_decl)
                if ocf != &null
                    && ocf->is_operator
                    && ocf->op_token.size() > 0
                    && ocf->op_token[0].kind == TokenKind::KwAs
                    && st->resolved_type != &null {
                    onm = "operator " + self._spell._type(st->resolved_type)
                }

                self._cg->sink->spell(
                    st->range,
                    (if (is_ptr) => ("->") else => ".") + onm,
                )

                is_ptr = false
                continue
            }

            if st->is_tuple_index() {
                self._ice(
                    st->range,
                    "EmitIR: tuple index step; TupleLowering owns it",
                )
            }

            if self._is_extension_member(st->resolved_decl) {
                self._ice(
                    st->range,
                    "EmitIR: extension member used as a value; ExtensionLowering rewrites the call form",
                )
            }

            if st->resolved_decl == &null && self._dependent_step(n, st) {
                self._dependent_member(st, is_ptr)
                is_ptr = false
                continue
            }

            if st->resolved_decl == &null {
                self._ice(
                    st->range,
                    "EmitIR: unbound member step reached codegen; gate failure",
                )
            }

            // A written `->` on a record (Sema accepts it only through the
            // record's `op ->`, Substitution::arrow_target) stays `->`: C++
            // calls the class's operator-> for it.
            var sep_arrow = is_ptr || st->access_kind == ChainExpr::AccessKind::Arrow
            var bq = if (j == i && j == 0 && self._base_is_self(n->base)) => (self._bound_qual(
                         st,
                     ))
                     else => ""
            self._cg->sink->spell(
                st->range,
                (if (sep_arrow) => ("->") else => ".") + bq,
            )

            self._name(st->name->name)
            // A pack-expanded variant's member holds one payload per element:
            // element K is its getter's (EnumLayoutQuery::payload_ref).
            if st->pack_index >= 0 {
                self._cg->sink->spell(
                    st->range,
                    ".template " + LowerTargets::adt_pack_get() + "<" + f"{st->pack_index}" + ">()",
                )
            }

            is_ptr = self._type_is_pointer(st->resolved_type)
        }

        return is_ptr
    }

    /// Step `i` of `n` is a `.` member the instance resolves, on a call
    /// whose result type only the instance knows: whether that result is a
    /// pointer decides `.` against `->`, and Sema cannot say.
    priv fn _dot_on_unknown_call(self, n: unsafe *ChainExpr, i: usize, upto: usize) -> bool {
        if i >= upto || i >= n->steps.size() || n->base == &null {
            return false
        }

        var unsafe *st = n->steps.get(i)
        if st->resolved_decl != &null || st->access_kind != ChainExpr::AccessKind::Dot {
            return false
        }

        if !isa<CallExpr>(self._strip(n->base)) {
            return false
        }

        var unsafe *bt = n->base->type_
        if bt != &null && !bt->is_dependent() && !bt->is_instantiation_dependent() {
            return false
        }

        return self._dependent_step(n, st)
    }

    /// A member step Sema left unbound ON PURPOSE: the chain is dependent
    /// and its first unbound step goes through a `<T: type>` parameter, so
    /// the step names a member of a type only the instance knows (Compiler/Spec/Generics.md
    /// D1). Anything else unbound still ICEs: a bounded body is Kairo's to
    /// check (D0), and an unbound step there (a bound call's dependent
    /// result, `c.get(1).w`) is a Sema gap, not a request for clang.
    prot fn _dependent_step(self, n: unsafe *ChainExpr, st: unsafe *ChainExpr::Step) -> bool {
        if st->name == &null || st->name->is_poisoned() {
            return false
        }

        // A chain through a duck-deduced local (`tail = tail->next`) is not
        // flagged dependent: Sema only knows its base's type is inferred.
        // The local is `auto` (_duck_local), so the step is the instance's.
        var via_local = n->base != &null
            && isa<NamedIdentExpr>(n->base)
            && self._duck_local(cast<NamedIdentExpr>(n->base)->resolved_decl)
        var k = st->access_kind
        if k != ChainExpr::AccessKind::Dot
            && k != ChainExpr::AccessKind::Arrow
            && k != ChainExpr::AccessKind::ColonColon {
            return false
        }

        // A member of a C++ class template instance over a Kairo parameter
        // (`self.v.push_back(x)` on a `vector<T>`): bound to its
        // overload set but left to each instance (OverloadResolution), so
        // spelled as written, as clang resolves a dependent call. The
        // dependent receiver is the evidence; the typer marks the CALL
        // unknown, not the callee chain.
        if st->candidate_cell != &null {
            return st == self._arg_dep_step || self._foreign_dependent_receiver(n, st)
        }

        if !n->is_instantiation_dependent() && !via_local {
            return false
        }

        return self._duck_rooted(n)
    }

    /// The receiver of step `st` of `n` is a dependent instance of an
    /// imported class template (or a pointer to one).
    priv fn _foreign_dependent_receiver(self,
                                        n:  unsafe *ChainExpr,
                                        st: unsafe *ChainExpr::Step) -> bool {
        var recv: unsafe *Type = if (n->base != &null) => (n->base->type_) else => &null
        for var i: usize = 0; i < n->steps.size(); ++i {
            var unsafe *s0 = n->steps.get(i)
            if s0 == st {
                break
            }

            recv = s0->resolved_type
        }

        return self._dependent_foreign_type(recv)
    }

    /// `recv` is a dependent instance of an imported class template, a
    /// reference to one, or a pointer to one.
    prot fn _dependent_foreign_type(self, recv: unsafe *Type) -> bool {
        if recv == &null {
            return false
        }

        var unsafe *c = canon_unqual(
            if (recv->canonical != &null) => (recv->canonical) else => recv,
        )

        if c != &null && isa<CXXLValueRefType>(c) {
            c = canon_unqual(cast<CXXLValueRefType>(c)->referee)
        }

        if c != &null && isa<PointerType>(c) {
            var unsafe *pt = cast<PointerType>(c)->pointee
            c = if (pt != &null) => (canon_unqual(
                    if (pt->canonical != &null) => (pt->canonical) else => pt,
                ))
                else => &null
        }

        if c == &null || !isa<RecordType>(c) || !c->is_dependent() {
            return false
        }

        return decl_is_imported(cast<RecordType>(c)->decl)
    }

    /// Whether `n`'s first unbound step is reached through a `: type`
    /// parameter: the base names the parameter itself (`T::f`), or the
    /// receiver of that step has the parameter's type, or points to it
    /// (`t.f`, `d->f`). Steps after it hang off a result only the instance
    /// knows, so they go with it.
    priv fn _duck_rooted(self, n: unsafe *ChainExpr) -> bool {
        var recv: unsafe *Type = &null
        if n->base != &null {
            var unsafe *ni = dyn_cast<NamedIdentExpr>(n->base)
            if ni != &null
                && ni->resolved_decl != &null
                && isa<GenericParamDecl>(ni->resolved_decl) {
                return cast<GenericParamDecl>(
                    ni->resolved_decl,
                )->kind_bound == GenericParamKindBound::Duck
            }

            recv = n->base->type_
        }

        for var i: usize = 0; i < n->steps.size(); ++i {
            var unsafe *st = n->steps.get(i)
            if st->resolved_decl == &null {
                // `t.inner().w`: the base is itself an unknown duck call, so
                // `.w` hangs off it like a later step of one chain.
                if i == 0 && recv == &null && n->base != &null {
                    return self._duck_rooted_expr(n->base)
                }

                if recv == &null && i > 0 && self._duck_local(n->steps.get(i - 1)->resolved_decl) {
                    return true
                }

                return self._is_duck_param_type(recv)
            }

            recv = st->resolved_type
        }

        return false
    }

    /// An unknown expression that is a duck chain, or a call through one.
    prot fn _duck_rooted_expr(self, e: unsafe *Expr) -> bool {
        var unsafe *c = dyn_cast<CallExpr>(e)
        // A call Sema left untyped because an argument is dependent
        // (`self.prec_of(cur)`, `cur` deduced from a duck call): its result is
        // the instance's, so a local initialised from it is `auto` too.
        if c != &null && c->type_ == &null && c->is_instantiation_dependent() {
            return true
        }

        if c != &null {
            e = c->callee
        }

        // `unsafe &self.dyn()->frames[i]`: the address of / index into
        // a duck chain is the instance's too, so a local initialised from it
        // is `auto` and its member steps go with the instance.
        var unsafe *ue = dyn_cast<UnsafeExpr>(e)
        if ue != &null {
            return self._duck_rooted_expr(ue->operand)
        }

        var unsafe *tc = dyn_cast<TypeCastExpr>(e)
        if tc != &null {
            return self._duck_rooted_expr(tc->operand)
        }

        var unsafe *pe = dyn_cast<ParenExpr>(e)
        if pe != &null {
            return self._duck_rooted_expr(pe->inner)
        }

        var unsafe *uo = dyn_cast<UnaryOperatorExpr>(e)
        if uo != &null {
            return self._duck_rooted_expr(uo->operand)
        }

        // `m.flag != Kind::None` with a duck operand: C++ types the result.
        var unsafe *be = dyn_cast<BinaryOperatorExpr>(e)
        if be != &null {
            return self._duck_rooted_expr(be->lhs) || self._duck_rooted_expr(be->rhs)
        }

        var unsafe *se = dyn_cast<SubscriptExpr>(e)
        // `self.ops[j].kind`: an element of a C++ vector whose argument
        // is a record nested in a generic class is the instance's, since
        // `vector<Op>` is instantiation-dependent and so is its operator[].
        if se != &null {
            return self._duck_rooted_expr(se->base) || self._dependent_foreign_type(se->base->type_)
        }

        // `if (x != &null) => (cast<T>(x)) else => &null` (O26b): an arm that
        // is the instance's makes the whole conditional the instance's; the
        // `&null` arm has no type of its own to contradict that.
        var unsafe *ie = dyn_cast<IfExpr>(e)
        if ie != &null {
            if self._duck_rooted_expr(ie->then_expr) || self._duck_rooted_expr(ie->else_expr) {
                return true
            }

            for var i: usize = 0; i < ie->else_ifs.size(); ++i {
                if self._duck_rooted_expr(ie->else_ifs.get(i)->body) {
                    return true
                }
            }

            return false
        }

        // A local deduced from a duck chain (`var head = prev->first`, prev a
        // `: type` parameter's pointer) has no type until the instance; it is
        // emitted `auto`, so a step through it is the instance's to look up
        // like any later step of the chain it came from. Without this the
        // step was an "unbound member step" ICE (Redeclarable::set_prev).
        var unsafe *ni = dyn_cast<NamedIdentExpr>(e)
        if ni != &null {
            return self._duck_local(ni->resolved_decl)
        }

        var unsafe *ch = dyn_cast<ChainExpr>(e)
        if ch == &null {
            return false
        }

        return ch->is_instantiation_dependent() && self._duck_rooted(ch)
    }

    /// `d` is a local with no type of its own, deduced from a duck chain:
    /// emitted `auto`, so what it holds is the instance's (as a name base,
    /// `tail->next`, or as the head step of a chain the parser left baseless).
    priv fn _duck_local(self, d: unsafe *Decl) -> bool {
        var unsafe *vd = dyn_cast<VariableDecl>(d)
        if vd == &null {
            return false
        }

        // `var m: T::Pending;`: declared, but its type is the instance's.
        if vd->type_ != &null
            && vd->type_->canonical == &null
            && self._spell.dependent_member(vd->type_).size() > 0 {
            return true
        }

        if vd->type_ != &null || vd->init == &null {
            return false
        }

        return self._duck_rooted_expr(vd->init)
    }

    /// `t` is a `: type` parameter, or a pointer to one.
    priv fn _is_duck_param_type(self, t: unsafe *Type) -> bool {
        if t == &null {
            return false
        }

        // `var m: T::Pending;` has no canonical type until an instance names
        // T: a member type of the parameter, so what its fields are is the
        // instance's, exactly as for `t.f`.
        if t->canonical == &null && self._spell.dependent_member(t).size() > 0 {
            return true
        }

        var unsafe *c = t->canonical
        if c == &null {
            c = t
        }

        c = canon_unqual(c)
        if c != &null && c->kind == TypeKind::PointerType {
            var unsafe *pt = cast<PointerType>(c)->pointee
            if pt == &null {
                return false
            }

            c = pt->canonical
            if c == &null {
                c = pt
            }

            c = canon_unqual(c)
        }

        if c == &null {
            return false
        }

        var unsafe *g = dyn_cast<GenericParamType>(c)
        if g == &null || g->owner == &null {
            return false
        }

        var gps = decl_generic_params(g->owner)
        if (g->param_index as usize) >= gps.size() {
            return false
        }

        var unsafe *gp = gps[g->param_index as usize]
        return gp != &null && gp->kind_bound == GenericParamKindBound::Duck
    }

    /// A dependent member step spelled as written, for clang to look up in
    /// each instance (Compiler/Spec/Generics.md#duck-regime): `.f` / `->f`, and `.template f<A...>` when
    /// it carries generic arguments, since the object's type is dependent.
    /// The separator is the receiver's when its type is known to be a
    /// pointer, else the one the user wrote; past the first unbound step the
    /// type is the instance's, so a later step can only go by the spelling.
    priv fn _dependent_member(self, st: unsafe *ChainExpr::Step, is_ptr: bool) {
        var arrow = is_ptr || st->access_kind == ChainExpr::AccessKind::Arrow
        self._dependent_member_named(st, (if (arrow) => ("->") else => "."))
    }

    /// `sep`, then the step's name as written, `template name<A...>` when it
    /// carries generic arguments (the scope is dependent, so C++ needs the
    /// keyword to read `<` as an argument list).
    /// The dependent C++ class template instance whose member step `k` of
    /// `n` names, when MemberTyping left that member to each instance
    /// (unbound, the expression instantiation-dependent, the step before it
    /// bound to an imported record over a parameter); else null.
    priv fn _foreign_dependent_scope(self, n: unsafe *ChainExpr, k: usize) -> unsafe *Type {
        if k == 0 || !n->is_instantiation_dependent() {
            return &null
        }

        var unsafe *st = n->steps.get(k)
        if st->resolved_decl != &null
            || st->candidate_cell != &null
            || st->name == &null
            || st->name->is_poisoned() {
            return &null
        }

        var unsafe *pt = n->steps.get(k - 1)->resolved_type
        if pt == &null {
            return &null
        }

        var unsafe *c = canon_unqual(
            if (pt->canonical != &null) => (pt->canonical) else => pt,
        )

        if c == &null || !isa<RecordType>(c) || !c->is_dependent() {
            return &null
        }

        if !decl_is_imported(cast<RecordType>(c)->decl) {
            return &null
        }

        return c
    }

    priv fn _dependent_member_named(self, st: unsafe *ChainExpr::Step, const sep: string) {
        self._cg->sink->spell(st->range, sep)
        if st->name == &null {
            self._ice(st->range, "EmitIR: a dependent member step with no name")
        }

        if st->generic_args.size() == 0 {
            self._name(st->name->name)
            return
        }

        self._cg->sink->spell(st->range, "template ")
        self._name(st->name->name)
        var s = "<"
        for var i: usize = 0; i < st->generic_args.size(); ++i {
            if i > 0 {
                s += ", "
            }

            var unsafe *ga = st->generic_args.get(i)
            if ga->ty == &null {
                self._ice(
                    st->range,
                    "EmitIR: a dependent member's generic argument with no type",
                )
            }

            s += self._spell._type(ga->ty)
        }

        s += ">"
        self._cg->sink->spell(st->range, s)
    }

    /// Index of the last `::` step before `upto`, or usize(-1).
    priv fn _last_scope_step(self, n: unsafe *ChainExpr, upto: usize) -> usize {
        var last = usize::MAX
        for var j: usize = 0; j < upto; ++j {
            if n->steps.get(j)->access_kind == ChainExpr::AccessKind::ColonColon {
                last = j
            }
        }

        return last
    }

    priv fn _is_pointer(self, e: unsafe *Expr) -> bool {
        if e == &null {
            return false
        }

        return self._type_is_pointer(e->type_)
    }

    /// An identifier is spelled from its IMM, never borrowed: TokenSink takes
    /// an identifier's spelling from the IdentifierInfo and its length is
    /// caret geometry, so the bytes at the range buy nothing -- and a token a
    /// lowering minted sits on bytes that are something else entirely. The imm
    /// indexes the table of the file that owns the body being emitted, which
    /// for a foreign template homed here is not this TU's.
    prot fn _name(self, t: Token) {
        // A name that came through a macro (a `crash!(why)` argument) is a
        // TkMacroExpand token: its imm is the expansion record, and read as
        // an identifier against the owning file's table it is some other
        // name (`why` printed as `io`). Unwrap the chain to the spelling.
        if (t.kind as u32) == (TokenKind::TkMacroExpand as u32) {
            var txt = TokenText::resolve(t, self._cg->ctx->tcm).text
            self._cg->sink->create_ident(t.range, txt)
            return
        }

        // A primitive type's name used as a local's name (`var u8 = ...`)
        // has no identifier to spell: Sema does not yet decide whether such
        // a name is legal, so the compile stops here with an error at it.
        if is_annotation(t.kind) && t.kind != TokenKind::AtComment {
            var kw = token_kind_to_readable_string(t.kind)
            self._cg->ctx->diag_sink.report(
                DiagCode(DiagID::U001E),
                t.range.start,
                f"'{kw}' is the name of a primitive type and cannot be emitted as the name of a declaration; choose another name",
            ).first(t.range)->emit()
            self._cg->sink->create_ident(t.range, kw)
            return
        }

        var spelled = self._spell.tok_name(t, self._owning_fid())
        if spelled == "<?>" {
            self._ice(
                t.range,
                "EmitIR: identifier token with no spelling in its owning file's table",
            )
        }

        self._cg->sink->create_ident(t.range, spelled)
    }
}
