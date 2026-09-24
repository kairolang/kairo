/// --- The Kairo Project ---------------- Sema/Lower/OperatorLowering.k --- ///
///
///   \brief Rewrite every user operator into the call it is.
///
///   \detail
///     `a + b` with a user `op +` is a call; the syntax is sugar. X resolved
///     which one (`resolved_op`, `op_via_free`, `op_rewrite`) and this pass
///     makes the tree say so:
///
///       member   a + b       ->  a.op+(b)            ChainExpr(a, Operator step) called with [b]
///       free     2 * v       ->  op*(2, v)           NamedIdentExpr(op token) called with [2, v]
///       unary    -v          ->  v.op-()  /  op-(v)
///       postfix  x++         ->  x.op++(0)           the `int` dummy C++ needs, minted as an i32
///       contain  x in xs     ->  xs.op in(x)         the RIGHT operand is the receiver
///       index    a[i]        ->  a.op[](i)
///       cast     x as T      ->  x.op as()           (`op as`; a converting ctor is _ctor_cast)
///       `^^`     x ^^ n      ->  pow(x, n)           the lang item, a free operator to X
///
///     Derived operators (X's op_rewrite):
///       a != b  from op ==   ->  !(a.op==(b))
///       a < b   from op <=>  ->  ((a.op<=>(b)) as i8) < 0     the original token, against 0
///
///     Compound assignment, one definition per pair:
///       a += b  with op +=   ->  a.op+=(b)
///       a += b  with op +    ->  a = a.op+(b)                  a evaluated once: an impure a
///                                                              is bound by address first
///       a + b   with op +=   ->  ({ var t = a; t.op+=(b); t as T&&; })
///
///     A node with `resolved_op == null` is a builtin operator and is left
///     alone: EmitIR emits those as C++ operators on primitives. `===` is
///     also left alone: it is typed on nullables only and the nullable trio
///     lowers it. After this pass no operator node has a record operand;
///     EmitIR ICEs if one does.
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
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sema::SemaContext::*;
import AST::OperatorFacts::*;
import Sema::Resolve::NameLookup::*;
import Sema::Lower::LowerSynth::*;
import AST::Visitor::ASTWriter::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Kind::ExprKind::*;
import Token::Token::*;
import Token::TokenKind::*;
import Location::SourceRange::*;

__inline_cpp("
#define ASTWriter_OperatorLowering ASTWriter<OperatorLowering>
");

class OperatorLowering derives ASTWriter::<OperatorLowering> {
    pub var sc: *SemaContext;
    priv var synth: LowerSynth;

    fn OperatorLowering(self, sc: *SemaContext) {
        self.sc    = sc;
        self.ctx   = sc->ctx;
        self.synth = LowerSynth(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked);
        if self.sc->tu == &null { return; }
        ASTWriter_OperatorLowering::run(self.sc->tu);
    }

    // --- the rewrites ---------------------------------------------------------

    fn transform_binary_operator_expr(self, n: *BinaryOperatorExpr) -> *Expr {
        var out = ASTWriter_OperatorLowering::transform_binary_operator_expr(n);
        if n->resolved_op == &null { return out; }   // builtin, or `===` (the nullable trio's).
        var f = self._fn(n->resolved_op);
        var k = n->op_token.kind;
        var args = vec::<*Expr>();

        switch n->op_rewrite {
            case OpRewrite::Not { return self._derived_ne(n, f); }
            case OpRewrite::Cmp { return self._derived_cmp(n, f); }
            default { 0; }
        }

        // `x in xs`: xs is the receiver, x the argument.
        if k == TokenKind::KwIn {
            args.push_back(n->lhs);
            return self._call(static_cast::<*Expr>(n), n->rhs, n->op_token, f, n->op_via_free, &args, n->op_instance);
        }

        // `a + b` from `op +=`: copy, mutate, yield.
        if OperatorFacts::op_kind(f) == OperatorFacts::compound_of(k) { return self._derived_sum(n, f); }

        args.push_back(n->rhs);
        return self._call(static_cast::<*Expr>(n), n->lhs, n->op_token, f, n->op_via_free, &args, n->op_instance);
    }

    fn transform_unary_operator_expr(self, n: *UnaryOperatorExpr) -> *Expr {
        var out = ASTWriter_OperatorLowering::transform_unary_operator_expr(n);
        if n->resolved_op == &null { return out; }
        var f = self._fn(n->resolved_op);
        var args = vec::<*Expr>();
        // C++ tells postfix from prefix by an `int` argument, `0` by
        // convention. Its type is i32: `int` on every target Kairo has.
        if OperatorFacts::is_postfix(f) { args.push_back(self.synth.int_literal(n->range, 0, BuiltinKind::I32)); }
        return self._call(static_cast::<*Expr>(n), n->operand, n->op_token, f, n->op_via_free, &args, n->op_instance);
    }

    fn transform_assign_operator_expr(self, n: *AssignOperatorExpr) -> *Expr {
        var out = ASTWriter_OperatorLowering::transform_assign_operator_expr(n);
        if n->resolved_op == &null { return out; }
        var f = self._fn(n->resolved_op);
        var args = vec::<*Expr>();
        args.push_back(n->rhs);
        // The type declared this compound operator: a call.
        if OperatorFacts::op_kind(f) == n->op_token.kind {
            return self._call(static_cast::<*Expr>(n), n->lhs, n->op_token, f, n->op_via_free, &args, n->op_instance);
        }
        // It declared the base operator: `a = a + b`.
        return self._compound_from_base(n, f);
    }

    fn transform_subscript_expr(self, n: *SubscriptExpr) -> *Expr {
        var out = ASTWriter_OperatorLowering::transform_subscript_expr(n);
        if n->resolved_op == &null { return out; }
        // `op []` is two tokens; the receiver's own range anchors the step.
        var args = vec::<*Expr>();
        args.push_back(n->index);
        return self._call_tokens(static_cast::<*Expr>(n), n->base, self._bracket_tokens(n), n->resolved_op, n->op_via_free, &args, &null);
    }

    fn transform_type_cast_expr(self, n: *TypeCastExpr) -> *Expr {
        var out = ASTWriter_OperatorLowering::transform_type_cast_expr(n);
        if n->resolved_ctor != &null { return self._ctor_cast(n); }
        if n->resolved_op == &null { return out; }
        var f = self._fn(n->resolved_op);
        ICE_IF(!f->is_operator, "OperatorLowering: a converting constructor arrives through resolved_ctor, not resolved_op");
        var args = vec::<*Expr>();
        return self._call_tokens(static_cast::<*Expr>(n), n->operand, f->op_token, n->resolved_op, false, &args, &null);
    }

    /// `x as T` through a converting constructor -> `T(x)`. The callee names
    /// the ctor decl; EmitIR spells the TYPE from the call's own canonical.
    priv fn _ctor_cast(self, n: *TypeCastExpr) -> *Expr {
        var f = self._fn(n->resolved_ctor);
        // Spelled through the decl's own context, interned into this file's.
        var c = NameLookup::ctx_of(static_cast::<*Decl>(f));
        if c == &null { c = self.ctx; }
        var head = NamedIdentExpr::create(self.ctx, n->range, self.synth.ident(n->range, c->get_spelling(f->name)));
        head->resolved_decl = n->resolved_ctor;

        var call = CallExpr::create(self.ctx, n->range, static_cast::<*Expr>(head));
        var all  = self.list_builder::<*Expr>();
        all.push(n->operand);
        all.freeze_into(&(call->args));
        call->adopt_sema(static_cast::<*Expr>(n));
        return static_cast::<*Expr>(call);
    }

    // --- derived operators -------------------------------------------------------

    /// `a != b` -> `!(a.op==(b))`.
    priv fn _derived_ne(self, n: *BinaryOperatorExpr, f: *FunctionDecl) -> *Expr {
        var args = vec::<*Expr>();
        args.push_back(n->rhs);
        var eq = self._call(static_cast::<*Expr>(n), n->lhs, self.synth.punct(n->op_token.range, TokenKind::OpEqualEqual),
                            f, n->op_via_free, &args, n->op_instance);
        eq->type_ = self._ret(f);   // bool, as OperatorSignatureCheck requires.
        var no = UnaryOperatorExpr::create(self.ctx, n->range, eq, self.synth.punct(n->op_token.range, TokenKind::OpExclaim),
                                           UnaryOperatorExpr::Fix::Prefix);
        no->adopt_sema(static_cast::<*Expr>(n));
        return static_cast::<*Expr>(no);
    }

    /// `a < b` -> `((a.op<=>(b)) as i8) < 0`, the original token against 0.
    /// Ordering's discriminants are -1 / 0 / 1 (Lib/builtin/lang.k), so the
    /// comparison needs no variant spelled and no lookup here.
    priv fn _derived_cmp(self, n: *BinaryOperatorExpr, f: *FunctionDecl) -> *Expr {
        var args = vec::<*Expr>();
        args.push_back(n->rhs);
        var cmp = self._call(static_cast::<*Expr>(n), n->lhs, self.synth.punct(n->op_token.range, TokenKind::OpLessEqualGreater),
                             f, n->op_via_free, &args, n->op_instance);
        cmp->type_ = self._ret(f);   // Ordering.
        var _i8 = self.sc->builtin(BuiltinKind::I8);
        var as_int = TypeCastExpr::create(self.ctx, n->range, cmp, _i8);
        as_int->type_          = _i8;
        as_int->value_category = Expr::ValueCategory::RValue;
        var zero = self.synth.int_literal(n->range, 0, BuiltinKind::I8);
        var rel  = BinaryOperatorExpr::create(self.ctx, n->range, static_cast::<*Expr>(as_int), zero, n->op_token);
        rel->adopt_sema(static_cast::<*Expr>(n));
        return static_cast::<*Expr>(rel);
    }

    /// `a + b` from `op +=`:  `({ var t = a; t.op+=(b); t as T&&; })`.
    /// `var t = a` copies from an lvalue and elides from a temporary, which is
    /// what makes `a + b + c` copy `a` once. The move out is explicit: a
    /// statement expression copy-initializes its result from the last
    /// expression, and `t` is an lvalue.
    priv fn _derived_sum(self, n: *BinaryOperatorExpr, f: *FunctionDecl) -> *Expr {
        var lt = canon_unqual(n->type_);
        ICE_IF(lt == &null, "OperatorLowering: derived `+` on an untyped node; ExprTyper gate failure");
        var vd = self.synth.local(n->range, "sum", lt, n->lhs);

        var args = vec::<*Expr>();
        args.push_back(n->rhs);
        var mut = self._call(static_cast::<*Expr>(n), self.synth.use_of(vd, n->range, Expr::ValueCategory::LValue),
                             self.synth.punct(n->op_token.range, OperatorFacts::compound_of(n->op_token.kind)),
                             f, n->op_via_free, &args, n->op_instance);
        mut->type_          = self._ret(f);
        mut->value_category = Expr::ValueCategory::RValue;

        var mv = TypeCastExpr::create(self.ctx, n->range, self.synth.use_of(vd, n->range, Expr::ValueCategory::LValue),
                                      self.sc->types->cxx_rref(lt));
        mv->type_          = lt;
        mv->value_category = Expr::ValueCategory::RValue;

        var stmts = self.list_builder::<*Stmt>();
        stmts.push(static_cast::<*Stmt>(DeclStmt::create(self.ctx, n->range, static_cast::<*Decl>(vd))));
        stmts.push(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, n->range, mut)));
        stmts.push(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, n->range, static_cast::<*Expr>(mv))));
        return self._stmt_expr(static_cast::<*Expr>(n), &stmts, lt);
    }

    /// `a += b` from `op +`:  `a = a.op+(b)`. An `a` with side effects is
    /// bound once by address: `({ var p = &a; *p = (*p).op+(b); })`.
    priv fn _compound_from_base(self, n: *AssignOperatorExpr, f: *FunctionDecl) -> *Expr {
        var lt = canon_unqual(n->lhs->type_);
        ICE_IF(lt == &null, "OperatorLowering: compound assignment on an untyped left side; ExprTyper gate failure");
        var base_tok = self.synth.punct(n->op_token.range, OperatorFacts::compound_base(n->op_token.kind));
        var eq_tok   = self.synth.punct(n->op_token.range, TokenKind::OpEqual);
        var args = vec::<*Expr>();
        args.push_back(n->rhs);

        if LowerSynth::pure(n->lhs) {
            var sum = self._call(static_cast::<*Expr>(n), n->lhs, base_tok, f, n->op_via_free, &args, n->op_instance);
            sum->type_          = self._ret(f);
            sum->value_category = Expr::ValueCategory::RValue;
            var asg = AssignOperatorExpr::create(self.ctx, n->range, n->lhs, sum, eq_tok);
            asg->adopt_sema(static_cast::<*Expr>(n));
            return static_cast::<*Expr>(asg);
        }

        var pt   = self.sc->types->pointer(lt);
        var addr = UnaryOperatorExpr::create(self.ctx, n->lhs->range, n->lhs, self.synth.punct(n->lhs->range, TokenKind::OpAmp),
                                             UnaryOperatorExpr::Fix::Prefix);
        addr->type_          = pt;
        addr->value_category = Expr::ValueCategory::RValue;
        var vd = self.synth.local(n->range, "lhs", pt, static_cast::<*Expr>(addr));

        var sum = self._call(static_cast::<*Expr>(n), self._deref(vd, n->range, lt), base_tok, f, n->op_via_free, &args, n->op_instance);
        sum->type_          = self._ret(f);
        sum->value_category = Expr::ValueCategory::RValue;
        var asg = AssignOperatorExpr::create(self.ctx, n->range, self._deref(vd, n->range, lt), sum, eq_tok);
        asg->adopt_sema(static_cast::<*Expr>(n));

        var stmts = self.list_builder::<*Stmt>();
        stmts.push(static_cast::<*Stmt>(DeclStmt::create(self.ctx, n->range, static_cast::<*Decl>(vd))));
        stmts.push(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, n->range, static_cast::<*Expr>(asg))));
        return self._stmt_expr(static_cast::<*Expr>(n), &stmts, n->type_);
    }

    /// `*p`, an lvalue of \p lt, reading the pointer local \p vd.
    priv fn _deref(self, vd: *VariableDecl, at: SourceRange, lt: *Type) -> *Expr {
        var d = UnaryOperatorExpr::create(self.ctx, at, self.synth.use_of(vd, at, Expr::ValueCategory::LValue),
                                          self.synth.punct(at, TokenKind::OpStar), UnaryOperatorExpr::Fix::Prefix);
        d->type_          = lt;
        d->value_category = Expr::ValueCategory::LValue;
        return static_cast::<*Expr>(d);
    }

    priv fn _stmt_expr(self, orig: *Expr, stmts: *ListBuilder::<*Stmt>, ty: *Type) -> *Expr {
        var body = CompoundStmt::create(self.ctx, orig->range);
        stmts->freeze_into(&(body->body));
        var se = StmtExpr::create(self.ctx, orig->range, body);
        se->adopt_sema(orig);
        se->type_          = ty;
        se->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(se);
    }

    // --- building the call ---------------------------------------------------------

    priv fn _fn(self, d: *Decl) -> *FunctionDecl {
        var f = dyn_cast::<FunctionDecl>(d);
        ICE_IF(f == &null, "OperatorLowering: resolved_op is not a function");
        return f;
    }

    /// The call's declared result, read from the decl: a derived operator's
    /// node is typed as the DERIVED expression, not as the call it contains.
    priv fn _ret(self, f: *FunctionDecl) -> *Type {
        if f->is_noreturn { return self.sc->builtin(BuiltinKind::Never); }
        if f->return_type == &null { return self.sc->builtin(BuiltinKind::Void); }
        return f->return_type->canonical;
    }

    priv fn _call(self, orig: *Expr, recv: *Expr, _op: Token, f: *FunctionDecl, via_free: bool,
                  args: *vec::<*Expr>, inst: *void) -> *Expr {
        var toks = self.list_builder::<Token>();
        toks.push(_op);
        var fl = create_empty_frozen_list::<Token>();
        toks.freeze_into(&fl);
        return self._call_tokens(orig, recv, fl, static_cast::<*Decl>(f), via_free, args, inst);
    }

    /// The call node. Member: `recv.op<toks>(args)`. Free: `op<toks>(recv, args)`.
    priv fn _call_tokens(self, orig: *Expr, recv: *Expr, op_toks: FrozenList::<Token>, decl: *Decl,
                         via_free: bool, args: *vec::<*Expr>, inst: *void) -> *Expr {
        var callee: *Expr = &null;
        var all = self.list_builder::<*Expr>();

        if via_free {
            // A free operator has no identifier; the head carries the first
            // op token for its span and the decl for its identity.
            ICE_IF(op_toks.size() == 0, "OperatorLowering: operator with no tokens");
            var head = NamedIdentExpr::create(self.ctx, op_toks[0].range, op_toks[0]);
            head->resolved_decl = decl;
            callee = static_cast::<*Expr>(head);
            all.push(recv);
        } else {
            var chain = ChainExpr::create(self.ctx, recv->range, recv);
            var steps = self.list_builder::<ChainExpr::Step>();
            var st = ChainExpr::Step();
            st.name          = &null;
            st.target        = ChainExpr::StepTarget::Operator;
            st.op_tokens     = op_toks;
            st.range         = (op_toks[0].range) if (op_toks.size() > 0) else (recv->range);
            st.access_kind   = ChainExpr::AccessKind::Dot;
            st.resolved_decl = decl;
            st.resolved_type = &null;      // callable: no type of its own.
            steps.push(st);
            steps.freeze_into(&(chain->steps));
            callee = static_cast::<*Expr>(chain);
        }

        for var i: usize = 0; i < args->size(); ++i { all.push((*args)[i]); }

        var call = CallExpr::create(self.ctx, orig->range, callee);
        all.freeze_into(&(call->args));
        call->adopt_sema(orig);            // type, value category, dependence, poison.
        call->instance = inst;
        return static_cast::<*Expr>(call);
    }

    /// `[` `]` as the operator's two tokens. SubscriptExpr keeps neither, so
    /// they are synthesized on the base's last byte and the node's last byte.
    priv fn _bracket_tokens(self, n: *SubscriptExpr) -> FrozenList::<Token> {
        var b = self.list_builder::<Token>();
        b.push(self.synth.punct(SourceRange::from_bounds(n->base->range.end, u32(1)), TokenKind::OpLSquare));
        b.push(self.synth.punct(SourceRange::from_bounds(n->range.end, u32(1)), TokenKind::OpRSquare));
        var fl = create_empty_frozen_list::<Token>();
        b.freeze_into(&fl);
        return fl;
    }
}

__inline_cpp("
#undef ASTWriter_OperatorLowering
");