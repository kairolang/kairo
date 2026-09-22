/// --- The Kairo Project ---------------- Sema/Lower/OperatorLowering.k --- ///
///
///   \brief Rewrite every user operator into the call it is.
///
///   \detail
///     `a + b` with a user `op +` is a call; the syntax is sugar. X resolved
///     which one (`resolved_op`, `op_via_free`) and this pass makes the tree
///     say so:
///
///       member  a + b        ->  a.op+(b)          ChainExpr(a, Operator step) called with [b]
///       free    2 * v        ->  op*(2, v)         NamedIdentExpr(op token) called with [2, v]
///       unary   -v           ->  v.op-()  /  op-(v)
///       assign  a += b       ->  a.op+=(b)
///       index   a[i]         ->  a.op[](i)
///       cast    x as T       ->  x.op as()         (`op as`; a converting ctor is CopyMoveLowering's)
///
///     A node with `resolved_op == null` is a builtin operator and is left
///     alone: EmitIR emits those as C++ operators on primitives. After this
///     pass no operator node has a record operand; EmitIR ICEs if one does.
///
///     The rewritten call carries the original node's sema facts (type,
///     value category, dependence) through adopt_sema; the Operator step
///     carries `resolved_decl` so codegen spells `operator+` from the decl,
///     never from the token.
///
///   \par Not here
///     `op in` (IterLowering), `??` (CoalesceLowering), `===` (identity, a
///     builtin), `..` (a RangeExpr), `^^` power (no C++ operator; a named
///     runtime call, TODO), postfix user `++`/`--` (C++ needs the `int` dummy;
///     TODO). Each ICEs with its owner's name if it arrives resolved.
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
import Sema::Resolve::NameLookup::*;
import AST::Visitor::ASTWriter::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Declarations::*;
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

    fn OperatorLowering(self, sc: *SemaContext) {
        self.sc  = sc;
        self.ctx = sc->ctx;
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked);
        if self.sc->tu == &null { return; }
        ASTWriter_OperatorLowering::run(self.sc->tu);
    }

    // --- the rewrites ---------------------------------------------------------

    fn transform_binary_operator_expr(self, n: *BinaryOperatorExpr) -> *Expr {
        var out = ASTWriter_OperatorLowering::transform_binary_operator_expr(n);
        // `^^` with no overload is the PRIMITIVE case: C++ has no such
        // operator, and there is no user decl to call instead, so it needs the
        // pow lang item rather than a rewrite. A `^^` that DID resolve is
        // spelled by CXXSpell::named_operator and falls through normally.
        ICE_IF((n->op_token.kind == TokenKind::OpCaretCaret) && (n->resolved_op == &null),
            "OperatorLowering: ^^ on primitives needs the pow lang item (well-known functions table); not written yet");
        if n->resolved_op == &null { return out; }
        var args = vec::<*Expr>();
        args.push_back(n->rhs);
        return self._call(static_cast::<*Expr>(n), n->lhs, n->op_token, n->resolved_op, n->op_via_free, &args);
    }

    fn transform_unary_operator_expr(self, n: *UnaryOperatorExpr) -> *Expr {
        var out = ASTWriter_OperatorLowering::transform_unary_operator_expr(n);
        if n->resolved_op == &null { return out; }
        // The NAME half of postfix is done -- CXXSpell::op_is_postfix drives the
        // `int` dummy on both emitters -- but the CALL half is not: it needs a
        // synthesized `0` argument, and a literal's `imm` must be an
        // Immediate::IntData entry. ASTContext::make_token interns an
        // IDENTIFIER, so the index it returns is the wrong table for
        // IntegerLiteralExpr::create. Minting an IntData entry from a lowering
        // pass is the missing piece.
        ICE_IF(self._is_postfix_op(cast::<FunctionDecl>(n->resolved_op)),
            "OperatorLowering: user postfix ++/-- needs a synthesized `0` argument; the writer cannot mint an Immediate::IntData entry yet");
        var args = vec::<*Expr>();
        return self._call(static_cast::<*Expr>(n), n->operand, n->op_token, n->resolved_op, n->op_via_free, &args);
    }

    fn transform_assign_operator_expr(self, n: *AssignOperatorExpr) -> *Expr {
        var out = ASTWriter_OperatorLowering::transform_assign_operator_expr(n);
        if n->resolved_op == &null { return out; }
        var args = vec::<*Expr>();
        args.push_back(n->rhs);
        return self._call(static_cast::<*Expr>(n), n->lhs, n->op_token, n->resolved_op, n->op_via_free, &args);
    }

    fn transform_subscript_expr(self, n: *SubscriptExpr) -> *Expr {
        var out = ASTWriter_OperatorLowering::transform_subscript_expr(n);
        if n->resolved_op == &null { return out; }
        // `op []` is two tokens; the receiver's own range anchors the step.
        var args = vec::<*Expr>();
        args.push_back(n->index);
        return self._call_tokens(static_cast::<*Expr>(n), n->base, self._bracket_tokens(n), n->resolved_op, n->op_via_free, &args);
    }

    fn transform_type_cast_expr(self, n: *TypeCastExpr) -> *Expr {
        var out = ASTWriter_OperatorLowering::transform_type_cast_expr(n);
        if n->resolved_ctor != &null { return self._ctor_cast(n); }
        if n->resolved_op == &null { return out; }
        var f = dyn_cast::<FunctionDecl>(n->resolved_op);
        ICE_IF(f == &null, "OperatorLowering: cast resolved to a non-function");
        ICE_IF(!f->is_operator, "OperatorLowering: a converting constructor arrives through resolved_ctor, not resolved_op");
        var args = vec::<*Expr>();
        return self._call_tokens(static_cast::<*Expr>(n), n->operand, f->op_token, n->resolved_op, false, &args);
    }

    /// `x as T` through a converting constructor -> `T(x)`. The callee names
    /// the ctor decl; EmitIR spells the TYPE from the call's own canonical.
    priv fn _ctor_cast(self, n: *TypeCastExpr) -> *Expr {
        var f = dyn_cast::<FunctionDecl>(n->resolved_ctor);
        ICE_IF(f == &null, "OperatorLowering: resolved_ctor is not a function");
        // Spelled through the decl's own context, interned into this file's.
        var c = NameLookup::ctx_of(static_cast::<*Decl>(f));
        if c == &null { c = self.ctx; }
        var t = Token();
        t.kind  = TokenKind::LitIdentifier;
        t.range = n->range;
        t.imm   = self.sc->imm_table()->intern_ident_copy(c->get_spelling(f->name));

        var head = NamedIdentExpr::create(self.ctx, n->range, t);
        head->resolved_decl = n->resolved_ctor;

        var call = CallExpr::create(self.ctx, n->range, static_cast::<*Expr>(head));
        var all  = self.list_builder::<*Expr>();
        all.push(n->operand);
        all.freeze_into(&(call->args));
        call->adopt_sema(static_cast::<*Expr>(n));
        return static_cast::<*Expr>(call);
    }

    /// `op r++` / `op r--`: the postfix form. CXXSpell::op_is_postfix is the
    /// codegen-side twin of this, and the duplication is deliberate -- Sema
    /// must not import Codegen, and one three-line fixity rule on each side of
    /// the boundary is cheaper than a shared layer invented to hold it.
    ///
    /// Spelled through the DECL'S OWN context: `op_token` carries per-fid imm
    /// indices, so reading it against this TU's context would give the
    /// interner's fallback text for an operator declared anywhere else.
    priv fn _is_postfix_op(self, f: *FunctionDecl) -> bool {
        if f == &null { return false; }
        if (!f->is_operator) || (f->op_token.size() != 2) { return false; }
        var c = NameLookup::ctx_of(static_cast::<*Decl>(f));
        if c == &null { c = self.ctx; }
        if c == &null { return false; }
        return c->get_spelling(f->op_token[0]) == "r";
    }

    // --- building the call ---------------------------------------------------------

    priv fn _call(self, orig: *Expr, recv: *Expr, _op: Token, decl: *Decl, via_free: bool,
                  args: *vec::<*Expr>) -> *Expr {
        var toks = self.list_builder::<Token>();
        toks.push(_op);
        var fl = create_empty_frozen_list::<Token>();
        toks.freeze_into(&fl);
        return self._call_tokens(orig, recv, fl, decl, via_free, args);
    }

    /// The call node. Member: `recv.op<toks>(args)`. Free: `op<toks>(recv, args)`.
    priv fn _call_tokens(self, orig: *Expr, recv: *Expr, op_toks: FrozenList::<Token>, decl: *Decl,
                         via_free: bool, args: *vec::<*Expr>) -> *Expr {
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
        return static_cast::<*Expr>(call);
    }

    /// `[` `]` as the operator's two tokens. SubscriptExpr keeps neither, so
    /// they are synthesized on the base's last byte and the node's last byte.
    priv fn _bracket_tokens(self, n: *SubscriptExpr) -> FrozenList::<Token> {
        var b = self.list_builder::<Token>();
        var l = Token();
        l.kind  = TokenKind::OpLSquare;
        l.range = SourceRange::from_bounds(n->base->range.end, u32(1));
        var r = Token();
        r.kind  = TokenKind::OpRSquare;
        r.range = SourceRange::from_bounds(n->range.end, u32(1));
        b.push(l);
        b.push(r);
        var fl = create_empty_frozen_list::<Token>();
        b.freeze_into(&fl);
        return fl;
    }

}

__inline_cpp("
#undef ASTWriter_OperatorLowering
");