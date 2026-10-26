/// --- The Kairo Project -------------------- Sema/Lower/CoalesceLowering.k --- ///
///
///   \brief The nullable operators that choose a value become the
///          if-expressions NULLABLE.md §2 writes for them.
///
///   \detail
///     NULLABLE.md 2.4, §5 step 1:
///
///       x ?? y        ->  if x? => x else y
///
///     The expansion is built TYPED, in the exact shape the typer gives the
///     same code written by hand, so the passes after this one lower it
///     with no knowledge of where it came from:
///
///       - the test is a postfix `x?` (bool, no resolved_op) whose operand
///         is the nullable: `null_test_of` classifies it, NullTestLowering
///         makes it `!x.is_null()`;
///       - the read of `x` in the then-arm is MARKED narrowed (narrowed_from
///         holds the `T?`, the node is typed `T`), as NullnessFlow::
///         read_value marks a proven read: NarrowedAccessLowering makes it
///         `x.__value()`;
///       - the if-expression is typed as the operator was, which EmitIR
///         spells as `(c ? a : b)`, each arm converted to that type.
///
///     The operand appears twice in the expansion, so it must be evaluated
///     once (SequenceLowering's rule). A place (`x`, `o.cache`, `p->c`:
///     LowerSynth::pure) is simply read twice. Anything else (a call, a
///     moved value, a nested expansion) is bound first to a `__kairo_coalK`
///     local in a statement expression, and the then-arm MOVES the value out
///     of it: CopyMoveLowering ran before this pass and never saw the
///     local, and a copy there would duplicate a move-only payload or run
///     its destructor one time too many.
///
///   Phase: LOWER, immediately before NullTestLowering (Sema.k). Before it
///   and NarrowedAccessLowering, which lower the test and the marked read
///   it builds; before NullableTypeLowering, so every type it reads is still
///   a NullableType. After CopyMoveLowering, whose `x as T?&&` on a last use
///   it finds as a non-place operand and binds.
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
import Sema::Lower::LowerSynth::*;
import AST::Visitor::ASTWriter::*;
import AST::ASTSupport::*;
import AST::LangItems::*;
import AST::Node::Base::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import Location::SourceRange::*;
import Token::Token::*;
import Token::TokenKind::*;

/// The operand of an expansion, ready to be read twice: \p test is what the
/// null test asks, \p value the marked read for the then-arm. \p decl is the
/// local a non-place operand was bound to (null for a place), whose DeclStmt
/// the caller places in front of the expansion.
struct CoalesceOperand {
    var test:  *Expr          = &null;
    var value: *Expr          = &null;
    var decl:  *VariableDecl  = &null;
}

class CoalesceLowering derives ASTWriter::<CoalesceLowering> {
    pub var sc: *SemaContext;
    priv var synth: LowerSynth;
    priv var tu:    TypeUtil;

    fn CoalesceLowering(self, sc: *SemaContext) {
        self.sc    = sc;
        self.ctx   = sc->ctx;
        self.synth = LowerSynth(sc);
        self.tu    = TypeUtil(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked);
        if self.sc->tu == &null { return; }
        // No builtin root: no `T?` was typed, so there is nothing to expand.
        if self.sc->well_known->get(WellKnownType::Nullable) == &null { return; }
        ASTWriter::<CoalesceLowering>::run(self.sc->tu);
    }

    // --- `??` -------------------------------------------------------------------

    /// `x ?? y`, its operands lowered first (`a ?? b ?? c` is `a ?? (b ?? c)`,
    /// and `x?.m ?? y` holds an expansion of its own on the left).
    fn transform_binary_operator_expr(self, n: *BinaryOperatorExpr) -> *Expr {
        var out = ASTWriter::<CoalesceLowering>::transform_binary_operator_expr(n);
        if n->op_token.kind != TokenKind::OpQuestionQuestion { return out; }
        if n->is_poisoned() || (n->type_ == &null) || (n->resolved_op != &null) { return out; }
        var lt = n->lhs->type_;
        if (lt == &null) || (self.tu.nullable_inner(lt) == &null) {
            // SC065W: a left side that is never null is the value, and the
            // right side is never evaluated.
            if (lt != &null) && (!lt->is_dependent()) { return n->lhs; }
            return out;
        }
        var stmts = self.list_builder::<*Stmt>();
        var opd = self._operand(n->lhs, &stmts);
        var ie = self._select(n->range, opd.test, opd.value, n->rhs, n->type_);
        return self._wrap(static_cast::<*Expr>(n), opd, &stmts, ie);
    }

    // --- the shared pieces ------------------------------------------------------

    /// \p e, a nullable, made readable twice: a place is read again (a
    /// fresh node per use), anything else is bound to a local first.
    priv fn _operand(self, e: *Expr, stmts: *ListBuilder::<*Stmt>) -> CoalesceOperand {
        var out = CoalesceOperand{};
        var nt  = self.tu.as_value(e->type_);
        var inner = self.tu.nullable_inner(nt);
        var x = self.tu.strip_parens(e);
        if LowerSynth::pure(x) && (isa::<NamedIdentExpr>(x) || isa::<ChainExpr>(x)) {
            out.test  = x;
            out.value = self._marked_copy(x, nt, inner);
            return out;
        }
        var vd = self.synth.local(e->range, "coal", nt, e);
        stmts->push(static_cast::<*Stmt>(DeclStmt::create(self.ctx, e->range, static_cast::<*Decl>(vd))));
        out.decl = vd;
        out.test = self.synth.use_of(vd, e->range, Expr::ValueCategory::LValue);
        var use  = self._marked_copy(self.synth.use_of(vd, e->range, Expr::ValueCategory::LValue), nt, inner);
        // The local is this expansion's own: its value moves out.
        var mv = TypeCastExpr::create(self.ctx, e->range, use, self.sc->types->cxx_rref(canon_unqual(inner)));
        mv->type_          = canon_unqual(inner);
        mv->value_category = Expr::ValueCategory::RValue;
        out.value = static_cast::<*Expr>(mv);
        return out;
    }

    /// A NEW read of the place \p x (a name or a pure field path), marked
    /// as the nullness analysis marks a proven read: typed \p inner, its
    /// `T?` in narrowed_from (on the name, or on the chain's last step).
    priv fn _marked_copy(self, x: *Expr, nt: *Type, inner: *Type) -> *Expr {
        if isa::<NamedIdentExpr>(x) {
            var src = cast::<NamedIdentExpr>(x);
            var id  = NamedIdentExpr::create(self.ctx, x->range, src->name);
            id->resolved_decl  = src->resolved_decl;
            id->adopt_sema(x);
            id->narrowed_from  = nt;
            id->type_          = inner;
            id->value_category = Expr::ValueCategory::LValue;
            return static_cast::<*Expr>(id);
        }
        var c  = cast::<ChainExpr>(x);
        var base = c->base;
        if (base != &null) && isa::<NamedIdentExpr>(self.tu.strip_parens(base)) {
            base = self._copy_name(cast::<NamedIdentExpr>(self.tu.strip_parens(base)));
        }
        var cc = ChainExpr::create(self.ctx, x->range, base);
        var steps = ListBuilder::<ChainExpr::Step>(self.ctx);
        for var i: usize = 0; i < c->steps.size(); ++i {
            var st = *(c->steps.get(i));
            if i + 1 == c->steps.size() {
                st.narrowed_from = nt;
                st.resolved_type = inner;
            }
            steps.push(st);
        }
        steps.freeze_into(&(cc->steps));
        cc->variant_decl = c->variant_decl;
        var ce = static_cast::<*Expr>(cc);
        ce->adopt_sema(x);
        ce->type_          = inner;
        ce->value_category = Expr::ValueCategory::LValue;
        return ce;
    }

    /// One more node naming what \p n names.
    priv fn _copy_name(self, n: *NamedIdentExpr) -> *Expr {
        var id = NamedIdentExpr::create(self.ctx, n->range, n->name);
        id->resolved_decl = n->resolved_decl;
        id->narrowed_from = n->narrowed_from;
        var e = static_cast::<*Expr>(id);
        e->adopt_sema(static_cast::<*Expr>(n));
        return e;
    }

    /// `test?`: the null test NullTestLowering lowers, typed as the typer
    /// types it (bool, no user operator).
    priv fn _test(self, at: SourceRange, operand: *Expr) -> *Expr {
        var q = UnaryOperatorExpr::create(self.ctx, at, operand, self.synth.punct(at, TokenKind::OpQuestion),
                                          UnaryOperatorExpr::Fix::Postfix);
        q->type_          = self.sc->builtin(BuiltinKind::Bool);
        q->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(q);
    }

    /// `if test? => then else other`, typed \p ty.
    priv fn _select(self, at: SourceRange, test: *Expr, then: *Expr, other: *Expr, ty: *Type) -> *Expr {
        var ie = IfExpr::create(self.ctx, at, self._test(at, test), then, other);
        ie->type_          = ty;
        ie->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(ie);
    }

    /// \p e in place of \p orig: alone when the operand was a place, else
    /// after the local it was bound to, as a statement expression.
    priv fn _wrap(self, orig: *Expr, opd: CoalesceOperand, stmts: *ListBuilder::<*Stmt>, e: *Expr) -> *Expr {
        if opd.decl == &null {
            e->expr_flags = orig->expr_flags;
            return e;
        }
        stmts->push(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, orig->range, e)));
        return self.synth.stmt_expr(orig, stmts, e->type_);
    }
}
