/// --- The Kairo Project ---------------------- Sema/Expand/Evaluator.k --- ///
///
///   \brief Evaluate expressions required to be compile-time constants.
///
///   \detail
///     The evaluator itself, distinct from EvalLowering and
///     EvalUsageChecking which own the `eval` keyword. Consumers: array
///     sizes, tuple index bounds, enum discriminants, generic value
///     arguments, and static assertions. Reports the first non-constant
///     subexpression rather than the whole expression.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

class Evaluator {
    // TODO: implement Evaluator
}
