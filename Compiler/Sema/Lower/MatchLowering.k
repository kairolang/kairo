/// --- The Kairo Project --------------------- Sema/Lower/MatchLowering.k --- ///
///
///   \brief Every `match` becomes labels, gotos and switches over a
///          once-evaluated scrutinee: PatternCompilation's decision DAG,
///          rendered. This pass decides nothing about the patterns.
///
///   \detail
///     Statement form:
///
///       { T __kairo_mN_s = e;                     // or const T& for a class lvalue
///         <root node>                             // every node ends in a goto
///         __kairo_mN_tK: <node>
///         __kairo_mN_fail: __builtin_trap();      // UnmatchedPolicy, when reachable
///         __kairo_mN_a0: { binders; body } goto __kairo_mN_end;
///         ...
///         __kairo_mN_aL: { binders; body }
///         __kairo_mN_end:; }
///
///     Value form, the same nodes with every leaf `arm = k; goto D;`:
///
///       ({ T __kairo_mN_s = e; u32 __kairo_mN_arm;
///          <nodes>
///          __kairo_mN_end:;
///          (arm == 0 ? ({ binders; (e0); }) : arm == 1 ? ... : ({ ...; (eL); })); })
///
///     clang folds the index away at -O2: the leaves become the arms. Two
///     cheaper shapes are taken when they apply: a tree that is one leaf is
///     `({ s; binders; (e); })`, and a single test between two leaves is
///     `({ s; (test ? A : B); })`.
///
///   \par Rules every match keeps
///     - The scrutinee is evaluated once: a scalar or prvalue into a local,
///       a class lvalue by `const T&`. A tuple literal is never built; each
///       element is its own local, in order.
///     - A switch holds only gotos, and every label sits at the match's top
///       level with the arm bodies in blocks of their own: no goto crosses
///       an initialization, and a `break`/`continue` in an arm reaches the
///       enclosing loop, not a switch.
///     - Labels come from LowerTargets with a per-function match number: C++
///       labels are function-scoped.
///     - A binder `var x` copies its occurrence; `const x` is `const T&` to
///       it. A guard reads its binders as `const T&` of its own.
///     - A `var` binder that is an arm's whole value is moved out:
///       `(static_cast<T&&>(x))`.
///     - Statement-expression tails are parenthesized: `({ ...; R(k); })`
///       would parse as a declaration.
///
///   \par Paths that differ
///     An arm reached on several paths whose binders sit at different
///     occurrences (alternatives: `case (var x, 0), (0, var x)`) reads them
///     through pointer slots, `const T* __kairo_mN_pI`, declared before the
///     first goto and set on each path before it jumps. A guard reached on
///     several paths is emitted once: each path sets a continuation index,
///     `__kairo_mN_k`, and the failure dispatches on it.
///
///   \par Tests
///       enum, tag      switch; a complete closed enum's default is
///                      UnmatchedPolicy, so an undeclared discriminant traps
///                      at -O0..-O2 and is unreachable at -O3.
///       integer        switch with GNU `case lo ... hi:`, keys un-biased to
///                      typed literals; i64's minimum is `(-9223372036854775807 - 1)`.
///       bool           `if`.
///       string         switch on `len`, then `__builtin_memcmp(data, "..", n) == 0`
///                      per length bucket: bytes, never `cp_len`.
///       opaque         `if` on `==`, or a range's two compares.
///
///   \par Not lowered here
///     A tuple that is not a literal is left as it is; EmitIR's ICE names
///     the owner. It appears in type-check-only tests that must keep
///     passing, so no gate reports it yet. An ADT's tag and payloads always
///     have their record by the time this runs: EnumLayoutLowering runs
///     before every body rewrite.
///
///   Phase: LOWER, after IterLowering and RangeLowering; before
///   SequenceLowering (which orders the scrutinee local) and StringLowering
///   (a string pattern's bytes are read here, before its literal becomes a
///   constructor call).
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
import Sema::Type::TypeUtil::*;
import Sema::Check::PatternSpace::*;
import Sema::Lower::LowerSynth::*;
import Sema::Lower::PatternCompilation::*;
import AST::Visitor::ASTWriter::*;
import AST::ASTSupport::*;
import AST::LangItems::*;
import AST::Context::SymbolTable::*;
import AST::Node::Base::*;
import AST::Node::Types::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Patterns::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Node::CanonicalNodes::*;
import AST::Kind::PatternKind::*;
import AST::Kind::TypeKind::*;
import Config::CodeGen::*;
import Token::Token::*;
import Token::TokenKind::*;
import Location::SourceRange::*;

__inline_cpp("
#define ASTWriter_MatchLowering ASTWriter<MatchLowering>
");

/// What one arm needs from the rendering.
struct ArmPlan {
    var reached: bool  = false;
    var slots:   bool  = false;  ///< binders differ between paths: read through slots.
    var rep:     i32   = -1;     ///< a Leaf/Guard node whose binders stand for every path.
    var used:    bool  = false;  ///< its label is a goto target.
    var label:   Token;
    var guards:  vec::<u32>;     ///< its Guard nodes.
    var glabel:  Token;          ///< the shared guard block, when guards.size() > 1.
}

/// A binder slot: `const T* __kairo_mN_pI`, for one decl of one arm.
struct Slot {
    var arm:  u32 = 0;
    var decl: *VariableDecl = &null;
    var var_: *VariableDecl = &null;
}

class MatchLowering derives ASTWriter::<MatchLowering> {
    pub var sc: *SemaContext;
    priv var tu: TypeUtil;
    priv var ps: PatternSpace;
    priv var synth: LowerSynth;
    priv var _fn_matches: usize = 0;   ///< matches lowered so far in this function.

    // --- one match ---------------------------------------------------------------
    priv var _n:       usize = 0;
    priv var _t:       *DecisionTree = &null;
    priv var _cases:   *FrozenList::<MatchCase> = &null;
    priv var _at:      SourceRange;
    priv var _value:   bool = false;
    priv var _ty:      *Type = &null;      ///< value form: the match's type.
    priv var _columns: usize = 0;
    priv var _locals:  vec::<*VariableDecl>;   ///< by occurrence; null when reached through a parent.
    priv var _labels:  vec::<Token>;           ///< by node.
    priv var _queued:  vec::<bool>;
    priv var _queue:   vec::<u32>;
    priv var _arms:    vec::<ArmPlan>;
    priv var _slots:   vec::<Slot>;
    priv var _arm_ix:  *VariableDecl = &null;
    priv var _cont:    *VariableDecl = &null;
    priv var _fail:    Token;
    priv var _fail_used: bool = false;
    priv var _end:     Token;
    priv var _buckets: usize = 0;
    priv var _qi:      usize = 0;       ///< next queued node to emit.

    fn MatchLowering(self, sc: *SemaContext) {
        self.sc    = sc;
        self.ctx   = sc->ctx;
        self.tu    = TypeUtil(sc);
        self.ps    = PatternSpace(sc);
        self.synth = LowerSynth(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked);
        if self.sc->tu == &null { return; }
        ASTWriter_MatchLowering::run(self.sc->tu);
    }

    // --- entry points -----------------------------------------------------------

    /// Labels are function-scoped, so the match number restarts per function.
    fn transform_function_decl(self, n: *FunctionDecl) -> vec::<*Decl> {
        var saved = self._fn_matches;
        self._fn_matches = 0;
        var out = ASTWriter_MatchLowering::transform_function_decl(n);
        self._fn_matches = saved;
        return out;
    }

    fn transform_match_stmt(self, n: *MatchStmt) -> vec::<*Stmt> {
        ASTWriter_MatchLowering::transform_match_stmt(n);   // inner matches, guards, bodies first.
        var out = self._lower(n->scrutinee, &(n->cases), n->decision, n->range, false, &null);
        if out == &null { return self._one_stmt(n); }
        return self._one_stmt(static_cast::<*Stmt>(out));
    }

    fn transform_match_expr(self, n: *MatchExpr) -> *Expr {
        ASTWriter_MatchLowering::transform_match_expr(n);
        var out = self._lower(n->scrutinee, &(n->cases), n->decision, n->range, true, n->type_);
        if out == &null { return n; }
        var se = cast::<StmtExpr>(cast::<ExpressionStmt>(cast::<CompoundStmt>(out)->body[0])->expr);
        se->adopt_sema(n);
        se->type_          = n->type_;
        se->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(se);
    }

    /// A value-form match whose value is discarded is the statement form:
    /// no arm index, no ternary.
    fn transform_expression_stmt(self, n: *ExpressionStmt) -> vec::<*Stmt> {
        var m = dyn_cast::<MatchExpr>(self.tu.strip_parens(n->expr));
        if m == &null { return ASTWriter_MatchLowering::transform_expression_stmt(n); }
        ASTWriter_MatchLowering::transform_match_expr(m);
        var out = self._lower(m->scrutinee, &(m->cases), m->decision, m->range, false, &null);
        if out == &null { return self._one_stmt(n); }
        return self._one_stmt(static_cast::<*Stmt>(out));
    }

    // --- one match -----------------------------------------------------------------

    /// The lowered block (statement form), or a block holding one
    /// ExpressionStmt of the StmtExpr (value form); null leaves the match.
    priv fn _lower(self, scrutinee: *Expr, cases: *FrozenList::<MatchCase>, decision: *void,
                   at: SourceRange, value: bool, ty: *Type) -> *CompoundStmt {
        if decision == &null { return &null; }
        self._t      = reinterpret_cast::<*DecisionTree>(decision);
        self._cases  = cases;
        self._at     = at;
        self._value  = value;
        self._ty     = ty;
        self._n      = self._fn_matches;
        self._reset();

        var pre = vec::<*Stmt>();
        self._bind_scrutinee(scrutinee, i32(0), &pre);
        if !self._renderable() { return &null; }
        self._fn_matches += 1;

        self._plan_arms();
        if self._value {
            var short = self._short_value();
            if short != &null { return self._wrap_value(&pre, short, &null); }
        }
        self._declare_state(&pre);

        var code = vec::<*Stmt>();
        var root = self._t->nodes[usize(self._t->root)];
        var skip_root = (!self._value) && (root.kind == DKind::Leaf) && (!self._arms[usize(root.arm)].slots);
        if !skip_root { self._node(self._t->root, &code); }
        self._drain(&code);
        self._shared_guards(&code);
        if self._fail_used {
            code.push_back(self._label_stmt(self._fail));
            code.push_back(self._policy());
        }

        if self._value {
            ICE_IF(self._t->nodes.size() == 0, "MatchLowering: empty decision tree");
            code.push_back(self._label_stmt(self._end));
            return self._wrap_value(&pre, self._ternary(), &code);
        }

        // Arms, in source order; the last one falls into the end label.
        var last: i32 = -1;
        for var k: usize = 0; k < self._arms.size(); ++k { if self._arms[k].reached { last = i32(k); } }
        var end_used = false;
        for var k: usize = 0; k < self._arms.size(); ++k {
            if !self._arms[k].reached { continue; }
            if self._arms[k].used { code.push_back(self._label_stmt(self._arms[k].label)); }
            code.push_back(static_cast::<*Stmt>(self._arm_block(u32(k))));
            if i32(k) != last {
                code.push_back(self._jump(self._end));
                end_used = true;
            }
        }
        if end_used { code.push_back(self._label_stmt(self._end)); }

        var all = vec::<*Stmt>();
        for var i: usize = 0; i < pre.size(); ++i  { all.push_back(pre[i]); }
        for var i: usize = 0; i < code.size(); ++i { all.push_back(code[i]); }
        return self._block(&all);
    }

    priv fn _reset(self) {
        var nn = self._t->nodes.size();
        self._columns = 0;
        self._locals  = vec::<*VariableDecl>();
        for var i: usize = 0; i < self._t->occs.size(); ++i { self._locals.push_back(&null); }
        self._labels = vec::<Token>();
        self._queued = vec::<bool>();
        for var i: usize = 0; i < nn; ++i {
            self._labels.push_back(self._name(LowerTargets::match_node(self._n, i)));
            self._queued.push_back(false);
        }
        self._queue  = vec::<u32>();
        self._arms   = vec::<ArmPlan>();
        for var k: usize = 0; k < self._cases->size(); ++k {
            var a = ArmPlan{};
            a.label  = self._name(LowerTargets::match_arm(self._n, k));
            a.glabel = self._name(LowerTargets::match_guard(self._n, k));
            self._arms.push_back(a);
        }
        self._slots     = vec::<Slot>();
        self._arm_ix    = &null;
        self._cont      = &null;
        self._fail      = self._name(LowerTargets::match_fail(self._n));
        self._fail_used = false;
        self._end       = self._name(LowerTargets::match_end(self._n));
        self._buckets   = 0;
        self._qi        = 0;
    }

    // --- the scrutinee -------------------------------------------------------------

    /// Bind \p e0 once. A tuple literal binds each element instead, in order;
    /// an element no pattern reaches is still evaluated.
    priv fn _bind_scrutinee(self, e0: *Expr, occ: i32, pre: *vec::<*Stmt>) {
        var e = self.tu.strip_parens(e0);
        var tl = dyn_cast::<TupleLiteralExpr>(e);
        if tl != &null {
            for var i: usize = 0; i < tl->elements.size(); ++i {
                var child: i32 = -1;
                if occ >= 0 { child = self._find_occ(u32(occ), OccKind::Elem, u32(i)); }
                self._bind_scrutinee(tl->elements[i], child, pre);
            }
            return;
        }
        var name = LowerTargets::match_scrutinee(self._n);
        if (occ != 0) || (self._columns > 0) {
            name = LowerTargets::match_column(self._n, self._columns);
        }
        self._columns += 1;

        var vt = canon_unqual(self._referee(e->type_));
        var lt = vt;
        if self._is_class(vt) && e->is_lvalue() {
            lt = self.sc->types->cxx_lref(self.sc->types->qualified(vt, QUAL_CONST()));
        }
        var vd = VariableDecl::create(self.ctx, self._at, self._name(name), StorageClass::Var);
        vd->type_ = lt;
        vd->init  = e;
        pre->push_back(static_cast::<*Stmt>(DeclStmt::create(self.ctx, self._at, static_cast::<*Decl>(vd))));
        if occ >= 0 { self._locals[usize(occ)] = vd; }
    }

    priv fn _find_occ(self, parent: u32, kind: OccKind, index: u32) -> i32 {
        for var i: usize = 0; i < self._t->occs.size(); ++i {
            var o = self._t->occs[i];
            if (o.parent == i32(parent)) && (o.kind == kind) && (o.index == index) { return i32(i); }
        }
        return -1;
    }

    /// A class value is bound by reference; a scalar or a plain enum is copied.
    priv fn _is_class(self, t: *Type) -> bool {
        if (t == &null) || (!isa::<RecordType>(t)) { return false; }
        var en = dyn_cast::<EnumDecl>(self.tu.pattern_of(cast::<RecordType>(t)->decl));
        if en != &null { return en->is_adt; }
        return true;
    }

    priv fn _referee(self, t: *Type) -> *Type {
        if (t != &null) && isa::<CXXLValueRefType>(t) { return cast::<CXXLValueRefType>(t)->referee; }
        if (t != &null) && isa::<CXXRValueRefType>(t) { return cast::<CXXRValueRefType>(t)->referee; }
        return t;
    }

    // --- what can be rendered --------------------------------------------------------

    /// Every occurrence the tree reads has a C++ path, and every enum it
    /// tests by tag has its record. See the file header.
    priv fn _renderable(self) -> bool {
        var t = self._t;
        for var i: usize = 0; i < t->nodes.size(); ++i {
            var n = t->nodes[i];
            if (n.kind == DKind::Switch) || (n.kind == DKind::Test) {
                if !self._occ_ok(n.occ) { return false; }
                for var k: u32 = 0; k < n.nedge; ++k {
                    var e = t->edges[usize(n.edge0 + k)];
                    if (e.kind == CtorKind::Variant) && (!self._tag_ok(n.occ)) { return false; }
                }
            }
            if (n.kind == DKind::Leaf) || (n.kind == DKind::Guard) {
                for var k: u32 = 0; k < n.nbind; ++k {
                    if !self._occ_ok(t->binds[usize(n.bind0 + k)].occ) { return false; }
                }
            }
        }
        return true;
    }

    priv fn _occ_ok(self, o: u32) -> bool {
        if self._locals[usize(o)] != &null { return true; }
        var d = self._t->occs[usize(o)];
        switch d.kind {
            case OccKind::Field   { return self._occ_ok(u32(d.parent)); }
            case OccKind::Payload {
                if !self._occ_ok(u32(d.parent)) { return false; }
                var v = self._variant_of(u32(d.parent), d.index);
                return (v != &null) && (v->adt_member != &null);
            }
            default { return false; }   // the root of a tuple literal, or an element of a tuple value.
        }
        return false;
    }

    priv fn _tag_ok(self, o: u32) -> bool {
        var en = self._enum_at(o);
        if en == &null { return false; }
        if !en->is_adt { return true; }
        return en->adt_tag_field != &null;
    }

    priv fn _enum_at(self, o: u32) -> *EnumDecl {
        return self.ps.domain_of(self._occ_type(o)).en;
    }

    priv fn _variant_of(self, o: u32, index: u32) -> *EnumVariantDecl {
        var en = self._enum_at(o);
        if (en == &null) || (usize(index) >= en->variants.size()) { return &null; }
        return en->variants[usize(index)];
    }

    // --- arms --------------------------------------------------------------------------

    /// Which arms are reached, which read their binders through slots, and
    /// which guards more than one path shares.
    priv fn _plan_arms(self) {
        var t = self._t;
        for var i: usize = 0; i < t->nodes.size(); ++i {
            var n = t->nodes[i];
            if (n.kind != DKind::Leaf) && (n.kind != DKind::Guard) { continue; }
            var a = &(self._arms[usize(n.arm)]);
            a->reached = true;
            if n.kind == DKind::Guard { a->guards.push_back(u32(i)); }
            if a->rep < 0 { a->rep = i32(i); continue; }
            if !self._same_binds(u32(a->rep), u32(i)) { a->slots = true; }
        }
    }

    priv fn _same_binds(self, a: u32, b: u32) -> bool {
        var na = self._t->nodes[usize(a)];
        var nb = self._t->nodes[usize(b)];
        if na.nbind != nb.nbind { return false; }
        for var i: u32 = 0; i < na.nbind; ++i {
            var x = self._t->binds[usize(na.bind0 + i)];
            var found = false;
            for var j: u32 = 0; j < nb.nbind; ++j {
                var y = self._t->binds[usize(nb.bind0 + j)];
                if (x.pat->decl == y.pat->decl) && (x.occ == y.occ) { found = true; break; }
            }
            if !found { return false; }
        }
        return true;
    }

    /// Slots, the arm index and the guard continuation: declared before the
    /// first goto, all trivially constructible.
    priv fn _declare_state(self, pre: *vec::<*Stmt>) {
        var any_shared = false;
        for var k: usize = 0; k < self._arms.size(); ++k {
            var a = &(self._arms[k]);
            if a->guards.size() > 1 { any_shared = true; }
            if (!a->reached) || (!a->slots) { continue; }
            var rep = self._t->nodes[usize(a->rep)];
            for var i: u32 = 0; i < rep.nbind; ++i {
                var b  = self._t->binds[usize(rep.bind0 + i)];
                var vd = cast::<VariableDecl>(b.pat->decl);
                var s  = Slot{};
                s.arm  = u32(k);
                s.decl = vd;
                s.var_ = VariableDecl::create(self.ctx, self._at,
                             self._name(LowerTargets::match_slot(self._n, self._slots.size())), StorageClass::Var);
                s.var_->type_ = self.sc->types->pointer(self.sc->types->qualified(self._binder_type(vd), QUAL_CONST()));
                s.var_->init  = &null;
                pre->push_back(static_cast::<*Stmt>(DeclStmt::create(self.ctx, self._at, static_cast::<*Decl>(s.var_))));
                self._slots.push_back(s);
            }
        }
        if self._value {
            self._arm_ix = VariableDecl::create(self.ctx, self._at,
                               self._name(LowerTargets::match_arm_index(self._n)), StorageClass::Var);
            self._arm_ix->type_ = self._u32();
            self._arm_ix->init  = &null;
            pre->push_back(static_cast::<*Stmt>(DeclStmt::create(self.ctx, self._at, static_cast::<*Decl>(self._arm_ix))));
        }
        if any_shared {
            self._cont = VariableDecl::create(self.ctx, self._at,
                             self._name(LowerTargets::match_cont(self._n)), StorageClass::Var);
            self._cont->type_ = self._u32();
            self._cont->init  = &null;
            pre->push_back(static_cast::<*Stmt>(DeclStmt::create(self.ctx, self._at, static_cast::<*Decl>(self._cont))));
        }
    }

    /// A binder's value type: what X typed it, before this pass makes a
    /// `const` binder a reference.
    priv fn _binder_type(self, vd: *VariableDecl) -> *Type {
        return canon_unqual(self._referee(vd->type_));
    }

    /// The statements that point \p arm's slots at node \p i's occurrences.
    priv fn _set_slots(self, arm: u32, i: u32, out: *vec::<*Stmt>) {
        if !self._arms[usize(arm)].slots { return; }
        var n = self._t->nodes[usize(i)];
        for var k: u32 = 0; k < n.nbind; ++k {
            var b = self._t->binds[usize(n.bind0 + k)];
            var s = self._slot(arm, cast::<VariableDecl>(b.pat->decl));
            out->push_back(self._expr_stmt(self._assign(self.synth.use_of(s, self._at, Expr::ValueCategory::LValue),
                                                         self.synth.addr_of(self._occ(b.occ)))));
        }
    }

    priv fn _slot(self, arm: u32, vd: *VariableDecl) -> *VariableDecl {
        for var i: usize = 0; i < self._slots.size(); ++i {
            if (self._slots[i].arm == arm) && (self._slots[i].decl == vd) { return self._slots[i].var_; }
        }
        ICE_FAIL("MatchLowering: a binder with no slot; alternatives must bind the same names (PatternBindingCheck)");
        return &null;
    }

    /// \p vd's initializer for arm \p arm: its occurrence on the
    /// representative path, or through its slot.
    priv fn _binder_init(self, arm: u32, vd: *VariableDecl) -> *Expr {
        var a = &(self._arms[usize(arm)]);
        if a->slots {
            var s = self._slot(arm, vd);
            return self._deref(self.synth.use_of(s, self._at, Expr::ValueCategory::LValue), self._binder_type(vd));
        }
        var rep = self._t->nodes[usize(a->rep)];
        for var k: u32 = 0; k < rep.nbind; ++k {
            var b = self._t->binds[usize(rep.bind0 + k)];
            if b.pat->decl == static_cast::<*Decl>(vd) { return self._occ(b.occ); }
        }
        ICE_FAIL("MatchLowering: a binder its representative path does not bind");
        return &null;
    }

    /// The arm's binder declarations, in the mode each was written with.
    priv fn _arm_binders(self, arm: u32, out: *vec::<*Stmt>) {
        var a = &(self._arms[usize(arm)]);
        var rep = self._t->nodes[usize(a->rep)];
        for var k: u32 = 0; k < rep.nbind; ++k {
            var b  = self._t->binds[usize(rep.bind0 + k)];
            var vd = cast::<VariableDecl>(b.pat->decl);
            var vt = self._binder_type(vd);
            vd->init = self._binder_init(arm, vd);
            if b.pat->is_const {
                vd->type_   = self.sc->types->cxx_lref(self.sc->types->qualified(vt, QUAL_CONST()));
                vd->storage = StorageClass::Var;   // the `const` is in the type; a keyword too would be `const const`.
            } else {
                vd->type_ = vt;
            }
            out->push_back(static_cast::<*Stmt>(DeclStmt::create(self.ctx, b.pat->range, static_cast::<*Decl>(vd))));
        }
    }

    /// The guard's own binders: `const T& x = <occurrence>`, never the
    /// arm's decls, which are declared in the arm block in their own mode.
    priv fn _guard_binders(self, arm: u32, out: *vec::<*Stmt>) {
        var a = &(self._arms[usize(arm)]);
        var rep = self._t->nodes[usize(a->rep)];
        for var k: u32 = 0; k < rep.nbind; ++k {
            var b  = self._t->binds[usize(rep.bind0 + k)];
            var vd = cast::<VariableDecl>(b.pat->decl);
            var g  = VariableDecl::create(self.ctx, b.pat->range, vd->name, StorageClass::Var);
            g->type_ = self.sc->types->cxx_lref(self.sc->types->qualified(self._binder_type(vd), QUAL_CONST()));
            g->init  = self._binder_init(arm, vd);
            out->push_back(static_cast::<*Stmt>(DeclStmt::create(self.ctx, b.pat->range, static_cast::<*Decl>(g))));
        }
    }

    /// Statement form: `{ binders; body }`.
    priv fn _arm_block(self, arm: u32) -> *CompoundStmt {
        var mc = self._cases->get(usize(arm));
        var out = vec::<*Stmt>();
        self._arm_binders(arm, &out);
        if mc->body != &null {
            for var i: usize = 0; i < mc->body->body.size(); ++i { out.push_back(mc->body->body[i]); }
        } else if mc->expression != &null {
            out.push_back(self._expr_stmt(mc->expression));
        }
        return self._block(&out);
    }

    /// Value form: the arm's value, `({ binders; (e); })` when it binds.
    priv fn _arm_value(self, arm: u32) -> *Expr {
        var mc = self._cases->get(usize(arm));
        ICE_IF(mc->expression == &null, "MatchLowering: a value-form arm with no expression");
        var stmts = vec::<*Stmt>();
        self._arm_binders(arm, &stmts);
        var e = self._moved_tail(arm, mc->expression);
        if stmts.size() == 0 { return e; }
        stmts.push_back(self._expr_stmt(self._paren(e)));
        var lb = self.list_builder::<*Stmt>();
        for var i: usize = 0; i < stmts.size(); ++i { lb.push(stmts[i]); }
        return self.synth.stmt_expr(mc->expression, &lb, mc->expression->type_);
    }

    /// `case .Error(var m) => m`: the binder copied the payload, so the
    /// value moves out of the binder instead of copying it again.
    priv fn _moved_tail(self, arm: u32, e: *Expr) -> *Expr {
        var s = dyn_cast::<NamedIdentExpr>(self.tu.strip_parens(e));
        if s == &null { return e; }
        var a = &(self._arms[usize(arm)]);
        var rep = self._t->nodes[usize(a->rep)];
        for var k: u32 = 0; k < rep.nbind; ++k {
            var b = self._t->binds[usize(rep.bind0 + k)];
            if (b.pat->decl != s->resolved_decl) || b.pat->is_const { continue; }
            var vt = self._binder_type(cast::<VariableDecl>(b.pat->decl));
            if !self._is_class(vt) { return e; }
            return self.synth.cast_to(e->range, e, self.sc->types->cxx_rref(vt), CastMode::Default);
        }
        return e;
    }

    // --- value form ------------------------------------------------------------------

    /// One leaf: the arm itself. One test between two leaves: a ternary.
    /// Null when neither applies.
    priv fn _short_value(self) -> *Expr {
        var t = self._t;
        var root = t->nodes[usize(t->root)];
        if root.kind == DKind::Leaf {
            if self._arms[usize(root.arm)].slots { return &null; }
            return self._arm_value(root.arm);
        }

        var cond: *Expr = &null;
        var yes: i32 = -1;
        var no:  i32 = -1;
        if root.kind == DKind::Test {
            var e = t->edges[usize(root.edge0)];
            yes = i32(e.child); no = root.other;
            if !(self._plain_leaf(yes) && self._plain_leaf(no)) { return &null; }
            cond = self._cond(root.occ, e);
        } else if root.kind == DKind::Switch {
            if root.strings { return &null; }
            if (root.nedge == 2) && (root.other < 0) && (t->edges[usize(root.edge0)].kind == CtorKind::Bool) {
                var e0 = t->edges[usize(root.edge0)];
                var e1 = t->edges[usize(root.edge0 + 1)];
                yes = (i32(e0.child)) if (e0.lo == u64(1)) else (i32(e1.child));
                no  = (i32(e1.child)) if (e0.lo == u64(1)) else (i32(e0.child));
                if !(self._plain_leaf(yes) && self._plain_leaf(no)) { return &null; }
                cond = self._occ(root.occ);
            } else if (root.nedge == 1) && (root.other >= 0) {
                var e = t->edges[usize(root.edge0)];
                yes = i32(e.child); no = root.other;
                if !(self._plain_leaf(yes) && self._plain_leaf(no)) { return &null; }
                cond = self._cond(root.occ, e);
            } else {
                return &null;
            }
        } else {
            return &null;
        }
        var ay = t->nodes[usize(yes)].arm;
        var an = t->nodes[usize(no)].arm;
        if ay == an { return &null; }
        var ie = IfExpr::create(self.ctx, self._at, cond, self._arm_value(ay), self._arm_value(an));
        ie->type_          = self._ty;
        ie->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(ie);
    }

    /// A Leaf whose arm reads its binders directly.
    priv fn _plain_leaf(self, i: i32) -> bool {
        if i < 0 { return false; }
        var n = self._t->nodes[usize(i)];
        return (n.kind == DKind::Leaf) && (!self._arms[usize(n.arm)].slots);
    }

    /// `arm == 0 ? A0 : arm == 1 ? A1 : ... : AL` over the reached arms.
    priv fn _ternary(self) -> *Expr {
        var reached = vec::<u32>();
        for var k: usize = 0; k < self._arms.size(); ++k { if self._arms[k].reached { reached.push_back(u32(k)); } }
        ICE_IF(reached.size() == 0, "MatchLowering: a value-form match no arm of which is reached");
        if reached.size() == 1 { return self._arm_value(reached[0]); }

        var ie = IfExpr::create(self.ctx, self._at, self._is_arm(reached[0]), self._arm_value(reached[0]),
                                self._arm_value(reached[reached.size() - 1]));
        var elifs = self.list_builder::<IfExpr::ElseIf>();
        for var i: usize = 1; i + 1 < reached.size(); ++i {
            var ei = IfExpr::ElseIf{};
            ei.condition = self._is_arm(reached[i]);
            ei.body      = self._arm_value(reached[i]);
            ei.range     = self._at;
            elifs.push(ei);
        }
        elifs.freeze_into(&(ie->else_ifs));
        ie->type_          = self._ty;
        ie->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(ie);
    }

    priv fn _is_arm(self, k: u32) -> *Expr {
        return self._eq(self.synth.use_of(self._arm_ix, self._at, Expr::ValueCategory::LValue),
                        self.synth.int_literal(self._at, u64(k), BuiltinKind::U32));
    }

    /// `({ pre; code; (value); })` as a block holding its one statement,
    /// the shape _lower returns.
    priv fn _wrap_value(self, pre: *vec::<*Stmt>, value: *Expr, code: *vec::<*Stmt>) -> *CompoundStmt {
        var lb = self.list_builder::<*Stmt>();
        for var i: usize = 0; i < pre->size(); ++i { lb.push((*pre)[i]); }
        if code != &null { for var i: usize = 0; i < code->size(); ++i { lb.push((*code)[i]); } }
        lb.push(self._expr_stmt(self._paren(value)));
        var body = CompoundStmt::create(self.ctx, self._at);
        lb.freeze_into(&(body->body));
        var se = StmtExpr::create(self.ctx, self._at, body);
        se->type_          = self._ty;
        se->value_category = Expr::ValueCategory::RValue;
        var one = vec::<*Stmt>();
        one.push_back(self._expr_stmt(static_cast::<*Expr>(se)));
        return self._block(&one);
    }

    // --- nodes -------------------------------------------------------------------------

    /// Node \p i's code. Every path through it ends in a goto (or the
    /// noreturn policy call), so the order nodes are emitted in is free.
    priv fn _node(self, i: u32, out: *vec::<*Stmt>) {
        var n = self._t->nodes[usize(i)];
        switch n.kind {
            case DKind::Fail   { out->push_back(self._policy()); }
            case DKind::Leaf   { self._accept(n.arm, i, out); }
            case DKind::Guard  { self._guard(i, out); }
            case DKind::Test {
                var e = self._t->edges[usize(n.edge0)];
                self._if_goto(self._cond(n.occ, e), i32(e.child), out);
                out->push_back(self._jump(self._target(n.other)));
            }
            case DKind::Switch { self._switch(i, out); }
        }
    }

    /// Taking arm \p arm from node \p i: point the slots, then jump to the
    /// arm (statement form) or record it and jump to the join (value form).
    priv fn _accept(self, arm: u32, i: u32, out: *vec::<*Stmt>) {
        self._set_slots(arm, i, out);
        if self._value {
            out->push_back(self._expr_stmt(self._assign(self.synth.use_of(self._arm_ix, self._at, Expr::ValueCategory::LValue),
                                                         self.synth.int_literal(self._at, u64(arm), BuiltinKind::U32))));
            out->push_back(self._jump(self._end));
            return;
        }
        self._arms[usize(arm)].used = true;
        out->push_back(self._jump(self._arms[usize(arm)].label));
    }

    /// A guard reached on one path is emitted where it is reached. One
    /// reached on several is a shared block (_shared_guards); each path
    /// points the slots, records which path it is, and jumps there.
    priv fn _guard(self, i: u32, out: *vec::<*Stmt>) {
        var n = self._t->nodes[usize(i)];
        var a = &(self._arms[usize(n.arm)]);
        if a->guards.size() > 1 {
            self._set_slots(n.arm, i, out);
            var j: usize = 0;
            while a->guards[j] != i { j += 1; }
            out->push_back(self._expr_stmt(self._assign(self.synth.use_of(self._cont, self._at, Expr::ValueCategory::LValue),
                                                         self.synth.int_literal(self._at, u64(j), BuiltinKind::U32))));
            out->push_back(self._jump(a->glabel));
            return;
        }
        self._set_slots(n.arm, i, out);
        out->push_back(static_cast::<*Stmt>(self._guard_block(n.arm)));
        out->push_back(self._jump(self._target(n.other)));
    }

    /// `{ const T& x = ...; if (guard) { <accept> } }`
    priv fn _guard_block(self, arm: u32) -> *CompoundStmt {
        var mc = self._cases->get(usize(arm));
        var inner = vec::<*Stmt>();
        self._guard_binders(arm, &inner);
        var take = vec::<*Stmt>();
        if self._value {
            take.push_back(self._expr_stmt(self._assign(self.synth.use_of(self._arm_ix, self._at, Expr::ValueCategory::LValue),
                                                         self.synth.int_literal(self._at, u64(arm), BuiltinKind::U32))));
            take.push_back(self._jump(self._end));
        } else {
            self._arms[usize(arm)].used = true;
            take.push_back(self._jump(self._arms[usize(arm)].label));
        }
        inner.push_back(static_cast::<*Stmt>(ConditionalStmt::create(self.ctx, mc->guard->range, mc->guard, self._block(&take), &null)));
        return self._block(&inner);
    }

    /// The blocks of guards reached on several paths: the guard once, then
    /// a dispatch on the continuation to the failing path's next node.
    priv fn _shared_guards(self, out: *vec::<*Stmt>) {
        for var k: usize = 0; k < self._arms.size(); ++k {
            var a = &(self._arms[k]);
            if a->guards.size() < 2 { continue; }
            out->push_back(self._label_stmt(a->glabel));
            out->push_back(static_cast::<*Stmt>(self._guard_block(u32(k))));
            var cases = vec::<DispatchCase>();
            for var j: usize = 0; j + 1 < a->guards.size(); ++j {
                var c = DispatchCase{};
                c.lo     = self.synth.int_literal(self._at, u64(j), BuiltinKind::U32);
                c.hi     = &null;
                c.target = self._target(self._t->nodes[usize(a->guards[j])].other);
                cases.push_back(c);
            }
            var last = self._t->nodes[usize(a->guards[a->guards.size() - 1])].other;
            out->push_back(self._dispatch(self.synth.use_of(self._cont, self._at, Expr::ValueCategory::LValue),
                                          &cases, last));
        }
        self._drain(out);   // their failures may reach nodes nothing else did.
    }

    /// Emit every queued node not yet emitted, each under its label. A
    /// node's code can queue more; the loop takes them too.
    priv fn _drain(self, out: *vec::<*Stmt>) {
        while self._qi < self._queue.size() {
            var k = self._queue[self._qi];
            self._qi += 1;
            out->push_back(self._label_stmt(self._labels[usize(k)]));
            self._node(k, out);
        }
    }

    // --- switches ------------------------------------------------------------------------

    priv fn _switch(self, i: u32, out: *vec::<*Stmt>) {
        var n = self._t->nodes[usize(i)];
        if n.strings { self._switch_strings(n, out); return; }
        var d = self.ps.domain_of(self._occ_type(n.occ));

        if d.kind == DomainKind::Bool {
            var yes = n.other;
            var no  = n.other;
            for var k: u32 = 0; k < n.nedge; ++k {
                var e = self._t->edges[usize(n.edge0 + k)];
                if e.lo == u64(1) { yes = i32(e.child); } else { no = i32(e.child); }
            }
            self._if_goto(self._occ(n.occ), yes, out);
            out->push_back(self._jump(self._target(no)));
            return;
        }

        var value: *Expr = &null;
        if d.kind == DomainKind::ClosedEnum {
            value = self._enum_value(n.occ, d.en);
        } else if d.kind == DomainKind::Int {
            value = self._occ(n.occ);
        } else {
            ICE_FAIL("MatchLowering: a switch over a domain PatternCompilation never switches on");
        }

        var cases = vec::<DispatchCase>();
        var count = n.nedge;
        var other = n.other;
        // A complete integer switch has no default of its own: the last
        // edge takes it. A complete enum's default is UnmatchedPolicy.
        if (other < 0) && (d.kind == DomainKind::Int) && (count > 0) {
            other = i32(self._t->edges[usize(n.edge0 + count - 1)].child);
            count = count - 1;
        }
        for var k: u32 = 0; k < count; ++k {
            var e = self._t->edges[usize(n.edge0 + k)];
            var c = DispatchCase{};
            c.target = self._target(i32(e.child));
            if d.kind == DomainKind::ClosedEnum {
                c.lo = self._enum_case(d.en, e.index, self._occ_type(n.occ));
                c.hi = &null;
            } else {
                var t = self._occ_type(n.occ);
                c.lo = self._int_value(d, e.lo, t);
                c.hi = (&null) if (e.lo == e.hi) else (self._int_value(d, e.hi, t));
            }
            cases.push_back(c);
        }
        out->push_back(self._dispatch(value, &cases, other));
    }

    /// The switch operand for an enum: the value itself, or for an ADT its
    /// tag as `u32` (tags are the variant positions; EnumLayoutLowering).
    priv fn _enum_value(self, occ: u32, en: *EnumDecl) -> *Expr {
        if !en->is_adt { return self._occ(occ); }
        var tag = en->adt_tag_field;
        var f = self.synth.field_of(self._at, self._occ(occ), static_cast::<*Decl>(tag), tag->type_);
        return self.synth.cast_to(self._at, f, self._u32(), CastMode::Default);
    }

    /// A case value: the enumerator, or for an ADT the tag's position.
    priv fn _enum_case(self, en: *EnumDecl, index: u32, ty: *Type) -> *Expr {
        if en->is_adt { return self.synth.int_literal(self._at, u64(index), BuiltinKind::U32); }
        return self._decl_ref(static_cast::<*Decl>(en->variants[usize(index)]), ty);
    }

    /// Strings: `switch (s.len)` into one bucket per length, each a run of
    /// `memcmp`s; whatever no bucket takes goes to the default.
    priv fn _switch_strings(self, n: DNode, out: *vec::<*Stmt>) {
        var lens   = vec::<usize>();
        var bucket = vec::<Token>();
        for var k: u32 = 0; k < n.nedge; ++k {
            var e = self._t->edges[usize(n.edge0 + k)];
            var b = vec::<u8>();
            pattern_string_bytes(self.sc, e.pat, &b);
            var seen = false;
            for var j: usize = 0; j < lens.size(); ++j { if lens[j] == b.size() { seen = true; break; } }
            if !seen {
                lens.push_back(b.size());
                bucket.push_back(self._name(LowerTargets::match_node(self._n, self._t->nodes.size() + self._buckets)));
                self._buckets += 1;
            }
        }

        var cases = vec::<DispatchCase>();
        for var j: usize = 0; j < lens.size(); ++j {
            var c = DispatchCase{};
            c.lo = self.synth.int_literal(self._at, u64(lens[j]), BuiltinKind::USize);
            c.hi = &null;
            c.target = bucket[j];
            if lens[j] == 0 {
                // Length alone settles the empty string: no bucket, no memcmp.
                for var k: u32 = 0; k < n.nedge; ++k {
                    var e = self._t->edges[usize(n.edge0 + k)];
                    var b = vec::<u8>();
                    pattern_string_bytes(self.sc, e.pat, &b);
                    if b.size() == 0 { c.target = self._target(i32(e.child)); break; }
                }
            }
            cases.push_back(c);
        }
        out->push_back(self._dispatch(self._string_field(n.occ, "len", self._usize()), &cases, n.other));

        for var j: usize = 0; j < lens.size(); ++j {
            if lens[j] == 0 { continue; }
            out->push_back(self._label_stmt(bucket[j]));
            for var k: u32 = 0; k < n.nedge; ++k {
                var e = self._t->edges[usize(n.edge0 + k)];
                var b = vec::<u8>();
                pattern_string_bytes(self.sc, e.pat, &b);
                if b.size() != lens[j] { continue; }
                self._if_goto(self._memcmp_eq(n.occ, &b), i32(e.child), out);
            }
            out->push_back(self._jump(self._target(n.other)));
        }
    }

    // --- tests -------------------------------------------------------------------------

    /// The condition under which the value at \p occ takes edge \p e.
    priv fn _cond(self, occ: u32, e: DEdge) -> *Expr {
        switch e.kind {
            case CtorKind::Bool {
                if e.lo == u64(1) { return self._occ(occ); }
                return self._not(self._occ(occ));
            }
            case CtorKind::Int {
                var d = self.ps.domain_of(self._occ_type(occ));
                var t = self._occ_type(occ);
                if e.lo == e.hi { return self._eq(self._occ(occ), self._int_value(d, e.lo, t)); }
                var c: *Expr = &null;
                if e.lo > u64(0)    { c = self._cmp(self._occ(occ), self._int_value(d, e.lo, t), TokenKind::OpGreaterEqual); }
                if e.hi < d.max_key { c = self._and(c, self._cmp(self._occ(occ), self._int_value(d, e.hi, t), TokenKind::OpLessEqual)); }
                if c == &null { return self.synth.bool_literal(self._at, true); }
                return c;
            }
            case CtorKind::Variant {
                var en = self._enum_at(occ);
                return self._eq(self._enum_value(occ, en), self._enum_case(en, e.index, self._occ_type(occ)));
            }
            case CtorKind::Opaque { return self._opaque_cond(occ, e.pat); }
            default { 0; }
        }
        ICE_FAIL("MatchLowering: a test on a constructor with no test (tuple or record)");
        return &null;
    }

    /// An opaque head's test, read off the pattern. Its operands are
    /// literals and constant names (X: SC126E for range bounds), leaves no
    /// later pass rewrites, so reading them on more than one path is safe.
    priv fn _opaque_cond(self, occ: u32, p: *Pattern) -> *Expr {
        var t = self._occ_type(occ);
        if (t != &null) && self.tu.is_string(t) {
            var b = vec::<u8>();
            ICE_IF(!pattern_string_bytes(self.sc, p, &b), "MatchLowering: a string head with no bytes; PatternCompilation gate failure");
            var len = self._eq(self._string_field(occ, "len", self._usize()),
                               self.synth.int_literal(self._at, u64(b.size()), BuiltinKind::USize));
            if b.size() == 0 { return len; }
            return self._and(len, self._memcmp_eq(occ, &b));
        }
        switch p->kind {
            case PatternKind::LiteralPattern {
                return self._eq(self._occ(occ), cast::<LiteralPattern>(p)->value);
            }
            case PatternKind::RangePattern {
                var r = cast::<RangePattern>(p);
                var c: *Expr = &null;
                if r->lo != &null { c = self._cmp(self._occ(occ), r->lo, TokenKind::OpGreaterEqual); }
                if r->hi != &null {
                    var k = (TokenKind::OpLessEqual) if (r->is_inclusive) else (TokenKind::OpLess);
                    c = self._and(c, self._cmp(self._occ(occ), r->hi, k));
                }
                if c == &null { return self.synth.bool_literal(self._at, true); }
                return c;
            }
            case PatternKind::ConstructorPattern {
                return self._eq(self._occ(occ), self._decl_ref(p->resolved_decl, t));
            }
            case PatternKind::UnresolvedConstructorPattern {
                return self._eq(self._occ(occ), self._decl_ref(p->resolved_decl, t));
            }
            default { 0; }
        }
        ICE_FAIL("MatchLowering: an opaque pattern kind with no test");
        return &null;
    }

    /// `__builtin_memcmp(s.data, "<bytes>", n) == 0`.
    priv fn _memcmp_eq(self, occ: u32, bytes: *vec::<u8>) -> *Expr {
        var f = self._builtin("__builtin_memcmp");
        var pu8 = self.sc->types->pointer(self.sc->types->qualified(self.sc->builtin(BuiltinKind::U8), QUAL_CONST()));
        var args = self.list_builder::<*Expr>();
        args.push(self._string_field(occ, "data", pu8));
        args.push(self.synth.bytes_literal(self._at, bytes, pu8));
        args.push(self.synth.int_literal(self._at, u64(bytes->size()), BuiltinKind::USize));
        var call = self._call(f, &args);
        return self._eq(call, self.synth.int_literal(self._at, 0, BuiltinKind::I32));
    }

    priv fn _string_field(self, occ: u32, name: string, ty: *Type) -> *Expr {
        return self.synth.field_of(self._at, self._occ(occ), self._lang_member(WellKnownType::String, name), ty);
    }

    /// Key \p key of \p d as a literal of type \p t: the bias undone, a
    /// negative value as `(-mag)`, and i64's minimum as `(-(2^63 - 1) - 1)`,
    /// since `2^63` has no signed 64-bit literal.
    priv fn _int_value(self, d: Domain, key: u64, t: *Type) -> *Expr {
        var kind = self._builtin_kind(t);
        if !d.signed { return self.synth.int_literal(self._at, key, kind); }
        var bias = u64(1) << u64(d.bits - 1);
        if key >= bias { return self.synth.int_literal(self._at, key - bias, kind); }
        var mag = bias - key;
        if (d.bits == 64) && (mag == bias) {
            var near = self._neg(self.synth.int_literal(self._at, bias - u64(1), kind), t);
            return self._arith(near, self.synth.int_literal(self._at, 1, kind), TokenKind::OpMinus, t);
        }
        return self._neg(self.synth.int_literal(self._at, mag, kind), t);
    }

    priv fn _builtin_kind(self, t: *Type) -> BuiltinKind {
        var b = dyn_cast::<BuiltinType>(canon_unqual(self.tu.as_value(t)));
        ICE_IF(b == &null, "MatchLowering: an integer column whose type is not a builtin integer");
        return b->builtin;
    }

    // --- occurrences -----------------------------------------------------------------

    /// The value at occurrence \p o, a fresh tree on every call: a node has
    /// one parent.
    priv fn _occ(self, o: u32) -> *Expr {
        var local = self._locals[usize(o)];
        if local != &null {
            var use = self.synth.use_of(local, self._at, Expr::ValueCategory::LValue);
            use->type_ = canon_unqual(self._referee(local->type_));
            return use;
        }
        var d = self._t->occs[usize(o)];
        switch d.kind {
            case OccKind::Field {
                return self.synth.field_of(self._at, self._occ(u32(d.parent)), static_cast::<*Decl>(d.field), self._occ_type(o));
            }
            case OccKind::Payload {
                var v = self._variant_of(u32(d.parent), d.index);
                var m = v->adt_member;
                var u = self.synth.field_of(self._at, self._occ(u32(d.parent)), static_cast::<*Decl>(m), m->type_);
                return self.synth.field_of(self._at, u, static_cast::<*Decl>(d.field), self._occ_type(o));
            }
            default { 0; }
        }
        ICE_FAIL("MatchLowering: an occurrence with no C++ path; _renderable gate failure");
        return &null;
    }

    priv fn _occ_type(self, o: u32) -> *Type {
        var d = self._t->occs[usize(o)];
        if d.type_ != &null { return d.type_; }
        if d.field != &null { return d.field->type_; }
        return &null;
    }

    // --- jumps -------------------------------------------------------------------------

    /// The label a jump to node \p i lands on: the fail block, an arm
    /// (statement form, a leaf with nothing to do first), or the node's own
    /// label, queueing the node.
    priv fn _target(self, i: i32) -> Token {
        ICE_IF(i < 0, "MatchLowering: a jump to no node");
        var n = self._t->nodes[usize(i)];
        if n.kind == DKind::Fail {
            self._fail_used = true;
            return self._fail;
        }
        if (n.kind == DKind::Leaf) && (!self._value) && (!self._arms[usize(n.arm)].slots) {
            self._arms[usize(n.arm)].used = true;
            return self._arms[usize(n.arm)].label;
        }
        if !self._queued[usize(i)] {
            self._queued[usize(i)] = true;
            self._queue.push_back(u32(i));
        }
        return self._labels[usize(i)];
    }

    /// `if (c) { goto <child>; }`
    priv fn _if_goto(self, c: *Expr, child: i32, out: *vec::<*Stmt>) {
        var take = vec::<*Stmt>();
        take.push_back(self._jump(self._target(child)));
        out->push_back(static_cast::<*Stmt>(ConditionalStmt::create(self.ctx, self._at, c, self._block(&take), &null)));
    }

    /// `switch (v) { case ...: goto ...; default: goto <other>; }`; a
    /// negative \p other, or one that is a Fail node, puts UnmatchedPolicy
    /// in the default itself.
    priv fn _dispatch(self, value: *Expr, cases: *vec::<DispatchCase>, other: i32) -> *Stmt {
        var s = SwitchDispatchStmt::create(self.ctx, self._at, value);
        var lb = self.list_builder::<DispatchCase>();
        for var i: usize = 0; i < cases->size(); ++i { lb.push((*cases)[i]); }
        lb.freeze_into(&(s->cases));
        if (other < 0) || (self._t->nodes[usize(other)].kind == DKind::Fail) {
            s->default_stmt = self._policy();
        } else {
            s->default_target = self._target(other);
        }
        return static_cast::<*Stmt>(s);
    }

    /// `__builtin_trap();` or `__builtin_unreachable();`, by UnmatchedPolicy.
    priv fn _policy(self) -> *Stmt {
        var name = ("__builtin_unreachable") if (self.sc->opts.unmatched == UnmatchedPolicy::Unreachable) else ("__builtin_trap");
        var none = self.list_builder::<*Expr>();
        return self._expr_stmt(self._call(self._builtin(name), &none));
    }

    priv fn _builtin(self, name: string) -> *FunctionDecl {
        ICE_IF(self.sc->builtins == &null, "MatchLowering: no builtin importer; the driver must initialize BuiltinImport before sema");
        var e = self.sc->builtins->resolve(name);
        ICE_IF(e.decl == &null, f"MatchLowering: '{name}' did not resolve as a clang builtin: {e.why}");
        return e.decl;
    }

    priv fn _call(self, f: *FunctionDecl, args: *ListBuilder::<*Expr>) -> *Expr {
        var callee = NamedIdentExpr::create(self.ctx, self._at, self.synth.ident(self._at, self.tu.decl_name(static_cast::<*Decl>(f))));
        callee->resolved_decl = static_cast::<*Decl>(f);
        var c = CallExpr::create(self.ctx, self._at, static_cast::<*Expr>(callee));
        args->freeze_into(&(c->args));
        c->type_          = f->return_type;
        c->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(c);
    }

    // --- lang-item members (IterLowering::_lang_member) ----------------------------------

    priv fn _lang_member(self, k: WellKnownType, name: string) -> *Decl {
        var d = self.sc->well_known->get(k);
        ICE_IF(d == &null, f"MatchLowering: the '{to_string(k)}' lang item is unbound");
        var body = self.tu.pattern_of(NameLookup::representative(d));
        var dc   = NameLookup::context_of(body);
        ICE_IF(dc == &null, f"MatchLowering: '{to_string(k)}' has no scope");
        var imm  = self.sc->imm_table()->intern_ident_copy(name);
        var cell = self.sc->lookup.in_context(dc, DeclName::ident(imm), name);
        ICE_IF(!cell.found(), f"MatchLowering: '{to_string(k)}' has no member '{name}'; Lib/builtin and the lowering disagree");
        return cell.first();
    }

    // --- minting -----------------------------------------------------------------------

    priv fn _name(self, s: string) -> Token { return self.synth.ident(self._at, s); }

    priv fn _u32(self)   -> *Type { return self.sc->builtin(BuiltinKind::U32); }
    priv fn _usize(self) -> *Type { return self.sc->builtin(BuiltinKind::USize); }
    priv fn _bool(self)  -> *Type { return self.sc->builtin(BuiltinKind::Bool); }

    priv fn _label_stmt(self, t: Token) -> *Stmt {
        return static_cast::<*Stmt>(LabelIntrinsicStmt::create(self.ctx, self._at, t));
    }

    priv fn _jump(self, t: Token) -> *Stmt {
        return static_cast::<*Stmt>(JumpIntrinsicStmt::create(self.ctx, self._at, t));
    }

    priv fn _block(self, stmts: *vec::<*Stmt>) -> *CompoundStmt {
        var lb = self.list_builder::<*Stmt>();
        for var i: usize = 0; i < stmts->size(); ++i { lb.push((*stmts)[i]); }
        var c = CompoundStmt::create(self.ctx, self._at);
        lb.freeze_into(&(c->body));
        return c;
    }

    priv fn _expr_stmt(self, e: *Expr) -> *Stmt {
        return static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, e->range, e));
    }

    priv fn _paren(self, e: *Expr) -> *Expr {
        var p = ParenExpr::create(self.ctx, e->range, e);
        p->type_          = e->type_;
        p->value_category = e->value_category;
        return static_cast::<*Expr>(p);
    }

    /// A name for an enumerator or a constant, spelled by EmitIR from the decl.
    priv fn _decl_ref(self, d: *Decl, ty: *Type) -> *Expr {
        var r = NamedIdentExpr::create(self.ctx, self._at, self.synth.ident(self._at, self.tu.decl_name(d)));
        r->resolved_decl  = d;
        r->type_          = ty;
        r->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(r);
    }

    priv fn _eq(self, l: *Expr, r: *Expr) -> *Expr { return self._cmp(l, r, TokenKind::OpEqualEqual); }

    priv fn _cmp(self, l: *Expr, r: *Expr, k: TokenKind) -> *Expr {
        var b = BinaryOperatorExpr::create(self.ctx, self._at, l, r, self.synth.punct(self._at, k));
        b->type_          = self._bool();
        b->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(b);
    }

    /// `l && r`; a null \p l is `r`.
    priv fn _and(self, l: *Expr, r: *Expr) -> *Expr {
        if l == &null { return r; }
        return self._cmp(l, r, TokenKind::OpAmpAmp);
    }

    priv fn _not(self, e: *Expr) -> *Expr {
        var u = UnaryOperatorExpr::create(self.ctx, self._at, e, self.synth.punct(self._at, TokenKind::OpExclaim),
                                          UnaryOperatorExpr::Fix::Prefix);
        u->type_          = self._bool();
        u->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(u);
    }

    priv fn _neg(self, e: *Expr, t: *Type) -> *Expr {
        var u = UnaryOperatorExpr::create(self.ctx, self._at, e, self.synth.punct(self._at, TokenKind::OpMinus),
                                          UnaryOperatorExpr::Fix::Prefix);
        u->type_          = t;
        u->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(u);
    }

    priv fn _arith(self, l: *Expr, r: *Expr, k: TokenKind, t: *Type) -> *Expr {
        var b = BinaryOperatorExpr::create(self.ctx, self._at, l, r, self.synth.punct(self._at, k));
        b->type_          = t;
        b->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(b);
    }

    priv fn _assign(self, l: *Expr, r: *Expr) -> *Expr {
        var a = AssignOperatorExpr::create(self.ctx, self._at, l, r, self.synth.punct(self._at, TokenKind::OpEqual));
        a->type_          = l->type_;
        a->value_category = Expr::ValueCategory::LValue;
        return static_cast::<*Expr>(a);
    }

    priv fn _deref(self, e: *Expr, t: *Type) -> *Expr {
        var u = UnaryOperatorExpr::create(self.ctx, self._at, e, self.synth.punct(self._at, TokenKind::OpStar),
                                          UnaryOperatorExpr::Fix::Prefix);
        u->type_          = t;
        u->value_category = Expr::ValueCategory::LValue;
        return static_cast::<*Expr>(u);
    }
}

__inline_cpp("
#undef ASTWriter_MatchLowering
");