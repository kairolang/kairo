/// --- The Kairo Project ----------------- Compiler/Sema/PanicLowering.k --- ///
///
///   \brief Lower panic into tagged return values.
///
///   \detail
///     A `panic` fn returns a tagged union {value | error+loc}. `panic X` ->
///     tagged-error return; try/catch -> branch on tag. Zero-cost, no unwinding.
///     Runs AFTER PanicEffectChecking.
///
///   Phase: LOWER
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

class PanicLowering {
    // TODO: implement PanicLowering
}
