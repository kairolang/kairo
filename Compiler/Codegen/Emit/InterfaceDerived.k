/// --- The Kairo Project -------------- Codegen/Emit/InterfaceDerived.k --- ///
///
///   InterfaceEmitter, part: derived members. What a record holds with no
///   Kairo declaration of its own: the derived comparisons and assignment
///   (destroy, then rebuild through placement `::new`), anonymous union fields
///   and pack unions, the eval helpers a record's members need, and the
///   large string constants eval values are spelled with
///   (EmitPlan::big_strs).
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

import AST::DeclFacts
import AST::LangItems::LowerTargets
import AST::Node::Base::{
    Decl,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    builtin_info,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::OperatorFacts::OperatorFacts
import Codegen::Emit::InterfaceEmitter::InterfaceEmitter
import Codegen::Emit::InterfaceEnums
import Codegen::Emit::InterfaceRecords
import Codegen::Emit::Spell::Speller
import Codegen::EmitPlan::{
    PlanMode,
    PlanTier,
}
import Location::SourceRange::SourceRange
import Token::TokenKind::TokenKind

extend InterfaceEmitter {
    /// Some class this run writes carries an `op =` that rebuilds in place
    /// (Body, Constrained): tier 1, and the records _record_def nests in
    /// those. A header skips what it includes, as run() does.
    /// An `eval for` in this TU, or an eval generator the plan declares or
    /// defines here: both spell the eval helpers.
    /// So does a compile-time string (`__kairo_estr`, Compiler/Spec/Eval.md#strings-at-compile-time): this TU
    /// spelled one, or a body or constant it emits from elsewhere may (an
    /// eval fn, an eval binding, a record with eval members). Which foreign
    /// body holds a literal is not known here, so any eval entry counts.
    /// `inline constexpr unsigned char __kairo_estrh_<len>_<hash>[len + 1] =
    /// {b..., 0};` for each long compile-time string the plan holds
    /// (EmitPlan::big_strs, Compiler/Spec/Eval.md#value-nodes), at global scope. `inline` and
    /// named for its content, so every TU and header that writes one writes
    /// the same entity, which the linker keeps once; a header guards each
    /// (two Kairo headers in one C++ TU), an include stream skips what an
    /// earlier include wrote (estr_seen).
    prot fn _big_strs(self, header: bool) {
        var n = self._plan->big_strs.size()
        if n == 0 {
            return
        }

        self._cg->sink->unanchored(true)
        for var i: usize = 0; i < n; ++i {
            var        h    = self._plan->big_strs[i].hash
            var        len  = self._plan->big_strs[i].len
            var unsafe *p   = self._plan->big_strs[i].bytes
            var        seen = false
            for var k: usize = 0; k < self.estr_seen.size(); ++k {
                if self.estr_seen[k] == h {
                    seen = true
                    break
                }
            }

            if seen {
                continue
            }

            self.estr_seen.push_back(h)
            var g = LowerTargets::eval_str_hashed_guard(h, len)
            if header {
                self._cg->sink->directive(self._tu_at(), "#ifndef " + g)
            }

            if header {
                self._cg->sink->directive(self._tu_at(), "#define " + g)
            }

            var s = "inline constexpr unsigned char " + LowerTargets::eval_str_hashed(
                h,
                len,
            ) + "[" + f"{len + 1}" + "] = {"
            for var b: usize = 0; b < len; ++b {
                s += f"{(p[b] as u32)}, "
            }

            s += "0};"
            self._cg->sink->spell(self._tu_at(), s)
            self._cg->sink->brk()
            if header {
                self._cg->sink->directive(self._tu_at(), "#endif")
            }
        }

        self._cg->sink->unanchored(false)
    }

    prot fn _needs_eval_helpers(self) -> bool {
        if self._cg->tu != &null && (self._cg->tu->has_eval_for || self._cg->tu->has_eval_string) {
            return true
        }

        if self._plan->needs_eval_str {
            return true
        }

        for var i: usize = 0; i < self._plan->entries.size(); ++i {
            var unsafe *d = self._plan->entries[i].decl
            var unsafe *f = dyn_cast<Declarations::FunctionDecl>(d)
            if f != &null && f->is_eval() {
                return true
            }

            var unsafe *v = dyn_cast<Declarations::VariableDecl>(d)
            if v != &null && v->is_eval() {
                return true
            }

            if self._has_eval_member(d) {
                return true
            }
        }

        return false
    }

    priv fn _has_eval_member(self, d: unsafe *Decl) -> bool {
        var ms = DeclFacts::decl_methods(d)
        for var i: usize = 0; i < ms.size(); ++i {
            var unsafe *m = ms[i]
            if m != &null && m->is_eval() {
                return true
            }
        }

        return false
    }

    prot fn _needs_new(self) -> bool {
        var header = self._plan->mode() == PlanMode::Header
        for var i: usize = 0; i < self._plan->entries.size(); ++i {
            var *e = &self._plan->entries[i]
            if e->tier != PlanTier::Definitions
                || e->scope != &null
                || e->witness != &null
                || e->eval_item != &null {
                continue
            }

            if header && !e->own {
                continue
            }

            if self._rebuilds(e->decl) {
                return true
            }
        }

        return false
    }

    priv fn _rebuilds(self, d: unsafe *Decl) -> bool {
        var form = self._assign_form_of(d)
        if form == Declarations::AssignForm::Body || form == Declarations::AssignForm::Constrained {
            return true
        }

        if (!isa<Declarations::ClassDecl>(d)) && !isa<Declarations::StructDecl>(d) {
            return false
        }

        var unsafe *dc = Speller::dc_of(d)
        if dc == &null {
            return false
        }

        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *nd = *dc->dc_decls.get(i)
            if nd == &null || isa<Declarations::VisibilityGroupDecl>(nd) || !self._is_type(nd) {
                continue
            }

            if self._rebuilds(Speller::rep(nd)) {
                return true
            }
        }

        return false
    }

    /// The six comparisons OperatorTyping derives from a member `op <=>`,
    /// written into the class so a C++ host sees what a Kairo caller does.
    /// C++20 cannot find them itself: it rewrites `a < b` as `(a <=> b) < 0`,
    /// which `Ordering` -- a scoped enum, not a comparison category -- cannot
    /// answer, and it never derives `==` from a user `<=>` at all. Each is
    /// `bool operator<(<other>) [const] { return static_cast<signed char>(
    /// this->operator<=>(o)) < 0; }`, the operand and cv the `<=>`'s own, in
    /// the class (invariant 12's exception, as the derived `op =`), with the
    /// `<=>`'s access and anchored on it. A comparison the record declares
    /// is its own and wins in Kairo (OperatorSignatureCheck warns), so it is
    /// not written; nor is `!=` beside a declared `==`, which C++20 rewrites
    /// exactly as Kairo derives it. A generic `<=>` has no one operand to
    /// spell and derives nothing here. Returns the access in force.
    prot fn _derived_cmps(self, d: unsafe *Decl, cur: u8, at: SourceRange) -> u8 {
        var methods  = DeclFacts::decl_methods(d)
        var has_eq   = false
        var declared = cxx::std::vector<TokenKind>()
        for var i: usize = 0; i < methods.size(); ++i {
            var unsafe *m = methods[i]
            if m == &null || !m->is_operator {
                continue
            }

            var k = OperatorFacts::op_kind(m)
            // `not_eq` is `!=` to C++.
            if k == TokenKind::KwNotEq {
                k = TokenKind::OpExclaimEqual
            }

            if k == TokenKind::OpEqualEqual {
                has_eq = true
            }

            declared.push_back(k)
        }

        var ops = cxx::std::vector<TokenKind>()
        ops.push_back(TokenKind::OpLess)
        ops.push_back(TokenKind::OpLessEqual)
        ops.push_back(TokenKind::OpGreater)
        ops.push_back(TokenKind::OpGreaterEqual)
        ops.push_back(TokenKind::OpEqualEqual)
        ops.push_back(TokenKind::OpExclaimEqual)
        var syms = cxx::std::vector<string>()
        syms.push_back("<")
        syms.push_back("<=")
        syms.push_back(">")
        syms.push_back(">=")
        syms.push_back("==")
        syms.push_back("!=")

        var acc = cur
        var sc8 = builtin_info(BuiltinKind::I8)->cxx
        for var i: usize = 0; i < methods.size(); ++i {
            var unsafe *m = methods[i]
            if m == &null || !m->is_operator || !m->is_method() {
                continue
            }

            if OperatorFacts::op_kind(m) != TokenKind::OpLessEqualGreater {
                continue
            }

            if self._spell->template_head(unsafe (m as unsafe *Decl)).size() > 0 {
                continue
            }

            // A panicking one returns a panic result, which no comparison
            // against 0 can read. Kairo's own `<` holds and tests the call
            // (PanicLowering); a C++ caller gets the `<=>` alone.
            if m->panic_result != &null {
                continue
            }

            var other: unsafe *Declarations::ParamDecl = &null
            for var j: usize = 0; j < m->params.size(); ++j {
                var unsafe *p = m->params[j]
                if p != &null && !p->is_self {
                    other = p
                    break
                }
            }

            if other == &null { // OperatorSignatureCheck rejected it already.
                continue
            }

            var mat   = self._at(m)
            var param = self._spell->param_decl(other, "o", &null, d)
            var quals = ""
            if m->is_const() {
                quals += " const"
            }

            if m->no_unwind {
                quals += " noexcept"
            }

            // Forwarded as the `<=>` takes it: a by-value or `&&` operand
            // is an lvalue `o` here and must be moved on.
            var call = "static_cast<" + sc8 + ">(this->" + self._spell->leaf(
                m,
            ) + "(static_cast<decltype(o)&&>(o)))"
            for var j: usize = 0; j < ops.size(); ++j {
                var k    = ops[j]
                var mine = false
                for var q: usize = 0; q < declared.size(); ++q {
                    if declared[q] == k {
                        mine = true
                        break
                    }
                }

                if mine {
                    continue
                }

                if k == TokenKind::OpExclaimEqual && has_eq {
                    continue
                }

                acc = self._access(acc, self._cxx_vis(m), false, at)
                self._cg->sink->spell(
                    mat,
                    "bool operator" + syms[j] + "(" + param + ")" + quals + " { return " + call + " " + syms[j] + " 0; }",
                )
            }
        }

        return acc
    }

    /// `X& operator=(...)`, as ClassLifecycle chose it (AssignForm). The
    /// operand is the transfer constructor's own `other`, so the
    /// constructor takes it exactly: `const X&` from `@copy fn X(self,
    /// const other: Self)`, `X&` without the `const`, `X&&` from `@move`.
    /// Anchored on the constructor, which it is derived from.
    prot fn _derived_assign(self, d: unsafe *Decl) {
        var        form = self._assign_form_of(d)
        var unsafe *x   = self._assign_from_of(d)
        if x == &null {
            self._ice(
                self._at(d),
                "InterfaceEmitter: a derived `op =` with no transfer constructor; ClassLifecycle gate failure",
            )
        }

        var other: unsafe *Declarations::ParamDecl = &null
        for var i: usize = 0; i < x->params.size(); ++i {
            var unsafe *p = x->params[i]
            if p != &null && !p->is_self {
                other = p
                break
            }
        }

        if other == &null {
            self._ice(
                self._at(unsafe (x as unsafe *Decl)),
                "InterfaceEmitter: a transfer constructor with no `other`; ClassLifecycle gate failure",
            )
        }

        var xat  = self._at(unsafe (x as unsafe *Decl))
        var head = self._spell->leaf(d) + "& operator=("
        // noexcept exactly when the transfer constructor it rebuilds through
        // is (a Kairo constructor cannot unwind unless -funwind / @unwind):
        // otherwise is_nothrow_move_assignable is false for a C++ user and
        // std::vector copies instead of moving on regrowth. Only the
        // forms with a body: `= default` deduces its own noexcept and a
        // deleted one is never called.
        var ne = ""
        if x->no_unwind {
            ne = " noexcept"
        }

        var bare = head + self._spell->param_decl(other, "", &null, d) + ")"
        var named = head + self._spell->param_decl(other, "o", &null, d) + ")" + ne
        // The constructor's own requires-clause, if it has one: the record's
        // explicit instantiation (`template class V<X>;`) instantiates every
        // unconstrained member, so an `op =` that rebuilds through a copy
        // constructor X's clause removed would fail for that X even though
        // nothing assigns one (`[MoveOnly]`'s constrained @copy).
        var xreq = self._spell->member_requires(x, d)
        match form {
            case Declarations::AssignForm::Default {
                self._cg->sink->spell(xat, bare + xreq + " = default;")
            } case Declarations::AssignForm::Deleted {
                self._cg->sink->spell(xat, bare + " = delete;")
            } case Declarations::AssignForm::Body {
                self._cg->sink->spell(xat, named + xreq + self._rebuild(d, x))
            } case Declarations::AssignForm::Constrained {
                // Exactly one is viable in an instance, as with a generic
                // ADT's special members; the deleted one leaves an instance
                // that fails the constraint unassignable by name.
                var ok = self._rebuild_constraint(d)
                self._cg->sink->spell(
                    xat,
                    named + " requires (" + ok + ")" + self._rebuild(d, x),
                )

                self._cg->sink->spell(
                    xat,
                    bare + " requires (!(" + ok + ")) = delete;",
                )
            } default {
                0
            }
        }
    }

    /// ` { if (this != &o) { this->X::~X(); ::new (static_cast<void*>(this))
    /// X(o); } return *this; }` (`static_cast<X&&>(o)` from a `@move`
    /// constructor). Nothing on self-assignment: destroying first would
    /// leave nothing to build from. The destructor call is qualified, so it
    /// is never virtual: only X is rebuilt (a polymorphic record never gets
    /// here). The old value goes before the new one is built, not after
    /// building it aside: emitted C++ is compiled without exceptions, so the
    /// constructor cannot leave the record half-assigned. `::new` is the
    /// global placement form (<new>, _needs_new); X is the injected class
    /// name, template or not.
    priv fn _rebuild(self, d: unsafe *Decl, x: unsafe *Declarations::FunctionDecl) -> string {
        var nm = self._spell->leaf(d)
        var src = if (x->transfer == Declarations::TransferKind::Move) => ("static_cast<" + nm + "&&>(o)")
                  else => "o"
        return " { if (this != &o) { this->" + nm + "::~" + nm + "(); ::new (static_cast<void*>(this)) " + nm + "(" + src + "); } return *this; }"
    }

    /// What a Constrained `op =` asks of an instance: every by-value field
    /// whose type depends on a generic parameter destructible, and every
    /// such base destructible and not polymorphic -- what ClassLifecycle
    /// could not decide in the pattern (_has_dependent_part walks the same
    /// lists with the same test). Traits over the parts, never over the
    /// record: inside its own body the record is incomplete, and clang
    /// rejects a trait on it there.
    priv fn _rebuild_constraint(self, d: unsafe *Decl) -> string {
        var s = ""
        if isa<Declarations::ClassDecl>(d) {
            var unsafe *c = cast<Declarations::ClassDecl>(d)
            for var i: usize = 0; i < c->derives_list.size(); ++i {
                var unsafe *e = c->derives_list.get(i)
                if e == &null || !self._dependent(e->base) {
                    continue
                }

                var b = self._spell->_type(e->base)
                if s.size() > 0 {
                    s += " && "
                }

                s += "__is_destructible(" + b + ") && !__is_polymorphic(" + b + ")"
            }
        }

        var fields = DeclFacts::decl_fields(d)
        for var i: usize = 0; i < fields.size(); ++i {
            var unsafe *f = fields[i]
            if f == &null || f->is_static() || !self._dependent(f->type_) {
                continue
            }

            if s.size() > 0 {
                s += " && "
            }

            s += "__is_destructible(" + self._spell->_type(f->type_, &null, d) + ")"
        }

        if s.size() == 0 {
            self._ice(
                self._at(d),
                "InterfaceEmitter: a constrained `op =` with no dependent part; ClassLifecycle gate failure",
            )
        }

        return s
    }

    /// The type depends on a generic parameter (ClassLifecycle's test for
    /// an open part).
    priv fn _dependent(self, t: unsafe *Type) -> bool {
        if t == &null || t->canonical == &null {
            return false
        }

        var unsafe *c = canon_unqual(t->canonical)
        return c->is_dependent() || c->is_instantiation_dependent()
    }

    /// `union { T a; U b; };`: an anonymous union, written where its field
    /// is. Its members are the owner's members to C++ and take the access
    /// in force for the field, so no specifier goes inside. Each member is
    /// spelled as an ordinary field would be, \p owner's body being the
    /// scope its types are named from. The layout is clang's.
    prot fn _anon_union_field(self, f: unsafe *Declarations::FieldDecl, owner: unsafe *Decl) {
        var unsafe *u  = self._plan->anon_union_of(f)
        var        fat = self._at(unsafe (f as unsafe *Decl))
        // A lang item's aligned payload (EnumDecl::adt_union_align): every
        // payload starts at that boundary, whatever the tag before it.
        var unsafe *oe = dyn_cast<Declarations::EnumDecl>(owner)
        if oe != &null && oe->adt_payload_offset != &null {
            // max(floor, alignof(payloads)): never weaker than the members'
            // own, which an `alignas` may not be.
            self._cg->sink->spell(
                fat,
                "union alignas(" + self._spell->leaf(oe->adt_payload_offset) + ") {",
            )
        } else {
            self._cg->sink->spell(fat, "union {")
        }

        for var i: usize = 0; i < u->fields.size(); ++i {
            var unsafe *m = u->fields[i]
            if m == &null {
                continue
            }

            var unsafe *mps = self._member_payload(m)
            if mps != &null && mps->adt_pack_param != &null {
                // One payload per element of the pack (_pack_union).
                self._cg->sink->spell(
                    self._at(unsafe (m as unsafe *Decl)),
                    "::" + LowerTargets::adt_pack_union() + "<" + self._pack_payload(
                        mps,
                        owner,
                    ) + "...> " + self._spell->leaf(unsafe (m as unsafe *Decl)) + ";",
                )

                continue
            }

            var ms = self._spell->decl(
                m->type_,
                self._spell->leaf(unsafe (m as unsafe *Decl)),
                &null,
                owner,
            )

            ms += ";"
            self._cg->sink->spell(self._at(unsafe (m as unsafe *Decl)), ms)
        }

        self._cg->sink->spell(fat, "};")
    }

    /// The payload member of a pack-expanded variant (Compiler/Spec/Panic.md#the-result-type):
    /// `__kairo_pu<P<E>...>`, a union of one payload per element, head and
    /// rest. Element K is `__kairo_get<K>()`; building one is the
    /// `(__kairo_vt<K>, f)` constructor, which recurses to the K-th member;
    /// destroying or copying element k (a runtime index, the tag's) is the
    /// helper of the same name, which recurses the same way. Its special
    /// members are trivial exactly when every member's are, so an ADT over
    /// trivial elements stays trivial; otherwise they do nothing, and the
    /// ADT's own (which know the tag) run the element's. Once per TU,
    /// beside the variant tags it is built with.
    prot fn _pack_union(self) {
        var pu  = LowerTargets::adt_pack_union()
        var hd  = LowerTargets::adt_pack_head()
        var rs  = LowerTargets::adt_pack_rest()
        var get = LowerTargets::adt_pack_get()
        var ds  = LowerTargets::adt_destroy()
        var cf  = LowerTargets::adt_construct_from()
        var vt  = "::" + LowerTargets::adt_variant_tag()
        var u   = builtin_info(BuiltinKind::U32)->cxx
        var tc  = "(__is_trivially_copyable(H) && (__is_trivially_copyable(R) && ...))"
        var td  = "(__is_trivially_destructible(H) && (__is_trivially_destructible(R) && ...))"
        var at  = self._tu_at()
        self._cg->sink->spell(
            at,
            "template <class... P> union " + pu + " { " + pu + "() noexcept {} void " + ds + "(" + u + ") noexcept {} " + "template <class O> void " + cf + "(" + u + ", O&&) noexcept {} };",
        )

        self._cg->sink->brk()
        var s = "template <class H, class... R> union " + pu + "<H, R...> { H " + hd + "; " + pu + "<R...> " + rs + "; " + pu + "() noexcept {} " + "template <class F> " + pu + "(" + vt + "<0>, F&& f) noexcept : " + hd + "(static_cast<F&&>(f)()) {} " + "template <" + u + " K, class F> requires (K > 0) " + pu + "(" + vt + "<K>, F&& f) noexcept : " + rs + "(" + vt + "<K - 1>{}, static_cast<F&&>(f)) {} " + pu + "(const " + pu + "&) requires " + tc + " = default; " + pu + "(const " + pu + "&) noexcept requires (!" + tc + ") {} " + pu + "(" + pu + "&&) requires " + tc + " = default; " + pu + "(" + pu + "&&) noexcept requires (!" + tc + ") {} " + pu + "& operator=(const " + pu + "&) requires " + tc + " = default; " + pu + "& operator=(" + pu + "&&) requires " + tc + " = default; " + "~" + pu + "() requires " + td + " = default; " + "~" + pu + "() noexcept requires (!" + td + ") {} " + "template <" + u + " K> auto& " + get + "() noexcept { if constexpr (K == 0) { return " + hd + "; } else { return " + rs + ".template " + get + "<K - 1>(); } } " + "template <" + u + " K> const auto& " + get + "() const noexcept { if constexpr (K == 0) { return " + hd + "; } else { return " + rs + ".template " + get + "<K - 1>(); } } " + "void " + ds + "(" + u + " k) noexcept { if (k == 0) { " + hd + ".~H(); } else { " + rs + "." + ds + "(k - 1); } } " + "template <class O> void " + cf + "(" + u + " k, O&& o) noexcept { if (k == 0) { new (&" + hd + ") H(static_cast<O&&>(o)." + hd + "); } " + "else { " + rs + "." + cf + "(k - 1, static_cast<O&&>(o)." + rs + "); } } };"
        self._cg->sink->spell(at, s)
        self._cg->sink->brk()
    }
}
