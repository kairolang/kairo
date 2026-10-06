/// --- The Kairo Project ----------------------- Sema/Lower/IterLowering.k --- ///
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
///     address for the whole loop.
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
///     Vector, set, map and string ICE naming what they wait on; FeatureGateCheck (SC116E) rejects them first, so the ICE is an invariant. A dependent iterable (iter_kind None, no type) is left for M2;
///     reaching codegen it ICEs in EmitIR.
///
///   Phase: LOWER, after CallLowering and before ExtensionLowering: a user
///   `op in` declared in an extension is called here through a chain, and
///   ExtensionLowering turns that into the free call. Before
///   ListLiteralLowering: an array literal bound here is rendered there.
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
import Sema::Lower::LowerSynth::*;
import AST::Visitor::ASTWriter::*;
import AST::ASTSupport::*;
import AST::LangItems::*;
import AST::Context::SymbolTable::*;
import AST::Node::Base::*;
import AST::Node::Types::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Node::CanonicalNodes::*;
import AST::Kind::StmtKind::*;
import AST::Kind::TypeKind::*;
import Token::Token::*;
import Token::TokenKind::*;
import Location::SourceRange::*;

__inline_cpp("
#define ASTWriter_IterLowering ASTWriter<IterLowering>
");

class IterLowering derives ASTWriter::<IterLowering> {
    pub var sc: *SemaContext;
    priv var tu: TypeUtil;
    priv var synth: LowerSynth;

    fn IterLowering(self, sc: *SemaContext) {
        self.sc    = sc;
        self.ctx   = sc->ctx;
        self.tu    = TypeUtil(sc);
        self.synth = LowerSynth(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked);
        if self.sc->tu == &null { return; }
        ASTWriter_IterLowering::run(self.sc->tu);
    }

    // --- entry points -----------------------------------------------------------

    fn transform_ranged_for_stmt(self, n: *RangedForStmt) -> vec::<*Stmt> {
        self._children(n);
        var pre  = self.list_builder::<*Stmt>();
        var loop = self._lower(n, &pre);
        if loop == &null { return self._one_stmt(n); }
        pre.push(loop);
        return self._one_stmt(static_cast::<*Stmt>(self._block(n->range, &pre)));
    }

    /// The label stays on the loop: `{ locals; label: while ... }`.
    fn transform_labeled_stmt(self, n: *LabeledStmt) -> vec::<*Stmt> {
        var rf = dyn_cast::<RangedForStmt>(n->inner);
        if rf == &null { return ASTWriter_IterLowering::transform_labeled_stmt(n); }
        self._children(rf);
        var pre  = self.list_builder::<*Stmt>();
        var loop = self._lower(rf, &pre);
        if loop == &null { return self._one_stmt(n); }
        n->inner = loop;
        pre.push(static_cast::<*Stmt>(n));
        return self._one_stmt(static_cast::<*Stmt>(self._block(n->range, &pre)));
    }

    /// Children first: a `for` inside the body or the iterable is lowered on
    /// its own before this one is.
    priv fn _children(self, n: *RangedForStmt) {
        if n->iterable != &null { n->iterable = self.transform_expr(n->iterable); }
        n->body = cast::<CompoundStmt>(self.transform_stmt_scalar(n->body));
    }

    // --- dispatch -----------------------------------------------------------------

    /// The minted loop, its hidden locals pushed onto \p pre; null leaves the
    /// node as it is (untyped or poisoned: already diagnosed, or dependent).
    priv fn _lower(self, n: *RangedForStmt, pre: *ListBuilder::<*Stmt>) -> *Stmt {
        if n->iterable == &null { return &null; }
        if n->iterable->is_poisoned() || (n->iterable->type_ == &null) { return &null; }
        ICE_IF(n->is_eval, "IterLowering: eval for; EvalLowering owns it");

        switch n->iter_kind {
            case IterKind::RangeLit   { return self._range(n, pre); }
            case IterKind::Array      { return self._array(n, pre); }
            case IterKind::Slice      { return self._slice(n, pre); }
            case IterKind::User       { return self._user(n, pre); }
            case IterKind::RangeValue { return self._range_value(n, pre); }
            case IterKind::Vector     { ICE_FAIL("IterLowering: iterating a Vector waits on Vector's constructor bodies and a by-reference view of an lvalue Vector"); }
            case IterKind::Set        { ICE_FAIL("IterLowering: iterating a set; the container migration owns it"); }
            case IterKind::Map        { ICE_FAIL("IterLowering: iterating a map; the container migration and tuple lowering own it"); }
            case IterKind::String     { ICE_FAIL("IterLowering: iterating a string (UTF-8 decode to char) is not lowered yet"); }
            case IterKind::None       { ICE_FAIL("IterLowering: a typed iterable X did not classify; StmtTyping::iter_elem_type gate failure"); }
        }
        return &null;
    }

    // --- shapes -------------------------------------------------------------------

    priv fn _range(self, n: *RangedForStmt, pre: *ListBuilder::<*Stmt>) -> *Stmt {
        var r  = cast::<RangeExpr>(self.tu.strip_parens(n->iterable));
        var t  = n->iter_elem;
        var at = n->range;
        ICE_IF(t == &null, "IterLowering: range with no element type");

        var lo = self._local(pre, at, "lo", t, r->begin);
        var hi = self._local(pre, at, "hi", t, r->end);
        var i  = self._local(pre, at, "i",  t, self._use(lo, at));

        var body = self.list_builder::<*Stmt>();
        self._bind(n, &body, at, self._use(i, at), false);

        if !r->is_inclusive {
            body.push(self._expr_stmt(self._preinc(self._use(i, at))));
            body.push(static_cast::<*Stmt>(n->body));
            return self._while(at, self._cmp(at, self._use(i, at), self._use(hi, at), TokenKind::OpLess), &body);
        }

        var more = self._local(pre, at, "more", self._bool(),
                               self._cmp(at, self._use(lo, at), self._use(hi, at), TokenKind::OpLessEqual));
        body.push(self._expr_stmt(self._assign(at, self._use(more, at),
                  self._cmp(at, self._use(i, at), self._use(hi, at), TokenKind::OpExclaimEqual))));
        var step = self.list_builder::<*Stmt>();
        step.push(self._expr_stmt(self._preinc(self._use(i, at))));
        body.push(static_cast::<*Stmt>(ConditionalStmt::create(self.ctx, at, self._use(more, at), self._block(at, &step), &null)));
        body.push(static_cast::<*Stmt>(n->body));
        return self._while(at, self._use(more, at), &body);
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
    priv fn _range_value(self, n: *RangedForStmt, pre: *ListBuilder::<*Stmt>) -> *Stmt {
        var at = n->range;
        var t  = n->iter_elem;
        var rt = canon_unqual(n->iterable->type_);
        ICE_IF((t == &null) || (rt == &null), "IterLowering: Range value with no type");
        var tb = dyn_cast::<BuiltinType>(canon_unqual(t));
        ICE_IF(tb == &null, "IterLowering: Range over a non-builtin element; X restricts ranges to integers");

        var r   = self._local(pre, at, "rng", rt, n->iterable);
        var i   = self._local(pre, at, "i",   t, self.synth.field_of(at, self._use(r, at), self._lang_member(WellKnownType::Range, "begin"), t));
        var hi  = self._local(pre, at, "hi",  t, self.synth.field_of(at, self._use(r, at), self._lang_member(WellKnownType::Range, "end"), t));
        var inc = self._local(pre, at, "inc", self._bool(),
                              self.synth.field_of(at, self._use(r, at), self._lang_member(WellKnownType::Range, "inclusive"), self._bool()));

        var more = self._local(pre, at, "more", self._bool(), self._cmp(at, self._use(i, at), self._use(hi, at), TokenKind::OpLess));
        var to_le = self.list_builder::<*Stmt>();
        to_le.push(self._expr_stmt(self._assign(at, self._use(more, at),
                   self._cmp(at, self._use(i, at), self._use(hi, at), TokenKind::OpLessEqual))));
        pre->push(static_cast::<*Stmt>(ConditionalStmt::create(self.ctx, at, self._use(inc, at), self._block(at, &to_le), &null)));

        var last = self._local(pre, at, "last", t, self._use(hi, at));
        var dec = self.list_builder::<*Stmt>();
        dec.push(self._expr_stmt(self._assign(at, self._use(last, at),
                 self._arith(at, self._use(hi, at), self.synth.int_literal(at, 1, tb->builtin), TokenKind::OpMinus, t))));
        var keep = self.list_builder::<*Stmt>();
        var excl = self.list_builder::<*Stmt>();
        excl.push(static_cast::<*Stmt>(ConditionalStmt::create(self.ctx, at, self._use(inc, at),
                  self._block(at, &keep), static_cast::<*Stmt>(self._block(at, &dec)))));
        pre->push(static_cast::<*Stmt>(ConditionalStmt::create(self.ctx, at, self._use(more, at), self._block(at, &excl), &null)));

        var body = self.list_builder::<*Stmt>();
        self._bind(n, &body, at, self._use(i, at), false);
        body.push(self._expr_stmt(self._assign(at, self._use(more, at),
                  self._cmp(at, self._use(i, at), self._use(last, at), TokenKind::OpExclaimEqual))));
        var step = self.list_builder::<*Stmt>();
        step.push(self._expr_stmt(self._preinc(self._use(i, at))));
        body.push(static_cast::<*Stmt>(ConditionalStmt::create(self.ctx, at, self._use(more, at), self._block(at, &step), &null)));
        body.push(static_cast::<*Stmt>(n->body));
        return self._while(at, self._use(more, at), &body);
    }

    priv fn _array(self, n: *RangedForStmt, pre: *ListBuilder::<*Stmt>) -> *Stmt {
        var at   = n->range;
        var elem = n->iter_elem;
        var arr  = canon_unqual(n->iterable->type_);
        ICE_IF((arr == &null) || (!isa::<FixedArrayType>(arr)), "IterLowering: Array kind on a non-array iterable");
        var fa = cast::<FixedArrayType>(arr);
        ICE_IF(fa->is_incomplete, "IterLowering: iterating an incomplete array");

        // The array, read once per iteration through `base`.
        var base: *Expr = &null;
        if n->iterable->is_lvalue() && LowerSynth::pure(n->iterable) {
            base = n->iterable;
        } else if n->iterable->is_lvalue() {
            var pa = self._local(pre, at, "pa", self.sc->types->pointer(arr), self.synth.addr_of(n->iterable));
            base = self._deref(self._use(pa, at), arr);
        } else {
            var seq = self._local(pre, at, "seq", arr, n->iterable);
            base = self._use(seq, at);
        }

        var cnt = self._local(pre, at, "n", self._usize(), self.synth.int_literal(at, static_cast::<u64>(fa->size_bits), BuiltinKind::USize));
        var k   = self._local(pre, at, "k", self._usize(), self.synth.int_literal(at, 0, BuiltinKind::USize));

        var body = self.list_builder::<*Stmt>();
        self._bind(n, &body, at, self._subscript(at, base, self._use(k, at), elem), true);
        body.push(self._expr_stmt(self._preinc(self._use(k, at))));
        body.push(static_cast::<*Stmt>(n->body));
        return self._while(at, self._cmp(at, self._use(k, at), self._use(cnt, at), TokenKind::OpLess), &body);
    }

    priv fn _slice(self, n: *RangedForStmt, pre: *ListBuilder::<*Stmt>) -> *Stmt {
        var at   = n->range;
        var elem = n->iter_elem;
        var st   = canon_unqual(n->iterable->type_);
        var ptr  = self.sc->types->pointer(elem);

        var s = self._local(pre, at, "seq", st, n->iterable);
        self._extend(n->iterable);

        var data = self._lang_member(WellKnownType::Slice, "data");
        var len  = self._lang_member(WellKnownType::Slice, "len");
        var p    = self._local(pre, at, "p", ptr, self.synth.field_of(at, self._use(s, at), data, ptr));
        var cnt  = self._local(pre, at, "n", self._usize(), self.synth.field_of(at, self._use(s, at), len, self._usize()));
        var k    = self._local(pre, at, "k", self._usize(), self.synth.int_literal(at, 0, BuiltinKind::USize));

        var body = self.list_builder::<*Stmt>();
        self._bind(n, &body, at, self._subscript(at, self._use(p, at), self._use(k, at), elem), true);
        body.push(self._expr_stmt(self._preinc(self._use(k, at))));
        body.push(static_cast::<*Stmt>(n->body));
        return self._while(at, self._cmp(at, self._use(k, at), self._use(cnt, at), TokenKind::OpLess), &body);
    }

    priv fn _user(self, n: *RangedForStmt, pre: *ListBuilder::<*Stmt>) -> *Stmt {
        var at   = n->range;
        var elem = n->iter_elem;
        ICE_IF(n->iter_op == &null, "IterLowering: user iteration with no `op in` selected; X gate failure");

        var recv: *Expr = n->iterable;
        if !recv->is_lvalue() {
            var tmp = self._local(pre, at, "seq", canon_unqual(recv->type_), recv);
            recv = self._use(tmp, at);
        }

        var gen_ty = self._yield_of(elem);
        var none   = self.list_builder::<*Expr>();
        var it     = self._local(pre, at, "it", gen_ty, self.synth.member_call(at, recv, n->iter_op, &none, gen_ty));

        var next_d = self._lang_member(WellKnownType::Yield, "next");
        var cur_d  = self._lang_member(WellKnownType::Yield, "current");

        var no_cur = self.list_builder::<*Expr>();
        var cur    = self.synth.member_call(at, self._use(it, at), cur_d, &no_cur, self.sc->types->pointer(elem));

        var body = self.list_builder::<*Stmt>();
        self._bind(n, &body, at, self._deref(cur, elem), true);
        body.push(static_cast::<*Stmt>(n->body));

        var no_next = self.list_builder::<*Expr>();
        return self._while(at, self.synth.member_call(at, self._use(it, at), next_d, &no_next, self._bool()), &body);
    }

    // --- the binder ---------------------------------------------------------------

    /// The binder's declaration, initialized from \p place, the element as an
    /// lvalue. \p stable: \p place is the element itself, so `*x` may take its
    /// address; otherwise (a range counter) `*x` points at a copy.
    priv fn _bind(self, n: *RangedForStmt, body: *ListBuilder::<*Stmt>, at: SourceRange, place: *Expr, stable: bool) {
        ICE_IF(n->bindings.size() != 1, "IterLowering: more than one binder (destructuring); the tuple lowering owns it");
        var b = n->bindings.get(0);
        if b->is_discard { return; }

        var sh = static_cast::<u8>(b->shorthand);
        ICE_IF((sh & static_cast::<u8>(BindingShorthand::Nullable)) != 0, "IterLowering: a nullable binder; NullableTypeLowering owns it");

        var vd = dyn_cast::<VariableDecl>(b->decl);
        ICE_IF(vd == &null, "IterLowering: binder with no declaration");
        ICE_IF(vd->type_ == &null, "IterLowering: untyped binder; StmtTyping::_bind_one gate failure");

        var as_ptr = ((sh & static_cast::<u8>(BindingShorthand::Pointer)) != 0) && (b->type_ == &null);
        if !as_ptr {
            vd->init = place;
        } else if stable {
            vd->init = self.synth.addr_of(place);
        } else {
            var copy = self._local(body, at, "v", canon_unqual(place->type_), place);
            vd->init = self.synth.addr_of(self._use(copy, at));
        }
        body->push(static_cast::<*Stmt>(DeclStmt::create(self.ctx, b->range, static_cast::<*Decl>(vd))));
    }

    // --- lang-item members ----------------------------------------------------------

    /// A member of a lang record by name, looked up in the pattern's scope.
    priv fn _lang_member(self, k: WellKnownType, name: string) -> *Decl {
        var d = self.sc->well_known->get(k);
        ICE_IF(d == &null, f"IterLowering: the '{to_string(k)}' lang item is unbound");
        var body = self.tu.pattern_of(NameLookup::representative(d));
        var dc   = NameLookup::context_of(body);
        ICE_IF(dc == &null, f"IterLowering: '{to_string(k)}' has no scope");
        var imm  = self.sc->imm_table()->intern_ident_copy(name);
        var cell = self.sc->lookup.in_context(dc, DeclName::ident(imm), name);
        ICE_IF(!cell.found(), f"IterLowering: '{to_string(k)}' has no member '{name}'; Lib/builtin and the lowering disagree");
        return cell.first();
    }

    priv fn _yield_of(self, elem: *Type) -> *Type {
        var a = vec::<*Type>();
        a.push_back(elem);
        var t = self.sc->lang_record(WellKnownType::Yield, &a);
        ICE_IF(t == &null, "IterLowering: the Yield lang item is unbound");
        return t;
    }

    // --- minting --------------------------------------------------------------------

    priv fn _local(self, pre: *ListBuilder::<*Stmt>, at: SourceRange, hint: string, ty: *Type, init: *Expr) -> *VariableDecl {
        var vd = self.synth.local(at, hint, ty, init);
        pre->push(static_cast::<*Stmt>(DeclStmt::create(self.ctx, at, static_cast::<*Decl>(vd))));
        return vd;
    }

    priv fn _use(self, vd: *VariableDecl, at: SourceRange) -> *Expr {
        return self.synth.use_of(vd, at, Expr::ValueCategory::LValue);
    }

    priv fn _bool(self)  -> *Type { return self.sc->builtin(BuiltinKind::Bool);  }
    priv fn _usize(self) -> *Type { return self.sc->builtin(BuiltinKind::USize); }

    priv fn _cmp(self, at: SourceRange, lhs: *Expr, rhs: *Expr, k: TokenKind) -> *Expr {
        var b = BinaryOperatorExpr::create(self.ctx, at, lhs, rhs, self.synth.punct(at, k));
        b->type_          = self._bool();
        b->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(b);
    }

    priv fn _arith(self, at: SourceRange, lhs: *Expr, rhs: *Expr, k: TokenKind, ty: *Type) -> *Expr {
        var b = BinaryOperatorExpr::create(self.ctx, at, lhs, rhs, self.synth.punct(at, k));
        b->type_          = ty;
        b->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(b);
    }

    priv fn _assign(self, at: SourceRange, lhs: *Expr, rhs: *Expr) -> *Expr {
        var a = AssignOperatorExpr::create(self.ctx, at, lhs, rhs, self.synth.punct(at, TokenKind::OpEqual));
        a->type_          = lhs->type_;
        a->value_category = Expr::ValueCategory::LValue;
        return static_cast::<*Expr>(a);
    }

    priv fn _preinc(self, e: *Expr) -> *Expr {
        var u = UnaryOperatorExpr::create(self.ctx, e->range, e, self.synth.punct(e->range, TokenKind::OpPlusPlus),
                                          UnaryOperatorExpr::Fix::Prefix);
        u->type_          = e->type_;
        u->value_category = Expr::ValueCategory::LValue;
        return static_cast::<*Expr>(u);
    }

    priv fn _deref(self, e: *Expr, ty: *Type) -> *Expr {
        var u = UnaryOperatorExpr::create(self.ctx, e->range, e, self.synth.punct(e->range, TokenKind::OpStar),
                                          UnaryOperatorExpr::Fix::Prefix);
        u->type_          = ty;
        u->value_category = Expr::ValueCategory::LValue;
        return static_cast::<*Expr>(u);
    }

    priv fn _subscript(self, at: SourceRange, base: *Expr, index: *Expr, ty: *Type) -> *Expr {
        var s = SubscriptExpr::create(self.ctx, at, base, index);
        s->type_          = ty;
        s->value_category = Expr::ValueCategory::LValue;
        return static_cast::<*Expr>(s);
    }

    priv fn _expr_stmt(self, e: *Expr) -> *Stmt {
        return static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, e->range, e));
    }

    priv fn _block(self, at: SourceRange, stmts: *ListBuilder::<*Stmt>) -> *CompoundStmt {
        var c = CompoundStmt::create(self.ctx, at);
        stmts->freeze_into(&(c->body));
        return c;
    }

    priv fn _while(self, at: SourceRange, cond: *Expr, body: *ListBuilder::<*Stmt>) -> *Stmt {
        return static_cast::<*Stmt>(WhileLoopStmt::create(self.ctx, at, cond, self._block(at, body)));
    }

    /// A slice literal bound to a local here lives to the end of the block,
    /// as one bound to a `var` does (LiteralTyping::mark_list_storage).
    priv fn _extend(self, e_in: *Expr) {
        var e = self.tu.strip_parens(e_in);
        if (e == &null) || (!isa::<ListLiteralExpr>(e)) { return; }
        var l = cast::<ListLiteralExpr>(e);
        if (l->type_ == &null) || (!self.tu.is_slice(l->type_)) { return; }
        l->storage = ListStorage::Extended;
        for var i: usize = 0; i < l->elements.size(); ++i { self._extend(l->elements[i]); }
    }
}

__inline_cpp("
#undef ASTWriter_IterLowering
");