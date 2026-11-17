/// --- The Kairo Project ------------------ Codegen/Emit/SpellRecords.k --- ///
///
///   Speller, part: records. Specializations of a generic record or
///   function and the member specializations an `extend` declares
///   (Compiler/Spec/Generics.md#member-specializations), the head and suffix
///   that name them, the spelling of a record type from its declaration,
///   owners and generic arguments, and the names of generic and pack
///   parameters.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::Context::DeclContext::DeclContextKind
import AST::Context::InstantiationRegistry::{
    InstanceEntry,
    InstantiationRegistry,
}
import AST::DeclFacts
import AST::LangItems::LowerTargets
import AST::Node::Base::{
    Decl,
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
import AST::Node::Declarations
import AST::Node::Types::GenericParamType
import AST::ParamMode::ParamMode
import Codegen::Emit::Spell::Speller
import Codegen::Emit::SpellConstraints
import Codegen::Emit::SpellFacts
import Codegen::Emit::SpellScopes
import Codegen::Emit::SpellTypes

extend Speller {
    /// # Specializations of a generic record

    /// `d` is a registered explicit or partial specialization of a record
    /// (TypeResolve sets `instantiated_from` to the primary). A function's
    /// is is_fn_spec.
    static fn is_record_spec(d: unsafe *Decl) -> bool {
        if d == &null
            || !(isa<Declarations::ClassDecl>(d)
                || isa<Declarations::StructDecl>(d)
                || isa<Declarations::UnionDecl>(d)) {
            return false
        }

        var k = DeclFacts::decl_spec_kind(d)
        if k != Declarations::SpecKind::Explicit && k != Declarations::SpecKind::Partial {
            return false
        }

        return DeclFacts::decl_instantiated_from(d) != &null
    }

    /// `d` is a full specialization of a generic function (`fn <> p<i32>`)
    /// paired with its primary (RedeclMerge sets `instantiated_from`): C++'s
    /// explicit specialization `template <> R p<int>(...)` of that primary,
    /// so a call of the primary at those arguments runs its body.
    static fn is_fn_spec(d: unsafe *Decl) -> bool {
        if d == &null || !isa<Declarations::FunctionDecl>(d) {
            return false
        }

        return DeclFacts::decl_spec_kind(d) == Declarations::SpecKind::Explicit
            && DeclFacts::decl_instantiated_from(d) != &null
            && cast<Declarations::FunctionDecl>(d)->member_spec_of == &null
    }

    /// Every paired specialization of generic function `prim0`, appended
    /// to `out` in declaration order. A specialization lives in its
    /// primary's scope (RedeclMerge pairs within one scope), so that scope's
    /// declarations are all there is to read.
    /// With `reg`, those written in another module than the primary's too
    /// (InstantiationRegistry::register_fn_spec), after the scope's own.
    static fn fn_specs_of(prim0: unsafe *Decl,
                          out:   unsafe *cxx::std::vector<unsafe *Decl>,
                          reg:   unsafe *InstantiationRegistry = &null) {
        var unsafe *prim = Speller::rep(prim0)
        if prim == &null || !isa<Declarations::FunctionDecl>(prim) || prim->semantic_dc == &null {
            return
        }

        if DeclFacts::decl_generic_params(prim).size() == 0 {
            return
        }

        // A member's scope lists it among its owner's methods.
        var unsafe *ext = DeclFacts::decl_extension_of(prim)
        var unsafe *own = if (ext != &null) => (unsafe (ext as unsafe *Decl))
                          else => prim->semantic_dc->dc_owner
        if own != &null && isa<Declarations::ExtensionDecl>(own) {
            var *ms = &cast<Declarations::ExtensionDecl>(own)->methods
            for var i: usize = 0; i < ms->size(); ++i {
                Speller::_fn_spec_in(
                    unsafe ((*ms)[i] as unsafe *Decl),
                    prim,
                    out,
                )
            }

            return
        }

        if own != &null && isa<Declarations::ClassDecl>(own) {
            var *ms = &cast<Declarations::ClassDecl>(own)->methods
            for var i: usize = 0; i < ms->size(); ++i {
                Speller::_fn_spec_in(
                    unsafe ((*ms)[i] as unsafe *Decl),
                    prim,
                    out,
                )
            }

            return
        }

        if own != &null && isa<Declarations::StructDecl>(own) {
            var *ms = &cast<Declarations::StructDecl>(own)->methods
            for var i: usize = 0; i < ms->size(); ++i {
                Speller::_fn_spec_in(
                    unsafe ((*ms)[i] as unsafe *Decl),
                    prim,
                    out,
                )
            }

            return
        }

        var unsafe *dc = prim->semantic_dc
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            Speller::_fn_spec_in(*dc->dc_decls.get(i), prim, out)
        }

        if reg == &null {
            return
        }

        var all = cxx::std::vector<unsafe *Decl>()
        reg->fn_specs_of(prim, unsafe &all)
        for var i: usize = 0; i < all.size(); ++i {
            if Speller::is_fn_spec(all[i]) {
                out->push_back(all[i])
            }
        }
    }

    /// An extension member that specializes a class-body method
    /// (FunctionDecl::member_spec_of): an ordinary member of its extension's
    /// scope struct, under a name of its own, which the method's own body
    /// calls for the arguments it covers (EmitIR::_member_spec_dispatch).
    static fn is_member_spec(d: unsafe *Decl) -> bool {
        var unsafe *f = dyn_cast<Declarations::FunctionDecl>(d)
        return f != &null && f->member_spec_of != &null
    }

    /// The member specializations of class method `m0` the build knows
    /// (InstantiationRegistry::register_fn_spec), in registration order.
    static fn member_specs_of(m0:  unsafe *Decl,
                              out: unsafe *cxx::std::vector<unsafe *Decl>,
                              reg: unsafe *InstantiationRegistry) {
        var unsafe *m = Speller::rep(m0)
        if m == &null || reg == &null {
            return
        }

        var all = cxx::std::vector<unsafe *Decl>()
        reg->fn_specs_of(m, unsafe &all)
        for var i: usize = 0; i < all.size(); ++i {
            if Speller::is_member_spec(all[i]) && !all[i]->is_poisoned() {
                out->push_back(all[i])
            }
        }
    }

    /// `d`, or each declaration a visibility group or `eval` block of it
    /// holds, when it is a specialization of `prim`.
    priv static fn _fn_spec_in(d:    unsafe *Decl,
                               prim: unsafe *Decl,
                               out:  unsafe *cxx::std::vector<unsafe *Decl>) {
        if d == &null {
            return
        }

        if isa<Declarations::VisibilityGroupDecl>(d) {
            var unsafe *g = cast<Declarations::VisibilityGroupDecl>(d)
            for var i: usize = 0; i < g->members.size(); ++i {
                Speller::_fn_spec_in(g->members[i], prim, out)
            }

            return
        }

        if isa<Declarations::EvalBlockDecl>(d) {
            var unsafe *b = cast<Declarations::EvalBlockDecl>(d)
            for var i: usize = 0; i < b->body.size(); ++i {
                Speller::_fn_spec_in(b->body[i], prim, out)
            }

            return
        }

        if d->is_poisoned() || !Speller::is_fn_spec(d) {
            return
        }

        if Speller::rep(DeclFacts::decl_instantiated_from(d)) == prim {
            out->push_back(d)
        }
    }

    /// The specialization of `prim` at canonical `args`, or null: its
    /// instance is the specialization's body, so no explicit instantiation
    /// of the primary is written for it.
    static fn fn_spec_for(prim: unsafe *Decl,
                          args: unsafe *cxx::std::vector<unsafe *Type>,
                          reg:  unsafe *InstantiationRegistry = &null) -> unsafe *Decl {
        var specs = cxx::std::vector<unsafe *Decl>()
        Speller::fn_specs_of(prim, unsafe &specs, reg)
        for var i: usize = 0; i < specs.size(); ++i {
            var sargs = DeclFacts::decl_spec_args(specs[i])
            if sargs.size() != args->size() {
                continue
            }

            var same = true
            for var k: usize = 0; k < sargs.size(); ++k {
                if sargs[k] == &null || sargs[k]->canonical != (*args)[k] {
                    same = false
                    break
                }
            }

            if same {
                return specs[i]
            }
        }

        return &null
    }

    /// The head of a record's own declaration and definition: an explicit
    /// specialization's `template <>`, else template_head. Not for an
    /// out-of-line MEMBER of one: [temp.expl.spec]/5 writes those with no
    /// `template <>` at all, and owner_template_head's template_head gives
    /// exactly that, since an explicit spec has no parameters.
    fn record_head(self, d: unsafe *Decl) -> string {
        if Speller::is_record_spec(d)
            && DeclFacts::decl_spec_kind(d) == Declarations::SpecKind::Explicit {
            return "template <> " + self.requires_clause(d)
        }

        return self.template_head(d)
    }

    /// `<P*>` / `<bool>`: a specialization's pattern, the arguments it
    /// specializes the primary at, with a partial's own parameters by name.
    /// "" for anything that is not a record spec. Appended to the leaf
    /// wherever the spec itself is named -- its declarations and the
    /// qualifier of its out-of-line members -- because C++ has no other way
    /// to say which specialization of `Store` is meant.
    fn spec_suffix(self, d: unsafe *Decl) -> string {
        if !Speller::is_record_spec(d) && !Speller::is_fn_spec(d) {
            return ""
        }

        var sargs = DeclFacts::decl_spec_args(d)
        var args  = cxx::std::vector<unsafe *Type>()
        for var i: usize = 0; i < sargs.size(); ++i {
            if sargs[i] == &null || sargs[i]->canonical == &null {
                kairo::std::ice_fail(
                    "CXXSpell: a specialization's pattern reached codegen unresolved",
                )
            }

            args.push_back(sargs[i]->canonical)
        }

        return self.args_str(args)
    }

    /// One segment of an out-of-line member's qualifier: the leaf, then a
    /// specialization's pattern or a generic owner's own parameters as its
    /// arguments (`Store<P*>`, `Store<bool>`, `Box<T>`).
    fn owner_segment(self, d: unsafe *Decl) -> string {
        var s = self.leaf(d)
        if Speller::is_record_spec(d) {
            return s + self.spec_suffix(d)
        }

        var gps = DeclFacts::decl_generic_params(d)
        if gps.size() == 0 {
            return s
        }

        s += "<"
        for var j: usize = 0; j < gps.size(); ++j {
            if j > 0 {
                s += ", "
            }

            s += self.tok_name(gps[j]->name, Speller::fid_of(d))
            if gps[j]->is_pack {
                s += "..."
            }
        }

        s += ">"
        return s
    }

    /// `template <class T>` for each generic owner of `owner`, outermost
    /// first: the head of an out-of-line member's definition.
    fn owner_template_head(self, owner: unsafe *Decl) -> string {
        var chain = self.owner_chain(owner)
        var s     = ""
        for var i: usize = 0; i < chain.size(); ++i {
            s += self.template_head(chain[i])
        }

        return s
    }

    /// `Outer<T>::Inner<U>`, each generic owner with its own parameters as
    /// its arguments (owner_segment): an out-of-line member's qualifier,
    /// relative to the outermost record's namespace wrapper.
    fn owner_qual(self, owner: unsafe *Decl) -> string {
        var chain = self.owner_chain(owner)
        var s     = ""
        for var i: usize = 0; i < chain.size(); ++i {
            if i > 0 {
                s += "::"
            }

            s += self.owner_segment(chain[i])
        }

        return s
    }

    /// Type owners from outermost to `owner` inclusive.
    fn owner_chain(self, owner: unsafe *Decl) -> cxx::std::vector<unsafe *Decl> {
        var rev = cxx::std::vector<unsafe *Decl>()
        rev.push_back(Speller::rep(owner))
        var unsafe *dc = owner->semantic_dc
        while dc != &null && dc->is_type_scope() && dc->dc_kind != DeclContextKind::Extension {
            rev.push_back(Speller::rep(dc->dc_owner))
            dc = dc->dc_parent
        }

        var out = cxx::std::vector<unsafe *Decl>()
        for var i: usize = 0; i < rev.size(); ++i {
            out.push_back(rev[rev.size() - 1 - i])
        }

        return out
    }

    /// # internals

    prot fn _join(self, ty: string, const name: string) -> string {
        if name.size() == 0 {
            return ty
        }

        // A declarator that starts with `*`/`&`/`(` binds without a space.
        var c = name[0]
        if c == ('*' as u8) || c == ('&' as u8) || c == ('(' as u8) || c == ('[' as u8) {
            return ty + name
        }

        return ty + " " + name
    }

    /// `r`'s arguments are exactly `iface`'s own parameters, in order.
    priv fn _own_args(self, r: unsafe *RecordType, iface: unsafe *Decl) -> bool {
        var gps = DeclFacts::decl_generic_params(iface)
        if gps.size() != r->args.size() {
            return false
        }

        for var i: usize = 0; i < r->args.size(); ++i {
            var unsafe *g = dyn_cast<GenericParamType>(canon_unqual(r->args[i]))
            if g == &null || g->param_index != (i as u32) {
                return false
            }

            if Speller::rep(g->owner) != iface {
                return false
            }
        }

        return true
    }

    prot fn _record(self,
                    r:     unsafe *RecordType,
                    subst: unsafe *InstanceEntry,
                    scope: unsafe *Decl) -> string {
        var unsafe *d = r->decl
        if d == &null {
            kairo::std::ice_fail("CXXSpell: RecordType with no decl")
        }

        if isa<Declarations::InterfaceDecl>(d) {
            var mine = self.self_iface != &null
                && Speller::rep(DeclFacts::decl_pattern(Speller::rep(d))) == self.self_iface
            // Self is `I` bare, or in a GENERIC interface `I<T...>` over its
            // own parameters (TypeResolve::_self_record) -- unsubstituted
            // here, the member's substitution applying only below it.
            if mine && (r->args.size() == 0 || self._own_args(r, self.self_iface)) {
                return self.self_spelling.copy()
            }

            self._ice(
                d->range,
                "CXXSpell: an interface has no C++ type; only its Self inside a witness is spelled",
            )
        }

        if DeclFacts::decl_is_imported(d) {
            // A tag hidden by an ordinary name (`struct timezone` beside
            // `extern long timezone`): bare `::timezone` is the variable in
            // C++, so the type is only reachable elaborated.
            var kw = DeclFacts::decl_ffi_tag_keyword(d)
            if kw.size() > 0 {
                return kw + " " + DeclFacts::decl_cxx_spelling(d)
            }

            // The PRIMARY over arguments -- `array<T, 4>` in a generic
            // signature, dependent so never filled -- is the template's name
            // and the arguments as Kairo spells them; the name alone was
            // `::std::array`, a template used without arguments. A filled
            // instance's spelling already carries its own.
            if r->args.size() > 0 && !DeclFacts::decl_is_instance(d) {
                // A defaulted parameter whose default names a param still
                // unplaced (`vector<T>`'s `allocator<T>` in a generic
                // body) is held by the primary's OWN param as a stand-in
                // (GenericArgs). That param is clang's and has no Kairo
                // name; every param after it is defaulted too, so stop
                // there and let C++ apply its defaults itself.
                var v = cxx::std::vector<unsafe *Type>()
                for var i: usize = 0; i < r->args.size(); ++i {
                    var unsafe *g = dyn_cast<GenericParamType>(
                        canon_unqual(r->args[i]),
                    )

                    if g != &null
                        && g->owner != &null
                        && Speller::rep(g->owner) == Speller::rep(d) {
                        break
                    }

                    // A parameter of a generic ALIAS (`BoxA(x)` over
                    // `template <class T> using BoxA = Box<T>`, no explicit
                    // arguments) is the alias's pattern, never in scope in
                    // an emitted body: spelling it gave `Box<T>` with an
                    // undeclared T (the self-host's `LockGuard(self._mu)`).
                    // The name alone leaves the arguments to clang's
                    // deduction, as for the template itself.
                    if g != &null
                        && g->owner != &null
                        && isa<Declarations::TypeAliasDecl>(
                            Speller::rep(g->owner),
                        ) {
                        v.clear()
                        break
                    }

                    v.push_back(r->args[i])
                }

                if v.size() == 0 {
                    return DeclFacts::decl_cxx_spelling(d)
                }

                return DeclFacts::decl_cxx_spelling(d) + self.args_str(
                    v,
                    subst,
                    scope,
                )
            }

            return DeclFacts::decl_cxx_spelling(d)
        }

        // A panic result whose set names a type parameter (a generic body,
        // Compiler/Spec/Panic.md#generic-bodies): C++ orders the set at each instance through the
        // sorting alias, so the template's result and a concrete caller's
        // `Panic<T, A, B>` are one type however the parameters land.
        if self._dependent_panic_set(r) {
            var s = "::" + LowerTargets::panic_set_alias() + "<" + self.qual_name(
                Speller::rep(d),
            )

            for var i: usize = 0; i < r->args.size(); ++i {
                s += ", " + self._type(r->args[i], subst, scope)
            }

            return s + ">"
        }

        // An instance shell names its PRIMARY plus the registry's args.
        if DeclFacts::decl_is_instance(d) {
            var unsafe *e = self._cg->instances->entry_of(d)
            if e == &null {
                self._ice(
                    d->range,
                    "CXXSpell: instance shell with no registry entry",
                )
            }

            return self._record_name(
                e->primary,
                self.args_str(e->args, subst, scope),
                scope,
            )
        }

        var targs = ""
        if r->args.size() > 0 {
            var v = cxx::std::vector<unsafe *Type>()
            for var i: usize = 0; i < r->args.size(); ++i {
                v.push_back(r->args[i])
            }

            targs = self.args_str(v, subst, scope)
        }

        // `L<i32>::P`: the member of the enclosing instance, spelled
        // through it -- `::ns::L<int>::P`, or `typename ::ns::L<T>::P` while
        // the instance is dependent.
        if r->outer != &null {
            var oq = self._type(r->outer, subst, scope)
            var dep = r->outer->is_dependent() || r->outer->is_instantiation_dependent()
            return Speller::_member_type(oq, dep, self.leaf(d), targs)
        }

        return self._record_name(d, targs, scope)
    }

    /// `r` is the Panic lang item (a type-id-tagged ADT) with an element
    /// past its value type that names a type parameter.
    priv fn _dependent_panic_set(self, r: unsafe *RecordType) -> bool {
        if r->args.size() < 2 {
            return false
        }

        var unsafe *en = dyn_cast<Declarations::EnumDecl>(Speller::rep(r->decl))

        if en == &null || !en->adt_explicit_tags || DeclFacts::adt_pack_param(en) == usize::MAX {
            return false
        }

        for var i: usize = 1; i < r->args.size(); ++i {
            var unsafe *a = r->args[i]
            if a != &null && (a->is_dependent() || a->is_instantiation_dependent()) {
                return true
            }
        }

        return false
    }

    /// A record's name with its own template arguments `targs` ("" for
    /// none). A type nested in a class template cannot be qualified the way
    /// qual_name does it: `::ns::L::P` names the template `L` without
    /// arguments, which C++ rejects. So, in order:
    ///   - inside the owner's own body (`scope`), the leaf: the owner's
    ///     scope is in force there, and its injected class name stands for
    ///     the current instantiation;
    ///   - any other place under a generic owner, the member of the owner
    ///     spelled with its own parameters, `typename ::ns::L<K>::P` -- what
    ///     an out-of-line member's return type and body need, and valid
    ///     anywhere inside the owner's template;
    ///   - everything else, the plain qualified name.
    /// Outside the owner's template the second form names parameters that
    /// are not in scope. That is unreachable from correct input only once
    /// Sema keeps the owner's arguments on a nested type (`L<i32>::P`
    /// canonicalizes to the pattern's `P` today), and the qualified form
    /// would be just as wrong there.
    priv fn _record_name(self,
                         d_in:        unsafe *Decl,
                         const targs: string,
                         scope:       unsafe *Decl) -> string {
        if Speller::in_function_scope(d_in) {
            return self.leaf(d_in) + targs
        }

        var unsafe *d   = Speller::rep(d_in)
        var unsafe *own = self._record_owner(d)
        if own == &null {
            return self.qual_name(d) + targs
        }

        if scope != &null {
            var unsafe *sc = Speller::rep(scope)
            if sc == own || sc == d {
                return self.leaf(d) + targs
            }
        }

        var q = self._generic_owner_qual(d)
        if q.size() == 0 {
            return self.qual_name(d) + targs
        }

        return Speller::_member_type(q, true, self.leaf(d), targs)
    }

    /// The record `d` is a member of, or null at namespace scope. An
    /// extension is not an owner here: it opens no C++ class scope a nested
    /// type could live in.
    prot fn _record_owner(self, d: unsafe *Decl) -> unsafe *Decl {
        var unsafe *dc = self._home_dc(d)
        if dc == &null || !dc->is_type_scope() || dc->dc_kind == DeclContextKind::Extension {
            return &null
        }

        return Speller::rep(dc->dc_owner)
    }

    /// `::ns::L<K>::Q`: `d`'s owners, each generic one spelled with its own
    /// parameters, i.e. the owner chain as its own template body sees it;
    /// "" when no owner is generic, because then qual_name is already a
    /// complete name. A generic owner past the first is a member template of
    /// a dependent type and takes `template`, as dependent_member_type
    /// spells it.
    prot fn _generic_owner_qual(self, d: unsafe *Decl) -> string {
        var        rev = cxx::std::vector<unsafe *Decl>()
        var unsafe *dc = self._home_dc(d)
        while dc != &null && dc->is_type_scope() {
            if dc->dc_kind != DeclContextKind::Extension {
                rev.push_back(Speller::rep(dc->dc_owner))
            }

            dc = dc->dc_parent
        }

        var s  = ""
        var ns = self.ns_segments(d)
        for var i: usize = 0; i < ns.size(); ++i {
            s += "::"
            s += ns[i]
        }

        var dependent = false
        for var i: usize = 0; i < rev.size(); ++i {
            var unsafe *o  = rev[rev.size() - 1 - i]
            var        gps = DeclFacts::decl_generic_params(o)
            s += "::"
            if dependent && gps.size() > 0 {
                s += "template "
            }

            s += self.leaf(o)
            if gps.size() == 0 {
                continue
            }

            dependent = true
            var fid = Speller::fid_of(o)
            s += "<"
            for var j: usize = 0; j < gps.size(); ++j {
                if j > 0 {
                    s += ", "
                }

                s += self.tok_name(gps[j]->name, fid)
                if gps[j]->is_pack {
                    s += "..."
                }
            }

            s += ">"
        }

        return if (dependent) => (s) else => ""
    }

    /// A Kairo type pack parameter that lowers to `T&&... xs` (param_type):
    /// by value or `@move`, not `const` (`const T&&` binds no lvalue, so a
    /// const pack stays `const T... xs`), not `@inout` (its elements are the
    /// pointers the call passes). An imported C++ pack is spelled by clang's
    /// own pattern, never here: its type is a reference to the pack.
    static fn forwarding_pack(p: unsafe *Declarations::ParamDecl) -> bool {
        if p == &null || p->is_const || p->mode == ParamMode::Inout {
            return false
        }

        if !DeclFacts::param_is_type_pack(p) || p->type_ == &null || p->type_->canonical == &null {
            return false
        }

        return isa<GenericParamType>(canon_unqual(p->type_->canonical))
    }

    /// The C++ name of type pack `g`'s template parameter, without the
    /// `...` _gparam appends: `static_cast<T&&>(xs)...`.
    fn pack_param_name(self, g: unsafe *GenericParamType) -> string {
        var unsafe *owner = Speller::rep(g->owner)
        var        gps    = DeclFacts::decl_generic_params(owner)
        if (g->param_index as usize) >= gps.size() {
            self._ice(
                owner->range,
                "CXXSpell: generic param index out of range",
            )
        }

        return self.tparam_name(gps[g->param_index as usize], owner)
    }

    /// `sigil` goes between an unsubstituted pack's name and its `...`
    /// (`T&&...`, param_type).
    prot fn _gparam(self,
                    g:           unsafe *GenericParamType,
                    subst:       unsafe *InstanceEntry,
                    const sigil: string = "") -> string {
        if g->owner == &null {
            kairo::std::ice_fail(
                "CXXSpell: canonical generic param with no owner",
            )
        }

        var unsafe *owner = Speller::rep(g->owner)
        // A pack is only ever spelled expanded: a canonical pack parameter
        // stands for its expansion (`R<i32, E...>`'s argument, `...xs: T`'s
        // type), so it is `E...`, or under an instance its elements.
        if g->is_pack && self.pack_alias != &null {
            var ags = DeclFacts::decl_generic_params(owner)
            if (g->param_index as usize) < ags.size()
                && ags[g->param_index as usize] == self.pack_alias {
                return LowerTargets::adt_pack_elem()
            }
        }

        if g->is_pack {
            var els = cxx::std::vector<unsafe *Type>()
            if self.subst_pack(g, subst, &els) {
                var ps = ""
                for var i: usize = 0; i < els.size(); ++i {
                    if i > 0 {
                        ps += ", "
                    }

                    ps += self._type(els[i], &null)
                }

                return ps
            }
        } else {
            // An instance's array argument is followed by the parameter's
            // `const &` or `*` (`template int f<int[2]>(int[2] const &)` is an
            // array of references): one type-specifier.
            var unsafe *t = self.subst_for(g, subst)
            if t != &null {
                return self.type_specifier(t, &null)
            }
        }

        var gps = DeclFacts::decl_generic_params(owner)
        if (g->param_index as usize) >= gps.size() {
            self._ice(
                owner->range,
                "CXXSpell: generic param index out of range",
            )
        }

        var nm = self.tparam_name(gps[g->param_index as usize], owner)
        if !g->is_pack
            && self.void_unit_owner != &null
            && Speller::rep(self.void_unit_owner) == owner {
            return "::" + LowerTargets::void_unit() + "<" + nm + ">"
        }

        return if (g->is_pack) => (nm + sigil + "...") else => nm
    }
}
