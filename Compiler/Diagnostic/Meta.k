/// --- The Kairo Project ---------------------------- Diagnostic/Meta.k --- ///
///
///   Diagnostic metadata and ID string formatting.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"

import Diagnostic::Category::{
    DiagCategory,
    diag_category_prefix,
}
import Diagnostic::Severity::DiagSeverity

/// Static metadata for a single diagnostic entry.
///
/// Stored in the diagnostic registry and cached inside `DiagCode`.
/// `hash` is the registry's `DiagID` value for the code. Equality and
/// the lexicographic order are over category -> severity -> number, the
/// same as `DiagCode`'s.
///
/// The `as` string conversion produces the canonical diagnostic ID string:
///
/// ### Example
/// ```kairo
/// SC(41, DiagSeverity::Error) -> "SC041E"
/// ```
///
/// Category codes: S, U, C, M, R, L, SC, P, CL, OPT, I.
/// Severity suffixes: E, W, N, I, R, V, D, F.
/// The numeric component is always zero-padded to three digits.
pub struct DiagMeta {
    pub var brief:    string       ///< Short human-readable description.
    pub var group:    string       ///< Suppression group name, e.g. \c "unused-variable".
    pub var number:   u32          ///< Three-digit diagnostic number, e.g. 041.
    pub var hash:     u32          ///< Unique ID encoding category - number - severity.
    pub var category: DiagCategory
    pub var severity: DiagSeverity

    /// # Comparisons

    /// Equality and order are over (category, severity, number). `hash`
    /// does not take part: a severity override keeps the original hash
    /// (DiagEngine::_override_severity), so two metas with one hash can
    /// differ in severity.
    fn op == (const self, const other: DiagMeta) -> bool {
        return self.category == other.category
            && self.severity == other.severity
            && self.number == other.number
    }

    fn op != (const self, const other: DiagMeta) -> bool {
        return !(self == other)
    }

    /// Lexicographic: category, then severity, then number.
    fn op <  (const self, const other: DiagMeta) -> bool {
        if self.category != other.category {
            return (self.category as u8) < (other.category as u8)
        }

        if self.severity != other.severity {
            return (self.severity as u8) < (other.severity as u8)
        }

        return self.number < other.number
    }

    fn op >  (const self, const other: DiagMeta) -> bool {
        return other < self
    }

    fn op <= (const self, const other: DiagMeta) -> bool {
        return !(other < self)
    }

    fn op >= (const self, const other: DiagMeta) -> bool {
        return !(self < other)
    }

    /// # Conversions

    /// Formats the metadata as a diagnostic ID string, e.g. `"SC041E"`.
    fn op as (const self) -> string {
        var out = diag_category_prefix(self.category)
        if out.is_empty() {
            kairo::std::ice_fail("invalid diag category")
        }

        // The number is at least three digits, zero-padded.
        if self.number < 10 {
            out += f"00{(self.number)}"
        } else if self.number < 100 {
            out += f"0{(self.number)}"
        } else {
            out += f"{(self.number)}"
        }

        match self.severity {
            case DiagSeverity::Error {
                out += "E"
            } case DiagSeverity::Warning {
                out += "W"
            } case DiagSeverity::Note {
                out += "N"
            } case DiagSeverity::Ignored {
                out += "I"
            } case DiagSeverity::Remark {
                out += "R"
            } case DiagSeverity::Verbose {
                out += "V"
            } case DiagSeverity::Debug {
                out += "D"
            } case DiagSeverity::Fatal {
                out += "F"
            } default {
                kairo::std::ice_fail("invalid diag severity")
            }
        }

        return out
    }
}

extend DiagMeta {
    pub fn copy(const self) -> DiagMeta {
        return DiagMeta {
            brief:    self.brief.copy(),
            group:    self.group.copy(),
            number:   self.number,
            hash:     self.hash,
            category: self.category,
            severity: self.severity,
        }
    }
}
