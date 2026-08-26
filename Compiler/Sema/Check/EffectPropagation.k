/// --- The Kairo Project --------------- Sema/Check/EffectPropagation.k --- ///
///
///   \brief Infer the panic effect set of every function.
///
///   \detail
///     Panic is a checked effect with typed inferred sets, so a
///     function's set is the union of what its body raises and what its
///     callees raise. Fixed-point over the call graph; recursive cycles
///     converge by iterating to a stable set. PanicEffectChecking
///     verifies declared sets against what this pass infers, so this runs
///     first.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

class EffectPropagation {
    // TODO: implement EffectPropagation
}
