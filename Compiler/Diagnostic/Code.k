/// --- The Kairo Project ---------------------------- Diagnostic/Code.k --- ///
///
///   Resolved diagnostic code handle.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Diagnostic::Category::DiagCategory
import Diagnostic::Meta::DiagMeta
import Diagnostic::Registry::{
    DiagID,
    diag_explain,
    diag_from_string,
    diag_meta,
}
import Diagnostic::Severity::DiagSeverity

/// A resolved diagnostic code, pairing a \c DiagID with its cached \c DiagMeta.
///
/// \c DiagCode is the primary handle passed through the diagnostic pipeline.
/// It is cheap to copy \c DiagMeta is a small struct and avoids repeated
/// registry lookups after construction.
///
/// Ordering follows category -> severity -> number, matching the sort order
/// used in diagnostic output and suppression tables.
pub class DiagCode {
    var _meta: DiagMeta
    var _id:   DiagID   ///< e.g. SC(41, DiagSeverity::Error) -> DiagID::SC041E

    /// # Constructors

    /// Constructs an invalid \c DiagCode. All fields are zeroed / \c Invalid.
    fn DiagCode(self) {
        self._id   = DiagID::Invalid
        self._meta = diag_meta(DiagID::Invalid)
    }

    /// Constructs from a \c DiagID, resolving metadata via the registry.
    pub fn DiagCode(self, _id: DiagID) {
        self._id   = _id
        self._meta = diag_meta(_id)
    }

    /// Constructs from pre-resolved \c DiagMeta. The \c DiagID is recovered
    /// from \c meta.hash.
    fn DiagCode(self, const _meta: DiagMeta) {
        self._meta = _meta
        self._id   = (_meta.hash as DiagID)
    }

    /// # Accessors

    fn id(self) -> DiagID {
        return self._id
    }

    fn meta(self) -> DiagMeta {
        return self._meta
    }

    pub fn category(const self) -> DiagCategory {
        return self._meta.category
    }

    pub fn severity(const self) -> DiagSeverity {
        return self._meta.severity
    }

    pub fn number(const self) -> u32 {
        return self._meta.number
    }

    fn hash(const self) -> u32 {
        return self._meta.hash
    }

    fn brief(self) -> string {
        return self._meta.brief
    }

    fn group(self) -> string {
        return self._meta.group
    }

    /// # Conversions

    /// Formats the code as a diagnostic ID string, e.g. \c "SC041E".
    pub fn op as (self) -> string {
        return self._meta as string
    }

    fn op as (self) -> DiagID {
        return self._id
    }

    /// # Comparisons

    /// Equality is defined over category - severity - number.
    fn op == (self, const other: DiagCode) -> bool {
        return self._meta.category == other._meta.category
            && self._meta.severity == other._meta.severity
            && self._meta.number == other._meta.number
    }

    fn op != (self, const other: DiagCode) -> bool {
        return !(self == other)
    }

    /// Ordering: category first, then severity, then number.
    fn op < (self, const other: DiagCode) -> bool {
        if self._meta.category != other._meta.category {
            return (self._meta.category as u8) < (other._meta.category as u8)
        }

        if self._meta.severity != other._meta.severity {
            return (self._meta.severity as u8) < (other._meta.severity as u8)
        }

        return self._meta.number < other._meta.number
    }

    fn op >  (self, const other: DiagCode) -> bool {
        return !(self < other) && self != other
    }

    fn op <= (self, const other: DiagCode) -> bool {
        return self < other || self == other
    }

    fn op >= (self, const other: DiagCode) -> bool {
        return self > other || self == other
    }
}

/// \brief the DiagID for a code as a user writes it: as a diagnostic prints
///        it (C195W) or as its table spells it (C0195W).
///
/// \details a code is its category, number and severity -- what DiagCode
///          compares -- but the registry is keyed on the table's spelling,
///          and the tables do not share a width: Clang's numbers are four
///          digits, Kairo's three, and a diagnostic prints at least three.
///          Matching the text alone missed every Clang code below 1000 as
///          printed. So the number's padding is dropped and each table width
///          is tried; gen_diag.py rejects two codes that share category,
///          number and severity, so at most one of them is registered.
pub fn diag_from_code(const text: string) -> DiagID {
    var id = diag_from_string(text)
    if !diag_explain(id).empty() {
        return id
    }

    // [category letters][digits][one severity letter]; anything else is not
    // a code, and the exact match above was its only chance.
    var r        = text
    var n        = r.size()
    var i: usize = 0
    while i < n && r[i] >= ('A' as u8) && r[i] <= ('Z' as u8) {
        i += 1
    }

    var j = i
    while j < n && r[j] >= ('0' as u8) && r[j] <= ('9' as u8) {
        j += 1
    }

    if i == 0 || j == i || j + 1 != n {
        return DiagID::Invalid
    }

    // Strip the padding, keeping one digit of an all-zero number.
    var lead = i
    while lead + 1 < j && r[lead] == ('0' as u8) {
        lead += 1
    }

    var prefix: string = r.subslice(0, i)
    var digits: string = r.subslice(lead, j - lead)
    var sev:    string = r.subslice(j, 1)
    for var width: usize = 3; width <= 4; ++width {
        if digits.size() > width {
            continue
        }

        var pad: string = ""
        for var k: usize = digits.size(); k < width; ++k {
            pad = pad + "0"
        }

        var cand = diag_from_string(prefix + pad + digits + sev)
        if !diag_explain(cand).empty() {
            return cand
        }
    }

    return DiagID::Invalid
}
