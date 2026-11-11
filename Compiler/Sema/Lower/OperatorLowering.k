/// --- The Kairo Project ---------------- Sema/Lower/OperatorLowering.k --- ///
///
///   \brief Rewrite every user operator into the call it is.
///
///   \detail
///     `a + b` with a user `op +` is a call; the syntax is sugar.
///     ExprTyper resolved which one (`resolved_op`, `op_via_free`,
///     `op_rewrite`) and this pass makes the tree say so:
///
///       member   a + b       ->  a.op+(b)            ChainExpr(a, Operator step) called with [b]
///       free     2 * v       ->  op*(2, v)           NamedIdentExpr(op token) called with [2, v]
///       unary    -v          ->  v.op-()  /  op-(v)
///       postfix  x++         ->  x.op++(0)           the `int` dummy C++ needs, minted as an i32
///       contain  x in xs     ->  xs.op in(x)         the RIGHT operand is the receiver
///       index    a[i]        ->  a.op[](i)
///       cast     x as T      ->  x.op as()           (`op as`; a converting ctor is _ctor_cast)
///       `^^`     x ^^ n      ->  pow(x, n)           lang item
///
///     Derived operators (ExprTyper's op_rewrite):
///       a != b  from op ==   ->  !(a.op==(b))
///       a < b   from op <=>  ->  ((a.op<=>(b)) as i8) < 0     the original token, against 0
///
///     An ADT's `==` (tag_eq: the enum declares no `op ==`) binds no
///     operator. It compares the two values' variants, in whatever form the
///     layout keeps them (EnumLayoutQuery::same_variant):
///       a == b  on an ADT    ->  a's variant == b's variant     `!=` likewise
///
///     Compound assignment, one definition per pair:
///       a += b  with op +=   ->  a.op+=(b)
///       a += b  with op +    ->  a = a.op+(b)                  a evaluated once: an impure a
///                                                              is bound by address first
///       a + b   with op +=   ->  ({ var t = a; t.op+=(b); t as T&&; })
///
///     A node with `resolved_op == null` (and no tag_eq) is a builtin
///     operator and is left alone: EmitIR emits those as C++ operators on
///     primitives. `===` is also left alone: it is typed on nullables only
///     and the nullable trio lowers it. After this pass no operator node has
///     a record operand; EmitIR ICEs if one does.
///
///     A PANICKING operator arrives already a call: PanicLowering, which
///     runs first, rewrote it through lower_one to hold the call (a derived
///     form's inner one), and this pass meets a plain call.
///
///     The rewritten call carries the original node's sema facts through
///     adopt_sema, the Operator step carries `resolved_decl` so codegen
///     spells the operator from the decl, and `instance` carries a generic
///     free operator's registry entry so EmitIR spells its arguments.
///
///   Phase: LOWER
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

import AST::ASTSupport::{
    FrozenList,
    create_empty_frozen_list,
}
import AST::Context::InstantiationRegistry::InstanceEntry
import AST::DeclFacts::{
    decl_instantiated_from,
    decl_is_imported,
    decl_is_instance,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Stmt,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    builtin_info,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    EnumDecl,
    FnBodyKind,
    FunctionDecl,
    VariableDecl,
}
import AST::Node::Expressions::{
    AssignOperatorExpr, BinaryOperatorExpr, CallExpr, ImplicitBoundaryCastExpr,
    OpRewrite,          ParenExpr,          StmtExpr, SubscriptExpr,
    TypeCastExpr,       UnaryOperatorExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Statements::{
    CompoundStmt,
    DeclStmt,
    ExpressionStmt,
    ReturnStmt,
}
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    PointerType,
}
import AST::OperatorFacts::OperatorFacts
import AST::Visitor::ASTWriter::{
    ASTWriter,
    ListBuilder,
}
import Location::SourceRange::SourceRange
import Sema::Lower::EnumLayoutLowering::EnumLayoutQuery
import Sema::Lower::LowerSynth::LowerSynth
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::Substitution::Substitution
import Sema::Type::TypeUtil::TypeUtil
import Token::Token::Token
import Token::TokenKind::TokenKind

pub class OperatorLowering derives ASTWriter<OperatorLowering> {
    pub var  sc:    unsafe *SemaContext
    priv var synth: LowerSynth

    /// The place operator whose body is being rewritten, or null. A `return`
    /// inside one hands C++ the object, not its address: the decl still says
    /// `*T` (importers' X reads it), but CXXSpell declares it `T&`.
    priv var _place_fn: unsafe *FunctionDecl = &null

    /// lower_one's calls, in the order built: when set, each call
    /// _call_tokens builds is kept on `made`.
    priv var _record: bool                               = false
    pub var  made:    cxx::std::vector<unsafe *CallExpr>

    fn OperatorLowering(self) {
        self.sc  = &null
        self.ctx = &null
    }

    fn OperatorLowering(self, sc: unsafe *SemaContext) {
        self.sc    = sc
        self.ctx   = sc->ctx
        self.synth = LowerSynth(sc)
    }

    /// One operator node's rewrite with its operands as they stand, none of
    /// them walked; every call it builds is on `made` afterwards. For
    /// PanicLowering, which lowers a PANICKING operator ahead of this pass
    /// so it can hold the call itself -- the derived forms test the result
    /// of the inner call, not of the node -- and has already rewritten the
    /// operands with its own walk. The pass, run later, meets the calls
    /// this built as calls and leaves them. One instance serves a whole
    /// PanicLowering run: the names it mints stay unique within it.
    pub fn lower_one(self, e: unsafe *Expr) -> unsafe *Expr {
        self.made.clear()
        self._record = true
        var unsafe *out = e
        if isa<BinaryOperatorExpr>(e) {
            out = self._binary(cast<BinaryOperatorExpr>(e), e)
        } else if isa<UnaryOperatorExpr>(e) {
            out = self._unary(cast<UnaryOperatorExpr>(e), e)
        } else if isa<AssignOperatorExpr>(e) {
            out = self._assign(cast<AssignOperatorExpr>(e), e)
        } else if isa<SubscriptExpr>(e) {
            out = self._subscript(cast<SubscriptExpr>(e), e)
        }

        self._record = false
        return out
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked)
        if self.sc->tu == &null {
            return
        }

        ASTWriter<OperatorLowering>::run(self, self.sc->tu)
    }

    /// # the rewrites

    fn transform_function_decl(self, n: unsafe *FunctionDecl) -> cxx::std::vector<unsafe *Decl> {
        // Saved and restored, and reset for every decl: a local fn nested in a
        // place operator returns its own values, not a place.
        var unsafe *saved = self._place_fn
        self._place_fn = if (OperatorFacts::returns_place(n)) => (n) else => &null
        var out = ASTWriter<OperatorLowering>::transform_function_decl(self, n)
        if self._place_fn != &null && n->body_kind == FnBodyKind::Expr && n->body_expr != &null {
            n->body_expr = self._place_value(n->body_expr)
        }

        self._place_fn = saved
        return out
    }

    fn transform_return_stmt(self, n: unsafe *ReturnStmt) -> cxx::std::vector<unsafe *Stmt> {
        var out = ASTWriter<OperatorLowering>::transform_return_stmt(self, n)
        if self._place_fn != &null && n->value != &null && !n->value->is_poisoned() {
            n->value = self._place_value(n->value)
        }

        return out
    }

    /// `return &x` -> `return x`; `return p` -> `return *p`. Either way the
    /// C++ `T&` binds the object the Kairo `*T` pointed at.
    priv fn _place_value(self, v: unsafe *Expr) -> unsafe *Expr {
        var unsafe *inner = v
        while isa<ParenExpr>(inner) {
            inner = cast<ParenExpr>(inner)->inner
        }

        var unsafe *u = dyn_cast<UnaryOperatorExpr>(inner)
        if u != &null
            && u->resolved_op == &null
            && u->is_prefix()
            && u->op_token.kind == TokenKind::OpAmp {
            return u->operand // already an lvalue of T.
        }

        var unsafe *pt = canon_unqual(v->type_)
        if pt == &null || !isa<PointerType>(pt) {
            kairo::std::ice_fail("OperatorLowering: is_place accepted a non-pointer return")
        }

        var unsafe *d = UnaryOperatorExpr::create(
            self.ctx,
            v->range,
            v,
            self.synth.punct(v->range, TokenKind::OpStar),
            UnaryOperatorExpr::Fix::Prefix,
        )

        d->type_          = cast<PointerType>(pt)->pointee
        d->value_category = Expr::ValueCategory::LValue
        return d
    }

    fn transform_binary_operator_expr(self, n: unsafe *BinaryOperatorExpr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<OperatorLowering>::transform_binary_operator_expr(self, n)
        return self._binary(n, out)
    }

    priv fn _binary(self, n: unsafe *BinaryOperatorExpr, out: unsafe *Expr) -> unsafe *Expr {
        // Before the builtin test: a tag `==` binds no operator either.
        if n->tag_eq {
            return self._tag_eq(n)
        }

        if n->resolved_op == &null { // builtin (`===` is CoalesceLowering's, gone by now).
            return out
        }

        var unsafe *f   = self._fn(n->resolved_op)
        var        k    = n->op_token.kind
        var        args = cxx::std::vector<unsafe *Expr>()

        match n->op_rewrite {
            case OpRewrite::Not {
                return self._derived_ne(n, f)
            } case OpRewrite::Cmp {
                return self._derived_cmp(n, f)
            } default {
                0
            }
        }

        // `x in xs`: xs is the receiver, x the argument -- operands out of
        // source order, which the call records for SequenceLowering (C++
        // evaluates the receiver first; Kairo evaluates x first).
        if k == TokenKind::KwIn {
            args.push_back(n->lhs)
            var unsafe *c = self._call(
                n,
                n->rhs,
                n->op_token,
                f,
                n->op_via_free,
                unsafe &args,
                n->op_instance,
            )

            if isa<CallExpr>(c) {
                cast<CallExpr>(c)->recv_last = true
            }

            return c
        }

        // `a + b` from `op +=`: copy, mutate, yield. Guarded on the base:
        // `compound_of` is TkUnknown for `^^`, and so is op_kind of the pow
        // lang item, which carries no op_token.
        var ck = OperatorFacts::compound_of(k)
        if ck != TokenKind::TkUnknown && OperatorFacts::op_kind(f) == ck {
            return self._derived_sum(n, f)
        }

        args.push_back(n->rhs)
        return self._call(n, n->lhs, n->op_token, f, n->op_via_free, unsafe &args, n->op_instance)
    }

    fn transform_unary_operator_expr(self, n: unsafe *UnaryOperatorExpr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<OperatorLowering>::transform_unary_operator_expr(self, n)
        return self._unary(n, out)
    }

    priv fn _unary(self, n: unsafe *UnaryOperatorExpr, out: unsafe *Expr) -> unsafe *Expr {
        if n->resolved_op == &null {
            return out
        }

        var unsafe *f   = self._fn(n->resolved_op)
        var        args = cxx::std::vector<unsafe *Expr>()
        // C++ tells postfix from prefix by an `int` argument, `0` by
        // convention. Its type is i32: `int` on every target Kairo has.
        if OperatorFacts::is_postfix(f) {
            args.push_back(self.synth.int_literal(n->range, 0, BuiltinKind::I32))
        }

        return self._call(
            unsafe (n as unsafe *Expr),
            n->operand,
            n->op_token,
            f,
            n->op_via_free,
            unsafe &args,
            n->op_instance,
        )
    }

    fn transform_assign_operator_expr(self, n: unsafe *AssignOperatorExpr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<OperatorLowering>::transform_assign_operator_expr(self, n)
        return self._assign(n, out)
    }

    priv fn _assign(self, n: unsafe *AssignOperatorExpr, out: unsafe *Expr) -> unsafe *Expr {
        if n->resolved_op == &null {
            return out
        }

        var unsafe *f   = self._fn(n->resolved_op)
        var        args = cxx::std::vector<unsafe *Expr>()
        args.push_back(n->rhs)
        // The type declared this compound operator: a call.
        if OperatorFacts::op_kind(f) == n->op_token.kind {
            return self._call(
                n,
                n->lhs,
                n->op_token,
                f,
                n->op_via_free,
                unsafe &args,
                n->op_instance,
            )
        }

        // It declared the base operator: `a = a + b`.
        return self._compound_from_base(n, f)
    }

    fn transform_subscript_expr(self, n: unsafe *SubscriptExpr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<OperatorLowering>::transform_subscript_expr(self, n)
        return self._subscript(n, out)
    }

    priv fn _subscript(self, n: unsafe *SubscriptExpr, out: unsafe *Expr) -> unsafe *Expr {
        if n->resolved_op == &null {
            return out
        }

        // `op []` is two tokens; the receiver's own range anchors the step.
        var args = cxx::std::vector<unsafe *Expr>()
        args.push_back(n->index)
        // `a[i..j]` on an array resolved to Slice's `op []` (MemberTyping):
        // the receiver is the array's view, not the array, and an array has
        // no members to call. EmitIR spells the cast as the Slice over it.
        var unsafe *recv = n->base
        var        tu    = TypeUtil(self.sc)
        var unsafe *view = tu.array_view(recv->type_)
        if view != &null {
            var unsafe *c = ImplicitBoundaryCastExpr::create(
                self.ctx,
                recv->range,
                recv,
                recv->type_,
                view,
            )

            c->type_          = view
            c->value_category = Expr::ValueCategory::RValue
            recv              = c
        }

        return self._call_tokens(
            unsafe (n as unsafe *Expr),
            recv,
            self._bracket_tokens(n),
            n->resolved_op,
            n->op_via_free,
            args,
            n->op_instance,
        )
    }

    fn transform_type_cast_expr(self, n: unsafe *TypeCastExpr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<OperatorLowering>::transform_type_cast_expr(self, n)
        if n->enum_check != &null && out != &null && isa<TypeCastExpr>(out) {
            // The enum was recorded at typing: the cast's own type may be a
            // `Nullable<E>` record by now (NullableTypeLowering).
            var unsafe *oc = cast<TypeCastExpr>(out)
            var unsafe *en = dyn_cast<EnumDecl>(n->enum_check)
            oc->enum_check = &null // checked once: a later walk must not wrap it again.
            if en != &null {
                oc->operand = self._closed_enum_operand(n, en, oc->operand)
            }
        }

        if n->asserting_downcast && out != &null && isa<TypeCastExpr>(out) {
            var unsafe *oc = cast<TypeCastExpr>(out)
            oc->asserting_downcast = false // checked once, as enum_check.
            return self._asserting_downcast(oc)
        }

        if n->resolved_ctor != &null {
            return self._ctor_cast(n)
        }

        if n->resolved_op == &null {
            // An identity cast on a record value (`s as S`, SC031W) names no
            // ctor and no `op as`; EmitIR refuses a record operand it was not
            // handed a conversion for (I003E). The cast is a no-op that
            // yields the value, so the operand stands in for it.
            if out != &null && isa<TypeCastExpr>(out) {
                var unsafe *oc = cast<TypeCastExpr>(out)
                // A cast to a C++ reference is not an identity: lowering writes
                // `static_cast<T &&>(x)` to MOVE out of a nullable or a coalesce
                // temporary, and folding it copies a move-only value (CL001E).
                var is_ref = (oc->type_ != &null &&
                              (isa<CXXRValueRefType>(oc->type_) || isa<CXXLValueRefType>(oc->type_))) ||
                             (oc->target != &null &&
                              (isa<CXXRValueRefType>(oc->target) || isa<CXXLValueRefType>(oc->target)))
                if (!is_ref) && oc->operand != &null && oc->operand->type_ != &null && oc->type_ != &null {
                    var tu  = TypeUtil(self.sc)
                    var unsafe *st = canon_unqual(oc->operand->type_)
                    if st == canon_unqual(oc->type_) && tu.record_decl(st) != &null && !isa<PointerType>(st) {
                        return oc->operand
                    }
                }
            }

            return out
        }

        return self._op_cast(n)
    }

    /// `x as T` through the type's `op as` -> `x.op as()`.
    priv fn _op_cast(self, n: unsafe *TypeCastExpr) -> unsafe *Expr {
        var unsafe *f = self._fn(n->resolved_op)
        if !f->is_operator {
            kairo::std::ice_fail(
                "OperatorLowering: a converting constructor arrives through resolved_ctor, not resolved_op",
            )
        }

        var args = cxx::std::vector<unsafe *Expr>()
        var unsafe *call = self._call_tokens(
            unsafe (n as unsafe *Expr),
            n->operand,
            f->op_token,
            n->resolved_op,
            false,
            args,
            &null,
        )

        // A generic record's `op as -> T` is `operator T` in the template,
        // but a call through an instance has no T to name: the step carries
        // the target as the instance binds it, and EmitIR spells the
        // conversion-function-id from it (`wr.operator long()`, which C++
        // finds as `operator T` with T = long).
        var unsafe *rt = if (f->return_type != &null) => (f->return_type->canonical) else => &null
        if rt != &null && rt->is_dependent() && n->operand->type_ != &null && isa<CallExpr>(call) {
            var tu = TypeUtil(self.sc)
            var sb = Substitution(self.sc)
            sb.bind_from_record(tu.strip_nullable(canon_unqual(n->operand->type_)))
            var unsafe *cr = sb.substitute(rt)
            var unsafe *ch = dyn_cast<ChainExpr>(cast<CallExpr>(call)->callee)
            if cr != &null && !cr->is_dependent() && ch != &null && ch->steps.size() == 1 {
                ch->steps.get(0)->resolved_type = cr
            }
        }

        return call
    }

    /// # `as` into a closed enum

    /// The operand \p v of `v as E`, E a closed plain enum (CastTyping
    /// marked the cast: \p v is not a constant), checked against E's values
    /// before the plain cast reads it:
    ///
    ///   `({ var t = v; if <t is no value of E> { unwrap_failed(m, n) }  t }) as E`
    ///
    /// The test is on the integer, so a value clang can see folds it away:
    /// `t >= N` (and `t < 0` when signed) when the values are `0..N-1`, else
    /// one `t != value` per variant. A miss crashes -- the crash family, as
    /// a failed bounds check (Compiler/Spec/Panic.md#crashes-are-not-panics): no set, no `try` -- through
    /// the same write-and-abort entry `unwrap!` uses (the UnwrapFailed lang
    /// item), whose message is whatever the caller built.
    priv fn _closed_enum_operand(self,
                                 n:  unsafe *TypeCastExpr,
                                 en: unsafe *EnumDecl,
                                 v:  unsafe *Expr) -> unsafe *Expr {
        var tu = TypeUtil(self.sc)
        if en->is_adt || en->is_open || v == &null || v->type_ == &null {
            return v
        }

        var unsafe *ut = canon_unqual(tu.as_value(v->type_))
        var        uk  = tu.kind_of(ut)
        if uk == BuiltinKind::COUNT {
            return v
        }

        var at = n->range

        var count = (en->variants.size() as u64)
        var dense = true
        for var i: usize = 0; i < en->variants.size(); ++i {
            var unsafe *ev = en->variants[i]
            if ev == &null || !ev->value.ok { // a value that failed said so.
                return v
            }

            if ev->value.neg || ev->value.mag >= count {
                dense = false
            }
        }

        var        stmts              = self.list_builder<unsafe *Stmt>()
        var unsafe *t                 = self.synth.bind(at, "ecast", ut, v, unsafe &stmts)
        var        miss: unsafe *Expr = &null
        if dense {
            miss = self._cmp(
                at,
                self.synth.use_of(t, at, Expr::ValueCategory::LValue),
                self.synth.int_literal(at, count, uk),
                TokenKind::OpGreaterEqual,
            )

            if builtin_info(uk)->is_signed() {
                var unsafe *neg = self._cmp(
                    at,
                    self.synth.use_of(t, at, Expr::ValueCategory::LValue),
                    self.synth.int_literal(at, 0, uk),
                    TokenKind::OpLess,
                )

                miss = self._cmp(at, neg, miss, TokenKind::OpPipePipe)
            }
        } else {
            // The `&&` of every `t != value` is built as a balanced tree, not
            // a left-leaning chain: EmitIR parenthesises each operator, so a
            // chain over a registry-sized enum (thousands of variants) nests
            // that many brackets and clang stops at -fbracket-depth=2048.
            var terms = cxx::std::vector<unsafe *Expr>()
            for var i: usize = 0; i < en->variants.size(); ++i {
                var unsafe *ev  = en->variants[i]
                var unsafe *lit = self.synth.int_literal(at, ev->value.mag, uk)
                if ev->value.neg {
                    var unsafe *m = UnaryOperatorExpr::create(
                        self.ctx,
                        at,
                        lit,
                        self.synth.punct(at, TokenKind::OpMinus),
                        UnaryOperatorExpr::Fix::Prefix,
                    )

                    m->type_          = self.sc->builtin(uk)
                    m->value_category = Expr::ValueCategory::RValue
                    lit               = m
                }

                var unsafe *ne = self._cmp(
                    at,
                    self.synth.use_of(t, at, Expr::ValueCategory::LValue),
                    lit,
                    TokenKind::OpExclaimEqual,
                )

                terms.push_back(ne)
            }

            // A FIFO pairing: each pass over the queue halves what is left, so
            // the depth is log2(n).
            var head: usize = 0
            while terms.size() - head > 1 {
                var unsafe *a = terms[head]
                var unsafe *b = terms[head + 1]
                head += 2
                terms.push_back(self._cmp(at, a, b, TokenKind::OpAmpAmp))
            }

            if terms.size() - head == 1 {
                miss = terms[head]
            }
        }

        stmts.push(self._crash_if(n, en, miss))
        stmts.push(
            ExpressionStmt::create(
                self.ctx,
                at,
                self.synth.use_of(t, at, Expr::ValueCategory::LValue),
            ),
        )

        return self.synth.stmt_expr(v, &stmts, ut)
    }

    /// `p as *D`, the asserting downcast (Compiler/Spec/Panic.md#crashes-are-not-panics):
    ///
    ///   `({ var s = p; var d = s as *D [dynamic_only]; if s && !d { unwrap_failed(m, n) }  d })`
    ///
    /// The inner cast is C++'s `dynamic_cast<D*>`, a null pointer on a miss
    /// (EmitIR); a null `p` stays null, as C++'s own downcast keeps it. A
    /// miss crashes -- the crash family (§2.8): no set, no `try` -- through
    /// the same entry as `unwrap!`, with a message built here, whole: the
    /// cast as written, the static and target types, and the site.
    priv fn _asserting_downcast(self, n: unsafe *TypeCastExpr) -> unsafe *Expr {
        var        tu  = TypeUtil(self.sc)
        var        at  = n->range
        var unsafe *st = n->operand->type_
        var unsafe *dt = n->type_
        if st == &null || dt == &null {
            return unsafe (n as unsafe *Expr)
        }

        var        stmts = self.list_builder<unsafe *Stmt>()
        var unsafe *s    = self.synth.bind(at, "dcs", st, n->operand, unsafe &stmts)
        var unsafe *dc = TypeCastExpr::create(
            self.ctx,
            at,
            self.synth.use_of(s, at, Expr::ValueCategory::LValue),
            n->target,
            false,
            n->mode,
        )

        dc->type_          = dt
        dc->value_category = Expr::ValueCategory::RValue
        dc->dynamic_only   = true
        var unsafe *d = self.synth.bind(at, "dcd", dt, dc, unsafe &stmts)

        var unsafe *nd = UnaryOperatorExpr::create(
            self.ctx,
            at,
            self.synth.use_of(d, at, Expr::ValueCategory::LValue),
            self.synth.punct(at, TokenKind::OpExclaim),
            UnaryOperatorExpr::Fix::Prefix,
        )

        nd->type_          = self.sc->builtin(BuiltinKind::Bool)
        nd->value_category = Expr::ValueCategory::RValue
        var unsafe *miss = self._cmp(
            at,
            self.synth.use_of(s, at, Expr::ValueCategory::LValue),
            nd,
            TokenKind::OpAmpAmp,
        )

        var        full = self.ctx->sm->get_line_col(at.start)
        var unsafe *tp  = tu.pointee(dt)
        var        tn   = if (tp != &null) => (tu.str(tp)) else => tu.str(dt)
        var text = f"{self.ctx->get_spelling(at)}: the object is not a '{tn}' (static type '{tu.str(st)}') at {self.ctx->sm->get_filename(at.start)}:{full.line}:{full.column}"
        stmts.push(
            self.synth.crash_if(at, miss, self.synth.crash_call(at, text, "OperatorLowering")),
        )

        stmts.push(
            ExpressionStmt::create(
                self.ctx,
                at,
                self.synth.use_of(d, at, Expr::ValueCategory::LValue),
            ),
        )

        return self.synth.stmt_expr(unsafe (n as unsafe *Expr), &stmts, dt)
    }

    /// `l <op> r`, a builtin compare or logical operator, typed bool.
    priv fn _cmp(self,
                 at: SourceRange,
                 l:  unsafe *Expr,
                 r:  unsafe *Expr,
                 k:  TokenKind) -> unsafe *Expr {
        var unsafe *b = BinaryOperatorExpr::create(self.ctx, at, l, r, self.synth.punct(at, k))
        b->type_          = self.sc->builtin(BuiltinKind::Bool)
        b->value_category = Expr::ValueCategory::RValue
        return b
    }

    /// `if miss { unwrap_failed("<message>", <len>) }`: the message names
    /// the cast as written, the enum and where.
    priv fn _crash_if(self,
                      n:    unsafe *TypeCastExpr,
                      en:   unsafe *EnumDecl,
                      miss: unsafe *Expr) -> unsafe *Stmt {
        var at   = n->range
        var tu   = TypeUtil(self.sc)
        var full = self.ctx->sm->get_line_col(at.start)
        var nm   = tu.decl_name(unsafe (en as unsafe *Decl))
        var text = f"{self.ctx->get_spelling(at)}: the value is no variant of the closed enum '{nm}' at {self.ctx->sm->get_filename(at.start)}:{full.line}:{full.column}"
        return self.synth.crash_if(at, miss, self.synth.crash_call(at, text, "OperatorLowering"))
    }

    /// `x as T` through a converting constructor -> `T(x)`. The callee names
    /// the ctor decl; EmitIR spells the TYPE from the call's own canonical.
    priv fn _ctor_cast(self, n: unsafe *TypeCastExpr) -> unsafe *Expr {
        var unsafe *f = self._fn(n->resolved_ctor)
        // Spelled through the decl's own context, interned into this file's.
        var unsafe *c = NameLookup::ctx_of(unsafe (f as unsafe *Decl))
        if c == &null {
            c = self.ctx
        }

        var unsafe *head = NamedIdentExpr::create(
            self.ctx,
            n->range,
            self.synth.ident(n->range, c->get_spelling(f->name)),
        )

        head->resolved_decl = n->resolved_ctor

        var unsafe *call = CallExpr::create(self.ctx, n->range, head)
        var        all   = self.list_builder<unsafe *Expr>()
        all.push(n->operand)
        all.freeze_into(&call->args)
        call->adopt_sema(unsafe (n as unsafe *Expr))
        // It IS a constructor call, the fact X records on one it types
        // (CallExpr::ctor_decl): CallLowering and EmitIR then bind `self`
        // whatever the head's spelling. Recognised by name alone, a class
        // template instance's constructor was not (its owner is the
        // instance), and `Tag() as WT<i32>` ICEd as a call short of `self`.
        call->ctor_decl = n->resolved_ctor
        return call
    }

    /// # ADT `==`

    /// `a == b` on an ADT with no `op ==`: the two variants compared, `!=`
    /// likewise, under the written token. The query builds it from builtin
    /// compares, so the node is no operator call: no resolved_op and no
    /// tag_eq, nothing for this pass or EmitIR to rewrite. Each operand
    /// appears once, so it runs once; their order is C++'s, as for every
    /// primitive operator (SequenceLowering orders call arguments only). How
    /// the variant is read is the layout's (EnumLayoutQuery), never spelled
    /// here.
    priv fn _tag_eq(self, n: unsafe *BinaryOperatorExpr) -> unsafe *Expr {
        var        tu = TypeUtil(self.sc)
        var unsafe *d = tu.record_decl(tu.as_value(n->lhs->type_))
        if d == &null {
            kairo::std::ice_fail(
                "OperatorLowering: tag_eq on an operand that is no record; OperatorTyping gate failure",
            )
        }

        var unsafe *en = dyn_cast<EnumDecl>(tu.pattern_of(d))
        if en == &null || !en->is_adt {
            kairo::std::ice_fail(
                "OperatorLowering: tag_eq on an operand that is no ADT enum; OperatorTyping gate failure",
            )
        }

        var q = EnumLayoutQuery(self.sc)
        if !q.has_layout(en) {
            kairo::std::ice_fail(
                "OperatorLowering: tag_eq on an ADT with no layout; EnumLayoutLowering runs first",
            )
        }

        var unsafe *cmp = q.same_variant(n->range, n->lhs, n->rhs, en, n->op_token)
        cmp->adopt_sema(n)
        return cmp
    }

    /// # derived operators

    /// `a != b` -> `!(a.op==(b))`.
    priv fn _derived_ne(self,
                        n: unsafe *BinaryOperatorExpr,
                        f: unsafe *FunctionDecl) -> unsafe *Expr {
        var args = cxx::std::vector<unsafe *Expr>()
        args.push_back(n->rhs)
        var unsafe *eq = self._call(
            unsafe (n as unsafe *Expr),
            n->lhs,
            self.synth.punct(n->op_token.range, TokenKind::OpEqualEqual),
            f,
            n->op_via_free,
            unsafe &args,
            n->op_instance,
        )

        eq->type_ = self._ret(f) // bool, as OperatorSignatureCheck requires.
        var unsafe *no = UnaryOperatorExpr::create(
            self.ctx,
            n->range,
            eq,
            self.synth.punct(n->op_token.range, TokenKind::OpExclaim),
            UnaryOperatorExpr::Fix::Prefix,
        )

        no->adopt_sema(n)
        return no
    }

    /// `a < b` -> `((a.op<=>(b)) as i8) < 0`, the original token against 0
    /// (`==` / `!=` from `op <=>` as well).
    /// Ordering's discriminants are -1 / 0 / 1 (Lib/builtin/lang.k), so the
    /// comparison needs no variant spelled and no lookup here.
    priv fn _derived_cmp(self,
                         n: unsafe *BinaryOperatorExpr,
                         f: unsafe *FunctionDecl) -> unsafe *Expr {
        var args = cxx::std::vector<unsafe *Expr>()
        args.push_back(n->rhs)
        var unsafe *cmp = self._call(
            unsafe (n as unsafe *Expr),
            n->lhs,
            self.synth.punct(n->op_token.range, TokenKind::OpLessEqualGreater),
            f,
            n->op_via_free,
            unsafe &args,
            n->op_instance,
        )

        cmp->type_ = self._ret(f) // Ordering.
        // An imported `<=>` answers a C++ ordering (`std::strong_ordering`),
        // which converts to no integer (and its type may be a dependent member
        // alias, no record Sema can name): C++ itself compares it with a literal
        // 0, so it is left uncast against an int 0.
        var unsafe *rd = TypeUtil(self.sc).record_decl(cmp->type_)
        var kairo_ord = rd != &null
            && !decl_is_imported(rd)
            && (!decl_is_instance(rd) || !decl_is_imported(decl_instantiated_from(rd)))
        if !kairo_ord {
            var unsafe *izero = self.synth.int_literal(n->range, 0, BuiltinKind::I32)
            var unsafe *irel = BinaryOperatorExpr::create(
                self.ctx,
                n->range,
                cmp,
                izero,
                n->op_token,
            )

            irel->adopt_sema(n)
            return irel
        }

        var unsafe *_i8    = self.sc->builtin(BuiltinKind::I8)
        var unsafe *as_int = TypeCastExpr::create(self.ctx, n->range, cmp, _i8)
        as_int->type_          = _i8
        as_int->value_category = Expr::ValueCategory::RValue
        var unsafe *zero = self.synth.int_literal(n->range, 0, BuiltinKind::I8)
        var unsafe *rel  = BinaryOperatorExpr::create(self.ctx, n->range, as_int, zero, n->op_token)
        rel->adopt_sema(n)
        return rel
    }

    /// `a + b` from `op +=`:  `({ var t = a; t.op+=(b); t as T&&; })`.
    /// `var t = a` copies from an lvalue and elides from a temporary, which is
    /// what makes `a + b + c` copy `a` once. The move out is explicit: a
    /// statement expression copy-initializes its result from the last
    /// expression, and `t` is an lvalue.
    priv fn _derived_sum(self,
                         n: unsafe *BinaryOperatorExpr,
                         f: unsafe *FunctionDecl) -> unsafe *Expr {
        var unsafe *lt = canon_unqual(n->type_)
        if lt == &null {
            kairo::std::ice_fail(
                "OperatorLowering: derived `+` on an untyped node; ExprTyper gate failure",
            )
        }

        var unsafe *vd = self.synth.local(n->range, "sum", lt, n->lhs)

        var args = cxx::std::vector<unsafe *Expr>()
        args.push_back(n->rhs)
        var unsafe *mut = self._call(
            n,
            self.synth.use_of(vd, n->range, Expr::ValueCategory::LValue),
            self.synth.punct(n->op_token.range, OperatorFacts::compound_of(n->op_token.kind)),
            f,
            n->op_via_free,
            unsafe &args,
            n->op_instance,
        )

        mut->type_          = self._ret(f)
        mut->value_category = Expr::ValueCategory::RValue

        var unsafe *mv = TypeCastExpr::create(
            self.ctx,
            n->range,
            self.synth.use_of(vd, n->range, Expr::ValueCategory::LValue),
            self.sc->types->cxx_rref(lt),
        )

        mv->type_          = lt
        mv->value_category = Expr::ValueCategory::RValue

        var stmts = self.list_builder<unsafe *Stmt>()
        stmts.push(
            unsafe (DeclStmt::create(self.ctx, n->range, unsafe (vd as unsafe *Decl)) as unsafe *Stmt),
        )

        stmts.push(ExpressionStmt::create(self.ctx, n->range, mut))
        stmts.push(
            unsafe (ExpressionStmt::create(self.ctx, n->range, unsafe (mv as unsafe *Expr)) as unsafe *Stmt),
        )

        return self._stmt_expr(n, &stmts, lt)
    }

    /// `a += b` from `op +`:  `a = a.op+(b)`. An `a` with side effects is
    /// bound once by address: `({ var p = &a; *p = (*p).op+(b); })`.
    priv fn _compound_from_base(self,
                                n: unsafe *AssignOperatorExpr,
                                f: unsafe *FunctionDecl) -> unsafe *Expr {
        var unsafe *lt = canon_unqual(n->lhs->type_)
        if lt == &null {
            kairo::std::ice_fail(
                "OperatorLowering: compound assignment on an untyped left side; ExprTyper gate failure",
            )
        }

        var base_tok = self.synth.punct(
            n->op_token.range,
            OperatorFacts::compound_base(n->op_token.kind),
        )

        var eq_tok = self.synth.punct(n->op_token.range, TokenKind::OpEqual)
        var args   = cxx::std::vector<unsafe *Expr>()
        args.push_back(n->rhs)

        if LowerSynth::pure(n->lhs) {
            var unsafe *sum = self._call(
                unsafe (n as unsafe *Expr),
                n->lhs,
                base_tok,
                f,
                n->op_via_free,
                unsafe &args,
                n->op_instance,
            )

            sum->type_          = self._ret(f)
            sum->value_category = Expr::ValueCategory::RValue
            var unsafe *asg = AssignOperatorExpr::create(self.ctx, n->range, n->lhs, sum, eq_tok)
            asg->adopt_sema(n)
            return asg
        }

        var unsafe *pt = self.sc->types->pointer(lt)
        var unsafe *addr = UnaryOperatorExpr::create(
            self.ctx,
            n->lhs->range,
            n->lhs,
            self.synth.punct(n->lhs->range, TokenKind::OpAmp),
            UnaryOperatorExpr::Fix::Prefix,
        )

        addr->type_          = pt
        addr->value_category = Expr::ValueCategory::RValue
        var unsafe *vd = self.synth.local(n->range, "lhs", pt, unsafe (addr as unsafe *Expr))

        var unsafe *sum = self._call(
            unsafe (n as unsafe *Expr),
            self._deref(vd, n->range, lt),
            base_tok,
            f,
            n->op_via_free,
            unsafe &args,
            n->op_instance,
        )

        sum->type_          = self._ret(f)
        sum->value_category = Expr::ValueCategory::RValue
        var unsafe *asg = AssignOperatorExpr::create(
            self.ctx,
            n->range,
            self._deref(vd, n->range, lt),
            sum,
            eq_tok,
        )

        asg->adopt_sema(n)

        var stmts = self.list_builder<unsafe *Stmt>()
        stmts.push(
            unsafe (DeclStmt::create(self.ctx, n->range, unsafe (vd as unsafe *Decl)) as unsafe *Stmt),
        )

        stmts.push(
            unsafe (ExpressionStmt::create(self.ctx, n->range, unsafe (asg as unsafe *Expr)) as unsafe *Stmt),
        )

        return self._stmt_expr(unsafe (n as unsafe *Expr), &stmts, n->type_)
    }

    /// `*p`, an lvalue of \p lt, reading the pointer local \p vd.
    priv fn _deref(self,
                   vd: unsafe *VariableDecl,
                   at: SourceRange,
                   lt: unsafe *Type) -> unsafe *Expr {
        var unsafe *d = UnaryOperatorExpr::create(
            self.ctx,
            at,
            self.synth.use_of(vd, at, Expr::ValueCategory::LValue),
            self.synth.punct(at, TokenKind::OpStar),
            UnaryOperatorExpr::Fix::Prefix,
        )

        d->type_          = lt
        d->value_category = Expr::ValueCategory::LValue
        return d
    }

    priv fn _stmt_expr(self,
                       orig:  unsafe *Expr,
                       stmts: *ListBuilder<unsafe *Stmt>,
                       ty:    unsafe *Type) -> unsafe *Expr {
        var unsafe *body = CompoundStmt::create(self.ctx, orig->range)
        stmts->freeze_into(&body->body)
        var unsafe *se = StmtExpr::create(self.ctx, orig->range, body)
        se->adopt_sema(orig)
        se->type_          = ty
        se->value_category = Expr::ValueCategory::RValue
        return se
    }

    /// # building the call

    priv fn _fn(self, d: unsafe *Decl) -> unsafe *FunctionDecl {
        var unsafe *f = dyn_cast<FunctionDecl>(d)
        if f == &null {
            kairo::std::ice_fail("OperatorLowering: resolved_op is not a function")
        }

        return f
    }

    /// The call's declared result, read from the decl: a derived operator's
    /// node is typed as the DERIVED expression, not as the call it contains.
    priv fn _ret(self, f: unsafe *FunctionDecl) -> unsafe *Type {
        if f->is_noreturn {
            return self.sc->builtin(BuiltinKind::Never)
        }

        if f->return_type == &null {
            return self.sc->builtin(BuiltinKind::Void)
        }

        return f->return_type->canonical
    }

    priv fn _call(self,
                  orig:     unsafe *Expr,
                  recv:     unsafe *Expr,
                  _op:      Token,
                  f:        unsafe *FunctionDecl,
                  via_free: bool,
                  args:     unsafe *cxx::std::vector<unsafe *Expr>,
                  inst:     unsafe *InstanceEntry) -> unsafe *Expr {
        var toks = self.list_builder<Token>()
        toks.push(_op)
        var fl = create_empty_frozen_list<Token>()
        toks.freeze_into(&fl)
        return self._call_tokens(orig, recv, fl, unsafe (f as unsafe *Decl), via_free, *args, inst)
    }

    /// The call node. Member: `recv.op<toks>(args)`. Free: `op<toks>(recv, args)`.
    priv fn _call_tokens(self,
                         orig:       unsafe *Expr,
                         recv:       unsafe *Expr,
                         op_toks:    FrozenList<Token>,
                         decl:       unsafe *Decl,
                         via_free:   bool,
                         const args: cxx::std::vector<unsafe *Expr>,
                         inst:       unsafe *InstanceEntry) -> unsafe *Expr {
        var callee: unsafe *Expr = &null
        var all                  = self.list_builder<unsafe *Expr>()

        if via_free {
            // A free operator has no identifier; the head carries the first
            // op token for its span and the decl for its identity.
            if op_toks.size() == 0 {
                kairo::std::ice_fail("OperatorLowering: operator with no tokens")
            }

            var unsafe *head = NamedIdentExpr::create(self.ctx, op_toks[0].range, op_toks[0])
            head->resolved_decl = decl
            callee              = head
            all.push(recv)
        } else {
            var unsafe *chain = ChainExpr::create(self.ctx, recv->range, recv)
            var        steps  = self.list_builder<ChainExpr::Step>()
            var        st     = ChainExpr::Step()
            st.name          = &null
            st.target        = ChainExpr::StepTarget::Operator
            st.op_tokens     = op_toks
            st.range         = if (op_toks.size() > 0) => (op_toks[0].range) else => recv->range
            st.access_kind   = ChainExpr::AccessKind::Dot
            st.resolved_decl = decl
            st.resolved_type = &null // callable: no type of its own.
            steps.push(st)
            steps.freeze_into(&chain->steps)
            callee = chain
        }

        for var i: usize = 0; i < args.size(); ++i {
            all.push((args)[i])
        }

        var unsafe *call = CallExpr::create(self.ctx, orig->range, callee)
        all.freeze_into(&call->args)
        call->adopt_sema(orig) // type, value category, dependence, poison.
        call->instance = inst
        if self._record {
            self.made.push_back(call)
        }

        return call
    }

    /// `[` `]` as the operator's two tokens. SubscriptExpr keeps neither, so
    /// they are synthesized on the base's last byte and the node's last byte.
    priv fn _bracket_tokens(self, n: unsafe *SubscriptExpr) -> FrozenList<Token> {
        var b = self.list_builder<Token>()
        b.push(
            self.synth.punct(
                SourceRange::from_bounds(n->base->range.end, 1 as u32),
                TokenKind::OpLSquare,
            ),
        )

        b.push(
            self.synth.punct(
                SourceRange::from_bounds(n->range.end, 1 as u32),
                TokenKind::OpRSquare,
            ),
        )

        var fl = create_empty_frozen_list<Token>()
        b.freeze_into(&fl)
        return fl
    }
}
