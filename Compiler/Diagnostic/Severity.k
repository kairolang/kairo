/// --- The Kairo Project ------------------------ Diagnostic/Severity.k --- ///
///
///   Diagnostic severity levels, used as the suffix component of a diagnostic ID.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// Severities are ordered by increasing impact: \c Ignored through \c Fatal.
/// The suffix character appended to a diagnostic ID corresponds to the first
/// letter of the severity name (e.g. \c E for \c Error, \c W for \c Warning).
///
/// \note \c Count is a sentinel not a valid severity.
pub enum DiagSeverity derives u8 {
    /// Diagnostic is suppressed entirely.
    Ignored,

    /// A remark informational, typically from optimization passes.
    Remark,

    /// Verbose-mode output, not shown in normal builds.
    Verbose,

    /// An attached note, always subordinate to a parent diagnostic.
    Note,

    /// Debug-only output, stripped in release builds.
    Debug,

    /// A recoverable warning compilation continues.
    Warning,

    /// A hard error compilation of the current unit fails.
    Error,

    /// An unrecoverable error the compiler must terminate immediately.
    Fatal,

    /// Sentinel total number of severities. Not a valid severity.
    Count,
}

/// The word every renderer prints for \p sev ("error", "note", ...);
/// "unknown" for \c Count.
pub fn diag_severity_name(sev: DiagSeverity) -> string {
    match sev {
        case DiagSeverity::Fatal {
            return "fatal"
        } case DiagSeverity::Error {
            return "error"
        } case DiagSeverity::Warning {
            return "warning"
        } case DiagSeverity::Note {
            return "note"
        } case DiagSeverity::Remark {
            return "remark"
        } case DiagSeverity::Debug {
            return "debug"
        } case DiagSeverity::Verbose {
            return "verbose"
        } case DiagSeverity::Ignored {
            return "ignored"
        } default {
            return "unknown"
        }
    }
}
