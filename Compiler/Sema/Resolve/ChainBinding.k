/// --- The Kairo Project ------------------ Sema/Resolve/ChainBinding.k --- ///
///
///   \brief Bind every chain step: `a.b`, `p->x`, `Foo::Bar`, `m::f`.
///
///   \detail
///     N binds the HEAD of a chain (an ordinary unqualified name) and hands
///     every later step through untouched, because a step's meaning depends
///     on what the previous one denotes -- a type's members, a module's
///     table, a value's TYPE's members -- and the value case needs
///     canonicals that only exist after T. This pass runs after T, walks
///     each chain left to right, and binds what is decidable from DECLARED
///     types.
///
///     What is decidable: any step whose left side is a type, a module, or a
///     value with a declared type (param, field, typed var, the synthesized
///     `self` receiver). That is `this->x` in C++ terms, and it is why
///     `self.x` in a method binds to the field here rather than in inference.
///
///     What is NOT: a step after a call (`f().x`), after an inferred `var`
///     (`var a = g(); a.x`), or after an overload set. Those are marked
///     NeedsInference and left with null slots -- NOT poisoned, NOT
///     diagnosed. TypeInference owns them (one writer rule: it promotes
///     candidate cells and fills the rest).
///
///     A step rooted in a GENERIC PARAMETER is decided by that parameter's
///     declaration, not deferred wholesale
///     A bounded `<T impl I>` / `<T derives B>` resolves against the bound's
///     members right here, once, at the template. An unbounded `<T>` has no
///     members at all and says so -- at the template, which is the whole
///     difference from C++. Only a dependent COMPOSITE (`[T]`, an unfilled
///     `Foo<T>::Inner`) is still Dependent for M2 (hard invariant #5).
///
///   \par One error, one home
///     "no member named X", "X is a type, use ::", "'::' after a value",
///     "'.' on a pointer (use ->)", ambiguous non-function members across
///     bases, "T has no members": HERE. Unknown head: N. Bad types: T.
///     Access: AccessCheck. Whether an INSTANTIATION satisfies the bound:
///     ConformanceChecking.
///
///   Phase: RESOLVE (T stage, after TypeResolution)
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sema::SemaContext::*;
import Sema::Check::ConstraintSet::*;
import Sema::Resolve::NameLookup::*;
import Sema::Resolve::MemberLookup::*;
import Sema::Resolve::GenericArgs::*;
import Sema::Resolve::ResolutionTrace::*;
import Sema::Resolve::ResolutionState::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::SymbolTable::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::DeclFacts::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Kind::TypeKind::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Token::Token::*;
import Token::TokenKind::*;
import Diagnostic::Registry::*;
import AST::Context::InstantiationRegistry::*;

__inline_cpp("
#define RecursiveASTVisitor_ChainBinding RecursiveASTVisitor<ChainBinding>
");

/// \enum AnchorKind
/// \brief What the LEFT side of a step denotes.
enum AnchorKind derives u8 {
    Module = 0,      ///< a module/TU scope: `::` steps do plain table lookup.
    Type,            ///< a type: `::` steps do member lookup (statics, nested, variants).
    Value,           ///< a value with a canonical type: `.`/`->` steps do member lookup.
    NeedsInference,  ///< a value whose type is not declared.
    Dependent,       ///< rooted in a generic parameter.
    Errored,         ///< already diagnosed; stay silent.
}

/// \class Anchor
class Anchor {
    pub var kind:  AnchorKind   = AnchorKind::Errored;
    /// Module: every scope the base denotes. More than one when a name is
    /// bound to a module reopened across files -- they are ONE namespace,
    /// so a `::` step searches all of them (IMPORTS.md §4.3).
    pub var scopes: vec::<*DeclContext>;
    pub var decl:  *Decl        = &null;   ///< Type: the record decl. Value: the decl (for notes).
    pub var ty:    *Type        = &null;   ///< Type: its record. Value: the canonical.
    fn Anchor(self) { }
}

class ChainBinding derives RecursiveASTVisitor::<ChainBinding> {
    pub var sc: *SemaContext;
    var ml: MemberLookup;

    pub var n_bound:     usize = 0;
    pub var n_cands:     usize = 0;
    pub var n_inference: usize = 0;
    pub var n_dependent: usize = 0;
    pub var n_errored:   usize = 0;

    priv var _self_imm: u32 = u32(-1);

    /// Default ctor so ChainBinding can be a MEMBER of a pass that builds it
    /// in its own body (ExprTyper holds one). Leaves sc null: every entry
    /// point dereferences it, so a default-constructed binder must be
    /// assigned a real one before use.
    fn ChainBinding(self) { self.sc = &null; }

    fn ChainBinding(self, sc: *SemaContext) {
        self.sc = sc;
        self.ml = MemberLookup(sc);
    }

    /// One-time setup the STEP BINDER needs, split out of run() because
    /// ExprTyper drives bind_step() directly without ever walking the program
    /// here. Idempotent: run() calls it too, and calling it twice costs an
    /// intern hit and a re-index, not correctness.
    fn prepare(self) {
        self._self_imm = self.sc->imm_table()->intern_ident_copy("self");
        self.ml.index_extensions();
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::NamesResolved);
        var tu = self.sc->tu;
        if tu == &null { return; }
        if tu->program == &null { return; }

        self.prepare();

        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); ++i {
            if self.stop { break; }
            var item = *(items->get(i));
            switch item.get_kind() {
                case TopLevelKind::Decl { self.dyn()->dispatch_decl(item.as_decl()); }
                case TopLevelKind::Stmt { self.dyn()->dispatch_stmt(item.as_stmt()); }
                case TopLevelKind::Expr { self.dyn()->dispatch_expr(item.as_expr()); }
            }
        }
    }

    // === The chain =============================================================

    fn traverse_chain_expr(self, n: *ChainExpr) -> *ChainExpr {
        if n == &null { return n; }
        // Base + generic args first (nested chains inside args bind too).
        var out = RecursiveASTVisitor_ChainBinding::traverse_chain_expr(n);

        var a = self._anchor_of_base(n);
        for var i: usize = 0; i < n->steps.size(); ++i {
            var st = n->steps.get(i);
            if st == &null { break; }
            if st->resolved_decl != &null { a = self._anchor_after(st->resolved_decl, st); continue; }   // idempotent re-run.
            a = self._bind_step(n, st, a);
        }
        if a.kind == AnchorKind::Dependent {
            n->expr_flags = static_cast::<Expr::ExprFlags>(
                static_cast::<u8>(n->expr_flags)
              | static_cast::<u8>(Expr::ExprFlags::IsDependent)
              | static_cast::<u8>(Expr::ExprFlags::IsInstantiationDependent));
        }
        return out;
    }

    /// What the base expression denotes, from N's binding + T's canonical.
    priv fn _anchor_of_base(self, n: *ChainExpr) -> Anchor {
        var a = Anchor{};

        if n->base == &null {
            // `::std::x`: global root.
            a.kind = AnchorKind::Module;
            a.scopes.push_back(static_cast::<*DeclContext>(self.sc->tu));
            return a;
        }
        if n->base->is_poisoned() { a.kind = AnchorKind::Errored; return a; }

        if isa::<NamedIdentExpr>(n->base) {
            var id = cast::<NamedIdentExpr>(n->base);
            if id->is_deferred() {
                // A cell of nothing but ModuleDecls is one reopened namespace,
                // not an overload set N failed to collapse: the canonicals are
                // distinct decls but the SCOPE is the union of their tables.
                // Anything else in the cell is a real overload set.
                var cell = id->candidate_cell;
                var all_mod = cell->size() > 0;
                for var i: usize = 0; i < cell->size(); ++i {
                    if !isa::<ModuleDecl>(cell->get(i)) { all_mod = false; break; }
                }
                if !all_mod { a.kind = AnchorKind::NeedsInference; return a; }
                a.kind = AnchorKind::Module;
                // Each candidate's whole ring, deduped (module_scopes skips a
                // scope already pushed): two reopenings of one ring would
                // otherwise contribute it twice.
                for var i: usize = 0; i < cell->size(); ++i {
                    NameLookup::module_scopes(cell->get(i), a.scopes);
                }
                return a;
            }
            
            if !id->is_bound() { // N diagnosed.
                a.kind = AnchorKind::Errored;
                return a;
            }
            
            if !id->generic_args.is_empty() {
                return self._anchor_of_generic_head(id);
            }

            return self._anchor_after(id->resolved_decl, &null);
        }

        // Any other base -- a call, a subscript, a paren, a literal -- has a
        // type only inference can name.
        a.kind = AnchorKind::NeedsInference;
        return a;
    }

    /// `Box<i32>::make()` / `Stack<i32>()`: a type head with explicit args in
    /// EXPRESSION position. T resolved the arg TYPES (the RAV dispatches them);
    /// the application is GenericArgs', the rule a type position uses --
    /// defaults, named args and a pack tail included. Probed silently: X
    /// types this expression afterwards and owns any arity error, so a list
    /// that does not apply leaves the step to inference.
    priv fn _anchor_of_generic_head(self, id: *NamedIdentExpr) -> Anchor {
        var a = Anchor{};
        var canon = NameLookup::representative(id->resolved_decl);
        a.decl = canon;
        var gps = decl_generic_params(canon);
        if gps.size() == 0 {
            a.kind = AnchorKind::NeedsInference;    // not a record with params.
            return a;
        }
        for var i: usize = 0; i < id->generic_args.size(); ++i {
            var g = id->generic_args.get(i);
            if (g->ty == &null) || g->ty->is_poisoned() {
                a.kind = AnchorKind::Errored;
                return a;
            }
            if (g->ty->canonical == &null) && (!g->ty->is_dependent()) && (!g->ty->is_instantiation_dependent()) {
                a.kind = AnchorKind::Errored;
                return a;   // T left it unresolved and undiagnosed: ICE territory.
            }
        }
        var ga = GenericArgs(self.sc);
        ga.report = false;
        var args = vec::<*Type>();
        if (!ga.check_arity(canon, "", gps, id->generic_args.size(), id->range))
        || (!ga.collect(canon, gps, id->generic_args, true, &args)) {
            a.kind = AnchorKind::NeedsInference;
            return a;
        }
        var dep = ga.inst_dependent;
        for var i: usize = 0; i < args.size(); ++i {
            if args[i]->is_dependent() || args[i]->is_instantiation_dependent() { dep = true; }
        }
        if dep {
            a.kind = AnchorKind::Dependent;
            return a;
        }

        var e = self.sc->instances->instance_for(canon, &args, self.sc->ctx->fid, NameLookup::ctx_of(canon));
        var inst = (e->decl) if (e != &null) else (canon);
        a.kind = AnchorKind::Type;
        a.ty   = self.sc->types->record(inst, &args);   // lookup walks inst's body: the spec's, if any.
        return a;
    }

    /// The anchor a bound decl provides for the NEXT step.
    priv fn _anchor_after(self, d: *Decl, st: *ChainExpr::Step) -> Anchor {
        var a = Anchor{};
        if d == &null { a.kind = AnchorKind::Errored; return a; }
        if d->is_poisoned() { a.kind = AnchorKind::Errored; return a; }

        switch d->kind {
            case DeclKind::ModuleDecl {
                a.kind = AnchorKind::Module;
                // N collapses a reopened module's cell to its canonical, so a
                // single decl arrives here -- but it DENOTES every block in its
                // ring. One scope would make `Util::b` miss when `b` lives in
                // the second `module Util { }`.
                NameLookup::module_scopes(d, a.scopes);
                a.decl = d;
                return a;
            }
            case DeclKind::ClassDecl     { return self._type_anchor(d); }
            case DeclKind::StructDecl    { return self._type_anchor(d); }
            case DeclKind::UnionDecl     { return self._type_anchor(d); }
            case DeclKind::InterfaceDecl { return self._type_anchor(d); }
            case DeclKind::EnumDecl      { return self._type_anchor(d); }
            case DeclKind::TypeAliasDecl {
                var td = cast::<TypeAliasDecl>(d);
                if td->aliased == &null { a.kind = AnchorKind::Errored; return a; }
                var c = canon_unqual(td->aliased->canonical);
                if c == &null {
                    a.kind = (AnchorKind::Dependent) if (td->aliased->is_dependent()) else (AnchorKind::Errored);
                    return a;
                }
                if isa::<RecordType>(c) { return self._type_anchor(cast::<RecordType>(c)->decl); }
                // Alias of a builtin/pointer/etc.: a type, but one with no
                // scope of its own. Extensions on it are still reachable.
                a.kind = AnchorKind::Type;
                a.decl = d;
                a.ty   = c;
                return a;
            }
            case DeclKind::ImportDecl {
                // Never a lookup answer: a plain import binds the source's
                // ModuleDecl and an ffi alias binds each header TU's own
                // module_self (ImportResolution::_resolve_ffi). A head bound
                // to the ImportDecl itself is an upstream bug with no
                // diagnostic to add here.
                a.kind = AnchorKind::Errored;
                return a;
            }
            case DeclKind::GenericParamDecl {
                // `T::Name` in expression position. Dependent, but NOT opaque:
                // the canonical is what the bound lookup keys on, so a
                // Dependent anchor carries it exactly as a Value anchor does.
                var gp = cast::<GenericParamDecl>(d);
                a.kind = AnchorKind::Dependent;
                a.decl = d;
                if gp->owner != &null {
                    a.ty = self.sc->types->generic_param(
                               NameLookup::representative(gp->owner), gp->index, gp->is_pack);
                }
                return a;
            }
            case DeclKind::ParamDecl {
                var p = cast::<ParamDecl>(d);
                return self._value_anchor(d, p->type_);
            }
            case DeclKind::VariableDecl {
                var v = cast::<VariableDecl>(d);
                return self._value_anchor(d, v->type_);
            }
            case DeclKind::FieldDecl {
                var f = cast::<FieldDecl>(d);
                return self._value_anchor(d, f->type_);
            }
            case DeclKind::EnumVariantDecl {
                // A variant is a value of its enum. The enum is the variant's
                // semantic_dc owner.
                if d->semantic_dc == &null { a.kind = AnchorKind::Errored; return a; }
                var edc = reinterpret_cast::<*DeclContext>(d->semantic_dc);
                var ed  = edc->owner_decl();
                if ed == &null { a.kind = AnchorKind::Errored; return a; }
                var args = vec::<*Type>();
                a.kind = AnchorKind::Value;
                a.decl = d;
                a.ty   = self.sc->types->record(NameLookup::representative(ed), &args);
                if self._generic_count(ed) > 0 { a.kind = AnchorKind::Dependent; }
                return a;
            }
            case DeclKind::FunctionDecl {
                // A function value or a method: what follows is a call result.
                a.kind = AnchorKind::NeedsInference;
                a.decl = d;
                return a;
            }
            case DeclKind::ExtensionDecl {
                var e = cast::<ExtensionDecl>(d);
                if (e->target == &null) || e->target->is_poisoned() { a.kind = AnchorKind::Errored; return a; }
                var c = canon_unqual(e->target->canonical);
                if c == &null {
                    a.kind = (AnchorKind::Dependent) if (e->target->is_dependent()) else (AnchorKind::Errored);
                    return a;
                }
                if isa::<RecordType>(c) { return self._type_anchor(cast::<RecordType>(c)->decl); }
                a.kind = AnchorKind::Type; a.decl = d; a.ty = c;
                return a;
            }
            default {
                a.kind = AnchorKind::NeedsInference;
                a.decl = d;
                return a;
            }
        }
    }

    priv fn _type_anchor(self, d: *Decl) -> Anchor {
        var a = Anchor{};
        var canon = NameLookup::representative(d);
        a.kind = AnchorKind::Type;
        a.decl = canon;
        // The record with its own params as args (Self-shaped). For member
        // lookup only the decl matters; the args make Self/dependence right.
        var args = vec::<*Type>();
        var gps  = decl_generic_params(canon);
        for var i: usize = 0; i < gps.size(); ++i {
            var gp = gps[i];
            if gp == &null { continue; }
            args.push_back(self.sc->types->generic_param(canon, gp->index, gp->is_pack));
        }
        a.ty = self.sc->types->record(canon, &args);
        return a;
    }

    /// A value's anchor is its declared type's canonical. No declared type,
    /// or a declared type that could not canonicalize, means inference.
    priv fn _value_anchor(self, d: *Decl, t: *Type) -> Anchor {
        var a = Anchor{};
        a.decl = d;
        if t == &null { a.kind = AnchorKind::NeedsInference; return a; }
        if t->is_poisoned() { a.kind = AnchorKind::Errored; return a; }
        if t->canonical == &null {
            a.kind = (AnchorKind::Dependent) if (t->is_dependent() || t->is_instantiation_dependent())
                     else (AnchorKind::NeedsInference);
            return a;
        }
        return self._value_anchor_from(d, t->canonical);
    }

    /// The same anchor built from a canonical that has no syntax node behind
    /// it -- ExprTyper's case, where the left side of a step is the type of an
    /// EXPRESSION (`f().x`) and there is no declared type to read.
    priv fn _value_anchor_from(self, d: *Decl, canonical: *Type) -> Anchor {
        var a = Anchor{};
        a.decl = d;
        if canonical == &null { a.kind = AnchorKind::NeedsInference; return a; }
        a.kind = AnchorKind::Value;
        a.ty   = canonical;
        return a;
    }

    // === The binder, for a second caller =======================================
    //
    // ExprTyper reaches the steps ChainBinding had to leave alone: the ones
    // whose left side only becomes knowable once expressions have types. It
    // uses the SAME binder rather than a copy of it, which is the whole reason
    // these three are public.

    /// Bind one `::`/`.` step against \p a, exactly as run() would.
    /// PRE: prepare() has been called on this instance.
    fn bind_step(self, chain: *ChainExpr, st: *ChainExpr::Step, a: Anchor) -> Anchor {
        return self._bind_step(chain, st, a);
    }

    /// Anchor for a value of canonical type \p canonical. \p d is optional and
    /// only feeds diagnostics ("declared here").
    fn anchor_for_value(self, d: *Decl, canonical: *Type) -> Anchor {
        return self._value_anchor_from(d, canonical);
    }

    /// Anchor for a TYPE the typer computed: a record resolves to its decl so
    /// member lookup can walk the table; anything else can still answer
    /// `T::assoc`-shaped questions from the type alone.
    fn anchor_for_type(self, t: *Type) -> Anchor {
        if t == &null {
            var e = Anchor{};
            e.kind = AnchorKind::Errored;
            return e;
        }
        var u = canon_unqual(t);
        if isa::<RecordType>(u) { return self._type_anchor(cast::<RecordType>(u)->decl); }
        var a = Anchor{};
        a.kind = AnchorKind::Type;
        a.ty   = t;
        return a;
    }

    // === One step ==================================================================

    priv fn _bind_step(self, chain: *ChainExpr, st: *ChainExpr::Step, a: Anchor) -> Anchor {
        var at  = st->range;
        var loc = st->range.start.id;
        if st->name != &null { at = st->name->range; loc = st->name->range.start.id; }

        // Unusable left side: record why and stop the chain.
        if a.kind == AnchorKind::Errored {
            if st->name != &null { st->name->poison(); }
            self._record(loc, MemberOutcome::Errored, &null, 0, &null);
            return a;
        }
        if a.kind == AnchorKind::NeedsInference {
            self._record(loc, MemberOutcome::NeedsInference, &null, 0, a.decl);
            self.n_inference += 1;
            return a;
        }
        if a.kind == AnchorKind::Dependent {
            return self._bind_dependent_step(st, a);
        }

        // Operator and tuple-index steps need a typed operand: inference.
        if st->is_operator() || st->is_tuple_index() {
            self._record(loc, MemberOutcome::NeedsInference, &null, 0, a.decl);
            self.n_inference += 1;
            var r = Anchor{}; r.kind = AnchorKind::NeedsInference; r.decl = a.decl;
            return r;
        }
        if st->name == &null {
            var r = Anchor{}; r.kind = AnchorKind::Errored; return r;
        }

        var imm = self._name_imm(st->name->name);
        if imm == u32(-1) {
            var r = Anchor{}; r.kind = AnchorKind::Errored; return r;
        }
        var name = DeclName::ident(imm);
        var spelled = self.sc->ctx->get_spelling(st->name->name);

        var is_scope_sep = (st->access_kind == ChainExpr::AccessKind::ColonColon);

        // --- `::` -----------------------------------------------------------------
        if is_scope_sep {
            if a.kind == AnchorKind::Value {
                self._err(DiagID::R027E, at, f"'::' cannot follow a value; use '.' to access a member of '{self._decl_name_str(a.decl)}\x27");
                st->name->poison();
                self._record(loc, MemberOutcome::Errored, &null, 0, a.decl);
                var r = Anchor{}; r.kind = AnchorKind::Errored; return r;
            }
            if a.kind == AnchorKind::Module {
                // Search every scope the anchor denotes and union the hits.
                var cands  = vec::<*Decl>();
                var nhit: usize = 0;
                var frozen: *OverloadCell = &null;
                for var si: usize = 0; si < a.scopes.size(); ++si {
                    var cell = self.ml.in_scope(a.scopes[si], name, spelled);
                    if cell == &null { continue; }
                    if cell->size() == 0 { continue; }
                    nhit  += 1;
                    frozen = cell;
                    for var i: usize = 0; i < cell->size(); ++i {
                        var d = cell->get(i);
                        if d == &null { continue; }
                        var dup = false;
                        for var k: usize = 0; k < cands.size(); ++k {
                            if cands[k] == d { dup = true; break; }
                        }
                        if !dup { cands.push_back(d); }
                    }
                }
                if cands.empty() {
                    // Nothing in the module's own table. Its pub/prot imports
                    // are part of its surface too, and they live in its
                    // OVERLAY rather than that table (IMPORTS.md §4.4).
                    for var si: usize = 0; si < a.scopes.size(); ++si {
                        var rx = self.ml.reexport_lookup(a.scopes[si], spelled);
                        if rx == &null { continue; }
                        for var i: usize = 0; i < rx->size(); ++i {
                            var d = rx->get(i);
                            if d == &null { continue; }
                            var dup = false;
                            for var k: usize = 0; k < cands.size(); ++k {
                                if cands[k] == d { dup = true; break; }
                            }
                            if !dup { cands.push_back(d); }
                        }
                    }
                }
                if cands.empty() {
                    var mn = ("the global scope") if (a.decl == &null) else (f"module '{self._decl_name_str(a.decl)}\x27");
                    self._err(DiagID::R025E, at, f"no member named '{spelled}' in {mn}");
                    st->name->poison();
                    self._record(loc, MemberOutcome::Errored, &null, 0, a.decl);
                    var r = Anchor{}; r.kind = AnchorKind::Errored; return r;
                }
                // A frozen cell may only be reused when it IS the answer: with
                // two contributing scopes the union is a new set.
                if nhit > 1 { frozen = &null; }
                return self._commit(st, loc, &cands, a.decl, frozen);
            }
            // Type: statics, nested types, enum variants, ctors -- member lookup.
            var cands = vec::<*Decl>();
            self.ml.lookup(a.ty, name, &cands);
            if cands.empty() {
                self._err(DiagID::R025E, at, f"no member named '{spelled}' in '{self._decl_name_str(a.decl)}\x27");
                st->name->poison();
                self._record(loc, MemberOutcome::Errored, &null, 0, a.decl);
                var r = Anchor{}; r.kind = AnchorKind::Errored; return r;
            }
            return self._commit(st, loc, &cands, a.decl, &null);
        }

        // --- `.` `->` `?.` `?->` -----------------------------------------------------
        if a.kind == AnchorKind::Module {
            self._err(DiagID::R027E, at, f"'.' cannot follow a module; use '::' to name a member of '{self._decl_name_str(a.decl)}\x27");
            st->name->poison();
            self._record(loc, MemberOutcome::Errored, &null, 0, a.decl);
            var r = Anchor{}; r.kind = AnchorKind::Errored; return r;
        }
        if a.kind == AnchorKind::Type {
            self._err(DiagID::R027E, at, f"'.' cannot follow a type; use '::' to name a member of '{self._decl_name_str(a.decl)}\x27");
            st->name->poison();
            self._record(loc, MemberOutcome::Errored, &null, 0, a.decl);
            var r = Anchor{}; r.kind = AnchorKind::Errored; return r;
        }

        // Value. Peel the separator's expected wrapper off the canonical.
        // A C++ reference first, before any separator rule: it is transparent
        // to `.` and `->` alike, and `vector&` must answer as `vector`.
        var ty = self.ml.peel_ref(a.ty);
        var arrow =(st->access_kind == ChainExpr::AccessKind::Arrow)
                 || (st->access_kind == ChainExpr::AccessKind::QuestionArrow);
        var maybe = (st->access_kind == ChainExpr::AccessKind::QuestionDot)
                 || (st->access_kind == ChainExpr::AccessKind::QuestionArrow);

        if maybe {
            if isa::<NullableType>(ty) {
                ty = cast::<NullableType>(ty)->inner;
            } else if isa::<RecordType>(ty) {
                // `T?` may have been lowered to `Null<T>` (lang item). Peel it.
                var rt = cast::<RecordType>(ty);
                var null_decl = self.sc->well_known->get(WellKnownType::Null);
                if (null_decl != &null) && (rt->decl == null_decl) && (rt->args.size() == 1) {
                    ty = rt->args[0];
                }
            }
            // `?.` on a non-nullable is a warning's worth, not an error; the
            // nullable checker owns it. Proceed on the type as-is.
        }
        if arrow {
            if !isa::<PointerType>(ty) {
                self._err(DiagID::R027E, at, "'->' requires a pointer on its left; use '.' for a value");
                st->name->poison();
                self._record(loc, MemberOutcome::Errored, &null, 0, a.decl);
                var r = Anchor{}; r.kind = AnchorKind::Errored; return r;
            }
            ty = cast::<PointerType>(ty)->pointee;
            ty = self.ml.peel_ref(ty);
        } else {
            if isa::<PointerType>(ty) {
                self._err(DiagID::R027E, at, "'.' cannot be applied to a pointer; use '->\x27");
                st->name->poison();
                self._record(loc, MemberOutcome::Errored, &null, 0, a.decl);
                var r = Anchor{}; r.kind = AnchorKind::Errored; return r;
            }
        }
        if ty == &null {
            var r = Anchor{}; r.kind = AnchorKind::Errored; return r;
        }
        // A dependent RECORD still has a known decl, and MemberLookup keys on
        // the decl: `self.x` in `class <T> Foo` binds to the field today, and
        // only the NEXT anchor (the field's type) carries the dependence. A
        // dependent non-record (`T`, `*T`, `[T]`) has no scope of its own --
        // what it has is whatever its DECLARATION promised, which is the
        // dependent path's question. Hand it the PEELED type: `p->draw()` on
        // a `p: *T` asks about T, not about the pointer.
        if ty->is_dependent() && (!isa::<RecordType>(ty)) {
            var dep = Anchor{};
            dep.kind = AnchorKind::Dependent;
            dep.decl = a.decl;
            dep.ty   = ty;
            return self._bind_dependent_step(st, dep);
        }

        var cands = vec::<*Decl>();
        self.ml.lookup(ty, name, &cands);
        if cands.empty() {
            var tn = self._type_name_str(ty);
            self._err(DiagID::R025E, at, f"no member named '{spelled}' in '{tn}\x27");
            st->name->poison();
            self._record(loc, MemberOutcome::Errored, &null, 0, a.decl);
            var r = Anchor{}; r.kind = AnchorKind::Errored; return r;
        }
        var owner: *Decl = &null;
        if isa::<RecordType>(ty) { owner = cast::<RecordType>(ty)->decl; }
        return self._commit(st, loc, &cands, owner, &null);
    }

    /// Write the step's slots from a candidate set and produce the next anchor.
    ///
    ///   one decl            -> resolved_decl
    ///   all functions       -> candidate_cell (the frozen cell if they all came
    ///                          from one; a sema-owned merged cell otherwise)
    ///   mixed / >1 non-fn   -> ambiguous: two distinct entities under one
    ///                          name reached through different bases.
    priv fn _commit(self, st: *ChainExpr::Step, loc: u32, cands: *vec::<*Decl>,
                    owner: *Decl, frozen: *OverloadCell) -> Anchor {
        var n = cands->size();
        if n == 1 {
            var d = NameLookup::representative((*cands)[0]);
            st->resolved_decl = d;
            self._record(loc, MemberOutcome::Bound, d, 1, self._home_of(d));
            self.n_bound += 1;
            return self._anchor_after(d, st);
        }

        var all_fn = true;
        var nonfn: *Decl = &null;
        var nonfn2: *Decl = &null;
        for var i: usize = 0; i < n; ++i {
            var d = (*cands)[i];
            if !isa::<FunctionDecl>(d) {
                all_fn = false;
                if nonfn == &null { nonfn = d; } else if nonfn2 == &null { nonfn2 = d; }
            }
        }

        if !all_fn {
            // A redecl chain (fwd + def) collapses to one entity; only distinct
            // entities are ambiguous.
            var sole: *Decl = &null;
            var distinct = false;
            for var i: usize = 0; i < n; ++i {
                var r = NameLookup::representative((*cands)[i]);
                if sole == &null { sole = r; continue; }
                if sole != r { distinct = true; break; }
            }
            if !distinct {
                st->resolved_decl = sole;
                self._record(loc, MemberOutcome::Bound, sole, 1, self._home_of(sole));
                self.n_bound += 1;
                return self._anchor_after(sole, st);
            }
            var nm = self.sc->ctx->get_spelling(st->name->name);
            var b = self.sc->diag->report(DiagID::R028E, st->name->range.start,
                f"'{nm}' is ambiguous: it names more than one member reachable from here"
            );
            b.first(st->name->range);
            for var i: usize = 0; i < n; ++i {
                var d = (*cands)[i];
                b.note(DiagID::R028N, d->range.start, "candidate declared here").first(d->range);
            }
            b.emit();
            st->name->poison();
            self._record(loc, MemberOutcome::Errored, &null, n, owner);
            self.n_errored += 1;
            var r = Anchor{}; r.kind = AnchorKind::Errored; return r;
        }

        // Overload set. Reuse the frozen cell when it is exactly the set;
        // otherwise union into a sema-owned cell (dies with sema_alloc).
        var cell: *OverloadCell = &null;
        if (frozen != &null) && (frozen->size() == n) {
            cell = frozen;
        } else {
            cell = self.sc->ctx->alloc_init_sema_cleanup::<OverloadCell>();
            for var i: usize = 0; i < n; ++i { cell->append((*cands)[i]); }
        }
        st->candidate_cell = cell;
        self._record(loc, MemberOutcome::Candidates, &null, n, owner);
        self.n_cands += 1;
        var r = Anchor{}; r.kind = AnchorKind::NeedsInference; r.decl = owner; return r;
    }

    // === The dependent regimes =====================================================
    //
    // A step whose left side is a generic parameter has THREE possible
    // answers, and which one applies is a property of the parameter's
    // DECLARATION, not of the step:
    //
    //   `<T: type>`            duck: defer everything to instantiation, the
    //                          C++ rule. No diagnostic here, ever.
    //   `<T impl I>` /         bounded: the parameter's members are exactly
    //   `<T derives B>`        the bound's members. Resolved NOW, at the
    //                          template, once -- not once per instantiation.
    //   `<T>`                  opaque: no bound, so no members. `x.anything`
    //                          is an error AT THE TEMPLATE, which is the whole
    //                          difference from C++.
    //
    // Everything below is the middle case doing real work; the other two are
    // one branch each.

    /// \class ParamBounds
    /// \brief What a generic parameter's declaration lets a body see.
    class ParamBounds {
        pub var duck:       bool = false;        ///< `: type`: defer everything.
        pub var interfaces: vec::<*Decl>;        ///< `impl I` bounds.
        pub var bases:      vec::<*Decl>;        ///< `derives B` bounds.
        pub var param:      *GenericParamDecl = &null;
        fn ParamBounds(self) { }
    }

    /// The declaring GenericParamDecl behind a canonical, or null when the
    /// canonical is not a bare parameter (`*T`, `[T]`: no declaration to ask).
    priv fn _param_of(self, t: *Type) -> *GenericParamDecl {
        if (t == &null) || (!isa::<GenericParamType>(t)) { return &null; }
        var g = cast::<GenericParamType>(t);
        if g->owner == &null { return &null; }
        var gps = decl_generic_params(g->owner);
        if static_cast::<usize>(g->param_index) >= gps.size() { return &null; }
        return gps[static_cast::<usize>(g->param_index)];
    }

    /// The bounds \p gp's declaration promised. The requires clause is the
    /// SINGLE source of truth for conformance: RequiresDesugar hoisted every
    /// inline `impl`/`derives` into it and cleared the inline lists, and
    /// ConstraintExtraction filed the partition in sc->bounds. Only the kind
    /// bound stays on the parameter, because it describes the slot rather
    /// than conjoining a constraint.
    priv fn _bounds_of(self, gp: *GenericParamDecl, owner: *Decl) -> ParamBounds {
        var b = ParamBounds{};
        if gp == &null { return b; }
        b.param = gp;
        b.duck  = (gp->kind_bound == GenericParamKindBound::Duck);

        var it = self.sc->bounds.find(reinterpret_cast::<u64>(owner));
        if it == self.sc->bounds.end() { return b; }
        var _set = &(it->second);
        for var i: usize = 0; i < _set->impl_constraints.size(); ++i {
            var c = _set->impl_constraints[i];
            if !self._constraint_names(c, gp) { continue; }
            var d = self._record_decl_of(c->rhs);
            if d != &null { b.interfaces.push_back(d); }
        }
        for var i: usize = 0; i < _set->derives_constraints.size(); ++i {
            var c = _set->derives_constraints[i];
            if !self._constraint_names(c, gp) { continue; }
            var d = self._record_decl_of(c->rhs);
            if d != &null { b.bases.push_back(d); }
        }
        return b;
    }

    /// Whether conjunct \p c constrains \p gp. The lhs is an ordinary
    /// identifier N bound like any other, so this is a pointer compare and not
    /// a name compare: `fn <T> f() requires T impl I` inside `class <T> C`
    /// constrains the FUNCTION's T, and the two T are different entities.
    priv fn _constraint_names(self, c: *ConstraintExpr, gp: *GenericParamDecl) -> bool {
        if (c == &null) || (c->lhs == &null) { return false; }
        var id = dyn_cast::<NamedIdentExpr>(c->lhs);
        if id == &null { return false; }
        return id->resolved_decl == static_cast::<*Decl>(gp);
    }

    /// The record decl a bound's written type names, or null if it names none
    /// (a builtin, a pointer: nothing with members to offer).
    priv fn _record_decl_of(self, t: *Type) -> *Decl {
        if (t == &null) || (t->canonical == &null) { return &null; }
        var c = canon_unqual(t->canonical);
        if !isa::<RecordType>(c) { return &null; }
        return NameLookup::representative(cast::<RecordType>(c)->decl);
    }

    /// One step whose left side is dependent.
    priv fn _bind_dependent_step(self, st: *ChainExpr::Step, a: Anchor) -> Anchor {
        var at  = st->range;
        var loc = st->range.start.id;
        if st->name != &null { at = st->name->range; loc = st->name->range.start.id; }

        var gp = self._param_of(a.ty);
        if gp == &null {
            // A dependent COMPOSITE (`[T]`, an unfilled `Foo<T>::Inner`, or a
            // parameter whose declarer T never stamped): no single declaration
            // to read a promise off. Undecidable before M2.
            self._record(loc, MemberOutcome::Dependent, &null, 0, a.decl);
            self.n_dependent += 1;
            return a;
        }
        var owner = cast::<GenericParamType>(a.ty)->owner;
        var b     = self._bounds_of(gp, owner);

        // `: type` -- the C++ regime. Not a hole we failed to fill: a hole the
        // author asked for.
        if b.duck {
            self._record(loc, MemberOutcome::Dependent, &null, 0, a.decl);
            self.n_dependent += 1;
            return a;
        }

        var pname = self._decl_name_str(static_cast::<*Decl>(gp));
        if (b.interfaces.size() == 0) && (b.bases.size() == 0) {
            var what = "this member";
            if st->name != &null { what = f"'{self.sc->ctx->get_spelling(st->name->name)}\x27"; }
            var d = self.sc->diag->report(DiagID::R051E, at.start,
                f"'{pname}' has no members, so {what} cannot be resolved"
            );
            d.first(at);
            d.note(DiagID::R051N, gp->range.start,
                f"'{pname}' is declared with no bound; add 'impl <Interface>' to give it members"
            ).first(gp->range);
            d.emit();
            if st->name != &null { st->name->poison(); }
            self._record(loc, MemberOutcome::Errored, &null, 0, a.decl);
            self.n_errored += 1;
            var r = Anchor{}; r.kind = AnchorKind::Errored; return r;
        }

        // An operator or a tuple index through a bound needs the operand's
        // TYPE, which is the typer's to supply, not this pass's.
        if st->is_operator() || st->is_tuple_index() || (st->name == &null) {
            self._record(loc, MemberOutcome::NeedsInference, &null, 0, a.decl);
            self.n_inference += 1;
            var r = Anchor{}; r.kind = AnchorKind::NeedsInference; r.decl = a.decl; return r;
        }

        if st->access_kind == ChainExpr::AccessKind::ColonColon {
            // `T::Name`: statics and nested types of a BASE. An interface
            // declares neither today (no statics, no associated types), so a
            // parameter bounded only by interfaces has an empty `::` scope.
            if b.bases.size() == 0 {
                self._err(DiagID::R027E, at,
                    f"'::' on '{pname}': its interface bounds declare no static members or nested types");
                st->name->poison();
                self._record(loc, MemberOutcome::Errored, &null, 0, a.decl);
                var r = Anchor{}; r.kind = AnchorKind::Errored; return r;
            }
        }

        var imm = self._name_imm(st->name->name);
        if imm == u32(-1) {
            var r = Anchor{}; r.kind = AnchorKind::Errored; return r;
        }
        var name    = DeclName::ident(imm);
        var spelled = self.sc->ctx->get_spelling(st->name->name);
        var cands   = vec::<*Decl>();
        var empty   = vec::<*Type>();
        for var i: usize = 0; i < b.interfaces.size(); ++i {
            self.ml.lookup(self.sc->types->record(b.interfaces[i], &empty), name, &cands);
        }
        for var i: usize = 0; i < b.bases.size(); ++i {
            self.ml.lookup(self.sc->types->record(b.bases[i], &empty), name, &cands);
        }
        if cands.empty() {
            self._err(DiagID::R025E, at, f"no member named '{spelled}' in the bounds of '{pname}\x27");
            st->name->poison();
            self._record(loc, MemberOutcome::Errored, &null, 0, a.decl);
            var r = Anchor{}; r.kind = AnchorKind::Errored; return r;
        }
        // _commit binds it like any other member, and the anchor it hands back
        // is already right: an interface method yields NeedsInference (a call
        // result), a base field yields that field's declared type.
        return self._commit(st, loc, &cands, self._bound_owner(&b), &null);
    }

    /// The decl a bound-resolved member is REPORTED against: the sole bound
    /// when there is one, nothing when several could have answered (naming
    /// one of them would be a guess).
    priv fn _bound_owner(self, b: *ParamBounds) -> *Decl {
        if (b->interfaces.size() == 1) && (b->bases.size() == 0) { return b->interfaces[0]; }
        if (b->bases.size() == 1) && (b->interfaces.size() == 0) { return b->bases[0]; }
        return &null;
    }
    // === helpers ===================================================================

    /// The decl that OWNS `d`'s scope -- the type a member was declared in,
    /// which is what a reader wants to see, not the type it was reached
    /// through.
    priv fn _home_of(self, d: *Decl) -> *Decl {
        if (d == &null) || (d->semantic_dc == &null) { return &null; }
        var owner = reinterpret_cast::<*DeclContext>(d->semantic_dc)->owner_decl();
        if isa::<ExtensionDecl>(owner) {
            // An ExtensionDecl has no name of its own, so reporting it says
            // "[member of ]". The home a reader means is the type extended.
            var e = cast::<ExtensionDecl>(owner);
            if (e->target != &null) && (e->target->canonical != &null) {
                var c = canon_unqual(e->target->canonical);
                if isa::<RecordType>(c) { return cast::<RecordType>(c)->decl; }
            }
        }
        return owner;
    }

    priv fn _record(self, loc: u32, o: MemberOutcome, d: *Decl, ncand: usize, owner: *Decl) {
        self.sc->trace.member_result(loc, o, d, ncand, owner);
    }

    priv fn _err(self, id: DiagID, at: SourceRange, msg: string) {
        self.sc->diag->report(id, at.start, msg).first(at).emit();
        self.n_errored += 1;
    }

    priv fn _name_imm(self, tok: Token) -> u32 {
        var im = self.sc->ctx->get_ident_imm(tok);
        if im != u32(-1) { return im; }
        if tok.kind == TokenKind::KwSelf { return self._self_imm; }
        return u32(-1);
    }

    priv fn _generic_count(self, d: *Decl) -> usize {
        return decl_generic_params(d).size();
    }

    /// Spelled with the decl's OWN context: a name reached through an import
    /// is interned in the source file's imm table, not this TU's.
    priv fn _decl_name_str(self, d: *Decl) -> string {
        if d == &null { return "<null>"; }
        var ctx = NameLookup::ctx_of(d);
        if ctx == &null { ctx = self.sc->ctx; }
        if isa::<ClassDecl>(d)        { return ctx->get_spelling(cast::<ClassDecl>(d)->name);        }
        if isa::<StructDecl>(d)       { return ctx->get_spelling(cast::<StructDecl>(d)->name);       }
        if isa::<UnionDecl>(d)        { return ctx->get_spelling(cast::<UnionDecl>(d)->name);        }
        if isa::<InterfaceDecl>(d)    { return ctx->get_spelling(cast::<InterfaceDecl>(d)->name);    }
        if isa::<EnumDecl>(d)         { return ctx->get_spelling(cast::<EnumDecl>(d)->name);         }
        if isa::<TypeAliasDecl>(d)    { return ctx->get_spelling(cast::<TypeAliasDecl>(d)->name);    }
        if isa::<ModuleDecl>(d)       { return ctx->get_spelling(cast::<ModuleDecl>(d)->name);       }
        if isa::<FunctionDecl>(d)     { return ctx->get_spelling(cast::<FunctionDecl>(d)->name);     }
        if isa::<ParamDecl>(d)        { return ctx->get_spelling(cast::<ParamDecl>(d)->name);        }
        if isa::<VariableDecl>(d)     { return ctx->get_spelling(cast::<VariableDecl>(d)->name);     }
        if isa::<FieldDecl>(d)        { return ctx->get_spelling(cast::<FieldDecl>(d)->name);        }
        if isa::<EnumVariantDecl>(d)  { return ctx->get_spelling(cast::<EnumVariantDecl>(d)->name);  }
        if isa::<GenericParamDecl>(d) { return ctx->get_spelling(cast::<GenericParamDecl>(d)->name); }
        return "<decl>";
    }

    /// Diagnostic spelling of a canonical. Kept minimal on purpose: the
    /// TypePrinter is the real renderer and this must not grow into a second
    /// one.
    priv fn _type_name_str(self, t: *Type) -> string {
        if t == &null { return "<type>"; }
        if isa::<BuiltinType>(t) { return cast::<BuiltinType>(t)->spelling(); }
        if isa::<RecordType>(t)  { return self._decl_name_str(cast::<RecordType>(t)->decl); }
        if isa::<PointerType>(t) { return f"*{self._type_name_str(cast::<PointerType>(t)->pointee)}"; }
        if isa::<NullableType>(t){ return f"{self._type_name_str(cast::<NullableType>(t)->inner)}?"; }
        if isa::<CXXLValueRefType>(t) {
            var lr = cast::<CXXLValueRefType>(t);
            return f"{self._type_name_str(lr->referee)}&";
        }
        if isa::<QualifiedType>(t) {
            var q = cast::<QualifiedType>(t);
            var s = ("const ") if (canon_has_const(t)) else ("");
            if canon_has_volatile(t) { s += "volatile "; }
            return s + self._type_name_str(q->inner);
        }
        if isa::<CXXRValueRefType>(t) { return f"{self._type_name_str(cast::<CXXRValueRefType>(t)->referee)}&&"; }
        if isa::<VectorType>(t)  { return f"[{self._type_name_str(cast::<VectorType>(t)->element)}]"; }
        if isa::<TupleType>(t)   { return "a tuple"; }
        if isa::<MapType>(t)     { return "a map"; }
        if isa::<SetType>(t)     { return "a set"; }
        if isa::<FunctionPointerType>(t) { return "a function pointer"; }
        return "this type";
    }
}