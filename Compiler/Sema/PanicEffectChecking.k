/// --- The Kairo Project ------------------- Sema/PanicEffectChecking.k --- ///
///
///   \brief Panic propagation / catch exhaustiveness (effect system).
///
///   \detail
///     Infer each fn's panic set from its body; verify try/catch discharges
///     every reachable error type or the fn is marked `panic`. Bare catch =
///     catch-all. `panic` + `!` is contradictory -> error. Runs AFTER
///     MacroExpansion (unwrap! adds panics), BEFORE PanicLowering.
///
///   Phase: CHECK
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

class PanicEffectChecking {
    // TODO: implement PanicEffectChecking
}
