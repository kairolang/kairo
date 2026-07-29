/// --- The Kairo Project ----------- Sema/Verify/CxxReservedWords.k --- ///
///
///   \brief The C++ keyword set for one file, plus the [lex.name]/3
///          reserved-identifier patterns clang does not flag.
///
///   \detail
///     Kairo emits identical spellings across the C++ boundary (no
///     mangling), so any user name that is a C++ keyword cannot be
///     emitted and cannot be called from real C++.
///
///     Direction matters: this does NOT intern keyword spellings into the
///     ImmediateTable. It PROBES the table (find_ident, non-mutating) for
///     each keyword spelling, and keeps only the hits. Interning would
///     mutate a table that is frozen by the time Verify runs, and would
///     add ~90 dead identifier entries per file.
///
///     The resulting indices are TABLE-LOCAL. An ImmediateTable is
///     per-fid; index 47 means different things in different files.
///     Never share a built set across fids, never store one anywhere
///     with a lifetime longer than the pass that built it.
///
///     Correct only against a fully-populated table. Verify runs post-
///     parse, so that holds; do not move a consumer of this earlier in
///     the pipeline without re-reading this paragraph.
///
///   Phase: VERIFY (pre-N)
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

ffi "c++" import "clang/Basic/TokenKinds.h";

import Lexer::Immediate::*;

class CxxKeywordSet {
    priv var _idx:   libcxx::unordered_set::<u32>;  ///< table-local ident indices
    priv var _built: bool = false;

    /// Probe every C++ keyword spelling against \p imms. Misses are the
    /// common case (a file uses a handful of names that happen to be C++
    /// keywords, if any) and cost one open-addressed probe each.
    fn build(self, imms: *ImmediateTable) {
        if self._built { return; }
        self._built = true;
        if imms == &null { return; }

        // NUM_TOKENS bounds the enum; getKeywordSpelling returns null for
        // every non-keyword kind, so the filter is clang's, not ours   it
        // cannot drift from what clang will actually reject.
        for var k: u32 = 0; k < static_cast::<u32>(clang::tok::NUM_TOKENS); ++k {
            var s = clang::tok::getKeywordSpelling(
                static_cast::<clang::tok::TokenKind>(k));
            if s == &null { continue; }

            // narrow bytes straight through: getKeywordSpelling is already
            // the right string tier, no transcode.
            var r = reinterpret_cast::<std::ConstPtr::<u8>>(s);
            var l = libcxx::strlen(s);
            var i = imms->find_ident(r, l, compute_hash(r, l));
            if i != static_cast::<u32>(-1) { self._idx.insert(i); }
        }
    }

    fn contains(self, imm: u32) -> bool {
        return self._idx.find(imm) != self._idx.end();
    }
}

/// Non-empty reason if \p s matches a [lex.name]/3 reserved pattern. These
/// are shape rules on the spelling, not identity   no interning involved.
fn cxx_reserved_reason(s: string) -> string {
    var n = s.length();
    if n == 0 { return ""; }

    for var i: usize = 1; i < n; ++i {
        if (s[i - 1] == '_') && (s[i] == '_') {
            return "contains a double underscore";
        }
    }

    if s[0] == '_' {
        if n > 1 {
            var c = s[1];
            if (c >= 'A') && (c <= 'Z') {
                return "begins with an underscore followed by an uppercase letter";
            }
        }
        return "begins with an underscore";
    }

    return "";
}