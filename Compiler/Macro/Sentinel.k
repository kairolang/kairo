/// --- The Kairo Project ----------------------------- Macro/Sentinel.k --- ///
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

enum MacroSentinel derives u32 {
    NoParent    = static_cast::<u32>(-1),
    Todo        = static_cast::<u32>(-2),
    Unreachable = static_cast::<u32>(-3),
    Include     = static_cast::<u32>(-4),
    IncludeStr  = static_cast::<u32>(-5),
    Embed       = static_cast::<u32>(-6),

    /// any imm >= Threshold is a sentinel, not an imm table index
    Threshold   = static_cast::<u32>(-10)
}
