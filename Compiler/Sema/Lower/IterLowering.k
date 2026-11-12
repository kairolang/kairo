/// --- The Kairo Project -------------------- Sema/Lower/IterLowering.k --- ///
///
///   \brief `for x in xs` becomes a plain loop over a once-evaluated iterable.
///
///   \detail
///     X classified the iterable (`RangedForStmt::iter_kind`), recorded its
///     element type (`iter_elem`) and, for a user `op in`, the operator it
///     selected (`iter_op`). This pass decides nothing: it renders one shape
///     per kind, a block holding the hidden locals and a `while` whose body
///     opens with the binder.
///
///       a..b    { T lo = a; T hi = b; T i = lo;
///                 while (i < hi) { T x = i; ++i; BODY } }
///
///       a..=b   { T lo = a; T hi = b; T i = lo; bool more = (lo <= hi);
///                 while (more) { T x = i; more = (i != hi); if (more) { ++i } BODY } }
///
///       [T; N]  { usize n = N; usize k = 0;
///                 while (k < n) { T x = arr[k]; ++k; BODY } }
///
///       [T;]    { Slice<T> s = xs; T* p = s.data; usize n = s.len; usize k = 0;
///                 while (k < n) { T x = p[k]; ++k; BODY } }
///
///       op in   { Yield<T> it = xs.__kairo_iter();
///                 while (it.next()) { T x = *it.current(); BODY } }
///
///       C++     { R* rng = &xs; B it = (*rng).begin(); E end = (*rng).end();
///                 while (it != end) { T x = *it; ++it; BODY } }
///               ([stmt.ranged]; `begin(*rng)` / `end(*rng)` when ADL found
///               free ones). X resolved both calls and typed the three
///               operations; this pass places them, lowering the operators
///               itself: they enter the tree after OperatorLowering ran.
///
///     Every loop advances BEFORE the body, so `continue`, which jumps to the
///     loop test, needs no step clause. The inclusive range never computes a
///     value past `hi`, so `lo..=T::MAX` cannot overflow; the exclusive one
///     only increments while `i < hi`.
///
///   \par Evaluation and lifetime
///     The iterable is evaluated once. An array lvalue that is pure is indexed
///     in place (re-reading a pure path changes nothing); an impure one is
///     reached through a pointer bound once; an array prvalue (a list literal)
///     is bound to a local. A Slice is copied: it is a view, the copy is two
///     words, and the copy drops a `const` the binding may carry. A prvalue
///     receiver of `op in` is bound to a local first: the generator holds its
///     address for the whole loop. A C++ range is reached through its
///     address when it is an lvalue, keeping its cv so `begin()` is the one
///     X chose, and is bound to a local when it is a prvalue -- C++'s
///     `auto&& __range`, which extends a temporary to the end of the loop.
///
///   \par Binders
///     One binder. Plain `x` is a copy of the element; `*x` is its address,
///     except over a range, where it is the address of a per-iteration copy:
///     the counter itself is not the user's to write. `_` binds nothing.
///
///   \par Labels
///     A labeled loop keeps its label on the minted `while`:
///     `{ locals; label: while ... }`.
///
///   \par Not lowered here
///     Vector, set, map and string that declare no `op in (self)` (a
///     declared one makes the loop IterKind::User, above) ICE naming what
///     they wait on; FeatureGateCheck (SC116E) rejects them first, so the ICE is an invariant. A dependent iterable (iter_kind None, no type) is left for M2;
///     reaching codegen it ICEs in EmitIR. An imported C++ instance over the
///     generic's parameter (cxx_dependent) is not lowered: EmitIR spells C++'s
///     own range-for.
///
///   Phase: LOWER, after CallLowering and before ExtensionLowering: a user
///   `op in` declared in an extension is called here through a chain, and
///   ExtensionLowering turns that into the free call. Before
///   ListLiteralLowering: an array literal bound here is rendered there.
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

import AST::Context::InstantiationRegistry::InstanceEntry
import AST::Context::SymbolTable::DeclName
import AST::Kind::StmtKind::to_string
import AST::Kind::TypeKind::to_string
import AST::LangItems::{
    LangMembers,
    WellKnownType,
    to_string,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Stmt,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    BuiltinType,
    QUAL_CONST,
    canon_has_const,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    FunctionDecl,
    VariableDecl,
}
import AST::Node::Expressions::{
    AssignOperatorExpr, BinaryOperatorExpr, CallExpr,  ClosureExpr,   ListLiteralExpr,
    ListStorage,        ParenExpr,          RangeExpr, SubscriptExpr, UnaryOperatorExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Statements::{
    Binding,  BindingShorthand, CompoundStmt,  ConditionalStmt, DeclStmt, ExpressionStmt,
    IterKind, LabeledStmt,      RangedForStmt, WhileLoopStmt,
}
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    FixedArrayType,
    PointerType,
}
import AST::Visitor::ASTWriter::{
    ASTWriter,
    ListBuilder,
}
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Location::SourceRange::SourceRange
import Sema::Check::ConstEval::ConstEval
import Sema::Lower::LowerStep::LowerStep
import Sema::Lower::LowerSynth::LowerSynth
import Sema::Lower::OperatorLowering::OperatorLowering
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::TypeUtil::TypeUtil
import Token::TokenKind::TokenKind

/// The shifts in a range loop's body whose count is the loop's binder, and
/// whether the body could change the binder (SHIFT spec §4): an assignment
/// or `++`/`--` to it, its address (`&x`, an `inout` marker), or a closure
/// naming it. The binder is a per-iteration copy and may be writable, so a
/// write anywhere voids the range fact for every shift.
pub class ShiftBinderScan derives RecursiveASTVisitor<ShiftBinderScan> {
    pub var  binder:    unsafe *Decl                                 = &null
    pub var  written:   bool                                         = false
    pub var  shifts:    cxx::std::vector<unsafe *BinaryOperatorExpr>
    pub var  assigns:   cxx::std::vector<unsafe *AssignOperatorExpr>
    priv var _closures: u32                                          = 0

    fn ShiftBinderScan(self) { }

    /// \p e is the binder, parens aside.
    priv fn _is_binder(self, e: unsafe *Expr) -> bool {
        var unsafe *x = e
        while x != &null && isa<ParenExpr>(x) {
            x = cast<ParenExpr>(x)->inner
        }

        return x != &null
            && isa<NamedIdentExpr>(x)
            && cast<NamedIdentExpr>(x)->resolved_decl == self.binder
    }

    /// The local a write through \p e reaches: `x`, `x.f`, `x[i]`.
    priv fn _root_is_binder(self, e: unsafe *Expr) -> bool {
        var unsafe *x = e
        while x != &null {
            if isa<ParenExpr>(x) {
                x = cast<ParenExpr>(x)->inner
                continue
            }

            if isa<ChainExpr>(x) {
                x = cast<ChainExpr>(x)->base
                continue
            }

            if isa<SubscriptExpr>(x) {
                x = cast<SubscriptExpr>(x)->base
                continue
            }

            break
        }

        return self._is_binder(x)
    }

    priv fn _shift(self, k: TokenKind) -> bool {
        return k == TokenKind::OpLessLess || k == TokenKind::OpGreaterGreater
    }

    fn visit_binary_operator_expr(self, n: unsafe *BinaryOperatorExpr) -> bool {
        if self._shift(n->op_token.kind) && n->resolved_op == &null && self._is_binder(n->rhs) {
            self.shifts.push_back(n)
        }

        return true
    }

    fn visit_assign_operator_expr(self, n: unsafe *AssignOperatorExpr) -> bool {
        if self._root_is_binder(n->lhs) {
            self.written = true
        }

        var k  = n->op_token.kind
        var sh = k == TokenKind::OpLessLessEqual || k == TokenKind::OpGreaterGreaterEqual
        if sh && n->resolved_op == &null && self._is_binder(n->rhs) {
            self.assigns.push_back(n)
        }

        return true
    }

    fn visit_unary_operator_expr(self, n: *UnaryOperatorExpr) -> bool {
        var k = n->op_token.kind
        if (k == TokenKind::OpAmp || k == TokenKind::OpPlusPlus || k == TokenKind::OpMinusMinus)
            && self._root_is_binder(n->operand) {
            self.written = true
        }

        return true
    }

    fn visit_named_ident_expr(self, n: unsafe *NamedIdentExpr) -> bool {
        if self._closures > 0 && n->resolved_decl == self.binder {
            self.written = true
        }

        return true
    }

    fn traverse_closure_expr(self, n: unsafe *ClosureExpr) -> unsafe *ClosureExpr {
        self._closures += 1
        var unsafe *r = RecursiveASTVisitor<ShiftBinderScan>::traverse_closure_expr(
            self,
            n,
        )

        self._closures -= 1
        return r
    }
}

pub class IterLowering derives ASTWriter<IterLowering> {
    pub var  sc:    unsafe *SemaContext
    priv var tu:    TypeUtil
    priv var synth: LowerSynth

    fn IterLowering(self, sc: unsafe *SemaContext) {
        self.sc    = sc
        self.ctx   = sc->ctx
        self.tu    = TypeUtil(sc)
        self.synth = LowerSynth(sc)
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked)
        self.sc->begin_lower(LowerStep::Iter)
        if self.sc->tu == &null {
            return
        }

        ASTWriter<IterLowering>::run(self, self.sc->tu)
    }

    /// # entry points

    /// > 0 inside an `eval fn`, which runs at compile time already: an `eval
    /// for` there is an ordinary loop (Compiler/Spec/Eval.md#evalusagechecking), so its bounds may be the
    /// function's parameters.
    priv var _in_eval_fn: u32 = 0

    fn transform_function_decl(self, n: unsafe *FunctionDecl) -> cxx::std::vector<unsafe *Decl> {
        if n->is_eval() {
            self._in_eval_fn += 1
        }

        var out = ASTWriter<IterLowering>::transform_function_decl(self, n)
        if n->is_eval() {
            self._in_eval_fn -= 1
        }

        return out
    }

    fn transform_ranged_for_stmt(self, n: unsafe *RangedForStmt) -> cxx::std::vector<unsafe *Stmt> {
        if n->is_eval && self._in_eval_fn > 0 {
            n->is_eval = false
        }

        // An `eval for` stays for EmitIR's expansion (Compiler/Spec/Eval.md#eval-for); only the
        // loops in its body are lowered, and a range's bounds are kept.
        if n->is_eval {
            var unsafe *r = dyn_cast<RangeExpr>(
                self.tu.strip_parens(n->iterable),
            )

            if n->iter_kind == IterKind::RangeLit && r != &null {
                n->ev_lo    = r->begin
                n->ev_hi    = r->end
                n->ev_incl  = r->is_inclusive
                n->iterable = &null
            }

            n->body = cast<CompoundStmt>(self.transform_stmt_scalar(n->body))
            if n->iterable != &null {
                n->iterable = self.transform_expr(n->iterable)
            }

            return self._one_stmt(n)
        }

        self._children(n)
        var        pre    = self.list_builder<unsafe *Stmt>()
        var unsafe *#loop = self._lower(n, unsafe &pre)
        if #loop == &null {
            return self._one_stmt(n)
        }

        pre.push(#loop)
        return self._one_stmt(self._block(n->range, &pre))
    }

    /// The label stays on the loop: `{ locals; label: while ... }`.
    fn transform_labeled_stmt(self, n: unsafe *LabeledStmt) -> cxx::std::vector<unsafe *Stmt> {
        var unsafe *rf = dyn_cast<RangedForStmt>(n->inner)
        if rf == &null || rf->is_eval {
            return ASTWriter<IterLowering>::transform_labeled_stmt(self, n)
        }

        self._children(rf)
        var        pre    = self.list_builder<unsafe *Stmt>()
        var unsafe *#loop = self._lower(rf, unsafe &pre)
        if #loop == &null {
            return self._one_stmt(n)
        }

        n->inner = #loop
        pre.push(n)
        return self._one_stmt(self._block(n->range, &pre))
    }

    /// Children first: a `for` inside the body or the iterable is lowered on
    /// its own before this one is.
    priv fn _children(self, n: unsafe *RangedForStmt) {
        if n->iterable != &null {
            n->iterable = self.transform_expr(n->iterable)
        }

        n->body = cast<CompoundStmt>(self.transform_stmt_scalar(n->body))
    }

    /// # dispatch

    /// The minted loop, its hidden locals pushed onto \p pre; null leaves the
    /// node as it is (untyped or poisoned: already diagnosed, or dependent).
    priv fn _lower(self,
                   n:   unsafe *RangedForStmt,
                   pre: unsafe *ListBuilder<unsafe *Stmt>) -> unsafe *Stmt {
        if n->iterable == &null {
            return &null
        }

        if n->iter_kind == IterKind::Pack {
            return &null
        }

        if n->cxx_dependent { // C++'s own range-for, per instance: EmitIR::_cxx_dependent_for.
            return &null
        }

        if n->iterable->is_poisoned() || n->iterable->type_ == &null {
            return &null
        }

        if n->is_eval {
            kairo::std::ice_fail(
                "IterLowering: an eval for reached the loop lowering; transform_ranged_for_stmt keeps it for EmitIR",
            )
        }

        match n->iter_kind {
            case IterKind::RangeLit {
                return self._range(n, pre)
            } case IterKind::Array {
                return self._array(n, pre)
            } case IterKind::Slice {
                return self._slice(n, pre)
            } case IterKind::User {
                return self._user(n, pre)
            } case IterKind::Cxx {
                return self._cxx(n, pre)
            } case IterKind::RangeValue {
                return self._range_value(n, pre)
            } case IterKind::Vector {
                kairo::std::ice_fail(
                    "IterLowering: iterating a Vector waits on Vector's constructor bodies and a by-reference view of an lvalue Vector",
                )
            } case IterKind::Set {
                kairo::std::ice_fail(
                    "IterLowering: iterating a set; the container migration owns it",
                )
            } case IterKind::Map {
                kairo::std::ice_fail(
                    "IterLowering: iterating a map; the container migration and tuple lowering own it",
                )
            } case IterKind::String {
                kairo::std::ice_fail(
                    "IterLowering: iterating a string (UTF-8 decode to char) is not lowered yet",
                )
            } case IterKind::None {
                kairo::std::ice_fail(
                    "IterLowering: a typed iterable X did not classify; StmtTyping::iter_elem_type gate failure",
                )
            } case IterKind::Pack { // C++ unrolls it: EmitIR's fold over the pack.
                return &null
            }
        }
    }

    /// # shapes

    priv fn _range(self,
                   n:   unsafe *RangedForStmt,
                   pre: unsafe *ListBuilder<unsafe *Stmt>) -> unsafe *Stmt {
        var unsafe *r = cast<RangeExpr>(self.tu.strip_parens(n->iterable))
        var unsafe *t = n->iter_elem
        var        at = n->range
        if t == &null {
            kairo::std::ice_fail("IterLowering: range with no element type")
        }

        self._prove_binder_shifts(n, r)
        var unsafe *lo = self._local(pre, at, "lo", t, r->begin)
        var unsafe *hi = self._local(pre, at, "hi", t, r->end)
        var unsafe *i  = self._local(pre, at, "i", t, self._use(lo, at))

        var body = self.list_builder<unsafe *Stmt>()
        self._bind(n, unsafe &body, at, self._use(i, at), false)

        if !r->is_inclusive {
            body.push(self._expr_stmt(self._preinc(self._use(i, at))))
            body.push(unsafe (n->body as unsafe *Stmt))
            return self._while(
                at,
                self._cmp(
                    at,
                    self._use(i, at),
                    self._use(hi, at),
                    TokenKind::OpLess,
                ),
                unsafe &body,
            )
        }

        var unsafe *more = self._local(
            pre,
            at,
            "more",
            self._bool(),
            self._cmp(
                at,
                self._use(lo, at),
                self._use(hi, at),
                TokenKind::OpLessEqual,
            ),
        )

        body.push(
            self._expr_stmt(
                self._assign(
                    at,
                    self._use(more, at),
                    self._cmp(
                        at,
                        self._use(i, at),
                        self._use(hi, at),
                        TokenKind::OpExclaimEqual,
                    ),
                ),
            ),
        )

        var step = self.list_builder<unsafe *Stmt>()
        step.push(self._expr_stmt(self._preinc(self._use(i, at))))
        body.push(
            ConditionalStmt::create(
                self.ctx,
                at,
                self._use(more, at),
                self._block(at, &step),
                &null,
            ),
        )

        body.push(unsafe (n->body as unsafe *Stmt))
        return self._while(at, self._use(more, at), unsafe &body)
    }

    /// A shift in the body of `for x in lo..hi` whose count is `x` has its
    /// count proven in [lo, hi) (SHIFT spec §4): with lo a constant >= 0 and
    /// hi a constant at most the shifted type's width, it is no_wrap, and
    /// EmitIR leaves its mask out -- `for i in 0..32 { m |= 1 << i }` costs
    /// nothing on ARM32. `..=hi` bounds it by hi + 1. One plain binder only,
    /// and none if the body could write it (ShiftBinderScan).
    priv fn _prove_binder_shifts(self, n: unsafe *RangedForStmt, r: unsafe *RangeExpr) {
        if n->bindings.size() != 1 {
            return
        }

        var unsafe *b = n->bindings.get(0)
        if b == &null || b->is_discard || b->type_ != &null || b->decl == &null {
            return
        }

        if !b->shorthand.empty() {
            return
        }

        var ce = ConstEval(self.sc)
        var lo = ce.eval_int(r->begin)
        if !lo.ok || lo.neg || lo.overflow {
            return
        }

        var hi = ConstEval(self.sc).eval_int(r->end)
        if !hi.ok || hi.neg || hi.overflow {
            return
        }

        var bound = hi.mag
        if r->is_inclusive {
            bound = bound + (1 as u64)
        }

        var scan = ShiftBinderScan()
        scan.binder = b->decl
        scan.dyn()->dispatch_stmt(n->body)
        if scan.written {
            return
        }

        for var i: usize = 0; i < scan.shifts.size(); ++i {
            var unsafe *sh = scan.shifts[i]
            var        w   = self.tu.int_bits(self.tu.as_value(sh->type_))
            if w != 0 && bound <= (w as u64) {
                sh->no_wrap = true
            }
        }

        for var i: usize = 0; i < scan.assigns.size(); ++i {
            var unsafe *asg = scan.assigns[i]
            var w = self.tu.int_bits(self.tu.as_value(asg->lhs->type_))
            if w != 0 && bound <= (w as u64) {
                asg->no_wrap = true
            }
        }
    }

    /// A Range value: `inclusive` is read at run time. One loop serves both,
    /// over `last`, the final value it yields. `last` is computed only when the
    /// range is non-empty, so `hi - 1` cannot underflow at `T::MIN`, and the
    /// loop never computes past `last`, so `..=T::MAX` cannot overflow.
    ///
    ///   { Range<T> r = value; T i = r.begin; T hi = r.end; bool inc = r.inclusive;
    ///     bool more = (i < hi); if (inc) { more = (i <= hi); }
    ///     T last = hi; if (more) { if (inc) { } else { last = (hi - 1); } }
    ///     while (more) { T x = i; more = (i != last); if (more) { ++i } BODY } }
    priv fn _range_value(self,
                         n:   unsafe *RangedForStmt,
                         pre: unsafe *ListBuilder<unsafe *Stmt>) -> unsafe *Stmt {
        var        at  = n->range
        var unsafe *t  = n->iter_elem
        var unsafe *rt = canon_unqual(n->iterable->type_)
        if t == &null || rt == &null {
            kairo::std::ice_fail("IterLowering: Range value with no type")
        }

        var unsafe *tb = dyn_cast<BuiltinType>(canon_unqual(t))
        if tb == &null {
            kairo::std::ice_fail(
                "IterLowering: Range over a non-builtin element; X restricts ranges to integers",
            )
        }

        var unsafe *r = self._local(pre, at, "rng", rt, n->iterable)
        var unsafe *i = self._local(
            pre,
            at,
            "i",
            t,
            self.synth.field_of(
                at,
                self._use(r, at),
                self._lang_member(
                    WellKnownType::Range,
                    LangMembers::range_begin(),
                ),
                t,
            ),
        )

        var unsafe *hi = self._local(
            pre,
            at,
            "hi",
            t,
            self.synth.field_of(
                at,
                self._use(r, at),
                self._lang_member(
                    WellKnownType::Range,
                    LangMembers::range_end(),
                ),
                t,
            ),
        )

        var unsafe *inc = self._local(
            pre,
            at,
            "inc",
            self._bool(),
            self.synth.field_of(
                at,
                self._use(r, at),
                self._lang_member(
                    WellKnownType::Range,
                    LangMembers::range_inclusive(),
                ),
                self._bool(),
            ),
        )

        var unsafe *more = self._local(
            pre,
            at,
            "more",
            self._bool(),
            self._cmp(
                at,
                self._use(i, at),
                self._use(hi, at),
                TokenKind::OpLess,
            ),
        )

        var to_le = self.list_builder<unsafe *Stmt>()
        to_le.push(
            self._expr_stmt(
                self._assign(
                    at,
                    self._use(more, at),
                    self._cmp(
                        at,
                        self._use(i, at),
                        self._use(hi, at),
                        TokenKind::OpLessEqual,
                    ),
                ),
            ),
        )

        pre->push(
            unsafe (ConditionalStmt::create(self.ctx, at, self._use(inc, at), self._block(at, &to_le), &null) as unsafe *Stmt),
        )

        var unsafe *last = self._local(pre, at, "last", t, self._use(hi, at))
        var        dec   = self.list_builder<unsafe *Stmt>()
        // `hi - 1` runs only when the range is non-empty (i < hi), so it
        // cannot underflow: no_wrap.
        var unsafe *hm1 = self._arith(
            at,
            self._use(hi, at),
            self.synth.int_literal(at, 1, tb->builtin),
            TokenKind::OpMinus,
            t,
        )

        if isa<BinaryOperatorExpr>(hm1) {
            cast<BinaryOperatorExpr>(hm1)->no_wrap = true
        }

        dec.push(self._expr_stmt(self._assign(at, self._use(last, at), hm1)))
        var keep = self.list_builder<unsafe *Stmt>()
        var excl = self.list_builder<unsafe *Stmt>()
        excl.push(
            unsafe (ConditionalStmt::create(self.ctx, at, self._use(inc, at),
                      self._block(at, &keep), unsafe (self._block(at, &dec) as unsafe *Stmt)) as unsafe *Stmt),
        )

        pre->push(
            unsafe (ConditionalStmt::create(self.ctx, at, self._use(more, at), self._block(at, &excl), &null) as unsafe *Stmt),
        )

        var body = self.list_builder<unsafe *Stmt>()
        self._bind(n, unsafe &body, at, self._use(i, at), false)
        body.push(
            self._expr_stmt(
                self._assign(
                    at,
                    self._use(more, at),
                    self._cmp(
                        at,
                        self._use(i, at),
                        self._use(last, at),
                        TokenKind::OpExclaimEqual,
                    ),
                ),
            ),
        )

        var step = self.list_builder<unsafe *Stmt>()
        step.push(self._expr_stmt(self._preinc(self._use(i, at))))
        body.push(
            unsafe (ConditionalStmt::create(self.ctx, at, self._use(more, at), self._block(at, &step), &null) as unsafe *Stmt),
        )

        body.push(unsafe (n->body as unsafe *Stmt))
        return self._while(at, self._use(more, at), unsafe &body)
    }

    priv fn _array(self,
                   n:   unsafe *RangedForStmt,
                   pre: unsafe *ListBuilder<unsafe *Stmt>) -> unsafe *Stmt {
        var        at    = n->range
        var unsafe *elem = n->iter_elem
        var unsafe *arr  = canon_unqual(n->iterable->type_)
        if arr == &null || !isa<FixedArrayType>(arr) {
            kairo::std::ice_fail(
                "IterLowering: Array kind on a non-array iterable",
            )
        }

        var unsafe *fa = cast<FixedArrayType>(arr)
        if fa->is_incomplete {
            kairo::std::ice_fail("IterLowering: iterating an incomplete array")
        }

        // The array, read once per iteration through `base`.
        var base: unsafe *Expr = &null
        if n->iterable->is_lvalue() && LowerSynth::pure(n->iterable) {
            base = n->iterable
        } else if n->iterable->is_lvalue() {
            var unsafe *pa = self._local(
                pre,
                at,
                "pa",
                self.sc->types->pointer(arr),
                self.synth.addr_of(n->iterable),
            )

            base = self._deref(self._use(pa, at), arr)
        } else {
            var unsafe *seq = self._local(pre, at, "seq", arr, n->iterable)
            base = self._use(seq, at)
        }

        var unsafe *cnt = self._local(
            pre,
            at,
            "n",
            self._usize(),
            self.synth.int_literal(at, fa->size_bits as u64, BuiltinKind::USize),
        )

        var unsafe *k = self._local(
            pre,
            at,
            "k",
            self._usize(),
            self.synth.int_literal(at, 0, BuiltinKind::USize),
        )

        var body = self.list_builder<unsafe *Stmt>()
        self._bind(
            n,
            unsafe &body,
            at,
            self._subscript(at, base, self._use(k, at), elem),
            true,
        )

        body.push(self._expr_stmt(self._preinc(self._use(k, at))))
        body.push(n->body)
        return self._while(
            at,
            self._cmp(
                at,
                self._use(k, at),
                self._use(cnt, at),
                TokenKind::OpLess,
            ),
            unsafe &body,
        )
    }

    priv fn _slice(self,
                   n:   unsafe *RangedForStmt,
                   pre: unsafe *ListBuilder<unsafe *Stmt>) -> unsafe *Stmt {
        var        at    = n->range
        var unsafe *elem = n->iter_elem
        var unsafe *st   = canon_unqual(n->iterable->type_)
        var unsafe *ptr  = self.sc->types->pointer(elem)

        var unsafe *s = self._local(pre, at, "seq", st, n->iterable)
        self._extend(n->iterable)

        var unsafe *data = self._lang_member(
            WellKnownType::Slice,
            LangMembers::slice_data(),
        )

        var unsafe *len = self._lang_member(
            WellKnownType::Slice,
            LangMembers::slice_len(),
        )

        var unsafe *p = self._local(
            pre,
            at,
            "p",
            ptr,
            self.synth.field_of(at, self._use(s, at), data, ptr),
        )

        var unsafe *cnt = self._local(
            pre,
            at,
            "n",
            self._usize(),
            self.synth.field_of(at, self._use(s, at), len, self._usize()),
        )

        var unsafe *k = self._local(
            pre,
            at,
            "k",
            self._usize(),
            self.synth.int_literal(at, 0, BuiltinKind::USize),
        )

        var body = self.list_builder<unsafe *Stmt>()
        self._bind(
            n,
            unsafe &body,
            at,
            self._subscript(at, self._use(p, at), self._use(k, at), elem),
            true,
        )

        body.push(self._expr_stmt(self._preinc(self._use(k, at))))
        body.push(n->body)
        return self._while(
            at,
            self._cmp(
                at,
                self._use(k, at),
                self._use(cnt, at),
                TokenKind::OpLess,
            ),
            unsafe &body,
        )
    }

    priv fn _user(self,
                  n:   unsafe *RangedForStmt,
                  pre: unsafe *ListBuilder<unsafe *Stmt>) -> unsafe *Stmt {
        var        at      = n->range
        var unsafe *elem   = n->iter_elem
        var unsafe *gen_ty = self._yield_of(elem)

        // The generator the loop drives. A record's `op in` makes one from
        // the iterable; a Yield<T> value IS one (StmtTyping::_iter_classify
        // selects no op for it).
        var it:     unsafe *VariableDecl = &null
        var by_addr                      = false
        if n->iter_op == &null {
            var unsafe *src = n->iterable
            if src->is_lvalue() {
                // In place, through its address: Yield is move-only, and the
                // loop advances the generator the caller holds.
                var unsafe *addr = UnaryOperatorExpr::create(
                    self.ctx,
                    src->range,
                    src,
                    self.synth.punct(src->range, TokenKind::OpAmp),
                    UnaryOperatorExpr::Fix::Prefix,
                )

                addr->type_          = self.sc->types->pointer(gen_ty, false)
                addr->value_category = Expr::ValueCategory::RValue
                it      = self._local(pre, at, "gen", addr->type_, addr)
                by_addr = true
            } else {
                it = self._local(pre, at, "it", gen_ty, src)
            }
        } else {
            var recv: unsafe *Expr = n->iterable
            if !recv->is_lvalue() {
                var unsafe *tmp = self._local(
                    pre,
                    at,
                    "seq",
                    canon_unqual(recv->type_),
                    recv,
                )

                recv = self._use(tmp, at)
            }

            var none = self.list_builder<unsafe *Expr>()
            var unsafe *call = self.synth.member_call(
                at,
                recv,
                n->iter_op,
                &none,
                gen_ty,
            )

            cast<CallExpr>(call)->instance = n->iter_inst
            it = self._local(pre, at, "it", gen_ty, call)
        }

        var unsafe *next_d = self._lang_member(
            WellKnownType::Yield,
            LangMembers::yield_next(),
        )

        var unsafe *cur_d = self._lang_member(
            WellKnownType::Yield,
            LangMembers::yield_current(),
        )

        var unsafe *gen_cur = if (by_addr) => (self._deref(
                                  self._use(it, at),
                                  gen_ty,
                              ))
                              else => self._use(it, at)
        var unsafe *gen_next = if (by_addr) => (self._deref(
                                   self._use(it, at),
                                   gen_ty,
                               ))
                               else => self._use(it, at)

        var no_cur = self.list_builder<unsafe *Expr>()
        var unsafe *cur = self.synth.member_call(
            at,
            gen_cur,
            cur_d,
            &no_cur,
            self.sc->types->pointer(elem),
        )

        var body = self.list_builder<unsafe *Stmt>()
        self._bind(n, unsafe &body, at, self._deref(cur, elem), true)
        body.push(n->body)

        var no_next = self.list_builder<unsafe *Expr>()
        return self._while(
            at,
            self.synth.member_call(at, gen_next, next_d, &no_next, self._bool()),
            unsafe &body,
        )
    }

    priv fn _cxx(self,
                 n:   unsafe *RangedForStmt,
                 pre: unsafe *ListBuilder<unsafe *Stmt>) -> unsafe *Stmt {
        var at = n->range
        if (n->cxx_it == &null
            || n->cxx_end == &null
            || n->cxx_cond == &null
            || n->cxx_deref == &null
            || n->cxx_next == &null) {
            kairo::std::ice_fail(
                "IterLowering: a C++ range with no protocol pieces; StmtTyping::_cxx_range gate failure",
            )
        }

        var unsafe *itv  = cast<VariableDecl>(n->cxx_it)
        var unsafe *endv = cast<VariableDecl>(n->cxx_end)

        var        rng: unsafe *VariableDecl = &null
        var unsafe *obj                      = self._referee(n->iterable->type_)
        if n->iterable->is_lvalue() {
            var unsafe *addr = UnaryOperatorExpr::create(
                self.ctx,
                n->iterable->range,
                n->iterable,
                self.synth.punct(n->iterable->range, TokenKind::OpAmp),
                UnaryOperatorExpr::Fix::Prefix,
            )

            addr->type_          = self.sc->types->pointer(obj, false)
            addr->value_category = Expr::ValueCategory::RValue
            rng = self._local(pre, at, "rng", addr->type_, addr)
            // The place's constness is C++'s to deduce: a field read through a
            // `const self` has a non-const Kairo type but a const address, and
            // its begin()/end() are the const overloads, so a spelled `T*` or
            // `iterator` would not bind.
            rng->auto_copy  = true
            itv->auto_copy  = true
            endv->auto_copy = true
        } else {
            rng = self._local(pre, at, "seq", canon_unqual(obj), n->iterable)
        }

        itv->init = self._cxx_call(
            n,
            at,
            rng,
            obj,
            n->cxx_begin_fn,
            n->cxx_begin_inst,
            itv->type_,
        )

        endv->init = self._cxx_call(
            n,
            at,
            rng,
            obj,
            n->cxx_end_fn,
            n->cxx_end_inst,
            endv->type_,
        )

        pre->push(
            unsafe (DeclStmt::create(self.ctx, at, unsafe (itv as unsafe *Decl)) as unsafe *Stmt),
        )

        pre->push(
            unsafe (DeclStmt::create(self.ctx, at, unsafe (endv as unsafe *Decl)) as unsafe *Stmt),
        )

        var        ops    = OperatorLowering(self.sc)
        var unsafe *cond  = ops.transform_expr(n->cxx_cond)
        var unsafe *place = ops.transform_expr(n->cxx_deref)
        var unsafe *next  = ops.transform_expr(n->cxx_next)

        var body = self.list_builder<unsafe *Stmt>()
        self._bind(n, unsafe &body, at, place, n->cxx_deref->is_lvalue())
        body.push(self._expr_stmt(next))
        body.push(n->body)
        return self._while(at, cond, unsafe &body)
    }

    /// The range object, read through \p rng: `*rng` for an lvalue's
    /// address, the local itself for a prvalue's copy.
    priv fn _cxx_range_obj(self,
                           at:  SourceRange,
                           rng: unsafe *VariableDecl,
                           obj: unsafe *Type) -> unsafe *Expr {
        var unsafe *use = self._use(rng, at)
        if isa<PointerType>(canon_unqual(rng->type_)) {
            return self._deref(use, obj)
        }

        return use
    }

    /// `(*rng).f()` for a member, `f(*rng)` for a free function ADL found.
    priv fn _cxx_call(self,
                      n:    unsafe *RangedForStmt,
                      at:   SourceRange,
                      rng:  unsafe *VariableDecl,
                      obj:  unsafe *Type,
                      f:    unsafe *Decl,
                      inst: unsafe *InstanceEntry,
                      ty:   unsafe *Type) -> unsafe *Expr {
        var unsafe *recv = self._cxx_range_obj(at, rng, obj)
        if !n->cxx_free {
            var        none  = self.list_builder<unsafe *Expr>()
            var unsafe *call = self.synth.member_call(at, recv, f, &none, ty)
            cast<CallExpr>(call)->instance = inst
            return call
        }

        var unsafe *callee = NamedIdentExpr::create(
            self.ctx,
            at,
            self.synth.ident(at, self.tu.decl_name(f)),
        )

        callee->resolved_decl = f
        var unsafe *c   = CallExpr::create(self.ctx, at, callee)
        var        args = self.list_builder<unsafe *Expr>()
        args.push(recv)
        args.freeze_into(&c->args)
        c->instance       = inst
        c->type_          = ty
        c->value_category = Expr::ValueCategory::RValue
        return c
    }

    /// A C++ reference names its referee; the range object is the referee.
    priv fn _referee(self, t: unsafe *Type) -> unsafe *Type {
        if t != &null && isa<CXXLValueRefType>(t) {
            return cast<CXXLValueRefType>(t)->referee
        }

        if t != &null && isa<CXXRValueRefType>(t) {
            return cast<CXXRValueRefType>(t)->referee
        }

        return t
    }

    /// # the binder

    /// The binders' declarations, initialized from \p place, the element as
    /// an lvalue. \p stable: \p place is the element itself, so `*x` may take
    /// its address; otherwise (a range counter) `*x` points at a copy.
    ///
    /// `for (k, v) in xs` destructures a tuple element the way TupleLowering
    /// destructures a value: the element once, into a hidden local (a
    /// reference to a stable element, with the element's own constness so
    /// `*q` can point into a mutable one; a copy of an unstable one), then
    /// one local per binder off its fields `_i`. The per-binder local is a
    /// field of a local, so it is stable either way.
    priv fn _bind(self,
                  n:      unsafe *RangedForStmt,
                  body:   unsafe *ListBuilder<unsafe *Stmt>,
                  at:     SourceRange,
                  place:  unsafe *Expr,
                  stable: bool) {
        if n->bindings.size() == 1 {
            self._bind_one(n->bindings.get(0), body, at, place, stable)
            return
        }

        var unsafe *t = canon_unqual(self.tu.as_value(place->type_))
        if !self.tu.is_tuple(t) {
            kairo::std::ice_fail(
                "IterLowering: a binder list over a non-tuple element; StmtTyping::_bind_list gate failure",
            )
        }

        var elems = self.tu.tuple_elems(t)
        if elems.size() != n->bindings.size() {
            kairo::std::ice_fail(
                "IterLowering: binder count differs from the element's arity; StmtTyping::_bind_list gate failure",
            )
        }

        var unsafe *lt = t
        if stable && place->is_lvalue() {
            var unsafe *rt = if (canon_has_const(place->type_)) => (self.sc->types->qualified(
                                 t,
                                 QUAL_CONST,
                             ))
                             else => t
            lt = self.sc->types->cxx_lref(rt)
        }

        var unsafe *el = self._local(body, at, "e", lt, place)
        for var i: usize = 0; i < n->bindings.size(); ++i {
            var unsafe *b = n->bindings.get(i)
            if b == &null || b->is_discard {
                continue
            }

            var unsafe *fd = self.tu.tuple_field(t, i)
            if fd == &null {
                kairo::std::ice_fail(
                    "IterLowering: tuple record with fewer fields than its arity",
                )
            }

            var unsafe *pi = self.synth.field_of(
                b->range,
                self._use(el, at),
                fd,
                elems[i],
            )

            self._bind_one(b, body, at, pi, true)
        }
    }

    priv fn _bind_one(self,
                      b:      unsafe *Binding,
                      body:   unsafe *ListBuilder<unsafe *Stmt>,
                      at:     SourceRange,
                      place:  unsafe *Expr,
                      stable: bool) {
        if b->is_discard {
            return
        }

        if b->shorthand.has(BindingShorthand::Nullable) {
            kairo::std::ice_fail(
                "IterLowering: a nullable binder; NullableTypeLowering owns it",
            )
        }

        var unsafe *vd = dyn_cast<VariableDecl>(b->decl)
        if vd == &null {
            kairo::std::ice_fail("IterLowering: binder with no declaration")
        }

        if vd->type_ == &null {
            kairo::std::ice_fail(
                "IterLowering: untyped binder; StmtTyping::_bind_one gate failure",
            )
        }

        var as_ptr = b->shorthand.has(BindingShorthand::Pointer) && b->type_ == &null
        if !as_ptr {
            vd->init = place
        } else if stable {
            vd->init = self.synth.addr_of(place)
        } else {
            var unsafe *copy = self._local(
                body,
                at,
                "v",
                canon_unqual(place->type_),
                place,
            )

            vd->init = self.synth.addr_of(self._use(copy, at))
        }

        body->push(
            unsafe (DeclStmt::create(self.ctx, b->range, unsafe (vd as unsafe *Decl)) as unsafe *Stmt),
        )
    }

    /// # lang-item members

    /// A member of a lang record by name, looked up in the pattern's scope.
    priv fn _lang_member(self, k: WellKnownType, const name: string) -> unsafe *Decl {
        var unsafe *d = self.sc->well_known->get(k)
        if d == &null {
            kairo::std::ice_fail(
                f"IterLowering: the '{to_string(k)}' lang item is unbound",
            )
        }

        var unsafe *body = self.tu.pattern_of(NameLookup::representative(d))
        var unsafe *dc   = NameLookup::context_of(body)
        if dc == &null {
            kairo::std::ice_fail(f"IterLowering: '{to_string(k)}' has no scope")
        }

        var imm  = self.sc->imm_table()->intern_ident_copy(name)
        var cell = self.sc->lookup.in_context(dc, DeclName::ident(imm), name)
        if !cell.found() {
            kairo::std::ice_fail(
                f"IterLowering: '{to_string(k)}' has no member '{name}'; Lib/builtin and the lowering disagree",
            )
        }

        return cell.first()
    }

    priv fn _yield_of(self, elem: unsafe *Type) -> unsafe *Type {
        var a = cxx::std::vector<unsafe *Type>()
        a.push_back(elem)
        var unsafe *t = self.sc->lang_record(WellKnownType::Yield, unsafe &a)
        if t == &null {
            kairo::std::ice_fail("IterLowering: the Yield lang item is unbound")
        }

        return t
    }

    /// # minting

    priv fn _local(self,
                   pre:        unsafe *ListBuilder<unsafe *Stmt>,
                   at:         SourceRange,
                   const hint: string,
                   ty:         unsafe *Type,
                   init:       unsafe *Expr) -> unsafe *VariableDecl {
        var unsafe *vd = self.synth.local(at, hint, ty, init)
        pre->push(
            unsafe (DeclStmt::create(self.ctx, at, unsafe (vd as unsafe *Decl)) as unsafe *Stmt),
        )

        return vd
    }

    priv fn _use(self, vd: unsafe *VariableDecl, at: SourceRange) -> unsafe *Expr {
        return self.synth.use_of(vd, at, Expr::ValueCategory::LValue)
    }

    priv fn _bool(self) -> unsafe *Type {
        return self.sc->builtin(BuiltinKind::Bool)
    }

    priv fn _usize(self) -> unsafe *Type {
        return self.sc->builtin(BuiltinKind::USize)
    }

    priv fn _cmp(self,
                 at:  SourceRange,
                 lhs: unsafe *Expr,
                 rhs: unsafe *Expr,
                 k:   TokenKind) -> unsafe *Expr {
        var unsafe *b = BinaryOperatorExpr::create(
            self.ctx,
            at,
            lhs,
            rhs,
            self.synth.punct(at, k),
        )

        b->type_          = self._bool()
        b->value_category = Expr::ValueCategory::RValue
        return b
    }

    priv fn _arith(self,
                   at:  SourceRange,
                   lhs: unsafe *Expr,
                   rhs: unsafe *Expr,
                   k:   TokenKind,
                   ty:  unsafe *Type) -> unsafe *Expr {
        var unsafe *b = BinaryOperatorExpr::create(
            self.ctx,
            at,
            lhs,
            rhs,
            self.synth.punct(at, k),
        )

        b->type_          = ty
        b->value_category = Expr::ValueCategory::RValue
        return b
    }

    priv fn _assign(self, at: SourceRange, lhs: unsafe *Expr, rhs: unsafe *Expr) -> unsafe *Expr {
        var unsafe *a = AssignOperatorExpr::create(
            self.ctx,
            at,
            lhs,
            rhs,
            self.synth.punct(at, TokenKind::OpEqual),
        )

        a->type_          = lhs->type_
        a->value_category = Expr::ValueCategory::LValue
        return a
    }

    priv fn _preinc(self, e: unsafe *Expr) -> unsafe *Expr {
        var unsafe *u = UnaryOperatorExpr::create(
            self.ctx,
            e->range,
            e,
            self.synth.punct(e->range, TokenKind::OpPlusPlus),
            UnaryOperatorExpr::Fix::Prefix,
        )

        u->type_          = e->type_
        u->value_category = Expr::ValueCategory::LValue
        // Every loop here steps only while the index is short of its bound
        // (`i < hi`, `i != last`, `k < n`), so an integer index never
        // overflows: C++'s own `++`, which keeps clang's induction-variable
        // reasoning (EmitIR's wrap forms would lose it).
        var unsafe *b = dyn_cast<BuiltinType>(canon_unqual(e->type_))
        u->no_wrap = b != &null && b->info()->is_integer()
        return u
    }

    priv fn _deref(self, e: unsafe *Expr, ty: unsafe *Type) -> unsafe *Expr {
        var unsafe *u = UnaryOperatorExpr::create(
            self.ctx,
            e->range,
            e,
            self.synth.punct(e->range, TokenKind::OpStar),
            UnaryOperatorExpr::Fix::Prefix,
        )

        u->type_          = ty
        u->value_category = Expr::ValueCategory::LValue
        return u
    }

    priv fn _subscript(self,
                       at:    SourceRange,
                       base:  unsafe *Expr,
                       index: unsafe *Expr,
                       ty:    unsafe *Type) -> unsafe *Expr {
        var unsafe *s = SubscriptExpr::create(self.ctx, at, base, index)
        s->type_          = ty
        s->value_category = Expr::ValueCategory::LValue
        return s
    }

    priv fn _expr_stmt(self, e: unsafe *Expr) -> unsafe *Stmt {
        return ExpressionStmt::create(self.ctx, e->range, e)
    }

    priv fn _block(self,
                   at:           SourceRange,
                   @inout stmts: ListBuilder<unsafe *Stmt>) -> unsafe *CompoundStmt {
        var unsafe *c = CompoundStmt::create(self.ctx, at)
        stmts.freeze_into(&c->body)
        return c
    }

    priv fn _while(self,
                   at:   SourceRange,
                   cond: unsafe *Expr,
                   body: unsafe *ListBuilder<unsafe *Stmt>) -> unsafe *Stmt {
        return WhileLoopStmt::create(
            self.ctx,
            at,
            cond,
            self._block(at, &*body),
        )
    }

    /// A slice literal bound to a local here lives to the end of the block,
    /// as one bound to a `var` does (LiteralTyping::mark_list_storage).
    priv fn _extend(self, e_in: unsafe *Expr) {
        var unsafe *e = self.tu.strip_parens(e_in)
        if e == &null || !isa<ListLiteralExpr>(e) {
            return
        }

        var unsafe *l = cast<ListLiteralExpr>(e)
        if l->type_ == &null || !self.tu.is_slice(l->type_) {
            return
        }

        l->storage = ListStorage::Extended
        for var i: usize = 0; i < l->elements.size(); ++i {
            self._extend(l->elements[i])
        }
    }
}
