/// --- The Kairo Project ------------------- Sema/Lower/RangeLowering.k --- ///
///
///   \brief Every range that reaches here becomes the record ExprTyper typed.
///
///   \detail
///     IterLowering consumed the ranges written as a loop's iterable. Every
///     other RangeExpr is built as an aggregate, by shape:
///
///       a..b, a..=b  ->  Range<T>{ .begin = a, .end = b, .inclusive = ... }
///       a..          ->  RangeFrom<T>{ .begin = a }
///       ..b, ..=b    ->  RangeTo<T>{ .end = b, .inclusive = ... }
///       ..           ->  RangeFrom<usize>{ .begin = 0 }
///
///     A designated initializer, not a constructor: C++ evaluates a braced
///     initializer's clauses left to right, so `f()..g()` runs `f` first with
///     no sequencing needed, and the records stay aggregates.
///
///     A subscript's range index is no special case. OperatorLowering ran
///     first and turned `a[r]` into `a.op[](r)`, so the range arrives here as
///     an ordinary call argument (still marked as_index). Open ranges are
///     only ever such an index: ExprTyper rejects one anywhere else.
///
///   Phase: LOWER, after IterLowering (which consumes ranges in loops) and
///   before SequenceLowering.
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
    LangMembers,
    WellKnownType,
    to_string,
}
import AST::Node::Base::Expr
import AST::Node::CanonicalNodes::BuiltinKind
import AST::Node::Expressions::{
    InitField,
    NamedInitializerExpr,
    RangeExpr,
}
import AST::Visitor::ASTWriter::ASTWriter
import Location::SourceRange::SourceRange
import Sema::Lower::LowerStep::LowerStep
import Sema::Lower::LowerSynth::LowerSynth
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::TypeUtil::TypeUtil

pub class RangeLowering derives ASTWriter<RangeLowering> {
    pub var  sc:    unsafe *SemaContext
    priv var tu:    TypeUtil
    priv var synth: LowerSynth

    fn RangeLowering(self, sc: unsafe *SemaContext) {
        self.sc    = sc
        self.ctx   = sc->ctx
        self.tu    = TypeUtil(sc)
        self.synth = LowerSynth(sc)
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked)
        self.sc->begin_lower(LowerStep::Range)
        if self.sc->tu == &null {
            return
        }

        ASTWriter<RangeLowering>::run(self, self.sc->tu)
    }

    fn transform_range_expr(self, n: unsafe *RangeExpr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<RangeLowering>::transform_range_expr(self, n)
        if n->is_poisoned() || n->type_ == &null {
            return out
        }

        if (n->begin == &null || n->end == &null) && !n->as_index {
            kairo::std::ice_fail(
                "RangeLowering: an open range outside a subscript index; ControlTyping::type_range must reject it",
            )
        }

        // Same shape rule as ControlTyping::type_range, which picked the type.
        var k = WellKnownType::Range
        if n->end == &null {
            k = WellKnownType::RangeFrom
        } else if n->begin == &null {
            k = WellKnownType::RangeTo
        }

        if self.sc->well_known->get(k) == &null {
            kairo::std::ice_fail(f"RangeLowering: the '{to_string(k)}' lang item is unbound")
        }

        var        at     = n->range
        var unsafe *init  = NamedInitializerExpr::create(self.ctx, at, &null)
        var        fields = self.list_builder<InitField>()
        if n->begin != &null {
            fields.push(self._field(at, LangMembers::range_begin(), n->begin))
        } else if n->end == &null {
            // `..`: X typed it RangeFrom<usize>; it starts at the first index.
            fields.push(
                self._field(
                    at,
                    LangMembers::range_begin(),
                    self.synth.int_literal(at, 0, BuiltinKind::USize),
                ),
            )
        }

        if n->end != &null {
            fields.push(self._field(at, LangMembers::range_end(), n->end))
            fields.push(
                self._field(
                    at,
                    LangMembers::range_inclusive(),
                    self.synth.bool_literal(at, n->is_inclusive),
                ),
            )
        }

        fields.freeze_into(&init->fields)

        init->adopt_sema(unsafe (n as unsafe *Expr))
        init->type_          = n->type_
        init->value_category = Expr::ValueCategory::RValue
        return init
    }

    priv fn _field(self, at: SourceRange, const name: string, value: unsafe *Expr) -> InitField {
        var f = InitField{}
        f.name  = self.synth.ident(at, name)
        f.value = value
        f.range = at
        return f
    }
}
