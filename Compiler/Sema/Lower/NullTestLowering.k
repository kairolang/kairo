/// --- The Kairo Project ---------------- Sema/Lower/NullTestLowering.k --- ///
///
///   \brief Every null test becomes a call of the Nullable's `is_null()`.
///
///   \detail
///     Compiler/Spec/Nullables.md#null-test, 2.2, §5 step 2. Each spelling `null_test_of`
///     (Sema/Type/NullnessFlow.k) recognises lowers by its polarity:
///
///       x?   x != null   null != x   !(x == null)   ->  !x.is_null()
///       !x?  x == null   null == x                   ->  x.is_null()
///
///     The tree is classified, never pattern-matched here: the spellings
///     live in one place, the same one the flow analysis narrows through,
///     so a test cannot lower one way and narrow another. Only the outer
///     level is tested: on a `(T?)?` it asks the outer nullable.
///
///     `is_null()` is one of the members EnumLayoutLowering mints on the
///     Nullable lang item's layout (AdtRole::IsNull) and InterfaceEmitter
///     writes in C++; it is found on the pattern's layout by role (an
///     instance shares the pattern's layout), and called through LowerSynth::member_call, so EmitIR spells
///     `x.is_null()` like any member call. The operand is evaluated once, as
///     it was written once. The `null` literal a comparison held is dropped
///     with the comparison, so NullableTypeLowering never sees it.
///
///   Phase: LOWER, after TupleLowering and immediately before
///   NullableTypeLowering (Sema.k). Before NullableTypeLowering: it needs
///   `NullableType` on the operand to classify, and the `null` it drops
///   would otherwise become a VariantInitExpr first. Before
///   OperatorLowering: a `x == null` left in place has a record operand
///   once the literal is lowered, which OperatorLowering does not rewrite
///   and EmitIR ICEs on ("user operator").
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

import AST::LangItems::{
    LowerTargets,
    WellKnownType,
}
import AST::Node::Base::Expr
import AST::Node::CanonicalNodes::BuiltinKind
import AST::Node::Declarations::{
    AdtRole,
    FunctionDecl,
}
import AST::Node::Expressions::{
    BinaryOperatorExpr,
    UnaryOperatorExpr,
}
import AST::Visitor::ASTWriter::ASTWriter
import Sema::Lower::LowerStep::LowerStep
import Sema::Lower::LowerSynth::LowerSynth
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::NullnessFlow::{
    NullTest,
    null_test_of,
}
import Token::TokenKind::TokenKind

pub class NullTestLowering derives ASTWriter<NullTestLowering> {
    pub var  sc:       unsafe *SemaContext
    priv var synth:    LowerSynth
    priv var _is_null: unsafe *FunctionDecl = &null ///< the layout's AdtRole::IsNull member.

    fn NullTestLowering(self, sc: unsafe *SemaContext) {
        self.sc    = sc
        self.ctx   = sc->ctx
        self.synth = LowerSynth(sc)
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked)
        self.sc->begin_lower(LowerStep::NullTest)
        if self.sc->tu == &null {
            return
        }

        // No builtin root: no `T?` was typed, so there is no test to lower.
        if !self.sc->well_known->has(WellKnownType::Nullable) {
            return
        }

        self._is_null = self.sc->nullable_member(
            AdtRole::IsNull,
            "NullTestLowering",
        )

        if self._is_null == &null {
            kairo::std::ice_fail(
                "NullTestLowering: the Nullable layout has no " + LowerTargets::nullable_is_null() + "(); EnumLayoutLowering::_nullable_surface mints it",
            )
        }

        ASTWriter<NullTestLowering>::run(self, self.sc->tu)
    }

    /// # the rewrites

    /// `x?`, and `!` over any null test (`!x?`, `!(x == null)`): classified
    /// whole BEFORE the children are visited, so the outer `!` folds into
    /// the polarity instead of leaving `!!x.is_null()`.
    fn transform_unary_operator_expr(self, n: unsafe *UnaryOperatorExpr) -> unsafe *Expr {
        var t = null_test_of(unsafe (n as unsafe *Expr))
        if t.operand != &null {
            return self._lower(unsafe (n as unsafe *Expr), t)
        }

        return ASTWriter<NullTestLowering>::transform_unary_operator_expr(
            self,
            n,
        )
    }

    /// `x == null`, `null == x`, `x != null`, `null != x`.
    fn transform_binary_operator_expr(self, n: unsafe *BinaryOperatorExpr) -> unsafe *Expr {
        var t = null_test_of(unsafe (n as unsafe *Expr))
        if t.operand != &null {
            return self._lower(unsafe (n as unsafe *Expr), t)
        }

        return ASTWriter<NullTestLowering>::transform_binary_operator_expr(
            self,
            n,
        )
    }

    /// \p n, the test \p t classified, as `x.is_null()` or `!x.is_null()`.
    /// The operand is lowered first: it may hold a test of its own
    /// (`f(a?)?`).
    priv fn _lower(self, n: unsafe *Expr, t: NullTest) -> unsafe *Expr {
        if n->is_poisoned() {
            return n
        }

        var unsafe *operand = self.dyn()->transform_expr(t.operand)
        var unsafe *_bool   = self.sc->builtin(BuiltinKind::Bool)
        var        args     = self.list_builder<unsafe *Expr>()
        var unsafe *call = self.synth.member_call(
            n->range,
            operand,
            self._is_null,
            &args,
            _bool,
        )

        if !t.present {
            call->adopt_sema(n)
            call->type_          = _bool
            call->value_category = Expr::ValueCategory::RValue
            return call
        }

        var unsafe *no = UnaryOperatorExpr::create(
            self.ctx,
            n->range,
            call,
            self.synth.punct(n->range, TokenKind::OpExclaim),
            UnaryOperatorExpr::Fix::Prefix,
        )

        no->adopt_sema(n)
        no->type_          = _bool
        no->value_category = Expr::ValueCategory::RValue
        return no
    }
}
