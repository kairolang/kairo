/// --- The Kairo Project ------------------- Sema/ConformanceChecking.k --- ///
///
///   \brief Interface conformance at the instantiation site, and the
///          conformance table it fills.
///
///   \detail
///     RESOLUTION.md §2b, "The conformance table". Wherever a generic's
///     `P impl I` bound meets a concrete argument X, `conforms(X, I)` finds
///     the ROW: for each of I's own requirements, the decl on X that
///     implements it -- an own or inherited member, an extension member, an
///     imported C++ member, whatever member lookup on X finds. The rows go
///     on the instance (`InstanceEntry::rows`, bound order, then each bound
///     interface's `derives` closure), which is the whole input of EmitPlan's
///     witness-specialization edge (CODEGEN.md §7b.6).
///
///     A requirement matches a candidate on the requirement's signature as
///     the conformer sees it: `Self` replaced by X (Deduction::replace_self),
///     the interface's own parameters by the bound's arguments. Exact, on
///     canonicals: the same receiver constness, the same parameter count,
///     modes and types, the same return type. Exact because the witness
///     forwards to the decl the row names and must reach the same one in
///     every TU (CODEGEN.md §7b.3); a looser match is a different design.
///
///     A row is shared build-wide (the registry's table): a row TU A found
///     is the one every TU holding the same instance reads. The row is
///     STRUCTURAL -- found at this use. Declared rows at the `impl`
///     declaration, the impl-only rule and extension visibility are this
///     pass's too and are not built yet; neither is the transitive case
///     (`f<T>` calling `g<T>`, M2's dependent conformance).
///
///   Phase: CHECK, after ExprTyper (it reads every call's registered
///   instance).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

import Sema::SemaContext::*;
import Sema::Resolve::NameLookup::*;
import Sema::Resolve::MemberLookup::*;
import Sema::Type::TypeUtil::*;
import Sema::Type::ArgumentDeduction::*;
import AST::Context::DeclContext::*;
import AST::Context::SymbolTable::*;
import AST::Context::TranslationUnit::*;
import AST::Context::InstantiationRegistry::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::ExprKind::*;
import AST::Kind::TypeKind::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Token::TokenKind::*;
import Diagnostic::Registry::*;
import Location::SourceRange::*;

class ConformanceChecking derives RecursiveASTVisitor::<ConformanceChecking> {
    pub var sc: *SemaContext;
    priv var tu: TypeUtil;
    priv var ml: MemberLookup;

    fn ConformanceChecking(self, sc: *SemaContext) {
        self.sc = sc;
        self.tu = TypeUtil(sc);
        self.ml = MemberLookup(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved);
        var tu = self.sc->tu;
        if (tu == &null) || (tu->program == &null) { return; }
        self.ml.index_extensions();
        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); ++i {
            var item = *(items->get(i));
            switch item.get_kind() {
                case TopLevelKind::Decl { self.dyn()->dispatch_decl(item.as_decl()); }
                case TopLevelKind::Stmt { self.dyn()->dispatch_stmt(item.as_stmt()); }
                case TopLevelKind::Expr { self.dyn()->dispatch_expr(item.as_expr()); }
            }
        }
    }

    fn visit_expr(self, e: *Expr) -> bool {
        if (e == &null) || e->is_poisoned() { return true; }
        // A bounded record's instance is an instantiation site wherever its
        // type turns up: written, inferred, or as an argument of another.
        if e->type_ != &null { self._check_type(e->type_, e->range, 0); }
        if e->kind != ExprKind::CallExpr { return true; }
        var c = cast::<CallExpr>(e);
        var ie = reinterpret_cast::<*InstanceEntry>(c->instance);
        if ie != &null { self._check_instance(ie, c->range); }
        self._check_qualified(c);
        return true;
    }

    fn visit_type(self, t: *Type) -> bool {
        if t != &null { self._check_type(t, t->range, 0); }
        return true;
    }

    /// Every record instance in \p t, its arguments included (`Vec<Box<M>>`).
    priv fn _check_type(self, t: *Type, at: SourceRange, depth: u32) {
        if (t == &null) || (depth > 16) { return; }
        var c = self._canon(t);
        if (c == &null) || c->is_dependent() || c->is_instantiation_dependent() { return; }
        switch c->kind {
            case TypeKind::PointerType      { self._check_type(cast::<PointerType>(c)->pointee, at, depth + 1); }
            case TypeKind::CXXLValueRefType { self._check_type(cast::<CXXLValueRefType>(c)->referee, at, depth + 1); }
            case TypeKind::CXXRValueRefType { self._check_type(cast::<CXXRValueRefType>(c)->referee, at, depth + 1); }
            case TypeKind::NullableType     { self._check_type(cast::<NullableType>(c)->inner, at, depth + 1); }
            case TypeKind::FixedArrayType   { self._check_type(cast::<FixedArrayType>(c)->element, at, depth + 1); }
            case TypeKind::RecordType {
                var r = cast::<RecordType>(c);
                for var i: usize = 0; i < r->args.size(); ++i { self._check_type(r->args[i], at, depth + 1); }
                if (r->decl == &null) || (!decl_is_instance(r->decl)) { return; }
                var e = self.sc->instances->entry_of(r->decl);
                if e != &null { self._check_instance(e, at); }
            }
            default { return; }
        }
    }

    /// `I::m(x, ...)` with x of a CONCRETE type: the call is the
    /// instantiation site, of no generic, so it carries its own row
    /// (CallExpr::witness_row). A dependent x is a bound's, and its rows come
    /// with the enclosing instance.
    priv fn _check_qualified(self, c: *CallExpr) {
        var ch = dyn_cast::<ChainExpr>(self.tu.strip_parens(c->callee));
        if (ch == &null) || (ch->steps.size() == 0) { return; }
        var st = ch->steps.get(ch->steps.size() - 1);
        if st->access_kind != ChainExpr::AccessKind::ColonColon { return; }
        var f = dyn_cast::<FunctionDecl>(st->resolved_decl);
        if (f == &null) || (!f->is_method()) || (!self._owned_by_interface(static_cast::<*Decl>(f))) { return; }
        var ai: i32 = 0;
        if c->arg_map.size() > 0 { ai = c->arg_map[0]; }
        if (ai < 0) || (static_cast::<usize>(ai) >= c->args.size()) { return; }
        var a = c->args[static_cast::<usize>(ai)];
        if (a == &null) || (a->type_ == &null) { return; }
        var x = self._object(a->type_);
        if (x == &null) || x->is_dependent() || x->is_instantiation_dependent() { return; }
        var home = reinterpret_cast::<*DeclContext>(f->semantic_dc)->owner_decl();
        var idecl = NameLookup::representative(home);
        if decl_generic_params(idecl).size() > 0 {
            var d = self.sc->diag->report(DiagID::SC001E, c->range.start,
                "a qualified call to a generic interface's requirement is not supported yet; call it through a value ('x.m()')");
            d.first(c->range);
            d.emit();
            return;
        }
        var empty = vec::<*Type>();
        var iface = self.sc->types->record(idecl, &empty);
        var row = self.conforms(x, iface);
        if (row == &null) || (!row->ok) { self._report(c->range, &null, x, iface, row); return; }
        c->witness_row = reinterpret_cast::<*void>(row);
    }

    /// The object a value of type \p t is: through a C++ reference, unqualified.
    priv fn _object(self, t: *Type) -> *Type {
        var c = self._canon(t);
        if c == &null { return &null; }
        if isa::<CXXLValueRefType>(c) { return canon_unqual(cast::<CXXLValueRefType>(c)->referee); }
        if isa::<CXXRValueRefType>(c) { return canon_unqual(cast::<CXXRValueRefType>(c)->referee); }
        return c;
    }

    // --- the instantiation site ----------------------------------------------------

    /// Fill \p e's rows from its primary's `impl` bounds, reporting at \p at
    /// a bound its argument does not meet.
    priv fn _check_instance(self, e: *InstanceEntry, at: SourceRange) {
        if e->rows_done { return; }
        // Checked at its first use with a place to report at; a type with no
        // range (a canonical reached without a written node) waits for one.
        if !at.start.is_valid() { return; }
        var prim = e->primary;
        if prim == &null { return; }
        var req = decl_requires_clause(prim);
        var bounds = vec::<*ConstraintExpr>();
        self._impl_bounds(req, &bounds);

        var rows = vec::<*ConformanceRow>();
        var ok = true;
        var gps = decl_generic_params(prim);
        for var i: usize = 0; i < bounds.size(); ++i {
            var b = bounds[i];
            var gp = self._param_named(b, prim);
            if (gp == &null) || gp->is_pack || (static_cast::<usize>(gp->index) >= e->args.size()) { continue; }
            var x = canon_unqual(e->args[static_cast::<usize>(gp->index)]);
            var iface = self._bound_iface(b, prim, e);
            if (x == &null) || (iface == &null) { continue; }
            var row = self.conforms(x, iface);
            if (row == &null) || (!row->ok) {
                self._report(at, b, x, iface, row);
                ok = false;
                continue;
            }
            if !self._push_closure(row, x, &rows, at, b) { ok = false; }
        }
        // Done either way: a non-conforming instance is reported once, at its
        // first use, however many times it is named.
        if !ok { rows.clear(); }
        self.sc->instances->set_rows(e, &rows);
    }

    /// \p row and the rows of its interface's `derives` closure, each once:
    /// a call bound to a base's requirement goes through the BASE's witness
    /// (CODEGEN.md §7b.9), so the instance needs that row too, and a base
    /// requirement \p x does not meet is the bound's failure, reported at
    /// \p at like the bound's own. False when one was reported.
    priv fn _push_closure(self, row: *ConformanceRow, x: *Type, out: *vec::<*ConformanceRow>,
                          at: SourceRange, b: *ConstraintExpr) -> bool {
        for var i: usize = 0; i < out->size(); ++i { if (*out)[i] == row { return true; } }
        out->push_back(row);
        var ok = true;
        var idecl = row->iface_decl;
        var edges = decl_bases(idecl);
        for var i: usize = 0; i < edges.size(); ++i {
            var base = edges.get(i)->base;
            if (base == &null) || (base->canonical == &null) { continue; }
            var bi = self._through_iface(canon_unqual(base->canonical), row->iface);
            var br = self.conforms(x, bi);
            if (br == &null) || (!br->ok) {
                self._report(at, b, x, bi, br);
                ok = false;
                continue;
            }
            if !self._push_closure(br, x, out, at, b) { ok = false; }
        }
        return ok;
    }

    // --- the table -----------------------------------------------------------------

    /// THE row for (\p x, \p iface): the table's, else built by the
    /// requirement match below and recorded. Never null for an interface
    /// type; `ok` false when some requirement has no implementation on \p x.
    fn conforms(self, x: *Type, iface: *Type) -> *ConformanceRow {
        var hit = self.sc->instances->row_find(x, iface);
        if hit != &null { return hit; }
        var idecl = self._iface_decl(iface);
        if idecl == &null { return &null; }

        var row = ConformanceRow();
        row.conformer  = x;
        row.iface      = iface;
        row.iface_decl = static_cast::<*Decl>(idecl);
        row.ok         = true;
        for var i: usize = 0; i < idecl->methods.size(); ++i {
            var m = idecl->methods[i];
            var w = self._implementation(x, iface, idecl, m);
            row.witnesses.push_back(w);
            var ea = vec::<*Type>();
            if (w == &null) || (!self._ext_args(cast::<FunctionDecl>(w), x, &ea)) { row.ok = false; }
            row.ext_arg_count.push_back(ea.size());
            for var k: usize = 0; k < ea.size(); ++k { row.ext_args.push_back(ea[k]); }
        }
        return self.sc->instances->row_add(&row);
    }

    /// The arguments \p x binds a GENERIC extension's parameters to, when
    /// \p f is its member (`extend <E> Wrap<E>` reached through `Wrap<i32>`:
    /// [i32]), appended to \p out; nothing for any other \p f. False when
    /// the target does not match \p x or leaves a parameter unbound.
    priv fn _ext_args(self, f: *FunctionDecl, x: *Type, out: *vec::<*Type>) -> bool {
        var ext = decl_extension_of(static_cast::<*Decl>(f));
        if ext == &null { return true; }
        var eps = decl_generic_params(static_cast::<*Decl>(ext));
        if eps.size() == 0 { return true; }
        var d = Deduction(self.sc, &null);
        if !d.bind_from_extension(f, x) { return false; }
        for var i: usize = 0; i < eps.size(); ++i {
            var gp = eps[i];
            if gp == &null { return false; }
            var b = d.lookup(NameLookup::representative(static_cast::<*Decl>(ext)), gp->index);
            if b == &null { b = d.lookup(static_cast::<*Decl>(ext), gp->index); }
            if (b == &null) || b->is_dependent() { return false; }
            out->push_back(b);
        }
        return true;
    }

    /// The member of \p x that implements requirement \p m of \p iface, or
    /// null. Every candidate member lookup finds is a decl the row could
    /// forward to; the one whose signature is \p m's exactly wins.
    priv fn _implementation(self, x: *Type, iface: *Type, idecl: *InterfaceDecl, m: *FunctionDecl) -> *Decl {
        if (m == &null) || m->is_poisoned() { return &null; }
        var cands = vec::<*Decl>();
        self.ml.lookup(x, self._name_of(m), &cands);
        for var i: usize = 0; i < cands.size(); ++i {
            var f = dyn_cast::<FunctionDecl>(cands[i]);
            if (f == &null) || f->is_poisoned() { continue; }
            if self._owned_by_interface(static_cast::<*Decl>(f)) { continue; }   // a bound's own requirement, never a witness.
            if self._signature_matches(f, m, x, iface, idecl) { return NameLookup::representative(static_cast::<*Decl>(f)); }
        }
        return &null;
    }

    priv fn _signature_matches(self, f: *FunctionDecl, m: *FunctionDecl, x: *Type, iface: *Type, idecl: *InterfaceDecl) -> bool {
        if f->is_method() != m->is_method() { return false; }
        if f->is_method() && (f->is_const() != m->is_const()) { return false; }
        if f->generic_params.size() != m->generic_params.size() { return false; }
        if f->params.size() != m->params.size() { return false; }
        for var i: usize = 0; i < f->params.size(); ++i {
            var fp = f->params[i];
            var mp = m->params[i];
            if (fp == &null) || (mp == &null) { return false; }
            if fp->is_self != mp->is_self { return false; }
            if fp->is_self { continue; }
            if (fp->mode != mp->mode) || (fp->is_pack != mp->is_pack) { return false; }
            if self._as_candidate(fp->type_, f, x) != self._as_conformer(mp->type_, x, iface, idecl, m, f) { return false; }
        }
        return self._as_candidate(f->return_type, f, x) == self._as_conformer(m->return_type, x, iface, idecl, m, f);
    }

    /// Candidate \p f's type \p t as reached through \p x: a generic
    /// extension's parameters bound from \p x (its target unified with it),
    /// \p f's own parameters left as themselves. Top-level cv dropped.
    priv fn _as_candidate(self, t: *Type, f: *FunctionDecl, x: *Type) -> *Type {
        var c = self._canon(t);
        if (c == &null) || (!c->is_dependent()) { return c; }
        var d = Deduction(self.sc, &null);
        if !d.bind_from_extension(f, x) { return c; }
        var frep = NameLookup::representative(static_cast::<*Decl>(f));
        for var i: usize = 0; i < f->generic_params.size(); ++i {
            var gp = f->generic_params[i];
            if gp == &null { continue; }
            d.bind(frep, gp->index, self.sc->types->generic_param(frep, gp->index, gp->is_pack));
        }
        var s = d.substitute(c);
        return (canon_unqual(s)) if (s != &null) else (c);
    }

    /// Requirement type \p t as conformer \p x sees it: the interface's own
    /// parameters bound to \p iface's arguments, a GENERIC requirement's own
    /// parameters to candidate \p f's by position (`fn <U> put(u: U)` and
    /// `fn <V> put(v: V)` are one signature), then `Self` replaced by \p x.
    /// Top-level cv dropped, as for any signature compare.
    priv fn _as_conformer(self, t: *Type, x: *Type, iface: *Type, idecl: *InterfaceDecl,
                          m: *FunctionDecl, f: *FunctionDecl) -> *Type {
        var c = self._canon(t);
        if c == &null { return &null; }
        var d = Deduction(self.sc, &null);
        if c->is_dependent() {
            d.bind_from_record(iface);
            var mrep = NameLookup::representative(static_cast::<*Decl>(m));
            var frep = NameLookup::representative(static_cast::<*Decl>(f));
            for var i: usize = 0; i < m->generic_params.size(); ++i {
                var gp = m->generic_params[i];
                if gp == &null { continue; }
                d.bind(mrep, gp->index, self.sc->types->generic_param(frep, f->generic_params[i]->index, gp->is_pack));
            }
            var s = d.substitute(c);
            if s != &null { c = s; }
        }
        return canon_unqual(d.replace_self(c, static_cast::<*Decl>(idecl), x));
    }

    priv fn _canon(self, t: *Type) -> *Type {
        if t == &null { return &null; }
        var c = t->canonical;
        if c == &null { c = t; }
        return canon_unqual(c);
    }

    /// The requirement's name in THIS TU's imm space: the interface may be
    /// another file's, and MemberLookup keys identifiers by the asking TU.
    priv fn _name_of(self, m: *FunctionDecl) -> DeclName {
        if m->is_operator {
            var k0 = TokenKind::TkUnknown; var k1 = TokenKind::TkUnknown;
            if m->op_token.size() > 0 { k0 = m->op_token[0].kind; }
            if m->op_token.size() > 1 { k1 = m->op_token[1].kind; }
            return DeclName::op_name(k0, k1);
        }
        var imms = self.sc->ctx->get_imm_table();
        return DeclName::ident(imms->intern_ident_copy(self.tu.decl_name(static_cast::<*Decl>(m))));
    }

    // --- bounds ----------------------------------------------------------------------

    /// Every `impl` conjunct of \p e, in clause order (RequiresDesugar hoisted
    /// the inline bounds in; ConstraintExtraction splits it the same way).
    priv fn _impl_bounds(self, e: *Expr, out: *vec::<*ConstraintExpr>) {
        if e == &null { return; }
        if e->kind == ExprKind::BinaryOperatorExpr {
            var b = cast::<BinaryOperatorExpr>(e);
            if (b->op_token.kind == TokenKind::OpAmpAmp) || (b->op_token.kind == TokenKind::KwAnd) {
                self._impl_bounds(b->lhs, out);
                self._impl_bounds(b->rhs, out);
                return;
            }
        }
        if e->kind != ExprKind::ConstraintExpr { return; }
        var c = cast::<ConstraintExpr>(e);
        if !c->is_derives() { out->push_back(c); }
    }

    /// The generic parameter of \p owner that conjunct \p c constrains, or
    /// null (a conjunct on an enclosing record's parameter).
    priv fn _param_named(self, c: *ConstraintExpr, owner: *Decl) -> *GenericParamDecl {
        var id = dyn_cast::<NamedIdentExpr>(c->lhs);
        if id == &null { return &null; }
        var gp = dyn_cast::<GenericParamDecl>(id->resolved_decl);
        if gp == &null { return &null; }
        var gps = decl_generic_params(owner);
        for var i: usize = 0; i < gps.size(); ++i { if gps[i] == gp { return gp; } }
        return &null;
    }

    /// The bound's interface at instance \p e: `T impl Container<U>` with
    /// U bound to e's argument.
    priv fn _bound_iface(self, c: *ConstraintExpr, owner: *Decl, e: *InstanceEntry) -> *Type {
        if (c->rhs == &null) || (c->rhs->canonical == &null) { return &null; }
        var t = canon_unqual(c->rhs->canonical);
        if !t->is_dependent() { return t; }
        var d = Deduction(self.sc, &null);
        var gps = decl_generic_params(owner);
        for var i: usize = 0; (i < gps.size()) && (i < e->args.size()); ++i {
            if gps[i] == &null { continue; }
            d.bind(owner, gps[i]->index, e->args[i]);
        }
        var s = d.substitute(t);
        return (canon_unqual(s)) if (s != &null) else (&null);
    }

    /// Base interface \p base, written in a `derives` edge of \p derived's
    /// declaration, at \p derived's arguments.
    priv fn _through_iface(self, base: *Type, derived: *Type) -> *Type {
        if !base->is_dependent() { return base; }
        var d = Deduction(self.sc, &null);
        d.bind_from_record(derived);
        var s = d.substitute(base);
        return (canon_unqual(s)) if (s != &null) else (base);
    }

    priv fn _iface_decl(self, iface: *Type) -> *InterfaceDecl {
        if (iface == &null) || (!isa::<RecordType>(iface)) { return &null; }
        var d = NameLookup::representative(self.tu.pattern_of(cast::<RecordType>(iface)->decl));
        return dyn_cast::<InterfaceDecl>(d);
    }

    priv fn _owned_by_interface(self, d: *Decl) -> bool {
        if d->semantic_dc == &null { return false; }
        var home = reinterpret_cast::<*DeclContext>(d->semantic_dc)->owner_decl();
        return (home != &null) && isa::<InterfaceDecl>(home);
    }

    // --- the diagnostic -------------------------------------------------------------

    /// `scale`, or `op +=` for an operator: an operator's name token is its
    /// operator token, which decl_name cannot spell as an identifier.
    priv fn _req_name(self, m: *FunctionDecl) -> string {
        if !m->is_operator { return self.tu.decl_name(static_cast::<*Decl>(m)); }
        var ctx = NameLookup::ctx_of(static_cast::<*Decl>(m));
        var s = "op ";
        for var i: usize = 0; i < m->op_token.size(); ++i { s += ctx->get_spelling(m->op_token[i]); }
        return s;
    }

    priv fn _report(self, at: SourceRange, b: *ConstraintExpr, x: *Type, iface: *Type, row: *ConformanceRow) {
        var xs = self.tu.str(x);
        var is = self.tu.str(iface);
        var missing = "";
        var req: *FunctionDecl = &null;
        if row != &null {
            var idecl = cast::<InterfaceDecl>(row->iface_decl);
            for var i: usize = 0; i < row->witnesses.size(); ++i {
                if row->witnesses[i] != &null { continue; }
                req = idecl->methods[i];
                missing = self._req_name(req);
                break;
            }
        }
        var msg = f"'{xs}' does not conform to '{is}\x27";
        if missing.size() > 0 { msg = f"'{xs}' does not conform to '{is}': no member '{missing}' with the requirement's signature"; }
        var d = self.sc->diag->report(DiagID::SC001E, at.start, msg);
        d.first(at);
        if b != &null { d.note(b->range.start, f"required by this bound").first(b->range); }
        if req != &null { d.note(req->range.start, f"'{missing}' is required here").first(req->range); }
        d.emit();
    }
}
