/// --- The Kairo Project ---------------------- Sema/Lower/RangeLowering.k --- ///
///
///   \brief Every range that reaches here becomes the record X typed it as.
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
///     only ever such an index: X rejects one anywhere else.
///
///   Phase: LOWER, after IterLowering (which consumes ranges in loops) and
///   before SequenceLowering.
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
import AST::Node::Casting::*;
import AST::Node::CanonicalNodes::*;
import Location::SourceRange::*;

__inline_cpp("
#define ASTWriter_RangeLowering ASTWriter<RangeLowering>
");

class RangeLowering derives ASTWriter::<RangeLowering> {
    pub var sc: *SemaContext;
    priv var tu: TypeUtil;
    priv var synth: LowerSynth;

    fn RangeLowering(self, sc: *SemaContext) {
        self.sc    = sc;
        self.ctx   = sc->ctx;
        self.tu    = TypeUtil(sc);
        self.synth = LowerSynth(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked);
        if self.sc->tu == &null { return; }
        ASTWriter_RangeLowering::run(self.sc->tu);
    }

    fn transform_range_expr(self, n: *RangeExpr) -> *Expr {
        var out = ASTWriter_RangeLowering::transform_range_expr(n);
        if n->is_poisoned() || (n->type_ == &null) { return out; }
        ICE_IF(((n->begin == &null) || (n->end == &null)) && (!n->as_index),
               "RangeLowering: an open range outside a subscript index; ControlTyping::type_range must reject it");

        // Same shape rule as ControlTyping::type_range, which picked the type.
        var k = WellKnownType::Range;
        if n->end == &null        { k = WellKnownType::RangeFrom; }
        else if n->begin == &null { k = WellKnownType::RangeTo; }
        ICE_IF(self.sc->well_known->get(k) == &null, f"RangeLowering: the '{to_string(k)}' lang item is unbound");

        var at   = n->range;
        var init = NamedInitializerExpr::create(self.ctx, at, &null);
        var fields = self.list_builder::<InitField>();
        if n->begin != &null {
            fields.push(self._field(at, "begin", n->begin));
        } else if n->end == &null {
            // `..`: X typed it RangeFrom<usize>; it starts at the first index.
            fields.push(self._field(at, "begin", self.synth.int_literal(at, 0, BuiltinKind::USize)));
        }
        if n->end != &null {
            fields.push(self._field(at, "end",       n->end));
            fields.push(self._field(at, "inclusive", self.synth.bool_literal(at, n->is_inclusive)));
        }
        fields.freeze_into(&(init->fields));

        init->adopt_sema(static_cast::<*Expr>(n));
        init->type_          = n->type_;
        init->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(init);
    }

    priv fn _field(self, at: SourceRange, name: string, value: *Expr) -> InitField {
        var f = InitField{};
        f.name  = self.synth.ident(at, name);
        f.value = value;
        f.range = at;
        return f;
    }
}

__inline_cpp("
#undef ASTWriter_RangeLowering
");