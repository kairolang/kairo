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
///   \par Cross-TU nodes
///     T never dispatches a node it does not own. An imported alias body or
///     a default on an imported primary is READ through its slots; DAG order
///     (CompilerInstance::_sema) is what guarantees those slots are filled.
///     `_foreign` is the gate.
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
import Sema::Resolve::MemberLookup::*;
import Sema::Resolve::ResolutionState::*;
import Sema::Resolve::GenericArgs::*;
import Sema::Check::ConstEval::*;
import Sema::Lower::LowerSynth::*;
import Lexer::Immediate::*;
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
import AST::DeclFacts::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::LangItems::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Kind::TypeKind::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Token::Token::*;
import Token::TokenKind::*;
import Diagnostic::Registry::*;
import AST::Context::InstantiationRegistry::*;
import Sema::Type::ArgumentDeduction::*;
import Sema::Type::PanicSets::*;
import AST::ParamMode::*;
import Sema::Type::TypeUtil::*;
import Sema::Check::EffectPropagation::*;

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

/// One executable-scope frame of T's LOCAL TYPE stack: type decls written at
/// statement scope. They sit in no table (by design) and are not generic
/// params, so neither existing lookup source can find them.
class LocalTypeFrame {
    pub var names: vec::<u32>;
    pub var decls: vec::<*Decl>;
    fn LocalTypeFrame(self) { }
}

/// The resolver's lexical state as it was before _enter_decl_scope; handed
/// back to _leave_decl_scope unchanged.
class SavedDeclScope {
    pub var cur_dc: *DeclContext = &null;
    pub var frames: vec::<GenericFrame>;
    pub var selfs:  vec::<*Type>;
    pub var ltypes: vec::<LocalTypeFrame>;
    fn SavedDeclScope(self) { }
}

///
/// \class TypeResolution
/// \brief The T pass. One instance per TU per run.
///
///        State is three cursors, all save/restored by the traverse_*
///        overrides:
///          cur_dc  -- innermost TABLE-owning scope, for unqualified lookup.
///          frames  -- generic-param frames, innermost last.
///          _selfs   -- what `Self` and the `self` receiver denote in each
///                     enclosing type body, innermost last. A TYPE, not a
///                     decl: a record body is its own record over its own
///                     params, but `extend <T> Wrap<Box<T>>` is Wrap<Box<T>>
///                     and `extend i32` is i32, neither of which a decl can
///                     say.
///
class TypeResolution derives RecursiveASTVisitor::<TypeResolution> {
    pub var sc: *SemaContext;

    var cur_dc: *DeclContext = &null;
    /// Where the out-of-line definition being resolved was WRITTEN, while its
    /// owning scope (cur_dc) lives in another TU; null otherwise. Mirrors
    /// NameResolution::_ool_lexical; read by _lookup_unqualified.
    priv var _ool_lexical: *DeclContext = &null;
    var frames: vec::<GenericFrame>;
    var _selfs:  vec::<*Type>;
    var ltypes: vec::<LocalTypeFrame>;

    /// How many alias-through-alias expansions are in flight right now. The
    /// resolution stack cannot answer this: it counts EVERY decl T descends
    /// into, so a two-link alias chain reached from inside a deep generic body
    /// would trip a budget the user set for alias depth alone. Bounded by
    /// sc->opts.max_type_alias_depth (--cmax-type-alias-depth).
    var _alias_depth: usize = 0;

    /// Counters for the driver's summary line.
    pub var n_canonical: usize = 0;
    pub var n_dependent: usize = 0;
    pub var n_errored:   usize = 0;

    fn TypeResolution(self, sc: *SemaContext) {
        self.sc = sc;
    }

    /// > 0 while a generic ARGUMENT is resolved: there a generic value
    /// parameter (`Buf<N>` inside `class <eval N: usize>`) is an argument,
    /// not a misused type (EVAL.md 3).
    priv var _arg_depth: u32 = 0;

    fn traverse_generic_arg(self, a: *ChainType::GenericArg) {
        self._arg_depth += 1;
        RecursiveASTVisitor::<TypeResolution>::traverse_generic_arg(a);
        self._arg_depth -= 1;
    }

    fn traverse_chain_type(self, n: *ChainType) -> *ChainType {
        if self.dyn()->walkup_chain_type(n) == false { return n; }
        for var i: usize = 0; i < n->segments.size(); i++ {
            if self.stop { break; }
            var seg = n->segments.get(i);
            for var j: usize = 0; j < seg->generic_args.size(); j++ {
                if self.stop { break; }
                var arg = seg->generic_args.get(j);
                if arg->ty == &null { continue; }
                self._arg_depth += 1;
                self.dyn()->dispatch_type(arg->ty);
                self._arg_depth -= 1;
            }
        }
        return n;
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
        self._register_specs_in(static_cast::<*DeclContext>(tu));

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
        var out = RecursiveASTVisitor::<TypeResolution>::dispatch_type(e);
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
            case TypeKind::QualifiedType         { 0; }   // canonical by construction.
            case TypeKind::InferredType          { 0; }   // TypeInference owns; no canonical here.
            case TypeKind::TypeOfType            { self._mark_inst_dependent(t); }   // needs expr typing.
            case TypeKind::TypeExpr              { self._resolve_value_arg(cast::<TypeExpr>(t)); }
            default                              { 0; }
        }

        // The written cv-qualifiers, onto the canonical. Every kind but
        // four: a canonical carries its own; a reference cannot be
        // qualified (`const T&` qualifies the REFEREE, and the ref arms do
        // that themselves); and a function type's remaining qualifiers are
        // effects, which are not cv.
        if (t->canonical != &null) && (!t->is_poisoned()) {
            var k = t->kind;
            if (k != TypeKind::QualifiedType)
            && (k != TypeKind::CXXLValueRefType) && (k != TypeKind::CXXRValueRefType)
            && (k != TypeKind::FunctionPointerType) {
                var q = self._canon_quals(t);
                if q != 0 { t->canonical = self.sc->types->qualified(t->canonical, q); }
            }
        }

        // The written effect qualifiers are sugar for a DECLARED type, as
        // `[T]` is for Vector: `yield T` is Yield<T>, `async T` is Future<T>.
        // Without this the canonical was the bare T, so `upto(5)` typed as
        // i32 and `g.next()` / `g.current()` were R025E on it. Only the
        // written qualifier lowers; the frame and ReturnPathCheck still read
        // it off the syntax node (TypeUtil::is_generator_return).
        if (t->canonical != &null) && (!t->is_poisoned()) {
            if t->is_yield() || t->is_async() {
                var ek = (WellKnownType::Yield) if (t->is_yield()) else (WellKnownType::Future);
                var ea = vec::<*Type>();
                ea.push_back(t->canonical);
                t->canonical = self._lang_record(t, ek, &ea);
            }
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
        n->canonical = self.sc->types->pointer(n->pointee->canonical, n->is_unsafe);
    }

    priv fn _resolve_nullable(self, n: *NullableType) {
        if !self._component_ok(n, n->inner) { return; }
        n->canonical = self.sc->types->nullable(n->inner->canonical);
    }

    /// The canonical RECORD for a container lang item, or null with \p n
    /// poisoned when the builtin root does not declare it.
    ///
    /// `[T]`, `{T}` and `{K: V}` are sugar for a DECLARED type, so an unbound
    /// item is a real error at the use rather than a quiet fall back to a
    /// structural canonical: the two would be different identities for the
    /// same written type, and the mismatch would surface far from here.
    ///
    /// The unbound item is diagnosed HERE, where there is a written node to
    /// point at; SemaContext::lang_record returns null for it and has no
    /// range of its own. Everything else -- trimming to the arity, and
    /// registering a concrete instance -- is that one builder's, so a written
    /// `[T;]` and one a literal takes are the same canonical.
    priv fn _lang_record(self, n: *Type, k: WellKnownType, args: *vec::<*Type>) -> *Type {
        var d = self.sc->well_known->get(k);
        if d == &null {
            self.sc->diag->report(DiagID::R055E, n->range.start,
                f"lang item '{to_string(k)}' is not declared in the builtin root"
            ).first(n->range).emit();
            n->poison();
            return &null;
        }
        return self.sc->lang_record(k, args);
    }

    priv fn _resolve_vector(self, n: *VectorType) {
        if !self._component_ok(n, n->element) { return; }
        var args = vec::<*Type>();
        args.push_back(n->element->canonical);
        n->canonical = self._lang_record(static_cast::<*Type>(n), WellKnownType::Vector, &args);
    }

    priv fn _resolve_set(self, n: *SetType) {
        if !self._component_ok(n, n->element) { return; }
        var args = vec::<*Type>();
        args.push_back(n->element->canonical);
        n->canonical = self._lang_record(static_cast::<*Type>(n), WellKnownType::HashSet, &args);
    }

    priv fn _resolve_cxx_lref(self, n: *CXXLValueRefType) {
        if !self._component_ok(n, n->referee) { return; }
        // A reference has no cv of its own: `const T&` qualifies the
        // referee. The written qualifier lands there, and resolve()'s
        // central wrap skips reference kinds so it is not applied twice.
        var referee = self.sc->types->qualified(n->referee->canonical, self._canon_quals(n));
        n->canonical = self.sc->types->cxx_lref(referee);
    }

    priv fn _resolve_cxx_rref(self, n: *CXXRValueRefType) {
        if !self._component_ok(n, n->referee) { return; }
        var referee = self.sc->types->qualified(n->referee->canonical, self._canon_quals(n));
        n->canonical = self.sc->types->cxx_rref(referee);
    }

    /// The bits of a syntax node's TypeQual that enter identity. Only
    /// const and volatile: restrict, atomic, eval and the effects are
    /// facts about a declaration or a use, not about which type it is.
    priv fn _canon_quals(self, t: *Type) -> u8 {
        var q: u8 = 0;
        if t->is_const()    { q = q | QUAL_CONST();    }
        if t->is_volatile() { q = q | QUAL_VOLATILE(); }
        return q;
    }

    priv fn _resolve_map(self, n: *MapType) {
        var ok_k = self._component_ok(n, n->key);
        var ok_v = self._component_ok(n, n->value);
        if !(ok_k && ok_v) { return; }
        var args = vec::<*Type>();
        args.push_back(n->key->canonical);
        args.push_back(n->value->canonical);
        n->canonical = self._lang_record(static_cast::<*Type>(n), WellKnownType::HashMap, &args);
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
        // A tuple is its arity's record, `Tuple2<A, B>` (TupleRecords): the
        // one builder every tuple canonical goes through, so this written
        // type and the one a literal takes are one identity.
        var t = self.sc->tuple_record(&elems);
        if t == &null {
            // TypeParse caps arity at the written type (S055E) and a
            // one-element tuple cannot be parsed, so the record is missing
            // only when there is no builtin root to home it in -- the
            // same failure as any unbound lang item.
            self.sc->diag->report(DiagID::R055E, n->range.start,
                f"a tuple of {elems.size()} elements has no record; the builtin root is not loaded"
            ).first(n->range).emit();
            n->poison();
            return;
        }
        n->canonical = t;
    }

    /// `[T; N]` has an identity only once N is a known constant. A literal,
    /// or anything ConstEval folds: an `eval` name, arithmetic over those
    /// (EVAL.md 0.1: an extent is type identity, so Sema computes it). A
    /// length that names a generic value parameter, an eval call or an eval
    /// constant that does not fold is C++'s to compute: its canonical is the
    /// interned expression (EVAL.md 0.2), and EmitPlan defines what it
    /// names ahead of any declaration spelling it (EVAL.md §11). Anything
    /// else is an error here: a `const` name (not eval-able, EVAL.md 3;
    /// fix-it to `eval`), a call of a non-eval fn, or a run-time value. A foreign
    /// header's array is left as it was. `[T;]` (incomplete, C interop)
    /// never has an extent and canonicalizes as extent 0 with the
    /// is_incomplete flag preserved on the SYNTAX node.
    priv fn _resolve_array(self, n: *FixedArrayType) {
        if !self._component_ok(n, n->element) { return; }
        var elem = n->element->canonical;

        if n->is_incomplete {
            // `[T;]` written in a KAIRO file is the Slice lang item. In an
            // FFI-imported header it is C's incomplete array and must stay
            // structural -- rewriting it would stop the imported signature
            // matching the header it came from.
            if (self.sc->tu != &null) && self.sc->tu->is_foreign {
                n->canonical = self.sc->types->array(elem, 0);
                return;
            }
            var sargs = vec::<*Type>();
            sargs.push_back(elem);
            n->canonical = self._lang_record(static_cast::<*Type>(n), WellKnownType::Slice, &sargs);
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

        if (!known) && (n->size_expr != &null) && (self.sc->tu != &null) && (!self.sc->tu->is_foreign) {
            var ce = ConstEval(self.sc);
            var c  = ce.eval_int(n->size_expr);
            if c.ok && (!c.overflow) && (!c.neg) && (ce.const_decl == &null) {
                n->canonical = self.sc->types->array(elem, c.mag);
                return;
            }
            // A value (a `const` read, a negative one) is wrong, not unknown.
            if c.ok || ce.quiet {
                self._bad_extent(n, &ce, c, "an array length");
                n->poison();
                return;
            }
            if self._own_class_constant(n, &ce) {
                n->poison();
                return;
            }
            // Not Sema's to compute (EVAL.md 0.2): a value parameter (`[T;
            // N]`, substituted per instance, EVAL.md 3), an expression over
            // them (`N + 1`), an eval constant that does not fold, an eval
            // call. Its canonical is the interned expression; C++ computes
            // it.
            var vx = self._value_expr(n->size_expr);
            if vx == &null {
                self._report_value(n->size_expr, &ce, c, "an array length");
                n->poison();
                return;
            }
            var vt = dyn_cast::<TypeExpr>(vx);
            if (vt != &null) && vt->is_exact() {
                // Folded here where ConstEval stops (`/`, `%`): a number.
                if vt->vneg {
                    self.sc->diag->report(DiagID::SC001E, n->size_expr->range.start,
                        f"an array length must be a non-negative constant that fits 64 bits; this one is -{vt->vmag}, which is negative"
                    ).first(n->size_expr->range).emit();
                    n->poison();
                    return;
                }
                n->canonical = self.sc->types->array(elem, vt->vmag);
                return;
            }
            if vx->is_dependent() { self._mark_dependent(n); }
            n->canonical = self.sc->types->array_of_param(elem, vx);
            return;
        }

        if !known {
            self._mark_inst_dependent(n);
            return;
        }
        n->canonical = self.sc->types->array(elem, extent);
    }

    /// `[i32; K]` as a field of K's own class, where K's value does not fold
    /// and C++ must compute it (EVAL.md 1.2a): inside its class body K is
    /// declared but the class is incomplete, so it is no constant expression
    /// there, in any C++ version. Reported (SC116E) with a fix-it hoisting K
    /// to module scope. One that folds is spelled as its value and is fine;
    /// a method body is a complete-class context and is fine too.
    priv fn _own_class_constant(self, n: *FixedArrayType, ce: *ConstEval) -> bool {
        if (self._cur_field == &null) || (ce->bad_decl == &null) { return false; }
        var k = dyn_cast::<FieldDecl>(ce->bad_decl);
        if (k == &null) || (!k->is_eval()) { return false; }
        if k->semantic_dc != self._cur_field->semantic_dc { return false; }
        var dc = reinterpret_cast::<*DeclContext>(k->semantic_dc);
        var owner = (dc->owner_decl()) if (dc != &null) else (&null);
        var kn = self.sc->ctx->get_spelling(k->name);
        var on = ("its class") if (owner == &null) else (f"'{ce->tu.decl_name(owner)}\x27");
        var b = self.sc->diag->report(DiagID::SC116E, n->size_expr->range.start,
            f"an array length computed by C++ from '{kn}', an 'eval' constant of the field\x27s own class, is not supported: {on} is incomplete inside its own body");
        b.first(n->size_expr->range);
        b.note(DiagID::SC001N, k->name.range.start,
            f"'{kn}' is declared here; its value is computed by C++, which reads it only once the class is complete").first(k->name.range);
        if (owner != &null) && (k->type_ != &null) && (k->init != &null) && (!self._foreign(static_cast::<*Decl>(k))) {
            var sm = self.sc->ctx->sm;
            var hoist = f"eval {kn}: {sm->get_text(k->type_->range)} = {sm->get_text(k->init->range)}\n";
            b.insert(self._with_vis(owner->range.start), hoist, f"move '{kn}' to module scope, where it is complete before the class");
            b.remove(SourceRange::from_bounds(self._with_vis(k->range.start), k->range.end), f"and remove it from the class");
        }
        b.emit();
        return true;
    }

    /// \p at, or the visibility keyword written right before it: a
    /// declaration's range starts after `pub`, and a fix-it that moves the
    /// declaration must take the keyword along.
    priv fn _with_vis(self, at: SourceLocation) -> SourceLocation {
        var sm = self.sc->ctx->sm;
        var kws = vec::<string>();
        kws.push_back("pub ");
        kws.push_back("priv ");
        kws.push_back("prot ");
        var off = sm->get_offset(at);
        for var i: usize = 0; i < kws.size(); ++i {
            var n = kws[i].size();
            if off < n { continue; }   // nothing before it in the file.
            var st = at.retreat(n);
            if sm->get_text(SourceRange::from_bounds(st, static_cast::<u32>(n))) == kws[i] { return st; }
        }
        return at;
    }

    /// A generic VALUE argument (`4` of `Buf<4>`, `N` of `Buf<N>` written as
    /// an expression): folded like an array length (EVAL.md 0.1: an
    /// instance's identity), to a canonical value_arg. One that stops at a
    /// value parameter is that parameter; anything else is reported as an
    /// array length is.
    priv fn _resolve_value_arg(self, n: *TypeExpr) {
        if n->is_value { return; }
        if (n->expr == &null) || (self.sc->tu == &null) || self.sc->tu->is_foreign {
            self._mark_inst_dependent(static_cast::<*Type>(n));
            return;
        }
        var ce = ConstEval(self.sc);
        var c  = ce.eval_int(n->expr);
        if c.ok && (!c.overflow) && (ce.const_decl == &null) {
            n->canonical = self.sc->types->value_arg(c.neg, c.mag);
            return;
        }
        if c.ok || ce.quiet {
            self._bad_value(n->expr, &ce, c, "a generic value argument");
            n->poison();
            return;
        }
        // As an array length (_resolve_array): a value parameter, an
        // expression over them, an eval constant or call C++ computes; the
        // instance's identity is the interned expression (EVAL.md 0.2).
        var vx = self._value_expr(n->expr);
        if vx == &null {
            self._report_value(n->expr, &ce, c, "a generic value argument");
            n->poison();
            return;
        }
        if vx->is_dependent() { self._mark_dependent(static_cast::<*Type>(n)); }
        n->canonical = vx;
    }

    // === Computed values (EVAL.md 0.2) ======================================

    /// Why _value_expr failed: the sub-expression and a phrase, and a
    /// callee that is not `eval` (a fix-it target).
    priv var _vx_bad: *Expr = &null;
    priv var _vx_why: string;
    priv var _vx_fn:  *FunctionDecl = &null;

    priv fn _vx_fail(self, e: *Expr, why: string) -> *Type {
        if self._vx_bad == &null {
            self._vx_bad = e;
            self._vx_why = why;
        }
        return &null;
    }

    /// The canonical value node of \p e0, an array length or generic value
    /// argument ConstEval could not fold: literals, value parameters, eval
    /// constants (folded when their initializer folds), the binding of an
    /// enclosing `eval for`, calls of eval fns, the builtin integer
    /// operators and `as` to an integer type, over those. Null when \p e0
    /// is none of that (_vx_bad says where). Every operand is interned, so
    /// the node's identity is the expression's structure.
    priv fn _value_expr(self, e0: *Expr) -> *Type {
        self._vx_bad = &null;
        self._vx_why = "";
        self._vx_fn  = &null;
        self._vx_in_call = 0;
        return self._vx(e0);
    }

    priv fn _vx(self, e0: *Expr) -> *Type {
        if (e0 == &null) || e0->is_poisoned() { return self._vx_fail(e0, "it does not resolve"); }
        var e = e0;
        while (e != &null) && isa::<ParenExpr>(e) { e = cast::<ParenExpr>(e)->inner; }
        if (e == &null) || e->is_poisoned() { return self._vx_fail(e0, "it does not resolve"); }
        var ce = ConstEval(self.sc);

        if isa::<IntegerLiteralExpr>(e) {
            var c = ce.eval_int(e);
            if (!c.ok) || c.overflow { return self._vx_fail(e, "this literal does not fit 64 bits"); }
            return self.sc->types->value_arg(c.neg, c.mag);
        }
        // A string literal (EVAL.md 7e, §11, USER): `Widget<Config(4,
        // "small")>`. Its node is its decoded bytes, so equal literals are
        // one value; C++ gets the string built over `__kairo_estr<...>`
        // (CXXSpell::value). Only as an argument: a string is no length.
        if isa::<StringLiteralExpr>(e) {
            var sl = cast::<StringLiteralExpr>(e);
            if self._vx_in_call == 0 { return self._vx_fail(e, "a string is computed at compile time here only as an argument of an 'eval' call"); }
            if (sl->imm == &null) || sl->is_format() { return self._vx_fail(e, "an f-string is not computed at compile time"); }
            var st = ce.tu.string_type();
            if st == &null { return self._vx_fail(e, "the string lang item is not declared"); }
            var bytes = vec::<u8>();
            if !self._vx_string_bytes(sl, &bytes) { return self._vx_fail(e, "this literal does not decode"); }
            return self.sc->types->value_str(&bytes, st);
        }
        if isa::<NamedIdentExpr>(e) { return self._vx_name(e, cast::<NamedIdentExpr>(e)->resolved_decl); }
        if isa::<ChainExpr>(e) {
            var ch = cast::<ChainExpr>(e);
            var d: *Decl = &null;
            if ch->steps.size() > 0 { d = ch->steps.get(ch->steps.size() - 1)->resolved_decl; }
            if d == &null { d = ce.scope_path(ch); }
            return self._vx_name(e, d);
        }
        if isa::<UnaryOperatorExpr>(e) {
            var u = cast::<UnaryOperatorExpr>(e);
            var k = u->op_token.kind;
            if k == TokenKind::KwCompl { k = TokenKind::OpTilde; }
            if (!u->is_prefix()) || (u->resolved_op != &null) || ((k != TokenKind::OpMinus) && (k != TokenKind::OpPlus) && (k != TokenKind::OpTilde)) {
                return self._vx_fail(e, f"'{self.sc->ctx->get_spelling(u->op_token)}' is not computed at compile time here");
            }
            var x = self._vx(u->operand);
            if x == &null { return &null; }
            if k == TokenKind::OpPlus { return x; }
            var ops = vec::<*Type>();
            ops.push_back(x);
            return ce.value_node(ValueOp::Unary, k, &null, &ops, &null);
        }
        if isa::<BinaryOperatorExpr>(e) {
            var b = cast::<BinaryOperatorExpr>(e);
            var k = b->op_token.kind;
            if k == TokenKind::KwBitor  { k = TokenKind::OpPipe; }
            if k == TokenKind::KwBitand { k = TokenKind::OpAmp; }
            if k == TokenKind::KwXor    { k = TokenKind::OpCaret; }
            var known = (k == TokenKind::OpPlus) || (k == TokenKind::OpMinus) || (k == TokenKind::OpStar)
                     || (k == TokenKind::OpSlash) || (k == TokenKind::OpPercent)
                     || (k == TokenKind::OpPipe) || (k == TokenKind::OpAmp) || (k == TokenKind::OpCaret)
                     || (k == TokenKind::OpLessLess) || (k == TokenKind::OpGreaterGreater);
            if (b->resolved_op != &null) || (!known) {
                return self._vx_fail(e, f"'{self.sc->ctx->get_spelling(b->op_token)}' is not computed at compile time here");
            }
            var l = self._vx(b->lhs);
            if l == &null { return &null; }
            var r = self._vx(b->rhs);
            if r == &null { return &null; }
            var ops = vec::<*Type>();
            ops.push_back(l);
            ops.push_back(r);
            return ce.value_node(ValueOp::Binary, k, &null, &ops, &null);
        }
        if isa::<TypeCastExpr>(e) {
            var c = cast::<TypeCastExpr>(e);
            var t: *Type = &null;
            if c->target != &null { t = self.resolve(c->target); }
            var ut = (canon_unqual(t)) if (t != &null) else (&null);
            if (c->resolved_op != &null) || (ut == &null) || (!ce.tu.is_integer(ut)) {
                return self._vx_fail(e, "only a cast to an integer type is computed at compile time here");
            }
            var x = self._vx(c->operand);
            if x == &null { return &null; }
            var ops = vec::<*Type>();
            ops.push_back(x);
            return ce.value_node(ValueOp::Cast, TokenKind::TkUnknown, &null, &ops, ut);
        }
        if isa::<CallExpr>(e) {
            var call = cast::<CallExpr>(e);
            // An eval class's constructor (`Widget<Config(4)>`, EVAL.md 7e):
            // the node names the class, as C++ spells the call.
            var rec = self._vx_record_callee(call);
            if rec != &null {
                var cargs = vec::<*Type>();
                self._vx_in_call += 1;
                for var i: usize = 0; i < call->args.size(); ++i {
                    var a = self._vx(call->args[i]);
                    if a == &null { self._vx_in_call -= 1; return &null; }
                    cargs.push_back(a);
                }
                self._vx_in_call -= 1;
                return ce.value_node(ValueOp::Call, TokenKind::TkUnknown, rec, &cargs, &null);
            }
            var f = self._vx_callee(call);
            if f == &null { return self._vx_fail(e, "the function this calls is not known here"); }
            // An initializer read through its eval binding (_vx_name) may be
            // LOWERED already, when it is another module's: a string literal
            // is then its `string(bytes, len, cp)` construction, and an eval
            // class's construction names the constructor. Both are the nodes
            // the written forms give, or identity would differ by module.
            var ls = self._vx_lowered_string(call, f);
            if ls != &null { return ls; }
            var own = self._vx_ctor_owner(f);
            if own != &null {
                var oargs = vec::<*Type>();
                self._vx_in_call += 1;
                for var i: usize = 0; i < call->args.size(); ++i {
                    var a = self._vx(call->args[i]);
                    if a == &null { self._vx_in_call -= 1; return &null; }
                    oargs.push_back(a);
                }
                self._vx_in_call -= 1;
                return ce.value_node(ValueOp::Call, TokenKind::TkUnknown, own, &oargs, &null);
            }
            if !f->is_eval() {
                self._vx_fn = f;
                return self._vx_fail(e, f"'{self.sc->ctx->get_spelling(f->name)}' is not an 'eval' function");
            }
            var args = vec::<*Type>();
            self._vx_in_call += 1;
            for var i: usize = 0; i < call->args.size(); ++i {
                var a = self._vx(call->args[i]);
                if a == &null { self._vx_in_call -= 1; return &null; }
                args.push_back(a);
            }
            self._vx_in_call -= 1;
            return ce.value_node(ValueOp::Call, TokenKind::TkUnknown, static_cast::<*Decl>(f), &args, &null);
        }
        return self._vx_fail(e, "this is not computed at compile time");
    }

    /// A name in a computed value.
    priv fn _vx_name(self, e: *Expr, d: *Decl) -> *Type {
        if d == &null { return self._vx_fail(e, "this name does not resolve here"); }
        var gp = dyn_cast::<GenericParamDecl>(d);
        if gp != &null {
            if (!gp->is_const_param) || (gp->owner == &null) { return self._vx_fail(e, f"'{self.sc->ctx->get_spelling(gp->name)}' is a type parameter, not a value"); }
            return self.sc->types->generic_param(gp->owner, gp->index, false);
        }
        // An `eval for` binding is a constant in each copy (EVAL.md §5).
        for var i: usize = 0; i < self._ef_binds.size(); ++i {
            if self._ef_binds[i] == d { return self.sc->types->value_expr(ValueOp::Decl, TokenKind::TkUnknown, d, &null, &null); }
        }
        var vd = dyn_cast::<VariableDecl>(d);
        var fd = dyn_cast::<FieldDecl>(d);
        var ev = ((vd != &null) && vd->is_eval()) || ((fd != &null) && fd->is_eval());
        if !ev { return self._vx_fail(e, f"'{ConstEval(self.sc).tu.decl_name(d)}' is not an 'eval' constant"); }
        var ce = ConstEval(self.sc);
        var c = ce.eval_decl(e, d);
        if c.ok && (!c.overflow) { return self.sc->types->value_arg(c.neg, c.mag); }
        var seen = self._vx_through(vd);
        if seen != &null { return seen; }
        return self.sc->types->value_expr(ValueOp::Decl, TokenKind::TkUnknown, d, &null, &null);
    }

    /// Bound while _vx_through reads an initializer: how deep, so `eval A =
    /// B` / `eval B = A` stops (the Decl node stands then).
    priv var _vx_through_depth: u32 = 0;
    /// Inside the arguments of a Call node: where a string is a value.
    priv var _vx_in_call: u32 = 0;

    /// An eval binding of an eval class whose initializer is a constructor
    /// call over literals (`eval SMALL = Config(4, "small")`) IS that
    /// call's value (EVAL.md 7e, §11, USER): `Widget<SMALL>` and
    /// `Widget<Config(4, "small")>` are one type, as they are one C++
    /// specialization (a class-type template argument is its value). Only
    /// a closed node -- literals, strings, constructor calls over those --
    /// is seen through: a binding computed by an eval fn keeps its Decl
    /// node, whose identity is its name (EVAL.md 0.2). Null otherwise.
    priv fn _vx_through(self, vd: *VariableDecl) -> *Type {
        if (vd == &null) || (vd->init == &null) || (self._vx_through_depth >= 8) { return &null; }
        var sb = self._vx_bad;
        var sw = self._vx_why;
        var sf = self._vx_fn;
        var sic = self._vx_in_call;
        self._vx_in_call = 0;
        self._vx_through_depth += 1;
        var iv = self._vx(vd->init);
        self._vx_through_depth -= 1;
        self._vx_in_call = sic;
        self._vx_bad = sb;
        self._vx_why = sw;
        self._vx_fn  = sf;
        if iv == &null { return &null; }
        var v = dyn_cast::<TypeExpr>(iv);
        if (v == &null) || (!v->is_value) || (v->vop != ValueOp::Call) { return &null; }
        if (!isa::<ClassDecl>(v->vdecl)) && (!isa::<StructDecl>(v->vdecl)) { return &null; }
        if !self._vx_closed(iv) { return &null; }
        return iv;
    }

    /// \p t holds nothing but literals, strings and eval constructor calls.
    priv fn _vx_closed(self, t: *Type) -> bool {
        var v = dyn_cast::<TypeExpr>(t);
        if (v == &null) || (!v->is_value) { return false; }
        if v->is_exact() || (v->vop == ValueOp::Str) { return true; }
        if v->vop != ValueOp::Call { return false; }
        if (!isa::<ClassDecl>(v->vdecl)) && (!isa::<StructDecl>(v->vdecl)) { return false; }
        for var i: usize = 0; i < v->vops.size(); ++i { if !self._vx_closed(v->vops[i]) { return false; } }
        return true;
    }

    /// The decoded bytes of string literal \p sl, every chained part, as
    /// StringLowering would build them (a part with owned text is already
    /// decoded). False when an escape does not decode.
    priv fn _vx_string_bytes(self, sl: *StringLiteralExpr, out: *vec::<u8>) -> bool {
        var synth = LowerSynth(self.sc);
        var tcm = self.sc->ctx->tcm;
        var tbl = (tcm->get_imm_table_for_fid(self.sc->ctx->sm->get_fid(sl->range))) if (tcm != &null) else (self.sc->imm_table());
        var seg = sl->imm;
        var raw = sl->is_raw();
        while seg != &null {
            if seg->has_owned_text() {
                for var i: usize = 0; i < static_cast::<usize>(seg->owned_len); ++i { out->push_back(seg->owned_ptr[i]); }
            } else if !synth.decode_text(seg->body, raw, out) {
                return false;
            }
            if (seg->next == u32(-1)) || (tbl == &null) { break; }
            seg = tbl->get::<Immediate::StringData>(seg->next);
            raw = (static_cast::<u8>(seg->prefix_kind) & static_cast::<u8>(Immediate::TextPrefixKind::Raw)) != 0;
        }
        return true;
    }

    /// `string(bytes, len, cp)`, a string literal StringLowering already
    /// rewrote (another module's initializer, read by _vx_through), as the
    /// Str node of its bytes; null for any other call.
    priv fn _vx_lowered_string(self, call: *CallExpr, f: *FunctionDecl) -> *Type {
        var sd = self.sc->well_known->get(WellKnownType::String);
        if (sd == &null) || (call->args.size() != 3) { return &null; }
        var dc = reinterpret_cast::<*DeclContext>(f->semantic_dc);
        if (dc == &null) || (!dc->is_type_scope()) || (dc->owner_decl() != sd) { return &null; }
        var a = call->args[0];
        while (a != &null) && (isa::<ParenExpr>(a) || isa::<TypeCastExpr>(a)) {
            if isa::<ParenExpr>(a) { a = cast::<ParenExpr>(a)->inner; } else { a = cast::<TypeCastExpr>(a)->operand; }
        }
        if (a == &null) || (!isa::<StringLiteralExpr>(a)) { return &null; }
        var sl = cast::<StringLiteralExpr>(a);
        if (sl->imm == &null) || (!sl->imm->has_owned_text()) { return &null; }
        var st = ConstEval(self.sc).tu.string_type();
        if st == &null { return &null; }
        var bytes = vec::<u8>();
        for var i: usize = 0; i < static_cast::<usize>(sl->imm->owned_len); ++i { bytes.push_back(sl->imm->owned_ptr[i]); }
        return self.sc->types->value_str(&bytes, st);
    }

    /// The record \p f constructs, when it is an `eval` constructor (a
    /// lowered construction names it, EVAL.md 7e); null otherwise.
    priv fn _vx_ctor_owner(self, f: *FunctionDecl) -> *Decl {
        if !f->is_eval() { return &null; }
        var dc = reinterpret_cast::<*DeclContext>(f->semantic_dc);
        if (dc == &null) || (!dc->is_type_scope()) { return &null; }
        var owner = dc->owner_decl();
        if (owner == &null) || ((!isa::<ClassDecl>(owner)) && (!isa::<StructDecl>(owner))) { return &null; }
        var tu = ConstEval(self.sc).tu;
        if tu.decl_name(static_cast::<*Decl>(f)) != tu.decl_name(owner) { return &null; }
        return owner;
    }

    /// The function \p c calls, when names alone say: one declaration (a
    /// call's overloads are X's to pick, and a computed value is resolved
    /// before X).
    priv fn _vx_callee(self, c: *CallExpr) -> *FunctionDecl {
        var e = c->callee;
        while (e != &null) && isa::<ParenExpr>(e) { e = cast::<ParenExpr>(e)->inner; }
        if e == &null { return &null; }
        var d: *Decl = &null;
        if isa::<NamedIdentExpr>(e) {
            var ni = cast::<NamedIdentExpr>(e);
            d = ni->resolved_decl;
            if (d == &null) && (ni->candidate_cell != &null) && (ni->candidate_cell->size() == 1) { d = ni->candidate_cell->get(0); }
        } else if isa::<ChainExpr>(e) {
            var ch = cast::<ChainExpr>(e);
            if ch->steps.size() > 0 { d = ch->steps.get(ch->steps.size() - 1)->resolved_decl; }
            if d == &null { d = ConstEval(self.sc).scope_path(ch); }
        }
        return dyn_cast::<FunctionDecl>(d);
    }

    /// The class \p c constructs, when it names a record with an `eval`
    /// constructor taking that many arguments (EVAL.md 7e); null otherwise.
    priv fn _vx_record_callee(self, c: *CallExpr) -> *Decl {
        var e = c->callee;
        while (e != &null) && isa::<ParenExpr>(e) { e = cast::<ParenExpr>(e)->inner; }
        if (e == &null) || (!isa::<NamedIdentExpr>(e)) { return &null; }
        var d = cast::<NamedIdentExpr>(e)->resolved_decl;
        if (d == &null) || ((!isa::<ClassDecl>(d)) && (!isa::<StructDecl>(d))) { return &null; }
        var ms: *FrozenList::<*FunctionDecl> = &null;
        if isa::<ClassDecl>(d) { ms = &(cast::<ClassDecl>(d)->methods); } else { ms = &(cast::<StructDecl>(d)->methods); }
        var ce = ConstEval(self.sc);
        var on = ce.tu.decl_name(d);
        for var i: usize = 0; i < ms->size(); ++i {
            var m = (*ms)[i];
            if (m == &null) || m->is_operator || (!m->is_eval()) { continue; }
            if ce.tu.decl_name(static_cast::<*Decl>(m)) != on { continue; }
            var n: usize = 0;
            for var p: usize = 0; p < m->params.size(); ++p { if (m->params[p] != &null) && (!m->params[p]->is_self) { n += 1; } }
            if n == c->args.size() { return d; }
        }
        return &null;
    }

    /// Why a computed value has no node: a non-eval callee (with a fix-it),
    /// else ConstEval's reason, else _vx's.
    priv fn _report_value(self, e: *Expr, ce: *ConstEval, c: IntConst, what: string) {
        if self._vx_fn != &null {
            var f  = self._vx_fn;
            var nm = self.sc->ctx->get_spelling(f->name);
            var at = (self._vx_bad->range) if (self._vx_bad != &null) else (e->range);
            var b = self.sc->diag->report(DiagID::SC001E, at.start,
                f"{what} can call only 'eval' functions; '{nm}' is not 'eval\x27");
            b.first(at);
            b.note(DiagID::SC001N, f->range.start, f"'{nm}' is declared here").first(f->name.range);
            if (!self._foreign(static_cast::<*Decl>(f))) && (!f->is_implicit) && (f->body_kind == FnBodyKind::Block) {
                b.insert(f->range.start, "eval ", f"make '{nm}' an 'eval fn\x27");
            }
            b.emit();
            return;
        }
        if (ce->bad != &null) && (!isa::<CallExpr>(ce->bad)) {
            self._bad_value(e, ce, c, what);
            return;
        }
        var at2 = (self._vx_bad) if (self._vx_bad != &null) else (e);
        self.sc->diag->report(DiagID::SC001E, at2->range.start,
            f"{what} must be computed at compile time: {self._vx_why}"
        ).first(at2->range).emit();
    }

    /// Why `[T; e]` has no extent, at the part of `e` that is at fault.
    priv fn _bad_extent(self, n: *FixedArrayType, ce: *ConstEval, c: IntConst, what: string) {
        self._bad_value(n->size_expr, ce, c, what);
    }

    /// Why \p e is no compile-time value where \p what must be one (an
    /// array length, a generic value argument), at the part at fault.
    priv fn _bad_value(self, e: *Expr, ce: *ConstEval, c: IntConst, what: string) {
        if ce->quiet { return; }
        if c.ok && (ce->const_decl != &null) {
            var vd  = ce->const_decl;
            var nm  = self.sc->ctx->get_spelling(vd->name);
            var at  = (ce->const_at->range) if (ce->const_at != &null) else (e->range);
            var b = self.sc->diag->report(DiagID::SC001E, at.start,
                f"{what} must be an 'eval' constant; '{nm}' is 'const', which is not evaluated at compile time");
            b.first(at);
            b.note(DiagID::SC001N, vd->name.range.start, f"'{nm}' is declared 'const' here").first(vd->name.range);
            var kw = vd->storage_kw;
            if kw.is_valid() && (vd->storage == StorageClass::Const) && (!vd->const_binding) && (!self._foreign(static_cast::<*Decl>(vd))) {
                b.fix(kw, "eval", f"declare '{nm}' as 'eval\x27");
            }
            b.emit();
            return;
        }
        if c.ok {
            var why = ("a value wider than 64 bits") if (c.overflow) else (f"{ce->str(c)}, which is negative");
            self.sc->diag->report(DiagID::SC001E, e->range.start,
                f"{what} must be a non-negative constant that fits 64 bits; this one is {why}"
            ).first(e->range).emit();
            return;
        }
        var bad = (ce->bad) if (ce->bad != &null) else (e);
        var bvd = (dyn_cast::<VariableDecl>(ce->bad_decl)) if (ce->bad_decl != &null) else (&null);
        if (bvd != &null) && (!bvd->is_const()) && (!bvd->is_eval()) {
            var vn = self.sc->ctx->get_spelling(bvd->name);
            var vb = self.sc->diag->report(DiagID::SC001E, bad->range.start,
                f"{what} must be an 'eval' constant; '{vn}' is a variable");
            vb.first(bad->range);
            vb.note(DiagID::SC001N, bvd->name.range.start, f"'{vn}' is declared here").first(bvd->name.range);
            vb.emit();
            return;
        }
        if isa::<CallExpr>(bad) {
            self.sc->diag->report(DiagID::SC116E, bad->range.start,
                f"{what} computed by a call is not yet supported"
            ).first(bad->range).emit();
            return;
        }
        var b = self.sc->diag->report(DiagID::SC001E, bad->range.start,
            f"{what} must be a compile-time constant: {ce->bad_why}");
        b.first(bad->range);
        if ce->bad_decl != &null {
            var dn = ce->tu.decl_name(ce->bad_decl);
            b.note(DiagID::SC001N, ce->bad_decl->range.start, f"'{dn}' is declared here").first(ce->bad_decl->range);
        }
        b.emit();
    }

    /// An unprototyped `fn()` from a C header canonicalizes as a zero-param
    /// function: Kairo has no "unknown parameters" identity and the C rule
    /// (any args) has no type-level meaning worth inventing. Callers that
    /// care check `is_unprototyped` on the syntax node.
    ///
    /// The written modes go into the key with the params. The parser fills
    /// `modes` parallel to `params` even when empty; a mismatch is a parser
    /// bug, not a user error.
    priv fn _resolve_fnptr(self, n: *FunctionPointerType) {
        ICE_IF((n->modes.size() != n->params.size()),
               "TypeResolution: FunctionPointerType::modes not parallel to params");
        var params = vec::<*Type>();
        var modes  = vec::<ParamMode>();
        var ok = true;
        for var i: usize = 0; i < n->params.size(); ++i {
            var p = n->params[i];
            if !self._component_ok(n, p) { ok = false; continue; }
            params.push_back(p->canonical);
            modes.push_back(n->modes[i]);
        }
        var ret: *Type = &null;
        if n->return_type != &null {
            if !self._component_ok(n, n->return_type) { ok = false; }
            else { ret = n->return_type->canonical; }
        } else {
            ret = self.sc->builtin(BuiltinKind::Void);
        }
        // A declared `panic(E1, E2)`: its elements are types and resolve
        // like the parameters, and a bad one poisons the `fn` type with
        // them. The effect is in the key (PANIC.md §2.2): `panic` and its
        // set, canonical, so `fn() panic(A, B)` and `fn() panic(B, A)` are
        // one type and `fn() panic(A)` another.
        for var i: usize = 0; i < n->panic_set.size(); ++i {
            if !self._component_ok(n, n->panic_set[i]) { ok = false; }
        }
        if !ok { return; }
        var pset = vec::<*Type>();
        if n->is_panic() {
            var tu = TypeUtil(self.sc);
            canonical_set(&tu, &(n->panic_set), &pset);
        }
        n->canonical = self.sc->types->func(&params, &modes, ret, n->is_panic(), &pset);
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
    ///
    /// Dependence ALWAYS flows up, canonical or not: `[T]` is dependent
    /// because `T` is, and it still has a canonical (vector(genparam)). Only
    /// propagating on the no-canonical path left every resolved `[T]`, `*T`,
    /// `(T, i32)` claiming to be concrete.
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

        parent->type_flags = static_cast::<Type::TypeFlags>(
            static_cast::<u8>(parent->type_flags) | static_cast::<u8>(child->type_flags));

        if child->canonical == &null {
            // Dependent, or awaiting M2. The flags above say which.
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
        var owner = self._current_self();
        if owner == &null {
            self.sc->diag->report(DiagID::R030E, n->range.start,
                "'Self' used outside of a type body"
            ).first(n->range).emit();
            n->poison();
            return;
        }
        n->canonical = owner;
    }

    priv fn _current_self(self) -> *Type {
        if self._selfs.empty() { return &null; }
        return self._selfs[self._selfs.size() - 1];
    }

    /// The record whose members a bare name inside the innermost type body
    /// reaches: Self's decl, or the body an instance Self selects (as
    /// _lookup_in_selfs walks it). Null outside a type body and for a
    /// non-record Self.
    priv fn _self_owner(self) -> *Decl {
        var t = self._current_self();
        if t == &null { return &null; }
        var d = self._self_decl_of(t);
        if d == &null { return &null; }
        var b = self.sc->record_body(t);
        if b != &null { return b; }
        return d;
    }

    /// The decl a Self type's members live in: its record's. Null for a
    /// non-record Self (`extend i32`), which has no scope to look into.
    priv fn _self_decl_of(self, t: *Type) -> *Decl {
        if t == &null { return &null; }
        var u = canon_unqual(t);
        if (u == &null) || (!isa::<RecordType>(u)) { return &null; }
        return cast::<RecordType>(u)->decl;
    }

    /// What Self denotes inside the type scope \p d owns. An extension is
    /// its TARGET, already resolved (traverse_extension_decl resolves it
    /// before its body); null while it is not, so the caller pushes nothing
    /// rather than the extension decl's own params.
    priv fn _self_of_scope(self, d: *Decl) -> *Type {
        if d == &null { return &null; }
        if isa::<ExtensionDecl>(d) {
            var e = cast::<ExtensionDecl>(d);
            if (e->target == &null) || e->target->is_poisoned() { return &null; }
            return e->target->canonical;
        }
        return self._self_record(d);
    }

    /// The record type a type body denotes for itself: Foo for a non-generic
    /// Foo, Foo<T, U> (with its OWN params as the args) for a generic one.
    /// The generic case is dependent by construction and the RecordType
    /// carries that flag through the store's flag absorption.
    priv fn _self_record(self, owner: *Decl) -> *Type {
        var canon = NameLookup::representative(owner);
        var spec = self._spec_self_record(canon);
        if spec != &null { return spec; }
        var gps   = decl_generic_params(canon);
        var args  = vec::<*Type>();
        for var i: usize = 0; i < gps.size(); ++i {
            var gp = gps[i];
            if gp == &null { continue; }
            args.push_back(self.sc->types->generic_param(canon, gp->index, gp->is_pack));
        }
        return self.sc->types->record(canon, &args);
    }

    /// Self inside a registered specialization is the instance it stands
    /// for, spelled through the primary as every other mention of it is:
    /// `<P> Store<*P>` is `Store<*P>` (dependent, the primary's; member
    /// lookup selects the partial back from the pattern) and `<> Store<bool>`
    /// is `Store<bool>`, the very canonical a use names. A record over the
    /// spec's own parameters instead would substitute into `Store<i32>` for
    /// `Store<*i32>` -- the partial's P against the primary's slot -- and
    /// spell `Store<P>` in C++, the primary. Null for anything else, or for
    /// a spec whose pattern did not resolve.
    priv fn _spec_self_record(self, canon: *Decl) -> *Type {
        var k = decl_spec_kind(canon);
        if (k != SpecKind::Partial) && (k != SpecKind::Explicit) { return &null; }
        var primary = decl_instantiated_from(canon);
        if primary == &null { return &null; }
        var sargs = decl_spec_args(canon);
        var args  = vec::<*Type>();
        for var i: usize = 0; i < sargs.size(); ++i {
            if (sargs[i] == &null) || (sargs[i]->canonical == &null) { return &null; }
            args.push_back(sargs[i]->canonical);
        }
        if k == SpecKind::Explicit { return self.sc->types->record(canon, &args); }
        return self.sc->types->record(NameLookup::representative(primary), &args);
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
                self.sc->diag->report(DiagID::R022E, n->range.start,
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
        // A bare pack, `T...`, the one form an argument list takes today:
        // its canonical is the pack parameter, which stands for its
        // expansion wherever it is an argument (Deduction::substitute
        // splices the elements in; CXXSpell spells `T...`). A pattern over
        // the pack (`Box<T>...`) has none yet.
        var pc = canon_unqual(n->pattern->canonical);
        if (pc != &null) && isa::<GenericParamType>(pc) && cast::<GenericParamType>(pc)->is_pack {
            n->canonical = pc;
        }
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

    // === Target portability ==================================================

    /// Reject a primitive whose REPRESENTATION does not exist on the target.
    ///
    /// `f80` is the only type that raises this. f80 is the x87 80-bit extended
    /// format -- 1/15/64 with an explicit integer bit, which no IEEE
    /// interchange format has -- and it lowers to C++ `long double`, so it
    /// exists exactly where the target ABI's `long double` is x87 extended.
    /// That is an ABI fact, not an ISA fact: x86_64-windows-msvc has x87
    /// hardware and a binary64 `long double`, x86_64-linux-android has a
    /// binary128 one, and off x86 it is binary64 (Apple, MSVC), binary128
    /// (AArch64/RISC-V Linux, s390x) or IBM double-double (PPC64). The answer
    /// comes from clang::TargetInfo via target.long_double_is_x87; is_x86 is
    /// only consulted to word the message.
    ///
    /// The alternative to erroring is picking a replacement, and both
    /// available replacements are wrong in a way the user cannot see: f128 is
    /// IEEE binary128, a different format whose every operation is a
    /// compiler-rt libcall, and f64 silently drops 11 bits of significand.
    /// A quiet precision change is worse than a failed build, so this is a
    /// hard error at the SPELLING, before anything downstream can depend on
    /// the type. CanonicalNodes.k's BuiltinKind::F80 comment promises exactly
    /// this behaviour; here it is.
    ///
    /// Gated on `target.resolved`: a hand-built invocation that never reached
    /// CompilerInstance::_apply_invocation has no target facts, and guessing
    /// "not x87" there would reject f80 on the very host it works on.
    priv fn _target_supports(self, bk: BuiltinKind, ct: *ChainType) -> bool {
        if bk != BuiltinKind::F80 { return true; }
        if self.sc->ctx == &null      { return true; }
        if self.sc->ctx->ci == &null  { return true; }
        var t = &(self.sc->ctx->ci->target);
        if !t->resolved               { return true; }
        if t->long_double_is_x87      { return true; }

        var tri  = t->describe();
        var arch = t->arch_name;
        var ld   = t->long_double_fmt_name;

        // Two different failures. The hardware may have x87 and the ABI still
        // not expose it: f80 lowers to C++ `long double`, so the ABI is the
        // fact that decides, not the ISA.
        var msg = "";
        if t->is_x86 {
            msg = f"'f80' is unavailable on '{tri}': x87 exists but this ABI's 'long double' is {ld}";
        } else {
            msg = f"'f80' requires x87, which {arch} does not have";
        }

        var why  = f"the effective target is '{tri}\x27";
            why += " (--target if given, else the host triple, after -m32/-m64)";

        // Point at the type that actually equals C's `long double` here, since
        // FFI is the common reason for spelling f80 at all. Never suggest f128
        // where the target has no __float128 -- arm64-windows-msvc, for one.
        var fix = "";
        if ld == "binary64" {
            fix = "use 'f64' (what C's 'long double' is on this target)";
            if t->has_float128 { fix += ", or 'f128' for range beyond f64"; }
        } else if (ld == "binary128") {
            fix = "use 'f128' (what C's 'long double' is on this target)";
        } else {
            fix = f"C's 'long double' here is {ld}, which has no Kairo builtin; bind it through FFI";
            if t->has_float128 { fix += ", or use 'f128\x27"; }
        }
        fix += "; see --explain P003E";

        self.sc->diag->report(DiagID::P003E, ct->range.start, msg)
            .first(ct->range)
            .note(ct->range.start, why)
            .note(ct->range.start, fix)
            .emit();
        return false;
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
                var sp = builtin_info(bk)->spelling;
                self.sc->diag->report(DiagID::R024E, ct->range.start,
                    f"'{sp}' is a primitive type; it has no members and takes no generic arguments"
                ).first(ct->range).emit();
                ct->poison();
                return;
            }
            if !self._target_supports(bk, ct) { ct->poison(); return; }
            var b = self.sc->builtin(bk);
            seg0->resolved_type = b;
            seg0->seg_kind      = ChainType::SegmentKind::Named;
            ct->canonical       = b;
            return;
        }

        // `Self` / `self` in type position: the enclosing type. Bare, it IS the
        // record (with its own params as args, dependent if generic). With
        // `::` after it, it is a HEAD like any other type decl: `Self::Inner`
        // steps into the enclosing body exactly as `Foo::Inner` would.
        var head: *Decl = &null;
        var head_owner: *Decl = &null;   // set iff head is a generic param.

        // Every scope the CURRENT segment denotes when its cell is all
        // ModuleDecls. A namespace reopened across files -- or across the
        // headers of one ffi closure: libc++ opens `std` in dozens -- is one
        // namespace over N tables, and the `::` walk has to search all of
        // them: ChainBinding's Anchor.scopes rule, in type position
        // (IMPORTS.md §4.3). Empty whenever the segment is anything else.
        var mods = vec::<*DeclContext>();

        if (tok.kind == TokenKind::KwSelf) || (tok.kind == TokenKind::BiSelf) {
            var sp = self.sc->ctx->get_spelling(tok);
            if !seg0->generic_args.is_empty() {
                self.sc->diag->report(DiagID::R032E, seg0->range.start,
                    f"'{sp}' takes no generic arguments; it already denotes the enclosing type with its own"
                ).first(seg0->range).emit();
                ct->poison();
                return;
            }
            var owner = self._current_self();
            if owner == &null {
                self.sc->diag->report(DiagID::R030E, ct->range.start,
                    f"'{sp}' used as a type outside of a type body"
                ).first(ct->range).emit();
                ct->poison();
                return;
            }
            var owner_decl = self._self_decl_of(owner);
            seg0->resolved_decl = owner_decl;
            if n == 1 {
                ct->canonical = owner;
                seg0->resolved_type = ct->canonical;
                return;
            }
            // `Self::X` inside `extend i32`: Self is a type, but one with no
            // scope of its own to walk.
            if owner_decl == &null {
                self.sc->diag->report(DiagID::R026E, seg0->range.start,
                    f"'{sp}' does not name a scope; '::' can only follow a type, module, or enum"
                ).first(seg0->range).emit();
                ct->poison();
                return;
            }
            // `Self::Inner`: walk from here. Inside `extend Box<i32>` the self
            // decl is an INSTANCE node whose table is empty until M2; its
            // nested types are on the pattern, so walk that (#12). An
            // instance of an IMPORTED template is clang's to fill, and must
            // be filled before that choice: its pattern's `size_type` is the
            // dependent spelling, not clang's `unsigned long`.
            head = owner_decl;
            MemberLookup::ensure_filled(self.sc, owner_decl);
            var body = self.sc->record_body(owner);   // unfilled instance, or a partial's dependent Self.
            if body != &null { head = body; }
        } else {
            // --- 2. head: generic frames, then the DC chain + overlay --------
            var imm = self._name_imm(tok);
            if imm == u32(-1) { ct->poison(); return; }   // recovery/synthetic name; parser diagnosed.

            var gh = self._lookup_generic(imm);
            if gh.decl != &null {
                head       = static_cast::<*Decl>(gh.decl);
                head_owner = gh.owner;
            } else {
                head = self._lookup_local_type(imm);
                if head == &null {
                    var r = self._lookup_unqualified(self.cur_dc, imm);
                    // An `extend` body's DeclContext parents to the TU, so the
                    // walk above never reaches the type being extended. Its
                    // nested types and aliases ARE in scope there -- `Nested`
                    // inside `extend Foo` means `Self::Nested`, exactly as it
                    // does inside `class Foo`. `_selfs` already holds the
                    // target (traverse_extension_decl pushed it); for a class
                    // body this is a no-op, the DC chain answered first.
                    if !r.found() { r = self._lookup_in_selfs(imm, self.sc->ctx->get_spelling(tok)); }
                    if !r.found() {
                        var nm = self.sc->ctx->get_spelling(tok);
                        self.sc->diag->report(DiagID::R021E, seg0->name->range.start,
                            f"unknown type name '{nm}\x27"
                        ).first(seg0->name->range).emit();
                        ct->poison();
                        return;
                    }
                    // The use-site half of a header-only collision
                    // (ImportResolution::_add), as N does for a value.
                    if r.via_overlay
                    && MemberLookup::report_lazy_ambiguity(self.sc, r.found_in, imm,
                                                           self.sc->ctx->get_spelling(tok), seg0->name->range) {
                        ct->poison();
                        return;
                    }
                    // A generic VALUE argument written as a name (`Ring<CAP>`)
                    // parses as a type: an `eval` variable here is its value
                    // (EVAL.md 3), anything else that is a value is reported
                    // as one that is not eval-able.
                    if (self._arg_depth > 0) && (n == 1) && seg0->generic_args.is_empty() && (r.cell->size() == 1)
                    && (isa::<VariableDecl>(r.cell->get(0)) || isa::<FieldDecl>(r.cell->get(0))) {
                        var at = static_cast::<*Expr>(seg0->name);
                        var ce = ConstEval(self.sc);
                        var c  = ce.eval_decl(at, r.cell->get(0));
                        if c.ok && (!c.overflow) && (ce.const_decl == &null) {
                            seg0->resolved_decl = r.cell->get(0);
                            ct->canonical = self.sc->types->value_arg(c.neg, c.mag);
                            return;
                        }
                        // An eval constant C++ computes (one that calls an
                        // eval fn, or an eval class's object, EVAL.md 0.2 /
                        // 7e): its value node.
                        if (!c.ok) && (!ce.quiet) {
                            self._vx_bad = &null;
                            self._vx_fn  = &null;
                            var vx = self._vx_name(at, r.cell->get(0));
                            if vx != &null {
                                seg0->resolved_decl = r.cell->get(0);
                                ct->canonical = vx;
                                return;
                            }
                        }
                        self._bad_value(at, &ce, c, "a generic value argument");
                        ct->poison();
                        return;
                    }
                    head = self._pick_type_candidate(r, seg0->name);
                    if head == &null { ct->poison(); return; }   // diagnosed inside.
                    // The scope exception's readability lint: `-> Node`
                    // resolves, and says `Self::Node` would read better.
                    var so = self._self_owner();
                    if MemberLookup::is_member_type_of(head, so) {
                        MemberLookup::warn_unqualified_member_type(self.sc, seg0->name->range, head, so);
                    }
                    self._append_module_scopes(r, &mods);
                }
            }
            seg0->resolved_decl = head;
        }

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
            if isa::<GenericParamDecl>(cur) {
                seg->seg_kind = ChainType::SegmentKind::Dependent;
                went_dependent = true;
                break;
            }
            // `Foo<Args>::Inner` with Foo IMPORTED and every arg concrete:
            // clang can answer now, so step into the registry instance and
            // let _scope_of fill it. A Kairo primary stays deferred to M2; so
            // does an instance clang could not fill (its table is empty and
            // the pattern's spellings are dependent -- today's behaviour).
            if !prev->generic_args.is_empty() {
                var inst = self._foreign_instance_of(ct, cur, prev);
                if ct->is_poisoned() { return; }   // arity / arg errors, diagnosed inside.
                if inst != &null {
                    self._scope_of(inst, seg->range);   // the fill trigger.
                }
                if (inst == &null) || MemberLookup::unfilled(inst) {
                    seg->seg_kind = ChainType::SegmentKind::Dependent;
                    went_dependent = true;
                    break;
                }
                cur = inst;
            }

            var scope = self._scope_of(cur, seg->range);
            if scope == &null {
                if !cur->is_poisoned() {
                    var pnm = self.sc->ctx->get_spelling(prev->name->name);
                    self.sc->diag->report(DiagID::R026E, prev->name->range.start,
                        f"'{pnm}' does not name a scope; '::' can only follow a type, module, or enum"
                    ).first(prev->name->range).emit();
                }
                ct->poison();
                return;
            }

            var simm = self._name_imm(seg->name->name);
            if simm == u32(-1) { ct->poison(); return; }
            // `scope` may live in another TU (`import lib` then `lib::Foo`),
            // and its table is keyed by ITS imms. Hand the spelling along so
            // the probe re-interns rather than trusting index agreement:
            // without it `lib::Aaa` silently resolved to whichever of lib's
            // decls happened to share this TU's index for `Aaa`.
            var sspell = self.sc->ctx->get_spelling(seg->name->name);
            var sr = self.sc->lookup.in_context(scope, DeclName::ident(simm), sspell);
            var next_mods = vec::<*DeclContext>();
            if mods.size() > 1 {
                // Every reopening. The first that has the name answers: a
                // type found in two is ONE entity, bound into each table by
                // the ForeignRegistry (or RedeclMerge). An all-module hit
                // carries its own reopenings on to the next segment.
                for var m: usize = 0; m < mods.size(); ++m {
                    var hit = self.sc->lookup.in_context(mods[m], DeclName::ident(simm), sspell);
                    if !hit.found() { continue; }
                    if !sr.found() { sr = hit; }
                    self._append_module_scopes(hit, &next_mods);
                }
            } else {
                self._append_module_scopes(sr, &next_mods);
            }
            if !sr.found() {
                var snm = self.sc->ctx->get_spelling(seg->name->name);
                var pnm = self.sc->ctx->get_spelling(prev->name->name);
                self.sc->diag->report(DiagID::R025E, seg->name->range.start,
                    f"no type named '{snm}' in '{pnm}\x27"
                ).first(seg->name->range).emit();
                ct->poison();
                return;
            }
            cur = self._pick_type_candidate(sr, seg->name);
            if cur == &null { ct->poison(); return; }
            cur_owner = &null;
            seg->resolved_decl = cur;
            mods = next_mods;
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

    /// An implicit instantiation M2 has not filled: empty table, empty base
    /// list. Its names live on `instantiated_from` until then.
    priv fn _is_unfilled_instance(self, d: *Decl) -> bool { return MemberLookup::unfilled(d); }

    /// The registry instance a middle segment `Foo<Args>` names, when Foo is
    /// an IMPORTED template and every arg is concrete; null otherwise (a
    /// Kairo primary, or a dependent arg -- both M2's). Arity and arg errors
    /// are diagnosed here and poison \p ct.
    priv fn _foreign_instance_of(self, ct: *ChainType, d: *Decl, seg: *ChainType::ChainSegment) -> *Decl {
        if (d == &null) || isa::<TypeAliasDecl>(d) { return &null; }
        var canon = NameLookup::representative(d);
        if !MemberLookup::primary_is_imported(canon) { return &null; }
        var gps = decl_generic_params(canon);
        if gps.size() == 0 { return &null; }
        if !self._check_arity(canon, gps, seg, ct) { return &null; }
        var args = vec::<*Type>();
        if !self._collect_args(seg, ct, canon, gps, &args) { return &null; }
        for var i: usize = 0; i < args.size(); ++i {
            if args[i]->is_dependent() || args[i]->is_instantiation_dependent() { return &null; }
        }
        var e = self.sc->instances->instance_for(canon, &args, self.sc->ctx->fid, NameLookup::ctx_of(canon));
        if e == &null { return &null; }
        seg->resolved_type = self.sc->types->record(e->decl, &args);
        return e->decl;
    }

    /// A cell in TYPE position: functions/vars are not types, and two type
    /// decls under one name are a redefinition N already reported. Collapse a
    /// redecl chain to its canonical (definition) link.
    priv fn _pick_type_candidate(self, r: SemaLookupResult, at: *NamedIdentExpr) -> *Decl {
        var best: *Decl = &null;
        var spec: *Decl = &null;
        for var i: usize = 0; i < r.cell->size(); ++i {
            var d = r.cell->get(i);
            if d == &null { continue; }
            if !self._is_type_decl(d) { continue; }
            if NameLookup::is_specialization(d) {
                if spec == &null { spec = d; }
                continue;   // never the answer to a NAME; M1 pairs it with the primary.
            }
            var rep = NameLookup::representative(d);
            if best == &null { best = rep; continue; }
            if best != rep { break; }   // N(a) diagnosed the redefinition; pick the first.
        }
        if (best == &null) && (spec != &null) {
            var nm = self.sc->ctx->get_spelling(at->name);
            self.sc->diag->report(DiagID::R042E, at->range.start,
                f"'{nm}' has a specialization but no primary template in scope"
            ).first(at->range)
             .note(DiagID::R042N, spec->range.start, "specialization declared here").first(spec->range)
             .emit();
            return &null;
        }
        if best == &null {
            var nm = self.sc->ctx->get_spelling(at->name);
            self.sc->diag->report(DiagID::R023E, at->range.start,
                f"'{nm}' does not name a type"
            ).first(at->range)
             .note(DiagID::R023N, r.cell->get(0)->range.start,
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

    /// Append the scope of every decl in \p r's cell when ALL of them are
    /// modules (`mods` in the qualified walk); append nothing otherwise.
    priv fn _append_module_scopes(self, r: SemaLookupResult, out: *vec::<*DeclContext>) {
        if !r.found() { return; }
        for var i: usize = 0; i < r.cell->size(); ++i {
            if !isa::<ModuleDecl>(r.cell->get(i)) { return; }
        }
        // Each entry's whole reopening ring, deduped -- `Util::SomeType` must
        // see a type declared in any `module Util { }` block, not only the
        // one the cell's entry is.
        for var i: usize = 0; i < r.cell->size(); ++i {
            NameLookup::module_scopes(r.cell->get(i), *out);
        }
    }

    /// The DeclContext a `::` step looks INTO. Aliases are expanded first
    /// (NameLookup::context_of returns null for them on purpose; expansion is
    /// T's job and this is where it happens).
    ///
    /// Every `::` step in type position comes through here -- an alias
    /// target, a generic argument, a bare `X::Y` in a signature -- so this is
    /// the one place a foreign shell is filled before its table is read
    /// (MemberLookup::ensure_filled; a failed fill leaves the table empty and
    /// the step misses as it always did).
    priv fn _scope_of(self, d: *Decl, at: SourceRange) -> *DeclContext {
        if d == &null { return &null; }
        if isa::<TypeAliasDecl>(d) {
            var c = canon_unqual(self._expand_alias(cast::<TypeAliasDecl>(d), at));
            if c == &null { return &null; }
            if !isa::<RecordType>(c) { return &null; }
            var rd = cast::<RecordType>(c)->decl;
            MemberLookup::ensure_filled(self.sc, rd);
            return NameLookup::context_of(rd);
        }
        MemberLookup::ensure_filled(self.sc, d);
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
                self.sc->diag->report(DiagID::R032E, seg->range.start,
                    f"generic parameter '{nm}' cannot itself take generic arguments"
                ).first(seg->range).emit();
                ct->poison();
                return &null;
            }
            // A value parameter as a generic argument (`Buf<N>`): the
            // parameter itself stands in, as a type parameter does.
            if gp->is_const_param && (self._arg_depth > 0) {
                self._mark_dependent(ct);
                return self.sc->types->generic_param(gowner, gp->index, false);
            }
            if gp->is_const_param {
                var nm = self.sc->ctx->get_spelling(gp->name);
                self.sc->diag->report(DiagID::R023E, seg->range.start,
                    f"'{nm}' is a value parameter and cannot be used as a type"
                ).first(seg->range)
                 .note(DiagID::R023N, gp->range.start, "declared as a generic value parameter here")
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

            // `cxx` is the C++ std overlay, whose ONE member is `std`
            // (IMPORTS.md §5). Naming it alone denotes nothing, and the
            // generic "is a module, not a type" leaves the reader guessing
            // which module and what to write instead.
            if (self.sc->tu != &null) && (d == self.sc->tu->cxx_module) {
                self.sc->diag->report(DiagID::R053E, seg->range.start,
                    "'cxx' names the C++ std overlay; write `cxx::std`"
                ).first(seg->range).emit();
                ct->poison();
                return &null;
            }

            self.sc->diag->report(DiagID::R023E, seg->range.start,
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
                // Generic alias APPLICATION: the aliased body with the
                // arguments substituted in, so `Mat<i32>` of `type <T> Mat =
                // [[T]]` IS `[[i32]]` -- the same canonical, the same
                // instance, as if written out. `Mat<U>` in a generic body is
                // `[[U]]`, dependent like any other use of U.
                if !self._check_arity(d, gps, seg, ct) { return &null; }
                var args = vec::<*Type>();
                if !self._collect_args(seg, ct, d, gps, &args) { return &null; }
                var body = self._expand_alias(td, seg->range);
                if (body == &null) && (td->is_poisoned() || (self.sc->rstate.decl_state(td) == ResolveState::Errored)) {
                    ct->poison();
                    return &null;
                }
                var applied = self._apply_alias(td, gps, &args, body);
                if applied != &null {
                    ct->type_flags = static_cast::<Type::TypeFlags>(
                        static_cast::<u8>(ct->type_flags) | static_cast::<u8>(applied->type_flags));
                    return applied;
                }
                // A body substitution cannot rewrite (a raw dependent
                // composite with no canonical): the use stays
                // instantiation-dependent, as every application was before.
                // Not an error.
                self._mark_inst_dependent(ct);
                return &null;
            }
            if !seg->generic_args.is_empty() {
                var nm = self.sc->ctx->get_spelling(td->name);
                self.sc->diag->report(DiagID::R032E, seg->range.start,
                    f"type alias '{nm}' is not generic and takes no arguments"
                ).first(seg->range)
                 .note(DiagID::R032N, td->range.start, "declared here").first(td->range).emit();
                ct->poison();
                return &null;
            }
            var c = self._expand_alias(td, seg->range);
            if c == &null {
                if td->is_poisoned() || (td->aliased == &null)
                || (self.sc->rstate.decl_state(td) == ResolveState::Errored) {
                    ct->poison();
                } else {
                    // Alias of a dependent type: inherit.
                    ct->type_flags = static_cast::<Type::TypeFlags>(
                        static_cast::<u8>(ct->type_flags) | static_cast::<u8>(td->aliased->type_flags));
                }
            }
            return c;
        }

        // -- nominal types --------------------------------------------------------
        var canon = NameLookup::representative(d);
        var gps   = decl_generic_params(canon);

        if !self._check_arity(canon, gps, seg, ct) { return &null; }

        var args = vec::<*Type>();
        if !self._collect_args(seg, ct, canon, gps, &args) { return &null; }

        var dep = ct->is_dependent() || ct->is_instantiation_dependent();
        for var i: usize = 0; i < args.size(); ++i {
            ct->type_flags = static_cast::<Type::TypeFlags>(
                static_cast::<u8>(ct->type_flags) | static_cast::<u8>(args[i]->type_flags));
            if args[i]->is_dependent() || args[i]->is_instantiation_dependent() { dep = true; }
        }

        // The Panic lang item (PANIC.md §1.1): the compiler forms every
        // instance; source names one only under the test hook, and then its
        // set is formed as the compiler forms one -- canonical, and checked
        // for colliding type ids (PanicSets).
        var psets = PanicSets(self.sc);
        if psets.is_panic(canon) {
            if (!self.sc->opts.test_panic_type) && (!self.sc->g->is_builtin_fid(self.sc->ctx->fid)) {
                var b = self.sc->diag->report(DiagID::SC116E, seg->range.start,
                    "a panic result type cannot be named yet; a panicking call is handled with 'try' or propagated");
                b.first(seg->range, "'Panic' is the result type of a 'panic' function, written by the compiler");
                b.note(DiagID::SC116N, canon->range.start, "the builtin result type, declared here").first(canon->range);
                b.emit();
                ct->poison();
                return &null;
            }
            if (!dep) && psets.canonicalize(&args) && (!psets.check_collisions(seg->range, &args)) {
                ct->poison();
                return &null;
            }
        }

        // #12. A CONCRETE instance points at the decl that IS the instance:
        // the explicit spec if one was registered for these args, else the
        // implicit node minted on this first mention. A dependent use keeps
        // the primary -- a pattern -- and is deferred (#5).
        var inst = canon;
        if (!dep) && (gps.size() > 0) {
            var e = self.sc->instances->instance_for(canon, &args, self.sc->ctx->fid,
                                                     NameLookup::ctx_of(canon));
            if e != &null { inst = e->decl; }
            if (e != &null) && (e->ambiguous_a != &null) && (!e->ambiguity_reported) {
                self._ambiguous_partials(e, seg->range);
            }
        }
        var rt = self.sc->types->record(inst, &args);
        if psets.is_panic(canon) && (!dep) { psets.note_formed(seg->range, rt); }
        return rt;
    }

    /// \p body (an alias's canonical, over its own parameters) with \p args
    /// bound to them; null when substitution cannot say. A pack parameter
    /// takes every argument from its position on, as an instance's do
    /// (Substitution::bind_from_record). Both the alias and its
    /// representative own the parameters a redeclared alias's body names.
    priv fn _apply_alias(self, td: *TypeAliasDecl, gps: FrozenList::<*GenericParamDecl>,
                         args: *vec::<*Type>, body: *Type) -> *Type {
        if body == &null { return &null; }
        var ded = Deduction(self.sc, &null);
        var owners = vec::<*Decl>();
        owners.push_back(static_cast::<*Decl>(td));
        var rep = NameLookup::representative(static_cast::<*Decl>(td));
        if rep != static_cast::<*Decl>(td) { owners.push_back(rep); }
        for var o: usize = 0; o < owners.size(); ++o {
            var at: usize = 0;
            for var i: usize = 0; i < gps.size(); ++i {
                var gp = gps[i];
                if gp == &null { continue; }
                if gp->is_pack {
                    ded.open_pack(owners[o], gp->index);
                    for var k: usize = at; k < args->size(); ++k { ded.push_pack(owners[o], gp->index, (*args)[k]); }
                    at = args->size();
                    continue;
                }
                if at >= args->size() { return &null; }
                ded.bind(owners[o], gp->index, (*args)[at]);
                at += 1;
            }
        }
        return ded.substitute(body);
    }

    // === Generic arguments ====================================================

    /// Arity against the primary's parameter list: at least the required
    /// count (no default, not a pack), at most the total unless a pack makes
    /// it unbounded. Named args are counted, not positioned -- positioning is
    /// _collect_args' job.
    /// GenericArgs::check_arity, poisoning \p ct on a miss.
    priv fn _check_arity(self, d: *Decl, gps: FrozenList::<*GenericParamDecl>,
                         seg: *ChainType::ChainSegment, ct: *ChainType) -> bool {
        var ga = GenericArgs(self.sc);
        if ga.check_arity(d, self._decl_name_str(d), gps, seg->generic_args.size(), seg->range) { return true; }
        ct->poison();
        return false;
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

    /// GenericArgs::collect over \p seg, poisoning \p ct on a miss. The
    /// defaults are demanded HERE first: GenericArgs only reads them, and a
    /// Kairo primary's default resolves in the PRIMARY's scope, which only T
    /// can set up (_demand_default).
    priv fn _collect_args(self, seg: *ChainType::ChainSegment, ct: *ChainType,
                          primary: *Decl, gps: FrozenList::<*GenericParamDecl>,
                          out: *vec::<*Type>) -> bool {
        if !self._resolve_args(seg, ct) { return false; }
        if seg->generic_args.size() < gps.size() {
            for var i: usize = 0; i < gps.size(); ++i {
                var gp = gps[i];
                if (gp != &null) && (gp->default_type != &null) { self._demand_default(gp, primary); }
            }
        }
        var ga = GenericArgs(self.sc);
        if !ga.collect(primary, gps, seg->generic_args, false, out) { ct->poison(); return false; }
        if ga.inst_dependent { self._mark_inst_dependent(ct); }
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

    /// A default on \p primary's parameter list, canonical or null. Resolved
    /// in the PRIMARY's scope with the primary's own params in frame (`<T,
    /// U = T>`), never in the use site's. A foreign primary's defaults were
    /// resolved by its own TU: read the slot.
    priv fn _demand_default(self, gp: *GenericParamDecl, primary: *Decl) -> *Type {
        var t = gp->default_type;
        if t == &null { return &null; }
        if self._foreign(primary) { return t->canonical; }
        if self.sc->rstate.type_done(t) { return t->canonical; }

        var saved = self._enter_decl_scope(primary);
        self.dispatch_type(t);
        self._leave_decl_scope(&saved);
        return t->canonical;
    }

    // === Aliases (the demand-driven core) ====================================

    /// Canonical of what \p td names, expanding through any chain of aliases,
    /// or null. Null + Errored state = diagnosed (cycle or bad target).
    /// Null + Resolved state = the target is dependent.
    fn _expand_alias(self, td: *TypeAliasDecl, at: SourceRange) -> *Type {
        if self._foreign(static_cast::<*Decl>(td)) {
            if td->aliased == &null { return &null; }
            return td->aliased->canonical;   // its own TU's T already settled it.
        }

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
        // Alias-chain depth has its own budget, checked BEFORE the resolution
        // stack's: it is the tighter of the two by default (64 vs 256) and the
        // one whose message can name a flag that actually helps. A chain of
        // re-exported aliases is the realistic way to hit this, and it says
        // nothing about how deeply nested the surrounding scopes are.
        var alias_cap = static_cast::<usize>(self.sc->opts.max_type_alias_depth);
        if (alias_cap > 0) && (self._alias_depth >= alias_cap) {
            var nm   = self.sc->ctx->get_spelling(td->name);
            var wider = alias_cap * 2;
            self.sc->diag->report(DiagID::R036E, at.start,
                f"type alias '{nm}\x27 expands through more than {alias_cap} nested aliases"
            ).first(at)
             .note(DiagID::R036N, td->range.start,
                f"'{nm}\x27 is declared here; the chain continues from its target"
            ).first(td->range)
             .fix(f"flatten the alias chain, or raise the limit with --cmax-type-alias-depth={wider}")
             .emit();
            self.sc->rstate.set_decl_state(td, ResolveState::Errored);
            return &null;
        }

        // Backstop for the case the alias budget cannot catch: the alias sits
        // so deep inside other resolution work that the shared stack fills up
        // first. Different cause, so a different flag to name.
        if self.sc->rstate.at_depth_limit() {
            var nm2   = self.sc->ctx->get_spelling(td->name);
            var scap  = self.sc->rstate.max_depth();
            self.sc->diag->report(DiagID::R036E, at.start,
                f"resolving type alias '{nm2}\x27 exceeded the nested scope limit ({scap})"
            ).first(at)
             .fix("raise the limit with --cmax-scope-depth, or reduce the nesting around this alias")
             .emit();
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
        // inside module M means M::Inner regardless of who wrote `X`, and the
        // `T` in `class <T> Box { type Elem = T }` is Box's whoever demands
        // Elem first. Self inside an alias body is its ENCLOSING type.
        var saved = self._enter_decl_scope(static_cast::<*Decl>(td));
        ++(self._alias_depth);
        self.dispatch_type(td->aliased);
        --(self._alias_depth);
        self._leave_decl_scope(&saved);

        var ok = !td->aliased->is_poisoned();
        if !ok { td->poison(); }
        self.sc->rstate.finish_decl(static_cast::<*Decl>(td), ok);
        return (td->aliased->canonical) if (ok) else (&null);
    }

    // === Alias visibility ====================================================

    /// Visibility as an ordinal, widest last.
    ///
    /// `None` means no keyword was written, and the default then depends on
    /// where the decl sits (pub at top level, priv for a class member, pub for
    /// a struct member). The laundering check never has to settle that: it
    /// fires only when a target's visibility was written DOWN explicitly, so an
    /// unwritten one ranks as the widest thing it could be and the check stays
    /// quiet. The bias is deliberate -- a false positive here rejects a legal
    /// program, and the member defaults belong to AccessCheck, not to T.
    priv fn _vis_rank(self, v: VisibilityKind) -> i32 {
        switch v {
            case VisibilityKind::Private   { return 0; }
            case VisibilityKind::Protected { return 1; }
            case VisibilityKind::Internal  { return 2; }
            default                        { return 3; }  // Public, and None-as-widest.
        }
    }

    priv fn _vis_word(self, v: VisibilityKind) -> string {
        switch v {
            case VisibilityKind::Private   { return "priv";     }
            case VisibilityKind::Protected { return "prot";     }
            case VisibilityKind::Internal  { return "internal"; }
            default                        { return "pub";      }
        }
    }

    /// An alias introduces a second NAME, not a second entity, so it must not
    /// publish what its target did not. `pub type B = A` over a `priv A` hands
    /// every importer a usable name for A: they can declare values of it, name
    /// it in their own signatures and reach its members, none of which the
    /// author of A allowed.
    ///
    /// Reported at the alias, once, rather than at each use: the use sites are
    /// in other files and the mistake is not theirs, and diagnosing there would
    /// repeat one error per caller.
    priv fn _check_alias_visibility(self, td: *TypeAliasDecl) {
        if td == &null              { return; }
        if td->aliased == &null     { return; }
        if td->is_poisoned()        { return; }

        var alias_rank = self._vis_rank(td->visibility);
        if alias_rank <= 0 { return; }   // a priv alias can widen nothing.

        var worst: *Decl = &null;
        var worst_rank   = alias_rank;
        self._narrowest_in_type(td->aliased, &worst, &worst_rank);
        if worst == &null { return; }

        var anm = self.sc->ctx->get_spelling(td->name);
        var tnm = self._decl_name_str(worst);
        var aw  = self._vis_word(td->visibility);
        var tw  = self._vis_word(worst->visibility);

        var b = self.sc->diag->report(DiagID::R050E, td->range.start,
            f"{aw} type alias \x27{anm}\x27 names \x27{tnm}\x27, which is {tw}"
        );
        b.first(td->range);
        b.note(DiagID::R050N, worst->range.start,
            f"\x27{tnm}\x27 is declared {tw} here"
        ).first(worst->range);
        // The narrowing edit is the safe one to offer: widening the target
        // publishes a second entity, which is a decision only its author makes.
        if td->visibility_range().is_valid() {
            b.fix(td->visibility_range(), tw,
                f"make the alias {tw}, matching \x27{tnm}\x27");
        }
        b.emit();
    }

    /// Narrowest decl named anywhere in \p t, recorded through the out-params.
    ///
    /// Walks the SYNTACTIC target, never its canonical: canonicalization erases
    /// both the intermediate aliases and the module path segments, and each of
    /// those launders exactly as well as the final type does. `pub type C = B`
    /// over a `priv type B` leaks through B; `pub type D = M::T` leaks through a
    /// priv M. Every component counts too -- a pointer, vector, tuple, map or
    /// generic argument hands the target over just as directly.
    priv fn _narrowest_in_type(self, t: *Type, worst: *(*Decl), worst_rank: *i32) {
        if t == &null { return; }

        switch t->kind {
            case TypeKind::ChainType {
                var ct = cast::<ChainType>(t);
                for var i: usize = 0; i < ct->segments.size(); ++i {
                    var seg = ct->segments.get(i);
                    self._consider_vis(seg->resolved_decl, worst, worst_rank);
                    for var j: usize = 0; j < seg->generic_args.size(); ++j {
                        self._narrowest_in_type(seg->generic_args.get(j)->ty, worst, worst_rank);
                    }
                }
            }
            case TypeKind::RecordType {
                self._consider_vis(cast::<RecordType>(t)->decl, worst, worst_rank);
                var rt = cast::<RecordType>(t);
                for var i: usize = 0; i < rt->args.size(); ++i {
                    self._narrowest_in_type(*(rt->args.get(i)), worst, worst_rank);
                }
            }
            case TypeKind::PointerType {
                self._narrowest_in_type(cast::<PointerType>(t)->pointee, worst, worst_rank);
            }
            case TypeKind::NullableType {
                self._narrowest_in_type(cast::<NullableType>(t)->inner, worst, worst_rank);
            }
            // These three stay even though `[T]`, `{T}` and `{K: V}` now
            // CANONICALIZE to records: this walk is over the alias's SYNTAX,
            // where they are still Vector/Set/Map nodes. The RecordType arm
            // above never sees them, so dropping these let `pub type L = [P]`
            // leak a priv P without a word.
            case TypeKind::VectorType {
                self._narrowest_in_type(cast::<VectorType>(t)->element, worst, worst_rank);
            }
            case TypeKind::SetType {
                self._narrowest_in_type(cast::<SetType>(t)->element, worst, worst_rank);
            }
            case TypeKind::MapType {
                var mt = cast::<MapType>(t);
                self._narrowest_in_type(mt->key,   worst, worst_rank);
                self._narrowest_in_type(mt->value, worst, worst_rank);
            }
            case TypeKind::FixedArrayType {
                self._narrowest_in_type(cast::<FixedArrayType>(t)->element, worst, worst_rank);
            }
            case TypeKind::TupleType {
                var tt = cast::<TupleType>(t);
                for var i: usize = 0; i < tt->elements.size(); ++i {
                    self._narrowest_in_type(*(tt->elements.get(i)), worst, worst_rank);
                }
            }
            case TypeKind::FunctionPointerType {
                var ft = cast::<FunctionPointerType>(t);
                for var i: usize = 0; i < ft->params.size(); ++i {
                    self._narrowest_in_type(*(ft->params.get(i)), worst, worst_rank);
                }
                self._narrowest_in_type(ft->return_type, worst, worst_rank);
            }
            case TypeKind::CXXLValueRefType {
                self._narrowest_in_type(cast::<CXXLValueRefType>(t)->referee, worst, worst_rank);
            }
            case TypeKind::CXXRValueRefType {
                self._narrowest_in_type(cast::<CXXRValueRefType>(t)->referee, worst, worst_rank);
            }
            case TypeKind::QualifiedType {
                self._narrowest_in_type(cast::<QualifiedType>(t)->inner, worst, worst_rank);
            }
            default { }
        }
    }

    priv fn _consider_vis(self, d: *Decl, worst: *(*Decl), worst_rank: *i32) {
        if d == &null { return; }
        // A generic parameter of the alias itself has no visibility to leak;
        // whatever it is instantiated with is checked at the instantiation.
        if isa::<GenericParamDecl>(d) { return; }
        var r = self._vis_rank(d->visibility);
        if r < (*worst_rank) {
            (*worst_rank) = r;
            (*worst)      = d;
        }
    }

    /// One error at the use that closed the loop, one note per link, in the
    /// order the resolver walked them. Every decl on the loop is marked
    /// Errored so no other use of any of them reports again.
    priv fn _report_alias_cycle(self, td: *TypeAliasDecl, at: SourceRange) {
        var idx = self.sc->rstate.cycle_index(static_cast::<*Decl>(td));
        var nm  = self.sc->ctx->get_spelling(td->name);

        var b = self.sc->diag->report(DiagID::R035E, at.start,
            f"type alias '{nm}' is defined in terms of itself"
        );
        b.first(at);

        if idx != usize(-1) {
            var stack = &(self.sc->rstate.stack);
            for var i: usize = idx; i < stack->size(); ++i {
                var fr = (*stack)[i];
                if fr.decl == &null { continue; }
                var lnm = self._decl_name_str(fr.decl);
                b.note(DiagID::R035N, fr.decl->range.start,
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

    /// The field whose type is being resolved, for EVAL.md 1.2a
    /// (_own_class_constant); null elsewhere.
    priv var _cur_field: *FieldDecl = &null;
    /// Eval fn bodies around the walk: an `eval for` there is a plain loop,
    /// whose binding is no constant.
    priv var _eval_fns: u32 = 0;
    /// Bindings of the unrolled `eval for`s around the walk: each copy's
    /// constant (EVAL.md §5), usable in a computed value.
    priv var _ef_binds: vec::<*Decl>;

    fn traverse_ranged_for_stmt(self, n: *RangedForStmt) -> *RangedForStmt {
        var pushed = false;
        if (n != &null) && n->is_eval && (self._eval_fns == 0) && (n->bindings.size() == 1) && (n->bindings[0].decl != &null) {
            self._ef_binds.push_back(static_cast::<*Decl>(n->bindings[0].decl));
            pushed = true;
        }
        var r = RecursiveASTVisitor::<TypeResolution>::traverse_ranged_for_stmt(n);
        if pushed { self._ef_binds.pop_back(); }
        return r;
    }

    fn traverse_field_decl(self, n: *FieldDecl) -> *FieldDecl {
        var saved = self._cur_field;
        self._cur_field = n;
        var r = RecursiveASTVisitor::<TypeResolution>::traverse_field_decl(n);
        self._cur_field = saved;
        return r;
    }

    fn traverse_function_decl(self, n: *FunctionDecl) -> *FunctionDecl {
        if n == &null { return n; }

        var saved_dc  = self.cur_dc;
        var saved_ool = self._ool_lexical;
        if (n->semantic_dc != &null) && (n->semantic_dc != n->lexical_dc) {
            self.cur_dc = reinterpret_cast::<*DeclContext>(n->semantic_dc);
            // Owning scope in another TU: see NameLookup::unqualified_out_of_line.
            var lex = reinterpret_cast::<*DeclContext>(n->lexical_dc);
            if (lex != &null) && (NameLookup::tu_of(self.cur_dc) != NameLookup::tu_of(lex)) {
                self._ool_lexical = lex;
            }
        } else {
            self.cur_dc = static_cast::<*DeclContext>(n);
        }

        // An out-of-line method's Self is the class it was written FOR.
        var pushed_self = false;
        if (n->semantic_dc != &null) && (n->semantic_dc != n->lexical_dc) {
            var home = reinterpret_cast::<*DeclContext>(n->semantic_dc);
            if home->is_type_scope() && (home->owner_decl() != &null) {
                var hs = self._self_of_scope(NameLookup::representative(home->owner_decl()));
                if hs != &null {
                    self._selfs.push_back(hs);
                    pushed_self = true;
                }
            }
        }

        self._push_frame(NameLookup::representative(static_cast::<*Decl>(n)), n->generic_params);

        // The `self` receiver has no written type (ParamDecl::create_self). T
        // is the one writer of ParamDecl::type_ for it: a SelfType node whose
        // canonical is the enclosing record. This is what lets N bind
        // `self.x` without asking T a question at every use.
        self._synthesize_receiver(n);

        // #68: spec args on a `<> f<...>` head are types to resolve; on a
        // Primary-classified head with NO bound params they DECLARE params
        // and must not be looked up. Pre-mark them done so dispatch skips.
        self._premark_primary_spec_args(n->spec_kind, n->generic_params, n->spec_args);

        if n->is_eval() { self._eval_fns += 1; }
        var out = RecursiveASTVisitor::<TypeResolution>::traverse_function_decl(n);
        if n->is_eval() { self._eval_fns -= 1; }

        self._refine_spec_kind(static_cast::<*Decl>(n), n->generic_params, n->spec_args);

        self._pop_frame();
        if pushed_self { self._selfs.pop_back(); }
        self.cur_dc       = saved_dc;
        self._ool_lexical = saved_ool;
        return out;
    }

    /// sc->lookup.unqualified, rerouted only for a walk that starts in the
    /// foreign owning chain of an out-of-line body (NameResolution::
    /// _lookup_unqualified, same rule). A walk from a scope of this TU -- or of
    /// an imported Kairo file T is reading, whose names that file keys -- is
    /// left exactly as it was.
    priv fn _lookup_unqualified(self, from: *DeclContext, imm: u32) -> SemaLookupResult {
        var name = DeclName::ident(imm);
        if (self._ool_lexical == &null) || (from == &null) {
            return self.sc->lookup.unqualified(from, name);
        }
        if NameLookup::tu_of(from) == NameLookup::tu_of(self._ool_lexical) {
            return self.sc->lookup.unqualified(from, name);
        }
        var imms = self.sc->ctx->get_imm_table();
        var sp   = (imms->get_ident(imm)) if (imms != &null) else ("");
        return self.sc->lookup.unqualified_out_of_line(from, name, sp, self._ool_lexical);
    }

    fn traverse_closure_expr(self, n: *ClosureExpr) -> *ClosureExpr {
        if n == &null { return n; }
        self._push_frame(&null, n->generic_params);
        var out = RecursiveASTVisitor::<TypeResolution>::traverse_closure_expr(n);
        self._pop_frame();
        return out;
    }

    fn traverse_class_decl(self, n: *ClassDecl) -> *ClassDecl {
        if n == &null { return n; }
        var saved = self.cur_dc;
        self.cur_dc = static_cast::<*DeclContext>(n);
        self._selfs.push_back(self._self_record(NameLookup::representative(static_cast::<*Decl>(n))));
        self._push_frame(NameLookup::representative(static_cast::<*Decl>(n)), n->generic_params);
        self._premark_primary_spec_args(n->spec_kind, n->generic_params, n->spec_args);
        var out = RecursiveASTVisitor::<TypeResolution>::traverse_class_decl(n);
        self._refine_spec_kind(static_cast::<*Decl>(n), n->generic_params, n->spec_args);
        // A Primary the parser could not tell from a spec (#68) is only
        // classified now. Register it late; a use that already minted an
        // implicit node for these args gets the "after instantiation" error,
        // which is the right answer for a spec written below its first use.
        if (decl_spec_kind(static_cast::<*Decl>(n)) == SpecKind::Explicit)
        && (decl_instantiated_from(static_cast::<*Decl>(n)) == &null) {
            self._register_type_spec(static_cast::<*Decl>(n));
        }
        self._pop_frame();
        self._selfs.pop_back();
        self.cur_dc = saved;
        return out;
    }

    fn traverse_struct_decl(self, n: *StructDecl) -> *StructDecl {
        if n == &null { return n; }
        var saved = self.cur_dc;
        self.cur_dc = static_cast::<*DeclContext>(n);
        self._selfs.push_back(self._self_record(NameLookup::representative(static_cast::<*Decl>(n))));
        self._push_frame(NameLookup::representative(static_cast::<*Decl>(n)), n->generic_params);
        self._premark_primary_spec_args(n->spec_kind, n->generic_params, n->spec_args);
        var out = RecursiveASTVisitor::<TypeResolution>::traverse_struct_decl(n);
        self._refine_spec_kind(static_cast::<*Decl>(n), n->generic_params, n->spec_args);
        // A Primary the parser could not tell from a spec (#68) is only
        // classified now. Register it late; a use that already minted an
        // implicit node for these args gets the "after instantiation" error,
        // which is the right answer for a spec written below its first use.
        if (decl_spec_kind(static_cast::<*Decl>(n)) == SpecKind::Explicit)
        && (decl_instantiated_from(static_cast::<*Decl>(n)) == &null) {
            self._register_type_spec(static_cast::<*Decl>(n));
        }
        self._pop_frame();
        self._selfs.pop_back();
        self.cur_dc = saved;
        return out;
    }

    fn traverse_union_decl(self, n: *UnionDecl) -> *UnionDecl {
        if n == &null { return n; }
        var saved = self.cur_dc;
        self.cur_dc = static_cast::<*DeclContext>(n);
        self._selfs.push_back(self._self_record(NameLookup::representative(static_cast::<*Decl>(n))));
        self._push_frame(NameLookup::representative(static_cast::<*Decl>(n)), n->generic_params);
        self._premark_primary_spec_args(n->spec_kind, n->generic_params, n->spec_args);
        var out = RecursiveASTVisitor::<TypeResolution>::traverse_union_decl(n);
        self._refine_spec_kind(static_cast::<*Decl>(n), n->generic_params, n->spec_args);
        // A Primary the parser could not tell from a spec (#68) is only
        // classified now. Register it late; a use that already minted an
        // implicit node for these args gets the "after instantiation" error,
        // which is the right answer for a spec written below its first use.
        if (decl_spec_kind(static_cast::<*Decl>(n)) == SpecKind::Explicit)
        && (decl_instantiated_from(static_cast::<*Decl>(n)) == &null) {
            self._register_type_spec(static_cast::<*Decl>(n));
        }
        self._pop_frame();
        self._selfs.pop_back();
        self.cur_dc = saved;
        return out;
    }

    fn traverse_interface_decl(self, n: *InterfaceDecl) -> *InterfaceDecl {
        if n == &null { return n; }
        var saved = self.cur_dc;
        self.cur_dc = static_cast::<*DeclContext>(n);
        self._selfs.push_back(self._self_record(NameLookup::representative(static_cast::<*Decl>(n))));
        self._push_frame(NameLookup::representative(static_cast::<*Decl>(n)), n->generic_params);
        var out = RecursiveASTVisitor::<TypeResolution>::traverse_interface_decl(n);
        self._pop_frame();
        self._selfs.pop_back();
        self.cur_dc = saved;
        return out;
    }

    fn traverse_enum_decl(self, n: *EnumDecl) -> *EnumDecl {
        if n == &null { return n; }
        var saved = self.cur_dc;
        self.cur_dc = static_cast::<*DeclContext>(n);
        self._selfs.push_back(self._self_record(NameLookup::representative(static_cast::<*Decl>(n))));
        self._push_frame(NameLookup::representative(static_cast::<*Decl>(n)), n->generic_params);
        var out = RecursiveASTVisitor::<TypeResolution>::traverse_enum_decl(n);
        self._check_enum_underlying(n);
        self._merge_enum_open(n);
        self._pop_frame();
        self._selfs.pop_back();
        self.cur_dc = saved;
        return out;
    }

    /// `extend Foo<T> { }`: the target is resolved FIRST, in the enclosing
    /// scope (its own params in frame), and then becomes Self for the body.
    fn traverse_extension_decl(self, n: *ExtensionDecl) -> *ExtensionDecl {
        if n == &null { return n; }
        var saved = self.cur_dc;

        self._push_frame(NameLookup::representative(static_cast::<*Decl>(n)), n->generic_params);
        if n->target != &null { self.dispatch_type(n->target); }

        // Self is the target as WRITTEN, args and all, after it resolved:
        // `extend <T> Wrap<Box<T>>` reads `self.inner` as Box<T>, and the T
        // there is the extension's, the one its signatures name. Any target,
        // not just a record -- extending primitives and builtins is legal,
        // and `Self` inside `extend i32` is i32.
        var self_ty = self._self_of_scope(static_cast::<*Decl>(n));
        var pushed = false;
        if self_ty != &null {
            self._selfs.push_back(self_ty);
            pushed = true;
        }

        self.cur_dc = static_cast::<*DeclContext>(n);
        var out = RecursiveASTVisitor::<TypeResolution>::traverse_extension_decl(n);

        if pushed { self._selfs.pop_back(); }
        self._pop_frame();
        self.cur_dc = saved;
        return out;
    }

    /// True when `d`'s names live in another TU. DAG order guarantees that
    /// TU's T already ran, so its Type nodes are READ, never dispatched:
    /// re-dispatching consults a per-TU memo that says "unresolved", re-runs
    /// lookups from the wrong TU, and reports foreign errors into this sink.
    priv fn _foreign(self, d: *Decl) -> bool {
        var c = NameLookup::ctx_of(d);
        return (c != &null) && (c != self.sc->ctx);
    }

    fn traverse_module_decl(self, n: *ModuleDecl) -> *ModuleDecl {
        if n == &null { return n; }
        var saved = self.cur_dc;
        if !n->is_anonymous { self.cur_dc = static_cast::<*DeclContext>(n); }
        var out = RecursiveASTVisitor::<TypeResolution>::traverse_module_decl(n);
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
        self._push_frame(NameLookup::representative(static_cast::<*Decl>(n)), n->generic_params);
        for var i: usize = 0; i < n->generic_params.size(); ++i {
            self.dyn()->dispatch_decl(*(n->generic_params.get(i)));
        }
        if n->requires_clause != &null { n->requires_clause = self.dyn()->dispatch_expr(n->requires_clause); }
        self._pop_frame();
        self._expand_alias(n, n->range);
        self._check_alias_visibility(n);
        return n;
    }

    // --- frame helpers ----------------------------------------------------------

    priv fn _push_frame(self, owner: *Decl, params: FrozenList::<*GenericParamDecl>) {
        var fr = GenericFrame{};
        fr.owner  = owner;
        fr.params = params;
        self.frames.push_back(fr);

        // THE one place a param learns its declarer. Every canonical
        // GenericParamType is uniqued on (fr.owner, index) -- see
        // _type_of_decl -- so stamping from the same value here is what makes
        // `param -> owner` and `canonical -> owner` the same answer, which is
        // what ChainBinding's bound lookup stands on. Guarded on null so a
        // closure frame (owner null by construction) never clears a real
        // owner and a re-entered frame is idempotent.
        if owner == &null { return; }
        for var i: usize = 0; i < params.size(); ++i {
            var gp = params[i];
            if gp == &null { continue; }
            if gp->owner == &null { gp->owner = owner; }
        }
    }

    priv fn _pop_frame(self) {
        if !self.frames.empty() { self.frames.pop_back(); }
    }

    /// Set the resolver's lexical state to \p d's DECLARATION scope, for
    /// resolving its types outside walk order: cur_dc to its semantic dc, the
    /// generic frames and selfs of every enclosing type scope and function,
    /// outermost first, then \p d's own generic params. Pair with
    /// _leave_decl_scope, which restores exactly what this returns.
    ///
    /// The rule (RESOLUTION.md §2.6): demand order may change WHEN a
    /// declaration's types resolve, never WHAT they resolve to. So the demand
    /// site's frames are cleared, not kept underneath -- a `T` visible where
    /// the alias was USED is a different `T`.
    ///
    /// The owner walk skips Block and Lambda scopes rather than stopping at
    /// them: a statement-scope decl sits in a Block, and the function's
    /// params (`fn <T> f() { type A = *T }`) are past it. A closure's
    /// generic params are not rebuilt (its frame has no owner decl).
    ///
    /// A decl with no semantic dc (a statement-scope alias) keeps the whole
    /// current state: see the branch below for why that state is its own.
    ///
    /// `ltypes` is the one exception to "cleared": it is KEPT for a local
    /// decl. Local types live on that stack and in no table, so clearing it
    /// would lose `fn f() { struct S { } type A = S }`; and a local decl can
    /// only be demanded from inside its own function, where the stack is
    /// already the right one. For any other decl it is cleared.
    priv fn _enter_decl_scope(self, d: *Decl) -> SavedDeclScope {
        var saved = SavedDeclScope{};
        saved.cur_dc = self.cur_dc;
        saved.frames = self.frames;
        saved.selfs  = self._selfs;
        saved.ltypes = self.ltypes;

        var home = reinterpret_cast::<*DeclContext>(d->semantic_dc);
        if home == &null {
            // No scope home: a statement-scope ALIAS (the parser tables and
            // links local classes, not local aliases). Its name enters
            // ltypes only when the walk reaches its DeclStmt, which resolves
            // it there and then, so every later use is a memo hit. It is
            // therefore only ever resolved in walk order, where the walk's
            // state already IS its declaration scope: keep it.
            var own0 = decl_generic_params(d);
            if own0.size() > 0 { self._push_frame(NameLookup::representative(d), own0); }
            return saved;
        }
        self.cur_dc = home;
        self.frames.clear();
        self._selfs.clear();

        // Innermost first; pushed reversed below.
        var owners = vec::<*Decl>();
        var local  = false;
        var c = home;
        while c != &null {
            if c->is_translation_unit() || (c->dc_kind == DeclContextKind::Module) { break; }
            var o = c->owner_decl();
            if c->is_type_scope() || c->is_function() {
                if o != &null { owners.push_back(o); }
            }
            if !c->is_type_scope() { local = true; }      // Function, Lambda, Block.
            c = c->dc_parent;
        }
        if !local { self.ltypes.clear(); }

        // The same values the walk's traverse_* push, from the same helpers.
        var n = owners.size();
        for var i: usize = 0; i < n; ++i {
            var o   = owners[(n - 1) - i];
            var rep = NameLookup::representative(o);
            self._push_frame(rep, decl_generic_params(o));
            if !isa::<FunctionDecl>(o) {
                var st = self._self_of_scope(rep);
                if st != &null { self._selfs.push_back(st); }
            }
        }

        var own = decl_generic_params(d);
        if own.size() > 0 { self._push_frame(NameLookup::representative(d), own); }
        return saved;
    }

    priv fn _leave_decl_scope(self, saved: *SavedDeclScope) {
        self.cur_dc = saved->cur_dc;
        self.frames = saved->frames;
        self._selfs = saved->selfs;
        self.ltypes = saved->ltypes;
    }

    // === Receiver synthesis ===================================================

    priv fn _synthesize_receiver(self, f: *FunctionDecl) {
        var owner = self._current_self();
        for var i: usize = 0; i < f->params.size(); ++i {
            var p = f->params[i];
            if p == &null { continue; }
            if !p->is_self { continue; }
            if p->type_ != &null { continue; }   // idempotent re-run.
            if owner == &null { continue; }      // free fn with self: N diagnosed.

            var st = SelfType::create(self.sc->ctx, p->range);
            st->canonical = owner;
            // `const self` is the implicit object parameter of a const method:
            // its object is `const Record`, and that is its canonical, as an
            // imported const method's `this` pointee is. Overload resolution
            // ranks the receiver on it ([over.match.funcs]/4).
            if (st->canonical != &null) && p->is_const {
                st->canonical = self.sc->types->qualified(st->canonical, QUAL_CONST());
            }
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
        var kind = decl_spec_kind(d);
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
        if concrete { decl_set_spec_kind(d, SpecKind::Explicit); }
    }

    // === Enum underlying ========================================================

    /// `@open` on any declaration of an enum opens all of them: the forward
    /// declaration `@open enum E derives u8` and the definition are one
    /// enum, and whichever decl a reader reaches must answer alike. Every
    /// link is visited, so the last visit leaves the whole ring agreed.
    priv fn _merge_enum_open(self, n: *EnumDecl) {
        var head = n->first_decl();
        if head == &null { return; }
        var any = false;
        var cur = head;
        while true {
            if cur->is_open { any = true; }
            cur = cur->next_in_chain();
            if cur == head { break; }
        }
        if !any { return; }
        // `@open enum E` forward-declares what turns out to be an ADT: the
        // parser saw no body, so it could not reject it there.
        var def = n->definition();
        if (def != &null) && def->is_adt {
            if n->is_open {
                var k  = self.sc->imm_table()->find_ident(LangAttrs::open_enum());
                var ar = (n->attribute_range(k)) if (k != u32(-1)) else (n->range);
                if !ar.is_valid() { ar = n->range; }
                var an = "\x27@" + LangAttrs::open_enum() + "\x27";
                var b = self.sc->diag->report(DiagID::SC001E, ar.start,
                    an + " does not apply to an ADT enum: no cast makes its tag, so it is always closed");
                b.first(ar);
                b.note(def->name.range.start, "its definition has payload variants");
                b.remove(ar, "remove " + an);
                b.emit();
                n->is_open = false;
            }
            return;
        }
        cur = head;
        while true {
            cur->is_open = true;
            cur = cur->next_in_chain();
            if cur == head { break; }
        }
    }

    priv fn _check_enum_underlying(self, n: *EnumDecl) {
        if n->underlying == &null { return; }
        var c = canon_unqual(n->underlying->canonical);
        if c == &null { return; }   // poisoned or dependent; already handled.
        if isa::<BuiltinType>(c) && builtin_info(cast::<BuiltinType>(c)->builtin)->is_integer() {
            if n->is_adt { self._check_adt_tag_fits(n, builtin_info(cast::<BuiltinType>(c)->builtin)); }
            return;
        }
        self.sc->diag->report(DiagID::R046E, n->underlying->range.start,
            "an enum's underlying type must be a primitive integer type"
        ).first(n->underlying->range).emit();
        n->underlying->poison();
    }

    /// An ADT's `derives` type is its tag's (EnumLayoutLowering), and its
    /// tags are the variant positions `0..N-1`: a type with fewer than N
    /// non-negative values cannot hold them. A plain enum's values are
    /// checked as literals of the type instead (LiteralTyping).
    priv fn _check_adt_tag_fits(self, n: *EnumDecl, bi: *BuiltinInfo) {
        var bits = bi->bits;
        if bi->is_signed() && (bits > 0) { bits = bits - 1; }
        if (bits == 0) || (bits >= 32) { return; }   // the target-width pair is at least 32 bits.
        var cap = usize(1) << bits;
        var count = n->variants.size();
        if count <= cap { return; }
        var want = ("u16") if (count <= 65536) else ("u32");
        var b = self.sc->diag->report(DiagID::R001E, n->underlying->range.start,
            f"an enum's underlying type is its tag's, and '{bi->spelling}' cannot hold its {count} variants");
        b.first(n->underlying->range, f"holds {cap} tag values");
        b.note(n->name.range.start, f"'{self._decl_name_str(static_cast::<*Decl>(n))}' declares {count} variants, tagged 0 to {count - 1}");
        b.fix(n->underlying->range, want, f"declare it 'derives {want}\x27");
        b.emit();
        n->underlying->poison();
    }

    // === Decl helpers ===========================================================

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

    /// Probe the enclosing type bodies, innermost first, for `imm`. The escape
    /// hatch for a scope the DC chain cannot reach -- today only an `extend`
    /// body, whose parent is the TU rather than the type it extends.
    ///
    /// An unfilled instance (`extend Box<i32>` before M2) has an empty table;
    /// its nested types live on the pattern it was instantiated from, so walk
    /// that instead (#12), the same substitution `Self::Inner` makes above.
    /// An instance of an IMPORTED template is filled first (`extend
    /// cont<i32>` then bare `size_type`), and its table lives in the
    /// header's TU, keyed by that TU's imms -- so the probe carries the
    /// spelling, as the `::` walk does, rather than trusting index agreement.
    priv fn _lookup_in_selfs(self, imm: u32, spelling: string) -> SemaLookupResult {
        var n = self._selfs.size();
        for var i: usize = 0; i < n; ++i {
            var d = self._self_decl_of(self._selfs[(n - 1) - i]);
            if d == &null { continue; }   // `extend i32`: no scope to look in.
            MemberLookup::ensure_filled(self.sc, d);
            // An unfilled instance, or a dependent `Store<*P>` (a partial's
            // own Self, `extend <P> Store<*P>`): the body the args select.
            var b = self.sc->record_body(self._selfs[(n - 1) - i]);
            if b != &null { d = b; }
            var dc = NameLookup::context_of(d);
            if dc == &null { continue; }
            var r = self.sc->lookup.in_context(dc, DeclName::ident(imm), spelling);
            if r.found() { return r; }
        }
        return SemaLookupResult::not_found();
    }

    priv fn _lookup_local_type(self, imm: u32) -> *Decl {
        if imm == u32(-1) { return &null; }
        var n = self.ltypes.size();
        for var i: usize = 0; i < n; ++i {
            var fr = &(self.ltypes[(n - 1) - i]);
            var m = fr->names.size();
            for var j: usize = 0; j < m; ++j {
                if fr->names[(m - 1) - j] == imm { return fr->decls[(m - 1) - j]; }
            }
        }
        return &null;
    }

    priv fn _local_type_imm(self, d: *Decl) -> u32 {
        if isa::<ClassDecl>(d)     { return self._name_imm(cast::<ClassDecl>(d)->name);     }
        if isa::<StructDecl>(d)    { return self._name_imm(cast::<StructDecl>(d)->name);    }
        if isa::<UnionDecl>(d)     { return self._name_imm(cast::<UnionDecl>(d)->name);     }
        if isa::<InterfaceDecl>(d) { return self._name_imm(cast::<InterfaceDecl>(d)->name); }
        if isa::<EnumDecl>(d)      { return self._name_imm(cast::<EnumDecl>(d)->name);      }
        if isa::<TypeAliasDecl>(d) { return self._name_imm(cast::<TypeAliasDecl>(d)->name); }
        return u32(-1);
    }

    /// Declared BEFORE its body is walked so a self-referential local type
    /// (`class Node { var next: *Node }`) resolves.
    fn traverse_decl_stmt(self, n: *DeclStmt) -> *DeclStmt {
        if n == &null { return n; }
        if self.dyn()->walkup_decl_stmt(n) == false { return n; }
        if n->decl == &null { return n; }
        var imm = self._local_type_imm(n->decl);
        if (imm != u32(-1)) && !self.ltypes.empty() {
            var fr = &(self.ltypes[self.ltypes.size() - 1]);
            fr->names.push_back(imm);
            fr->decls.push_back(n->decl);
        }
        n->decl = self.dyn()->dispatch_decl(n->decl);
        return n;
    }

    /// Every brace scope is a frame. A function body pushes one too (via
    /// this, from traverse_block) -- a frame per block is cheap and makes
    /// shadowing between sibling blocks right for free.
    fn traverse_compound_stmt(self, n: *CompoundStmt) -> *CompoundStmt {
        if n == &null { return n; }
        self.ltypes.push_back(LocalTypeFrame{});
        var out = RecursiveASTVisitor::<TypeResolution>::traverse_compound_stmt(n);
        self.ltypes.pop_back();
        return out;
    }

    /// Same keyword handling as N: `self` is KwSelf, not an identifier.
    priv fn _name_imm(self, tok: Token) -> u32 {
        return self.sc->ctx->get_ident_imm(tok);
    }

    // === specialization registration =========================================

    priv fn _register_specs_in(self, dc: *DeclContext) {
        if dc == &null { return; }
        var type_body = dc->is_type_scope();
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var d = *(dc->dc_decls.get(i));
            if d == &null { continue; }
            if type_body && isa::<VisibilityGroupDecl>(d) { continue; }   // same rule as N(a) / RAV.
            self._register_spec_decl(d);
        }
    }

    priv fn _register_spec_decl(self, d: *Decl) {
        if isa::<VisibilityGroupDecl>(d) {
            var g = cast::<VisibilityGroupDecl>(d);
            for var i: usize = 0; i < g->members.size(); ++i { self._register_spec_decl(g->members[i]); }
            return;
        }
        if isa::<EvalBlockDecl>(d) {
            var b = cast::<EvalBlockDecl>(d);
            for var i: usize = 0; i < b->body.size(); ++i { self._register_spec_decl(b->body[i]); }
            return;
        }
        if isa::<ModuleDecl>(d) { self._register_specs_in(NameLookup::context_of(d)); return; }

        var k = decl_spec_kind(d);
        // `extend <> Store<bool>` / `extend <P> Store<*P>` are extensions
        // whose TARGET is the specialization; they specialize nothing
        // themselves. Registered, they found no primary and were poisoned
        // silently, which hid their members from codegen (lookup ignores
        // the poison; EmitPlan's scope walk does not).
        if ((k == SpecKind::Explicit) || (k == SpecKind::Partial)) && (!isa::<FunctionDecl>(d)) && (!isa::<ExtensionDecl>(d)) {
            self._register_type_spec(d);            // function specs: OverloadResolution's.
        }
        var child = NameLookup::context_of(d);
        if (child != &null) && child->is_type_scope() { self._register_specs_in(child); }
    }

    /// Resolve a spec's args in ITS scope, find its primary, register.
    /// Idempotent: `instantiated_from` doubles as the done-mark, so the
    /// position warning below fires once per specialization however many
    /// times registration is attempted.
    priv fn _register_type_spec(self, d: *Decl) {
        if d->is_poisoned() { return; }
        if decl_instantiated_from(d) != &null { return; }
        self._warn_if_local_spec(d);
        var primary = self._primary_of_spec(d);
        if primary == &null { d->poison(); return; }        // diagnosed inside.
        decl_set_instantiated_from(d, primary);

        var saved = self._enter_decl_scope(d);

        var sargs = decl_spec_args(d);
        var args  = vec::<*Type>();
        var ok    = true;
        var dep   = false;
        for var i: usize = 0; i < sargs.size(); ++i {
            var a = sargs[i];
            if a == &null { ok = false; continue; }
            self.dispatch_type(a);                    // memoized; the main walk's dispatch is then a no-op.
            if a->is_poisoned() || (a->canonical == &null) { ok = false; continue; }
            // `Traits<Box<T>, Args...>`: the registry never matches a pack
            // pattern (InstantiationRegistry::_match), so the partial could
            // never be selected here while C++ would select it per instance.
            // Dropped, as it was before `Args...` had a canonical (ticketed).
            if isa::<PackExpansionType>(a) { ok = false; continue; }
            if a->is_dependent() || a->is_instantiation_dependent() { dep = true; }
            args.push_back(a->canonical);
        }

        self._leave_decl_scope(&saved);
        if !ok { d->poison(); return; }

        if (decl_spec_kind(d) == SpecKind::Partial) || dep {
            // Selection by a `requires` clause needs the clause evaluated per
            // instance (requires-dispatch, eval lowering), and neither
            // exists: registered, the pattern alone would select it whether
            // or not the clause holds. Refused, so the primary keeps every
            // instance and nothing is silently misselected.
            if decl_requires_clause(d) != &null {
                self._requires_partial_unsupported(d);
                d->poison();
                return;
            }
            // A pattern: the registry matches it against each concrete
            // instance's args as the instance is minted. Never a
            // RecordType::decl. The representative, because its params'
            // GenericParamType owner is, and matching binds by owner.
            self.sc->instances->register_partial(primary, NameLookup::representative(d));
            return;
        }

        var e = self.sc->instances->register_explicit(primary, &args, d, self.sc->ctx->fid);
        if e == &null { return; }
        if e->decl == d { return; }                  // first spec for these args.

        var nm = self._decl_name_str(d);
        if !e->is_explicit {
            self.sc->diag->report(DiagID::R043E, d->range.start,
                f"explicit specialization of '{nm}' after it was already instantiated with these arguments"
            ).first(d->range)
             .note(DiagID::R043N, e->decl->range.start,
                "first instantiated here; a specialization must precede every use of it")
             .first(e->decl->range).emit();
            d->poison();
            return;
        }
        if e->home_fid != self.sc->ctx->fid {
            self.sc->diag->report(DiagID::R044E, d->range.start,
                f"explicit specialization of '{nm}' redeclared in a different file"
            ).first(d->range)
             .note(DiagID::R044N, e->decl->range.start, "previously declared here").first(e->decl->range)
             .emit();
            d->poison();
            return;
        }
        // Same file, same args, second explicit spec: fwd + def, or a redefinition.
        self._link_spec(e, e->decl, d);
    }

    /// An explicit specialization written inside a function, closure, or
    /// block body. LEGAL in Kairo and unambiguously GLOBAL: specialization
    /// matching is structural on the arguments and not scope-sensitive, so
    /// once the spec exists in a translation unit every use of those
    /// arguments matches it -- including uses that cannot see this
    /// declaration, and including C++ code that includes the emitted header.
    /// There is no scope-restricted form to offer instead, which is why C++
    /// forbids the position outright ([temp.expl.spec]).
    ///
    /// Warned rather than rejected so the message can say what the semantics
    /// ARE, which an error could not. Promote to an error if users ask for
    /// it: warn-to-error is a compatible tightening and the reverse is not.
    ///
    /// Placed in _register_type_spec rather than in traverse_class_decl
    /// because the same late-registration block is duplicated in
    /// traverse_struct_decl and traverse_union_decl; one call site here
    /// covers all three.
    priv fn _warn_if_local_spec(self, d: *Decl) {
        var dc = reinterpret_cast::<*DeclContext>(d->lexical_dc);
        if dc == &null { return; }
        if dc->is_type_scope()       { return; }
        if dc->is_translation_unit() { return; }
        if dc->dc_kind == DeclContextKind::Module { return; }

        var nm = self._decl_name_str(d);
        self.sc->diag->report(DiagID::R045W, d->range.start,
            f"explicit specialization of '{nm}' is written inside a function body"
        ).first(d->range)
         .note(DiagID::R045N, d->range.start,
            f"specializations are global regardless of where they are written; this one applies to every use of '{nm}' in the program, including uses that cannot see this declaration"
        )
         .note(DiagID::R045N, d->range.start,
            "write it at module scope to make that visible")
         .emit();
    }

    /// `struct <P> X<*P> requires pred<P>()`. NameResolution reports the
    /// same thing for the form whose pattern is only its own parameters
    /// (`<P> X<P> requires ...`), which the parser files as a second primary.
    priv fn _requires_partial_unsupported(self, d: *Decl) {
        var rc = decl_requires_clause(d);
        var b = self.sc->diag->report(DiagID::SC001E, d->range.start,
            "a partial specialization selected by 'requires' is not supported yet; the primary is used for every instance");
        b.first(rc->range);
        b.note(DiagID::SC001N, d->range.start,
            "partial specializations are selected by their argument pattern alone (`<P> X<*P>`); write the pattern instead");
        b.emit();
    }

    /// Two partial specializations match \p e's args and neither is more
    /// specialized than the other: C++ rejects the instance, so Kairo does,
    /// at the first written mention of it (one report per instance; later
    /// mentions and unwritten ones -- a substitution -- stay quiet).
    priv fn _ambiguous_partials(self, e: *InstanceEntry, at: SourceRange) {
        e->ambiguity_reported = true;
        var nm = self._decl_name_str(e->primary);
        var b = self.sc->diag->report(DiagID::SC001E, at.start,
            f"ambiguous partial specializations of '{nm}' for these arguments");
        b.first(at);
        b.note(DiagID::SC001N, e->ambiguous_a->range.start, "matches this partial specialization");
        b.note(DiagID::SC001N, e->ambiguous_b->range.start, "and this one, and neither is more specialized than the other");
        b.emit();
    }

    /// The primary this spec specializes: same name, same kind, not itself a
    /// spec, visible from the spec's scope. Sole home of "no primary".
    priv fn _primary_of_spec(self, d: *Decl) -> *Decl {
        var scope = reinterpret_cast::<*DeclContext>(d->semantic_dc);
        var imm   = self._decl_name_imm(d);
        if (scope == &null) || (imm == u32(-1)) { return &null; }
        // A Kairo spec of an IMPORTED primary has its semantic scope in the
        // header's TU, keyed by that TU's imms: probe it by spelling, then
        // fall back to where the spec was written (unqualified_out_of_line).
        // A spec whose scope is this TU's walks exactly as before.
        var r   = SemaLookupResult::not_found();
        var lex = reinterpret_cast::<*DeclContext>(d->lexical_dc);
        if (lex != &null) && (NameLookup::tu_of(scope) != NameLookup::tu_of(lex)) {
            var imms = self.sc->ctx->get_imm_table();
            var sp   = (imms->get_ident(imm)) if (imms != &null) else ("");
            r = self.sc->lookup.unqualified_out_of_line(scope, DeclName::ident(imm), sp, lex);
        } else {
            r = self.sc->lookup.unqualified(scope, DeclName::ident(imm));
        }
        if r.found() {
            for var i: usize = 0; i < r.cell->size(); ++i {
                var c = r.cell->get(i);
                if (c == &null) || (c->kind != d->kind) { continue; }
                if NameLookup::is_specialization(c) { continue; }
                return NameLookup::representative(c);
            }
        }
        var nm = self._decl_name_str(d);
        self.sc->diag->report(DiagID::R042E, d->range.start,
            f"'{nm}' is declared as a specialization, but no primary template named '{nm}' is visible here"
        ).first(d->range).emit();
        return &null;
    }

    /// fwd-declared spec + its definition. Both define -> redefinition.
    priv fn _link_spec(self, e: *InstanceEntry, prev: *Decl, cur: *Decl) {
        var both = false;
        if isa::<ClassDecl>(prev) {
            var a = cast::<ClassDecl>(prev); var b = cast::<ClassDecl>(cur);
            if a->canonical_decl() != b->canonical_decl() { b->set_prev(a); }
            both = a->is_this_definition && b->is_this_definition;
            var def = a->definition();
            a->retarget_canonical((def) if (def != &null) else (a->first_decl()));
        } else if isa::<StructDecl>(prev) {
            var a = cast::<StructDecl>(prev); var b = cast::<StructDecl>(cur);
            if a->canonical_decl() != b->canonical_decl() { b->set_prev(a); }
            both = a->is_this_definition && b->is_this_definition;
            var def = a->definition();
            a->retarget_canonical((def) if (def != &null) else (a->first_decl()));
        } else if isa::<UnionDecl>(prev) {
            var a = cast::<UnionDecl>(prev); var b = cast::<UnionDecl>(cur);
            if a->canonical_decl() != b->canonical_decl() { b->set_prev(a); }
            both = a->is_this_definition && b->is_this_definition;
            var def = a->definition();
            a->retarget_canonical((def) if (def != &null) else (a->first_decl()));
        } else {
            return;
        }
        if both {
            var nm = self._decl_name_str(cur);
            self.sc->diag->report(DiagID::R029E, cur->range.start,
                f"redefinition of specialization '{nm}\x27"
            ).first(cur->range)
             .note(DiagID::R029N, prev->range.start, "previous definition is here").first(prev->range)
             .emit();
            cur->poison();
            return;
        }
        self.sc->instances->retarget(e, NameLookup::representative(prev));
    }

    priv fn _decl_name_imm(self, d: *Decl) -> u32 {
        if isa::<ClassDecl>(d)     { return self._name_imm(cast::<ClassDecl>(d)->name);     }
        if isa::<StructDecl>(d)    { return self._name_imm(cast::<StructDecl>(d)->name);    }
        if isa::<UnionDecl>(d)     { return self._name_imm(cast::<UnionDecl>(d)->name);     }
        if isa::<EnumDecl>(d)      { return self._name_imm(cast::<EnumDecl>(d)->name);      }
        if isa::<InterfaceDecl>(d) { return self._name_imm(cast::<InterfaceDecl>(d)->name); }
        return u32(-1);
    }
}