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
///     is the one every TU holding the same instance reads, and an
///     instance's rows are the union over every TU that checked it (MONO.md
///     D7), so every TU's C++ carries the same ones. Which rows a TU's own
///     checks may USE is a per-TU filter, the extension-visibility rule: a
///     row whose extension members are outside the TU's transitive import
///     set is not this TU's (`_usable`; ConformanceRow::seen_by), and a use
///     here is checked against what this TU sees, even of an instance
///     another TU made live first (`_recheck`). The row is
///     STRUCTURAL -- found at this use -- or DECLARED, found at the `impl`
///     declaration (`class X impl I`, `extend X impl I`) and recorded
///     under it for EmitPlan (visit_decl). A generic declared conformance
///     is one row over the declaring decl's own parameters, and a concrete
///     row it covers says so (_covering). The impl-only rule and extension
///     visibility are this pass's too and are not built yet: a declared row
///     that does not hold is not reported.
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
import Sema::Type::Conversion::*;
import Sema::Check::ClassLifecycle::*;
import AST::Context::DeclContext::*;
import AST::Context::SymbolTable::*;
import AST::Context::TranslationUnit::*;
import AST::Context::ASTContext::*;
import AST::Context::GlobalDisambigTable::*;
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
    /// Parallel to `types`: where each was found, the hop note's place.
    pub var type_at: vec::<SourceRange>;
    fn _NestedUses(self) { }

    fn visit_expr(self, e: *Expr) -> bool {
        if (e == &null) || e->is_poisoned() { return true; }
        if (e->type_ != &null) && e->type_->is_dependent() {
            self.types.push_back(e->type_);
            self.type_at.push_back(e->range);
        }
        if e->kind != ExprKind::CallExpr { return true; }
        var c = cast::<CallExpr>(e);
        if c->dep_args.size() > 0 { self.calls.push_back(c); }
        return true;
    }

    fn visit_type(self, t: *Type) -> bool {
        if (t != &null) && t->is_dependent() {
            self.types.push_back(t);
            self.type_at.push_back(t->range);
        }
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
        self._indexed = true;
        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); ++i {
            var item = *(items->get(i));
            switch item.get_kind() {
                case TopLevelKind::Decl { self.dyn()->dispatch_decl(item.as_decl()); }
                case TopLevelKind::Stmt { self.dyn()->dispatch_stmt(item.as_stmt()); }
                case TopLevelKind::Expr { self.dyn()->dispatch_expr(item.as_expr()); }
            }
        }
        for var i: usize = 0; i < self._rangeless.size(); ++i { self._check_instance(self._rangeless[i], self._rangeless_at[i]); }
        // What the instances this TU uses reach, to the fixpoint: their
        // nonconformance is this TU's to report, beside its own.
        self.discover();
    }

    fn visit_expr(self, e: *Expr) -> bool {
        if (e == &null) || e->is_poisoned() { return true; }
        if e->range.start.is_valid() { self._cur_at = e->range; }
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
        if (t != &null) && t->range.start.is_valid() { self._cur_at = t->range; }
        if t != &null { self._check_type(t, t->range, 0); }
        return true;
    }

    fn visit_decl(self, d: *Decl) -> bool {
        if (d == &null) || d->is_poisoned() { return true; }
        if d->range.start.is_valid() { self._cur_at = d->range; }
        if isa::<ClassDecl>(d) {
            var cd = cast::<ClassDecl>(d);
            for var i: usize = 0; i < cd->implements.size(); ++i { self._check_declared(d, self._self_type(d), cd->implements.get(i)->base); }
        } else if isa::<StructDecl>(d) {
            var sd = cast::<StructDecl>(d);
            for var i: usize = 0; i < sd->implements.size(); ++i { self._check_declared(d, self._self_type(d), sd->implements.get(i)->base); }
        } else if isa::<ExtensionDecl>(d) {
            var x = cast::<ExtensionDecl>(d);
            var t = (self._canon(x->target)) if (x->target != &null) else (&null);
            for var i: usize = 0; i < x->implements.size(); ++i { self._check_declared(d, t, x->implements.get(i)->base); }
        }
        return true;
    }

    /// The type a record declares for itself: `R`, or `R<T, U>` over its
    /// own parameters for a generic one (TypeResolve's `_self_record`).
    /// Null for a record nested in a generic: its witness would be a member
    /// of a template, which a partial specialization cannot key on.
    priv fn _self_type(self, d: *Decl) -> *Type {
        var rep = NameLookup::representative(d);
        var dc0 = reinterpret_cast::<*DeclContext>(d->semantic_dc);
        var o = (dc0->owner_decl()) if (dc0 != &null) else (&null);
        for var depth: u32 = 0; (o != &null) && (depth < 32); ++depth {
            if decl_generic_params(o).size() > 0 { return &null; }
            var dc = reinterpret_cast::<*DeclContext>(o->semantic_dc);
            o = (dc->owner_decl()) if (dc != &null) else (&null);
        }
        var gps = decl_generic_params(rep);
        var args = vec::<*Type>();
        for var i: usize = 0; i < gps.size(); ++i {
            if gps[i] == &null { continue; }
            args.push_back(self.sc->types->generic_param(rep, gps[i]->index, gps[i]->is_pack));
        }
        return self.sc->types->record(rep, &args);
    }

    /// A DECLARED conformance of \p x to \p base, written on \p by: its
    /// row, recorded so EmitPlan can admit the witness specialization where
    /// \p by is emitted, with no Kairo instance to reach it -- a C++ host
    /// instantiating a bounded template with X is the use Kairo never sees
    /// (CODEGEN.md §7b.6). A GENERIC conformance (`extend <E> Wrap<E> impl
    /// I`, `class <T> Box impl I`) is one row over \p by's own parameters,
    /// the partial specialization's. A row that does not hold is left
    /// unreported: the impl-only rule is not built, and a host's
    /// instantiation then fails at the concept, as a structural one does.
    priv fn _check_declared(self, by: *Decl, x: *Type, base: *Type) {
        if (x == &null) || (base == &null) { return; }
        var c = self._canon(x);
        var iface = self._canon(base);
        if (c == &null) || (iface == &null) { return; }
        if self._iface_decl(iface) == &null { return; }
        // Dependent on anything but \p by's own parameters (an enclosing
        // generic's), it is not one partial specialization.
        if (c->is_dependent() || iface->is_dependent()) && (!isa::<RecordType>(c)) { return; }
        var row = self.conforms(c, iface, by);
        if (row == &null) || (!row->ok) { return; }
        self.sc->instances->declare_row(by, row);
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

    /// The last range the visitor passed: where a use with no range of its
    /// own (a canonical reached without a written node) is checked when no
    /// written use of the instance follows, instead of not at all (D4).
    priv var _cur_at: SourceRange = SourceRange::invalid();
    /// Roots whose chain already reported the depth limit: one error per
    /// use, however many branches of its chain run past it.
    priv var _too_deep: vec::<*InstanceEntry>;
    priv var _indexed: bool = false;
    /// Instances first met with no range, and the range the visitor was
    /// under: checked there if no written use came by the end of the TU.
    priv var _rangeless:    vec::<*InstanceEntry>;
    priv var _rangeless_at: vec::<SourceRange>;

    /// \p e is used at \p site: a root of the discovery fixpoint. Its bounds
    /// are checked here, once for the build -- a non-conforming instance is
    /// reported at its first use, however many times it is named -- and
    /// what its body reaches is walked by discover.
    priv fn _check_instance(self, e: *InstanceEntry, site: SourceRange) {
        if e == &null { return; }
        if e->depth > 0 { self._recheck(e, site); return; }
        if !site.start.is_valid() {
            // A written use usually follows (`var b = Box<M>(...)` visits the
            // decl's inferred type before its initializer): wait for it, and
            // fall back to the enclosing range at the end of the TU (run).
            if self._cur_at.start.is_valid() {
                self._rangeless.push_back(e);
                self._rangeless_at.push_back(self._cur_at);
            }
            return;
        }
        if !self.sc->instances->mark_live(e, site, &null, SourceRange::invalid()) { return; }
        self._check_bounds(e);
    }

    /// Fill live \p e's rows from its primary's `impl` bounds, reporting at
    /// its use (InstanceEntry::use_at, a reached one's root's) a bound its
    /// argument does not meet. False when one did not: such an instance's
    /// body is not walked (it is marked walked here). The rows found are
    /// unioned into the instance's program-wide list (add_rows, D7).
    priv fn _check_bounds(self, e: *InstanceEntry) -> bool {
        var rows = vec::<*ConformanceRow>();
        var ok = self._bound_rows(e, e->use_at, e, &rows);
        if !ok {
            rows.clear();
            self.sc->instances->set_checked(e);
            self.sc->instances->mark_failed(e);
        }
        self.sc->instances->add_rows(e, &rows);
        if ok { self._check_facts(e); }
        return ok;
    }

    /// Instances another TU (or an earlier use here) made live, already
    /// checked once for the build, that THIS TU uses directly: their bounds
    /// asked again against what this TU can see (MONO.md D7, the per-TU
    /// filter), reported at this use with no chain -- it is a root here.
    /// Once per instance per TU. Not for an instance that failed where it
    /// became live (reported there, D6), and not for a reached one: a
    /// reached instance's rows are implied by its root's bounds, which its
    /// root's own use checks here.
    priv var _rechecked: vec::<*InstanceEntry>;
    priv fn _recheck(self, e: *InstanceEntry, site: SourceRange) {
        if e->failed { return; }
        var at = site;
        if !at.start.is_valid() { at = self._cur_at; }
        if !at.start.is_valid() { return; }
        for var i: usize = 0; i < self._rechecked.size(); ++i { if self._rechecked[i] == e { return; } }
        self._rechecked.push_back(e);
        var rows = vec::<*ConformanceRow>();
        if self._bound_rows(e, at, &null, &rows) { self.sc->instances->add_rows(e, &rows); }
    }

    /// \p e's rows from its primary's `impl` bounds as this TU sees them,
    /// appended to \p rows; a bound not met is reported at \p at, with
    /// \p chain's instantiation chain when non-null. False when one was not.
    priv fn _bound_rows(self, e: *InstanceEntry, at: SourceRange, chain: *InstanceEntry,
                        rows: *vec::<*ConformanceRow>) -> bool {
        var prim = e->primary;
        var ok = true;
        if prim != &null {
            var req = decl_requires_clause(prim);
            var bounds = vec::<*ConstraintExpr>();
            self._impl_bounds(req, &bounds);
            for var i: usize = 0; i < bounds.size(); ++i {
                var b = bounds[i];
                var gp = self._param_named(b, prim);
                if (gp == &null) || gp->is_pack { continue; }
                var x = self._arg_of(e, prim, gp);
                var iface = self._bound_iface(b, prim, e);
                if (x == &null) || (iface == &null) { continue; }
                var row = self.conforms(x, iface);
                if (row == &null) || (!row->ok) {
                    self._report(at, b, x, iface, row, chain);
                    ok = false;
                    continue;
                }
                if !self._push_closure(row, x, rows, at, b) { ok = false; }
            }
        }
        return ok;
    }

    /// Live record instance \p e's lifecycle (MONO.md G6): a rule its
    /// generic class's declaration could not decide (an Unknown fact) that
    /// the instance's own facts fail, reported at its use with its chain
    /// (D6). Once per build, with the bounds; a failure the declaration
    /// shows is the declaration's, never repeated here (instance_failures).
    priv fn _check_facts(self, e: *InstanceEntry) {
        if (e == &null) || (e->primary == &null) || isa::<FunctionDecl>(e->primary) { return; }
        if !e->use_at.start.is_valid() { return; }
        var fails = vec::<LifecycleFailure>();
        lifecycle_of(self.sc)->instance_failures(e, &fails);
        for var i: usize = 0; i < fails.size(); ++i {
            var x = &(fails[i]);
            var b = self.sc->diag->report(x->id, e->use_at.start, x->msg);
            b.first(e->use_at, f"'{self._inst_name(e)}' is instantiated here");
            for var k: usize = 0; k < x->note_ids.size(); ++k {
                b.note(x->note_ids[k], x->note_at[k].start, x->note_msg[k]).first(x->note_at[k]);
            }
            self.chain_notes(&b, e);
            b.emit();
        }
    }

    /// THE discovery fixpoint (MONO.md D4): walk every live instance's reach,
    /// a batch at a time in worklist (mint) order, until a walk makes nothing
    /// new live. Run at the end of each TU's checks, and again by M1, where
    /// it finds the worklist empty unless something after the checks made an
    /// instance live. A chain longer than --cmax-generic-depth is an error
    /// (_too_deep), never a silent stop.
    fn discover(self) {
        var reg = self.sc->instances;
        if reg == &null { return; }
        var batch = vec::<*InstanceEntry>();
        reg->drain(&batch);
        // M1's pass is a fresh one: a row's member lookup needs the
        // extension index run() builds.
        if (batch.size() > 0) && (!self._indexed) {
            self.ml.index_extensions();
            self._indexed = true;
        }
        while batch.size() > 0 {
            for var i: usize = 0; i < batch.size(); ++i {
                reg->set_checked(batch[i]);
                self._walk(batch[i]);
            }
            batch.clear();
            reg->drain(&batch);
        }
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

    /// Walk live \p e's primary's body (a record's: its methods, and its
    /// fields' types) for the dependent uses that become instances
    /// under \p e's arguments. Each is minted, linked (InstanceEntry::reached:
    /// every plan holding \p e homes or `extern`s it, and admits its rows,
    /// CODEGEN.md §7b.6) and made live one hop below \p e, which checks its
    /// bounds; its own reach is the worklist's next batch. The cycle state
    /// is the entry's (`checked`), never the decl's: every function instance
    /// shares its primary's decl.
    priv fn _walk(self, e: *InstanceEntry) {
        var prim = e->primary;
        if prim == &null { return; }
        var uses = _NestedUses();
        if isa::<FunctionDecl>(prim) {
            uses.dispatch_decl(prim);
        } else {
            var ms = self._methods_of(prim);
            for var i: usize = 0; i < ms.size(); ++i { if ms[i] != &null { uses.dispatch_decl(static_cast::<*Decl>(ms[i])); } }
            // The fields' types are instantiated with the record (C++ checks a
            // constrained template's bounds even where it is only named, as
            // behind a pointer), and a field is no method's use.
            var fs = self._fields_of(prim);
            for var i: usize = 0; i < fs.size(); ++i {
                var f = fs[i];
                if (f == &null) || (f->type_ == &null) { continue; }
                var ft = self._canon(f->type_);
                if (ft == &null) || (!ft->is_dependent()) { continue; }
                uses.types.push_back(f->type_);
                uses.type_at.push_back(f->range);
            }
        }
        if (uses.calls.size() == 0) && (uses.types.size() == 0) { return; }

        var d = Deduction(self.sc, &null);
        self._bind_instance(&d, e, prim);
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
            if e->depth >= self._depth_limit() {
                var have = self.sc->instances->find(rep, &args);
                if (have == &null) || (have->depth == 0) {
                    self._too_deep_at(e, self._spell(rep, &args), c->range);
                    return;
                }
            }
            var ne = self.sc->instances->instance_for(rep, &args, self.sc->ctx->fid, NameLookup::ctx_of(rep));
            if ne == &null { continue; }
            self.sc->instances->add_reach(e, ne);
            // Its failure is reported at the root use, the hop notes saying
            // which body asked for it (chain_notes).
            if self.sc->instances->mark_live(ne, SourceRange::invalid(), e, c->range) { self._check_bounds(ne); }
        }
        for var i: usize = 0; i < uses.types.size(); ++i {
            var s = d.substitute(self._canon(uses.types[i]));
            if (s == &null) || s->is_dependent() { continue; }
            var at = uses.type_at[i];
            if !at.start.is_valid() { at = e->use_at; }
            if !self._take_type(e, s, at, 0) { return; }
        }
    }

    /// Every record instance in substituted type \p t, as _check_type finds
    /// them, each linked as reached by \p outer and made live below it at
    /// \p at. False when the chain ran past the depth limit (reported).
    priv fn _take_type(self, outer: *InstanceEntry, t: *Type, at: SourceRange, depth: u32) -> bool {
        var c = self._canon(t);
        if (c == &null) || (depth > 16) { return true; }
        switch c->kind {
            case TypeKind::PointerType      { return self._take_type(outer, cast::<PointerType>(c)->pointee, at, depth + 1); }
            case TypeKind::CXXLValueRefType { return self._take_type(outer, cast::<CXXLValueRefType>(c)->referee, at, depth + 1); }
            case TypeKind::CXXRValueRefType { return self._take_type(outer, cast::<CXXRValueRefType>(c)->referee, at, depth + 1); }
            case TypeKind::NullableType     { return self._take_type(outer, cast::<NullableType>(c)->inner, at, depth + 1); }
            case TypeKind::FixedArrayType   { return self._take_type(outer, cast::<FixedArrayType>(c)->element, at, depth + 1); }
            case TypeKind::RecordType {
                var r = cast::<RecordType>(c);
                for var i: usize = 0; i < r->args.size(); ++i { if !self._take_type(outer, r->args[i], at, depth + 1) { return false; } }
                if (r->decl == &null) || (!decl_is_instance(r->decl)) { return true; }
                var ne = self.sc->instances->entry_of(r->decl);
                if ne == &null { return true; }
                self.sc->instances->add_reach(outer, ne);
                if ne->depth > 0 { return true; }
                if outer->depth >= self._depth_limit() {
                    self._too_deep_at(outer, self.tu.str(c), at);
                    return false;
                }
                if self.sc->instances->mark_live(ne, SourceRange::invalid(), outer, at) { self._check_bounds(ne); }
                return true;
            }
            default { return true; }
        }
        return true;
    }

    priv fn _depth_limit(self) -> u32 {
        var lim = self.sc->opts.max_generic_depth;
        if lim < 1 { lim = 1; }
        return static_cast::<u32>(lim);
    }

    /// Live \p e, at the depth limit, needs \p next at \p at in its body: the
    /// chain is too long (D4). One error per root, at the root's use, naming
    /// the chain's first three and last three instances.
    priv fn _too_deep_at(self, e: *InstanceEntry, next: string, at: SourceRange) {
        var chain = vec::<*InstanceEntry>();
        var r = e;
        while r != &null { chain.push_back(r); r = r->via; }
        var root = chain[chain.size() - 1];
        for var i: usize = 0; i < self._too_deep.size(); ++i { if self._too_deep[i] == root { return; } }
        self._too_deep.push_back(root);
        var names = vec::<string>();
        for var i: usize = chain.size(); i > 0; --i { names.push_back(self._inst_name(chain[i - 1])); }
        names.push_back(next);
        var n = names.size();
        var shown = "";
        for var i: usize = 0; i < n; ++i {
            if (n > 6) && (i >= 3) && (i + 3 < n) {
                if i == 3 { shown += " -> ..."; }
                continue;
            }
            if i > 0 { shown += " -> "; }
            shown += "\x27" + names[i] + "\x27";
        }
        var lim = self._depth_limit();
        var b = self.sc->diag->report(DiagID::SC001E, e->use_at.start,
            f"instantiation depth exceeds {lim}: {shown}");
        b.first(e->use_at, "the chain starts here");
        if at.start.is_valid() { b.note(at.start, f"'{next}' is required here, instantiation {lim + 1} of the chain").first(at); }
        b.note("the limit is set by --cmax-generic-depth");
        b.emit();
    }

    /// The instantiation chain of reached instance \p e, on \p b, an error
    /// reported at its root's use (MONO.md D6): one note per hop, innermost
    /// first, "in instantiation of 'X<A>' required here" at the use in the
    /// body that needed X<A>. Past N = --cmax-generic-backtrace hops
    /// (default 5: the first 3 and the last 2) the first ceil(N/2) and the
    /// last floor(N/2) are shown, with a note counting the rest. Each hop is one instance (the chain is the `via`
    /// links, acyclic), and an instance's failure is reported once, at the
    /// first use that needed it, so a second use of a failing instance adds
    /// nothing. Nothing for a root (\p e used directly). Public: a fact that
    /// fails for an instance (G6's lifecycle) reports at `use_at` with this.
    fn chain_notes(self, b: *DiagBuilder, e: *InstanceEntry) {
        var hops = vec::<*InstanceEntry>();
        var h = e;
        while (h != &null) && (h->via != &null) { hops.push_back(h); h = h->via; }
        var n = hops.size();
        if n == 0 { return; }
        var cap = n;
        if self.sc->opts.max_generic_backtrace > 0 { cap = static_cast::<usize>(self.sc->opts.max_generic_backtrace); }
        var head = n;
        var tail: usize = 0;
        if n > cap {
            head = (cap + 1) / 2;
            tail = cap / 2;
        }
        for var i: usize = 0; i < n; ++i {
            if (i >= head) && (i + tail < n) {
                if i == head {
                    var more = n - head - tail;
                    b->note(f"{more} more instantiations in the chain; --cmax-generic-backtrace=0 shows them all");
                }
                continue;
            }
            var hp = hops[i];
            if !hp->via_at.start.is_valid() { continue; }
            b->note(hp->via_at.start, f"in instantiation of '{self._inst_name(hp)}' required here").first(hp->via_at);
        }
    }

    /// \p e as the user reads it: `Wrap<Metric>`, `inner<Wrap<Metric>>`.
    priv fn _inst_name(self, e: *InstanceEntry) -> string {
        if (e->decl != &null) && (!isa::<FunctionDecl>(e->primary)) {
            var t = self.sc->types->record(e->decl, &(e->args));
            if t != &null { return self.tu.str(t); }
        }
        return self._spell(e->primary, &(e->args));
    }

    priv fn _spell(self, prim: *Decl, args: *vec::<*Type>) -> string {
        var s = self.tu.decl_name(prim);
        s += "<";
        for var i: usize = 0; i < args->size(); ++i {
            if i > 0 { s += ", "; }
            s += self.tu.str((*args)[i]);
        }
        s += ">";
        return s;
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

    priv fn _fields_of(self, d: *Decl) -> FrozenList::<*FieldDecl> {
        if isa::<ClassDecl>(d)  { return cast::<ClassDecl>(d)->fields; }
        if isa::<StructDecl>(d) { return cast::<StructDecl>(d)->fields; }
        if isa::<UnionDecl>(d)  { return cast::<UnionDecl>(d)->fields; }
        return create_empty_frozen_list::<*FieldDecl>();
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
    ///
    /// \p declared is the `impl` that declares it, for a GENERIC row (\p x
    /// over that decl's own parameters): the row is born with it, since
    /// codegen spells the partial specialization's head from it.
    ///
    /// Per TU (MONO.md D7): the table's row only where this TU can use it
    /// (_usable). Otherwise the match runs again over what this TU sees, and
    /// its result is DETACHED, never the table's: not ok with
    /// ConformanceRow::hidden naming the member this TU cannot see, or, when
    /// it found a different implementation this TU can see, not ok with
    /// `clash` -- one conformance cannot have two (every TU's C++ carries
    /// the same witness). A row that is not ok is never recorded either: it
    /// was one TU's view (or one moment's: the extension index skips a TU
    /// whose types have not been resolved yet), not a fact of the program.
    fn conforms(self, x: *Type, iface: *Type, declared: *Decl = &null) -> *ConformanceRow {
        var hit = self.sc->instances->row_find(x, iface);
        if (hit != &null) && self._usable(hit) { return hit; }
        var idecl = self._iface_decl(iface);
        if idecl == &null { return &null; }
        self._hidden = &null;

        var row = ConformanceRow();
        row.conformer  = x;
        row.iface      = iface;
        row.iface_decl = static_cast::<*Decl>(idecl);
        row.declared   = declared;
        row.ok         = true;
        // Parallel to the interface's composed requirement list. An
        // associated type's witness is the conformer's alias (or, for a
        // default, the requirement itself) and its type goes in
        // `assoc_types`; one the conformer does not supply fails the row.
        var decls = vec::<*Decl>();
        var srcs  = vec::<*Type>();
        self._reqs(idecl, iface, &decls, &srcs);
        for var i: usize = 0; i < decls.size(); ++i {
            var m = dyn_cast::<FunctionDecl>(decls[i]);
            var w: *Decl = &null;
            var ea = vec::<*Type>();
            var at: *Type = &null;
            var ta = dyn_cast::<TypeAliasDecl>(decls[i]);
            if ta != &null {
                w = self._assoc_implementation(x, iface, ta, &at);
                // The supplied type must meet the associated type's own
                // bounds (`type Item impl Display`).
                if (w != &null) && (at != &null) && (!self._assoc_bounds_met(at, ta, x)) { w = &null; }
                if w == &null { row.ok = false; }
            }
            if m != &null {
                var k = self._iface_decl(srcs[i]);
                w = self._implementation(x, srcs[i], k, m);
                // A constructor slot's witness may be the record itself (its
                // implicit default constructor), which has no extension.
                var wf = dyn_cast::<FunctionDecl>(w);
                if (w == &null) || ((wf != &null) && (!self._ext_args(wf, x, &ea))) { row.ok = false; }
            }
            row.witnesses.push_back(w);
            row.reqs.push_back(decls[i]);
            row.sources.push_back(srcs[i]);
            row.assoc_types.push_back(at);
            row.ext_arg_count.push_back(ea.size());
            for var k2: usize = 0; k2 < ea.size(); ++k2 { row.ext_args.push_back(ea[k2]); }
        }
        row.hidden = self._hidden;
        if hit != &null {
            if row.ok {
                row.ok    = false;
                row.clash = hit;
            }
            return self.sc->instances->row_detached(&row);
        }
        if !row.ok { return self.sc->instances->row_detached(&row); }
        row.covered_by = self._covering(x, iface, &row);
        row.seen_by.push_back(self.sc->ctx->fid);
        return self.sc->instances->row_add(&row);
    }

    // --- visibility (the extension-visibility rule, per TU) ------------------------

    /// The member _implementation skipped last because this TU cannot see
    /// it, though it matched: why a detached row is not ok.
    priv var _hidden: *Decl = &null;
    /// This TU's fid, the builtin subtree's, and every fid its imports
    /// reach, transitively: what its checks may use an extension from.
    /// Built on first need.
    priv var _visible:       vec::<u32>;
    priv var _visible_built: bool = false;

    /// Table row \p row is usable in this TU: each implementing decl that is
    /// an extension member is in this TU's transitive import set (an own
    /// member is visible wherever its type is). Remembered on the row
    /// (seen_by), so a second ask is one lookup.
    priv fn _usable(self, row: *ConformanceRow) -> bool {
        var fid = self.sc->ctx->fid;
        if self.sc->instances->row_visible_in(row, fid) { return true; }
        for var i: usize = 0; i < row->witnesses.size(); ++i {
            var w = row->witnesses[i];
            if (w != &null) && (!self._sees(w)) { return false; }
        }
        self.sc->instances->row_mark_visible(row, fid);
        return true;
    }

    /// \p d may implement a requirement here: not an extension member, or
    /// one in a file this TU (transitively) imports.
    priv fn _sees(self, d: *Decl) -> bool {
        if decl_extension_of(d) == &null { return true; }
        var fid = self.tu.fid_of(d);
        if fid == self.sc->ctx->fid { return true; }
        if (self.sc->g != &null) && self.sc->g->is_builtin_fid(fid) { return true; }
        if !self._visible_built { self._build_visible(); }
        for var i: usize = 0; i < self._visible.size(); ++i { if self._visible[i] == fid { return true; } }
        return false;
    }

    priv fn _build_visible(self) {
        self._visible_built = true;
        var root = self.sc->tu;
        if root == &null { return; }
        self._visible.push_back(self.sc->ctx->fid);
        var work = vec::<*TranslationUnit>();
        work.push_back(root);
        while work.size() > 0 {
            var t = work[work.size() - 1];
            work.pop_back();
            for var i: usize = 0; i < t->import_edges.size(); ++i {
                var ed = t->import_edges.get(i);
                if ed == &null { continue; }
                var f = ed->target_fid;
                if (f == 0) || (f == u32(-1)) { continue; }   // ffi or unresolved: no Kairo extension behind it.
                var have = false;
                for var k: usize = 0; k < self._visible.size(); ++k { if self._visible[k] == f { have = true; break; } }
                if have { continue; }
                self._visible.push_back(f);
                if self.sc->g == &null { continue; }
                var c = self.sc->g->get_context(f);
                if c == &null { continue; }
                var ot = reinterpret_cast::<*TranslationUnit>(c->tu);
                if ot != &null { work.push_back(ot); }
            }
        }
    }

    /// The GENERIC declared row that covers concrete \p row of instance \p x:
    /// declared on x's pattern (`class <T> Box impl I`) or by a generic
    /// extension of it (`extend <E> Wrap<E> impl I`), its conformer and
    /// interface at x's arguments \p x and \p iface, and its witnesses
    /// \p row's. Then its partial specialization is \p row's witness, and a
    /// full one would only repeat it. Null otherwise: a non-instance, an
    /// explicit specialization's own members, a conformance only structural.
    priv fn _covering(self, x: *Type, iface: *Type, row: *ConformanceRow) -> *ConformanceRow {
        if (!isa::<RecordType>(x)) || x->is_dependent() { return &null; }
        var xd = cast::<RecordType>(x)->decl;
        if (xd == &null) || (!decl_is_instance(xd)) { return &null; }
        var pat = NameLookup::representative(self.sc->body_of(xd));   // a selected partial's `impl` list.
        if pat == &null { return &null; }
        if isa::<ClassDecl>(pat) {
            var cd = cast::<ClassDecl>(pat);
            for var i: usize = 0; i < cd->implements.size(); ++i {
                var g = self._covers(pat, self._self_type(pat), cd->implements.get(i)->base, x, iface, row);
                if g != &null { return g; }
            }
        } else if isa::<StructDecl>(pat) {
            var sd = cast::<StructDecl>(pat);
            for var i: usize = 0; i < sd->implements.size(); ++i {
                var g = self._covers(pat, self._self_type(pat), sd->implements.get(i)->base, x, iface, row);
                if g != &null { return g; }
            }
        }
        var exts = self.ml.extensions_of_decl(pat);
        if exts == &null { exts = self.ml.extensions_of_decl(self.tu.pattern_of(xd)); }
        if exts == &null { return &null; }
        for var i: usize = 0; i < exts->size(); ++i {
            var e = (*exts)[i];
            if (e == &null) || e->is_poisoned() || (e->target == &null) { continue; }
            if decl_generic_params(static_cast::<*Decl>(e)).size() == 0 { continue; }
            for var k: usize = 0; k < e->implements.size(); ++k {
                var g = self._covers(static_cast::<*Decl>(e), self._canon(e->target), e->implements.get(k)->base, x, iface, row);
                if g != &null { return g; }
            }
        }
        return &null;
    }

    /// _covering for one `impl` edge \p base of \p by, whose conformer is
    /// \p gx: its generic row when that covers \p row, else null.
    priv fn _covers(self, by: *Decl, gx: *Type, base: *Type, x: *Type, iface: *Type, row: *ConformanceRow) -> *ConformanceRow {
        if (gx == &null) || (base == &null) || (!gx->is_dependent()) { return &null; }
        var bi = self._canon(base);
        if (bi == &null) || (static_cast::<*Decl>(self._iface_decl(bi)) != row->iface_decl) { return &null; }
        var d = Deduction(self.sc, &null);
        if d.unify(gx, x, false) == ImplicitRank::None { return &null; }
        var at = d.substitute(bi);
        if (at == &null) || (canon_unqual(at) != iface) { return &null; }
        // The table's generic row whoever can see it: coverage decides which
        // C++ specialization is THE witness, a program-wide fact (D7), not a
        // per-TU one.
        var g = self.sc->instances->row_find(gx, bi);
        if g == &null { g = self.conforms(gx, bi, by); }
        if (g == &null) || (!g->ok) || (g->witnesses.size() != row->witnesses.size()) { return &null; }
        for var i: usize = 0; i < g->witnesses.size(); ++i {
            if self._entity(g->witnesses[i]) != self._entity(row->witnesses[i]) { return &null; }
        }
        return g;
    }

    /// \p d as one entity across a pattern and its instances: a constructor
    /// slot's witness is the record, `Wrap` in a generic row and `Wrap<i32>`
    /// in a concrete one.
    priv fn _entity(self, d: *Decl) -> *Decl {
        if d == &null { return &null; }
        return NameLookup::representative(self.tu.pattern_of(d));
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
        // A GENERIC row's conformer is dependent (`Wrap<E>`), which
        // bind_from_extension declines; unified directly, the extension's
        // parameters bind to the row's own (E := E), which the partial
        // specialization then spells by name.
        var dep = x->is_dependent();
        if dep {
            if (ext->target == &null) || (ext->target->canonical == &null) { return false; }
            if d.unify(canon_unqual(ext->target->canonical), canon_unqual(x), false) == ImplicitRank::None { return false; }
        } else if !d.bind_from_extension(f, x) { return false; }
        for var i: usize = 0; i < eps.size(); ++i {
            var gp = eps[i];
            if gp == &null { return false; }
            var b = d.lookup(NameLookup::representative(static_cast::<*Decl>(ext)), gp->index);
            if b == &null { b = d.lookup(static_cast::<*Decl>(ext), gp->index); }
            if (b == &null) || (b->is_dependent() && (!dep)) { return false; }
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
            if !self._signature_matches(f, m, x, iface, idecl) { continue; }
            // An extension this TU does not import implements nothing here
            // (the extension-visibility rule); kept for the diagnostic.
            if !self._sees(static_cast::<*Decl>(f)) {
                if self._hidden == &null { self._hidden = NameLookup::representative(static_cast::<*Decl>(f)); }
                continue;
            }
            return NameLookup::representative(static_cast::<*Decl>(f));
        }
        return &null;
    }

    /// What supplies associated-type requirement \p ta of \p iface on
    /// \p x: \p x's alias of that name, or \p ta itself when an explicit
    /// conformance takes its default; null when nothing does (structural
    /// conformance never takes a default). The type goes in \p out --
    /// Substitution::assoc_witness's answer, the same one every use reads.
    /// A dependent \p x (a generic row's `Wrap<E>`) reads its alias through
    /// E, which the partial specialization spells. A generic associated
    /// type is not checked: its uses are SC116E.
    priv fn _assoc_implementation(self, x: *Type, iface: *Type, ta: *TypeAliasDecl, out: *(*Type)) -> *Decl {
        if ta->generic_params.size() > 0 { return static_cast::<*Decl>(ta); }
        var d = Deduction(self.sc, &null);
        var t = d.assoc_witness(x, iface, static_cast::<*Decl>(ta));
        if (t == &null) || isa::<AssocType>(canon_unqual(t)) { return &null; }
        (*out) = t;
        // The alias, when x declares one (a default has none): codegen
        // spells the type either way, the decl is for the report's note.
        var cands = vec::<*Decl>();
        var imms = self.sc->ctx->get_imm_table();
        self.ml.lookup(x, DeclName::ident(imms->intern_ident_copy(self.tu.decl_name(static_cast::<*Decl>(ta)))), &cands);
        for var i: usize = 0; i < cands.size(); ++i {
            var a = dyn_cast::<TypeAliasDecl>(cands[i]);
            if (a != &null) && (!a->is_associated) { return NameLookup::representative(cands[i]); }
        }
        return static_cast::<*Decl>(ta);
    }

    /// \p t, supplied for associated type \p ta by conformer \p x, meets
    /// every `impl` bound \p ta declares, `Self` in a bound read as \p x.
    /// A bound still dependent after that is not checked here.
    priv fn _assoc_bounds_met(self, t: *Type, ta: *TypeAliasDecl, x: *Type) -> bool {
        var cs = vec::<*ConstraintExpr>();
        self._impl_bounds(ta->requires_clause, &cs);
        var home: *Decl = &null;
        if ta->semantic_dc != &null { home = reinterpret_cast::<*DeclContext>(ta->semantic_dc)->owner_decl(); }
        for var i: usize = 0; i < cs.size(); ++i {
            var c = cs[i];
            if (c->rhs == &null) || (c->rhs->canonical == &null) { continue; }
            var bt = canon_unqual(c->rhs->canonical);
            if bt->is_dependent() && (home != &null) {
                var d = Deduction(self.sc, &null);
                bt = canon_unqual(d.replace_self(bt, NameLookup::representative(home), x, true));
            }
            if bt->is_dependent() { continue; }
            var r = self.conforms(canon_unqual(t), bt);
            if (r != &null) && (!r->ok) { return false; }
        }
        return true;
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
        var dc = NameLookup::context_of(self.sc->body_of(d));   // an unfilled instance has an empty table; its body's.
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
        // A member of a generic record (`class <T> Holder { fn first() ->
        // T }`) reached through an instance reads T at its argument, as a
        // call on that instance does.
        if (decl_extension_of(static_cast::<*Decl>(f)) == &null) && isa::<RecordType>(canon_unqual(x)) { d.bind_from_record(canon_unqual(x)); }
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

    /// \p e, when given, is the instance whose bound failed: a reached one
    /// gets its instantiation chain (chain_notes).
    priv fn _report(self, at: SourceRange, b: *ConstraintExpr, x: *Type, iface: *Type, row: *ConformanceRow,
                    e: *InstanceEntry = &null) {
        var xs = self.tu.str(x);
        var is = self.tu.str(iface);
        var missing = "";
        var req: *FunctionDecl = &null;
        var areq: *TypeAliasDecl = &null;
        if row != &null {
            var decls = vec::<*Decl>();
            var srcs  = vec::<*Type>();
            self._reqs(cast::<InterfaceDecl>(row->iface_decl), row->iface, &decls, &srcs);
            // A missing associated type first: every requirement that names
            // it then fails too, and only it says why.
            for var i: usize = 0; (i < row->witnesses.size()) && (i < decls.size()); ++i {
                if row->witnesses[i] != &null { continue; }
                var ta = dyn_cast::<TypeAliasDecl>(decls[i]);
                if ta != &null { areq = ta; break; }
            }
            for var i: usize = 0; (areq == &null) && (i < row->witnesses.size()) && (i < decls.size()); ++i {
                if row->witnesses[i] != &null { continue; }
                var f = dyn_cast::<FunctionDecl>(decls[i]);
                if f == &null { continue; }
                req = f;
                missing = self._req_name(req);
                break;
            }
        }
        if (row != &null) && (row->clash != &null) {
            self._report_clash(at, b, xs, is, row, e);
            return;
        }
        if areq != &null {
            var an = self.tu.decl_name(static_cast::<*Decl>(areq));
            var dd = Deduction(self.sc, &null);
            var sup = dd.assoc_witness(x, row->iface, static_cast::<*Decl>(areq));
            if (sup != &null) && (!isa::<AssocType>(canon_unqual(sup))) {
                // Supplied, but not meeting the associated type's own bounds.
                var ss = self.tu.str(sup);
                var bd = self.sc->diag->report(DiagID::SC001E, at.start,
                    f"'{xs}' does not conform to '{is}': its associated type '{an}' is '{ss}', which does not meet the bounds '{an}' declares");
                bd.first(at);
                if b != &null { bd.note(b->range.start, f"required by this bound").first(b->range); }
                bd.note(areq->range.start, f"'{an}' and its bounds are declared here").first(areq->range);
                if e != &null { self.chain_notes(&bd, e); }
                bd.emit();
                return;
            }
            // interfaces.md, Defaults: a structural conformer declares every
            // associated type; only an explicit `impl` takes a default.
            var ad = self.sc->diag->report(DiagID::SC001E, at.start,
                f"'{xs}' does not conform to '{is}': it declares no associated type '{an}\x27");
            ad.first(at);
            if b != &null { ad.note(b->range.start, f"required by this bound").first(b->range); }
            if (areq->aliased != &null) && (row->declared == &null) {
                ad.note(areq->range.start, f"'{an}' has a default, but a default applies only to a type that declares 'impl {is}\x27").first(areq->range);
            } else {
                ad.note(areq->range.start, f"'{an}' is required here").first(areq->range);
            }
            if e != &null { self.chain_notes(&ad, e); }
            ad.emit();
            return;
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
        } else if (missing.size() > 0) && (row->hidden != &null) {
            msg = f"'{xs}' does not conform to '{is}' here: '{missing}' is implemented by an extension this file does not import";
        } else if missing.size() > 0 {
            msg = f"'{xs}' does not conform to '{is}': no member '{missing}' with the requirement's signature";
        }
        var d = self.sc->diag->report(DiagID::SC001E, at.start, msg);
        d.first(at);
        if b != &null { d.note(b->range.start, f"required by this bound").first(b->range); }
        if req != &null { d.note(req->range.start, req_note).first(req->range); }
        if (missing.size() > 0) && (row->hidden != &null) {
            d.note(row->hidden->range.start,
                "this extension member implements it, in a file this one does not import; import its module here to use the conformance"
            ).first(row->hidden->range);
        }
        if e != &null { self.chain_notes(&d, e); }
        d.emit();
    }

    /// Detached \p row found an implementation of (\p xs, \p is) that this
    /// TU sees and that differs from the table's (ConformanceRow::clash):
    /// one conformance with two implementations, which no TU's C++ can hold
    /// both of (one witness specialization per conformance, ODR).
    priv fn _report_clash(self, at: SourceRange, b: *ConstraintExpr, xs: string, is: string,
                          row: *ConformanceRow, e: *InstanceEntry) {
        var other = row->clash;
        var d = self.sc->diag->report(DiagID::SC001E, at.start,
            f"'{xs}' conforms to '{is}' through a different implementation here than elsewhere in the program; a conformance has one implementation");
        d.first(at);
        if b != &null { d.note(b->range.start, f"required by this bound").first(b->range); }
        for var i: usize = 0; (i < row->witnesses.size()) && (i < other->witnesses.size()); ++i {
            var mine   = row->witnesses[i];
            var theirs = other->witnesses[i];
            if (mine == &null) || (theirs == &null) || (self._entity(mine) == self._entity(theirs)) { continue; }
            d.note(mine->range.start, "this implementation is the one visible here").first(mine->range);
            d.note(theirs->range.start, "this one implements it for another file of the program").first(theirs->range);
            break;
        }
        if e != &null { self.chain_notes(&d, e); }
        d.emit();
    }
}
