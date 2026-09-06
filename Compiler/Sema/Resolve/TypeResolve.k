/// --- The Kairo Project ------------------- Sema/Resolve/TypeResolve.k --- ///
///
///   \brief Phase T: every non-dependent Type node becomes canonical.
///
///   \detail
///     T assigns types to type NODES only (RESOLUTION.md §2 "T"). Typing
///     expressions -- inference, coercion, operator resolution -- is
///     TypeInference/M2 territory and never happens here.
///
///     T NEVER REWRITES A NODE. It fills exactly four kinds of slot:
///       Type::canonical           the uniqued, unqualified identity
///       Type::type_flags          dependence, propagated up from components
///       ChainType::ChainSegment::resolved_*  what each `::` segment bound to
///       Type::poisoned            when a diagnostic was emitted
///     `T` inside `fn foo<T>()` stays a ChainType whose canonical is a
///     GenericParamType. Rewriting node kinds through a RAV is unsafe (the
///     parent already holds the old pointer type) and buys nothing: every
///     consumer reads `->canonical`, not `->kind`.
///
///   \par Demand-driven, not two-phase
///     Resolution recurses: `type A = B` needs B canonical first, and B may
///     live three files away. `resolve()` is memoized on ResolutionState and
///     `_expand_alias` claims the alias decl before descending, so
///     `type A = B; type B = A` is a DIAGNOSTIC (with the whole chain as
///     notes), not a hang. The whole-TU walk in run() is just a driver that
///     visits every node once; any node may already be Resolved by the time
///     the walk reaches it because something else demanded it first.
///
///   \par Post-order
///     dispatch_type is overridden to walk children THEN resolve the parent.
///     That is the whole ordering discipline: by the time `_resolve_pointer`
///     runs, `pointee->canonical` is set, so the store is only ever handed
///     canonical components -- its one contract.
///
///   \par Cross-TU writes
///     Expanding an imported alias writes `canonical` onto a node in ANOTHER
///     fid's arena. That is safe today because the driver runs sema in
///     reverse import-tree order (CompilerInstance::_sema): the source file's
///     T finished before the importer's began, so the write is a no-op re-set
///     of the same pointer on a node nobody else is touching. Change that loop
///     order and this becomes a data race.
///
///   \par One error, one home
///     Unknown-type-name, generic arity, alias cycle, builtin-with-args,
///     value-param-as-type, non-type-in-type-position: HERE. Unresolved
///     value idents: N. Conformance of bases/impls: ConformanceChecking.
///     Whether a const generic arg is actually constant: the evaluator.
///
///   Phase: RESOLVE (T)
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
import Sema::Resolve::NameLookup::*;
import Sema::Resolve::ResolutionState::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::SymbolTable::*;
import AST::Context::CanonicalTypes::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Kind::TypeKind::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Token::Token::*;
import Token::TokenKind::*;
import Diagnostic::Registry::*;

__inline_cpp("
#define RecursiveASTVisitor_TypeResolution RecursiveASTVisitor<TypeResolution>
");

///
/// \class GenericFrame
/// \brief One generic-parameter scope on T's lexical stack. Generic params are
///        NOT in any symbol table (they come off the declaring node), so T
///        keeps its own stack exactly as N keeps a locals stack.
///
class GenericFrame {
    pub var owner:  *Decl = &null;                      ///< the declaring decl; null for a closure.
    pub var params: FrozenList::<*GenericParamDecl>;

    fn GenericFrame(self) { }
}

///
/// \class TypeResolution
/// \brief The T pass. One instance per TU per run.
///
///        State is three cursors, all save/restored by the traverse_*
///        overrides:
///          cur_dc  -- innermost TABLE-owning scope, for unqualified lookup.
///          frames  -- generic-param frames, innermost last.
///          selfs   -- enclosing TYPE decls (canonical links), innermost last;
///                     what `Self` and the `self` receiver denote.
///
class TypeResolution derives RecursiveASTVisitor::<TypeResolution> {
    pub var sc: *SemaContext;

    var cur_dc: *DeclContext = &null;
    var frames: vec::<GenericFrame>;
    var selfs:  vec::<*Decl>;

    /// Counters for the driver's summary line.
    pub var n_canonical: usize = 0;
    pub var n_dependent: usize = 0;
    pub var n_errored:   usize = 0;

    fn TypeResolution(self, sc: *SemaContext) {
        self.sc = sc;
    }

    /// Entry point. PRE: NamesResolved (redecl chains linked, out-of-line
    /// attached -- both needed so a name resolves to the DEFINITION). POST
    /// (advanced by the driver): every non-dependent Type node canonical.
    fn run(self) {
        self.sc->require_phase(SemaPhase::NamesResolved);
        var tu = self.sc->tu;
        if tu == &null { return; }
        if tu->program == &null { return; }
        assert((self.sc->types != &null) && r"TypeResolution: canonical store not wired");

        self.cur_dc = static_cast::<*DeclContext>(tu);

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

    // === The post-order hook ==================================================

    /// Children first (base dispatch recurses), then this node. Every other
    /// method in this file may assume its components are already canonical.
    fn dispatch_type(self, e: *Type) -> *Type {
        if e == &null { return e; }
        if self.stop  { return e; }
        var out = RecursiveASTVisitor_TypeResolution::dispatch_type(e);
        self.resolve(out);
        return out;
    }

    /// Resolve ONE node whose children are already resolved. Idempotent via
    /// rstate: a node demanded twice is computed once.
    /// \return the canonical, or null for dependent / errored.
    fn resolve(self, t: *Type) -> *Type {
        if t == &null { return &null; }
        if self.sc->rstate.type_done(t) { return t->canonical; }

        if is_recovery(t) {
            // A failed PARSE. Already diagnosed by the parser; poison so
            // consumers degrade, say nothing.
            t->poison();
            self.sc->rstate.set_type_state(t, ResolveState::Errored);
            self.n_errored += 1;
            return &null;
        }

        switch t->kind {
            case TypeKind::ChainType             { self._resolve_chain(cast::<ChainType>(t));                 }
            case TypeKind::BuiltinType           { 0; }   // canonical by construction.
            case TypeKind::RecordType            { 0; }   // canonical by construction.
            case TypeKind::PointerType           { self._resolve_pointer(cast::<PointerType>(t));             }
            case TypeKind::NullableType          { self._resolve_nullable(cast::<NullableType>(t));           }
            case TypeKind::VectorType            { self._resolve_vector(cast::<VectorType>(t));               }
            case TypeKind::SetType               { self._resolve_set(cast::<SetType>(t));                     }
            case TypeKind::MapType               { self._resolve_map(cast::<MapType>(t));                     }
            case TypeKind::TupleType             { self._resolve_tuple(cast::<TupleType>(t));                 }
            case TypeKind::FixedArrayType        { self._resolve_array(cast::<FixedArrayType>(t));            }
            case TypeKind::FunctionPointerType   { self._resolve_fnptr(cast::<FunctionPointerType>(t));       }
            case TypeKind::SelfType              { self._resolve_self(cast::<SelfType>(t));                   }
            case TypeKind::GenericParamType      { self._resolve_gparam_node(cast::<GenericParamType>(t));    }
            case TypeKind::SubstGenericParamType { self._resolve_subst(cast::<SubstGenericParamType>(t));     }
            case TypeKind::VariadicPackType      { self._resolve_variadic(cast::<VariadicPackType>(t));       }
            case TypeKind::PackExpansionType     { self._resolve_pack_expansion(cast::<PackExpansionType>(t)); }
            case TypeKind::CXXLValueRefType      { self._resolve_cxx_lref(cast::<CXXLValueRefType>(t));       }
            case TypeKind::CXXRValueRefType      { self._resolve_cxx_rref(cast::<CXXRValueRefType>(t));       }
            case TypeKind::OpaqueFFIType         { self._resolve_opaque(cast::<OpaqueFFIType>(t));            }
            case TypeKind::InferredType          { 0; }   // TypeInference owns; no canonical here.
            case TypeKind::TypeOfType            { self._mark_inst_dependent(t); }   // needs expr typing.
            case TypeKind::TypeExpr              { self._mark_inst_dependent(t); }   // const arg; evaluator.
            default                              { 0; }
        }

        var st = ResolveState::Resolved;
        if t->is_poisoned() {
            st = ResolveState::Errored;
            self.n_errored += 1;
        } else if t->canonical != &null {
            self.n_canonical += 1;
        } else if t->is_dependent() || t->is_instantiation_dependent() {
            self.n_dependent += 1;
        }
        self.sc->rstate.set_type_state(t, st);
        return t->canonical;
    }

    // === Structural kinds =====================================================
    //
    // Shape of every one: read the component's canonical; if null, inherit
    // its dependence/poison and stop; else ask the store.

    priv fn _resolve_pointer(self, n: *PointerType) {
        if !self._component_ok(n, n->pointee) { return; }
        n->canonical = self.sc->types->pointer(n->pointee->canonical);
    }

    priv fn _resolve_nullable(self, n: *NullableType) {
        if !self._component_ok(n, n->inner) { return; }
        n->canonical = self.sc->types->nullable(n->inner->canonical);
    }

    priv fn _resolve_vector(self, n: *VectorType) {
        if !self._component_ok(n, n->element) { return; }
        n->canonical = self.sc->types->vector(n->element->canonical);
    }

    priv fn _resolve_set(self, n: *SetType) {
        if !self._component_ok(n, n->element) { return; }
        n->canonical = self.sc->types->set_of(n->element->canonical);
    }

    priv fn _resolve_cxx_lref(self, n: *CXXLValueRefType) {
        if !self._component_ok(n, n->referee) { return; }
        n->canonical = self.sc->types->cxx_lref(n->referee->canonical);
    }

    priv fn _resolve_cxx_rref(self, n: *CXXRValueRefType) {
        if !self._component_ok(n, n->referee) { return; }
        n->canonical = self.sc->types->cxx_rref(n->referee->canonical);
    }

    priv fn _resolve_map(self, n: *MapType) {
        var ok_k = self._component_ok(n, n->key);
        var ok_v = self._component_ok(n, n->value);
        if !(ok_k && ok_v) { return; }
        n->canonical = self.sc->types->map_of(n->key->canonical, n->value->canonical);
    }

    priv fn _resolve_tuple(self, n: *TupleType) {
        var elems = vec::<*Type>();
        var ok = true;
        for var i: usize = 0; i < n->elements.size(); ++i {
            var e = n->elements[i];
            if !self._component_ok(n, e) { ok = false; continue; }
            elems.push_back(e->canonical);
        }
        if !ok { return; }
        n->canonical = self.sc->types->tuple(&elems);
    }

    /// `[T; N]` has an identity only once N is a known constant. The parser
    /// accepts any expression there, but the evaluator does not exist yet, so
    /// the one case T can settle is a literal. Anything else is marked
    /// instantiation-dependent and left -- NOT an error: `[u8; SIZE]` with a
    /// `const SIZE` is legal, just not decidable here. `[T;]` (incomplete, C
    /// interop) never has an extent and canonicalizes as extent 0 with the
    /// is_incomplete flag preserved on the SYNTAX node.
    priv fn _resolve_array(self, n: *FixedArrayType) {
        if !self._component_ok(n, n->element) { return; }
        var elem = n->element->canonical;

        if n->is_incomplete {
            n->canonical = self.sc->types->array(elem, 0);
            return;
        }

        var extent: u64 = 0;
        var known  = false;
        if (n->size_expr != &null) && isa::<IntegerLiteralExpr>(n->size_expr) {
            var lit = cast::<IntegerLiteralExpr>(n->size_expr);
            if (lit->imm != &null) && (!lit->is_big()) && (!lit->is_negative()) {
                extent = lit->get_value_lo();
                known  = true;
            }
        }

        if !known {
            self._mark_inst_dependent(n);
            return;
        }
        n->canonical = self.sc->types->array(elem, extent);
    }

    /// An unprototyped `fn()` from a C header canonicalizes as a zero-param
    /// function: Kairo has no "unknown parameters" identity and the C rule
    /// (any args) has no type-level meaning worth inventing. Callers that
    /// care check `is_unprototyped` on the syntax node.
    priv fn _resolve_fnptr(self, n: *FunctionPointerType) {
        var params = vec::<*Type>();
        var ok = true;
        for var i: usize = 0; i < n->params.size(); ++i {
            var p = n->params[i];
            if !self._component_ok(n, p) { ok = false; continue; }
            params.push_back(p->canonical);
        }
        var ret: *Type = &null;
        if n->return_type != &null {
            if !self._component_ok(n, n->return_type) { ok = false; }
            else { ret = n->return_type->canonical; }
        } else {
            ret = self.sc->builtin(BuiltinKind::Void);
        }
        if !ok { return; }
        n->canonical = self.sc->types->func(&params, ret);
    }

    priv fn _resolve_opaque(self, n: *OpaqueFFIType) {
        n->canonical = self.sc->types->opaque(n->name);
    }

    priv fn _resolve_subst(self, n: *SubstGenericParamType) {
        // create() already pointed canonical at the replacement's canonical;
        // re-derive in case the replacement was resolved after this node was
        // built (M2 constructs these, so today this is future-proofing).
        if !self._component_ok(n, n->replacement) { return; }
        n->canonical = n->replacement->canonical;
    }

    /// Reads a child's outcome onto the parent. Returns true iff the child has
    /// a canonical to build with. On false the parent has already been marked
    /// poisoned or dependent to match, so the caller just returns.
    priv fn _component_ok(self, parent: *Type, child: *Type) -> bool {
        if child == &null {
            // Missing child on a non-recovery node: the parser promised one.
            // Treat as poisoned-and-silent; the parse diagnostic already fired.
            parent->poison();
            return false;
        }
        if child->is_poisoned() {
            parent->poison();
            return false;
        }
        if child->canonical == &null {
            // Dependent, or awaiting M2. Inherit exactly the flags it carries.
            parent->type_flags = static_cast::<Type::TypeFlags>(
                static_cast::<u8>(parent->type_flags) | static_cast::<u8>(child->type_flags));
            if !(parent->is_dependent() || parent->is_instantiation_dependent()) {
                // A resolved, non-dependent, unpoisoned child with no canonical
                // is an ICE in T, not a user error.
                self.sc->diag->report(DiagID::I002F, child->range.start,
                    "internal: type node resolved with neither a canonical nor a dependence flag "
                    "(TypeResolution invariant violation, please report)"
                ).first(child->range).emit();
                parent->poison();
            }
            return false;
        }
        return true;
    }

    priv fn _mark_inst_dependent(self, t: *Type) {
        t->type_flags = static_cast::<Type::TypeFlags>(
            static_cast::<u8>(t->type_flags)
          | static_cast::<u8>(Type::TypeFlags::IsInstantiationDependent));
    }

    priv fn _mark_dependent(self, t: *Type) {
        t->type_flags = static_cast::<Type::TypeFlags>(
            static_cast::<u8>(t->type_flags)
          | static_cast::<u8>(Type::TypeFlags::IsDependent)
          | static_cast::<u8>(Type::TypeFlags::IsInstantiationDependent));
    }

    // === Self =================================================================

    priv fn _resolve_self(self, n: *SelfType) {
        var owner = self._current_self_decl();
        if owner == &null {
            // FIXME(diag-table): wants its own code.
            self.sc->diag->report(DiagID::R001E, n->range.start,
                "'Self' used outside of a type body"
            ).first(n->range).emit();
            n->poison();
            return;
        }
        n->canonical = self._self_record(owner);
        if n->canonical == &null {
            // Generic enclosing type: Self is Foo<T...>, dependent.
            self._mark_dependent(n);
        }
    }

    priv fn _current_self_decl(self) -> *Decl {
        if self.selfs.empty() { return &null; }
        return self.selfs[self.selfs.size() - 1];
    }

    /// The record type a type body denotes for itself: Foo for a non-generic
    /// Foo, Foo<T, U> (with its OWN params as the args) for a generic one.
    /// The generic case is dependent by construction and the RecordType
    /// carries that flag through the store's flag absorption.
    priv fn _self_record(self, owner: *Decl) -> *Type {
        var canon = self._representative(owner);
        var gps   = self._generic_params_of(canon);
        var args  = vec::<*Type>();
        for var i: usize = 0; i < gps.size(); ++i {
            var gp = gps[i];
            if gp == &null { continue; }
            args.push_back(self.sc->types->generic_param(canon, gp->index, gp->is_pack));
        }
        return self.sc->types->record(canon, &args);
    }

    // === Generic params =======================================================

    /// A parser-built GenericParamType (only `...T` today). The parser could
    /// not bind it; find the declaring frame by NAME and fill owner+index, then
    /// canonicalize on (owner, index).
    priv fn _resolve_gparam_node(self, n: *GenericParamType) {
        var owner: *Decl = n->owner;
        var index = n->param_index;

        if owner == &null {
            if n->param_name == &null {
                n->poison();
                return;
            }
            var imm = self._name_imm(n->param_name->name);
            var hit = self._lookup_generic(imm);
            if hit.decl == &null {
                var nm = self.sc->ctx->get_spelling(n->param_name->name);
                self.sc->diag->report(DiagID::R001E, n->range.start,
                    f"use of undeclared generic parameter '{nm}\x27"
                ).first(n->range).emit();
                n->poison();
                return;
            }
            owner = hit.owner;
            index = hit.decl->index;
            n->owner       = owner;
            n->param_index = index;
            if hit.decl->is_pack { n->is_pack = true; }
        }

        n->canonical = self.sc->types->generic_param(owner, index, n->is_pack);
        self._mark_dependent(n);
    }

    priv fn _resolve_variadic(self, n: *VariadicPackType) {
        if n->param == &null { n->poison(); return; }
        // The inner GenericParamType was NOT dispatched by the RAV (it is a
        // back-ref, skipped), so resolve it on demand here.
        self.resolve(static_cast::<*Type>(n->param));
        if n->param->is_poisoned() { n->poison(); return; }
        // A pack type in declaration position has no canonical of its own: it
        // is the pack, and identity lives on the GenericParamType it wraps.
        n->canonical = n->param->canonical;
        self._mark_dependent(n);
        n->type_flags = static_cast::<Type::TypeFlags>(
            static_cast::<u8>(n->type_flags)
          | static_cast::<u8>(Type::TypeFlags::ContainsUnexpandedPack));
    }

    priv fn _resolve_pack_expansion(self, n: *PackExpansionType) {
        if n->pattern == &null { n->poison(); return; }
        if n->pattern->is_poisoned() { n->poison(); return; }
        // Expansion produces N types, not one; there is no single canonical
        // until instantiation. Dependent, unexpanded-pack bit CLEARED (this
        // node consumed it), exactly as create() set up.
        self._mark_dependent(n);
    }

    /// \class GenericHit
    /// \brief Result of a frame lookup: the param and the decl that owns it.
    class GenericHit {
        pub var decl:  *GenericParamDecl = &null;
        pub var owner: *Decl             = &null;
        fn GenericHit(self) { }
    }

    /// Innermost frame first: a method's `<T>` shadows its class's `<T>`.
    priv fn _lookup_generic(self, imm: u32) -> GenericHit {
        var out = GenericHit{};
        if imm == u32(-1) { return out; }
        var n = self.frames.size();
        for var i: usize = 0; i < n; ++i {
            var fr = &(self.frames[(n - 1) - i]);
            for var j: usize = 0; j < fr->params.size(); ++j {
                var gp = fr->params[j];
                if gp == &null { continue; }
                if self.sc->ctx->get_ident_imm(gp->name) == imm {
                    out.decl  = gp;
                    out.owner = fr->owner;
                    return out;
                }
            }
        }
        return out;
    }

    /// The decl that owns \p gp, found through the frames (the primary is on
    /// the stack when its own default is being resolved). Null if not framed.
    priv fn _frame_owner_of(self, gp: *GenericParamDecl) -> *Decl {
        for var i: usize = 0; i < self.frames.size(); ++i {
            var fr = &(self.frames[i]);
            for var j: usize = 0; j < fr->params.size(); ++j {
                if fr->params[j] == gp { return fr->owner; }
            }
        }
        return &null;
    }

    // === ChainType: the real work ============================================

    priv fn _resolve_chain(self, ct: *ChainType) {
        var n = ct->segments.size();
        if n == 0 { ct->poison(); return; }

        var seg0 = ct->segments.get(0);
        if (seg0 == &null) || (seg0->name == &null) { ct->poison(); return; }

        var tok = seg0->name->name;

        // --- 1. builtins resolve by TOKEN KIND, before any lookup ------------
        // `i32` is AtI32, not an identifier: it is in no table, and a user
        // decl can never shadow it. This is the only place that fact is
        // enforced; everything after this line is name-domain.
        var bk = builtin_for_token(tok.kind);
        if bk != BuiltinKind::COUNT {
            if (n > 1) || (!seg0->generic_args.is_empty()) {
                var sp = builtin_spelling(bk);
                // FIXME(diag-table): wants its own code.
                self.sc->diag->report(DiagID::R001E, ct->range.start,
                    f"'{sp}' is a primitive type; it has no members and takes no generic arguments"
                ).first(ct->range).emit();
                ct->poison();
                return;
            }
            var b = self.sc->builtin(bk);
            seg0->resolved_type = b;
            seg0->seg_kind      = ChainType::SegmentKind::Named;
            ct->canonical       = b;
            return;
        }

        // `self` in type position (KwSelf is in TYPE_TOK_TBL) means Self.
        if tok.kind == TokenKind::KwSelf {
            if n > 1 {
                self.sc->diag->report(DiagID::R001E, ct->range.start,
                    "'self' cannot be qualified in a type; use 'Self::Member' for a nested type"
                ).first(ct->range).emit();
                ct->poison();
                return;
            }
            var owner = self._current_self_decl();
            if owner == &null {
                self.sc->diag->report(DiagID::R001E, ct->range.start,
                    "'self' used as a type outside of a type body"
                ).first(ct->range).emit();
                ct->poison();
                return;
            }
            seg0->resolved_decl = owner;
            ct->canonical = self._self_record(owner);
            if ct->canonical == &null { self._mark_dependent(ct); }
            return;
        }

        // --- 2. head: generic frames, then the DC chain + overlay ------------
        var imm = self._name_imm(tok);
        if imm == u32(-1) { ct->poison(); return; }   // recovery/synthetic name; parser diagnosed.

        var head: *Decl = &null;
        var head_owner: *Decl = &null;   // set iff head is a generic param.

        var gh = self._lookup_generic(imm);
        if gh.decl != &null {
            head       = static_cast::<*Decl>(gh.decl);
            head_owner = gh.owner;
        } else {
            var r = self.sc->lookup.unqualified(self.cur_dc, DeclName::ident(imm));
            if !r.found() {
                var nm = self.sc->ctx->get_spelling(tok);
                self.sc->diag->report(DiagID::R001E, seg0->name->range.start,
                    f"unknown type name '{nm}\x27"
                ).first(seg0->name->range).emit();
                ct->poison();
                return;
            }
            head = self._pick_type_candidate(r, seg0->name);
            if head == &null { ct->poison(); return; }   // diagnosed inside.
        }
        seg0->resolved_decl = head;

        // --- 3. walk `::` segments ------------------------------------------
        var cur       = head;
        var cur_owner = head_owner;
        var went_dependent = false;

        for var i: usize = 1; i < n; ++i {
            var seg = ct->segments.get(i);
            if (seg == &null) || (seg->name == &null) { ct->poison(); return; }

            // `T::Item` / `Foo<T>::Inner`: a member of something we cannot see
            // into until instantiation. Mark and stop; M2 owns it (hard
            // invariant #5: dependent = deferred, not failed).
            var prev = ct->segments.get(i - 1);
            if isa::<GenericParamDecl>(cur) || (!prev->generic_args.is_empty()) {
                seg->seg_kind = ChainType::SegmentKind::Dependent;
                went_dependent = true;
                break;
            }

            var scope = self._scope_of(cur, seg->range);
            if scope == &null {
                if !cur->is_poisoned() {
                    var pnm = self.sc->ctx->get_spelling(prev->name->name);
                    self.sc->diag->report(DiagID::R001E, prev->name->range.start,
                        f"'{pnm}' does not name a scope; '::' can only follow a type, module, or enum"
                    ).first(prev->name->range).emit();
                }
                ct->poison();
                return;
            }

            var simm = self._name_imm(seg->name->name);
            if simm == u32(-1) { ct->poison(); return; }
            var sr = self.sc->lookup.in_context(scope, DeclName::ident(simm));
            if !sr.found() {
                var snm = self.sc->ctx->get_spelling(seg->name->name);
                var pnm = self.sc->ctx->get_spelling(prev->name->name);
                self.sc->diag->report(DiagID::R001E, seg->name->range.start,
                    f"no type named '{snm}' in '{pnm}\x27"
                ).first(seg->name->range).emit();
                ct->poison();
                return;
            }
            cur = self._pick_type_candidate(sr, seg->name);
            if cur == &null { ct->poison(); return; }
            cur_owner = &null;
            seg->resolved_decl = cur;
        }

        if went_dependent {
            self._mark_dependent(ct);
            return;
        }

        // --- 4. the final decl becomes a type --------------------------------
        var last = ct->segments.get(n - 1);
        ct->canonical = self._type_of_decl(ct, cur, cur_owner, last);
        if last->resolved_type == &null { last->resolved_type = ct->canonical; }
    }

    /// A cell in TYPE position: functions/vars are not types, and two type
    /// decls under one name are a redefinition N already reported. Collapse a
    /// redecl chain to its canonical (definition) link.
    priv fn _pick_type_candidate(self, r: SemaLookupResult, at: *NamedIdentExpr) -> *Decl {
        var best: *Decl = &null;
        for var i: usize = 0; i < r.cell->size(); ++i {
            var d = r.cell->get(i);
            if d == &null { continue; }
            if !self._is_type_decl(d) { continue; }
            var rep = self._representative(d);
            if best == &null { best = rep; continue; }
            if best != rep {
                // Two distinct type entities under one name: N(a) diagnosed
                // the redefinition; do not re-report, just pick the first.
                break;
            }
        }
        if best == &null {
            var nm = self.sc->ctx->get_spelling(at->name);
            self.sc->diag->report(DiagID::R001E, at->range.start,
                f"'{nm}' does not name a type"
            ).first(at->range)
             .note(DiagID::R001N, r.cell->get(0)->range.start,
                f"'{nm}' is declared here, but as a value, not a type"
            ).first(r.cell->get(0)->range).emit();
            return &null;
        }
        return best;
    }

    priv fn _is_type_decl(self, d: *Decl) -> bool {
        switch d->kind {
            case DeclKind::ClassDecl        { return true; }
            case DeclKind::StructDecl       { return true; }
            case DeclKind::UnionDecl        { return true; }
            case DeclKind::InterfaceDecl    { return true; }
            case DeclKind::EnumDecl         { return true; }
            case DeclKind::TypeAliasDecl    { return true; }
            case DeclKind::GenericParamDecl { return true; }
            case DeclKind::ModuleDecl       { return true; }   // a scope, not a type; rejected at the END.
            default                         { return false; }
        }
    }

    /// The DeclContext a `::` step looks INTO. Aliases are expanded first
    /// (NameLookup::context_of returns null for them on purpose; expansion is
    /// T's job and this is where it happens).
    priv fn _scope_of(self, d: *Decl, at: SourceRange) -> *DeclContext {
        if d == &null { return &null; }
        if isa::<TypeAliasDecl>(d) {
            var c = self._expand_alias(cast::<TypeAliasDecl>(d), at);
            if c == &null { return &null; }
            if !isa::<RecordType>(c) { return &null; }
            return NameLookup::context_of(cast::<RecordType>(c)->decl);
        }
        return NameLookup::context_of(d);
    }

    /// Turn the decl the final segment bound to into a canonical type,
    /// checking whatever the decl kind demands.
    priv fn _type_of_decl(self, ct: *ChainType, d: *Decl, gowner: *Decl, seg: *ChainType::ChainSegment) -> *Type {
        if d == &null { ct->poison(); return &null; }

        // -- generic parameter ------------------------------------------------
        if isa::<GenericParamDecl>(d) {
            var gp = cast::<GenericParamDecl>(d);
            if !seg->generic_args.is_empty() {
                var nm = self.sc->ctx->get_spelling(gp->name);
                self.sc->diag->report(DiagID::R001E, seg->range.start,
                    f"generic parameter '{nm}' cannot itself take generic arguments"
                ).first(seg->range).emit();
                ct->poison();
                return &null;
            }
            if gp->is_const_param {
                var nm = self.sc->ctx->get_spelling(gp->name);
                self.sc->diag->report(DiagID::R001E, seg->range.start,
                    f"'{nm}' is a value parameter and cannot be used as a type"
                ).first(seg->range)
                 .note(DiagID::R001N, gp->range.start, "declared as a const generic parameter here")
                 .first(gp->range).emit();
                ct->poison();
                return &null;
            }
            self._mark_dependent(ct);
            if gp->is_pack {
                ct->type_flags = static_cast::<Type::TypeFlags>(
                    static_cast::<u8>(ct->type_flags)
                  | static_cast::<u8>(Type::TypeFlags::ContainsUnexpandedPack));
            }
            return self.sc->types->generic_param(gowner, gp->index, gp->is_pack);
        }

        // -- module: a scope, never a type ------------------------------------
        if isa::<ModuleDecl>(d) {
            var nm = self.sc->ctx->get_spelling(cast::<ModuleDecl>(d)->name);
            self.sc->diag->report(DiagID::R001E, seg->range.start,
                f"'{nm}' is a module, not a type"
            ).first(seg->range).emit();
            ct->poison();
            return &null;
        }

        // -- alias --------------------------------------------------------------
        if isa::<TypeAliasDecl>(d) {
            var td  = cast::<TypeAliasDecl>(d);
            var gps = td->generic_params;
            if gps.size() > 0 {
                // Generic alias APPLICATION needs substitution of the aliased
                // body -- M2's machinery. Check arity now (that is T's), then
                // hand off as instantiation-dependent. Not an error.
                if !self._check_arity(d, gps, seg, ct) { return &null; }
                if !self._resolve_args(seg, ct) { return &null; }
                self._mark_inst_dependent(ct);
                return &null;
            }
            if !seg->generic_args.is_empty() {
                var nm = self.sc->ctx->get_spelling(td->name);
                self.sc->diag->report(DiagID::R001E, seg->range.start,
                    f"type alias '{nm}' is not generic and takes no arguments"
                ).first(seg->range)
                 .note(DiagID::R001N, td->range.start, "declared here").first(td->range).emit();
                ct->poison();
                return &null;
            }
            var c = self._expand_alias(td, seg->range);
            if c == &null {
                if self.sc->rstate.decl_state(td) == ResolveState::Errored {
                    ct->poison();
                } else if td->aliased != &null {
                    // Alias of a dependent type: inherit.
                    ct->type_flags = static_cast::<Type::TypeFlags>(
                        static_cast::<u8>(ct->type_flags) | static_cast::<u8>(td->aliased->type_flags));
                }
            }
            return c;
        }

        // -- nominal types --------------------------------------------------------
        var canon = self._representative(d);
        var gps   = self._generic_params_of(canon);

        if !self._check_arity(canon, gps, seg, ct) { return &null; }

        var args = vec::<*Type>();
        if !self._collect_args(seg, ct, gps, &args) { return &null; }

        // Any dependent argument makes the instance dependent; the store
        // absorbs the flags, but the SYNTAX node needs them too so parents
        // inherit correctly.
        for var i: usize = 0; i < args.size(); ++i {
            ct->type_flags = static_cast::<Type::TypeFlags>(
                static_cast::<u8>(ct->type_flags) | static_cast::<u8>(args[i]->type_flags));
        }
        return self.sc->types->record(canon, &args);
    }

    // === Generic arguments ====================================================

    /// Arity against the primary's parameter list: at least the required
    /// count (no default, not a pack), at most the total unless a pack makes
    /// it unbounded. Named args are counted, not positioned -- positioning is
    /// _collect_args' job.
    priv fn _check_arity(self, d: *Decl, gps: FrozenList::<*GenericParamDecl>,
                         seg: *ChainType::ChainSegment, ct: *ChainType) -> bool {
        var given = seg->generic_args.size();
        var total = gps.size();
        var required: usize = 0;
        var has_pack = false;
        for var i: usize = 0; i < total; ++i {
            var gp = gps[i];
            if gp == &null { continue; }
            if gp->is_pack { has_pack = true; continue; }
            if gp->default_type == &null { required += 1; }
        }

        if (given == 0) && (total == 0) { return true; }

        var nm = self._decl_name_str(d);
        if (given > 0) && (total == 0) {
            self.sc->diag->report(DiagID::R001E, seg->range.start,
                f"'{nm}' is not generic and takes no generic arguments"
            ).first(seg->range)
             .note(DiagID::R001N, d->range.start, "declared here").first(d->range).emit();
            ct->poison();
            return false;
        }
        if given < required {
            self.sc->diag->report(DiagID::R001E, seg->range.start,
                f"'{nm}' requires at least {required} generic argument(s), but {given} were given"
            ).first(seg->range)
             .note(DiagID::R001N, d->range.start, "declared here").first(d->range).emit();
            ct->poison();
            return false;
        }
        if (!has_pack) && (given > total) {
            self.sc->diag->report(DiagID::R001E, seg->range.start,
                f"'{nm}' takes at most {total} generic argument(s), but {given} were given"
            ).first(seg->range)
             .note(DiagID::R001N, d->range.start, "declared here").first(d->range).emit();
            ct->poison();
            return false;
        }
        return true;
    }

    /// Resolve every argument type in place (they were already dispatched by
    /// the RAV; this reads the outcome). False if any is poisoned.
    priv fn _resolve_args(self, seg: *ChainType::ChainSegment, ct: *ChainType) -> bool {
        for var i: usize = 0; i < seg->generic_args.size(); ++i {
            var a = seg->generic_args.get(i);
            if a->ty == &null { continue; }
            self.resolve(a->ty);
            if a->ty->is_poisoned() { ct->poison(); return false; }
        }
        return true;
    }

    /// Positional + named args into parameter order, defaults filled, pack
    /// tail gathered. Out: one canonical per NON-pack param slot, then the
    /// pack's args flat (the store keys on the whole vector; a pack of two is
    /// two entries). Named args that name nothing, or name a slot twice, are
    /// errors here.
    priv fn _collect_args(self, seg: *ChainType::ChainSegment, ct: *ChainType,
                          gps: FrozenList::<*GenericParamDecl>, out: *vec::<*Type>) -> bool {
        if !self._resolve_args(seg, ct) { return false; }

        var total = gps.size();
        var slots = vec::<*Type>();
        var filled = vec::<bool>();
        var pack_index: usize = usize(-1);
        for var i: usize = 0; i < total; ++i {
            slots.push_back(&null);
            filled.push_back(false);
            if (gps[i] != &null) && gps[i]->is_pack && (pack_index == usize(-1)) { pack_index = i; }
        }
        var pack_args = vec::<*Type>();

        var pos: usize = 0;
        for var i: usize = 0; i < seg->generic_args.size(); ++i {
            var a = seg->generic_args.get(i);
            var cty: *Type = &null;
            if a->ty != &null { cty = self._arg_canonical(a->ty); }

            if a->name != &null {
                var nimm = self._name_imm(a->name->name);
                var found = usize(-1);
                for var j: usize = 0; j < total; ++j {
                    if (gps[j] != &null) && (self.sc->ctx->get_ident_imm(gps[j]->name) == nimm) { found = j; break; }
                }
                if found == usize(-1) {
                    var nm = self.sc->ctx->get_spelling(a->name->name);
                    self.sc->diag->report(DiagID::R001E, a->name_range.start,
                        f"no generic parameter named '{nm}\x27"
                    ).first(a->name_range).emit();
                    ct->poison();
                    return false;
                }
                if filled[found] {
                    var nm = self.sc->ctx->get_spelling(a->name->name);
                    self.sc->diag->report(DiagID::R001E, a->name_range.start,
                        f"generic argument '{nm}' specified more than once"
                    ).first(a->name_range).emit();
                    ct->poison();
                    return false;
                }
                slots[found]  = cty;
                filled[found] = true;
                continue;
            }

            // positional: into the pack once we reach it, else next free slot.
            if (pack_index != usize(-1)) && (pos >= pack_index) {
                pack_args.push_back(cty);
                continue;
            }
            if pos >= total {
                // arity check already bounded this; defensive.
                ct->poison();
                return false;
            }
            slots[pos]  = cty;
            filled[pos] = true;
            pos += 1;
        }

        // defaults + emit
        for var i: usize = 0; i < total; ++i {
            var gp = gps[i];
            if gp == &null { continue; }
            if gp->is_pack {
                for var k: usize = 0; k < pack_args.size(); ++k {
                    if pack_args[k] == &null { ct->poison(); return false; }
                    out->push_back(pack_args[k]);
                }
                continue;
            }
            if !filled[i] {
                if gp->default_type == &null { ct->poison(); return false; }   // arity said otherwise; defensive.
                // A default lives on the PRIMARY and may mention the primary's
                // own params. Substituting those is M2's job, so a default that
                // is dependent (or not yet resolvable) makes the instance
                // instantiation-dependent rather than erroring.
                var dc = self._demand_in_scope_of(gp->default_type, static_cast::<*Decl>(gp));
                if dc == &null {
                    self._mark_inst_dependent(ct);
                    out->push_back(self.sc->types->generic_param(self._frame_owner_of(gp), gp->index, false));
                    continue;
                }
                out->push_back(dc);
                continue;
            }
            if slots[i] == &null { ct->poison(); return false; }
            out->push_back(slots[i]);
        }
        return true;
    }

    /// The canonical of an argument, or null. A dependent argument is fine
    /// (the instance is then dependent); a poisoned one already poisoned ct.
    priv fn _arg_canonical(self, t: *Type) -> *Type {
        if t == &null { return &null; }
        if t->canonical != &null { return t->canonical; }
        if t->is_dependent() {
            // Represent a dependent arg by ITS canonical if it has one
            // (GenericParamType does); a raw dependent composite has none and
            // the instance cannot be keyed -- fall back to marking.
            return &null;
        }
        return &null;
    }

    /// Resolve a node that lives on ANOTHER decl (a default type on an
    /// imported primary), with cur_dc pointed at that decl's home. Returns
    /// canonical or null.
    priv fn _demand_in_scope_of(self, t: *Type, owner: *Decl) -> *Type {
        if t == &null { return &null; }
        if self.sc->rstate.type_done(t) { return t->canonical; }
        var saved_dc = self.cur_dc;
        var saved_frames = self.frames;
        if (owner != &null) && (owner->semantic_dc != &null) {
            self.cur_dc = reinterpret_cast::<*DeclContext>(owner->semantic_dc);
        }
        self.dispatch_type(t);
        self.cur_dc = saved_dc;
        self.frames = saved_frames;
        return t->canonical;
    }

    // === Aliases (the demand-driven core) ====================================

    /// Canonical of what \p td names, expanding through any chain of aliases,
    /// or null. Null + Errored state = diagnosed (cycle or bad target).
    /// Null + Resolved state = the target is dependent.
    fn _expand_alias(self, td: *TypeAliasDecl, at: SourceRange) -> *Type {
        var st = self.sc->rstate.decl_state(td);
        if st == ResolveState::Resolved {
            if td->aliased == &null { return &null; }
            return td->aliased->canonical;
        }
        if st == ResolveState::Errored { return &null; }
        if st == ResolveState::InProgress {
            self._report_alias_cycle(td, at);
            return &null;
        }
        if self.sc->rstate.at_depth_limit() {
            var nm = self.sc->ctx->get_spelling(td->name);
            self.sc->diag->report(DiagID::R001E, at.start,
                f"type alias '{nm}' nests deeper than the limit ({self.sc->rstate.max_depth()}); "
                "raise it with --cmax-scope-depth or flatten the alias chain"
            ).first(at).emit();
            self.sc->rstate.set_decl_state(td, ResolveState::Errored);
            return &null;
        }

        if td->aliased == &null {
            // Index-mode node or parse recovery; parser diagnosed.
            self.sc->rstate.set_decl_state(td, ResolveState::Errored);
            return &null;
        }

        if !self.sc->rstate.begin_decl(td, at) { return &null; }

        // Resolve in the ALIAS's scope, not the use site's: `type X = Inner`
        // inside module M means M::Inner regardless of who wrote `X`.
        var saved_dc     = self.cur_dc;
        var saved_frames = self.frames;
        var saved_selfs  = self.selfs;
        if td->semantic_dc != &null {
            self.cur_dc = reinterpret_cast::<*DeclContext>(td->semantic_dc);
        }
        self.frames.clear();
        if td->generic_params.size() > 0 {
            var fr = GenericFrame{};
            fr.owner  = static_cast::<*Decl>(td);
            fr.params = td->generic_params;
            self.frames.push_back(fr);
        }
        // Self inside an alias body is the alias's ENCLOSING type, if any.
        self.selfs.clear();
        self._push_enclosing_selfs(self.cur_dc);

        self.dispatch_type(td->aliased);

        self.cur_dc = saved_dc;
        self.frames = saved_frames;
        self.selfs  = saved_selfs;

        var ok = !td->aliased->is_poisoned();
        if !ok { td->poison(); }
        self.sc->rstate.finish_decl(static_cast::<*Decl>(td), ok);
        return (td->aliased->canonical) if (ok) else (&null);
    }

    /// One error at the use that closed the loop, one note per link, in the
    /// order the resolver walked them. Every decl on the loop is marked
    /// Errored so no other use of any of them reports again.
    priv fn _report_alias_cycle(self, td: *TypeAliasDecl, at: SourceRange) {
        var idx = self.sc->rstate.cycle_index(static_cast::<*Decl>(td));
        var nm  = self.sc->ctx->get_spelling(td->name);

        var b = self.sc->diag->report(DiagID::R001E, at.start,
            f"type alias '{nm}' is defined in terms of itself"
        );
        b.first(at);

        if idx != usize(-1) {
            var stack = &(self.sc->rstate.stack);
            for var i: usize = idx; i < stack->size(); ++i {
                var fr = (*stack)[i];
                if fr.decl == &null { continue; }
                var lnm = self._decl_name_str(fr.decl);
                b.note(DiagID::R001N, fr.decl->range.start,
                    f"'{lnm}' is declared here and refers to the next alias in the cycle"
                ).first(fr.decl->range);
                fr.decl->poison();
                self.sc->rstate.set_decl_state(fr.decl, ResolveState::Errored);
            }
        }
        b.emit();
        td->poison();
        self.sc->rstate.set_decl_state(static_cast::<*Decl>(td), ResolveState::Errored);
    }

    // === Scope cursor management (mirrors NameResolution) =====================

    fn traverse_function_decl(self, n: *FunctionDecl) -> *FunctionDecl {
        if n == &null { return n; }

        var saved_dc = self.cur_dc;
        if (n->semantic_dc != &null) && (n->semantic_dc != n->lexical_dc) {
            self.cur_dc = reinterpret_cast::<*DeclContext>(n->semantic_dc);
        } else {
            self.cur_dc = static_cast::<*DeclContext>(n);
        }

        // An out-of-line method's Self is the class it was written FOR.
        var pushed_self = false;
        if (n->semantic_dc != &null) && (n->semantic_dc != n->lexical_dc) {
            var home = reinterpret_cast::<*DeclContext>(n->semantic_dc);
            if home->is_type_scope() && (home->owner_decl() != &null) {
                self.selfs.push_back(self._representative(home->owner_decl()));
                pushed_self = true;
            }
        }

        self._push_frame(static_cast::<*Decl>(n), n->generic_params);

        // The `self` receiver has no written type (ParamDecl::create_self). T
        // is the one writer of ParamDecl::type_ for it: a SelfType node whose
        // canonical is the enclosing record. This is what lets N bind
        // `self.x` without asking T a question at every use.
        self._synthesize_receiver(n);

        // #68: spec args on a `<> f<...>` head are types to resolve; on a
        // Primary-classified head with NO bound params they DECLARE params
        // and must not be looked up. Pre-mark them done so dispatch skips.
        self._premark_primary_spec_args(n->spec_kind, n->generic_params, n->spec_args);

        var out = RecursiveASTVisitor_TypeResolution::traverse_function_decl(n);

        self._refine_spec_kind(static_cast::<*Decl>(n), n->generic_params, n->spec_args);

        self._pop_frame();
        if pushed_self { self.selfs.pop_back(); }
        self.cur_dc = saved_dc;
        return out;
    }

    fn traverse_closure_expr(self, n: *ClosureExpr) -> *ClosureExpr {
        if n == &null { return n; }
        self._push_frame(&null, n->generic_params);
        var out = RecursiveASTVisitor_TypeResolution::traverse_closure_expr(n);
        self._pop_frame();
        return out;
    }

    fn traverse_class_decl(self, n: *ClassDecl) -> *ClassDecl {
        if n == &null { return n; }
        var saved = self.cur_dc;
        self.cur_dc = static_cast::<*DeclContext>(n);
        self.selfs.push_back(self._representative(static_cast::<*Decl>(n)));
        self._push_frame(static_cast::<*Decl>(n), n->generic_params);
        self._premark_primary_spec_args(n->spec_kind, n->generic_params, n->spec_args);
        var out = RecursiveASTVisitor_TypeResolution::traverse_class_decl(n);
        self._refine_spec_kind(static_cast::<*Decl>(n), n->generic_params, n->spec_args);
        self._pop_frame();
        self.selfs.pop_back();
        self.cur_dc = saved;
        return out;
    }

    fn traverse_struct_decl(self, n: *StructDecl) -> *StructDecl {
        if n == &null { return n; }
        var saved = self.cur_dc;
        self.cur_dc = static_cast::<*DeclContext>(n);
        self.selfs.push_back(self._representative(static_cast::<*Decl>(n)));
        self._push_frame(static_cast::<*Decl>(n), n->generic_params);
        self._premark_primary_spec_args(n->spec_kind, n->generic_params, n->spec_args);
        var out = RecursiveASTVisitor_TypeResolution::traverse_struct_decl(n);
        self._refine_spec_kind(static_cast::<*Decl>(n), n->generic_params, n->spec_args);
        self._pop_frame();
        self.selfs.pop_back();
        self.cur_dc = saved;
        return out;
    }

    fn traverse_union_decl(self, n: *UnionDecl) -> *UnionDecl {
        if n == &null { return n; }
        var saved = self.cur_dc;
        self.cur_dc = static_cast::<*DeclContext>(n);
        self.selfs.push_back(self._representative(static_cast::<*Decl>(n)));
        self._push_frame(static_cast::<*Decl>(n), n->generic_params);
        self._premark_primary_spec_args(n->spec_kind, n->generic_params, n->spec_args);
        var out = RecursiveASTVisitor_TypeResolution::traverse_union_decl(n);
        self._refine_spec_kind(static_cast::<*Decl>(n), n->generic_params, n->spec_args);
        self._pop_frame();
        self.selfs.pop_back();
        self.cur_dc = saved;
        return out;
    }

    fn traverse_interface_decl(self, n: *InterfaceDecl) -> *InterfaceDecl {
        if n == &null { return n; }
        var saved = self.cur_dc;
        self.cur_dc = static_cast::<*DeclContext>(n);
        self.selfs.push_back(self._representative(static_cast::<*Decl>(n)));
        self._push_frame(static_cast::<*Decl>(n), n->generic_params);
        var out = RecursiveASTVisitor_TypeResolution::traverse_interface_decl(n);
        self._pop_frame();
        self.selfs.pop_back();
        self.cur_dc = saved;
        return out;
    }

    fn traverse_enum_decl(self, n: *EnumDecl) -> *EnumDecl {
        if n == &null { return n; }
        var saved = self.cur_dc;
        self.cur_dc = static_cast::<*DeclContext>(n);
        self.selfs.push_back(self._representative(static_cast::<*Decl>(n)));
        self._push_frame(static_cast::<*Decl>(n), n->generic_params);
        var out = RecursiveASTVisitor_TypeResolution::traverse_enum_decl(n);
        self._check_enum_underlying(n);
        self._pop_frame();
        self.selfs.pop_back();
        self.cur_dc = saved;
        return out;
    }

    /// `extend Foo<T> { }`: the target is resolved FIRST, in the enclosing
    /// scope (its own params in frame), and then becomes Self for the body.
    fn traverse_extension_decl(self, n: *ExtensionDecl) -> *ExtensionDecl {
        if n == &null { return n; }
        var saved = self.cur_dc;

        self._push_frame(static_cast::<*Decl>(n), n->generic_params);
        if n->target != &null { self.dispatch_type(n->target); }

        var pushed = false;
        if (n->target != &null) && (n->target->canonical != &null) && isa::<RecordType>(n->target->canonical) {
            self.selfs.push_back(cast::<RecordType>(n->target->canonical)->decl);
            pushed = true;
        } else if (n->target != &null) && (!n->target->is_poisoned()) && (!n->target->is_dependent()) {
            self.sc->diag->report(DiagID::R001E, n->target->range.start,
                "'extend' target must be a class, struct, union, enum, or interface"
            ).first(n->target->range).emit();
            n->target->poison();
            n->poison();
        }

        self.cur_dc = static_cast::<*DeclContext>(n);
        var out = RecursiveASTVisitor_TypeResolution::traverse_extension_decl(n);

        if pushed { self.selfs.pop_back(); }
        self._pop_frame();
        self.cur_dc = saved;
        return out;
    }

    fn traverse_module_decl(self, n: *ModuleDecl) -> *ModuleDecl {
        if n == &null { return n; }
        var saved = self.cur_dc;
        if !n->is_anonymous { self.cur_dc = static_cast::<*DeclContext>(n); }
        var out = RecursiveASTVisitor_TypeResolution::traverse_module_decl(n);
        self.cur_dc = saved;
        return out;
    }

    /// Route the whole-TU walk through the same demand path a use would take,
    /// so the alias's state is consistent however it is first reached.
    fn traverse_type_alias_decl(self, n: *TypeAliasDecl) -> *TypeAliasDecl {
        if n == &null { return n; }
        if self.dyn()->walkup_type_alias_decl(n) == false { return n; }
        // requires_clause + generic param bounds walk normally; the body goes
        // through _expand_alias (which sets up the frame itself).
        self._push_frame(static_cast::<*Decl>(n), n->generic_params);
        for var i: usize = 0; i < n->generic_params.size(); ++i {
            self.dyn()->dispatch_decl(*(n->generic_params.get(i)));
        }
        if n->requires_clause != &null { n->requires_clause = self.dyn()->dispatch_expr(n->requires_clause); }
        self._pop_frame();
        self._expand_alias(n, n->range);
        return n;
    }

    // --- frame helpers ----------------------------------------------------------

    priv fn _push_frame(self, owner: *Decl, params: FrozenList::<*GenericParamDecl>) {
        var fr = GenericFrame{};
        fr.owner  = owner;
        fr.params = params;
        self.frames.push_back(fr);
    }

    priv fn _pop_frame(self) {
        if !self.frames.empty() { self.frames.pop_back(); }
    }

    /// Walk outward from \p dc pushing every enclosing type scope's decl,
    /// outermost first, so the innermost lands at the top.
    priv fn _push_enclosing_selfs(self, dc: *DeclContext) {
        var chain = vec::<*Decl>();
        var c = dc;
        while c != &null {
            if c->is_type_scope() && (c->owner_decl() != &null) {
                chain.push_back(self._representative(c->owner_decl()));
            }
            c = c->dc_parent;
        }
        var n = chain.size();
        for var i: usize = 0; i < n; ++i { self.selfs.push_back(chain[(n - 1) - i]); }
    }

    // === Receiver synthesis ===================================================

    priv fn _synthesize_receiver(self, f: *FunctionDecl) {
        var owner = self._current_self_decl();
        for var i: usize = 0; i < f->params.size(); ++i {
            var p = f->params[i];
            if p == &null { continue; }
            if !p->is_self { continue; }
            if p->type_ != &null { continue; }   // idempotent re-run.
            if owner == &null { continue; }      // free fn with self: N diagnosed.

            var st = SelfType::create(self.sc->ctx, p->range);
            st->canonical = self._self_record(owner);
            if st->canonical == &null { self._mark_dependent(st); }
            // Record the outcome so the RAV's later visit of this ParamDecl
            // (it dispatches type_) finds it done rather than re-resolving.
            self.sc->rstate.set_type_state(st, ResolveState::Resolved);
            if st->canonical != &null { self.n_canonical += 1; } else { self.n_dependent += 1; }
            p->type_ = st;
        }
    }

    // === #68: specialization refinement ========================================

    priv fn _premark_primary_spec_args(self, kind: SpecKind,
                                       gps: FrozenList::<*GenericParamDecl>,
                                       args: FrozenList::<*Type>) {
        if kind != SpecKind::Primary { return; }
        if gps.size() > 0 { return; }   // `<P> Box<P>`: P IS bound; resolve normally.
        // `<> Box<T>`: T declares. Nothing to resolve; do not look it up.
        for var i: usize = 0; i < args.size(); ++i {
            var a = args[i];
            if a == &null { continue; }
            self.sc->rstate.set_type_state(a, ResolveState::Resolved);
            self._mark_dependent(a);
        }
    }

    /// The parser could only say "all simple idents" (Primary candidate).
    /// After resolution: every arg bound to a type variable of the head ->
    /// stays Primary; any arg bound to a concrete type -> Explicit. This is
    /// the name-resolution fact the parser deferred to sema (#68).
    priv fn _refine_spec_kind(self, d: *Decl, gps: FrozenList::<*GenericParamDecl>,
                              args: FrozenList::<*Type>) {
        var kind = self._spec_kind_of(d);
        if kind != SpecKind::Primary { return; }
        if gps.size() == 0 { return; }   // `<> Box<T>` stays Primary by construction.
        var concrete = false;
        for var i: usize = 0; i < args.size(); ++i {
            var a = args[i];
            if a == &null { continue; }
            if !isa::<ChainType>(a) { concrete = true; break; }
            var ct = cast::<ChainType>(a);
            var seg = ct->segments.get(0);
            if (seg == &null) || (seg->resolved_decl == &null) { continue; }
            if !isa::<GenericParamDecl>(seg->resolved_decl) { concrete = true; break; }
        }
        if concrete { self._set_spec_kind(d, SpecKind::Explicit); }
    }

    priv fn _spec_kind_of(self, d: *Decl) -> SpecKind {
        if isa::<FunctionDecl>(d) { return cast::<FunctionDecl>(d)->spec_kind; }
        if isa::<ClassDecl>(d)    { return cast::<ClassDecl>(d)->spec_kind;    }
        if isa::<StructDecl>(d)   { return cast::<StructDecl>(d)->spec_kind;   }
        if isa::<UnionDecl>(d)    { return cast::<UnionDecl>(d)->spec_kind;    }
        return SpecKind::None;
    }

    priv fn _set_spec_kind(self, d: *Decl, k: SpecKind) {
        if isa::<FunctionDecl>(d) { cast::<FunctionDecl>(d)->spec_kind = k; return; }
        if isa::<ClassDecl>(d)    { cast::<ClassDecl>(d)->spec_kind    = k; return; }
        if isa::<StructDecl>(d)   { cast::<StructDecl>(d)->spec_kind   = k; return; }
        if isa::<UnionDecl>(d)    { cast::<UnionDecl>(d)->spec_kind    = k; return; }
    }

    // === Enum underlying ========================================================

    priv fn _check_enum_underlying(self, n: *EnumDecl) {
        if n->underlying == &null { return; }
        var c = n->underlying->canonical;
        if c == &null { return; }   // poisoned or dependent; already handled.
        if isa::<BuiltinType>(c) && builtin_is_integer(cast::<BuiltinType>(c)->builtin) { return; }
        self.sc->diag->report(DiagID::R001E, n->underlying->range.start,
            "an enum's underlying type must be a primitive integer type"
        ).first(n->underlying->range).emit();
        n->underlying->poison();
    }

    // === Decl helpers ===========================================================

    /// Same rule as NameResolution::_chain_canonical: the redecl chain's
    /// canonical (the definition once N(a) retargeted it), or the decl itself
    /// for non-redeclarable kinds. Duplicated rather than shared because
    /// passes may not import each other; the third copy should move it onto
    /// NameLookup.
    priv fn _representative(self, d: *Decl) -> *Decl {
        if d == &null { return &null; }
        if isa::<ClassDecl>(d)     { return static_cast::<*Decl>(cast::<ClassDecl>(d)->canonical_decl());     }
        if isa::<StructDecl>(d)    { return static_cast::<*Decl>(cast::<StructDecl>(d)->canonical_decl());    }
        if isa::<UnionDecl>(d)     { return static_cast::<*Decl>(cast::<UnionDecl>(d)->canonical_decl());     }
        if isa::<InterfaceDecl>(d) { return static_cast::<*Decl>(cast::<InterfaceDecl>(d)->canonical_decl()); }
        if isa::<EnumDecl>(d)      { return static_cast::<*Decl>(cast::<EnumDecl>(d)->canonical_decl());      }
        if isa::<ModuleDecl>(d)    { return static_cast::<*Decl>(cast::<ModuleDecl>(d)->canonical_decl());    }
        return d;
    }

    priv fn _generic_params_of(self, d: *Decl) -> FrozenList::<*GenericParamDecl> {
        if d == &null { return create_empty_frozen_list::<*GenericParamDecl>(); }
        if isa::<ClassDecl>(d)     { return cast::<ClassDecl>(d)->generic_params;     }
        if isa::<StructDecl>(d)    { return cast::<StructDecl>(d)->generic_params;    }
        if isa::<UnionDecl>(d)     { return cast::<UnionDecl>(d)->generic_params;     }
        if isa::<InterfaceDecl>(d) { return cast::<InterfaceDecl>(d)->generic_params; }
        if isa::<EnumDecl>(d)      { return cast::<EnumDecl>(d)->generic_params;      }
        if isa::<TypeAliasDecl>(d) { return cast::<TypeAliasDecl>(d)->generic_params; }
        if isa::<FunctionDecl>(d)  { return cast::<FunctionDecl>(d)->generic_params;  }
        if isa::<ExtensionDecl>(d) { return cast::<ExtensionDecl>(d)->generic_params; }
        return create_empty_frozen_list::<*GenericParamDecl>();
    }

    priv fn _decl_name_str(self, d: *Decl) -> string {
        if d == &null { return "<null>"; }
        if isa::<ClassDecl>(d)        { return self.sc->ctx->get_spelling(cast::<ClassDecl>(d)->name);        }
        if isa::<StructDecl>(d)       { return self.sc->ctx->get_spelling(cast::<StructDecl>(d)->name);       }
        if isa::<UnionDecl>(d)        { return self.sc->ctx->get_spelling(cast::<UnionDecl>(d)->name);        }
        if isa::<InterfaceDecl>(d)    { return self.sc->ctx->get_spelling(cast::<InterfaceDecl>(d)->name);    }
        if isa::<EnumDecl>(d)         { return self.sc->ctx->get_spelling(cast::<EnumDecl>(d)->name);         }
        if isa::<TypeAliasDecl>(d)    { return self.sc->ctx->get_spelling(cast::<TypeAliasDecl>(d)->name);    }
        if isa::<ModuleDecl>(d)       { return self.sc->ctx->get_spelling(cast::<ModuleDecl>(d)->name);       }
        if isa::<FunctionDecl>(d)     { return self.sc->ctx->get_spelling(cast::<FunctionDecl>(d)->name);     }
        if isa::<GenericParamDecl>(d) { return self.sc->ctx->get_spelling(cast::<GenericParamDecl>(d)->name); }
        return "<decl>";
    }

    /// Same keyword handling as N: `self` is KwSelf, not an identifier.
    priv fn _name_imm(self, tok: Token) -> u32 {
        return self.sc->ctx->get_ident_imm(tok);
    }
}