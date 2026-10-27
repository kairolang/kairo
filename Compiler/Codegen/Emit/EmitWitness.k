/// --- The Kairo Project -------------------- Codegen/Emit/EmitWitness.k --- ///
///
///   \brief Interface witnesses: the class template a generic body's call
///          through an interface bound goes through, its concept, and the
///          specializations for the conformances the template cannot reach.
///
///   \detail
///     CODEGEN.md §7b is the contract. For `interface Scalable { fn
///     scale(const self, f: i32) -> i32 }` in module `ring`:
///
///       template <class __kairo_Self> struct Scalable_witness {        primary
///           static signed int scale(const __kairo_Self* self, signed int f)
///               requires requires { static_cast<signed int (__kairo_Self::*)(signed int) const>(&__kairo_Self::scale); }
///           { return self->scale(static_cast<decltype(f)&&>(f)); }
///       };
///       template <class __kairo_Self> concept Scalable_c = requires (...) { ... };
///       template <> struct Scalable_witness<::ring::Metric> {           a row
///           static signed int scale(const ::ring::Metric* self, signed int f)
///           { return ::ring::__kairo_ext_Metric::scale(self, static_cast<decltype(f)&&>(f)); }
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
///     concept clause (§7b.3). Not built: associated types.
///
///   Import law: CodegenContext only.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Codegen::CodegenContext::*;
import Codegen::CodegenICE::*;
import Codegen::Emit::CXXSpell::*;
import AST::Context::DeclContext::*;
import AST::Context::InstantiationRegistry::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::LangItems::*;
import AST::Node::Base::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::TypeKind::*;
import Location::SourceRange::*;

/// One witness plan entry: an interface's primary and concept (`row`
/// null), or one conformance row's specialization. EmitPlan's, like
/// ExtScope: tier 0 declares a primary, tier 1 defines either kind.
class WitnessPiece {
    pub var iface: *Decl = &null;            ///< the InterfaceDecl's representative.
    pub var row:   *ConformanceRow = &null;  ///< null for the primary.
    /// Tier-1 decls the definition needs complete: by-value records in a
    /// member signature, and a specialization's conformer.
    pub var deps:  vec::<*Decl>;
    /// A specialization's extension scopes (EmitPlan's `_scopes` indexes):
    /// it calls their static members, so it follows their definitions.
    pub var scopes: vec::<usize>;
    /// Interfaces whose primary (and concept) must come first: a
    /// specialization's own interface, a concept's bases.
    pub var after:  vec::<*Decl>;
    /// The identity across plans and includes: the witness and its Self.
    pub var key:   string;
    fn WitnessPiece(self) { }
}

class EmitWitness {
    priv var _cg:    obs::<CodegenContext>;
    priv var _spell: obs::<CXXSpell>;
    /// Substitutions for requirements inherited through a DEPENDENT generic
    /// instance (members_with): no registry entry exists for one, so they
    /// are minted here and live as long as this emitter, which outlives
    /// every member list it hands out. `_dep_src` is parallel: the source
    /// type each was made for, so one leaf's requirements share an entry.
    priv var _dep_arena: llvm::SpecificBumpPtrAllocator::<InstanceEntry>;
    priv var _dep_src:   vec::<*Type>;
    priv var _dep_ent:   vec::<*InstanceEntry>;

    fn EmitWitness(self, cg: *CodegenContext, spell: *CXXSpell) {
        self._cg    = cg;
        self._spell = spell;
    }

    priv fn _ice(self, at: SourceRange, msg: string) {
        codegen_ice(self._cg->ctx, at, msg);
    }

    // --- the members -----------------------------------------------------------------

    /// \p idecl's requirements as witness members, PARALLEL to its composed
    /// requirement list (and so to a row's witnesses): null for an
    /// associated type, which has no member yet. An interface never composed
    /// (poisoned upstream) gives its own methods.
    fn members(self, idecl: *InterfaceDecl) -> vec::<*FunctionDecl> {
        var substs = vec::<*InstanceEntry>();
        return self.members_with(idecl, &substs);
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
    fn members_with(self, idecl: *InterfaceDecl, substs: *vec::<*InstanceEntry>,
                    row: *ConformanceRow = &null) -> vec::<*FunctionDecl> {
        var out = vec::<*FunctionDecl>();
        if idecl->compose_state != 2 {
            for var i: usize = 0; i < idecl->methods.size(); ++i { out.push_back(idecl->methods[i]); substs->push_back(&null); }
            return out;
        }
        var me = CXXSpell::rep(static_cast::<*Decl>(idecl));
        for var i: usize = 0; i < idecl->requirements.size(); ++i {
            var r = idecl->requirements.get(i);
            var f = dyn_cast::<FunctionDecl>(r->decl);
            var sub: *InstanceEntry = &null;
            if (f != &null) && (r->source != &null) && isa::<RecordType>(canon_unqual(r->source)) {
                var src = cast::<RecordType>(canon_unqual(r->source));
                var sd = CXXSpell::rep(decl_pattern(CXXSpell::rep(src->decl)));
                if (sd != me) && (decl_generic_params(sd).size() > 0) {
                    if !src->is_dependent() {
                        sub = self._iface_subst(static_cast::<*Type>(src));
                    } else if row == &null {
                        sub = self._dep_subst(sd, src);
                    } else {
                        var at_row = (row->sources[i]) if (i < row->sources.size()) else (&null);
                        sub = self._subst_of(at_row);
                        // A row's sources are at its own arguments: instances,
                        // or for a generic row instances over its declaring
                        // decl's parameters; a null here would spell the
                        // leaf's own parameters, which are not in scope.
                        if sub == &null { self._ice(CXXSpell::at(r->decl), "EmitWitness: a row with no source for an inherited requirement; ConformanceChecking records it at the row's arguments"); }
                    }
                }
            }
            out.push_back(f);
            substs->push_back(sub);
        }
        return out;
    }

    // --- the decision (§7b.4) --------------------------------------------------------

    /// False when the primary serves \p row: every requirement is met by a
    /// member function of a Kairo record conformer whose C++ signature is
    /// the witness member's forwarded-to signature exactly. Decided from
    /// spellings, never by lookup; an imported member is always
    /// specialized, since its C++ type is not Kairo's to compare.
    fn needs_specialization(self, row: *ConformanceRow) -> bool {
        if (row == &null) || (row->conformer == &null) { return true; }
        // Nothing to forward -- every requirement a constructor (or an
        // associated type) -- and the primary is already right, for a
        // builtin conformer too: an empty specialization would be noise.
        if !self._has_members(cast::<InterfaceDecl>(row->iface_decl)) { return false; }
        if !isa::<RecordType>(row->conformer) { return true; }   // a builtin has no members.
        var x = cast::<RecordType>(row->conformer)->decl;
        if decl_is_imported(CXXSpell::rep(x)) { return true; }
        var idecl = cast::<InterfaceDecl>(row->iface_decl);
        var subst = self._subst_of(row->iface);
        var subs = vec::<*InstanceEntry>();
        var ms = self.members_with(idecl, &subs, row);
        for var i: usize = 0; i < ms.size(); ++i {
            var m = ms[i];
            if m == &null { continue; }   // an associated type: no member yet.
            // A constructor slot has no member to forward to, and its witness
            // may be the record itself (its implicit default constructor).
            if decl_is_ctor_requirement(m) { continue; }
            var w = dyn_cast::<FunctionDecl>((row->witnesses[i]) if (i < row->witnesses.size()) else (&null));
            if w == &null { return true; }
            if decl_extension_of(static_cast::<*Decl>(w)) != &null { return true; }
            if decl_is_imported(static_cast::<*Decl>(w)) { return true; }
            if w->is_operator != m->is_operator { return true; }
            var ms_sub = (subs[i]) if (subs[i] != &null) else (subst);
            if self._member_sig(w, &null, "") != self._member_sig(m, ms_sub, self._spell->_type(row->conformer)) { return true; }
        }
        return false;
    }

    /// Some requirement of \p idecl is a witness member: neither an
    /// associated type nor a constructor.
    priv fn _has_members(self, idecl: *InterfaceDecl) -> bool {
        var ms = self.members(idecl);
        for var i: usize = 0; i < ms.size(); ++i { if (ms[i] != &null) && (!decl_is_ctor_requirement(ms[i])) { return true; } }
        return false;
    }

    /// `R (P1, P2) const` of a member, as the member pointer cast spells it,
    /// with \p m's bare Self spelled \p self_s (empty: \p m has none).
    priv fn _member_sig(self, m: *FunctionDecl, subst: *InstanceEntry, self_s: string) -> string {
        var saved_i = self._spell->self_iface;
        var saved_s = self._spell->self_spelling;
        if self_s.size() > 0 { self._self_as(m, self_s); }
        var s = self._ret(m, subst) + " (";
        var k: usize = 0;
        for var i: usize = 0; i < m->params.size(); ++i {
            var p = m->params[i];
            if (p == &null) || p->is_self { continue; }
            if k > 0 { s += ", "; }
            s += self._spell->param_decl(p, "", subst);
            k += 1;
        }
        if CXXSpell::op_is_postfix(m) { s += (", int") if (k > 0) else ("int"); }
        s += ")";
        if m->is_const() { s += " const"; }
        self._spell->self_iface    = saved_i;
        self._spell->self_spelling = saved_s;
        return s;
    }

    // --- text ------------------------------------------------------------------------

    /// Tier 0: `template <class __kairo_Self, ...> struct I_witness;`.
    fn fwd(self, p: *WitnessPiece) {
        self._cg->sink->spell(self._at(p), self._head(p->iface) + " struct " + self._leaf_witness(p->iface) + ";");
    }

    /// Tier 1: the primary, or a row's specialization.
    fn def(self, p: *WitnessPiece) {
        if p->row == &null { self._primary(p); return; }
        self._specialization(p);
    }

    /// Tier 0: the concept. Ahead of every head that names it -- a bounded
    /// record's forward declaration included -- and of the primary's
    /// definition: it names only the declared witness, and its
    /// requires-parameters need their types declared, not complete.
    fn concept_def(self, p: *WitnessPiece) { self._concept(p); }

    priv fn _primary(self, p: *WitnessPiece) {
        var idecl = cast::<InterfaceDecl>(p->iface);
        var at = self._at(p);
        var me = LowerTargets::witness_self();
        self._cg->sink->spell(at, self._head(p->iface) + " struct " + self._leaf_witness(p->iface) + " {");
        var subs = vec::<*InstanceEntry>();
        var ms = self.members_with(idecl, &subs);
        for var i: usize = 0; i < ms.size(); ++i {
            var m = ms[i];
            if (m == &null) || m->is_poisoned() || decl_is_ctor_requirement(m) { continue; }
            var sig  = self._member_sig(m, subs[i], me);
            var decl = self._member_decl(m, subs[i], me);
            var leaf = self._spell->leaf(static_cast::<*Decl>(m));
            var targs = self._own_args(m);
            var gate = "";
            if targs.size() > 0 {
                // A GENERIC requirement has no member pointer to cast without
                // its arguments: the gate is the callable form, the one corner
                // that keeps 7b.3's hazard (§7b.12, question 6).
                gate = "requires requires { " + self._member_call(m, me, LowerTargets::witness_receiver_name(), "template " + leaf + targs) + "; }";
            } else {
                // A static requirement is gated on a plain function pointer: a
                // static member's address is not a pointer to member.
                var owner = (me) if (m->is_method()) else ("");
                gate = "requires requires { static_cast<" + self._pointer_to_member(sig, owner) + ">(&" + me + "::" + leaf + "); }";
            }
            var call = self._member_call(m, me, LowerTargets::witness_receiver_name(), (("template " + leaf + targs) if (targs.size() > 0) else (leaf)));
            self._cg->sink->spell(CXXSpell::at(static_cast::<*Decl>(m)), decl + " " + gate + " { return " + call + "; }");
        }
        self._cg->sink->spell(at, "};");
        self._cg->sink->brk();
    }

    /// `I_c<S, A...> = (bases' concepts) && requires (...) { each member; }`.
    /// True for every instance Kairo enumerated (ConformanceChecking proved
    /// its row); its job is the instantiations Kairo cannot see (§7b.7).
    priv fn _concept(self, p: *WitnessPiece) {
        var idecl = cast::<InterfaceDecl>(p->iface);
        var me = LowerTargets::witness_self();
        var self_args = self._self_params(p->iface);
        var s = self._head(p->iface) + " concept " + self._leaf_concept(p->iface) + " = ";
        // No base concepts: the requirement list already holds everything
        // the interface derives (InterfaceComposition, D4).
        var conj = "";
        var parms = "";
        var body  = "";
        var k: usize = 0;
        var subs = vec::<*InstanceEntry>();
        var ms = self.members_with(idecl, &subs);
        for var i: usize = 0; i < ms.size(); ++i {
            var m = ms[i];
            if (m == &null) || m->is_poisoned() { continue; }
            // A generic requirement has no argument to call it with (§7b.7).
            if m->generic_params.size() > 0 { continue; }
            // A constructor requirement is the one clause that names no
            // witness member: `__kairo_Self(a0)`, the construction a bounded
            // body's `T(args)` performs, so a host's class without it fails
            // at the call.
            var ctor = decl_is_ctor_requirement(m);
            // A static requirement is called with no receiver.
            var args = "";
            var fwd  = "";
            if m->is_method() && (!ctor) {
                var r = LowerTargets::witness_recv(i);
                if parms.size() > 0 { parms += ", "; }
                parms += self._receiver(m, me) + " " + r;
                args = r;
            }
            var saved_i = self._spell->self_iface;
            var saved_s = self._spell->self_spelling;
            self._self_as(m, me);
            for var j: usize = 0; j < m->params.size(); ++j {
                var q = m->params[j];
                if (q == &null) || q->is_self { continue; }
                var a = LowerTargets::witness_arg(k);
                k += 1;
                if parms.size() > 0 { parms += ", "; }
                parms += self._spell->param_decl(q, a, subs[i]);
                if args.size() > 0 { args += ", "; }
                args += a;
                // Forwarded as the witness forwards: a by-value `other: Self`
                // is then an rvalue, so a `@move` requirement's clause asks
                // for a move constructor, not a copy one.
                if fwd.size() > 0 { fwd += ", "; }
                fwd += "static_cast<decltype(" + a + ")&&>(" + a + ")";
            }
            self._spell->self_iface    = saved_i;
            self._spell->self_spelling = saved_s;
            if ctor { body += " " + me + "(" + fwd + ");"; continue; }
            if CXXSpell::op_is_postfix(m) { args += ((", ") if (args.size() > 0) else ("")) + "0"; }
            body += " " + self._spell->witness_name(p->iface) + self_args + "::"
                  + self._spell->witness_member_name(m) + "(" + args + ");";
        }
        if body.size() > 0 {
            if conj.size() > 0 { conj += " && "; }
            conj += ("requires {") if (parms.size() == 0) else ("requires (" + parms + ") {");
            conj += body + " }";
        }
        if conj.size() == 0 { conj = "true"; }
        self._cg->sink->spell(self._at(p), s + conj + ";");
        self._cg->sink->brk();
    }

    priv fn _specialization(self, p: *WitnessPiece) {
        var row   = p->row;
        var idecl = cast::<InterfaceDecl>(row->iface_decl);
        var at    = self._at(p);
        var subst = self._subst_of(row->iface);
        var x     = self._spell->_type(row->conformer);
        self._cg->sink->spell(at, self._spec_head(row) + "struct " + self._leaf_witness(p->iface)
                                  + self._spell->witness_args(x, row->iface) + " {");
        var subs = vec::<*InstanceEntry>();
        var ms = self.members_with(idecl, &subs, row);
        for var i: usize = 0; i < ms.size(); ++i {
            var m = ms[i];
            if (m == &null) || m->is_poisoned() || decl_is_ctor_requirement(m) { continue; }
            var w = dyn_cast::<FunctionDecl>((row->witnesses[i]) if (i < row->witnesses.size()) else (&null));
            if (w == &null) { self._ice(CXXSpell::at(static_cast::<*Decl>(m)), "EmitWitness: a row with no decl for a requirement; ConformanceChecking records only complete rows on an instance"); }
            var decl = self._member_decl(m, (subs[i]) if (subs[i] != &null) else (subst), x);
            var ea = vec::<*Type>();
            row->ext_args_of(i, &ea);
            self._cg->sink->spell(CXXSpell::at(static_cast::<*Decl>(m)), decl + " { return " + self._target(w, m, x, &ea) + "; }");
        }
        self._cg->sink->spell(at, "};");
        self._cg->sink->brk();
    }

    /// The call a specialization member makes: the extension member,
    /// qualified, receiver first (none for a static); or the conformer's own
    /// member, through \p x for a static.
    priv fn _target(self, w: *FunctionDecl, m: *FunctionDecl, x: string, ext_args: *vec::<*Type>) -> string {
        var args = self._forward(m);
        // A generic requirement's arguments are the witness member's own
        // parameters, spelled: nothing is left for deduction to choose.
        var targs = self._own_args(m);
        var x_ext = decl_extension_of(static_cast::<*Decl>(w));
        if x_ext != &null {
            // A generic extension's member takes the extension's arguments
            // first, as the row bound them (CXXSpell::template_params order).
            var ne = decl_generic_params(static_cast::<*Decl>(x_ext)).size();
            if (ne > 0) && (ext_args->size() != ne) { self._ice(CXXSpell::at(static_cast::<*Decl>(w)), "EmitWitness: a generic extension's member as a witness with no extension arguments on its row; ConformanceChecking records them"); }
            if ne > 0 {
                var t = "<";
                for var k: usize = 0; k < ext_args->size(); ++k { if k > 0 { t += ", "; } t += self._spell->_type((*ext_args)[k]); }
                if targs.size() > 0 {
                    // `<U, V>` without its brackets, after the extension's.
                    var inner = "";
                    for var k: usize = 1; k + 1 < targs.size(); ++k { inner += targs[k]; }
                    t += ", " + inner;
                }
                targs = t + ">";
            }
            var all = (LowerTargets::witness_receiver_name()) if (m->is_method()) else ("");
            if args.size() > 0 { all += ((", ") if (all.size() > 0) else ("")) + args; }
            return self._spell->qual_name(static_cast::<*Decl>(w)) + targs + "(" + all + ")";
        }
        return self._member_call(m, x, LowerTargets::witness_receiver_name(), self._spell->leaf(static_cast::<*Decl>(w)) + targs);
    }

    /// The call of member \p name (already carrying any `template` keyword
    /// and arguments) through receiver \p recv, or through \p self_s for a
    /// static: `self->m(...)`, `self.operator==(...)`, `S::make(...)`.
    priv fn _member_call(self, m: *FunctionDecl, self_s: string, recv: string, name: string) -> string {
        var args = self._forward(m);
        if !m->is_method() { return self_s + "::" + name + "(" + args + ")"; }
        if m->is_operator { return recv + "." + name + "(" + args + ")"; }
        return recv + "->" + name + "(" + args + ")";
    }

    /// `<U, V>`: a generic requirement's own parameters as arguments, or "".
    priv fn _own_args(self, m: *FunctionDecl) -> string {
        if m->generic_params.size() == 0 { return ""; }
        var fid = CXXSpell::fid_of(static_cast::<*Decl>(m));
        var s = "<";
        for var i: usize = 0; i < m->generic_params.size(); ++i {
            if i > 0 { s += ", "; }
            s += self._spell->imm_name(m->generic_params[i]->name.imm, fid);
            if m->generic_params[i]->is_pack { s += "..."; }
        }
        return s + ">";
    }

    // --- pieces ----------------------------------------------------------------------

    /// `static R name(RECV self, P p, ...)` for requirement \p m with Self
    /// spelled \p self_s.
    priv fn _member_decl(self, m: *FunctionDecl, subst: *InstanceEntry, self_s: string) -> string {
        var saved_i = self._spell->self_iface;
        var saved_s = self._spell->self_spelling;
        self._self_as(m, self_s);
        var ps = "";
        if m->is_method() { ps = self._receiver(m, self_s) + " " + LowerTargets::witness_receiver_name(); }
        for var i: usize = 0; i < m->params.size(); ++i {
            var p = m->params[i];
            if (p == &null) || p->is_self { continue; }
            if ps.size() > 0 { ps += ", "; }
            ps += self._spell->param_decl(p, self._pname(m, p), subst);
        }
        if CXXSpell::op_is_postfix(m) { ps += ", int " + LowerTargets::witness_postfix(); }
        var s = self._spell->template_head(static_cast::<*Decl>(m)) + "static " + self._ret(m, subst) + " " + self._spell->witness_member_name(m) + "(" + ps;
        s += ")";
        self._spell->self_iface    = saved_i;
        self._spell->self_spelling = saved_s;
        return s;
    }

    /// Every argument after the receiver, as its own declared type.
    priv fn _forward(self, m: *FunctionDecl) -> string {
        var s = "";
        for var i: usize = 0; i < m->params.size(); ++i {
            var p = m->params[i];
            if (p == &null) || p->is_self { continue; }
            if s.size() > 0 { s += ", "; }
            var nm = self._pname(m, p);
            s += "static_cast<decltype(" + nm + ")&&>(" + nm + ")";
        }
        if CXXSpell::op_is_postfix(m) { s += ((", ") if (s.size() > 0) else ("")) + LowerTargets::witness_postfix(); }
        return s;
    }

    /// `[const ]S*`, or `[const ]S&` for an operator (CXXSpell::ext_receiver's rule).
    priv fn _receiver(self, m: *FunctionDecl, self_s: string) -> string {
        var s = ("const ") if (m->is_const()) else ("");
        return s + self_s + (("&") if (m->is_operator) else ("*"));
    }

    /// `R (S::*)(P...) const` from `R (P...) const`; `R (*)(P...)` when
    /// \p self_s is empty (a static member).
    priv fn _pointer_to_member(self, sig: string, self_s: string) -> string {
        // MIGRATE(raw_string): string(sig.raw_string().substr(0, open)) once
        // the compiler builds against a string that has raw_string(); Stage 0's
        // has neither it nor substr, so the split is a char loop until then.
        var out = "";
        var done = false;
        for var i: usize = 0; i < sig.size(); ++i {
            if (!done) && (sig[i] == '(') {
                out += ("(*)") if (self_s.size() == 0) else ("(" + self_s + "::*)");
                done = true;
            }
            out += sig[i];
        }
        return out;
    }

    priv fn _ret(self, m: *FunctionDecl, subst: *InstanceEntry) -> string {
        if m->is_noreturn || (m->return_type == &null) { return "void"; }
        return self._spell->return_spelling(m, subst);
    }

    priv fn _pname(self, m: *FunctionDecl, p: *ParamDecl) -> string {
        return self._spell->imm_name(p->name.imm, CXXSpell::fid_of(static_cast::<*Decl>(m)));
    }

    /// Spell the bare Self of \p m's interface as \p self_s until restored.
    priv fn _self_as(self, m: *FunctionDecl, self_s: string) {
        var dc = reinterpret_cast::<*DeclContext>(m->semantic_dc);
        var owner = (dc->owner_decl()) if (dc != &null) else (&null);
        self._spell->self_iface    = (CXXSpell::rep(owner)) if (owner != &null) else (&null);
        self._spell->self_spelling = self_s;
    }

    /// `template <class __kairo_Self, class T>`: Self, then the interface's own.
    priv fn _head(self, iface: *Decl) -> string {
        var s = "template <class " + LowerTargets::witness_self();
        var gps = decl_generic_params(iface);
        var fid = CXXSpell::fid_of(iface);
        for var i: usize = 0; i < gps.size(); ++i {
            if gps[i]->is_const_param { self._ice(CXXSpell::at(iface), "EmitWitness: an interface with a value parameter; not built"); }
            s += ", class ";
            s += self._spell->imm_name(gps[i]->name.imm, fid);
        }
        return s + ">";
    }

    /// `<__kairo_Self, T>`: the primary's own parameters as arguments.
    priv fn _self_params(self, iface: *Decl) -> string {
        var s = "<" + LowerTargets::witness_self();
        var gps = decl_generic_params(iface);
        var fid = CXXSpell::fid_of(iface);
        for var i: usize = 0; i < gps.size(); ++i { s += ", " + self._spell->imm_name(gps[i]->name.imm, fid); }
        return s + ">";
    }

    priv fn _leaf_witness(self, iface: *Decl) -> string { return self._spell->leaf(iface) + LowerTargets::witness_suffix(); }
    priv fn _leaf_concept(self, iface: *Decl) -> string { return self._spell->leaf(iface) + LowerTargets::concept_suffix(); }

    /// A GENERIC row (§7b.3): a declared conformance whose conformer is
    /// over the declaring decl's own parameters (`extend <E> Wrap<E> impl
    /// I`), one partial specialization for every `Wrap<X>`.
    static fn is_generic_row(row: *ConformanceRow) -> bool {
        return (row->declared != &null) && (row->conformer != &null) && row->conformer->is_dependent();
    }

    /// `template <> `, or for a generic row its declaring decl's head,
    /// `template <class E> `, interface bounds included: a conditional
    /// conformance's partial specialization matches only the arguments that
    /// meet them, and every other `Wrap<X>` gets the primary.
    priv fn _spec_head(self, row: *ConformanceRow) -> string {
        if !EmitWitness::is_generic_row(row) { return "template <> "; }
        var h = self._spell->template_head(CXXSpell::rep(row->declared));
        if h.size() == 0 { self._ice(CXXSpell::at(row->declared), "EmitWitness: a generic row whose declaring decl has no template parameters"); }
        return h;
    }

    /// _iface_subst, or for a DEPENDENT instance (a generic row's
    /// `Container<E>`, which has no registry entry) _dep_subst: its
    /// arguments are the row's own parameters, spelled by name.
    priv fn _subst_of(self, iface: *Type) -> *InstanceEntry {
        if (iface == &null) || (!isa::<RecordType>(canon_unqual(iface))) { return &null; }
        var r = cast::<RecordType>(canon_unqual(iface));
        if !r->is_dependent() { return self._iface_subst(static_cast::<*Type>(r)); }
        var sd = CXXSpell::rep(decl_pattern(CXXSpell::rep(r->decl)));
        if decl_generic_params(sd).size() == 0 { return &null; }
        return self._dep_subst(sd, r);
    }

    /// The registry entry an interface instance's arguments come from, so a
    /// specialization of `Container<i32>` spells its `T` as `signed int`.
    priv fn _iface_subst(self, iface: *Type) -> *InstanceEntry {
        if (iface == &null) || (!isa::<RecordType>(iface)) { return &null; }
        var d = cast::<RecordType>(iface)->decl;
        if !decl_is_instance(d) { return &null; }
        return self._cg->instances->entry_of(d);
    }

    /// The substitution a requirement inherited through dependent instance
    /// \p src of interface \p sd is spelled through: sd's parameters bound
    /// to src's arguments, which are written in the composing interface's
    /// parameters. CXXSpell spells a substituted argument with no further
    /// substitution, so `T` comes out as the composing interface's own name.
    priv fn _dep_subst(self, sd: *Decl, src: *RecordType) -> *InstanceEntry {
        var key = static_cast::<*Type>(src);
        for var i: usize = 0; i < self._dep_src.size(); ++i { if self._dep_src[i] == key { return self._dep_ent[i]; } }
        var e = self._dep_arena.Allocate(1);
        libcxx::construct_at(e);
        e->primary = sd;
        for var i: usize = 0; i < src->args.size(); ++i { e->args.push_back(src->args[i]); }
        self._dep_src.push_back(key);
        self._dep_ent.push_back(e);
        return e;
    }

    priv fn _at(self, p: *WitnessPiece) -> SourceRange {
        return CXXSpell::at(p->iface);
    }
}
