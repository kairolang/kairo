/// --- The Kairo Project ----------------- Compiler/Sema/NullableNarrowing.k --- ///
///
///   \brief Flow-sensitive non-null narrowing for T?.
///
///   \detail
///     After `if x?` (and `if !x? { diverge }`), narrow x to non-null in the
///     guarded region. DROP the narrowing on: reassignment, move, mutable
///     borrow, or for field places like foo.data ANY call that takes the
///     receiver by mutable self. Stage 1: shallow, drop-on-doubt. Sound, not
///     complete. Analysis only; rewrite is NarrowedAccessLowering.
///
///   Phase: CHECK
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

class NullableNarrowing {
    // TODO: implement NullableNarrowing
}
