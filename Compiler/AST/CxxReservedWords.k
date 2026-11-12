/// --- The Kairo Project ----------------------- AST/CxxReservedWords.k --- ///
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
///     Two consumers: CxxNameCheck (VERIFY, pre-N) probes user names
///     through CxxKeywordSet; CXXSpell::entry_stem asks is_cxx_keyword of
///     a file stem, which is no table entry at all. A leaf with no Sema
///     dependency, so it lives here and codegen can import it.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "llvm/ADT/StringMap.h"
ffi "c++" import "clang/Basic/IdentifierTable.h"
ffi "c++" import "clang/Basic/LangOptions.h"
ffi "c++" import "clang/Basic/LangStandard.h"
ffi "c++" import "clang/Basic/TokenKinds.h"
ffi "c++" import "llvm/TargetParser/Triple.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"
ffi "c++" import "string"
ffi "c++" import "cstring"

import Lexer::Immediate::ImmediateTable
import Support::EvalHash::compute_hash

/// # Process-wide keyword spellings

/// The keyword spellings both consumers below walk, computed once for the
/// process. Both lists come from clang's own tables and nothing
/// else, so they cannot drift from what clang rejects. Recomputing them per
/// call (every token kind's getKeywordSpelling and a strlen, per module-path
/// segment) or per file (a LangOptions and an IdentifierTable each) would
/// repeat that work needlessly.
/// Filled during static initialization, before main and before any worker
/// thread exists, and never written after, so every read is lock-free.
class CxxKeywordSpellings {
    /// Every keyword spelling clang knows, for any language it lexes:
    /// is_cxx_keyword's set (the digraph words are checked beside it).
    pub var any_lang: llvm::StringMap<u8>
    /// Those that are keywords under the newest GNU C++ mode, in token
    /// kind order: what CxxKeywordSet::build probes a file's table for.
    pub var gnucxx: cxx::std::vector<llvm::StringRef>

    fn CxxKeywordSpellings(self) {
        var lo:   clang::LangOptions
        var incs: cxx::std::vector<cxx::std::string>
        clang::LangOptions::setLangDefaults(
            &lo,
            clang::Language::CXX,
            llvm::Triple(),
            &incs,
            clang::LangStandard::lang_gnucxx26,
        )

        var ids = clang::IdentifierTable(lo)
        for var k: u32 = 0; k < ((clang::tok::NUM_TOKENS as u16) as u32); ++k {
            var unsafe *s = clang::tok::getKeywordSpelling(((k as u16) as clang::tok::TokenKind))
            if s == &null {
                continue
            }

            var sp = llvm::StringRef(s)
            self.any_lang.try_emplace(sp, (1 as u8))
            var *ii = &ids.get(sp)
            if ii->isKeyword(lo) {
                self.gnucxx.push_back(sp)
            }
        }
    }
}

/// The one instance (see CxxKeywordSpellings).
var _KEYWORD_SPELLINGS: CxxKeywordSpellings = CxxKeywordSpellings()

pub class CxxKeywordSet {
    priv var _idx:   llvm::DenseSet<u32> ///< table-local ident indices; never the u32(-1) miss (see build).
    priv var _built: bool                = false

    /// Probe every C++ keyword spelling against \p imms. Misses are the
    /// common case (a file uses a handful of names that happen to be C++
    /// keywords, if any) and cost one open-addressed probe each.
    pub fn build(self, imms: unsafe *ImmediateTable) {
        if self._built {
            return
        }

        self._built = true
        if imms == &null {
            return
        }

        // NUM_TOKENS bounds the enum; getKeywordSpelling returns null for
        // every non-keyword kind, so the filter is clang's, not ours   it
        // cannot drift from what clang will actually reject.
        //
        // getKeywordSpelling answers for EVERY language clang lexes: HLSL's
        // `in` / `out` / `inout`, OpenCL's and ObjC's words are kinds too.
        // A user name is rejected here (SC004E) only if C++ would reject it,
        // so each spelling is also asked whether it is a keyword under the
        // newest GNU C++ mode, the widest C++ the emitted code may be built
        // as. Without that, `var out` and `out: *T` would be errors though
        // `int out;` is valid C++.
        // The spelling list is clang's, filtered once for the process
        // (CxxKeywordSpellings, which says how).
        var *kws = &_KEYWORD_SPELLINGS.gnucxx
        for var k: usize = 0; k < kws->size(); ++k {
            var sp = (*kws)[k]
            // narrow bytes straight through: getKeywordSpelling is already
            // the right string tier, no transcode.
            var unsafe *r = unsafe (sp.data() as kairo::std::ConstPtr<u8>)
            var        l  = sp.size()
            var        i  = imms->find_ident(r, l, ((compute_hash(r, l)) as u32))
            if i != ((-1) as i32 as u32) {
                self._idx.insert(i)
            }
        }
    }

    pub fn contains(self, imm: u32) -> bool {
        // u32(-1) is "no ident" and DenseSet's empty key: a lookup with it
        // asserts, so answer it before the probe.
        if imm == ((-1) as i32 as u32) {
            return false
        }

        return self._idx.contains(imm)
    }
}

/// Whether \p s is reserved by C++ at EVERY scope ([lex.name]/3: a double
/// underscore anywhere, or `_` + uppercase), as opposed to a plain leading
/// `_` + lowercase, which C++ reserves only at global scope and Kairo
/// reserves everywhere by its own rule (SC005W). Only meaningful when
/// cxx_reserved_reason(s) is non-empty.
pub fn cxx_reserved_everywhere(const s: string) -> bool {
    var n = s.length()
    for var i: usize = 1; i < n; ++i {
        if s[i - 1] == ('_' as u8) && s[i] == ('_' as u8) {
            return true
        }
    }

    if n > 1 && s[0] == ('_' as u8) && s[1] >= ('A' as u8) && s[1] <= ('Z' as u8) {
        return true
    }

    return false
}

/// Non-empty reason if \p s matches a [lex.name]/3 reserved pattern. These
/// are shape rules on the spelling, not identity   no interning involved.
pub fn cxx_reserved_reason(const s: string) -> string {
    var n = s.length()
    if n == 0 {
        return ""
    }

    for var i: usize = 1; i < n; ++i {
        if s[i - 1] == ('_' as u8) && s[i] == ('_' as u8) {
            return "contains a double underscore"
        }
    }

    if s[0] == ('_' as u8) {
        if n > 1 {
            var c = s[1]
            if c >= ('A' as u8) && c <= ('Z' as u8) {
                return "begins with an underscore followed by an uppercase letter"
            }
        }

        return "begins with an underscore"
    }

    return ""
}

/// True if \p s is spelled as a C++ keyword in any language mode clang
/// knows, or as one of the [lex.digraph] alternative tokens (`and`, `not`,
/// ...), which clang lexes as punctuators and so has no keyword spelling
/// for. String-keyed, for a spelling that is in no ImmediateTable (a file
/// stem). Over-inclusive on purpose: a C-only or extension keyword costs a
/// trailing `_`, a missed one costs a clang error.
pub fn is_cxx_keyword(const s: string) -> bool {
    if s.length() == 0 {
        return false
    }

    // One hash probe: cxx_segment runs once per qualified name's path
    // segment.
    if _KEYWORD_SPELLINGS.any_lang.contains(kairo::sref(s)) {
        return true
    }

    return s == "and"
        || s == "and_eq"
        || s == "bitand"
        || s == "bitor"
        || s == "compl"
        || s == "not"
        || s == "not_eq"
        || s == "or"
        || s == "or_eq"
        || s == "xor"
        || s == "xor_eq"
}
