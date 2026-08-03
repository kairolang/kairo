/// --- The Kairo Project ----------------------- Sema/CaptureAnalysis.k --- ///
///
///   \brief Compute closure capture lists (free-variable analysis).
///
///   \detail
///     MUST run AFTER MatchLowering / FinallyLowering / MacroExpansion, since
///     those SYNTHESIZE closures (match->IIFE, finally->lambda). Decides
///     by-value vs by-ref capture per variable.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///
