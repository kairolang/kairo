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
///     A constructor requirement is the exception to looking up by name:
///     X's own constructors are, named after X (_ctor_implementation).
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
import Sema::Check::ClassLifecycle::*;
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

/// The dependent uses in a generic body that name instances of their own
/// once the body's parameters are known: calls whose callee's arguments are
/// still dependent (CallExpr::dep_args), and dependent record types.
/// Collected, not checked: ConformanceChecking substitutes and checks them
/// per instance of the enclosing generic.
class _NestedUses derives RecursiveASTVisitor::<_NestedUses> {
    pub var calls: vec::<*CallExpr>;
    pub var types: vec::<*Type>;
    fn _NestedUses(self) { }

    fn visit_expr(self, e: *Expr) -> bool {
        if (e == &null) || e->is_poisoned() { return true; }
        if (e->type_ != &null) && e->type_->is_dependent() { self.types.push_back(e->type_); }
        if e->kind != ExprKind::CallExpr { return true; }
        var c = cast::<CallExpr>(e);
        if c->dep_args.size() > 0 { self.calls.push_back(c); }
        return true;
    }

    fn visit_type(self, t: *Type) -> bool {
        if (t != &null) && t->is_dependent() { self.types.push_back(t); }
        return true;
    }
}

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
        if x == &null { return; }
        if isa::<GenericParamType>(x) { self._qualified_bound(c, cast::<GenericParamType>(x), f); return; }
        if x->is_dependent() || x->is_instantiation_dependent() { return; }
        // The requirement's DECLARING interface at the qualifier's arguments
        // (CallTyping left the qualifier on the call): `Container<i32>::get`
        // checks Box against Container<i32>, and `Sub<i32>::get` against the
        // Container instance Sub derives.
        var home = reinterpret_cast::<*DeclContext>(f->semantic_dc)->owner_decl();
        var idecl = NameLookup::representative(home);
        var iface: *Type = &null;
        if c->witness_iface != &null {
            var d = Deduction(self.sc, &null);
            iface = d.declaring_instance(f, c->witness_iface);
        }
        if iface == &null {
            var empty = vec::<*Type>();
            iface = self.sc->types->record(idecl, &empty);
        }
        var row = self.conforms(x, iface);
        if (row == &null) || (!row->ok) { self._report(c->range, &null, x, iface, row); return; }
        c->witness_row = reinterpret_cast::<*void>(row);
    }

    /// `I<A>::m(c, ...)` with c a bounded parameter: the bound the call goes
    /// through is the one whose `m` is the qualifier's -- with `C impl
    /// Container<i32> + Container<bool>`, `Container<bool>::get(c, 0)` is
    /// the second -- and the call keeps it (CallExpr::witness_iface) for
    /// ExtensionLowering. No such bound is an error here: the first bound
    /// with an `m` would type, and spell a witness the call did not name.
    priv fn _qualified_bound(self, c: *CallExpr, g: *GenericParamType, f: *FunctionDecl) {
        if c->witness_iface == &null { return; }
        var d = Deduction(self.sc, &null);
        var want = d.declaring_instance(f, c->witness_iface);
        if want == &null { return; }
        var it = self.sc->bounds.find(reinterpret_cast::<u64>(g->owner));
        if it != self.sc->bounds.end() {
            var _set = &(it->second);
            for var i: usize = 0; i < _set->impl_constraints.size(); ++i {
                var b = _set->impl_constraints[i];
                var id = dyn_cast::<NamedIdentExpr>(b->lhs);
                if id == &null { continue; }
                var gp = dyn_cast::<GenericParamDecl>(id->resolved_decl);
                if (gp == &null) || (gp->index != g->param_index) { continue; }
                if NameLookup::representative(gp->owner) != NameLookup::representative(g->owner) { continue; }
                if (b->rhs == &null) || (b->rhs->canonical == &null) { continue; }
                var t = canon_unqual(b->rhs->canonical);
                if d.declaring_instance(f, t) == want { c->witness_iface = t; return; }
            }
        }
        var xs = self.tu.str(static_cast::<*Type>(g));
        var is = self.tu.str(c->witness_iface);
        var r = self.sc->diag->report(DiagID::SC001E, c->range.start,
            f"no bound on '{xs}' provides '{is}::{self._req_name(f)}'; bound it 'impl {is}\x27");
        r.first(c->range);
        r.note(f->range.start, f"'{self._req_name(f)}' is required here").first(f->range);
        r.emit();
        c->poison();
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
    /// Instances whose rows are being computed, outermost first: a generic
    /// that reaches itself (directly, or `f<T>` calling `f<Wrap<T>>`) stops
    /// there instead of recursing forever.
    priv var _active: vec::<*InstanceEntry>;

    priv fn _check_instance(self, e: *InstanceEntry, at: SourceRange) {
        if e->rows_done { return; }
        for var i: usize = 0; i < self._active.size(); ++i { if self._active[i] == e { return; } }
        if self._active.size() >= 8 { return; }   // M2's depth, not ours to chase further.
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
            if (gp == &null) || gp->is_pack { continue; }
            var x = self._arg_of(e, prim, gp);
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
        // The instances its body reaches once its parameters are known, and
        // their rows: every TU holding this instance may compile its body
        // and theirs (§7b.6), so they ride on this instance's rows.
        if ok {
            self._active.push_back(e);
            if !self._reach(e, prim, at, &rows) { ok = false; }
            self._active.pop_back();
        }
        // Done either way: a non-conforming instance is reported once, at its
        // first use, however many times it is named.
        if !ok { rows.clear(); }
        self.sc->instances->set_rows(e, &rows);
    }

    /// Instance \p e's argument for \p gp, a parameter of \p prim or of its
    /// extension: instance arguments run in CXXSpell::template_params order,
    /// an extension's first.
    priv fn _arg_of(self, e: *InstanceEntry, prim: *Decl, gp: *GenericParamDecl) -> *Type {
        var off: usize = 0;
        var x = decl_extension_of(prim);
        if x != &null {
            var eps = decl_generic_params(static_cast::<*Decl>(x));
            for var i: usize = 0; i < eps.size(); ++i { if eps[i] == gp { off = i; return (canon_unqual(e->args[off])) if (off < e->args.size()) else (&null); } }
            off = eps.size();
        }
        var k = off + static_cast::<usize>(gp->index);
        return (canon_unqual(e->args[k])) if (k < e->args.size()) else (&null);
    }

    /// Walk \p prim's body (a record's: its methods') for the dependent
    /// uses that become instances under \p e's arguments, check each, and
    /// add its rows -- its own reach included -- to \p rows. False when one
    /// of them does not conform (reported at \p at, the outer use).
    priv fn _reach(self, e: *InstanceEntry, prim: *Decl, at: SourceRange, rows: *vec::<*ConformanceRow>) -> bool {
        var uses = _NestedUses();
        if isa::<FunctionDecl>(prim) {
            uses.dispatch_decl(prim);
        } else {
            var ms = self._methods_of(prim);
            for var i: usize = 0; i < ms.size(); ++i { if ms[i] != &null { uses.dispatch_decl(static_cast::<*Decl>(ms[i])); } }
        }
        if (uses.calls.size() == 0) && (uses.types.size() == 0) { return true; }

        var d = Deduction(self.sc, &null);
        self._bind_instance(&d, e, prim);
        var ok = true;
        for var i: usize = 0; i < uses.calls.size(); ++i {
            var c = uses.calls[i];
            var callee = self._callee_of(c);
            if (callee == &null) || self._owned_by_interface(callee) { continue; }
            var args = vec::<*Type>();
            var whole = true;
            for var k: usize = 0; k < c->dep_args.size(); ++k {
                var s = d.substitute(c->dep_args[k]);
                if (s == &null) || s->is_dependent() || s->is_instantiation_dependent() { whole = false; break; }
                args.push_back(canon_unqual(s));
            }
            if !whole { continue; }   // a parameter of an inner generic: that one's instances reach it.
            var rep = NameLookup::representative(callee);
            var ne = self.sc->instances->instance_for(rep, &args, self.sc->ctx->fid, NameLookup::ctx_of(rep));
            if !self._take(ne, at, rows) {
                // The error points at the outer use; this says which call in
                // the generic's body asked for the instance that failed.
                var nb = self.sc->diag->report(DiagID::SC001N, c->range.start,
                    f"required by this call, in the instance of '{self.tu.decl_name(prim)}' used there");
                nb.first(c->range);
                nb.emit();
                ok = false;
            }
        }
        for var i: usize = 0; i < uses.types.size(); ++i {
            var s = d.substitute(self._canon(uses.types[i]));
            if (s == &null) || s->is_dependent() { continue; }
            if !self._take_type(s, at, rows, 0) { ok = false; }
        }
        return ok;
    }

    /// Check nested instance \p ne at the outer use and add its rows.
    priv fn _take(self, ne: *InstanceEntry, at: SourceRange, rows: *vec::<*ConformanceRow>) -> bool {
        if ne == &null { return true; }
        var before = self.sc->diag->error_count();
        self._check_instance(ne, at);
        if self.sc->diag->error_count() != before { return false; }
        for var k: usize = 0; k < ne->rows.size(); ++k {
            var dup = false;
            for var j: usize = 0; j < rows->size(); ++j { if (*rows)[j] == ne->rows[k] { dup = true; break; } }
            if !dup { rows->push_back(ne->rows[k]); }
        }
        return true;
    }

    /// Every record instance in substituted type \p t, as _check_type finds them.
    priv fn _take_type(self, t: *Type, at: SourceRange, rows: *vec::<*ConformanceRow>, depth: u32) -> bool {
        var c = self._canon(t);
        if (c == &null) || (depth > 16) { return true; }
        var ok = true;
        switch c->kind {
            case TypeKind::PointerType      { ok = self._take_type(cast::<PointerType>(c)->pointee, at, rows, depth + 1); }
            case TypeKind::CXXLValueRefType { ok = self._take_type(cast::<CXXLValueRefType>(c)->referee, at, rows, depth + 1); }
            case TypeKind::CXXRValueRefType { ok = self._take_type(cast::<CXXRValueRefType>(c)->referee, at, rows, depth + 1); }
            case TypeKind::NullableType     { ok = self._take_type(cast::<NullableType>(c)->inner, at, rows, depth + 1); }
            case TypeKind::FixedArrayType   { ok = self._take_type(cast::<FixedArrayType>(c)->element, at, rows, depth + 1); }
            case TypeKind::RecordType {
                var r = cast::<RecordType>(c);
                for var i: usize = 0; i < r->args.size(); ++i { if !self._take_type(r->args[i], at, rows, depth + 1) { ok = false; } }
                if (r->decl != &null) && decl_is_instance(r->decl) {
                    if !self._take(self.sc->instances->entry_of(r->decl), at, rows) { ok = false; }
                }
            }
            default { ok = true; }
        }
        return ok;
    }

    /// \p e's arguments bound to \p prim's parameters (an extension
    /// member's extension's first; a record method's body sees its record's).
    priv fn _bind_instance(self, d: *Deduction, e: *InstanceEntry, prim: *Decl) {
        var k: usize = 0;
        var x = decl_extension_of(prim);
        if x != &null {
            var eps = decl_generic_params(static_cast::<*Decl>(x));
            var xr = NameLookup::representative(static_cast::<*Decl>(x));
            for var i: usize = 0; (i < eps.size()) && (k < e->args.size()); ++i {
                if eps[i] != &null { d->bind(xr, eps[i]->index, e->args[k]); }
                k += 1;
            }
        }
        var gps = decl_generic_params(prim);
        var pr = NameLookup::representative(prim);
        for var i: usize = 0; (i < gps.size()) && (k < e->args.size()); ++i {
            if gps[i] != &null { d->bind(pr, gps[i]->index, e->args[k]); }
            k += 1;
        }
    }

    priv fn _callee_of(self, c: *CallExpr) -> *Decl {
        var callee = self.tu.strip_parens(c->callee);
        var ni = dyn_cast::<NamedIdentExpr>(callee);
        if ni != &null { return ni->resolved_decl; }
        var ch = dyn_cast::<ChainExpr>(callee);
        if (ch != &null) && (ch->steps.size() > 0) { return ch->steps.get(ch->steps.size() - 1)->resolved_decl; }
        return &null;
    }

    priv fn _methods_of(self, d: *Decl) -> FrozenList::<*FunctionDecl> {
        if isa::<ClassDecl>(d)  { return cast::<ClassDecl>(d)->methods; }
        if isa::<StructDecl>(d) { return cast::<StructDecl>(d)->methods; }
        if isa::<UnionDecl>(d)  { return cast::<UnionDecl>(d)->methods; }
        return create_empty_frozen_list::<*FunctionDecl>();
    }

    /// \p row and the rows of its interface's `derives` closure, each once:
    /// a call bound to a base's requirement goes through the BASE's witness
    /// (CODEGEN.md §7b.9), so the instance needs that row too, and a base
    /// requirement \p x does not meet is the bound's failure, reported at
    /// \p at like the bound's own. False when one was reported.
    priv fn _push_closure(self, row: *ConformanceRow, x: *Type, out: *vec::<*ConformanceRow>,
                          at: SourceRange, b: *ConstraintExpr) -> bool {
        for var i: usize = 0; i < out->size(); ++i { if (*out)[i] == row { return true; } }
        // One row covers the interface's whole composed requirement list,
        // inherited requirements included (InterfaceComposition): a call
        // through the bound goes through the bound's witness, so there are no
        // base rows to add.
        out->push_back(row);
        return true;
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
        // Parallel to the interface's composed requirement list. An
        // associated type's entry has no witness decl yet (they are not
        // compiled) and does not fail the row.
        var decls = vec::<*Decl>();
        var srcs  = vec::<*Type>();
        self._reqs(idecl, iface, &decls, &srcs);
        for var i: usize = 0; i < decls.size(); ++i {
            var m = dyn_cast::<FunctionDecl>(decls[i]);
            var w: *Decl = &null;
            var ea = vec::<*Type>();
            if m != &null {
                var k = self._iface_decl(srcs[i]);
                w = self._implementation(x, srcs[i], k, m);
                // A constructor slot's witness may be the record itself (its
                // implicit default constructor), which has no extension.
                var wf = dyn_cast::<FunctionDecl>(w);
                if (w == &null) || ((wf != &null) && (!self._ext_args(wf, x, &ea))) { row.ok = false; }
            }
            row.witnesses.push_back(w);
            row.sources.push_back(srcs[i]);
            row.ext_arg_count.push_back(ea.size());
            for var k2: usize = 0; k2 < ea.size(); ++k2 { row.ext_args.push_back(ea[k2]); }
        }
        return self.sc->instances->row_add(&row);
    }

    /// \p idecl's requirement decls and, for each, the interface instance it
    /// came through, at \p iface's arguments. The composed list
    /// (InterfaceComposition); an interface it never composed (it was
    /// poisoned) contributes its own methods.
    priv fn _reqs(self, idecl: *InterfaceDecl, iface: *Type, decls: *vec::<*Decl>, srcs: *vec::<*Type>) {
        if idecl->compose_state != 2 {
            for var i: usize = 0; i < idecl->methods.size(); ++i { decls->push_back(static_cast::<*Decl>(idecl->methods[i])); srcs->push_back(iface); }
            return;
        }
        for var i: usize = 0; i < idecl->requirements.size(); ++i {
            var r = idecl->requirements.get(i);
            decls->push_back(r->decl);
            srcs->push_back(self._through_iface(self._canon(r->source), iface));
        }
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
        if decl_is_ctor_requirement(m) { return self._ctor_implementation(x, iface, idecl, m); }
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

    /// The constructor of \p x that meets constructor requirement \p m, or
    /// null. Looked up as CallTyping's `_ctor_call` looks up `X(args)`: X's
    /// OWN table under DeclName::ctor(), never member lookup, whose walk
    /// reaches a base's constructors and no extension can add one. A record
    /// that declares none has the implicit default constructor `X()` types
    /// against; the record itself stands for it, so the row is complete. A
    /// builtin has no constructor to call -- `i32()` is SC037E -- and so
    /// meets none.
    priv fn _ctor_implementation(self, x: *Type, iface: *Type, idecl: *InterfaceDecl, m: *FunctionDecl) -> *Decl {
        var c = self._canon(x);
        if c == &null { return &null; }
        if m->transfer != TransferKind::NotTransfer { return self._transfer_implementation(c, m); }
        if !isa::<RecordType>(c) { return &null; }
        var d = self.tu.record_decl(c);
        if (d == &null) || isa::<InterfaceDecl>(d) { return &null; }
        var dc = NameLookup::context_of(self.tu.pattern_of(d));   // an unfilled instance has an empty table.
        var cands = vec::<*Decl>();
        if dc != &null {
            var cell = self.sc->lookup.in_context(dc, DeclName::ctor());
            if cell.found() {
                for var i: usize = 0; i < cell.cell->size(); ++i { cands.push_back(cell.cell->get(i)); }
            }
        }
        if cands.size() == 0 {
            if self._arity(m) == 0 { return NameLookup::representative(d); }
            return &null;
        }
        for var i: usize = 0; i < cands.size(); ++i {
            var f = dyn_cast::<FunctionDecl>(cands[i]);
            if (f == &null) || f->is_poisoned() || (f->adt_role != AdtRole::None) { continue; }
            if self._ctor_matches(f, m, c, iface, idecl) { return NameLookup::representative(static_cast::<*Decl>(f)); }
        }
        return &null;
    }

    /// A LIFECYCLE requirement (`@copy fn Copyable(self, const other: Self)`)
    /// asks for a category, not a declared constructor (Doc: Interface
    /// Requirements): `@copy` is met by COPY types, `@move` by COPY and
    /// MOVE, NON_TRANSFER by neither -- an implicit transfer counts, and a
    /// builtin is COPY. The record stands as the witness; a builtin has no
    /// decl, so the requirement itself does, which no consumer forwards to
    /// (a constructor slot never reaches a witness member).
    priv fn _transfer_implementation(self, c: *Type, m: *FunctionDecl) -> *Decl {
        var f = lifecycle_of(self.sc)->facts_of_type(c);
        var ok = (f.category == LifecycleCategory::Copy);
        if m->transfer == TransferKind::Move { ok = ok || (f.category == LifecycleCategory::Move); }
        if !ok { return &null; }
        var d = self.tu.record_decl(c);
        if d != &null { return NameLookup::representative(d); }
        return static_cast::<*Decl>(m);
    }

    /// _signature_matches for a constructor: no receiver constness and no
    /// return type to compare, and a generic record's parameters in the
    /// candidate bound from \p x, as `Box<i32>(n)` binds them.
    priv fn _ctor_matches(self, f: *FunctionDecl, m: *FunctionDecl, x: *Type, iface: *Type, idecl: *InterfaceDecl) -> bool {
        if f->generic_params.size() != m->generic_params.size() { return false; }
        if f->params.size() != m->params.size() { return false; }
        for var i: usize = 0; i < f->params.size(); ++i {
            var fp = f->params[i];
            var mp = m->params[i];
            if (fp == &null) || (mp == &null) { return false; }
            if fp->is_self != mp->is_self { return false; }
            if fp->is_self { continue; }
            if (fp->mode != mp->mode) || (fp->is_pack != mp->is_pack) { return false; }
            if self._as_ctor_param(fp->type_, f, x) != self._as_conformer(mp->type_, x, iface, idecl, m, f) { return false; }
        }
        return true;
    }

    /// Constructor \p f's parameter type \p t as `X(args)` sees it: the
    /// record's parameters bound to \p x's arguments, \p f's own left as
    /// themselves. Top-level cv dropped.
    priv fn _as_ctor_param(self, t: *Type, f: *FunctionDecl, x: *Type) -> *Type {
        var c = self._canon(t);
        if (c == &null) || (!c->is_dependent()) { return c; }
        var d = Deduction(self.sc, &null);
        d.bind_from_record(x);
        var frep = NameLookup::representative(static_cast::<*Decl>(f));
        for var i: usize = 0; i < f->generic_params.size(); ++i {
            var gp = f->generic_params[i];
            if gp == &null { continue; }
            d.bind(frep, gp->index, self.sc->types->generic_param(frep, gp->index, gp->is_pack));
        }
        var s = d.substitute(c);
        return (canon_unqual(s)) if (s != &null) else (c);
    }

    /// Parameters after the receiver.
    priv fn _arity(self, m: *FunctionDecl) -> usize {
        var n: usize = 0;
        for var i: usize = 0; i < m->params.size(); ++i { if (m->params[i] != &null) && (!m->params[i]->is_self) { n += 1; } }
        return n;
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
        // Self first: in a GENERIC interface it is `I<T>` over I's own
        // parameters, which the substitution below would turn into an
        // instance (`I<i32>`) that no longer reads as Self.
        // A dependent x waits: the substitution cannot bind the caller's
        // parameters, and would give up on the whole type.
        if !x->is_dependent() { c = d.replace_self(c, static_cast::<*Decl>(idecl), x, true); }
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

    /// `Counter(i32, Counter)`: constructor requirement \p m as conformer
    /// \p x would declare it, Self and the interface's parameters replaced.
    priv fn _ctor_spelling(self, m: *FunctionDecl, x: *Type, iface: *Type, idecl: *InterfaceDecl) -> string {
        var s = self.tu.str(x) + "(";
        var k: usize = 0;
        for var i: usize = 0; i < m->params.size(); ++i {
            var p = m->params[i];
            if (p == &null) || p->is_self { continue; }
            if k > 0 { s += ", "; }
            s += self.tu.str(self._as_conformer(p->type_, x, iface, idecl, m, m));
            k += 1;
        }
        return s + ")";
    }

    priv fn _report(self, at: SourceRange, b: *ConstraintExpr, x: *Type, iface: *Type, row: *ConformanceRow) {
        var xs = self.tu.str(x);
        var is = self.tu.str(iface);
        var missing = "";
        var req: *FunctionDecl = &null;
        if row != &null {
            var decls = vec::<*Decl>();
            var srcs  = vec::<*Type>();
            self._reqs(cast::<InterfaceDecl>(row->iface_decl), row->iface, &decls, &srcs);
            for var i: usize = 0; (i < row->witnesses.size()) && (i < decls.size()); ++i {
                if row->witnesses[i] != &null { continue; }
                var f = dyn_cast::<FunctionDecl>(decls[i]);
                if f == &null { continue; }   // an associated type: not checked yet.
                req = f;
                missing = self._req_name(req);
                break;
            }
        }
        var msg = f"'{xs}' does not conform to '{is}\x27";
        var req_note = f"'{missing}' is required here";
        if (req != &null) && decl_is_ctor_requirement(req) {
            // Named as the conformer's constructor would be, since that is what
            // is missing: the requirement's own name is the interface's.
            var ctor = self._ctor_spelling(req, x, row->iface, cast::<InterfaceDecl>(row->iface_decl));
            msg = f"'{xs}' does not conform to '{is}': no constructor '{ctor}\x27";
            req_note = "the constructor is required here";
            // A lifecycle requirement asks for a category, which is what to
            // name: the transfer constructor may well be implicit.
            if req->transfer == TransferKind::Copy { msg = f"'{xs}' does not conform to '{is}': '{xs}' is not a COPY type"; }
            if req->transfer == TransferKind::Move { msg = f"'{xs}' does not conform to '{is}': '{xs}' is neither COPY nor MOVE"; }
        } else if missing.size() > 0 {
            msg = f"'{xs}' does not conform to '{is}': no member '{missing}' with the requirement's signature";
        }
        var d = self.sc->diag->report(DiagID::SC001E, at.start, msg);
        d.first(at);
        if b != &null { d.note(b->range.start, f"required by this bound").first(b->range); }
        if req != &null { d.note(req->range.start, req_note).first(req->range); }
        d.emit();
    }
}
