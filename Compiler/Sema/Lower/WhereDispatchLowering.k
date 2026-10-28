/// --- The Kairo Project -------------- Sema/Lower/WhereDispatchLowering.k --- ///
///
///   \brief Fold each `where` dispatch group into one function that tests
///          the guards and calls the matching candidate.
///
///   \detail
///       fn categorize(x: i32) -> string where x > 100 { return "high" }
///       fn categorize(x: i32) -> string where x > 0   { return "positive" }
///       fn categorize(x: i32) -> string               { return "non-positive" }
///     ->
///       fn categorize(x: i32) -> string {
///           if x > 100 { return __kairo_where_categorize_0(x) }
///           if x > 0   { return __kairo_where_categorize_1(x) }
///           return __kairo_where_categorize_2(x)
///       }
///       priv fn __kairo_where_categorize_0(x: i32) -> string { return "high" }
///       priv fn __kairo_where_categorize_1(x: i32) -> string { return "positive" }
///       priv fn __kairo_where_categorize_2(x: i32) -> string { return "non-positive" }
///
///     Kairo declares the candidates separately; C++ sees ONE function with
///     the public name and the shared signature, so a C++ caller (a kcc
///     header, InterfaceEmitter) uses it like any other. The candidates are
///     `priv`: in the entry TU that puts them in the file's unnamed
///     namespace (CXXSpell::is_anon), and a module header leaves them out.
///     A method group's candidates are private members.
///
///   \par Identity
///     The group's lead (FunctionDecl::where_lead, its first-declared
///     member) IS the dispatcher: OverloadResolution bound every call to
///     it, here and in every importing TU, so no call site changes. Each
///     member, the lead included, hands its parameters and body to a fresh
///     candidate FunctionDecl (`__kairo_where_<name>_<k>`, k its position in
///     source order, LowerTargets::where_candidate) -- a body's references
///     already name those parameters, so nothing in a body is rewritten.
///     The lead takes fresh parameters; each guard moves into the
///     dispatcher and is the one thing retargeted, from its member's
///     parameters to the lead's new ones, by position (`self` included).
///     A non-lead member leaves the tree; its candidate takes its place.
///
///   \par Order and evaluation
///     WhereGuardCheck filed each group in dispatch order: the guarded
///     members as declared, then the fallback. Each guard is an `if` that
///     returns, so it is evaluated at most once, in order, and only until
///     one holds. A group whose guards were proven to cover every value has
///     no fallback; its last guarded member is called untested.
///
///   \par Forwarding
///     Each parameter is passed on as the lvalue it is, and the C++ the
///     candidate's parameter needs falls out of its mode: a `@move` or
///     by-value MOVE parameter moves (EmitIR casts an lvalue to a `@move`
///     parameter, and a by-value MOVE one is recorded in
///     SemaContext::move_sites for CopyMoveLowering, MoveCheck's channel),
///     `@inout` binds its `T&` as is, and a copyable value copies. Every
///     parameter is passed once, on the one path taken.
///
///   \par Generic groups (MONO.md G12)
///     Members equal up to their generic parameters' names (RedeclMerge
///     _alpha_same) fold the same way: each candidate is a template over
///     its member's parameters, the dispatcher is the lead's template, and
///     each guard is an ordinary `if` in it, a runtime test even when it
///     reads only the parameters' types (`sizeof T > 8`). Under D0 every
///     candidate is well-formed for every argument its (shared) bounds
///     admit, so testing a per-instance constant at run time is correct,
///     and clang folds it; no `if constexpr`, no prediction to pin.
///
///   Phase: LOWER, right after ExprBodyDesugar (so every candidate's body
///   is a block, and the dispatcher is a block for every pass after it)
///   and before CopyMoveLowering (which reads the move sites recorded
///   here). Every pass after it meets ordinary functions; the guards are
///   ordinary `if` conditions.
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
import Sema::Type::TypeUtil::*;
import Sema::Check::ClassLifecycle::*;
import Sema::Lower::LowerSynth::*;
import AST::Visitor::ASTWriter::*;
import AST::ASTSupport::*;
import AST::LangItems::*;
import AST::Mixin::Annotation::*;
import AST::Context::DeclContext::*;
import AST::Node::Base::*;
import AST::Node::Types::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::ParamMode::*;
import Token::Token::*;
import Location::SourceRange::*;

/// A guard's parameter references, moved from its member's parameters to
/// the dispatcher's: the i-th of `from` becomes the i-th of `to`. In place;
/// every other node is left as it is.
class WhereGuardRemap derives ASTWriter::<WhereGuardRemap> {
    pub var from: vec::<*Decl>;
    pub var to:   vec::<*Decl>;

    fn WhereGuardRemap(self, ctx: *ASTContext) {
        self.ctx = ctx;
    }

    fn transform_named_ident_expr(self, n: *NamedIdentExpr) -> *Expr {
        var out = ASTWriter::<WhereGuardRemap>::transform_named_ident_expr(n);
        for var i: usize = 0; i < self.from.size(); ++i {
            if n->resolved_decl == self.from[i] {
                n->resolved_decl = self.to[i];
                break;
            }
        }
        return out;
    }
}

class WhereDispatchLowering derives ASTWriter::<WhereDispatchLowering> {
    pub var sc: *SemaContext;
    priv var tu:    TypeUtil;
    priv var synth: LowerSynth;

    // Every member already given its candidate, and that candidate:
    // parallel. A member is reached once per list that holds it (a method
    // in a visibility group is in two), and each reach answers the same.
    priv var _members: vec::<*FunctionDecl>;
    priv var _cands:   vec::<*FunctionDecl>;

    fn WhereDispatchLowering(self, sc: *SemaContext) {
        self.sc    = sc;
        self.ctx   = sc->ctx;
        self.tu    = TypeUtil(sc);
        self.synth = LowerSynth(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked);
        if self.sc->tu == &null { return; }
        if self.sc->where_groups.size() == 0 { return; }
        ASTWriter::<WhereDispatchLowering>::run(self.sc->tu);
        for var i: usize = 0; i < self.sc->where_groups.size(); ++i {
            ICE_IF(self._cand_of(self.sc->where_groups[i]) == &null,
                "WhereDispatchLowering: a where group member was never visited");
        }
    }

    fn transform_function_decl(self, n: *FunctionDecl) -> vec::<*Decl> {
        // Children first: a body may hold a block-scope group of its own.
        var out = ASTWriter::<WhereDispatchLowering>::transform_function_decl(n);
        if (n->where_lead == &null) || n->is_poisoned() { return out; }
        if !self._filed(n) { return out; }

        var lead = n->where_lead;
        if self._cand_of(lead) == &null { self._fold(lead); }

        var res = vec::<*Decl>();
        if n == lead { res.push_back(static_cast::<*Decl>(lead)); }
        res.push_back(static_cast::<*Decl>(self._cand_of(n)));
        return res;
    }

    priv fn _filed(self, f: *FunctionDecl) -> bool {
        for var i: usize = 0; i < self.sc->where_groups.size(); ++i {
            if self.sc->where_groups[i] == f { return true; }
        }
        return false;
    }

    priv fn _cand_of(self, f: *FunctionDecl) -> *FunctionDecl {
        for var i: usize = 0; i < self._members.size(); ++i {
            if self._members[i] == f { return self._cands[i]; }
        }
        return &null;
    }

    // === one group ============================================================

    /// Mint every member's candidate, then make \p lead the dispatcher.
    priv fn _fold(self, lead: *FunctionDecl) {
        var order = vec::<*FunctionDecl>();     // dispatch order (WhereGuardCheck)
        for var i: usize = 0; i < self.sc->where_groups.size(); ++i {
            var m = self.sc->where_groups[i];
            if m->where_lead == lead { order.push_back(m); }
        }
        ICE_IF(order.size() == 0, "WhereDispatchLowering: a lead with no filed group");

        var name = self.tu.decl_name(static_cast::<*Decl>(lead));
        // The guards, and the parameters each was written against, before
        // the candidates take the parameters away.
        var guards = vec::<*Expr>();
        var olds   = vec::<FrozenList::<*ParamDecl>>();
        for var i: usize = 0; i < order.size(); ++i {
            var m = order[i];
            guards.push_back(m->where_clause);
            m->where_clause = &null;            // moved: one node, one parent.
            olds.push_back(m->params);
            var k = self._source_rank(m, &order);
            var c = self._mint(m, self.synth.ident(m->range, LowerTargets::where_candidate(name, k)));
            self._members.push_back(m);
            self._cands.push_back(c);
        }

        // The lead's own parameters went to its candidate; the dispatcher
        // gets fresh ones of the same shape.
        var fresh = self.list_builder::<*ParamDecl>();
        var lead_old = olds[self._index_in(lead, &order)];
        for var i: usize = 0; i < lead_old.size(); ++i { fresh.push(self._clone_param(lead_old[i])); }
        fresh.freeze_into(&(lead->params));

        var at   = lead->range;
        var body = CompoundStmt::create(self.ctx, at);
        var stmts = self.list_builder::<*Stmt>();
        for var i: usize = 0; i < order.size(); ++i {
            var m = order[i];
            var c = self._cand_of(m);
            // The last is the fallback, or the guarded member the others
            // were proven to leave every remaining value for.
            var untested = i == order.size() - 1;
            var fwd = self._forward(lead, c, m->range);
            if untested {
                for var s: usize = 0; s < fwd.size(); ++s { stmts.push(fwd[s]); }
                continue;
            }
            var g = self._retarget(guards[i], &(olds[i]), &(lead->params));
            var then_ = CompoundStmt::create(self.ctx, g->range);
            var tb = self.list_builder::<*Stmt>();
            for var s: usize = 0; s < fwd.size(); ++s { tb.push(fwd[s]); }
            tb.freeze_into(&(then_->body));
            stmts.push(static_cast::<*Stmt>(ConditionalStmt::create(self.ctx, g->range, g, then_, &null)));
        }
        stmts.freeze_into(&(body->body));

        lead->body_kind  = FnBodyKind::Block;
        lead->body_block = body;
        lead->body_expr  = &null;
        lead->is_this_definition = true;
    }

    /// \p m's position among \p order in source order: the k of its name.
    priv fn _source_rank(self, m: *FunctionDecl, order: *vec::<*FunctionDecl>) -> usize {
        var k: usize = 0;
        for var i: usize = 0; i < order->size(); ++i {
            if (*order)[i]->range.start.id < m->range.start.id { k += 1; }
        }
        return k;
    }

    priv fn _index_in(self, m: *FunctionDecl, order: *vec::<*FunctionDecl>) -> usize {
        for var i: usize = 0; i < order->size(); ++i { if (*order)[i] == m { return i; } }
        ICE_FAIL("WhereDispatchLowering: the lead is not in its own group");
        return 0;
    }

    /// A candidate: \p m's parameters, body and contract under \p name,
    /// private, where \p m was declared. \p m keeps nothing of either.
    priv fn _mint(self, m: *FunctionDecl, name: Token) -> *FunctionDecl {
        var c = self.ctx->alloc::<FunctionDecl>();
        libcxx::memset(static_cast::<*void>(c), 0, sizeof(FunctionDecl));
        c->kind  = DeclKind::FunctionDecl;
        c->range = m->range;
        c->name  = name;
        c->init_annotations(&(self.ctx->ast_alloc));
        c->init_dc(DeclContextKind::Function, self.ctx, reinterpret_cast::<*DeclContext>(m->semantic_dc), static_cast::<*Decl>(c));
        c->init_redecl();
        c->generic_params  = create_empty_frozen_list::<*GenericParamDecl>();
        c->op_token        = create_empty_frozen_list::<Token>();
        c->spec_args       = create_empty_frozen_list::<*Type>();
        c->spec_kind       = SpecKind::None;
        c->requires_clause = &null;
        c->where_clause    = &null;
        c->where_lead      = &null;
        c->qualifier       = &null;

        c->semantic_dc = m->semantic_dc;
        c->lexical_dc  = m->lexical_dc;
        c->visibility  = VisibilityKind::Private;
        // A generic member's candidate is a template of its own: it takes
        // the member's parameter list and clause (shared with the lead's
        // dispatcher for the lead's candidate: the same names, the same
        // entities its parameter types already point at), and the
        // dispatcher calls it with nothing written, C++ deducing the
        // arguments (WhereGuardCheck refused a group where it could not).
        // It keeps the member's visibility: wherever the dispatcher's
        // template is instantiated, a module header included, the candidate
        // must be declared (MONO.md G12).
        if m->generic_params.size() > 0 {
            c->generic_params  = m->generic_params;
            c->requires_clause = m->requires_clause;
            c->visibility      = m->visibility;
        }
        c->is_implicit = true;
        c->abi         = m->abi;              // a static method's candidates are static.
        c->modifiers   = m->modifiers;
        c->return_type = m->return_type;      // shared, as every minted function's is.
        c->is_noreturn = m->is_noreturn;
        c->no_unwind   = m->no_unwind;
        // Its panic contract is the member's own (PANIC.md §2.8): the set
        // EffectPropagation solved for this body, and the written one. The
        // dispatcher keeps the group (where_lead / where_group), whose set
        // is the union of these.
        c->panic_set   = m->panic_set;
        c->panic_range = m->panic_range;
        c->panic_eff   = m->panic_eff;
        c->panic_state = m->panic_state;

        c->params     = m->params;            // moved: the body names these.
        c->body_kind  = m->body_kind;
        c->body_block = m->body_block;
        c->body_expr  = m->body_expr;
        c->is_this_definition = true;

        m->body_kind  = FnBodyKind::None;
        m->body_block = &null;
        m->body_expr  = &null;
        return c;
    }

    /// A parameter of the dispatcher shaped like \p p: name, type, mode,
    /// receiver-ness, const-ness, position. Never a default (WhereGuardCheck
    /// gates them).
    priv fn _clone_param(self, p: *ParamDecl) -> *ParamDecl {
        var q = self.ctx->alloc::<ParamDecl>();
        libcxx::memcpy(static_cast::<*void>(q), static_cast::<*void>(p), sizeof(ParamDecl));
        q->default_val   = &null;
        q->default_thunk = &null;
        return q;
    }

    /// \p g with its references to \p from moved to \p to, by position.
    priv fn _retarget(self, g: *Expr, from: *FrozenList::<*ParamDecl>, to: *FrozenList::<*ParamDecl>) -> *Expr {
        var rm = WhereGuardRemap(self.ctx);
        for var i: usize = 0; (i < from->size()) && (i < to->size()); ++i {
            rm.from.push_back(static_cast::<*Decl>((*from)[i]));
            rm.to.push_back(static_cast::<*Decl>((*to)[i]));
        }
        return rm.run_on_expr(g);
    }

    /// The statements that call \p c with \p lead's parameters and leave:
    /// `return c(args)`, or `c(args); return` when there is no value.
    priv fn _forward(self, lead: *FunctionDecl, c: *FunctionDecl, at: SourceRange) -> vec::<*Stmt> {
        var args = self.list_builder::<*Expr>();
        var recv: *Expr = &null;
        for var i: usize = 0; i < lead->params.size(); ++i {
            var p = lead->params[i];
            var use = self._use(p, at);
            if p->is_self { recv = use; continue; }
            if (p->mode == ParamMode::Value) && moves_on_pass(self.sc, self.tu.param_value_type(p)) {
                self.sc->move_sites.insert(reinterpret_cast::<u64>(use));
            }
            args.push(use);
        }

        var rt = self._ret(c);
        var call: *Expr = &null;
        if recv != &null { call = self.synth.member_call(at, recv, static_cast::<*Decl>(c), &args, rt); }
        else             { call = self.synth.free_call(at, static_cast::<*Decl>(c), &args, rt); }

        var out = vec::<*Stmt>();
        if self.tu.is_void(rt) || self.tu.is_never(rt) {
            out.push_back(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, at, call)));
            out.push_back(static_cast::<*Stmt>(ReturnStmt::create(self.ctx, at, &null)));
        } else {
            out.push_back(static_cast::<*Stmt>(ReturnStmt::create(self.ctx, at, call)));
        }
        return out;
    }

    /// A read of the dispatcher's parameter \p p, typed as X types one.
    priv fn _use(self, p: *ParamDecl, at: SourceRange) -> *Expr {
        var use = NamedIdentExpr::create(self.ctx, at, p->name);
        use->resolved_decl = static_cast::<*Decl>(p);
        var t = self.tu.param_value_type(p);
        if p->is_const && (!p->is_self) && (t != &null) { t = self.sc->types->qualified(t, QUAL_CONST()); }
        use->type_          = t;
        use->value_category = Expr::ValueCategory::LValue;
        return static_cast::<*Expr>(use);
    }

    priv fn _ret(self, f: *FunctionDecl) -> *Type {
        if f->is_noreturn { return self.sc->builtin(BuiltinKind::Never); }
        if f->return_type == &null { return self.sc->builtin(BuiltinKind::Void); }
        return f->return_type->canonical;
    }
}
