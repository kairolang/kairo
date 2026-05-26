///--- The Kairo Project ----------------------------------------------------///
///                                                                          ///
///   Part of the Kairo Project, under the Attribution 4.0 International     ///
///   license (CC BY 4.0).  You are allowed to use, modify, redistribute,    ///
///   and create derivative works, even for commercial purposes, provided    ///
///   that we give appropriate credit, and indicate if changes were made.    ///
///                                                                          ///
///   For more information on the license terms and requirements, please     ///
///     visit: https://creativecommons.org/licenses/by/4.0/                  ///
///                                                                          ///
///   SPDX-License-Identifier: Apache-2.0                                    ///
///   Copyright (c) 2026 The Kairo Project (Apache-2.0)                      ///
///                                                                          ///
///------------------------------------------------------------ KAIRO -------///

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
