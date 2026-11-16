/// --- The Kairo Project -------------- Codegen/Emit/SpellConstraints.k --- ///
///
///   Speller, part: constraints and witnesses. Witness and concept names
///   (Compiler/Spec/Witnesses.md), associated types, `requires` clauses, the
///   bound and layout asserts a body or record carries, predicates, and
///   template heads.
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

import AST::Context::InstantiationRegistry::InstanceEntry
import AST::DeclFacts
import AST::LangItems::LowerTargets
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    AssocType,
    BoundsState,
    QualifiedType,
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Expressions::{
    AlignOfExpr,   BinaryOperatorExpr, CallExpr,       ConstraintExpr, ParenExpr, SizeOfExpr,
    TypeTraitExpr, UnaryOperatorExpr,  type_trait_cxx,
}
import AST::Node::PrimaryExpressions::{
    BooleanLiteralExpr,
    IntegerLiteralExpr,
    NamedIdentExpr,
}
import AST::Node::Statements::ReturnStmt
import AST::Node::Types::GenericParamType
import AST::OperatorFacts::OperatorFacts
import Codegen::Emit::Spell::Speller
import Codegen::Emit::SpellFacts
import Codegen::Emit::SpellRecords
import Codegen::Emit::SpellScopes
import Codegen::Emit::SpellTypes
import Token::TokenKind::TokenKind

extend Speller {
    /// # Witnesses (Compiler/Spec/Witnesses.md)

    /// `namespace std`'s segments: where a std::hash adapter is written
    /// (EmitWitness::_std_hash_decl).
    static fn std_ns() -> cxx::std::vector<string> {
        var v = cxx::std::vector<string>()
        v.push_back("std")
        return v
    }

    /// `::ns::I_witness`: the class template a bound call goes through.
    fn witness_name(self, iface: unsafe *Decl) -> string {
        return self._iface_qual(iface) + LowerTargets::witness_suffix()
    }

    /// `::ns::I_c`: the concept an interface bound renders as.
    /// An imported C++ concept is its own C++ name (`::Addable`): the bound
    /// IS that concept, and the `I_c` stand-in is written only beside the
    /// Kairo file's own pieces, under the header's module namespace, which
    /// a kcc header layout of the file does not contain ("no member
    /// named 'my_code' in the global namespace").
    fn concept_name(self, iface: unsafe *Decl) -> string {
        var unsafe *r = Speller::rep(iface)
        if DeclFacts::decl_is_imported(r) {
            return DeclFacts::decl_cxx_spelling(r)
        }

        return self._iface_qual(iface) + LowerTargets::concept_suffix()
    }

    /// `::ns::I`, the prefix both names share. An interface nested in a
    /// type would put its witness inside a class, where a specialization
    /// cannot be declared; none reaches here yet.
    priv fn _iface_qual(self, iface: unsafe *Decl) -> string {
        var unsafe *r = Speller::rep(iface)
        if self.owner_types(r).size() > 0 {
            self._ice(
                r->range,
                "CXXSpell: a witness for an interface nested in a type; no naming rule for it yet",
            )
        }

        var s  = ""
        var ns = self.ns_segments(r)
        for var i: usize = 0; i < ns.size(); ++i {
            s += "::"
            s += ns[i]
        }

        return s + "::" + self.leaf(r)
    }

    /// `typename ::ns::I_witness<B, A...>::Node` for associated type \p a.
    ///
    /// The witness is the BOUND's (`G impl Big`, Big derives Graph:
    /// `Big_witness<G>::Node`), since rows -- and so specializations -- exist
    /// for the bound, not for the interface that declares the requirement.
    /// A base that is an interface's Self is only ever spelled inside a
    /// witness: there the bare member name (a specialization) or
    /// assoc_self_qual (a concept).
    fn assoc_spelling(self,
                      a:     unsafe *AssocType,
                      subst: unsafe *InstanceEntry = &null,
                      scope: unsafe *Decl = &null) -> string {
        var leaf = self.leaf(a->assoc)
        // A generic associated type is the witness's member alias template
        // (`template <class K> using Map = ...`), named with its arguments.
        var targs = ""
        if a->args.size() > 0 {
            targs = "<"
            for var i: usize = 0; i < a->args.size(); ++i {
                if i > 0 {
                    targs += ", "
                }

                targs += self._type(a->args[i], subst, scope)
            }

            targs += ">"
        }

        var unsafe *b = canon_unqual(a->base)
        if isa<RecordType>(b)
            && isa<Declarations::InterfaceDecl>(
                Speller::rep(
                    DeclFacts::decl_pattern(
                        Speller::rep(cast<RecordType>(b)->decl),
                    ),
                ),
            ) {
            if self.assoc_self_qual.size() == 0 {
                return leaf + targs
            }

            if targs.size() > 0 {
                return "typename " + self.assoc_self_qual + "::template " + leaf + targs
            }

            return "typename " + self.assoc_self_qual + "::" + leaf
        }

        var unsafe *via = a->iface
        var unsafe *g   = dyn_cast<GenericParamType>(b)
        if g != &null {
            var unsafe *bt = self._assoc_bound(g, a)
            if bt != &null {
                via = bt
            }
        }

        // Reached through another associated type (`T::Item::Inner`): the
        // bound of THAT type that requires this one, as Sema read it
        // (AssocType::bounds) -- rows, and so specializations, exist for the
        // bound, not for the interface that declares the requirement.
        var unsafe *ab = dyn_cast<AssocType>(b)
        if ab != &null {
            var unsafe *bt2 = self._assoc_bound_of(ab, a)
            if bt2 != &null {
                via = bt2
            }
        }

        var unsafe *ic = canon_unqual(via)
        if ic == &null || !isa<RecordType>(ic) {
            self._ice(
                a->range,
                "CXXSpell: an associated type through a non-interface",
            )

            return ""
        }

        var unsafe *idecl = Speller::rep(
            DeclFacts::decl_pattern(Speller::rep(cast<RecordType>(ic)->decl)),
        )

        var q = self.witness_name(idecl) + self.witness_args(
            self._type(a->base, subst, scope),
            via,
            subst,
        )

        return Speller::_member_type(q, true, leaf, targs)
    }

    /// The bound of associated type \p base (its cached, substituted
    /// bounds) whose interface requires \p a's associated type, or null.
    priv fn _assoc_bound_of(self, base: unsafe *AssocType, a: unsafe *AssocType) -> unsafe *Type {
        if base->bounds_state != (BoundsState::Done as u8) {
            return &null
        }

        var unsafe *want = Speller::rep(a->assoc)
        for var i: usize = 0; i < base->bounds.size(); ++i {
            var unsafe *bt = canon_unqual(base->bounds[i])
            if bt == &null || !isa<RecordType>(bt) {
                continue
            }

            var unsafe *idecl = dyn_cast<Declarations::InterfaceDecl>(
                Speller::rep(
                    DeclFacts::decl_pattern(
                        Speller::rep(cast<RecordType>(bt)->decl),
                    ),
                ),
            )

            if idecl == &null || idecl->compose_state != (Declarations::ComposeState::Done as u8) {
                continue
            }

            for var j: usize = 0; j < idecl->requirements.size(); ++j {
                if Speller::rep(idecl->requirements.get(j)->decl) == want {
                    return bt
                }
            }
        }

        return &null
    }

    /// The bound of \p g whose interface requires \p a's associated type
    /// (itself or through what it derives), or null.
    priv fn _assoc_bound(self, g: unsafe *GenericParamType, a: unsafe *AssocType) -> unsafe *Type {
        if g->owner == &null {
            return &null
        }

        var cs = cxx::std::vector<unsafe *ConstraintExpr>()
        Speller::impl_bounds(
            DeclFacts::decl_requires_clause(Speller::rep(g->owner)),
            unsafe &cs,
        )

        var unsafe *want = Speller::rep(a->assoc)
        for var i: usize = 0; i < cs.size(); ++i {
            var unsafe *c  = cs[i]
            var unsafe *id = dyn_cast<NamedIdentExpr>(c->lhs)
            if id == &null {
                continue
            }

            var unsafe *gp = dyn_cast<Declarations::GenericParamDecl>(
                id->resolved_decl,
            )

            if gp == &null || gp->index != g->param_index {
                continue
            }

            if c->rhs == &null || c->rhs->canonical == &null {
                continue
            }

            var unsafe *bt = canon_unqual(c->rhs->canonical)
            if !isa<RecordType>(bt) {
                continue
            }

            var unsafe *idecl = dyn_cast<Declarations::InterfaceDecl>(
                Speller::rep(
                    DeclFacts::decl_pattern(
                        Speller::rep(cast<RecordType>(bt)->decl),
                    ),
                ),
            )

            if idecl == &null || idecl->compose_state != (Declarations::ComposeState::Done as u8) {
                continue
            }

            for var j: usize = 0; j < idecl->requirements.size(); ++j {
                if Speller::rep(idecl->requirements.get(j)->decl) == want {
                    return bt
                }
            }
        }

        return &null
    }

    /// `<Self, A...>`: a witness's or concept's arguments for interface
    /// instance \p iface, Self already spelled as \p self_s.
    fn witness_args(self,
                    const self_s: string,
                    iface:        unsafe *Type,
                    subst:        unsafe *InstanceEntry = &null) -> string {
        var s = "<" + self_s
        var v = self.iface_args(iface)
        for var i: usize = 0; i < v.size(); ++i {
            s += ", "
            s += self._type(v[i], subst)
        }

        return s + ">"
    }

    /// The arguments of interface instance \p iface, in parameter order.
    fn iface_args(self, iface: unsafe *Type) -> cxx::std::vector<unsafe *Type> {
        var        v  = cxx::std::vector<unsafe *Type>()
        var unsafe *c = canon_unqual(iface)
        if c == &null || !isa<RecordType>(c) {
            return v
        }

        var unsafe *r = cast<RecordType>(c)
        var unsafe *d = r->decl
        if DeclFacts::decl_is_instance(d) {
            var unsafe *e = self._cg->instances->entry_of(d)
            if e == &null {
                self._ice(
                    d->range,
                    "CXXSpell: interface instance with no registry entry",
                )
            }

            for var i: usize = 0; i < e->args.size(); ++i {
                v.push_back(e->args[i])
            }

            return v
        }

        for var i: usize = 0; i < r->args.size(); ++i {
            v.push_back(r->args[i])
        }

        return v
    }

    /// ` requires (::ns::I_c<T> && ...)` for \p d's interface bounds, one
    /// conjunct per `P impl I<A...>` in clause order, or "". Only bounds on
    /// \p d's OWN template parameters (template_params: an extension
    /// member's extension's, then its own), read off \p d's clause and, for
    /// an extension member, its extension's: a class's bound is the class
    /// head's, never repeated on a member that adds no parameter. Every
    /// declaration of the entity -- forward declaration, definition, an
    /// out-of-line member's owner head -- comes through template_head, so
    /// the heads agree, as [temp.over.link] and the mangled constraint need.
    /// Concepts are tier 0 (EmitPlan), ahead of every head that names one.
    fn requires_clause(self, d: unsafe *Decl) -> string {
        var tps = Speller::template_params(d)
        if tps.size() == 0 {
            return ""
        }

        var        cs = cxx::std::vector<unsafe *ConstraintExpr>()
        var unsafe *x = DeclFacts::decl_extension_of(d)
        if x != &null {
            Speller::impl_bounds(
                DeclFacts::decl_requires_clause(unsafe (x as unsafe *Decl)),
                unsafe &cs,
            )
        }

        Speller::impl_bounds(DeclFacts::decl_requires_clause(d), unsafe &cs)
        // A primary record's head carries none of its interface bounds
        // (bound_asserts): C++ checks a class template's constraints where
        // the template-id is NAMED, and a class names an instance over
        // itself while it is still incomplete -- the CRTP base-specifier
        // `class Seven : Mixin<Seven>`, a field `*Holder<Node>` in Node --
        // where no concept on it can hold yet. The bound is Kairo's anyway
        // (D0: ConformanceChecking proved it at the use); the instance's
        // home pins it once the class is complete.
        var deferred = Speller::defers_bounds(d)
        var s        = ""
        for var i: usize = 0; i < cs.size(); ++i {
            var unsafe *c = cs[i]
            if c->rhs == &null || c->rhs->canonical == &null {
                continue
            }

            var unsafe *gp = Speller::_bound_param(c)
            if gp == &null {
                continue
            }

            if deferred && gp->owner != &null && Speller::rep(gp->owner) == Speller::rep(d) {
                continue
            }

            var mine = false
            for var k: usize = 0; k < tps.size(); ++k {
                if tps[k] == gp {
                    mine = true
                    break
                }
            }

            if !mine {
                continue
            }

            var unsafe *rhs = canon_unqual(c->rhs->canonical)
            if !isa<RecordType>(rhs) {
                continue
            }

            var unsafe *idecl = Speller::rep(
                DeclFacts::decl_pattern(
                    Speller::rep(cast<RecordType>(rhs)->decl),
                ),
            )

            if !isa<Declarations::InterfaceDecl>(idecl) {
                continue
            }

            s += if (s.size() == 0) => (" requires (") else => " && "
            var conj = self.concept_name(idecl) + self.witness_args(
                self.tparam_name(gp, Speller::rep(gp->owner)),
                rhs,
            )

            // A pack's bound holds of every element: a fold, since a
            // constraint naming the pack unexpanded is ill-formed.
            if gp->is_pack {
                conj = "(" + conj + " && ...)"
            }

            s += conj
        }

        // A record's VALUE predicates (`class <T> B requires sizeof T <= 128`)
        // as C++ constraints, so clang rejects a bad instance where it is
        // named (Compiler/Spec/Eval.md#evaluation-model, E10). Only one that names nothing but the
        // record's own parameters, literals and sizeof / alignof is
        // spelled: the head is written before every other declaration, and
        // a constant or function it named would not be declared yet. The
        // rest are static_asserts in the record's body (body_predicates). A
        // function's predicates are its body's static_asserts (EmitIR::_body).
        // An enum's are its ADT record's: the record is written under
        // the enum's own head (InterfaceEmitter::_adt_def).
        if isa<Declarations::ClassDecl>(d)
            || isa<Declarations::StructDecl>(d)
            || isa<Declarations::UnionDecl>(d)
            || isa<Declarations::EnumDecl>(d) {
            var vps = cxx::std::vector<unsafe *Expr>()
            Speller::value_predicates(
                DeclFacts::decl_requires_clause(d),
                unsafe &vps,
            )

            for var i: usize = 0; i < vps.size(); ++i {
                var t = self._pred_text(vps[i])
                if t.size() == 0 {
                    continue
                }

                s += if (s.size() == 0) => (" requires (") else => " && "
                s += "(" + t + ")"
            }
        }

        var unsafe *fd = dyn_cast<Declarations::FunctionDecl>(d)
        if fd != &null && self.fn_preds_in_head(fd) {
            var vps = cxx::std::vector<unsafe *Expr>()
            Speller::value_predicates(fd->requires_clause, unsafe &vps)
            for var i: usize = 0; i < vps.size(); ++i {
                s += if (s.size() == 0) => (" requires (") else => " && "
                s += "(" + self._pred_text(vps[i], true) + ")"
            }
        }

        // Parenthesized: what follows the head is often a return type that
        // starts with `::` (`::builtin::Tuple2<...> f(...)`), and C++ reads a
        // `::` after `I_c<T>` as continuing the concept's qualified name --
        // no spacing separates them, only the closing paren.
        if s.size() > 0 {
            s += ")"
        }

        return s
    }

    /// \p d is a generic record PRIMARY, whose interface bounds stay off its
    /// template head (requires_clause). A partial specialization keeps its
    /// clause: there it selects, and dropping it would let C++ pick the
    /// partial where Kairo did not. Functions keep theirs (their concept is
    /// in the mangled name, Compiler/Spec/Witnesses.md#the-concept).
    static fn defers_bounds(d0: unsafe *Decl) -> bool {
        if d0 == &null {
            return false
        }

        var unsafe *d = Speller::rep(d0)
        if !(isa<Declarations::ClassDecl>(d)
            || isa<Declarations::StructDecl>(d)
            || isa<Declarations::UnionDecl>(d)
            || isa<Declarations::EnumDecl>(d)) {
            return false
        }

        var k = DeclFacts::decl_spec_kind(d)
        return k == Declarations::SpecKind::Primary || k == Declarations::SpecKind::None
    }

    /// Kairo class \p d0 has a virtual destructor: its own `virtual` /
    /// `override fn op finally`, or a Kairo base's (C++ makes the derived one
    /// virtual then, written or not). Such a class carries the hidden
    /// `__kairo_layout()` (InterfaceEmitter::_layout_virtual) that
    /// `__builtin_dynamic_size` / `_align` read. An imported base is not
    /// looked into: it has no `__kairo_layout()` to override, and the
    /// intrinsic's body refuses a polymorphic T without one.
    static fn has_virtual_dtor(d0: unsafe *Decl, depth: u32 = 0) -> bool {
        if d0 == &null || depth > 64 {
            return false
        }

        var unsafe *cd = dyn_cast<Declarations::ClassDecl>(
            Speller::rep(DeclFacts::decl_pattern(Speller::rep(d0))),
        )

        if cd == &null || DeclFacts::decl_is_imported(cd) {
            return false
        }

        for var i: usize = 0; i < cd->methods.size(); ++i {
            var unsafe *m = cd->methods[i]
            if m == &null || !m->is_operator || m->op_token.size() == 0 {
                continue
            }

            if m->op_token[0].kind != TokenKind::KwFinally {
                continue
            }

            if m->abi == Declarations::AbiKind::Virtual
                || m->abi == Declarations::AbiKind::Override {
                return true
            }
        }

        for var i: usize = 0; i < cd->derives_list.size(); ++i {
            var unsafe *e = cd->derives_list.get(i)
            if e == &null || e->base == &null || e->base->canonical == &null {
                continue
            }

            var unsafe *bc = canon_unqual(e->base->canonical)
            // A base that is the class's type parameter: what its bound's
            // class has, every argument has. An argument that adds a
            // virtual destructor its bound lacks is refused by Sema
            // (SC352E), so the bound is the whole answer.
            if isa<GenericParamType>(bc) {
                var unsafe *pb = Speller::param_bound(
                    cast<GenericParamType>(bc),
                )

                if pb != &null && Speller::has_virtual_dtor(pb->decl, depth + 1) {
                    return true
                }

                continue
            }

            if !isa<RecordType>(bc) {
                continue
            }

            if Speller::has_virtual_dtor(cast<RecordType>(bc)->decl, depth + 1) {
                return true
            }
        }

        return false
    }

    /// The class the first `derives` bound of type parameter \p g names, read
    /// off its owner's requires clause (where RequiresDesugar keeps every
    /// bound); null when it has none.
    static fn param_bound(g: unsafe *GenericParamType) -> unsafe *RecordType {
        if g == &null || g->owner == &null {
            return &null
        }

        var todo = cxx::std::vector<unsafe *Expr>()
        todo.push_back(DeclFacts::decl_requires_clause(Speller::rep(g->owner)))
        for var i: usize = 0; i < todo.size(); ++i {
            var unsafe *x = todo[i]
            if x == &null {
                continue
            }

            var unsafe *b = dyn_cast<BinaryOperatorExpr>(x)
            if b != &null
                && (b->op_token.kind == TokenKind::OpAmpAmp
                    || b->op_token.kind == TokenKind::KwAnd) {
                todo.push_back(b->lhs)
                todo.push_back(b->rhs)
                continue
            }

            var unsafe *c = dyn_cast<ConstraintExpr>(x)
            if c == &null || !c->is_derives() || c->rhs == &null || c->rhs->canonical == &null {
                continue
            }

            var unsafe *id = dyn_cast<NamedIdentExpr>(c->lhs)
            var unsafe *gp = if (id != &null) => (dyn_cast<Declarations::GenericParamDecl>(
                                 id->resolved_decl,
                             ))
                             else => &null
            if gp == &null || gp->index != g->param_index {
                continue
            }

            var unsafe *r = dyn_cast<RecordType>(
                canon_unqual(c->rhs->canonical),
            )

            if r != &null
                && r->decl != &null
                && isa<Declarations::ClassDecl>(
                    Speller::rep(DeclFacts::decl_pattern(Speller::rep(r->decl))),
                ) {
                return r
            }
        }

        return &null
    }

    /// A Kairo base of \p d0 has a virtual destructor, so \p d0's
    /// `__kairo_layout()` overrides that base's and says so.
    static fn layout_overrides(d0: unsafe *Decl) -> bool {
        if d0 == &null {
            return false
        }

        var unsafe *cd = dyn_cast<Declarations::ClassDecl>(
            Speller::rep(DeclFacts::decl_pattern(Speller::rep(d0))),
        )

        if cd == &null {
            return false
        }

        for var i: usize = 0; i < cd->derives_list.size(); ++i {
            var unsafe *e = cd->derives_list.get(i)
            if e == &null || e->base == &null || e->base->canonical == &null {
                continue
            }

            var unsafe *bc = canon_unqual(e->base->canonical)
            if isa<GenericParamType>(bc) {
                var unsafe *pb = Speller::param_bound(
                    cast<GenericParamType>(bc),
                )

                if pb != &null && Speller::has_virtual_dtor(pb->decl, 1) {
                    return true
                }

                continue
            }

            if isa<RecordType>(bc) && Speller::has_virtual_dtor(cast<RecordType>(bc)->decl, 1) {
                return true
            }
        }

        return false
    }

    /// `static_assert(::ns::I_c<A, ...>, "...");` for each interface bound
    /// requires_clause kept off primary record \p d's head, at instance
    /// \p ie: written beside the home's explicit instantiation, where the
    /// arguments are complete, so a C++ disagreement with Kairo's check is
    /// still an error there. A pack parameter's bound is not pinned (no one
    /// argument to spell).
    fn bound_asserts(self,
                     d0: unsafe *Decl,
                     ie: unsafe *InstanceEntry) -> cxx::std::vector<string> {
        var out = cxx::std::vector<string>()
        if ie == &null || !Speller::defers_bounds(d0) {
            return out
        }

        var unsafe *d = Speller::rep(d0)
        var        cs = cxx::std::vector<unsafe *ConstraintExpr>()
        Speller::impl_bounds(DeclFacts::decl_requires_clause(d), unsafe &cs)
        for var i: usize = 0; i < cs.size(); ++i {
            var unsafe *c = cs[i]
            if c->rhs == &null || c->rhs->canonical == &null {
                continue
            }

            var unsafe *gp = Speller::_bound_param(c)
            if gp == &null || gp->is_pack || gp->owner == &null || Speller::rep(gp->owner) != d {
                continue
            }

            var at = (gp->index as usize)
            if at >= ie->args.size() {
                continue
            }

            var unsafe *rhs = canon_unqual(c->rhs->canonical)
            if !isa<RecordType>(rhs) {
                continue
            }

            var unsafe *idecl = Speller::rep(
                DeclFacts::decl_pattern(
                    Speller::rep(cast<RecordType>(rhs)->decl),
                ),
            )

            if !isa<Declarations::InterfaceDecl>(idecl) {
                continue
            }

            var subj = self._type(ie->args[at], &null)
            out.push_back(
                "static_assert(" + self.concept_name(idecl) + self.witness_args(
                    subj,
                    rhs,
                    ie,
                ) + ", \"Kairo checked this bound at the instance; C++ disagrees\");",
            )
        }

        return out
    }

    /// `static_assert(::ns::I_c<T>, "...");` for each interface bound of the
    /// generic record primary whose constructor \p f is, spelled over the
    /// record's own parameters: the record's C++ head carries none of them
    /// (defers_bounds: a head clause is checked where the template-id is
    /// named, over a CRTP base or a `*Holder<Node>` inside Node while the
    /// argument is still incomplete, and clang rejects those). A
    /// constructor's body is instantiated only when a value is made, when
    /// the argument is complete, so a C++ user making `Holder<Bad>` is told
    /// which bound failed instead of failing inside a witness call.
    /// Empty for anything else, and for a pack's bound (no one argument).
    fn ctor_bound_asserts(self, f: unsafe *Declarations::FunctionDecl) -> cxx::std::vector<string> {
        var out = cxx::std::vector<string>()
        if f == &null || f->semantic_dc == &null || !f->semantic_dc->is_type_scope() {
            return out
        }

        var unsafe *d = Speller::rep(f->semantic_dc->dc_owner)
        if d == &null
            || !Speller::defers_bounds(d)
            || DeclFacts::decl_generic_params(d).size() == 0 {
            return out
        }

        var cs = cxx::std::vector<unsafe *ConstraintExpr>()
        Speller::impl_bounds(DeclFacts::decl_requires_clause(d), unsafe &cs)
        for var i: usize = 0; i < cs.size(); ++i {
            var unsafe *c = cs[i]
            if c->rhs == &null || c->rhs->canonical == &null {
                continue
            }

            var unsafe *gp = Speller::_bound_param(c)
            if gp == &null || gp->is_pack || gp->owner == &null || Speller::rep(gp->owner) != d {
                continue
            }

            var unsafe *rhs = canon_unqual(c->rhs->canonical)
            if !isa<RecordType>(rhs) {
                continue
            }

            var unsafe *idecl = Speller::rep(
                DeclFacts::decl_pattern(
                    Speller::rep(cast<RecordType>(rhs)->decl),
                ),
            )

            if !isa<Declarations::InterfaceDecl>(idecl) {
                continue
            }

            var tn = self.tparam_name(gp, d)
            var msg = "\x27" + self.leaf(
                d,
            ) + "\x27 requires \x27" + tn + "\x27 to implement \x27" + self.leaf(
                idecl,
            ) + "\x27"
            out.push_back(
                "static_assert(" + self.concept_name(idecl) + self.witness_args(
                    tn,
                    rhs,
                ) + ", \"" + msg + "\");",
            )
        }

        return out
    }

    /// Every VALUE predicate of requires clause \p e (conjuncts that are not
    /// `T impl I` / `T derives B`), in clause order.
    static fn value_predicates(e: unsafe *Expr, out: unsafe *cxx::std::vector<unsafe *Expr>) {
        if e == &null {
            return
        }

        var unsafe *b = dyn_cast<BinaryOperatorExpr>(e)
        if b != &null
            && (b->op_token.kind == TokenKind::OpAmpAmp || b->op_token.kind == TokenKind::KwAnd) {
            Speller::value_predicates(b->lhs, out)
            Speller::value_predicates(b->rhs, out)
            return
        }

        if isa<ConstraintExpr>(e) {
            return
        }

        out->push_back(e)
    }

    /// The value predicates of generic record \p d's `requires` that its
    /// template head cannot carry (_pred_text is "": one naming an eval
    /// constant or fn, which the head -- written in tier 0, before any of
    /// them is declared -- cannot name). They are static_asserts in the
    /// record's body instead (InterfaceEmitter::_record_def; an ADT enum's
    /// in its record, _adt_def), evaluated per
    /// instance once the items are defined (EmitPlan::_decl_type_items puts
    /// them ahead of the record). Not on a specialization: its clause
    /// selects, and an assert would turn a non-match into an error.
    fn body_predicates(self, d: unsafe *Decl) -> cxx::std::vector<unsafe *Expr> {
        var out = cxx::std::vector<unsafe *Expr>()
        if !(isa<Declarations::ClassDecl>(d)
            || isa<Declarations::StructDecl>(d)
            || isa<Declarations::UnionDecl>(d)
            || isa<Declarations::EnumDecl>(d)) {
            return out
        }

        if Speller::template_params(d).size() == 0 || Speller::is_record_spec(d) {
            return out
        }

        var vps = cxx::std::vector<unsafe *Expr>()
        Speller::value_predicates(
            DeclFacts::decl_requires_clause(d),
            unsafe &vps,
        )

        for var i: usize = 0; i < vps.size(); ++i {
            if self._pred_text(vps[i]).size() == 0 {
                out.push_back(vps[i])
            }
        }

        return out
    }

    /// The value predicates of method \p m's `requires` as a C++20 trailing
    /// requires-clause (` requires (...)`), or "" when they stay its body's
    /// static_asserts (EmitIR::_body). Every home of a generic record writes
    /// its explicit instantiation (`template class B<X>;`), which
    /// instantiates every member body: an assert there failed each X the
    /// predicate rejects, whether or not anything called the member.
    /// As a clause, C++ leaves the member out for that X, and only a call is
    /// an error (ConformanceChecking reports it first, in Kairo's words).
    /// Only a non-template, non-virtual member of a generic record -- a
    /// member template is never instantiated by the record's, and a virtual
    /// function cannot be constrained -- and only when every predicate
    /// spells (_pred_text): the declaration and the out-of-line definition
    /// must carry the same clause, so it is all or none.
    fn member_requires(self, m: unsafe *Declarations::FunctionDecl, owner: unsafe *Decl) -> string {
        if m == &null || owner == &null || m->requires_clause == &null {
            return ""
        }

        if m->generic_params.size() > 0 {
            return ""
        }

        if m->abi == Declarations::AbiKind::Virtual
            || m->abi == Declarations::AbiKind::Override
            || m->body_kind == Declarations::FnBodyKind::Virtual {
            return ""
        }

        if DeclFacts::decl_generic_params(Speller::rep(owner)).size() == 0 {
            return ""
        }

        var vps = cxx::std::vector<unsafe *Expr>()
        Speller::value_predicates(m->requires_clause, unsafe &vps)
        var s = self._owner_impl_conjuncts(m, owner)
        for var i: usize = 0; i < vps.size(); ++i {
            var t = self._pred_text(vps[i], true)
            if t.size() == 0 {
                return ""
            }

            s += if (s.size() == 0) => (" requires (") else => " && "
            s += "(" + t + ")"
        }

        return if (s.size() > 0) => (s + ")") else => ""
    }

    /// ` requires (::ns::I_c<P> && ...`, unclosed, for each `P impl I` of
    /// member \p m's clause whose P is a parameter of \p owner, or "". The
    /// instance that does not meet it has no such member, so its body is
    /// never instantiated there.
    priv fn _owner_impl_conjuncts(self,
                                  m:     unsafe *Declarations::FunctionDecl,
                                  owner: unsafe *Decl) -> string {
        var tps = Speller::template_params(Speller::rep(owner))
        var cs  = cxx::std::vector<unsafe *ConstraintExpr>()
        Speller::impl_bounds(m->requires_clause, unsafe &cs)
        var s = ""
        for var i: usize = 0; i < cs.size(); ++i {
            var unsafe *c = cs[i]
            if c->rhs == &null || c->rhs->canonical == &null {
                continue
            }

            var unsafe *gp  = Speller::_bound_param(c)
            var        mine = false
            for var k: usize = 0; gp != &null && k < tps.size(); ++k {
                if tps[k] == gp {
                    mine = true
                    break
                }
            }

            var unsafe *rhs = canon_unqual(c->rhs->canonical)
            if !mine || gp->is_pack || !isa<RecordType>(rhs) {
                continue
            }

            var unsafe *idecl = Speller::rep(
                DeclFacts::decl_pattern(
                    Speller::rep(cast<RecordType>(rhs)->decl),
                ),
            )

            if !isa<Declarations::InterfaceDecl>(idecl) {
                continue
            }

            s += if (s.size() == 0) => (" requires (") else => " && "
            s += self.concept_name(idecl) + self.witness_args(
                self.tparam_name(gp, Speller::rep(gp->owner)),
                rhs,
            )
        }

        return s
    }

    /// A call of an `eval fn` whose whole body is `return f<P...>()` with f
    /// imported (`__builtin_is_trivially_copyable<T>()`, whose body is
    /// `return kairo_rt_is_trivially_copyable<T>()`): f at the call's
    /// written arguments, or "". The eval fn is declared after every record,
    /// so a clause inside one cannot name it; the runtime header declaring f
    /// comes before all of them.
    priv fn _pred_call(self, c: unsafe *CallExpr) -> string {
        if c == &null || c->args.size() != 0 || c->callee == &null {
            return ""
        }

        var unsafe *ce = c->callee
        while ce != &null && isa<ParenExpr>(ce) {
            ce = cast<ParenExpr>(ce)->inner
        }

        var unsafe *ni = dyn_cast<NamedIdentExpr>(ce)
        if ni == &null || ni->resolved_decl == &null {
            return ""
        }

        var unsafe *f = dyn_cast<Declarations::FunctionDecl>(
            Speller::rep(ni->resolved_decl),
        )

        if f == &null || !f->is_eval() || f->generic_params.size() == 0 {
            return ""
        }

        if ni->generic_args.size() != f->generic_params.size() {
            return ""
        }

        var unsafe *b = f->body_block
        if b == &null || b->body.size() != 1 {
            return ""
        }

        var unsafe *rs = dyn_cast<ReturnStmt>(b->body[0])
        if rs == &null || rs->value == &null {
            return ""
        }

        var unsafe *ie = rs->value
        while ie != &null && isa<ParenExpr>(ie) {
            ie = cast<ParenExpr>(ie)->inner
        }

        var unsafe *ic = dyn_cast<CallExpr>(ie)
        if ic == &null || ic->args.size() != 0 || ic->callee == &null {
            return ""
        }

        var unsafe *ini = dyn_cast<NamedIdentExpr>(ic->callee)
        if ini == &null || ini->resolved_decl == &null {
            return ""
        }

        var unsafe *target = Speller::rep(ini->resolved_decl)
        if !DeclFacts::decl_is_imported(target) {
            return ""
        }

        var s = ""
        for var i: usize = 0; i < ini->generic_args.size(); ++i {
            var unsafe *ga = ini->generic_args.get(i)
            if ga->ty == &null || ga->ty->canonical == &null {
                return ""
            }

            var unsafe *c0 = ga->ty->canonical
            while isa<QualifiedType>(c0) {
                c0 = cast<QualifiedType>(c0)->inner
            }

            var arg = ""
            if isa<GenericParamType>(c0) {
                // The eval fn's own parameter: the call's argument for it.
                var unsafe *g = cast<GenericParamType>(c0)
                if g->owner == &null || Speller::rep(g->owner) != f {
                    return ""
                }

                var k = (g->param_index as usize)
                if k >= ni->generic_args.size() {
                    return ""
                }

                var unsafe *wa = ni->generic_args.get(k)
                if wa->ty == &null || wa->ty->canonical == &null {
                    return ""
                }

                arg = self._type(wa->ty)
            } else {
                if c0->is_dependent() {
                    return ""
                }

                arg = self._type(ga->ty)
            }

            if arg.size() == 0 {
                return ""
            }

            s += if (i == 0) => (arg) else => ", " + arg
        }

        return self.qual_name(target) + "<" + s + ">()"
    }

    /// `P impl I<A...>` as `::ns::I_c<P, A...>`, for an interface bound on a
    /// template parameter; "" for anything else (a `derives` test, a
    /// pack).
    priv fn _concept_text(self, c: unsafe *ConstraintExpr) -> string {
        if c->is_derives() || c->rhs == &null || c->rhs->canonical == &null {
            return ""
        }

        var unsafe *gp = Speller::_bound_param(c)
        if gp == &null || gp->is_pack || gp->owner == &null {
            return ""
        }

        var unsafe *rhs = canon_unqual(c->rhs->canonical)
        if !isa<RecordType>(rhs) {
            return ""
        }

        var unsafe *idecl = Speller::rep(
            DeclFacts::decl_pattern(Speller::rep(cast<RecordType>(rhs)->decl)),
        )

        if !isa<Declarations::InterfaceDecl>(idecl) {
            return ""
        }

        return self.concept_name(idecl) + self.witness_args(
            self.tparam_name(gp, Speller::rep(gp->owner)),
            rhs,
        )
    }

    /// Generic function \p f's value predicates go in its template head
    /// (requires_clause) rather than its body's static_asserts (EmitIR::
    /// _body): when every one spells. C++ then selects among overloads by
    /// the same clauses Kairo did (`requires T impl I` beside `requires
    /// !(T impl I)`), and two overloads that differ only in a predicate are
    /// two templates rather than one redefined. All or none, because the
    /// declaration and the definition carry the same head.
    fn fn_preds_in_head(self, f: unsafe *Declarations::FunctionDecl) -> bool {
        if f == &null || f->requires_clause == &null || f->generic_params.size() == 0 {
            return false
        }

        var vps = cxx::std::vector<unsafe *Expr>()
        Speller::value_predicates(f->requires_clause, unsafe &vps)
        if vps.size() == 0 {
            return false
        }

        for var i: usize = 0; i < vps.size(); ++i {
            if self._pred_text(vps[i], true).size() == 0 {
                return false
            }
        }

        return true
    }

    /// C++ text of a self-contained predicate (requires_clause), or "".
    /// \p concepts admits `P impl I` as `I_c<P>`: a function's head and a
    /// member's trailing clause are checked where they are called, after
    /// every class is complete; a record's head is not (defers_bounds).
    priv fn _pred_text(self, e0: unsafe *Expr, concepts: bool = false) -> string {
        if e0 == &null {
            return ""
        }

        var unsafe *e = e0
        while e != &null && isa<ParenExpr>(e) {
            e = cast<ParenExpr>(e)->inner
        }

        if e == &null {
            return ""
        }

        if isa<IntegerLiteralExpr>(e) {
            var unsafe *lit = cast<IntegerLiteralExpr>(e)
            if lit->imm == &null || lit->get_value_hi() != (0 as u64) {
                return ""
            }

            return f"{lit->get_value_lo()}"
        }

        if isa<BooleanLiteralExpr>(e) {
            return (if (cast<BooleanLiteralExpr>(e)->value) => ("true") else => "false")
        }

        if isa<ConstraintExpr>(e) {
            return if (concepts) => (self._concept_text(cast<ConstraintExpr>(e))) else => ""
        }

        if isa<CallExpr>(e) {
            return self._pred_call(cast<CallExpr>(e))
        }

        if isa<TypeTraitExpr>(e) {
            var unsafe *tt = cast<TypeTraitExpr>(e)
            var        bi  = type_trait_cxx(tt->fact)
            if bi.size() == 0 || tt->type_arg == &null || tt->type_arg->canonical == &null {
                return ""
            }

            return bi + "(" + self._type(tt->type_arg) + ")"
        }

        if isa<SizeOfExpr>(e) {
            var unsafe *t = cast<SizeOfExpr>(e)->type_arg
            if t == &null || t->canonical == &null {
                return ""
            }

            return "sizeof(" + self._type(t) + ")"
        }

        if isa<AlignOfExpr>(e) {
            var unsafe *t = cast<AlignOfExpr>(e)->type_arg
            if t == &null || t->canonical == &null {
                return ""
            }

            return "alignof(" + self._type(t) + ")"
        }

        if isa<NamedIdentExpr>(e) {
            var unsafe *gp = dyn_cast<Declarations::GenericParamDecl>(
                cast<NamedIdentExpr>(e)->resolved_decl,
            )

            if gp == &null || !gp->is_const_param || gp->owner == &null {
                return ""
            }

            return self.tparam_name(gp, Speller::rep(gp->owner))
        }

        if isa<UnaryOperatorExpr>(e) {
            var unsafe *u = cast<UnaryOperatorExpr>(e)
            if u->resolved_op != &null {
                return ""
            }

            var k = u->op_token.kind
            var o = ""
            if k == TokenKind::OpExclaim || k == TokenKind::KwNot {
                o = "!"
            } else if k == TokenKind::OpMinus {
                o = "-"
            } else if k == TokenKind::OpTilde {
                o = "~"
            } else {
                return ""
            }

            var x = self._pred_text(u->operand, concepts)
            if x.size() == 0 {
                return ""
            }

            return o + "(" + x + ")"
        }

        if isa<BinaryOperatorExpr>(e) {
            var unsafe *b = cast<BinaryOperatorExpr>(e)
            if b->resolved_op != &null {
                return ""
            }

            var o = Speller::_pred_op(b->op_token.kind)
            if o.size() == 0 {
                return ""
            }

            var l = self._pred_text(b->lhs, concepts)
            var r = self._pred_text(b->rhs, concepts)
            if l.size() == 0 || r.size() == 0 {
                return ""
            }

            return "(" + l + ") " + o + " (" + r + ")"
        }

        return ""
    }

    static fn _pred_op(k: TokenKind) -> string {
        match k {
            case TokenKind::OpPlus,       TokenKind::OpMinus,          TokenKind::OpStar,
                 TokenKind::OpSlash,      TokenKind::OpPercent,        TokenKind::OpLess,
                 TokenKind::OpLessEqual,  TokenKind::OpGreater,        TokenKind::OpGreaterEqual,
                 TokenKind::OpEqualEqual, TokenKind::OpExclaimEqual,   TokenKind::OpAmpAmp,
                 TokenKind::KwAnd,        TokenKind::OpPipePipe,       TokenKind::KwOr,
                 TokenKind::OpAmp,        TokenKind::KwBitand,         TokenKind::OpPipe,
                 TokenKind::KwBitor,      TokenKind::OpCaret,          TokenKind::KwXor,
                 TokenKind::OpLessLess,   TokenKind::OpGreaterGreater {
                return OperatorFacts::cxx_symbol(k)
            } default {
                return ""
            }
        }
    }

    /// The generic parameter a conjunct constrains, or null.
    static fn _bound_param(c: unsafe *ConstraintExpr) -> unsafe *Declarations::GenericParamDecl {
        var unsafe *id = dyn_cast<NamedIdentExpr>(c->lhs)
        if id == &null {
            return &null
        }

        return dyn_cast<Declarations::GenericParamDecl>(id->resolved_decl)
    }

    /// Every `impl` conjunct of requires clause \p e, in clause order.
    static fn impl_bounds(e: unsafe *Expr, out: unsafe *cxx::std::vector<unsafe *ConstraintExpr>) {
        if e == &null {
            return
        }

        var unsafe *b = dyn_cast<BinaryOperatorExpr>(e)
        if b != &null
            && (b->op_token.kind == TokenKind::OpAmpAmp || b->op_token.kind == TokenKind::KwAnd) {
            Speller::impl_bounds(b->lhs, out)
            Speller::impl_bounds(b->rhs, out)
            return
        }

        var unsafe *c = dyn_cast<ConstraintExpr>(e)
        if c != &null && !c->is_derives() {
            out->push_back(c)
        }
    }

    /// Generic parameter \p gp of \p owner by name (rename_tparams).
    fn tparam_name(self,
                   gp:    unsafe *Declarations::GenericParamDecl,
                   owner: unsafe *Decl) -> string {
        if self.rename_tparams != &null {
            if self._renamed_for != self.rename_tparams {
                self._renamed_for = self.rename_tparams
                self._renamed = Speller::template_params(self.rename_tparams)
            }

            for var i: usize = 0; i < self._renamed.size(); ++i {
                if self._renamed[i] == gp {
                    return LowerTargets::friend_tparam(i)
                }
            }
        }

        return self.tok_name(gp->name, Speller::fid_of(owner))
    }

    /// `template <class T, class... Ts, int N>` for a generic decl; "" otherwise.
    fn template_head(self, d_in: unsafe *Decl) -> string {
        var unsafe *d = d_in
        // A generic function declared and then defined is one entity whose
        // links may name their parameters differently (`fn <U> m` in the
        // class, `fn <W> C::m` out of line). Every canonical `U` / `W` is
        // spelled through the representative (_gparam), so every link's head
        // is the representative's too: one set of names, one requires.
        if isa<Declarations::FunctionDecl>(d) {
            var unsafe *r = Speller::rep(d)
            if r != &null
                && r != d
                && DeclFacts::decl_generic_params(r).size() == DeclFacts::decl_generic_params(
                    d,
                ).size() {
                d = r
            }
        }

        if Speller::is_fn_spec(d) {
            return "template <> "
        }

        var gps = Speller::template_params(d)
        if gps.size() == 0 {
            return ""
        }

        var s = "template <"
        for var i: usize = 0; i < gps.size(); ++i {
            var unsafe *gp = gps[i]
            if i > 0 {
                s += ", "
            }

            if gp->is_const_param {
                s += self._type(gp->value_type)
            } else {
                s += "class"
            }

            if gp->is_pack {
                s += "..."
            }

            s += " "
            s += self.tparam_name(gp, d)
        }

        s += ">"
        s += self.requires_clause(d)
        s += " "
        return s
    }
}
