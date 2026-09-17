/// --- The Kairo Project ----------------------- Sema/Type/ExprTyper.k --- ///
///
///   \brief The expression typer. One pass, one class, every mixin: the
///          demand-driven `type_of` and the state the mixins share.
///
///   \detail
///     type_of(e, expected) is memoized per node, walks children itself, and
///     writes exactly these slots: Expr::type_, Expr::value_category,
///     Expr::expr_flags, Expr::poisoned; the inferred type of a VariableDecl
///     / ClosureExpr / expr-bodied FunctionDecl / binder decl (the canonical
///     node itself); and the promotion candidate_cell -> resolved_decl on a
///     callee. Nothing else. It allocates no AST node.
///
///     The RAV drives the walk over the TU so that scope-carrying overrides
///     (StmtTyping) push frames; `dispatch_expr` is overridden to route
///     every expression through type_of, which makes the RAV's own pre-order
///     visit a memo hit for anything a statement already typed with an
///     expected type.
///
///     `expected` is bidirectional only where a node consumes it: literals,
///     initializers, closures, `null`. Everything else ignores it. A node has
///     one parent, so one expected type, so memoizing on the node is sound.
///
///     Four terminal states for a node, and every mixin returns to one:
///       typed      type_ set.
///       poisoned   diagnosed here or below; type_ null.
///       unknown    IsInstantiationDependent set, type_ null, not poisoned:
///                  dependent (M2), foreign (clang), or a hole owned by a
///                  later pass. Consumers skip checks on it.
///       type/module  the expression names a type or module; recorded in
///                  the side tables so a callee/initializer can read it.
///
///   Phase: CHECK stage, after TypeResolution + ChainBinding, before
///          ShadowCheck (which reads what this writes).
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
import Sema::Resolve::ChainBinding::*;
import Sema::Resolve::GenericArgs::*;
import Sema::Type::TypeUtil::*;
import Sema::Type::Conversion::*;
import Sema::Type::OverloadResolution::*;
import Sema::Type::ArgumentDeduction::*;
import Sema::Type::LiteralTyping::*;
import Sema::Type::OperatorTyping::*;
import Sema::Type::CallTyping::*;
import Sema::Type::MemberTyping::*;
import Sema::Type::CastTyping::*;
import Sema::Type::ControlTyping::*;
import Sema::Type::StmtTyping::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::SymbolTable::*;
import AST::Context::InstantiationRegistry::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Statements::*;
import AST::Node::Patterns::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Kind::ExprKind::*;
import AST::Kind::TypeKind::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Token::TokenKind::*;
import Diagnostic::Registry::*;
import AST::ParamMode::*;

__inline_cpp("
#define RecursiveASTVisitor_ExprTyper RecursiveASTVisitor<ExprTyper>
");

/// Memo states, keyed by node address.
enum TyperState derives u8 {
    Untouched = 0,
    InProgress,
    Done,
}

class ExprTyper
  derives StmtTyping::<ExprTyper>,          // brings the RAV with it
          LiteralTyping::<ExprTyper>,
          OperatorTyping::<ExprTyper>,
          CallTyping::<ExprTyper>,
          MemberTyping::<ExprTyper>,
          CastTyping::<ExprTyper>,
          ControlTyping::<ExprTyper> {

    // --- context + components -------------------------------------------
    pub var sc:   *SemaContext;
    pub var tu:   TypeUtil;
    pub var conv: Conversion;
    pub var ovl:  OverloadResolution;
    pub var ml:   MemberLookup;
    pub var cb:   ChainBinding;

    // --- scope state ------------------------------------------------------
    pub var frames:       vec::<TyperFrame>;
    pub var unsafe_depth: u32 = 0;

    // --- side tables --------------------------------------------------------
    priv var _memo:    libcxx::unordered_map::<u64, u8>;
    priv var _chains:  libcxx::unordered_map::<u64, ChainInfo>;
    priv var _typeexp: libcxx::unordered_map::<u64, *Type>;   ///< expr -> the type it denotes.
    priv var _modexp:  libcxx::unordered_map::<u64, u8>;      ///< expr denotes a module.
    priv var _panics:  vec::<*Expr>;                          ///< asserting downcasts.
    priv var _lang_reported: vec::<string>;
    priv var _scratch_ded: Deduction;

    // --- counters for the dump -----------------------------------------------
    pub var n_typed:    usize = 0;
    pub var n_unknown:  usize = 0;
    pub var n_errored:  usize = 0;

    fn ExprTyper(self, sc: *SemaContext) {
        self.sc   = sc;
        self.tu   = TypeUtil(sc);
        self.conv = Conversion(sc);
        self.ovl  = OverloadResolution(sc, &(self.conv));
        self.ml   = MemberLookup(sc);
        self.cb   = ChainBinding(sc);
        self._scratch_ded = Deduction(sc, &(self.conv));
    }

    /// PRE: TypesResolved (canonicals exist, chain steps with declared
    /// bases are bound). POST: every reachable expression is typed, poisoned
    /// or unknown; inferred decl slots filled; callee cells promoted.
    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved);
        var tu = self.sc->tu;
        if tu == &null { return; }
        if tu->program == &null { return; }

        self.ml.index_extensions();
        self.cb.prepare();

        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); ++i {
            if self.stop { break; }
            var item = *(items->get(i));
            switch item.get_kind() {
                case TopLevelKind::Decl { self.dispatch_decl(item.as_decl()); }
                case TopLevelKind::Stmt { self.dispatch_stmt(item.as_stmt()); }
                case TopLevelKind::Expr { self.type_of(item.as_expr(), &null); }
            }
        }
    }

    fn panic_sites(self) -> *vec::<*Expr> { return &(self._panics); }

    // === the entry ==========================================================

    /// The core. Idempotent per node; children walked by the mixins.
    fn type_of(self, e: *Expr, expected: *Type) -> *Type {
        if e == &null { return &null; }
        var key = reinterpret_cast::<u64>(e);
        var it = self._memo.find(key);
        if it != self._memo.end() {
            if static_cast::<TyperState>(it->second) == TyperState::InProgress {
                // an expression that reaches itself (only via a demand path):
                // the demand helper reported the cycle; stay quiet.
                return &null;
            }
            return e->type_;
        }
        self._memo[key] = static_cast::<u8>(TyperState::InProgress);

        var t: *Type = &null;
        if is_recovery(e) {
            e->poison();                     // parser diagnosed.
        } else if e->is_poisoned() {
            0;                               // an earlier pass diagnosed.
        } else {
            t = self._dispatch(e, expected);
        }
        self.finish(e, t);
        return e->type_;
    }

    /// Record the outcome on the node. Public so a mixin that typed a child
    /// out of band (the `-literal` fold) can commit it.
    fn finish(self, e: *Expr, t: *Type) {
        var key = reinterpret_cast::<u64>(e);
        self._memo[key] = static_cast::<u8>(TyperState::Done);
        if e->is_poisoned() {
            e->type_ = &null;
            self.n_errored += 1;
            return;
        }
        if t == &null {
            if !e->is_instantiation_dependent() {
                // a type/module-denoting expr or a callable has no type by
                // design; anything else with a null type is a hole to count.
                var k = key;
                if (self._typeexp.find(k) == self._typeexp.end()) && (self._modexp.find(k) == self._modexp.end()) {
                    var ci = self._chains.find(k);
                    var callable = (ci != self._chains.end()) && (ci->second.callable_cands.size() > 0);
                    if !callable { self.n_unknown += 1; }
                }
            } else {
                self.n_unknown += 1;
            }
            return;
        }
        e->type_ = t;
        if t->is_dependent() {
            e->expr_flags = static_cast::<Expr::ExprFlags>(
                static_cast::<u8>(e->expr_flags)
              | static_cast::<u8>(Expr::ExprFlags::IsDependent)
              | static_cast::<u8>(Expr::ExprFlags::IsInstantiationDependent));
        }
        if e->value_category == Expr::ValueCategory::Unknown {
            e->value_category = self._default_category(e, t);
        }
        self.n_typed += 1;
    }

    /// The category of a typed expression whose arm did not set one.
    ///
    ///   1. By TYPE. An expression of C++ reference type is the referent
    ///      ([expr.type]/1): `T&` an lvalue, `T&&` an xvalue. Only imported
    ///      signatures produce these, and every kind can -- a call, an
    ///      operator (`cout << 1` is `ostream&`, and the next `<<` binds it
    ///      to `ostream&`), a member -- so it is decided here once.
    ///   2. By KIND. What only ever makes a new value is a prvalue: literals,
    ///      by-value calls, temporaries, casts, arithmetic, control
    ///      expressions. The kinds whose category is whatever they NAME --
    ///      identifiers, chains, subscripts, parens, assignments -- get
    ///      nothing: their arm decides, and ValueCategoryPass ICEs on one
    ///      that did not. A default there would hide the missing arm.
    priv fn _default_category(self, e: *Expr, t: *Type) -> Expr::ValueCategory {
        if isa::<CXXLValueRefType>(t) { return Expr::ValueCategory::LValue; }
        if isa::<CXXRValueRefType>(t) { return Expr::ValueCategory::XValue; }
        var k = e->kind;
        if (k == ExprKind::NamedIdentExpr) || (k == ExprKind::ChainExpr) || (k == ExprKind::SubscriptExpr)
        || (k == ExprKind::ParenExpr) || (k == ExprKind::AssignOperatorExpr) {
            return Expr::ValueCategory::Unknown;
        }
        return Expr::ValueCategory::RValue;
    }

    priv fn _dispatch(self, e: *Expr, expected: *Type) -> *Type {
        switch e->kind {
            case ExprKind::IntegerLiteralExpr   { return self.type_int_literal(cast::<IntegerLiteralExpr>(e), expected, false); }
            case ExprKind::FloatingLiteralExpr  { return self.type_float_literal(cast::<FloatingLiteralExpr>(e), expected); }
            case ExprKind::StringLiteralExpr    { return self.type_string_literal(cast::<StringLiteralExpr>(e), expected); }
            case ExprKind::CharacterLiteralExpr { return self.type_char_literal(cast::<CharacterLiteralExpr>(e), expected); }
            case ExprKind::BooleanLiteralExpr   { return self.type_bool_literal(cast::<BooleanLiteralExpr>(e), expected); }
            case ExprKind::NullLiteralExpr      { return self.type_null_literal(cast::<NullLiteralExpr>(e), expected); }
            case ExprKind::ListLiteralExpr      { return self.type_list_literal(cast::<ListLiteralExpr>(e), expected); }
            case ExprKind::TupleLiteralExpr     { return self.type_tuple_literal(cast::<TupleLiteralExpr>(e), expected); }
            case ExprKind::SetLiteralExpr       { return self.type_set_literal(cast::<SetLiteralExpr>(e), expected); }
            case ExprKind::MapLiteralExpr       { return self.type_map_literal(cast::<MapLiteralExpr>(e), expected); }
            case ExprKind::NamedInitializerExpr { return self.type_named_init(cast::<NamedInitializerExpr>(e), expected); }
            case ExprKind::AnonInitializerExpr  { return self.type_anon_init(cast::<AnonInitializerExpr>(e), expected); }
            case ExprKind::ChainExpr            { return self.type_chain(cast::<ChainExpr>(e), expected); }
            case ExprKind::CallExpr             { return self.type_call(cast::<CallExpr>(e), expected); }
            case ExprKind::SubscriptExpr        { return self.type_subscript(cast::<SubscriptExpr>(e), expected); }
            case ExprKind::NamedIdentExpr       { return self._type_ident(cast::<NamedIdentExpr>(e), expected); }
            case ExprKind::UnaryOperatorExpr    { return self.type_unary(cast::<UnaryOperatorExpr>(e), expected); }
            case ExprKind::BinaryOperatorExpr   { return self.type_binary(cast::<BinaryOperatorExpr>(e), expected); }
            case ExprKind::AssignOperatorExpr   { return self.type_assign(cast::<AssignOperatorExpr>(e), expected); }
            case ExprKind::ImplConformanceExpr  { return self.type_constraint(e, expected); }
            case ExprKind::DerivesRelationExpr  { return self.type_constraint(e, expected); }
            case ExprKind::ConstraintExpr       { return self.type_constraint(e, expected); }
            case ExprKind::IfExpr               { return self.type_if_expr(cast::<IfExpr>(e), expected); }
            case ExprKind::TryCatchExpr         { return self.type_try_expr(cast::<TryCatchExpr>(e), expected); }
            case ExprKind::MatchExpr            { return self.type_match_expr(cast::<MatchExpr>(e), expected); }
            case ExprKind::RangeExpr            { return self.type_range(cast::<RangeExpr>(e), expected); }
            case ExprKind::ClosureExpr          { return self.type_closure(cast::<ClosureExpr>(e), expected); }
            case ExprKind::AwaitExpr            { return self.type_await(cast::<AwaitExpr>(e), expected); }
            case ExprKind::SpawnExpr            { return self.type_spawn(e, cast::<SpawnExpr>(e)->operand, expected); }
            case ExprKind::ThreadExpr           { return self.type_spawn(e, cast::<ThreadExpr>(e)->operand, expected); }
            case ExprKind::SizeOfExpr           { return self.type_sizeof(cast::<SizeOfExpr>(e), expected); }
            case ExprKind::AlignOfExpr          { return self.type_alignof(cast::<AlignOfExpr>(e), expected); }
            case ExprKind::TypeOfExpr           { return self.type_typeof(cast::<TypeOfExpr>(e), expected); }
            case ExprKind::EvalExpr             { return self.type_eval(cast::<EvalExpr>(e), expected); }
            case ExprKind::UnsafeExpr           { return self.type_unsafe(cast::<UnsafeExpr>(e), expected); }
            case ExprKind::DeleteExpr           { return self.type_delete(cast::<DeleteExpr>(e), expected); }
            case ExprKind::TypeCastExpr         { return self.type_cast(cast::<TypeCastExpr>(e), expected); }
            case ExprKind::PackExpansionExpr {
                self.type_of(cast::<PackExpansionExpr>(e)->operand, &null);
                self.mark_unknown(e);
                return &null;
            }
            case ExprKind::ImplicitBoundaryCastExpr {
                var c = cast::<ImplicitBoundaryCastExpr>(e);
                self.type_of(c->original, &null);
                return (c->target_type->canonical) if (c->target_type != &null) else (&null);
            }
            case ExprKind::ParenExpr {
                var p = cast::<ParenExpr>(e);
                var t = self.type_of(p->inner, expected);
                if self.propagate(e, p->inner) { return &null; }
                if p->inner != &null {
                    e->value_category = p->inner->value_category;
                    var d = self.denoted_type(p->inner);
                    if d != &null { self.note_type_expr(e, d); }
                }
                return t;
            }
            case ExprKind::VerbatimExpr { self.mark_unknown(e); return &null; }
            default { self.fail(e, "expression kind is not typable"); return &null; }
        }
    }

    // === identifiers ========================================================

    priv fn _type_ident(self, n: *NamedIdentExpr, expected: *Type) -> *Type {
        if n->is_deferred() {
            // an overload set as a value: only a callee may read a cell.
            var all_mod = true;
            for var i: usize = 0; i < n->candidate_cell->size(); ++i {
                if !isa::<ModuleDecl>(n->candidate_cell->get(i)) { all_mod = false; break; }
            }
            if all_mod { self.note_module_expr(n); return &null; }
            var ci = self.new_chain_info_for_ident(n);
            for var i: usize = 0; i < n->candidate_cell->size(); ++i { ci->callable_cands.push_back(n->candidate_cell->get(i)); }
            return &null;
        }
        if !n->is_bound() { self.mark_unknown(n); return &null; }

        var d = n->resolved_decl;
        switch d->kind {
            case DeclKind::ParamDecl {
                var p = cast::<ParamDecl>(d);
                n->value_category = Expr::ValueCategory::LValue;
                if p->type_ == &null { self.mark_unknown(n); return &null; }
                // A `const` binding is a const OBJECT, and an object's type
                // carries its cv: `&x` on a const param is `*const T`, and
                // `T&` deduces `const T` from it. The receiver is exempt: a
                // const method's `self` already has type `const Record`
                // (TypeResolve::_synthesize_receiver, DeclImport).
                var t = p->type_->canonical;
                if p->is_const && (!p->is_self) { t = self.sc->types->qualified(t, QUAL_CONST()); }
                return t;
            }
            case DeclKind::VariableDecl {
                n->value_category = Expr::ValueCategory::LValue;
                var v = cast::<VariableDecl>(d);
                var t = self.var_type(v);
                if t == &null { if d->is_poisoned() { self.poison_only(n); } else { self.mark_unknown(n); } }
                else if v->is_const() { t = self.sc->types->qualified(t, QUAL_CONST()); }
                return t;
            }
            case DeclKind::FieldDecl {
                // reachable only as a static field or from a type body default.
                var f = cast::<FieldDecl>(d);
                n->value_category = Expr::ValueCategory::LValue;
                if f->type_ == &null { self.mark_unknown(n); return &null; }
                return f->type_->canonical;
            }
            case DeclKind::EnumVariantDecl {
                var edc = reinterpret_cast::<*DeclContext>(d->semantic_dc);
                var ed  = (edc->owner_decl()) if (edc != &null) else (&null);
                if ed == &null { self.mark_unknown(n); return &null; }
                var a = vec::<*Type>();
                n->value_category = Expr::ValueCategory::RValue;    // a variant is a value, not storage.
                return self.sc->types->record(NameLookup::representative(ed), &a);
            }
            case DeclKind::FunctionDecl {
                var f = cast::<FunctionDecl>(d);
                var ci = self.new_chain_info_for_ident(n);
                ci->callable_cands.push_back(d);
                n->value_category = Expr::ValueCategory::RValue;    // as a value: the fn pointer.
                if (!f->is_method()) && (f->generic_params.size() == 0) { return self.fn_pointer_type(f); }
                return &null;
            }
            case DeclKind::GenericParamDecl { self.mark_unknown(n); return &null; }
            case DeclKind::ModuleDecl {
                // A module used as a value is the typer's own (still open)
                // question and stays silent here. `cxx` is not: it is the C++
                // std overlay, its one member is `std`, and naming it alone
                // denotes nothing -- answerable now, so answer it.
                if (self.sc->tu != &null) && (d == self.sc->tu->cxx_module) {
                    self.sc->diag->report(DiagID::R053E, n->range.start,
                        "'cxx' names the C++ std overlay; write `cxx::std`"
                    ).first(n->range).emit();
                    return &null;
                }
                self.note_module_expr(n);
                return &null;
            }
            case DeclKind::ExtensionDecl {
                // `Self` inside an extend: denotes the target type.
                var t = self.type_from_type_decl(d, n->generic_args, static_cast::<*Expr>(n));
                if t != &null { self.note_type_expr(n, t); }
                return &null;
            }
            default {
                if self.tu.is_type_decl(d) {
                    var t = self.type_from_type_decl(d, n->generic_args, static_cast::<*Expr>(n));
                    if t == &null { return &null; }
                    self.note_type_expr(n, t);
                    return &null;
                }
                self.fail(n, f"'{self.tu.decl_name(d)}' is not a value");
                return &null;
            }
        }
    }

    // === type-denoting expressions ==========================================

    /// The record a type decl denotes in expression position, applying
    /// explicit generic args or leaving the pattern. The args go through
    /// GenericArgs, the rule a type position uses: `std::vector<i32>()` is
    /// legal because _Alloc has a default.
    fn type_from_type_decl(self, d: *Decl, gargs: FrozenList::<ChainType::GenericArg>, at: *Expr) -> *Type {
        if isa::<ExtensionDecl>(d) {
            var e = cast::<ExtensionDecl>(d);
            if (e->target == &null) || (e->target->canonical == &null) { self.mark_unknown(at); return &null; }
            return e->target->canonical;
        }
        if isa::<TypeAliasDecl>(d) {
            var td = cast::<TypeAliasDecl>(d);
            if (td->aliased == &null) || (td->aliased->canonical == &null) { self.mark_unknown(at); return &null; }
            return td->aliased->canonical;
        }
        var rep = NameLookup::representative(d);
        var gps = self.tu.generic_params_of(rep);
        var args = vec::<*Type>();
        var dep = false;
        if gargs.size() > 0 {
            var ga = GenericArgs(self.sc);
            if !ga.check_arity(rep, self.tu.decl_name(rep), gps, gargs.size(), at->range) { self.poison_only(at); return &null; }
            for var i: usize = 0; i < gargs.size(); ++i {
                var g = gargs.get(i);
                if (g->ty == &null) || g->ty->is_poisoned() { self.poison_only(at); return &null; }
            }
            if !ga.collect(rep, gps, gargs, true, &args) { self.poison_only(at); return &null; }
            dep = ga.inst_dependent;
            for var i: usize = 0; i < args.size(); ++i {
                if args[i]->is_dependent() || args[i]->is_instantiation_dependent() { dep = true; }
            }
        } else {
            for var i: usize = 0; i < gps.size(); ++i {
                var gp = gps[i];
                if gp == &null { continue; }
                dep = true;
                args.push_back(self.sc->types->generic_param(rep, gp->index, gp->is_pack));
            }
        }
        if dep || (args.size() == 0) { return self.sc->types->record(rep, &args); }
        var e = self.sc->instances->instance_for(rep, &args, self.sc->ctx->fid, NameLookup::ctx_of(rep));
        var inst = (e->decl) if (e != &null) else (rep);
        return self.sc->types->record(inst, &args);
    }

    fn note_type_expr(self, e: *Expr, t: *Type) { self._typeexp[reinterpret_cast::<u64>(e)] = t; }
    fn note_module_expr(self, e: *Expr)         { self._modexp[reinterpret_cast::<u64>(e)] = 1; }

    /// The type \p e denotes, or null when it is a value / unknown.
    fn denoted_type(self, e: *Expr) -> *Type {
        if e == &null { return &null; }
        self.type_of(e, &null);
        var it = self._typeexp.find(reinterpret_cast::<u64>(e));
        if it == self._typeexp.end() { return &null; }
        return it->second;
    }

    fn denotes_module(self, e: *Expr) -> bool {
        if e == &null { return false; }
        return self._modexp.find(reinterpret_cast::<u64>(e)) != self._modexp.end();
    }

    // === chain side table ===================================================

    fn new_chain_info(self, n: *ChainExpr) -> *ChainInfo {
        var key = reinterpret_cast::<u64>(static_cast::<*Expr>(n));
        self._chains[key] = ChainInfo{};
        return &(self._chains[key]);
    }

    fn new_chain_info_for_ident(self, n: *NamedIdentExpr) -> *ChainInfo {
        var key = reinterpret_cast::<u64>(static_cast::<*Expr>(n));
        self._chains[key] = ChainInfo{};
        return &(self._chains[key]);
    }

    fn chain_info(self, n: *ChainExpr) -> *ChainInfo {
        var it = self._chains.find(reinterpret_cast::<u64>(static_cast::<*Expr>(n)));
        if it == self._chains.end() { return &null; }
        return &(it->second);
    }

    fn ded_scratch(self) -> *Deduction {
        self._scratch_ded = Deduction(self.sc, &(self.conv));
        return &(self._scratch_ded);
    }

    /// The fn-pointer canonical of a non-generic function. The receiver is
    /// not a parameter of the type; every other parameter's MODE is.
    fn fn_pointer_type(self, f: *FunctionDecl) -> *Type {
        var ps = vec::<*Type>();
        var ms = vec::<ParamMode>();
        for var i: usize = 0; i < f->params.size(); ++i {
            var p = f->params[i];
            if (p == &null) || p->is_self { continue; }
            if (p->type_ == &null) || (p->type_->canonical == &null) { return &null; }
            // a function type has no top-level cv on its parameters ([dcl.fct]/5)
            ps.push_back(canon_unqual(p->type_->canonical));
            ms.push_back(p->mode);
        }
        var r = self.fn_return_type(f);
        if r == &null { return &null; }
        return self.sc->types->func(&ps, &ms, r);
    }

    // === outcomes ===========================================================

    fn fail(self, e: *Expr, msg: string) {
        if e == &null { return; }
        if !e->is_poisoned() {
            self.sc->diag->report(DiagID::SC001E, e->range.start, msg).first(e->range).emit();
        }
        e->poison();
    }

    fn warn(self, e: *Expr, msg: string) {
        if e == &null { return; }
        self.sc->diag->report(DiagID::SC001W, e->range.start, msg).first(e->range).emit();
    }

    /// Poison without a diagnostic: the child already reported.
    fn poison_only(self, e: *Expr) { if e != &null { e->poison(); } }

    fn mark_unknown(self, e: *Expr) {
        if e == &null { return; }
        e->expr_flags = static_cast::<Expr::ExprFlags>(
            static_cast::<u8>(e->expr_flags)
          | static_cast::<u8>(Expr::ExprFlags::IsInstantiationDependent));
    }

    /// Lift a child's poison / unknown onto \p e. True when \p e cannot be typed.
    fn propagate(self, e: *Expr, child: *Expr) -> bool {
        if child == &null { return false; }
        if child->is_poisoned() { e->poison(); return true; }
        if (child->type_ == &null) && child->is_instantiation_dependent() {
            self.mark_unknown(e);
            return true;
        }
        if child->is_dependent() {
            e->expr_flags = static_cast::<Expr::ExprFlags>(
                static_cast::<u8>(e->expr_flags) | static_cast::<u8>(child->expr_flags));
        }
        return false;
    }

    fn is_lvalue(self, e: *Expr) -> bool {
        var x = self.tu.strip_parens(e);
        if x == &null { return false; }
        return x->value_category == Expr::ValueCategory::LValue;
    }

        /// Implicit-convert check at a use site. Diagnoses and poisons \p e on
    /// failure; silent on unknown / already poisoned.
    fn check_convertible(self, e: *Expr, to: *Type) -> bool {
        if (e == &null) || (to == &null) { return true; }
        if e->is_poisoned() { return false; }
        var from = e->type_;
        if from == &null { return true; }   // unknown: nothing to check here.
        if to->is_dependent() { return true; }
        var r = self.conv.implicit(from, to);
        if r != ImplicitRank::None { return true; }

        var hint = "";
        var fk = self.tu.kind_of(from);
        var tk = self.tu.kind_of(to);
        if (fk != BuiltinKind::COUNT) && (tk != BuiltinKind::COUNT) {
            switch self.conv.classify(fk, tk) {
                case ConvClass::E { hint = "; the conversion may lose value and needs an explicit 'as\x27"; }
                case ConvClass::U { hint = "; the conversion needs 'as' inside an unsafe context"; }
                case ConvClass::W { hint = "; implicit conversions are disabled (-fno-implicit-conv), write 'as\x27"; }
                default { 0; }
            }
        } else if (self.tu.nullable_inner(from) != &null) && (self.tu.strip_nullable(from) == to) {
            hint = "; the value may be null, use '??' or 'unwrap!()\x27";
        } else if (self.tu.pointee(to) != &null) && (self.tu.pointee(from) == &null) {
            hint = "; take the address with '&\x27";
        } else if (self.tu.pointee(from) != &null) && (self.tu.pointee(to) != &null) {
            var fd = self.tu.record_decl(self.tu.pointee(from));
            var td = self.tu.record_decl(self.tu.pointee(to));
            if (fd != &null) && (td != &null) && self.tu.derives_from(td, fd) {
                hint = "; a base-to-derived pointer needs an explicit 'as\x27";
            } else if self.tu.is_unsafe_ptr(from) != self.tu.is_unsafe_ptr(to) {
                hint = "; safe and unsafe pointers do not convert implicitly";
            }
        }

        self.sc->diag->report(DiagID::SC001E, e->range.start,
            f"cannot convert '{self.tu.str(from)}' to '{self.tu.str(to)}'{hint}"
        ).first(e->range).emit();
        e->poison();
        return false;
    }

    // === lang items / panic sites ===========================================

    /// One report per unbound lang item per TU: the "error at USE" rule from
    /// SemaContext.k, without a repeat on every use in the file.
    fn missing_lang_item(self, e: *Expr, name: string) {
        for var i: usize = 0; i < self._lang_reported.size(); ++i {
            if self._lang_reported[i] == name { self.poison_only(e); return; }
        }
        self._lang_reported.push_back(name);
        self.sc->diag->report(DiagID::SC001E, e->range.start,
            f"this expression needs the '{name}' lang item, which is not bound in this build"
        ).first(e->range)
         .note(e->range.start, "the builtin module that defines it is not in the import set; further uses in this file are not reported")
         .emit();
        e->poison();
    }

    /// An asserting downcast is a panic site. PanicEffectChecking reads
    /// panic_sites() when it lands; until then the list is inert.
    fn note_panic_site(self, e: *Expr) { self._panics.push_back(e); }

    // === RAV routing ========================================================

    /// Every expression the RAV reaches goes through type_of. A statement
    /// override already typed most of them with an expected type; those are
    /// memo hits. Anything left (an attribute argument, a generic default in
    /// expression position, a requires conjunct) is typed with none.
    fn dispatch_expr(self, e: *Expr) -> *Expr {
        if e == &null { return e; }
        self.type_of(e, &null);
        return e;
    }

    /// Closures are expressions and are typed through type_of, which pushes
    /// the frame and walks the body itself. The base traversal must not
    /// walk the body a second time with no frame.
    fn traverse_closure_expr(self, n: *ClosureExpr) -> *ClosureExpr {
        if n == &null { return n; }
        self.type_of(static_cast::<*Expr>(n), &null);
        return n;
    }

    /// Attribute arguments hang off the annotation mixin; the RAV never
    /// walks them. Type them so a user macro's arguments are not a blind
    /// spot; a miss there is not an error (the attribute checker decides).
    fn visit_decl(self, n: *Decl) -> bool {
        if n == &null { return true; }
        for var i: usize = 0; i < n->annotations.size(); ++i {
            var a = n->annotations.get(i);
            if (a == &null) || (a->kind != AnnotationKind::Attribute) { continue; }
            // args is a FrozenList<*void>: the annotation mixin cannot name
            // Expr (AST/Mixin/Annotation.k), but every element is one.
            for var j: usize = 0; j < a->args.size(); ++j {
                self.type_of(reinterpret_cast::<*Expr>(a->args[j]), &null);
            }
        }
        return true;
    }
}

    