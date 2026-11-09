/// --- The Kairo Project ----------------------------- Macro/Sentinel.k --- ///
///
///   MacroSentinel: reserved immediate values that mark builtin macros.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

pub enum MacroSentinel derives u32 {
    NoParent    = ((-1) as i32 as u32),
    Todo        = ((-2) as i32 as u32),
    Unreachable = ((-3) as i32 as u32),
    Include     = ((-4) as i32 as u32),
    EmbedStr    = ((-5) as i32 as u32),
    Embed       = ((-6) as i32 as u32),
    Poison      = ((-7) as i32 as u32),
    UnreachableUnchecked = ((-8) as i32 as u32),

    /// any imm >= Threshold is a sentinel, not an imm table index
    Threshold   = ((-16) as i32 as u32),
}
