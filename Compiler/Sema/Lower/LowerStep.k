/// --- The Kairo Project ---------------------- Sema/Lower/LowerStep.k --- ///
///
///   \brief The lowering schedule, as an order the passes check.
///
///   \detail
///     Sema::_stage_lowerings runs the lowerings in one fixed order, and
///     each pass's header says what it must come after and before. Those
///     sentences were the only enforcement: every pass gated on
///     `require_phase(Checked)` alone, so a pass moved up or down the list
///     ran on a tree it was not written for, and some of them ICE far from
///     the cause on a node a pass they now precede should have removed.
///
///     The enum below IS the order (declaration order is run order). Each
///     pass's `run()` names its own step (SemaContext::begin_lower), which
///     in a debug build ICEs unless the step just before it in this list is
///     the last one that started. So every pairwise "after X" / "before Y"
///     in the headers is checked by one comparison, and a pass added to the
///     schedule has to be added here, at its place. Sema::_stage_lowerings
///     closes the list (SemaContext::end_lowerings) so a pass dropped from
///     the schedule but left here is caught too.
///
///     Only the passes of _stage_lowerings. PatternCompilation, in this
///     directory, is a check (the last of the check stage), and
///     TypeQueryLowering is an empty stub no stage runs; the inference and
///     sweep that follow the lowerings (PurityInference, ParamPassInference,
///     EnumLayoutSweep) are not tree rewrites and keep their own gates.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

// No imports: SemaContext imports this, and every pass imports SemaContext.

/// One lowering of _stage_lowerings, in run order. `None` is "no lowering
/// has started"; the reasons for each position are the comments at its
/// call in Sema::_stage_lowerings and in the pass's own header.
pub enum LowerStep derives u8 {
    None,
    VariantInit,
    EnumLayout,
    ExprBody,
    WhereDispatch,
    FieldInit,
    CtorInit,
    CopyMove,
    Script,
    Panic,
    Finally,
    Tuple,
    Coalesce,
    NullTest,
    NarrowedAccess,
    NullableType,
    Operator,
    FString,
    Call,
    Iter,
    Range,
    Match,
    Label,
    Extension,
    Sequence,
    SequenceCheck,
    ListLiteral,
    String,
    /// end_lowerings ran: the tree is the one codegen renders.
    Done,
}
