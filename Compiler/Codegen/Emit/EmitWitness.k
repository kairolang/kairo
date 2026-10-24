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
///     Built: non-generic requirements -- named, operator and static (a
///     static member, gated on a plain function pointer and called through
///     Self) -- and every row with a concrete conformer (a full
///     specialization each, also for a row a generic extension supplies).
///     Not built: generic requirements, associated types, constructor
///     requirements in the concept, partial specializations for generic
///     conformances (§7b.3, for C++ hosts).
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

    fn EmitWitness(self, cg: *CodegenContext, spell: *CXXSpell) {
        self._cg    = cg;
        self._spell = spell;
    }

    priv fn _ice(self, at: SourceRange, msg: string) {
        codegen_ice(self._cg->ctx, at, msg);
    }

    // --- the decision (§7b.4) --------------------------------------------------------

    /// False when the primary serves \p row: every requirement is met by a
    /// member function of a Kairo record conformer whose C++ signature is
    /// the witness member's forwarded-to signature exactly. Decided from
    /// spellings, never by lookup; an imported member is always
    /// specialized, since its C++ type is not Kairo's to compare.
    fn needs_specialization(self, row: *ConformanceRow) -> bool {
        if (row == &null) || (row->conformer == &null) { return true; }
        if !isa::<RecordType>(row->conformer) { return true; }   // a builtin has no members.
        var x = cast::<RecordType>(row->conformer)->decl;
        if decl_is_imported(CXXSpell::rep(x)) { return true; }
        var idecl = cast::<InterfaceDecl>(row->iface_decl);
        var subst = self._iface_subst(row->iface);
        for var i: usize = 0; i < idecl->methods.size(); ++i {
            var m = idecl->methods[i];
            var w = dyn_cast::<FunctionDecl>((row->witnesses[i]) if (i < row->witnesses.size()) else (&null));
            if w == &null { return true; }
            if decl_extension_of(static_cast::<*Decl>(w)) != &null { return true; }
            if decl_is_imported(static_cast::<*Decl>(w)) { return true; }
            if w->is_operator != m->is_operator { return true; }
            if self._member_sig(w, &null, "") != self._member_sig(m, subst, self._spell->_type(row->conformer)) { return true; }
        }
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

    /// Tier 1: the primary and the concept, or a row's specialization.
    fn def(self, p: *WitnessPiece) {
        if p->row == &null { self._primary(p); self._concept(p); return; }
        self._specialization(p);
    }

    priv fn _primary(self, p: *WitnessPiece) {
        var idecl = cast::<InterfaceDecl>(p->iface);
        var at = self._at(p);
        var me = LowerTargets::witness_self();
        self._cg->sink->spell(at, self._head(p->iface) + " struct " + self._leaf_witness(p->iface) + " {");
        for var i: usize = 0; i < idecl->methods.size(); ++i {
            var m = idecl->methods[i];
            if (m == &null) || m->is_poisoned() { continue; }
            self._unsupported(m);
            var sig  = self._member_sig(m, &null, me);
            var decl = self._member_decl(m, &null, me);
            // A static requirement is gated on a plain function pointer: a
            // static member's address is not a pointer to member.
            var owner = (me) if (m->is_method()) else ("");
            var gate = "requires requires { static_cast<" + self._pointer_to_member(sig, owner) + ">(&" + me + "::"
                     + self._spell->leaf(static_cast::<*Decl>(m)) + "); }";
            var call = "";
            if !m->is_method() { call = me + "::" + self._spell->leaf(static_cast::<*Decl>(m)) + "(" + self._forward(m) + ")"; }
            else if m->is_operator { call = "self." + self._spell->leaf(static_cast::<*Decl>(m)) + "(" + self._forward(m) + ")"; }
            else { call = "self->" + self._spell->leaf(static_cast::<*Decl>(m)) + "(" + self._forward(m) + ")"; }
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
        var conj = "";
        var bases = decl_bases(p->iface);
        for var i: usize = 0; i < bases.size(); ++i {
            var b = bases.get(i)->base;
            if (b == &null) || (b->canonical == &null) || (!isa::<RecordType>(canon_unqual(b->canonical))) { continue; }
            var bd = CXXSpell::rep(decl_pattern(CXXSpell::rep(cast::<RecordType>(canon_unqual(b->canonical))->decl)));
            if conj.size() > 0 { conj += " && "; }
            conj += self._spell->concept_name(bd) + self._spell->witness_args(me, canon_unqual(b->canonical));
        }
        var parms = "";
        var body  = "";
        var k: usize = 0;
        for var i: usize = 0; i < idecl->methods.size(); ++i {
            var m = idecl->methods[i];
            if (m == &null) || m->is_poisoned() { continue; }
            // A static requirement is called with no receiver.
            var args = "";
            if m->is_method() {
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
                parms += self._spell->param_decl(q, a);
                if args.size() > 0 { args += ", "; }
                args += a;
            }
            self._spell->self_iface    = saved_i;
            self._spell->self_spelling = saved_s;
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
        var subst = self._iface_subst(row->iface);
        var x     = self._spell->_type(row->conformer);
        self._cg->sink->spell(at, "template <> struct " + self._leaf_witness(p->iface)
                                  + self._spell->witness_args(x, row->iface) + " {");
        for var i: usize = 0; i < idecl->methods.size(); ++i {
            var m = idecl->methods[i];
            if (m == &null) || m->is_poisoned() { continue; }
            self._unsupported(m);
            var w = dyn_cast::<FunctionDecl>((row->witnesses[i]) if (i < row->witnesses.size()) else (&null));
            if (w == &null) { self._ice(CXXSpell::at(static_cast::<*Decl>(m)), "EmitWitness: a row with no decl for a requirement; ConformanceChecking records only complete rows on an instance"); }
            var decl = self._member_decl(m, subst, x);
            self._cg->sink->spell(CXXSpell::at(static_cast::<*Decl>(m)), decl + " { return " + self._target(w, m, x) + "; }");
        }
        self._cg->sink->spell(at, "};");
        self._cg->sink->brk();
    }

    /// The call a specialization member makes: the extension member,
    /// qualified, receiver first (none for a static); or the conformer's own
    /// member, through \p x for a static.
    priv fn _target(self, w: *FunctionDecl, m: *FunctionDecl, x: string) -> string {
        var args = self._forward(m);
        if decl_extension_of(static_cast::<*Decl>(w)) != &null {
            if (CXXSpell::template_params(static_cast::<*Decl>(w)).size() > 0) { self._ice(CXXSpell::at(static_cast::<*Decl>(w)), "EmitWitness: a generic extension member as a witness; its arguments are not spelled yet"); }
            var all = ("self") if (m->is_method()) else ("");
            if args.size() > 0 { all += ((", ") if (all.size() > 0) else ("")) + args; }
            return self._spell->qual_name(static_cast::<*Decl>(w)) + "(" + all + ")";
        }
        if !m->is_method() { return x + "::" + self._spell->leaf(static_cast::<*Decl>(w)) + "(" + args + ")"; }
        if w->is_operator { return "self." + self._spell->leaf(static_cast::<*Decl>(w)) + "(" + args + ")"; }
        return "self->" + self._spell->leaf(static_cast::<*Decl>(w)) + "(" + args + ")";
    }

    // --- pieces ----------------------------------------------------------------------

    /// `static R name(RECV self, P p, ...)` for requirement \p m with Self
    /// spelled \p self_s.
    priv fn _member_decl(self, m: *FunctionDecl, subst: *InstanceEntry, self_s: string) -> string {
        var saved_i = self._spell->self_iface;
        var saved_s = self._spell->self_spelling;
        self._self_as(m, self_s);
        var ps = "";
        if m->is_method() { ps = self._receiver(m, self_s) + " self"; }
        for var i: usize = 0; i < m->params.size(); ++i {
            var p = m->params[i];
            if (p == &null) || p->is_self { continue; }
            if ps.size() > 0 { ps += ", "; }
            ps += self._spell->param_decl(p, self._pname(m, p), subst);
        }
        if CXXSpell::op_is_postfix(m) { ps += ", int " + LowerTargets::witness_postfix(); }
        var s = "static " + self._ret(m, subst) + " " + self._spell->witness_member_name(m) + "(" + ps;
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

    /// The registry entry an interface instance's arguments come from, so a
    /// specialization of `Container<i32>` spells its `T` as `signed int`.
    priv fn _iface_subst(self, iface: *Type) -> *InstanceEntry {
        if (iface == &null) || (!isa::<RecordType>(iface)) { return &null; }
        var d = cast::<RecordType>(iface)->decl;
        if !decl_is_instance(d) { return &null; }
        return self._cg->instances->entry_of(d);
    }

    priv fn _unsupported(self, m: *FunctionDecl) {
        if m->generic_params.size() > 0 { self._ice(CXXSpell::at(static_cast::<*Decl>(m)), "EmitWitness: a generic requirement; its witness member is not built (CODEGEN.md §7b.12, question 6)"); }
        // A constructor requirement is met by an own constructor, never
        // through the witness (§7b.3); it belongs in the concept, not built.
        var dc = reinterpret_cast::<*DeclContext>(m->semantic_dc);
        var owner = (dc->owner_decl()) if (dc != &null) else (&null);
        if (owner != &null) && (self._spell->leaf(static_cast::<*Decl>(m)) == self._spell->leaf(owner)) {
            self._ice(CXXSpell::at(static_cast::<*Decl>(m)), "EmitWitness: a constructor requirement; it never goes through the witness, and the concept does not list it yet");
        }
    }

    priv fn _at(self, p: *WitnessPiece) -> SourceRange {
        return CXXSpell::at(p->iface);
    }
}
