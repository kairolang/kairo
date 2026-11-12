/// --- The Kairo Project ------------------- Sema/Lower/MatchLowering.k --- ///
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
///       enum           switch; a complete `@open` (or imported) enum's
///                      default is UnmatchedPolicy, so an undeclared
///                      discriminant traps at -O0..-O2 and is unreachable at
///                      -O3. A closed plain enum holds no undeclared value
///                      (`as` into it is checked), so its default is the
///                      ADT tag's policy below.
///       ADT tag        switch on EnumLayoutQuery::tag_word; a complete
///                      one's default is unreachable (no value holds another
///                      tag), a trap under --hardening=enum-tags.
///       integer        switch with GNU `case lo ... hi:`, keys un-biased to
///                      typed literals; i64's minimum is `(-9223372036854775807 - 1)`.
///       bool           `if`.
///       string         switch on `len`, then `__builtin_memcmp(data, "..", n) == 0`
///                      per length bucket: bytes, never `cp_len`.
///       opaque         `if` on `==`, or a range's two compares. On a record
///                      column the `==` is the one X typed for the pattern
///                      (SemaContext::pattern_eqs): the user `op ==`, as a
///                      call (_eq_test).
///
///   \par Not lowered here
///     Nothing of a tuple's: a tuple VALUE is its arity's record and reads
///     through the Field path like any struct (TupleLowering gives the
///     index step a field name later); a tuple LITERAL scrutinee is never
///     built (above). An ADT's tag and payloads always have their record
///     by the time this runs: EnumLayoutLowering runs before every body
///     rewrite.
///
///   Phase: LOWER, after IterLowering and RangeLowering; before
///   SequenceLowering (which orders the scrutinee local) and StringLowering
///   (a string pattern's bytes are read here, before its literal becomes a
///   constructor call).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::ASTSupport::FrozenList
import AST::Context::SymbolTable::DeclName
import AST::DeclFacts::adt_variant_at
import AST::Kind::PatternKind::{
    PatternKind,
    to_string,
}
import AST::Kind::TypeKind::to_string
import AST::LangItems::{
    LangMembers,
    LowerTargets,
    WellKnownType,
    to_string,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Pattern,
    Stmt,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    BuiltinType,
    QUAL_CONST,
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    EnumDecl,
    EnumVariantDecl,
    FieldDecl,
    FunctionDecl,
    StorageClass,
    VariableDecl,
}
import AST::Node::Expressions::{
    AssignOperatorExpr, BinaryOperatorExpr, CallExpr,         CastMode,          IfExpr, MatchExpr,
    ParenExpr,          StmtExpr,           TupleLiteralExpr, UnaryOperatorExpr,
}
import AST::Node::Patterns::{
    LiteralPattern,
    RangePattern,
}
import AST::Node::PrimaryExpressions::NamedIdentExpr
import AST::Node::Statements::{
    CompoundStmt,      ConditionalStmt,    DeclStmt,  DispatchCase, ExpressionStmt,
    JumpIntrinsicStmt, LabelIntrinsicStmt, MatchCase, MatchStmt,    SwitchDispatchStmt,
}
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
}
import AST::Visitor::ASTWriter::{
    ASTWriter,
    ListBuilder,
}
import Config::CodeGen::UnmatchedPolicy
import Location::SourceRange::SourceRange
import Sema::Check::PatternSpace::{
    CtorKind,
    Domain,
    DomainKind,
    PatternSpace,
}
import Sema::Lower::EnumLayoutLowering::EnumLayoutQuery
import Sema::Lower::LowerStep::LowerStep
import Sema::Lower::LowerSynth::LowerSynth
import Sema::Lower::OperatorLowering::OperatorLowering
import Sema::Lower::PatternCompilation::{
    DEdge,
    DKind,
    DNode,
    DecisionTree,
    OccKind,
    pattern_string_bytes,
}
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::TypeUtil::TypeUtil
import Token::Token::Token
import Token::TokenKind::TokenKind

/// What one arm needs from the rendering.
pub struct ArmPlan {
    var reached: bool                  = false
    var slots:   bool                  = false ///< binders differ between paths: read through slots.
    var rep:     i32                   = -1 ///< a Leaf/Guard node whose binders stand for every path.
    var used:    bool                  = false ///< its label is a goto target.
    var label:   Token
    var guards:  cxx::std::vector<u32> ///< its Guard nodes.
    var glabel:  Token ///< the shared guard block, when guards.size() > 1.
}

/// A binder slot: `const T* __kairo_mN_pI`, for one decl of one arm.
pub struct Slot {
    var arm:  u32                  = 0
    var decl: unsafe *VariableDecl = &null
    var var_: unsafe *VariableDecl = &null
}

pub class MatchLowering derives ASTWriter<MatchLowering> {
    pub var  sc:          unsafe *SemaContext
    priv var tu:          TypeUtil
    priv var ps:          PatternSpace
    priv var synth:       LowerSynth
    priv var layout:      EnumLayoutQuery ///< every read and test of an ADT value.
    priv var ops:         OperatorLowering ///< a record pattern's `op ==` test (_eq_test); one instance per run, so minted names stay unique.
    priv var _fn_matches: usize               = 0 ///< matches lowered so far in this function.

    /// # one match

    priv var _n:         usize                                  = 0
    priv var _t:         unsafe *DecisionTree                   = &null
    priv var _cases:     unsafe *FrozenList<MatchCase>          = &null
    priv var _at:        SourceRange
    priv var _value:     bool                                   = false
    priv var _ty:        unsafe *Type                           = &null ///< value form: the match's type.
    priv var _columns:   usize                                  = 0
    priv var _locals:    cxx::std::vector<unsafe *VariableDecl> ///< by occurrence; null when reached through a parent.
    priv var _labels:    cxx::std::vector<Token> ///< by node.
    priv var _queued:    cxx::std::vector<u8>
    priv var _queue:     cxx::std::vector<u32>
    priv var _arms:      cxx::std::vector<ArmPlan>
    priv var _slots:     cxx::std::vector<Slot>
    priv var _arm_ix:    unsafe *VariableDecl                   = &null
    priv var _cont:      unsafe *VariableDecl                   = &null
    priv var _fail:      Token
    priv var _fail_used: bool                                   = false
    /// A jump to the fail block from a test that is not an ADT tag's: the
    /// block then takes the general policy, not the ADT one (_policy).
    priv var _fail_general: bool  = false
    priv var _adt_ctx:      bool  = false ///< the test now rendering is over a variant-only enum (_holds_only_variants).
    priv var _end:          Token
    priv var _buckets:      usize = 0
    priv var _qi:           usize = 0 ///< next queued node to emit.

    fn MatchLowering(self, sc: unsafe *SemaContext) {
        self.sc     = sc
        self.ctx    = sc->ctx
        self.tu     = TypeUtil(sc)
        self.ps     = PatternSpace(sc)
        self.synth  = LowerSynth(sc)
        self.layout = EnumLayoutQuery(sc)
        self.ops    = OperatorLowering(sc)
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked)
        self.sc->begin_lower(LowerStep::Match)
        if self.sc->tu == &null {
            return
        }

        ASTWriter<MatchLowering>::run(self, self.sc->tu)
    }

    /// # entry points

    /// Labels are function-scoped, so the match number restarts per function.
    fn transform_function_decl(self, n: unsafe *FunctionDecl) -> cxx::std::vector<unsafe *Decl> {
        var saved = self._fn_matches
        self._fn_matches = 0
        var out = ASTWriter<MatchLowering>::transform_function_decl(self, n)
        self._fn_matches = saved
        return out
    }

    fn transform_match_stmt(self, n: unsafe *MatchStmt) -> cxx::std::vector<unsafe *Stmt> {
        ASTWriter<MatchLowering>::transform_match_stmt(self, n) // inner matches, guards, bodies first.
        var unsafe *out = self._lower(
            n->scrutinee,
            unsafe &n->cases,
            n->decision,
            n->range,
            false,
            &null,
        )

        if out == &null {
            return self._one_stmt(n)
        }

        return self._one_stmt(out)
    }

    fn transform_match_expr(self, n: unsafe *MatchExpr) -> unsafe *Expr {
        ASTWriter<MatchLowering>::transform_match_expr(self, n)
        var unsafe *out = self._lower(
            n->scrutinee,
            unsafe &n->cases,
            n->decision,
            n->range,
            true,
            n->type_,
        )

        if out == &null {
            return n
        }

        var unsafe *se = cast<StmtExpr>(
            cast<ExpressionStmt>(cast<CompoundStmt>(out)->body[0])->expr,
        )

        se->adopt_sema(n)
        se->type_          = n->type_
        se->value_category = Expr::ValueCategory::RValue
        return se
    }

    /// A value-form match whose value is discarded is the statement form:
    /// no arm index, no ternary.
    fn transform_expression_stmt(self,
                                 n: unsafe *ExpressionStmt) -> cxx::std::vector<unsafe *Stmt> {
        var unsafe *m = dyn_cast<MatchExpr>(self.tu.strip_parens(n->expr))
        if m == &null {
            return ASTWriter<MatchLowering>::transform_expression_stmt(self, n)
        }

        ASTWriter<MatchLowering>::transform_match_expr(self, m)
        var unsafe *out = self._lower(
            m->scrutinee,
            unsafe &m->cases,
            m->decision,
            m->range,
            false,
            &null,
        )

        if out == &null {
            return self._one_stmt(n)
        }

        return self._one_stmt(unsafe (out as unsafe *Stmt))
    }

    /// # one match

    /// The lowered block (statement form), or a block holding one
    /// ExpressionStmt of the StmtExpr (value form); null leaves the match.
    priv fn _lower(self,
                   scrutinee: unsafe *Expr,
                   cases:     unsafe *FrozenList<MatchCase>,
                   decision:  unsafe *void,
                   at:        SourceRange,
                   value:     bool,
                   ty:        unsafe *Type) -> unsafe *CompoundStmt {
        if decision == &null {
            return &null
        }

        self._t     = unsafe (decision as unsafe *DecisionTree)
        self._cases = cases
        self._at    = at
        self._value = value
        self._ty    = ty
        self._n     = self._fn_matches
        self._reset()

        var pre = cxx::std::vector<unsafe *Stmt>()
        self._bind_scrutinee(scrutinee, 0, unsafe &pre)
        if !self._renderable() {
            return &null
        }

        self._fn_matches += 1

        self._plan_arms()
        if self._value {
            var unsafe *short_ = self._short_value()
            if short_ != &null {
                return self._wrap_value(pre, short_, &null)
            }
        }

        self._declare_state(&pre)

        var code = cxx::std::vector<unsafe *Stmt>()
        var root = self._t->nodes[self._t->root as usize]
        var skip_root = !self._value
            && root.kind == DKind::Leaf
            && !self._arms[root.arm as usize].slots
        if !skip_root {
            self._node(self._t->root, unsafe &code)
        }

        self._drain(unsafe &code)
        self._shared_guards(unsafe &code)
        if self._fail_used {
            code.push_back(self._label_stmt(self._fail))
            code.push_back(self._policy(!self._fail_general))
        }

        if self._value {
            if self._t->nodes.size() == 0 {
                kairo::std::ice_fail("MatchLowering: empty decision tree")
            }

            code.push_back(self._label_stmt(self._end))
            return self._wrap_value(pre, self._ternary(), unsafe &code)
        }

        // Arms, in source order; the last one falls into the end label.
        var last: i32 = -1
        for var k: usize = 0; k < self._arms.size(); ++k {
            if self._arms[k].reached {
                last = (k as i32)
            }
        }

        var end_used = false
        for var k: usize = 0; k < self._arms.size(); ++k {
            if !self._arms[k].reached {
                continue
            }

            if self._arms[k].used {
                code.push_back(self._label_stmt(self._arms[k].label))
            }

            code.push_back(unsafe (self._arm_block(k as u32) as unsafe *Stmt))
            if (k as i32) != last {
                code.push_back(self._jump(self._end))
                end_used = true
            }
        }

        if end_used {
            code.push_back(self._label_stmt(self._end))
        }

        var all = cxx::std::vector<unsafe *Stmt>()
        for var i: usize = 0; i < pre.size(); ++i {
            all.push_back(pre[i])
        }

        for var i: usize = 0; i < code.size(); ++i {
            all.push_back(code[i])
        }

        return self._block(&all)
    }

    priv fn _reset(self) {
        var nn = self._t->nodes.size()
        self._columns = 0
        self._locals  = cxx::std::vector<unsafe *VariableDecl>()
        for var i: usize = 0; i < self._t->occs.size(); ++i {
            self._locals.push_back(&null)
        }

        self._labels = cxx::std::vector<Token>()
        self._queued = cxx::std::vector<u8>()
        for var i: usize = 0; i < nn; ++i {
            self._labels.push_back(
                self._name(LowerTargets::match_node(self._n, i)),
            )

            self._queued.push_back(0)
        }

        self._queue = cxx::std::vector<u32>()
        self._arms  = cxx::std::vector<ArmPlan>()
        for var k: usize = 0; k < self._cases->size(); ++k {
            var a = ArmPlan{}
            a.label  = self._name(LowerTargets::match_arm(self._n, k))
            a.glabel = self._name(LowerTargets::match_guard(self._n, k))
            self._arms.push_back(a)
        }

        self._slots        = cxx::std::vector<Slot>()
        self._arm_ix       = &null
        self._cont         = &null
        self._fail         = self._name(LowerTargets::match_fail(self._n))
        self._fail_used    = false
        self._fail_general = false
        self._adt_ctx      = false
        self._end          = self._name(LowerTargets::match_end(self._n))
        self._buckets      = 0
        self._qi           = 0
    }

    /// # the scrutinee

    /// Bind \p e0 once. A tuple literal binds each element instead, in order;
    /// an element no pattern reaches is still evaluated.
    priv fn _bind_scrutinee(self,
                            e0:  unsafe *Expr,
                            occ: i32,
                            pre: unsafe *cxx::std::vector<unsafe *Stmt>) {
        var unsafe *e  = self.tu.strip_parens(e0)
        var unsafe *tl = dyn_cast<TupleLiteralExpr>(e)
        if tl != &null {
            // PatternCompilation opened element i as the record's field
            // `_i` (a tuple is its arity's record); the element's own local
            // stands in for that occurrence.
            var unsafe *tt = canon_unqual(self._referee(tl->type_))
            for var i: usize = 0; i < tl->elements.size(); ++i {
                var child: i32 = -1
                if occ >= 0 {
                    child = self._find_occ_field(
                        occ as u32,
                        self.tu.tuple_field(tt, i),
                    )
                }

                self._bind_scrutinee(tl->elements[i], child, pre)
            }

            return
        }

        var name = LowerTargets::match_scrutinee(self._n)
        if occ != 0 || self._columns > 0 {
            name = LowerTargets::match_column(self._n, self._columns)
        }

        self._columns += 1

        var unsafe *vt = canon_unqual(self._referee(e->type_))
        var unsafe *lt = vt
        if self._is_class(vt) && e->is_lvalue() {
            lt = self.sc->types->cxx_lref(
                self.sc->types->qualified(vt, QUAL_CONST),
            )
        }

        var unsafe *vd = VariableDecl::create(
            self.ctx,
            self._at,
            self._name(name),
            StorageClass::Var,
        )

        vd->type_ = lt
        vd->init  = e
        pre->push_back(
            unsafe (DeclStmt::create(self.ctx, self._at, unsafe (vd as unsafe *Decl)) as unsafe *Stmt),
        )

        if occ >= 0 {
            self._locals[occ as usize] = vd
        }
    }

    /// The Field occurrence of \p f under \p parent, or -1 when no pattern
    /// reached it (its element is still evaluated, into a local nothing reads).
    priv fn _find_occ_field(self, parent: u32, f: unsafe *FieldDecl) -> i32 {
        if f == &null {
            return -1
        }

        for var i: usize = 0; i < self._t->occs.size(); ++i {
            var o = self._t->occs[i]
            if o.parent == (parent as i32) && o.kind == OccKind::Field && o.field == f {
                return i as i32
            }
        }

        return -1
    }

    priv fn _find_occ(self, parent: u32, kind: OccKind, index: u32) -> i32 {
        for var i: usize = 0; i < self._t->occs.size(); ++i {
            var o = self._t->occs[i]
            if o.parent == (parent as i32) && o.kind == kind && o.index == index {
                return i as i32
            }
        }

        return -1
    }

    /// A class value is bound by reference; a scalar or a plain enum is copied.
    priv fn _is_class(self, t: unsafe *Type) -> bool {
        if t == &null || !isa<RecordType>(t) {
            return false
        }

        var unsafe *en = dyn_cast<EnumDecl>(
            self.tu.pattern_of(cast<RecordType>(t)->decl),
        )

        if en != &null {
            return en->is_adt
        }

        return true
    }

    priv fn _referee(self, t: unsafe *Type) -> unsafe *Type {
        if t != &null && isa<CXXLValueRefType>(t) {
            return cast<CXXLValueRefType>(t)->referee
        }

        if t != &null && isa<CXXRValueRefType>(t) {
            return cast<CXXRValueRefType>(t)->referee
        }

        return t
    }

    /// # what can be rendered

    /// Every occurrence the tree reads has a C++ path, and every enum it
    /// tests by tag has its record. See the file header.
    priv fn _renderable(self) -> bool {
        var unsafe *t = self._t
        for var i: usize = 0; i < t->nodes.size(); ++i {
            var n = t->nodes[i]
            if n.kind == DKind::Switch || n.kind == DKind::Test {
                if !self._occ_ok(n.occ) {
                    return false
                }

                for var k: u32 = 0; k < n.nedge; ++k {
                    var e = t->edges[(n.edge0 + k) as usize]
                    if e.kind == CtorKind::Variant && !self._tag_ok(n.occ) {
                        return false
                    }
                }
            }

            if n.kind == DKind::Leaf || n.kind == DKind::Guard {
                for var k: u32 = 0; k < n.nbind; ++k {
                    if !self._occ_ok(t->binds[(n.bind0 + k) as usize].occ) {
                        return false
                    }
                }
            }
        }

        return true
    }

    priv fn _occ_ok(self, o: u32) -> bool {
        if self._locals[o as usize] != &null {
            return true
        }

        var d = self._t->occs[o as usize]
        match d.kind {
            case OccKind::Field {
                return self._occ_ok(d.parent as u32)
            } case OccKind::Payload {
                if !self._occ_ok(d.parent as u32) {
                    return false
                }

                return self.layout.has_payload(
                    self._enum_at(d.parent as u32),
                    d.index,
                )
            } default { // the root of a tuple literal: never bound, its elements are.
                return false
            }
        }
    }

    priv fn _tag_ok(self, o: u32) -> bool {
        var unsafe *en = self._enum_at(o)
        if en == &null {
            return false
        }

        if !en->is_adt {
            return true
        }

        return self.layout.has_layout(en)
    }

    /// No value of \p en is outside its variants: an ADT (no cast writes a
    /// tag) or a closed plain enum (`as` into it is checked, CastTyping). An
    /// `@open` enum, and every imported one, may hold any value of its
    /// underlying type, so its complete match keeps UnmatchedPolicy.
    priv fn _holds_only_variants(self, en: unsafe *EnumDecl) -> bool {
        if en == &null {
            return false
        }

        return en->is_adt || !en->is_open
    }

    priv fn _enum_at(self, o: u32) -> unsafe *EnumDecl {
        return self.ps.domain_of(self._occ_type(o)).en
    }

    priv fn _variant_of(self, o: u32, index: u32) -> unsafe *EnumVariantDecl {
        var unsafe *en = self._enum_at(o)
        return adt_variant_at(en, index as usize) // \p index is expanded (EnumLayoutQuery).
    }

    /// # arms

    /// Which arms are reached, which read their binders through slots, and
    /// which guards more than one path shares.
    priv fn _plan_arms(self) {
        var unsafe *t = self._t
        for var i: usize = 0; i < t->nodes.size(); ++i {
            var n = t->nodes[i]
            if n.kind != DKind::Leaf && n.kind != DKind::Guard {
                continue
            }

            var *a = &self._arms[n.arm as usize]
            a->reached = true
            if n.kind == DKind::Guard {
                a->guards.push_back(i as u32)
            }

            if a->rep < 0 {
                a->rep = (i as i32)
                continue
            }

            if !self._same_binds(a->rep as u32, (i as u32)) {
                a->slots = true
            }
        }
    }

    priv fn _same_binds(self, a: u32, b: u32) -> bool {
        var na = self._t->nodes[a as usize]
        var nb = self._t->nodes[b as usize]
        if na.nbind != nb.nbind {
            return false
        }

        for var i: u32 = 0; i < na.nbind; ++i {
            var x     = self._t->binds[(na.bind0 + i) as usize]
            var found = false
            for var j: u32 = 0; j < nb.nbind; ++j {
                var y = self._t->binds[(nb.bind0 + j) as usize]
                if x.pat->decl == y.pat->decl && x.occ == y.occ {
                    found = true
                    break
                }
            }

            if !found {
                return false
            }
        }

        return true
    }

    /// Slots, the arm index and the guard continuation: declared before the
    /// first goto, all trivially constructible.
    priv fn _declare_state(self, @inout pre: cxx::std::vector<unsafe *Stmt>) {
        var any_shared = false
        for var k: usize = 0; k < self._arms.size(); ++k {
            var *a = &self._arms[k]
            if a->guards.size() > 1 {
                any_shared = true
            }

            if !a->reached || !a->slots {
                continue
            }

            var rep = self._t->nodes[a->rep as usize]
            for var i: u32 = 0; i < rep.nbind; ++i {
                var        b   = self._t->binds[(rep.bind0 + i) as usize]
                var unsafe *vd = cast<VariableDecl>(b.pat->decl)
                var        s   = Slot{}
                s.arm  = (k as u32)
                s.decl = vd
                s.var_ = VariableDecl::create(
                    self.ctx,
                    self._at,
                    self._name(
                        LowerTargets::match_slot(self._n, self._slots.size()),
                    ),
                    StorageClass::Var,
                )

                s.var_->type_ = self.sc->types->pointer(
                    self.sc->types->qualified(self._binder_type(vd), QUAL_CONST),
                )

                s.var_->init = &null
                pre.push_back(
                    unsafe (DeclStmt::create(self.ctx, self._at, unsafe (s.var_ as unsafe *Decl)) as unsafe *Stmt),
                )

                self._slots.push_back(s)
            }
        }

        if self._value {
            self._arm_ix = VariableDecl::create(
                self.ctx,
                self._at,
                self._name(LowerTargets::match_arm_index(self._n)),
                StorageClass::Var,
            )

            self._arm_ix->type_ = self._u32()
            self._arm_ix->init  = &null
            pre.push_back(
                unsafe (DeclStmt::create(self.ctx, self._at, unsafe (self._arm_ix as unsafe *Decl)) as unsafe *Stmt),
            )
        }

        if any_shared {
            self._cont = VariableDecl::create(
                self.ctx,
                self._at,
                self._name(LowerTargets::match_cont(self._n)),
                StorageClass::Var,
            )

            self._cont->type_ = self._u32()
            self._cont->init  = &null
            pre.push_back(
                unsafe (DeclStmt::create(self.ctx, self._at, unsafe (self._cont as unsafe *Decl)) as unsafe *Stmt),
            )
        }
    }

    /// A binder's value type: what X typed it, before this pass makes a
    /// `const` binder a reference.
    priv fn _binder_type(self, vd: unsafe *VariableDecl) -> unsafe *Type {
        return canon_unqual(self._referee(vd->type_))
    }

    /// The statements that point \p arm's slots at node \p i's occurrences.
    priv fn _set_slots(self, arm: u32, i: u32, @inout out: cxx::std::vector<unsafe *Stmt>) {
        if !self._arms[arm as usize].slots {
            return
        }

        var n = self._t->nodes[i as usize]
        for var k: u32 = 0; k < n.nbind; ++k {
            var        b  = self._t->binds[(n.bind0 + k) as usize]
            var unsafe *s = self._slot(arm, cast<VariableDecl>(b.pat->decl))
            out.push_back(
                self._expr_stmt(
                    self._assign(
                        self.synth.use_of(
                            s,
                            self._at,
                            Expr::ValueCategory::LValue,
                        ),
                        self.synth.addr_of(self._occ(b.occ)),
                    ),
                ),
            )
        }
    }

    priv fn _slot(self, arm: u32, vd: unsafe *VariableDecl) -> unsafe *VariableDecl {
        for var i: usize = 0; i < self._slots.size(); ++i {
            if self._slots[i].arm == arm && self._slots[i].decl == vd {
                return self._slots[i].var_
            }
        }

        kairo::std::ice_fail(
            "MatchLowering: a binder with no slot; alternatives must bind the same names (PatternBindingCheck)",
        )
    }

    /// \p vd's initializer for arm \p arm: its occurrence on the
    /// representative path, or through its slot.
    priv fn _binder_init(self, arm: u32, vd: unsafe *VariableDecl) -> unsafe *Expr {
        var *a = &self._arms[arm as usize]
        if a->slots {
            var unsafe *s = self._slot(arm, vd)
            return self._deref(
                self.synth.use_of(s, self._at, Expr::ValueCategory::LValue),
                self._binder_type(vd),
            )
        }

        var rep = self._t->nodes[a->rep as usize]
        for var k: u32 = 0; k < rep.nbind; ++k {
            var b = self._t->binds[(rep.bind0 + k) as usize]
            if b.pat->decl == vd {
                return self._occ(b.occ)
            }
        }

        kairo::std::ice_fail(
            "MatchLowering: a binder its representative path does not bind",
        )
    }

    /// The arm's binder declarations, in the mode each was written with.
    priv fn _arm_binders(self, arm: u32, @inout out: cxx::std::vector<unsafe *Stmt>) {
        var *a  = &self._arms[arm as usize]
        var rep = self._t->nodes[a->rep as usize]
        for var k: u32 = 0; k < rep.nbind; ++k {
            var        b   = self._t->binds[(rep.bind0 + k) as usize]
            var unsafe *vd = cast<VariableDecl>(b.pat->decl)
            var unsafe *vt = self._binder_type(vd)
            vd->init = self._binder_init(arm, vd)
            if b.pat->is_const {
                vd->type_ = self.sc->types->cxx_lref(
                    self.sc->types->qualified(vt, QUAL_CONST),
                )

                vd->storage = StorageClass::Var // the `const` is in the type; a keyword too would be `const const`.
            } else {
                vd->type_ = vt
            }

            out.push_back(
                unsafe (DeclStmt::create(self.ctx, b.pat->range, unsafe (vd as unsafe *Decl)) as unsafe *Stmt),
            )
        }
    }

    /// The guard's own binders: `const T& x = <occurrence>`, never the
    /// arm's decls, which are declared in the arm block in their own mode.
    priv fn _guard_binders(self, arm: u32, @inout out: cxx::std::vector<unsafe *Stmt>) {
        var *a  = &self._arms[arm as usize]
        var rep = self._t->nodes[a->rep as usize]
        for var k: u32 = 0; k < rep.nbind; ++k {
            var        b   = self._t->binds[(rep.bind0 + k) as usize]
            var unsafe *vd = cast<VariableDecl>(b.pat->decl)
            var unsafe *g = VariableDecl::create(
                self.ctx,
                b.pat->range,
                vd->name,
                StorageClass::Var,
            )

            g->type_ = self.sc->types->cxx_lref(
                self.sc->types->qualified(self._binder_type(vd), QUAL_CONST),
            )

            g->init = self._binder_init(arm, vd)
            out.push_back(
                unsafe (DeclStmt::create(self.ctx, b.pat->range, unsafe (g as unsafe *Decl)) as unsafe *Stmt),
            )
        }
    }

    /// Statement form: `{ binders; body }`.
    priv fn _arm_block(self, arm: u32) -> unsafe *CompoundStmt {
        var unsafe *mc = self._cases->get(arm as usize)
        var        out = cxx::std::vector<unsafe *Stmt>()
        self._arm_binders(arm, &out)
        if mc->body != &null {
            for var i: usize = 0; i < mc->body->body.size(); ++i {
                out.push_back(mc->body->body[i])
            }
        } else if mc->expression != &null {
            out.push_back(self._expr_stmt(mc->expression))
        }

        return self._block(&out)
    }

    /// Value form: the arm's value, `({ binders; (e); })` when it binds.
    priv fn _arm_value(self, arm: u32) -> unsafe *Expr {
        var unsafe *mc = self._cases->get(arm as usize)
        if mc->expression == &null {
            kairo::std::ice_fail(
                "MatchLowering: a value-form arm with no expression",
            )
        }

        var stmts = cxx::std::vector<unsafe *Stmt>()
        self._arm_binders(arm, &stmts)
        var unsafe *e = self._moved_tail(arm, mc->expression)
        if stmts.size() == 0 {
            return e
        }

        stmts.push_back(self._expr_stmt(self._paren(e)))
        var lb = self.list_builder<unsafe *Stmt>()
        for var i: usize = 0; i < stmts.size(); ++i {
            lb.push(stmts[i])
        }

        return self.synth.stmt_expr(mc->expression, &lb, mc->expression->type_)
    }

    /// `case .Error(var m) => m`: the binder copied the payload, so the
    /// value moves out of the binder instead of copying it again.
    priv fn _moved_tail(self, arm: u32, e: unsafe *Expr) -> unsafe *Expr {
        var unsafe *s = dyn_cast<NamedIdentExpr>(self.tu.strip_parens(e))
        if s == &null {
            return e
        }

        var *a  = &self._arms[arm as usize]
        var rep = self._t->nodes[a->rep as usize]
        for var k: u32 = 0; k < rep.nbind; ++k {
            var b = self._t->binds[(rep.bind0 + k) as usize]
            if b.pat->decl != s->resolved_decl || b.pat->is_const {
                continue
            }

            var unsafe *vt = self._binder_type(cast<VariableDecl>(b.pat->decl))
            if !self._is_class(vt) {
                return e
            }

            return self.synth.cast_to(
                e->range,
                e,
                self.sc->types->cxx_rref(vt),
                CastMode::Default,
            )
        }

        return e
    }

    /// # value form

    /// One leaf: the arm itself. One test between two leaves: a ternary.
    /// Null when neither applies.
    priv fn _short_value(self) -> unsafe *Expr {
        var unsafe *t   = self._t
        var        root = t->nodes[t->root as usize]
        if root.kind == DKind::Leaf {
            if self._arms[root.arm as usize].slots {
                return &null
            }

            return self._arm_value(root.arm)
        }

        var cond: unsafe *Expr = &null
        var yes:  i32          = -1
        var no:   i32          = -1
        if root.kind == DKind::Test {
            var e = t->edges[root.edge0 as usize]
            yes = (e.child as i32)
            no  = root.other
            if !(self._plain_leaf(yes) && self._plain_leaf(no)) {
                return &null
            }

            cond = self._cond(root.occ, e)
        } else if root.kind == DKind::Switch {
            if root.strings {
                return &null
            }

            if root.nedge == 2
                && root.other < 0
                && t->edges[root.edge0 as usize].kind == CtorKind::Bool {
                var e0 = t->edges[root.edge0 as usize]
                var e1 = t->edges[(root.edge0 + 1) as usize]
                yes = if (e0.lo == (1 as u64)) => (e0.child as i32) else => (e1.child as i32)
                no  = if (e0.lo == (1 as u64)) => (e1.child as i32) else => (e0.child as i32)
                if !(self._plain_leaf(yes) && self._plain_leaf(no)) {
                    return &null
                }

                cond = self._occ(root.occ)
            } else if root.nedge == 1 && root.other >= 0 {
                var e = t->edges[root.edge0 as usize]
                yes = (e.child as i32)
                no  = root.other
                if !(self._plain_leaf(yes) && self._plain_leaf(no)) {
                    return &null
                }

                cond = self._cond(root.occ, e)
            } else {
                return &null
            }
        } else {
            return &null
        }

        var ay = t->nodes[yes as usize].arm
        var an = t->nodes[no as usize].arm
        if ay == an {
            return &null
        }

        var unsafe *ie = IfExpr::create(
            self.ctx,
            self._at,
            cond,
            self._arm_value(ay),
            self._arm_value(an),
        )

        ie->type_          = self._ty
        ie->value_category = Expr::ValueCategory::RValue
        return ie
    }

    /// A Leaf whose arm reads its binders directly.
    priv fn _plain_leaf(self, i: i32) -> bool {
        if i < 0 {
            return false
        }

        var n = self._t->nodes[i as usize]
        return n.kind == DKind::Leaf && !self._arms[n.arm as usize].slots
    }

    /// `arm == 0 ? A0 : arm == 1 ? A1 : ... : AL` over the reached arms.
    priv fn _ternary(self) -> unsafe *Expr {
        var reached = cxx::std::vector<u32>()
        for var k: usize = 0; k < self._arms.size(); ++k {
            if self._arms[k].reached {
                reached.push_back(k as u32)
            }
        }

        if reached.size() == 0 {
            kairo::std::ice_fail(
                "MatchLowering: a value-form match no arm of which is reached",
            )
        }

        if reached.size() == 1 {
            return self._arm_value(reached[0])
        }

        var unsafe *ie = IfExpr::create(
            self.ctx,
            self._at,
            self._is_arm(reached[0]),
            self._arm_value(reached[0]),
            self._arm_value(reached[reached.size() - 1]),
        )

        var elifs = self.list_builder<IfExpr::ElseIf>()
        for var i: usize = 1; i + 1 < reached.size(); ++i {
            var ei = IfExpr::ElseIf{}
            ei.condition = self._is_arm(reached[i])
            ei.body      = self._arm_value(reached[i])
            ei.range     = self._at
            elifs.push(ei)
        }

        elifs.freeze_into(&ie->else_ifs)
        ie->type_          = self._ty
        ie->value_category = Expr::ValueCategory::RValue
        return ie
    }

    priv fn _is_arm(self, k: u32) -> unsafe *Expr {
        return self._eq(
            self.synth.use_of(
                self._arm_ix,
                self._at,
                Expr::ValueCategory::LValue,
            ),
            self.synth.int_literal(self._at, k, BuiltinKind::U32),
        )
    }

    /// `({ pre; code; (value); })` as a block holding its one statement,
    /// the shape _lower returns.
    priv fn _wrap_value(self,
                        const pre: cxx::std::vector<unsafe *Stmt>,
                        value:     unsafe *Expr,
                        code:      unsafe *cxx::std::vector<unsafe *Stmt>) -> unsafe *CompoundStmt {
        var lb = self.list_builder<unsafe *Stmt>()
        for var i: usize = 0; i < pre.size(); ++i {
            lb.push((pre)[i])
        }

        if code != &null {
            for var i: usize = 0;
            i < code->size();
            ++i {
                lb.push((*code)[i])
            }
        }

        lb.push(self._expr_stmt(self._paren(value)))
        var unsafe *body = CompoundStmt::create(self.ctx, self._at)
        lb.freeze_into(&body->body)
        var unsafe *se = StmtExpr::create(self.ctx, self._at, body)
        se->type_          = self._ty
        se->value_category = Expr::ValueCategory::RValue
        var one = cxx::std::vector<unsafe *Stmt>()
        one.push_back(self._expr_stmt(se))
        return self._block(&one)
    }

    /// # nodes

    /// Node \p i's code. Every path through it ends in a goto (or the
    /// noreturn policy call), so the order nodes are emitted in is free.
    priv fn _node(self, i: u32, out: unsafe *cxx::std::vector<unsafe *Stmt>) {
        var n = self._t->nodes[i as usize]
        match n.kind {
            case DKind::Fail {
                out->push_back(self._policy(false))
            } case DKind::Leaf {
                self._accept(n.arm, i, out)
            } case DKind::Guard {
                self._guard(i, out)
            } case DKind::Test {
                var e = self._t->edges[n.edge0 as usize]
                self._if_goto(self._cond(n.occ, e), e.child as i32, &*out)
                self._adt_ctx = e.kind == CtorKind::Variant
                    && self._holds_only_variants(self._enum_at(n.occ))
                out->push_back(self._jump(self._target(n.other)))
                self._adt_ctx = false
            } case DKind::Switch {
                self._switch(i, out)
            }
        }
    }

    /// Taking arm \p arm from node \p i: point the slots, then jump to the
    /// arm (statement form) or record it and jump to the join (value form).
    priv fn _accept(self, arm: u32, i: u32, out: unsafe *cxx::std::vector<unsafe *Stmt>) {
        self._set_slots(arm, i, &*out)
        if self._value {
            out->push_back(
                self._expr_stmt(
                    self._assign(
                        self.synth.use_of(
                            self._arm_ix,
                            self._at,
                            Expr::ValueCategory::LValue,
                        ),
                        self.synth.int_literal(self._at, arm, BuiltinKind::U32),
                    ),
                ),
            )

            out->push_back(self._jump(self._end))
            return
        }

        self._arms[arm as usize].used = true
        out->push_back(self._jump(self._arms[arm as usize].label))
    }

    /// A guard reached on one path is emitted where it is reached. One
    /// reached on several is a shared block (_shared_guards); each path
    /// points the slots, records which path it is, and jumps there.
    priv fn _guard(self, i: u32, out: unsafe *cxx::std::vector<unsafe *Stmt>) {
        var n  = self._t->nodes[i as usize]
        var *a = &self._arms[n.arm as usize]
        if a->guards.size() > 1 {
            self._set_slots(n.arm, i, &*out)
            var j: usize = 0
            while a->guards[j] != i {
                j += 1
            }

            out->push_back(
                self._expr_stmt(
                    self._assign(
                        self.synth.use_of(
                            self._cont,
                            self._at,
                            Expr::ValueCategory::LValue,
                        ),
                        self.synth.int_literal(
                            self._at,
                            j as u64,
                            BuiltinKind::U32,
                        ),
                    ),
                ),
            )

            out->push_back(self._jump(a->glabel))
            return
        }

        self._set_slots(n.arm, i, &*out)
        out->push_back(self._guard_block(n.arm))
        out->push_back(self._jump(self._target(n.other)))
    }

    /// `{ const T& x = ...; if (guard) { <accept> } }`
    priv fn _guard_block(self, arm: u32) -> unsafe *CompoundStmt {
        var unsafe *mc   = self._cases->get(arm as usize)
        var        inner = cxx::std::vector<unsafe *Stmt>()
        self._guard_binders(arm, &inner)
        var take = cxx::std::vector<unsafe *Stmt>()
        if self._value {
            take.push_back(
                self._expr_stmt(
                    self._assign(
                        self.synth.use_of(
                            self._arm_ix,
                            self._at,
                            Expr::ValueCategory::LValue,
                        ),
                        self.synth.int_literal(self._at, arm, BuiltinKind::U32),
                    ),
                ),
            )

            take.push_back(self._jump(self._end))
        } else {
            self._arms[arm as usize].used = true
            take.push_back(self._jump(self._arms[arm as usize].label))
        }

        inner.push_back(
            ConditionalStmt::create(
                self.ctx,
                mc->guard->range,
                mc->guard,
                self._block(&take),
                &null,
            ),
        )

        return self._block(&inner)
    }

    /// The blocks of guards reached on several paths: the guard once, then
    /// a dispatch on the continuation to the failing path's next node.
    priv fn _shared_guards(self, out: unsafe *cxx::std::vector<unsafe *Stmt>) {
        for var k: usize = 0; k < self._arms.size(); ++k {
            var unsafe *a = unsafe &self._arms[k]
            if a->guards.size() < 2 {
                continue
            }

            out->push_back(self._label_stmt(a->glabel))
            out->push_back(unsafe (self._guard_block(k as u32) as unsafe *Stmt))
            var cases = cxx::std::vector<DispatchCase>()
            for var j: usize = 0; j + 1 < a->guards.size(); ++j {
                var c = DispatchCase{}
                c.lo = self.synth.int_literal(
                    self._at,
                    j as u64,
                    BuiltinKind::U32,
                )

                c.hi = &null
                c.target = self._target(
                    self._t->nodes[a->guards[j] as usize].other,
                )

                cases.push_back(c)
            }

            var last = self._t->nodes[a->guards[a->guards.size() - 1] as usize].other
            out->push_back(
                self._dispatch(
                    self.synth.use_of(
                        self._cont,
                        self._at,
                        Expr::ValueCategory::LValue,
                    ),
                    cases,
                    last,
                    false,
                ),
            )
        }

        self._drain(out) // their failures may reach nodes nothing else did.
    }

    /// Emit every queued node not yet emitted, each under its label. A
    /// node's code can queue more; the loop takes them too.
    priv fn _drain(self, out: unsafe *cxx::std::vector<unsafe *Stmt>) {
        while self._qi < self._queue.size() {
            var k = self._queue[self._qi]
            self._qi += 1
            out->push_back(self._label_stmt(self._labels[k as usize]))
            self._node(k, out)
        }
    }

    /// # switches

    priv fn _switch(self, i: u32, out: unsafe *cxx::std::vector<unsafe *Stmt>) {
        var n = self._t->nodes[i as usize]
        if n.strings {
            self._switch_strings(n, out)
            return
        }

        var d = self.ps.domain_of(self._occ_type(n.occ))

        if d.kind == DomainKind::Bool {
            var yes = n.other
            var no  = n.other
            for var k: u32 = 0; k < n.nedge; ++k {
                var e = self._t->edges[(n.edge0 + k) as usize]
                if e.lo == (1 as u64) {
                    yes = (e.child as i32)
                } else {
                    no = (e.child as i32)
                }
            }

            self._if_goto(self._occ(n.occ), yes, &*out)
            out->push_back(self._jump(self._target(no)))
            return
        }

        var value: unsafe *Expr = &null
        if d.kind == DomainKind::ClosedEnum {
            value = self._enum_value(n.occ, d.en)
            if value == &null {
                self._chain(n, out)
                return
            }
        } else if d.kind == DomainKind::Int {
            value = self._occ(n.occ)
        } else {
            kairo::std::ice_fail(
                "MatchLowering: a switch over a domain PatternCompilation never switches on",
            )
        }

        var cases = cxx::std::vector<DispatchCase>()
        var count = n.nedge
        var other = n.other
        // A complete integer switch has no default of its own: the last
        // edge takes it. A complete enum's default is UnmatchedPolicy.
        if other < 0 && d.kind == DomainKind::Int && count > 0 {
            other = (self._t->edges[(n.edge0 + count - 1) as usize].child as i32)
            count = count - 1
        }

        for var k: u32 = 0; k < count; ++k {
            var e = self._t->edges[(n.edge0 + k) as usize]
            var c = DispatchCase{}
            c.target = self._target(e.child as i32)
            if d.kind == DomainKind::ClosedEnum {
                c.lo = self._enum_case(d.en, e.index, self._occ_type(n.occ))
                c.hi = &null
            } else {
                var unsafe *t = self._occ_type(n.occ)
                c.lo = self._int_value(d, e.lo, t)
                c.hi = if (e.lo == e.hi) => (&null) else => self._int_value(d, e.hi, t)
            }

            cases.push_back(c)
        }

        out->push_back(
            self._dispatch(
                value,
                cases,
                other,
                d.kind == DomainKind::ClosedEnum && self._holds_only_variants(d.en),
            ),
        )
    }

    /// An ADT with no tag to switch on (niche-filled; EnumLayoutQuery): an
    /// `if` per variant, from variant_test, in edge order. When nothing but
    /// the policy follows the last edge, the last edge is taken untested --
    /// it is the only variant left -- which is the switch's unreachable
    /// default spelled as control flow.
    priv fn _chain(self, n: DNode, out: unsafe *cxx::std::vector<unsafe *Stmt>) {
        var        count    = n.nedge
        var        other    = n.other
        var        open_end = other < 0 || self._t->nodes[other as usize].kind == DKind::Fail
        var unsafe *en      = self._enum_at(n.occ)
        for var k: u32 = 0; k < count; ++k {
            var e = self._t->edges[(n.edge0 + k) as usize]
            if k + 1 == count
                && open_end
                && self.sc->opts.adt_unmatched == UnmatchedPolicy::Unreachable {
                out->push_back(self._jump(self._target(e.child as i32)))
                return
            }

            self._if_goto(
                self.layout.variant_test(
                    self._at,
                    self._occ(n.occ),
                    en,
                    e.index,
                ),
                e.child as i32,
                &*out,
            )
        }

        if open_end {
            out->push_back(self._policy(true))
            return
        }

        out->push_back(self._jump(self._target(other)))
    }

    /// The switch operand for an enum: the value itself, or for an ADT the
    /// word its layout dispatches on (EnumLayoutQuery::tag_word); null for
    /// an ADT with no tag (_chain).
    priv fn _enum_value(self, occ: u32, en: unsafe *EnumDecl) -> unsafe *Expr {
        if !en->is_adt {
            return self._occ(occ)
        }

        return self.layout.tag_word(self._at, self._occ(occ), en)
    }

    /// A case value: the enumerator, or for an ADT the variant's stored
    /// discriminant (EnumLayoutQuery::tag_case).
    priv fn _enum_case(self, en: unsafe *EnumDecl, index: u32, ty: unsafe *Type) -> unsafe *Expr {
        if en->is_adt {
            return self.layout.tag_case(self._at, ty, en, index)
        }

        return self._decl_ref(
            unsafe (en->variants[index as usize] as unsafe *Decl),
            ty,
        )
    }

    /// Strings: `switch (s.len)` into one bucket per length, each a run of
    /// `memcmp`s; whatever no bucket takes goes to the default.
    priv fn _switch_strings(self, n: DNode, out: unsafe *cxx::std::vector<unsafe *Stmt>) {
        var lens   = cxx::std::vector<usize>()
        var bucket = cxx::std::vector<Token>()
        for var k: u32 = 0; k < n.nedge; ++k {
            var e = self._t->edges[(n.edge0 + k) as usize]
            var b = cxx::std::vector<u8>()
            pattern_string_bytes(self.sc, e.pat, unsafe &b)
            var seen = false
            for var j: usize = 0; j < lens.size(); ++j {
                if lens[j] == b.size() {
                    seen = true
                    break
                }
            }

            if !seen {
                lens.push_back(b.size())
                bucket.push_back(
                    self._name(
                        LowerTargets::match_node(
                            self._n,
                            self._t->nodes.size() + self._buckets,
                        ),
                    ),
                )

                self._buckets += 1
            }
        }

        var cases = cxx::std::vector<DispatchCase>()
        for var j: usize = 0; j < lens.size(); ++j {
            var c = DispatchCase{}
            c.lo = self.synth.int_literal(
                self._at,
                lens[j] as u64,
                BuiltinKind::USize,
            )

            c.hi     = &null
            c.target = bucket[j]
            if lens[j] == 0 {
                // Length alone settles the empty string: no bucket, no memcmp.
                for var k: u32 = 0; k < n.nedge; ++k {
                    var e = self._t->edges[(n.edge0 + k) as usize]
                    var b = cxx::std::vector<u8>()
                    pattern_string_bytes(self.sc, e.pat, unsafe &b)
                    if b.size() == 0 {
                        c.target = self._target(e.child as i32)
                        break
                    }
                }
            }

            cases.push_back(c)
        }

        out->push_back(
            self._dispatch(
                self._string_call(
                    n.occ,
                    LangMembers::string_length(),
                    self._usize(),
                ),
                cases,
                n.other,
                false,
            ),
        )

        for var j: usize = 0; j < lens.size(); ++j {
            if lens[j] == 0 {
                continue
            }

            out->push_back(self._label_stmt(bucket[j]))
            for var k: u32 = 0; k < n.nedge; ++k {
                var e = self._t->edges[(n.edge0 + k) as usize]
                var b = cxx::std::vector<u8>()
                pattern_string_bytes(self.sc, e.pat, unsafe &b)
                if b.size() != lens[j] {
                    continue
                }

                self._if_goto(
                    self._memcmp_eq(n.occ, unsafe &b),
                    e.child as i32,
                    &*out,
                )
            }

            out->push_back(self._jump(self._target(n.other)))
        }
    }

    /// # tests

    /// The condition under which the value at \p occ takes edge \p e.
    priv fn _cond(self, occ: u32, e: DEdge) -> unsafe *Expr {
        match e.kind {
            case CtorKind::Bool {
                if e.lo == (1 as u64) {
                    return self._occ(occ)
                }

                return self._not(self._occ(occ))
            } case CtorKind::Int {
                var        d  = self.ps.domain_of(self._occ_type(occ))
                var unsafe *t = self._occ_type(occ)
                if e.lo == e.hi {
                    return self._eq(self._occ(occ), self._int_value(d, e.lo, t))
                }

                var c: unsafe *Expr = &null
                if e.lo > (0 as u64) {
                    c = self._cmp(
                        self._occ(occ),
                        self._int_value(d, e.lo, t),
                        TokenKind::OpGreaterEqual,
                    )
                }

                if e.hi < d.max_key {
                    c = self._and(
                        c,
                        self._cmp(
                            self._occ(occ),
                            self._int_value(d, e.hi, t),
                            TokenKind::OpLessEqual,
                        ),
                    )
                }

                if c == &null {
                    return self.synth.bool_literal(self._at, true)
                }

                return c
            } case CtorKind::Variant {
                var unsafe *en = self._enum_at(occ)
                if en->is_adt {
                    return self.layout.variant_test(
                        self._at,
                        self._occ(occ),
                        en,
                        e.index,
                    )
                }

                return self._eq(
                    self._enum_value(occ, en),
                    self._enum_case(en, e.index, self._occ_type(occ)),
                )
            } case CtorKind::Opaque {
                return self._opaque_cond(occ, e.pat)
            } default {
                0
            }
        }

        kairo::std::ice_fail(
            "MatchLowering: a test on a constructor with no test (tuple or record)",
        )
    }

    /// An opaque head's test, read off the pattern. Its operands are
    /// literals and constant names (X: SC126E for range bounds), leaves no
    /// later pass rewrites, so reading them on more than one path is safe.
    priv fn _opaque_cond(self, occ: u32, p: unsafe *Pattern) -> unsafe *Expr {
        var unsafe *t = self._occ_type(occ)
        if t != &null && self.tu.is_string(t) {
            var b = cxx::std::vector<u8>()
            if !pattern_string_bytes(self.sc, p, unsafe &b) {
                kairo::std::ice_fail(
                    "MatchLowering: a string head with no bytes; PatternCompilation gate failure",
                )
            }

            var unsafe *len = self._eq(
                self._string_call(
                    occ,
                    LangMembers::string_length(),
                    self._usize(),
                ),
                self.synth.int_literal(
                    self._at,
                    b.size() as u64,
                    BuiltinKind::USize,
                ),
            )

            if b.size() == 0 {
                return len
            }

            return self._and(len, self._memcmp_eq(occ, unsafe &b))
        }

        var it = self.sc->pattern_eqs.find(p as usize as u64)
        if it != self.sc->pattern_eqs.end() {
            return self._eq_test(
                occ,
                p,
                unsafe (cast<BinaryOperatorExpr>(it->second) as unsafe *BinaryOperatorExpr),
            )
        }

        match p->kind {
            case PatternKind::LiteralPattern {
                return self._eq(self._occ(occ), cast<LiteralPattern>(p)->value)
            } case PatternKind::RangePattern {
                var unsafe *r              = cast<RangePattern>(p)
                var        c: unsafe *Expr = &null
                if r->lo != &null {
                    c = self._cmp(
                        self._occ(occ),
                        r->lo,
                        TokenKind::OpGreaterEqual,
                    )
                }

                if r->hi != &null {
                    var k = if (r->is_inclusive) => (TokenKind::OpLessEqual)
                            else => TokenKind::OpLess
                    c = self._and(c, self._cmp(self._occ(occ), r->hi, k))
                }

                if c == &null {
                    return self.synth.bool_literal(self._at, true)
                }

                return c
            } case PatternKind::ConstructorPattern {
                return self._eq(
                    self._occ(occ),
                    self._decl_ref(p->resolved_decl, t),
                )
            } case PatternKind::UnresolvedConstructorPattern {
                return self._eq(
                    self._occ(occ),
                    self._decl_ref(p->resolved_decl, t),
                )
            } default {
                0
            }
        }

        kairo::std::ice_fail(
            "MatchLowering: an opaque pattern kind with no test",
        )
    }

    /// A literal or constant head on a record column: the `==` X typed for
    /// it (PatternTyping::_type_eq_test), rebuilt over this occurrence and
    /// lowered the way OperatorLowering would have, which has already run.
    /// The user `op ==` (or the `op <=>` it derives from) is the call; a
    /// plain enum's builtin `==` stays an operator node. Fresh operands on
    /// every call: a test rendered on two paths is two trees.
    priv fn _eq_test(self,
                     occ:   u32,
                     p:     unsafe *Pattern,
                     typed: unsafe *BinaryOperatorExpr) -> unsafe *Expr {
        var rhs: unsafe *Expr = &null
        if p->kind == PatternKind::LiteralPattern {
            rhs = cast<LiteralPattern>(p)->value
        } else {
            rhs = self._decl_ref(
                p->resolved_decl,
                if (typed->rhs->type_ != &null) => (typed->rhs->type_) else => self._occ_type(occ),
            )
        }

        var unsafe *b = BinaryOperatorExpr::create(
            self.ctx,
            self._at,
            self._occ(occ),
            rhs,
            typed->op_token,
        )

        b->type_          = typed->type_
        b->value_category = Expr::ValueCategory::RValue
        b->resolved_op    = typed->resolved_op
        b->op_via_free    = typed->op_via_free
        b->op_rewrite     = typed->op_rewrite
        b->op_instance    = typed->op_instance
        b->tag_eq         = typed->tag_eq
        if b->resolved_op == &null && !b->tag_eq {
            return b
        }

        return self.ops.lower_one(unsafe (b as unsafe *Expr))
    }

    /// `__builtin_memcmp(s.as_ptr(), "<bytes>", n) == 0`.
    priv fn _memcmp_eq(self, occ: u32, bytes: unsafe *cxx::std::vector<u8>) -> unsafe *Expr {
        var unsafe *f = self._builtin(LowerTargets::clang_memcmp())
        var unsafe *pu8 = self.sc->types->pointer(
            self.sc->types->qualified(
                self.sc->builtin(BuiltinKind::U8),
                QUAL_CONST,
            ),
        )

        var args = self.list_builder<unsafe *Expr>()
        args.push(self._string_call(occ, LangMembers::string_as_ptr(), pu8))
        args.push(self.synth.bytes_literal(self._at, bytes, pu8))
        args.push(
            self.synth.int_literal(
                self._at,
                bytes->size() as u64,
                BuiltinKind::USize,
            ),
        )

        var unsafe *call = self._call(f, &args)
        return self._eq(
            call,
            self.synth.int_literal(self._at, 0, BuiltinKind::I32),
        )
    }

    /// `s.name()`, a no-argument string accessor.
    priv fn _string_call(self, occ: u32, const name: string, ty: unsafe *Type) -> unsafe *Expr {
        var none = self.list_builder<unsafe *Expr>()
        return self.synth.member_call(
            self._at,
            self._occ(occ),
            self._lang_member(WellKnownType::String, name),
            &none,
            ty,
        )
    }

    /// Key \p key of \p d as a literal of type \p t: the bias undone, a
    /// negative value as `(-mag)`, and i64's minimum as `(-(2^63 - 1) - 1)`,
    /// since `2^63` has no signed 64-bit literal.
    priv fn _int_value(self, d: Domain, key: u64, t: unsafe *Type) -> unsafe *Expr {
        var kind = self._builtin_kind(t)
        if !d.signed_ {
            return self.synth.int_literal(self._at, key, kind)
        }

        var bias = (1 as u64) << ((d.bits - 1) as u64)
        if key >= bias {
            return self.synth.int_literal(self._at, key - bias, kind)
        }

        var mag = bias - key
        if d.bits == 64 && mag == bias {
            var unsafe *adjacent = self._neg(
                self.synth.int_literal(self._at, bias - (1 as u64), kind),
                t,
            )

            return self._arith(
                adjacent,
                self.synth.int_literal(self._at, 1, kind),
                TokenKind::OpMinus,
                t,
            )
        }

        return self._neg(self.synth.int_literal(self._at, mag, kind), t)
    }

    priv fn _builtin_kind(self, t: unsafe *Type) -> BuiltinKind {
        var unsafe *b = dyn_cast<BuiltinType>(canon_unqual(self.tu.as_value(t)))
        if b == &null {
            kairo::std::ice_fail(
                "MatchLowering: an integer column whose type is not a builtin integer",
            )
        }

        return b->builtin
    }

    /// # occurrences

    /// The value at occurrence \p o, a fresh tree on every call: a node has
    /// one parent.
    priv fn _occ(self, o: u32) -> unsafe *Expr {
        var unsafe *local = self._locals[o as usize]
        if local != &null {
            var unsafe *use = self.synth.use_of(
                local,
                self._at,
                Expr::ValueCategory::LValue,
            )

            use->type_ = canon_unqual(self._referee(local->type_))
            return use
        }

        var d = self._t->occs[o as usize]
        match d.kind {
            case OccKind::Field {
                return self.synth.field_of(
                    self._at,
                    self._occ(d.parent as u32),
                    d.field,
                    self._occ_type(o),
                )
            } case OccKind::Payload {
                return self.layout.field_ref(
                    self._at,
                    self._occ(d.parent as u32),
                    self._enum_at(d.parent as u32),
                    d.index,
                    d.field,
                    self._occ_type(o),
                )
            } default {
                0
            }
        }

        kairo::std::ice_fail(
            "MatchLowering: an occurrence with no C++ path; _renderable gate failure",
        )
    }

    priv fn _occ_type(self, o: u32) -> unsafe *Type {
        var d = self._t->occs[o as usize]
        if d.type_ != &null {
            return d.type_
        }

        if d.field != &null {
            return d.field->type_
        }

        return &null
    }

    /// # jumps

    /// The label a jump to node \p i lands on: the fail block, an arm
    /// (statement form, a leaf with nothing to do first), or the node's own
    /// label, queueing the node.
    priv fn _target(self, i: i32) -> Token {
        if i < 0 {
            kairo::std::ice_fail("MatchLowering: a jump to no node")
        }

        var n = self._t->nodes[i as usize]
        if n.kind == DKind::Fail {
            self._fail_used = true
            if !self._adt_ctx {
                self._fail_general = true
            }

            return self._fail
        }

        if n.kind == DKind::Leaf && !self._value && !self._arms[n.arm as usize].slots {
            self._arms[n.arm as usize].used = true
            return self._arms[n.arm as usize].label
        }

        if self._queued[i as usize] == 0 {
            self._queued[i as usize] = 1
            self._queue.push_back(i as u32)
        }

        return self._labels[i as usize]
    }

    /// `if (c) { goto <child>; }`
    priv fn _if_goto(self,
                     c:          unsafe *Expr,
                     child:      i32,
                     @inout out: cxx::std::vector<unsafe *Stmt>) {
        var take = cxx::std::vector<unsafe *Stmt>()
        take.push_back(self._jump(self._target(child)))
        out.push_back(
            ConditionalStmt::create(
                self.ctx,
                self._at,
                c,
                self._block(&take),
                &null,
            ),
        )
    }

    /// `switch (v) { case ...: goto ...; default: goto <other>; }`; a
    /// negative \p other, or one that is a Fail node, puts UnmatchedPolicy
    /// in the default itself -- the ADT one when \p adt, the switch being
    /// over a tag (_policy).
    priv fn _dispatch(self,
                      value:       unsafe *Expr,
                      const cases: cxx::std::vector<DispatchCase>,
                      other:       i32,
                      adt:         bool) -> unsafe *Stmt {
        var unsafe *s = SwitchDispatchStmt::create(self.ctx, self._at, value)
        var        lb = self.list_builder<DispatchCase>()
        for var i: usize = 0; i < cases.size(); ++i {
            lb.push((cases)[i])
        }

        lb.freeze_into(&s->cases)
        if other < 0 || self._t->nodes[other as usize].kind == DKind::Fail {
            s->default_stmt = self._policy(adt)
        } else {
            s->default_target = self._target(other)
        }

        return s
    }

    /// `__builtin_trap();` or `__builtin_unreachable();`, by UnmatchedPolicy:
    /// for an ADT's tag or a closed plain enum (\p adt, _holds_only_variants)
    /// the policy that defaults to unreachable, for anything else the one
    /// that follows -O. Sema proved the match covers every variant, and no
    /// value of the enum holds another, so the trap only kept a range check
    /// in front of every table load
    /// (CodeGenOptions::adt_tag_policy; --hardening=enum-tags restores it).
    priv fn _policy(self, adt: bool) -> unsafe *Stmt {
        var pol = if (adt) => (self.sc->opts.adt_unmatched) else => self.sc->opts.unmatched
        var name = if (pol == UnmatchedPolicy::Unreachable) => (LowerTargets::clang_unreachable())
                   else => LowerTargets::clang_trap()
        var none = self.list_builder<unsafe *Expr>()
        return self._expr_stmt(self._call(self._builtin(name), &none))
    }

    priv fn _builtin(self, const name: string) -> unsafe *FunctionDecl {
        if self.sc->builtins == &null {
            kairo::std::ice_fail(
                "MatchLowering: no builtin importer; the driver must initialize BuiltinImport before sema",
            )
        }

        var e = self.sc->builtins->resolve(name)
        if e.decl == &null {
            kairo::std::ice_fail(
                f"MatchLowering: '{name}' did not resolve as a clang builtin: {e.why}",
            )
        }

        return e.decl
    }

    priv fn _call(self,
                  f:           unsafe *FunctionDecl,
                  @inout args: ListBuilder<unsafe *Expr>) -> unsafe *Expr {
        var unsafe *callee = NamedIdentExpr::create(
            self.ctx,
            self._at,
            self.synth.ident(
                self._at,
                self.tu.decl_name(unsafe (f as unsafe *Decl)),
            ),
        )

        callee->resolved_decl = unsafe (f as unsafe *Decl)
        var unsafe *c = CallExpr::create(self.ctx, self._at, callee)
        args.freeze_into(&c->args)
        c->type_          = f->return_type
        c->value_category = Expr::ValueCategory::RValue
        return c
    }

    /// # lang-item members (IterLowering::_lang_member)

    priv fn _lang_member(self, k: WellKnownType, const name: string) -> unsafe *Decl {
        var unsafe *d = self.sc->well_known->get(k)
        if d == &null {
            kairo::std::ice_fail(
                f"MatchLowering: the '{to_string(k)}' lang item is unbound",
            )
        }

        var unsafe *body = self.tu.pattern_of(NameLookup::representative(d))
        var unsafe *dc   = NameLookup::context_of(body)
        if dc == &null {
            kairo::std::ice_fail(
                f"MatchLowering: '{to_string(k)}' has no scope",
            )
        }

        var imm  = self.sc->imm_table()->intern_ident_copy(name)
        var cell = self.sc->lookup.in_context(dc, DeclName::ident(imm), name)
        if !cell.found() {
            kairo::std::ice_fail(
                f"MatchLowering: '{to_string(k)}' has no member '{name}'; Lib/builtin and the lowering disagree",
            )
        }

        return cell.first()
    }

    /// # minting

    priv fn _name(self, const s: string) -> Token {
        return self.synth.ident(self._at, s)
    }

    priv fn _u32(self) -> unsafe *Type {
        return self.sc->builtin(BuiltinKind::U32)
    }

    priv fn _usize(self) -> unsafe *Type {
        return self.sc->builtin(BuiltinKind::USize)
    }

    priv fn _bool(self) -> unsafe *Type {
        return self.sc->builtin(BuiltinKind::Bool)
    }

    priv fn _label_stmt(self, t: Token) -> unsafe *Stmt {
        return LabelIntrinsicStmt::create(self.ctx, self._at, t)
    }

    priv fn _jump(self, t: Token) -> unsafe *Stmt {
        return JumpIntrinsicStmt::create(self.ctx, self._at, t)
    }

    priv fn _block(self, @inout stmts: cxx::std::vector<unsafe *Stmt>) -> unsafe *CompoundStmt {
        var lb = self.list_builder<unsafe *Stmt>()
        for var i: usize = 0; i < stmts.size(); ++i {
            lb.push((stmts)[i])
        }

        var unsafe *c = CompoundStmt::create(self.ctx, self._at)
        lb.freeze_into(&c->body)
        return c
    }

    priv fn _expr_stmt(self, e: unsafe *Expr) -> unsafe *Stmt {
        return ExpressionStmt::create(self.ctx, e->range, e)
    }

    priv fn _paren(self, e: unsafe *Expr) -> unsafe *Expr {
        var unsafe *p = ParenExpr::create(self.ctx, e->range, e)
        p->type_          = e->type_
        p->value_category = e->value_category
        return p
    }

    /// A name for an enumerator or a constant, spelled by EmitIR from the decl.
    priv fn _decl_ref(self, d: unsafe *Decl, ty: unsafe *Type) -> unsafe *Expr {
        var unsafe *r = NamedIdentExpr::create(
            self.ctx,
            self._at,
            self.synth.ident(self._at, self.tu.decl_name(d)),
        )

        r->resolved_decl  = d
        r->type_          = ty
        r->value_category = Expr::ValueCategory::RValue
        return r
    }

    priv fn _eq(self, l: unsafe *Expr, r: unsafe *Expr) -> unsafe *Expr {
        return self._cmp(l, r, TokenKind::OpEqualEqual)
    }

    priv fn _cmp(self, l: unsafe *Expr, r: unsafe *Expr, k: TokenKind) -> unsafe *Expr {
        var unsafe *b = BinaryOperatorExpr::create(
            self.ctx,
            self._at,
            l,
            r,
            self.synth.punct(self._at, k),
        )

        b->type_          = self._bool()
        b->value_category = Expr::ValueCategory::RValue
        return b
    }

    /// `l && r`; a null \p l is `r`.
    priv fn _and(self, l: unsafe *Expr, r: unsafe *Expr) -> unsafe *Expr {
        if l == &null {
            return r
        }

        return self._cmp(l, r, TokenKind::OpAmpAmp)
    }

    priv fn _not(self, e: unsafe *Expr) -> unsafe *Expr {
        var unsafe *u = UnaryOperatorExpr::create(
            self.ctx,
            self._at,
            e,
            self.synth.punct(self._at, TokenKind::OpExclaim),
            UnaryOperatorExpr::Fix::Prefix,
        )

        u->type_          = self._bool()
        u->value_category = Expr::ValueCategory::RValue
        return u
    }

    priv fn _neg(self, e: unsafe *Expr, t: unsafe *Type) -> unsafe *Expr {
        var unsafe *u = UnaryOperatorExpr::create(
            self.ctx,
            self._at,
            e,
            self.synth.punct(self._at, TokenKind::OpMinus),
            UnaryOperatorExpr::Fix::Prefix,
        )

        u->type_          = t
        u->value_category = Expr::ValueCategory::RValue
        return u
    }

    priv fn _arith(self,
                   l: unsafe *Expr,
                   r: unsafe *Expr,
                   k: TokenKind,
                   t: unsafe *Type) -> unsafe *Expr {
        var unsafe *b = BinaryOperatorExpr::create(
            self.ctx,
            self._at,
            l,
            r,
            self.synth.punct(self._at, k),
        )

        b->type_          = t
        b->value_category = Expr::ValueCategory::RValue
        return b
    }

    priv fn _assign(self, l: unsafe *Expr, r: unsafe *Expr) -> unsafe *Expr {
        var unsafe *a = AssignOperatorExpr::create(
            self.ctx,
            self._at,
            l,
            r,
            self.synth.punct(self._at, TokenKind::OpEqual),
        )

        a->type_          = l->type_
        a->value_category = Expr::ValueCategory::LValue
        return a
    }

    priv fn _deref(self, e: unsafe *Expr, t: unsafe *Type) -> unsafe *Expr {
        var unsafe *u = UnaryOperatorExpr::create(
            self.ctx,
            self._at,
            e,
            self.synth.punct(self._at, TokenKind::OpStar),
            UnaryOperatorExpr::Fix::Prefix,
        )

        u->type_          = t
        u->value_category = Expr::ValueCategory::LValue
        return u
    }
}
