/// --- The Kairo Project ------------------- Codegen/Emit/EmitWitness.k --- ///
///
///   \brief Interface witnesses: the class template a generic body's call
///          through an interface bound goes through, its concept, and the
///          specializations for the conformances the template cannot reach.
///
///   \detail
///     Compiler/Spec/Witnesses.md is the contract. For `interface Scalable { fn
///     scale(const self, f: i32) -> i32 }` in module `ring`:
///
///       template <class __kairo_Self> struct Scalable_witness {        primary
///           static signed int scale(const __kairo_Self* self, signed int f)
///               requires requires { static_cast<auto (__kairo_Self::*)(signed
///                   int) const -> signed int>(&__kairo_Self::scale); }
///           { return self->scale(static_cast<decltype(f)&&>(f)); }
///       };
///       template <class __kairo_Self> concept Scalable_c = requires (...) {
///           ... };
///       template <> struct Scalable_witness<::ring::Metric> {           a row
///           static signed int scale(const ::ring::Metric* self, signed int f)
///           { return ::ring::__kairo_ext_Metric::scale(self,
///               static_cast<decltype(f)&&>(f)); }
///       };
///
///     The primary forwards to MEMBERS, constrained on an exact member
///     signature so a TU that lacks a specialization fails to compile rather
///     than compile a different witness (§7b.3). A row whose every
///     requirement is such a member needs nothing; any other row -- an
///     extension member, a builtin conformer, an imported member -- is a
///     specialization forwarding to the decls the row names (§7b.4).
///
///     Every witness member is declared as the requirement would be as an
///     extension member of Self, so the call site takes ExtensionLowering's
///     receiver rules unchanged: `[const ]Self*`, or `[const ]Self&` for an
///     operator, named as an extension operator is. Arguments are forwarded
///     as `static_cast<decltype(p)&&>(p)`, as operator forwarders do.
///
///     Built: named, operator and static requirements (a static member,
///     gated on a plain function pointer and called through Self), generic
///     requirements, named and operator (a member template, gated on the
///     callable form and left out of the concept, §7b.7), and every row
///     with a concrete conformer (a full specialization each, also for a row
///     a generic extension supplies structurally), a GENERIC declared
///     conformance (`extend <E> Wrap<E> impl I`: one partial
///     specialization, headed by the declaring decl, which the concrete
///     rows it covers use in place of their own), and requirements
///     inherited through a generic interface instance, concrete or
///     dependent (§7b.9), and constructor requirements: no member anywhere,
///     since `T(args)` is already the C++ for every conformer, only a
///     concept clause (§7b.3). Associated types
///         (Compiler/Spec/Interfaces.md#associated-types): every row
///     of an interface that declares one is a specialization, which opens
///     with `using Node = <the conformer's type>;`; the primary declares
///     none and leaves out every member whose signature names one, so a
///     type with no specialization fails the concept's `typename
///     I_witness<Self>::Node;` clause instead of hard-erroring inside the
///     primary's instantiation; a bounded body spells `T::Node` as
///     `typename I_witness<T>::Node` (CXXSpell::assoc_spelling).
///
///   Import law: CodegenContext only.
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
ffi "c++" import "llvm/Support/Allocator.h"
ffi "c++" import "memory"

import AST::Context::InstantiationRegistry::{
    ConformanceRow,
    InstanceEntry,
}
import AST::DeclFacts::{
    decl_extension_of, decl_generic_params, decl_is_ctor_requirement, decl_is_imported,
    decl_is_instance,  decl_is_requirement, decl_pattern,
}
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
import AST::Node::Declarations::{
    FunctionDecl,
    InterfaceDecl,
    ParamDecl,
    TypeAliasDecl,
}
import AST::Node::Types::{
    FixedArrayType,
    PointerType,
}
import Codegen::CodegenContext::CodegenContext
import Codegen::CodegenICE::codegen_ice
import Codegen::Emit::CXXSpell::CXXSpell
import Location::SourceRange::SourceRange
import Token::TokenKind::TokenKind

/// One witness plan entry: an interface's primary and concept (`row`
/// null), or one conformance row's specialization. EmitPlan's, like
/// ExtScope: tier 0 declares a primary, tier 1 defines either kind.
pub class WitnessPiece {
    pub var iface: unsafe *Decl           = &null ///< the InterfaceDecl's representative.
    pub var row:   unsafe *ConformanceRow = &null ///< null for the primary.
    /// Tier-1 decls the definition needs complete: by-value records in a
    /// member signature, and a specialization's conformer.
    pub var deps: cxx::std::vector<unsafe *Decl>
    /// A specialization's extension scopes (EmitPlan's `_scopes` indexes):
    /// it calls their static members, so it follows their definitions.
    pub var scopes: cxx::std::vector<usize>
    /// Interfaces whose primary (and concept) must come first: a
    /// specialization's own interface, a concept's bases.
    pub var after: cxx::std::vector<unsafe *Decl>
    /// The identity across plans and includes: the witness and its Self.
    pub var key: string
    /// A `std::hash<K>` ADAPTER for `row` (K impl Hash), not a witness: an
    /// imported C++ container keyed by a Kairo record (`cxx::std::
    /// unordered_map<string, V>`) defaults its hasher to `std::hash<K>`,
    /// whose primary is disabled for any type C++ was not told about. Tier
    /// 0 declares the specialization in namespace std, its call operator
    /// only declared, so it precedes every record whose field instantiates
    /// the hasher (K need only be declared); tier 1 defines the operator,
    /// forwarding to `Hash_witness<K>::hash`, after the row's
    /// specialization when it has one. Equality needs nothing: libc++'s
    /// `std::equal_to<K>` is `a == b`, and Hash's `op ==` is a member.
    pub var std_hash: bool = false
    fn WitnessPiece(self) { }
}

pub class EmitWitness {
    priv var _cg:    unsafe *CodegenContext
    priv var _spell: unsafe *CXXSpell
    /// Substitutions for requirements inherited through a DEPENDENT generic
    /// instance (members_with): no registry entry exists for one, so they
    /// are minted here and live as long as this emitter, which outlives
    /// every member list it hands out. `_dep_src` is parallel: the source
    /// type each was made for, so one leaf's requirements share an entry.
    priv var _dep_arena: llvm::SpecificBumpPtrAllocator<InstanceEntry>
    priv var _dep_src:   cxx::std::vector<unsafe *Type>
    priv var _dep_ent:   cxx::std::vector<unsafe *InstanceEntry>

    fn EmitWitness(self, cg: unsafe *CodegenContext, spell: unsafe *CXXSpell) {
        self._cg    = cg
        self._spell = spell
    }

    priv fn _ice(self, at: SourceRange, const msg: string) {
        codegen_ice(self._cg->ctx, at, msg)
    }

    /// # the members

    /// \p idecl's requirements as witness members, PARALLEL to its composed
    /// requirement list (and so to a row's witnesses): null for an
    /// associated type, which has no member yet. An interface never composed
    /// (poisoned upstream) gives its own methods.
    fn members(self, idecl: unsafe *InterfaceDecl) -> cxx::std::vector<unsafe *FunctionDecl> {
        var substs = cxx::std::vector<unsafe *InstanceEntry>()
        return self.members_with(idecl, &substs)
    }

    /// members(), and per member the instance entry its types are spelled
    /// through: a requirement inherited through a CONCRETE generic instance
    /// (`derives Container<i32>`) is spelled at that instance's arguments,
    /// as a specialization's are. Null for an own member or a non-generic
    /// source -- the caller's own substitution applies.
    ///
    /// One inherited through a DEPENDENT instance (`interface <T> F derives
    /// Container<T>`) is two substitutions deep: Container's E is F's T, and
    /// F's T is the row's argument. Without \p row (the primary, the
    /// concept) only the first applies, and it is enough: the text is
    /// written inside F's template, where F's T is in scope. With \p row (a
    /// specialization) the source as Sema substituted it at the row's
    /// arguments (ConformanceRow::sources, `Container<i32>`) is a concrete
    /// instance, and its entry is both at once -- or, for a generic row, an
    /// instance over the declaring decl's parameters (`Container<E>`),
    /// spelled through _dep_subst inside the partial specialization.
    fn members_with(self,
                    idecl:         unsafe *InterfaceDecl,
                    @inout substs: cxx::std::vector<unsafe *InstanceEntry>,
                    row:           unsafe *ConformanceRow = &null) -> cxx::std::vector<unsafe *FunctionDecl> {
        var out = cxx::std::vector<unsafe *FunctionDecl>()
        if idecl->compose_state != 2 {
            for var i: usize = 0; i < idecl->methods.size(); ++i {
                out.push_back(idecl->methods[i])
                substs.push_back(&null)
            }

            return out
        }

        var unsafe *me = CXXSpell::rep(idecl)
        for var i: usize = 0; i < idecl->requirements.size(); ++i {
            var unsafe *r                         = idecl->requirements.get(i)
            var unsafe *f                         = dyn_cast<FunctionDecl>(r->decl)
            var        sub: unsafe *InstanceEntry = &null
            if f != &null && r->source != &null && isa<RecordType>(canon_unqual(r->source)) {
                var unsafe *src = cast<RecordType>(canon_unqual(r->source))
                var unsafe *sd  = CXXSpell::rep(decl_pattern(CXXSpell::rep(src->decl)))
                if sd != me && decl_generic_params(sd).size() > 0 {
                    if !src->is_dependent() {
                        sub = self._iface_subst(unsafe (src as unsafe *Type))
                    } else if row == &null {
                        sub = self._dep_subst(sd, src)
                    } else {
                        var unsafe *at_row = if (i < row->sources.size()) => (row->sources[i])
                                             else => &null
                        sub = self._subst_of(at_row)
                        // A row's sources are at its own arguments: instances,
                        // or for a generic row instances over its declaring
                        // decl's parameters; a null here would spell the
                        // leaf's own parameters, which are not in scope.
                        if sub == &null {
                            self._ice(
                                CXXSpell::at(r->decl),
                                "EmitWitness: a row with no source for an inherited requirement; ConformanceChecking records it at the row's arguments",
                            )
                        }
                    }
                }
            }

            out.push_back(f)
            substs.push_back(sub)
        }

        return out
    }

    /// # the decision (§7b.4)

    /// False when the primary serves \p row: every requirement is met by a
    /// member function of a Kairo record conformer whose C++ signature is
    /// the witness member's forwarded-to signature exactly. Decided from
    /// spellings, never by lookup; an imported member is always
    /// specialized, since its C++ type is not Kairo's to compare.
    fn needs_specialization(self, row: unsafe *ConformanceRow) -> bool {
        if row == &null || row->conformer == &null {
            return true
        }

        // The associated types are the specialization's member types, and
        // the primary declares none (see the file header).
        if self.has_assoc(cast<InterfaceDecl>(row->iface_decl)) {
            return true
        }

        // Nothing to forward -- every requirement a constructor (or an
        // associated type) -- and the primary is already right, for a
        // builtin conformer too: an empty specialization would be noise.
        if !self._has_members(cast<InterfaceDecl>(row->iface_decl)) {
            return false
        }

        if !isa<RecordType>(row->conformer) { // a builtin has no members.
            return true
        }

        var unsafe *x = cast<RecordType>(row->conformer)->decl
        if decl_is_imported(CXXSpell::rep(x)) {
            return true
        }

        var unsafe *idecl = cast<InterfaceDecl>(row->iface_decl)
        var unsafe *subst = self._subst_of(row->iface)
        var        subs   = cxx::std::vector<unsafe *InstanceEntry>()
        var        ms     = self.members_with(idecl, &subs, row)
        for var i: usize = 0; i < ms.size(); ++i {
            var unsafe *m = ms[i]
            if m == &null { // an associated type: no member yet.
                continue
            }

            // A constructor slot has no member to forward to, and its witness
            // may be the record itself (its implicit default constructor).
            if decl_is_ctor_requirement(m) {
                continue
            }

            var unsafe *w = dyn_cast<FunctionDecl>(
                if (i < row->witnesses.size()) => (row->witnesses[i]) else => &null,
            )

            if w == &null {
                return true
            }

            if decl_extension_of(w) != &null {
                return true
            }

            if decl_is_imported(w) {
                return true
            }

            if w->is_operator != m->is_operator {
                return true
            }

            var unsafe *ms_sub = if (subs[i] != &null) => (subs[i]) else => subst
            if self._member_sig(w, &null, "") != self._member_sig(
                m,
                ms_sub,
                self._spell->_type(row->conformer),
            ) {
                return true
            }
        }

        return false
    }

    /// \p idecl (composed) requires an associated type, generic or not.
    fn has_assoc(self, idecl: unsafe *InterfaceDecl) -> bool {
        if idecl == &null || idecl->compose_state != 2 {
            return false
        }

        for var i: usize = 0; i < idecl->requirements.size(); ++i {
            if isa<TypeAliasDecl>(idecl->requirements.get(i)->decl) {
                return true
            }
        }

        return false
    }

    /// \p m's signature names an associated type: the primary has no
    /// member type to spell it with.
    priv fn _names_assoc(self, m: unsafe *FunctionDecl) -> bool {
        if CXXSpell::mentions_assoc(m->return_type) {
            return true
        }

        for var i: usize = 0; i < m->params.size(); ++i {
            var unsafe *p = m->params[i]
            if p != &null && !p->is_self && CXXSpell::mentions_assoc(p->type_) {
                return true
            }
        }

        return false
    }

    /// Some requirement of \p idecl is a witness member: neither an
    /// associated type nor a constructor.
    priv fn _has_members(self, idecl: unsafe *InterfaceDecl) -> bool {
        var ms = self.members(idecl)
        for var i: usize = 0; i < ms.size(); ++i {
            if ms[i] != &null && !decl_is_ctor_requirement(ms[i]) {
                return true
            }
        }

        return false
    }

    /// `R (P1, P2) const` of a member, as the member pointer cast spells it,
    /// with \p m's bare Self spelled \p self_s (empty: \p m has none).
    priv fn _member_sig(self,
                        m:            unsafe *FunctionDecl,
                        subst:        unsafe *InstanceEntry,
                        const self_s: string) -> string {
        return self._member_ret(m, subst, self_s) + " " + self._member_params(m, subst, self_s)
    }

    /// \p m's return type as _member_sig spells it, Self read as \p self_s.
    priv fn _member_ret(self,
                        m:            unsafe *FunctionDecl,
                        subst:        unsafe *InstanceEntry,
                        const self_s: string) -> string {
        var unsafe *saved_i = self._spell->self_iface
        var        saved_s  = self._spell->self_spelling
        if self_s.size() > 0 {
            self._self_as(m, self_s)
        }

        var r = self._ret(m, subst)
        self._spell->self_iface    = saved_i
        self._spell->self_spelling = saved_s
        return r
    }

    /// `(params) [const]`, the rest of _member_sig after the return type.
    priv fn _member_params(self,
                           m:            unsafe *FunctionDecl,
                           subst:        unsafe *InstanceEntry,
                           const self_s: string) -> string {
        var unsafe *saved_i = self._spell->self_iface
        var        saved_s  = self._spell->self_spelling
        if self_s.size() > 0 {
            self._self_as(m, self_s)
        }

        var s        = "("
        var k: usize = 0
        for var i: usize = 0; i < m->params.size(); ++i {
            var unsafe *p = m->params[i]
            if p == &null || p->is_self {
                continue
            }

            if k > 0 {
                s += ", "
            }

            s += self._spell->param_decl(p, "", subst)
            k += 1
        }

        if CXXSpell::op_is_postfix(m) {
            s += if (k > 0) => (", int") else => "int"
        }

        s += ")"
        if m->is_const() {
            s += " const"
        }

        self._spell->self_iface    = saved_i
        self._spell->self_spelling = saved_s
        return s
    }

    /// # text

    /// Tier 0: `template <class __kairo_Self, ...> struct I_witness;`.
    fn fwd(self, p: unsafe *WitnessPiece) {
        if p->std_hash {
            self._std_hash_decl(p)
            return
        }

        self._cg->sink->spell(
            self._at(p),
            self._head(p->iface) + " struct " + self._leaf_witness(p->iface) + ";",
        )
    }

    /// Tier 1: the primary, or a row's specialization.
    fn def(self, p: unsafe *WitnessPiece) {
        if p->std_hash {
            self._std_hash_def(p)
            return
        }

        if p->row == &null {
            self._primary(p)
            return
        }

        self._specialization(p)
    }

    /// Tier 0, inside `namespace std`: the adapter's class (WitnessPiece::
    /// std_hash). Its operator is defined out of line (_std_hash_def), so
    /// the class needs K declared only.
    priv fn _std_hash_decl(self, p: unsafe *WitnessPiece) {
        var x = self._spell->_type(p->row->conformer)
        self._cg->sink->spell(
            self._at(p),
            "template <> struct " + LowerTargets::cxx_std_hash_leaf() + "<" + x + "> { " + LowerTargets::cxx_size_t() + " operator()(const " + x + " & v) const noexcept; };",
        )
    }

    /// Tier 1, inside `namespace std`: the adapter's operator, the Kairo
    /// hash through the witness -- the same call a `{K: V}` makes.
    priv fn _std_hash_def(self, p: unsafe *WitnessPiece) {
        var x = self._spell->_type(p->row->conformer)
        var w = self._spell->witness_name(p->iface) + self._spell->witness_args(x, p->row->iface)
        self._cg->sink->spell(
            self._at(p),
            "inline " + LowerTargets::cxx_size_t() + " " + LowerTargets::cxx_std_hash_leaf() + "<" + x + ">::operator()(const " + x + " & v) const noexcept { return " + w + "::hash(&v); }",
        )

        self._cg->sink->brk()
    }

    /// Tier 0: the concept. Ahead of every head that names it -- a bounded
    /// record's forward declaration included -- and of the primary's
    /// definition: it names only the declared witness, and its
    /// requires-parameters need their types declared, not complete.
    fn concept_def(self, p: unsafe *WitnessPiece) {
        self._concept(p)
    }

    priv fn _primary(self, p: unsafe *WitnessPiece) {
        var unsafe *idecl = cast<InterfaceDecl>(p->iface)
        var        at     = self._at(p)
        var        me     = LowerTargets::witness_self()
        self._cg->sink->spell(
            at,
            self._head(p->iface) + " struct " + self._leaf_witness(p->iface) + " {",
        )

        var subs = cxx::std::vector<unsafe *InstanceEntry>()
        var ms   = self.members_with(idecl, &subs)
        for var i: usize = 0; i < ms.size(); ++i {
            var unsafe *m = ms[i]
            if m == &null || m->is_poisoned() || decl_is_ctor_requirement(m) {
                continue
            }

            if self._names_assoc(m) { // the specializations' alone.
                continue
            }

            var decl  = self._member_decl(m, subs[i], me)
            var leaf  = self._spell->leaf(unsafe (m as unsafe *Decl))
            var targs = self._own_args(m)
            var gate  = ""
            if targs.size() > 0 {
                // A GENERIC requirement has no member pointer to cast without
                // its arguments: the gate is the callable form, the one corner
                // that keeps 7b.3's hazard (§7b.12, question 6).
                gate = "requires requires { " + self._member_call(
                    m,
                    me,
                    LowerTargets::witness_receiver_name(),
                    "template " + leaf + targs,
                ) + "; }"
            } else {
                // A static requirement is gated on a plain function pointer: a
                // static member's address is not a pointer to member.
                var owner = if (m->is_method()) => (me) else => ""
                gate = "requires requires { static_cast<" + self._pointer_to_member(
                    m,
                    subs[i],
                    me,
                    owner,
                ) + ">(&" + me + "::" + leaf + "); }"
            }

            var call = self._member_call(m, me, LowerTargets::witness_receiver_name(), (if (targs.size() > 0) => ("template " + leaf + targs) else => leaf))
            self._cg->sink->spell(
                CXXSpell::at(unsafe (m as unsafe *Decl)),
                decl + " " + gate + " { return " + call + "; }",
            )
        }

        self._cg->sink->spell(at, "};")
        self._cg->sink->brk()
    }

    /// `I_c<S, A...> = (bases' concepts) && requires (...) { each member; }`.
    /// True for every instance Kairo enumerated (ConformanceChecking proved
    /// its row); its job is the instantiations Kairo cannot see (§7b.7).
    priv fn _concept(self, p: unsafe *WitnessPiece) {
        var unsafe *idecl    = cast<InterfaceDecl>(p->iface)
        var        me        = LowerTargets::witness_self()
        var        self_args = self._self_params(p->iface)
        var s = self._head(p->iface) + " concept " + self._leaf_concept(p->iface) + " = "
        // No base concepts: the requirement list already holds everything
        // the interface derives (InterfaceComposition, D4).
        var conj          = ""
        var parms         = ""
        var body          = ""
        var k:      usize = 0
        var subs          = cxx::std::vector<unsafe *InstanceEntry>()
        var ms            = self.members_with(idecl, &subs)
        var saved_q       = self._spell->assoc_self_qual
        self._spell->assoc_self_qual = self._spell->witness_name(p->iface) + self_args
        for var i: usize = 0; i < ms.size(); ++i {
            var unsafe *m = ms[i]
            if m == &null || m->is_poisoned() {
                continue
            }

            // A generic requirement has no argument to call it with (§7b.7).
            if m->generic_params.size() > 0 {
                continue
            }

            // A constructor requirement is the one clause that names no
            // witness member: `__kairo_Self(a0)`, the construction a bounded
            // body's `T(args)` performs, so a host's class without it fails
            // at the call.
            var ctor = decl_is_ctor_requirement(m)
            // A static requirement is called with no receiver.
            var args = ""
            var fwd  = ""
            if m->is_method() && !ctor {
                var r = LowerTargets::witness_recv(i)
                if parms.size() > 0 {
                    parms += ", "
                }

                parms += self._receiver(m, me) + " " + r
                args = r
            }

            var unsafe *saved_i = self._spell->self_iface
            var        saved_s  = self._spell->self_spelling
            self._self_as(m, me)
            for var j: usize = 0; j < m->params.size(); ++j {
                var unsafe *q = m->params[j]
                if q == &null || q->is_self {
                    continue
                }

                var a = LowerTargets::witness_arg(k)
                k += 1
                if parms.size() > 0 {
                    parms += ", "
                }

                parms += self._spell->param_decl(q, a, subs[i])
                if args.size() > 0 {
                    args += ", "
                }

                args += a
                // Forwarded as the witness forwards: a by-value `other: Self`
                // is then an rvalue, so a `@move` requirement's clause asks
                // for a move constructor, not a copy one.
                if fwd.size() > 0 {
                    fwd += ", "
                }

                fwd += "static_cast<decltype(" + a + ")&&>(" + a + ")"
            }

            self._spell->self_iface    = saved_i
            self._spell->self_spelling = saved_s
            if ctor {
                body += " " + me + "(" + fwd + ");"
                continue
            }

            if CXXSpell::op_is_postfix(m) {
                args += (if (args.size() > 0) => (", ") else => "") + "0"
            }

            body += " " + self._spell->witness_name(
                p->iface,
            ) + self_args + "::" + self._spell->witness_member_name(m) + "(" + args + ");"
        }

        self._spell->assoc_self_qual = saved_q
        // Each associated type first: a type with no specialization has none,
        // and fails here rather than at a member that names it.
        var tn = ""
        if idecl->compose_state == 2 {
            for var i: usize = 0; i < idecl->requirements.size(); ++i {
                var unsafe *ta = dyn_cast<TypeAliasDecl>(idecl->requirements.get(i)->decl)
                // A generic associated type has no argument to probe it
                // with, as a generic requirement has none to call it with.
                if ta == &null || ta->generic_params.size() > 0 {
                    continue
                }

                tn += " typename " + self._spell->witness_name(
                    p->iface,
                ) + self_args + "::" + self._spell->leaf(ta) + ";"
            }
        }

        if tn.size() > 0 {
            if conj.size() > 0 {
                conj += " && "
            }

            conj += "requires {" + tn + " }"
        }

        if body.size() > 0 {
            if conj.size() > 0 {
                conj += " && "
            }

            conj += if (parms.size() == 0) => ("requires {") else => "requires (" + parms + ") {"
            conj += body + " }"
        }

        if conj.size() == 0 {
            conj = "true"
        }

        self._cg->sink->spell(self._at(p), s + conj + ";")
        self._cg->sink->brk()
    }

    priv fn _specialization(self, p: unsafe *WitnessPiece) {
        var unsafe *row   = p->row
        var unsafe *idecl = cast<InterfaceDecl>(row->iface_decl)
        var        at     = self._at(p)
        var unsafe *subst = self._subst_of(row->iface)
        var        x      = self._spell->_type(row->conformer)
        self._cg->sink->spell(
            at,
            self._spec_head(row) + "struct " + self._leaf_witness(
                p->iface,
            ) + self._spell->witness_args(x, row->iface) + " {",
        )

        // A pointer conformer is named through an alias inside: the members
        // spell Self as text, and `const ` in front of `int *` would make
        // `const int *` (a pointer to const) where `const Self` is meant.
        // An array conformer likewise: `const int[2] *` is no type, and
        // `const __kairo_Self *` is the pointer to the array (P946).
        var is_ptr = isa<PointerType>(canon_unqual(row->conformer))
        if is_ptr || isa<FixedArrayType>(canon_unqual(row->conformer)) {
            self._cg->sink->spell(at, "using " + LowerTargets::witness_self() + " = " + x + ";")
            x = LowerTargets::witness_self()
        }

        // The associated types, ahead of the members whose signatures name
        // them: the conformer's alias, or the default it took.
        if idecl->compose_state == 2 {
            for var i: usize = 0; i < idecl->requirements.size(); ++i {
                var unsafe *ta = dyn_cast<TypeAliasDecl>(idecl->requirements.get(i)->decl)
                if ta == &null {
                    continue
                }

                var unsafe *at_t = if (i < row->assoc_types.size()) => (row->assoc_types[i])
                                   else => &null
                if at_t == &null {
                    self._ice(
                        CXXSpell::at(unsafe (ta as unsafe *Decl)),
                        "EmitWitness: a row with no type for an associated type; ConformanceChecking records only complete rows on an instance",
                    )
                }

                self._cg->sink->spell(
                    CXXSpell::at(unsafe (ta as unsafe *Decl)),
                    self._assoc_head(ta, row, i) + "using " + self._spell->leaf(
                        ta,
                    ) + " = " + self._spell->_type(at_t, subst) + ";",
                )
            }
        }

        var subs = cxx::std::vector<unsafe *InstanceEntry>()
        var ms   = self.members_with(idecl, &subs, row)
        for var i: usize = 0; i < ms.size(); ++i {
            var unsafe *m = ms[i]
            if m == &null || m->is_poisoned() || decl_is_ctor_requirement(m) {
                continue
            }

            var unsafe *w = dyn_cast<FunctionDecl>(
                if (i < row->witnesses.size()) => (row->witnesses[i]) else => &null,
            )

            if w == &null {
                self._ice(
                    CXXSpell::at(m),
                    "EmitWitness: a row with no decl for a requirement; ConformanceChecking records only complete rows on an instance",
                )
            }

            var decl = self._member_decl(m, if (subs[i] != &null) => (subs[i]) else => subst, x)
            var ea   = cxx::std::vector<unsafe *Type>()
            row->ext_args_of(i, &ea)
            var call = self._target(w, m, x, unsafe &ea, row->conformer->is_dependent(), is_ptr)
            // A conformer met structurally keeps its own result: a
            // smaller set's panic result, or a plain value when it does not
            // panic. A declared one returns the requirement's
            // (PanicLowering::_requirement_of), but one method may meet many
            // interfaces, so the witness converts instead, as a widened `fn`
            // value does: `__kairo_pcall<R>` forwards a panic result whole
            // and makes a plain value (or nothing) Ok.
            var unsafe *msub = if (subs[i] != &null) => (subs[i]) else => subst
            if m->panic_result != &null
                && self._member_ret(w, &null, "") != self._member_ret(m, msub, x) {
                var nx = if (self._cg->opts.unwind) => ("") else => " noexcept"
                call = "::" + LowerTargets::panic_call_as() + "<" + self._member_ret(
                    m,
                    msub,
                    x,
                ) + ">([&]()" + nx + " { return " + call + "; })"
            }

            self._cg->sink->spell(CXXSpell::at(m), decl + " { return " + call + "; }")
        }

        self._cg->sink->spell(at, "};")
        self._cg->sink->brk()
    }

    /// `template <class K> ` for generic associated type \p ta in \p row:
    /// the member alias template's parameters are those of the decl that
    /// supplies it (the conformer's `type <K> Map = ...`, or the requirement
    /// for a default), since the row's type is spelled over them. "" for a
    /// plain associated type.
    priv fn _assoc_head(self,
                        ta:  unsafe *TypeAliasDecl,
                        row: unsafe *ConformanceRow,
                        i:   usize) -> string {
        if ta->generic_params.size() == 0 {
            return ""
        }

        var unsafe *w = if (i < row->witnesses.size()) => (row->witnesses[i]) else => &null
        if w == &null {
            w = unsafe (ta as unsafe *Decl)
        }

        var gps = decl_generic_params(CXXSpell::rep(w))
        if gps.size() != ta->generic_params.size() {
            self._ice(
                CXXSpell::at(unsafe (ta as unsafe *Decl)),
                "EmitWitness: a generic associated type supplied by a decl of another arity; ConformanceChecking matches arities",
            )
        }

        var s = "template <"
        for var k: usize = 0; k < gps.size(); ++k {
            if k > 0 {
                s += ", "
            }

            s += "class "
            s += self._spell->imm_name(gps[k]->name.imm, CXXSpell::fid_of(CXXSpell::rep(w)))
        }

        return s + "> "
    }

    /// The call a specialization member makes: the extension member,
    /// qualified, receiver first (none for a static); or the conformer's own
    /// member, through \p x for a static.
    priv fn _target(self,
                    w:        unsafe *FunctionDecl,
                    m:        unsafe *FunctionDecl,
                    const x:  string,
                    ext_args: unsafe *cxx::std::vector<unsafe *Type>,
                    dep:      bool,
                    ptr:      bool = false) -> string {
        var args = self._forward(m)
        // The requirement as its own witness: the conformer's native `==`
        // (ConformanceChecking::_native_implementation), a builtin's or an
        // imported record's, member or free -- C++ picks it here.
        if decl_is_requirement(w) {
            // The Hash lang item's `hash` (ConformanceChecking::_is_std_hash_slot,
            // the only named requirement Sema lets stand as its own
            // witness): a pointer's is its address -- HashMap mixes every
            // hash before it indexes, so an identity hash is enough -- and an
            // imported C++ type's is `std::hash<X>`.
            if !m->is_operator {
                if ptr {
                    return "reinterpret_cast<" + LowerTargets::cxx_size_t() + ">(*" + LowerTargets::witness_receiver_name() + ")"
                }

                return "static_cast<" + LowerTargets::cxx_size_t() + ">(" + LowerTargets::cxx_std_hash() + "<" + x + ">{}(*" + LowerTargets::witness_receiver_name() + "))"
            }

            if m->op_token.size() != 1 || m->op_token[0].kind != TokenKind::OpEqualEqual {
                self._ice(
                    CXXSpell::at(unsafe (m as unsafe *Decl)),
                    "EmitWitness: a requirement as its own witness other than 'op =='; ConformanceChecking::_native_implementation admits only that",
                )
            }

            return "(" + LowerTargets::witness_receiver_name() + " == " + args + ")"
        }

        // A generic requirement's arguments are the witness member's own
        // parameters, spelled: nothing is left for deduction to choose.
        var        targs  = self._own_args(m)
        var unsafe *x_ext = decl_extension_of(w)
        if x_ext != &null {
            // A generic extension's member takes the extension's arguments
            // first, as the row bound them (CXXSpell::template_params order).
            var ne = decl_generic_params(unsafe (x_ext as unsafe *Decl)).size()
            if ne > 0 && ext_args->size() != ne {
                self._ice(
                    CXXSpell::at(w),
                    "EmitWitness: a generic extension's member as a witness with no extension arguments on its row; ConformanceChecking records them",
                )
            }

            if ne > 0 {
                var t = "<"
                for var k: usize = 0; k < ext_args->size(); ++k {
                    if k > 0 {
                        t += ", "
                    }

                    t += self._spell->_type((*ext_args)[k])
                }

                if targs.size() > 0 {
                    // `<U, V>` without its brackets, after the extension's.
                    var inner = ""
                    for var k: usize = 1; k + 1 < targs.size(); ++k {
                        inner.push_back(targs[k])
                    }

                    t += ", " + inner
                }

                targs = t + ">"
            }

            var all = if (m->is_method()) => (LowerTargets::witness_receiver_name()) else => ""
            if args.size() > 0 {
                all += (if (all.size() > 0) => (", ") else => "") + args
            }

            return self._spell->qual_name(w) + targs + "(" + all + ")"
        }

        // A generic requirement's member is a template-id through a receiver
        // whose type a generic row's partial specialization leaves dependent
        // (`self->template wrap<K>(k)` for `Tag<N>`): without the keyword
        // clang reads the `<` as less-than.
        var tkw = if (targs.size() > 0 && dep) => ("template ") else => ""
        return self._member_call(
            m,
            x,
            LowerTargets::witness_receiver_name(),
            tkw + self._spell->leaf(w) + targs,
        )
    }

    /// The call of member \p name (already carrying any `template` keyword
    /// and arguments) through receiver \p recv, or through \p self_s for a
    /// static: `self->m(...)`, `self.operator==(...)`, `S::make(...)`.
    priv fn _member_call(self,
                         m:            unsafe *FunctionDecl,
                         const self_s: string,
                         const recv:   string,
                         const name:   string) -> string {
        var args = self._forward(m)
        if !m->is_method() {
            return self_s + "::" + name + "(" + args + ")"
        }

        if m->is_operator {
            return recv + "." + name + "(" + args + ")"
        }

        return recv + "->" + name + "(" + args + ")"
    }

    /// `<U, V>`: a generic requirement's own parameters as arguments, or "".
    priv fn _own_args(self, m: unsafe *FunctionDecl) -> string {
        if m->generic_params.size() == 0 {
            return ""
        }

        var fid = CXXSpell::fid_of(unsafe (m as unsafe *Decl))
        var s   = "<"
        for var i: usize = 0; i < m->generic_params.size(); ++i {
            if i > 0 {
                s += ", "
            }

            s += self._spell->imm_name(m->generic_params[i]->name.imm, fid)
            if m->generic_params[i]->is_pack {
                s += "..."
            }
        }

        return s + ">"
    }

    /// # pieces

    /// `static R name(RECV self, P p, ...)` for requirement \p m with Self
    /// spelled \p self_s.
    priv fn _member_decl(self,
                         m:            unsafe *FunctionDecl,
                         subst:        unsafe *InstanceEntry,
                         const self_s: string) -> string {
        var unsafe *saved_i = self._spell->self_iface
        var        saved_s  = self._spell->self_spelling
        self._self_as(m, self_s)
        var ps = ""
        if m->is_method() {
            ps = self._receiver(m, self_s) + " " + LowerTargets::witness_receiver_name()
        }

        for var i: usize = 0; i < m->params.size(); ++i {
            var unsafe *p = m->params[i]
            if p == &null || p->is_self {
                continue
            }

            if ps.size() > 0 {
                ps += ", "
            }

            ps += self._spell->param_decl(p, self._pname(m, p), subst)
        }

        if CXXSpell::op_is_postfix(m) {
            ps += ", int " + LowerTargets::witness_postfix()
        }

        // The requirement's convention is the thunk's own, so a call through
        // the bound reaches the conformer with no extra hop of another one.
        var s = self._spell->template_head(
            unsafe (m as unsafe *Decl),
        ) + "static " + CXXSpell::call_conv_attr(m->call_conv) + self._ret(
            m,
            subst,
        ) + " " + self._spell->witness_member_name(m) + "(" + ps
        s += ")"
        // A Kairo frame, noexcept as the conformer's own function is: a
        // static thunk's address goes into an `unsafe fn` (ScopeFrame's
        // A::alloc), whose pointer type is noexcept.
        if !self._cg->opts.unwind {
            s += " noexcept"
        }

        self._spell->self_iface    = saved_i
        self._spell->self_spelling = saved_s
        return s
    }

    /// Every argument after the receiver, as its own declared type.
    priv fn _forward(self, m: unsafe *FunctionDecl) -> string {
        var s = ""
        for var i: usize = 0; i < m->params.size(); ++i {
            var unsafe *p = m->params[i]
            if p == &null || p->is_self {
                continue
            }

            if s.size() > 0 {
                s += ", "
            }

            var nm = self._pname(m, p)
            s += "static_cast<decltype(" + nm + ")&&>(" + nm + ")"
        }

        if CXXSpell::op_is_postfix(m) {
            s += (if (s.size() > 0) => (", ") else => "") + LowerTargets::witness_postfix()
        }

        return s
    }

    /// `[const ]S*`, or `[const ]S&` for an operator (CXXSpell::ext_receiver's rule).
    priv fn _receiver(self, m: unsafe *FunctionDecl, const self_s: string) -> string {
        var s = if (m->is_const()) => ("const ") else => ""
        return s + self_s + (if (m->is_operator) => ("&") else => "*")
    }

    /// `auto (S::*)(P...) const -> R` for \p m with Self spelled \p me, S
    /// being \p owner; `auto (*)(P...) -> R` when \p owner is empty (a
    /// static member).
    priv fn _pointer_to_member(self,
                               m:           unsafe *FunctionDecl,
                               subst:       unsafe *InstanceEntry,
                               const me:    string,
                               const owner: string) -> string {
        // The return type goes TRAILING: spliced in front of the declarator,
        // a return spelled with parentheses of its own split at the wrong
        // one -- `-> usize` is `decltype(sizeof(0))`, and cutting at the
        // first `(` made `decltype(*)(sizeof(0))()` -- and a return
        // that is itself a function pointer has no prefix form at all.
        var star = if (owner.size() == 0) => ("(*)") else => "(" + owner + "::*)"
        // The requirement's calling convention is part of the member's type;
        // clang takes it leading the whole type-id.
        return CXXSpell::call_conv_attr(m->call_conv) + "auto " + star + self._member_params(
            m,
            subst,
            me,
        ) + " -> " + self._member_ret(m, subst, me)
    }

    priv fn _ret(self, m: unsafe *FunctionDecl, subst: unsafe *InstanceEntry) -> string {
        // PanicLowering's result (Compiler/Spec/Panic.md#paniclowering), at a specialization's
        // arguments: a generic interface's set may name its parameters.
        if m->panic_result != &null {
            return self._spell->_type(m->panic_result, subst)
        }

        if m->is_noreturn || m->return_type == &null {
            return "void"
        }

        return self._spell->return_spelling(m, subst)
    }

    priv fn _pname(self, m: unsafe *FunctionDecl, p: unsafe *ParamDecl) -> string {
        return self._spell->imm_name(p->name.imm, CXXSpell::fid_of(unsafe (m as unsafe *Decl)))
    }

    /// Spell the bare Self of \p m's interface as \p self_s until restored.
    priv fn _self_as(self, m: unsafe *FunctionDecl, const self_s: string) {
        var unsafe *dc    = m->semantic_dc
        var unsafe *owner = if (dc != &null) => (dc->owner_decl()) else => &null
        self._spell->self_iface    = if (owner != &null) => (CXXSpell::rep(owner)) else => &null
        self._spell->self_spelling = self_s
    }

    /// `template <class __kairo_Self, class T>`: Self, then the interface's own.
    priv fn _head(self, iface: unsafe *Decl) -> string {
        var s   = "template <class " + LowerTargets::witness_self()
        var gps = decl_generic_params(iface)
        var fid = CXXSpell::fid_of(iface)
        for var i: usize = 0; i < gps.size(); ++i {
            if gps[i]->is_const_param {
                self._ice(
                    CXXSpell::at(iface),
                    "EmitWitness: an interface with a value parameter; not built",
                )
            }

            s += ", class "
            s += self._spell->imm_name(gps[i]->name.imm, fid)
        }

        return s + ">"
    }

    /// `<__kairo_Self, T>`: the primary's own parameters as arguments.
    priv fn _self_params(self, iface: unsafe *Decl) -> string {
        var s   = "<" + LowerTargets::witness_self()
        var gps = decl_generic_params(iface)
        var fid = CXXSpell::fid_of(iface)
        for var i: usize = 0; i < gps.size(); ++i {
            s += ", " + self._spell->imm_name(gps[i]->name.imm, fid)
        }

        return s + ">"
    }

    priv fn _leaf_witness(self, iface: unsafe *Decl) -> string {
        return self._spell->leaf(iface) + LowerTargets::witness_suffix()
    }

    priv fn _leaf_concept(self, iface: unsafe *Decl) -> string {
        return self._spell->leaf(iface) + LowerTargets::concept_suffix()
    }

    /// A GENERIC row (§7b.3): a declared conformance whose conformer is
    /// over the declaring decl's own parameters (`extend <E> Wrap<E> impl
    /// I`), one partial specialization for every `Wrap<X>`.
    static fn is_generic_row(row: unsafe *ConformanceRow) -> bool {
        return row->declared != &null && row->conformer != &null && row->conformer->is_dependent()
    }

    /// `template <> `, or for a generic row its declaring decl's head,
    /// `template <class E> `, interface bounds included: a conditional
    /// conformance's partial specialization matches only the arguments that
    /// meet them, and every other `Wrap<X>` gets the primary.
    priv fn _spec_head(self, row: unsafe *ConformanceRow) -> string {
        if !EmitWitness::is_generic_row(row) {
            return "template <> "
        }

        var h = self._spell->template_head(CXXSpell::rep(row->declared))
        if h.size() == 0 {
            self._ice(
                CXXSpell::at(row->declared),
                "EmitWitness: a generic row whose declaring decl has no template parameters",
            )
        }

        return h
    }

    /// _iface_subst, or for a DEPENDENT instance (a generic row's
    /// `Container<E>`, which has no registry entry) _dep_subst: its
    /// arguments are the row's own parameters, spelled by name.
    priv fn _subst_of(self, iface: unsafe *Type) -> unsafe *InstanceEntry {
        if iface == &null || !isa<RecordType>(canon_unqual(iface)) {
            return &null
        }

        var unsafe *r = cast<RecordType>(canon_unqual(iface))
        if !r->is_dependent() {
            return self._iface_subst(unsafe (r as unsafe *Type))
        }

        var unsafe *sd = CXXSpell::rep(decl_pattern(CXXSpell::rep(r->decl)))
        if decl_generic_params(sd).size() == 0 {
            return &null
        }

        return self._dep_subst(sd, r)
    }

    /// The registry entry an interface instance's arguments come from, so a
    /// specialization of `Container<i32>` spells its `T` as `signed int`.
    priv fn _iface_subst(self, iface: unsafe *Type) -> unsafe *InstanceEntry {
        if iface == &null || !isa<RecordType>(iface) {
            return &null
        }

        var unsafe *d = cast<RecordType>(iface)->decl
        if !decl_is_instance(d) {
            return &null
        }

        return self._cg->instances->entry_of(d)
    }

    /// The substitution a requirement inherited through dependent instance
    /// \p src of interface \p sd is spelled through: sd's parameters bound
    /// to src's arguments, which are written in the composing interface's
    /// parameters. CXXSpell spells a substituted argument with no further
    /// substitution, so `T` comes out as the composing interface's own name.
    priv fn _dep_subst(self, sd: unsafe *Decl, src: unsafe *RecordType) -> unsafe *InstanceEntry {
        var unsafe *key = unsafe (src as unsafe *Type)
        for var i: usize = 0; i < self._dep_src.size(); ++i {
            if self._dep_src[i] == key {
                return self._dep_ent[i]
            }
        }

        var unsafe *e = self._dep_arena.Allocate(1)
        cxx::std::construct_at(e)
        e->primary = sd
        for var i: usize = 0; i < src->args.size(); ++i {
            e->args.push_back(src->args[i])
        }

        self._dep_src.push_back(key)
        self._dep_ent.push_back(e)
        return e
    }

    priv fn _at(self, p: unsafe *WitnessPiece) -> SourceRange {
        return CXXSpell::at(p->iface)
    }
}
