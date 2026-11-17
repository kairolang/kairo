/// --- The Kairo Project ------------------------ Diagnostic/Category.k --- ///
///
///   Diagnostic category codes, used as the first component of a diagnostic ID.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// Each category has a short alphabetic code that appears in the diagnostic ID
/// string: `S001E` means category `Syntax`, code `001`, severity `Error`.
///
/// **Note:** `Count` is a sentinel not a valid category.
pub enum DiagCategory derives u8 {
    /// Parser and lexer diagnostics. Code: `S`
    Syntax,

    /// Diagnostics not yet assigned to a category. Code: `U`
    ///
    /// **Warning:** This is a temporary fallback and should never appear in
    /// production diagnostics. All diagnostics must be triaged into a
    /// real category before stabilisation.
    Uncategorized,

    /// Code generation diagnostics. Code: `C`
    CodeGen,

    /// Memory model and allocation diagnostics. Code: `M`
    Memory,

    /// Name and symbol resolution diagnostics. Code: `R`
    Resolution,

    /// Linker diagnostics. Code: `L`
    Linker,

    /// Semantic analysis diagnostics. Code: `SC`
    Semantic,

    /// Portability diagnostics. Code: `P`
    Portability,

    /// Diagnostics originating from Clang during lowering to LLVM IR. Code: `CL`
    Lowering,

    /// Optimisation-pass diagnostics. Code: `OPT`
    Optimization,

    /// Internal compiler errors and assertions. Code: `I`
    Internal,

    /// Sentinel total number of categories. Not a valid category.
    Count,
}

/// The letters that start a code of `cat` (`SC` for Semantic, `OPT` for
/// Optimization); "" for `Count`.
pub fn diag_category_prefix(cat: DiagCategory) -> string {
    match cat {
        case DiagCategory::Syntax {
            return "S"
        } case DiagCategory::Uncategorized {
            return "U"
        } case DiagCategory::CodeGen {
            return "C"
        } case DiagCategory::Memory {
            return "M"
        } case DiagCategory::Resolution {
            return "R"
        } case DiagCategory::Linker {
            return "L"
        } case DiagCategory::Semantic {
            return "SC"
        } case DiagCategory::Portability {
            return "P"
        } case DiagCategory::Lowering {
            return "CL"
        } case DiagCategory::Optimization {
            return "OPT"
        } case DiagCategory::Internal {
            return "I"
        } default {
            return ""
        }
    }
}
