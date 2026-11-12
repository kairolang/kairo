/// --- The Kairo Project ---------------- Diagnostic/BufferedDiagSink.k --- ///
///
///   A diagnostic sink that buffers diagnostics in memory until explicitly drained.
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
ffi "c++" import "vector"

import Diagnostic::Code::DiagCode
import Diagnostic::DiagBuilder::DiagBuilder
import Diagnostic::DiagSink::DiagEngineVBase
import Diagnostic::Diagnostic::Diagnostic
import Diagnostic::Engine::{
    DiagEngine,
    diag_policy_key,
}
import Diagnostic::Registry::DiagID
import Diagnostic::Severity::DiagSeverity
import Location::SourceLocation::SourceLocation
import Location::SourceManager::SourceManager
import Location::SourceRange::SourceRange

/// Sort key for draining in source order: (file, offset, insertion order).
/// A diagnostic with no resolvable location (has_loc == false, or a location
/// SourceManager can't map, e.g. a synthesized/recovery token) gets
/// `fid == usize(-1)` back from \c SourceManager::resolve, which this key's
/// ordering puts after every diagnostic with a real location. `seq` is the
/// diagnostic's original push_back position; it breaks ties for diagnostics
/// that share a location (two checks anchoring the same token) so the sort
/// is stable even if the sort routine itself ever stops being one.
pub struct DiagSortKey {
    pub var fid:    usize = 0
    pub var offset: usize = 0
    pub var seq:    usize = 0
}

pub class BufferedDiagSink derives DiagEngineVBase {
    priv var _diags:          cxx::std::vector<unsafe *Diagnostic>
    priv var _error_count:    u32                                  = 0
    priv var _suppress_depth: u32                                  = 0
    priv var _warn_count:     u32                                  = 0
    /// `@no_warn(CODE)` scopes (AttributeCheck::register_suppressions): a
    /// warning whose code is `key` (diag_policy_key) and whose location is
    /// inside `scope` is dropped at emit, before it is counted. Warnings
    /// only: an error is never suppressed by a source attribute, as `-A`
    /// never drops one.
    struct QuietScope {
        var key:   u32
        var scope: SourceRange
    }

    priv var _quiet: cxx::std::vector<Self::QuietScope>

    fn BufferedDiagSink(self) {
        self._diags.reserve(16)
    }

    // sink does NOT own-free on dtor assert on bug
    // Not transferable: every live DiagBuilder holds its address, and a copy would drain the same diagnostics twice.
    @copy fn BufferedDiagSink(self, const other: Self) = delete

    fn op finally (self) {
        if self._diags.size() != 0 {
            kairo::std::ice_fail("BufferedDiagSink dropped without drain")
        }
    }

    /// # report: mirror DiagEngine exactly so DiagBuilder binds to us

    pub fn report(self, code: DiagCode, loc: SourceLocation, msg: string) -> DiagBuilder {
        if loc == SourceLocation::invalid() {
            return self.report(code, msg)
        }

        return DiagBuilder(&self, code, loc, msg)
    }

    fn report(self, code: DiagCode, msg: string) -> DiagBuilder {
        return DiagBuilder(&self, code, msg)
    }

    pub fn report(self, id: DiagID, loc: SourceLocation, msg: string) -> DiagBuilder {
        if loc == SourceLocation::invalid() {
            return DiagBuilder(&self, DiagCode(id), msg)
        }

        return DiagBuilder(&self, DiagCode(id), loc, msg)
    }

    pub fn report(self, id: DiagID, msg: string) -> DiagBuilder {
        return DiagBuilder(&self, DiagCode(id), msg)
    }

    /// # suppression: parse-local, immediate (TentativeGuard drives this)

    pub fn push_suppress(self) {
        self._suppress_depth += 1
    }

    pub fn pop_suppress(self) {
        if self._suppress_depth > 0 {
            self._suppress_depth -= 1
        }
    }

    /// True inside a push_suppress region: what is reported now is dropped.
    pub fn is_suppressed(self) -> bool {
        return self._suppress_depth > 0
    }

    /// Lets one diagnostic through a push_suppress region, returning the depth
    /// to hand restore_suppress. For an error that holds for EVERY instance of
    /// a region checked once on purpose (the branch of a generic `eval if
    /// typeof T == U`): dropping it left a poisoned node for codegen to ICE
    /// on with no diagnostic at all.
    fn lift_suppress(self) -> u32 {
        var d = self._suppress_depth
        self._suppress_depth = 0
        return d
    }

    fn restore_suppress(self, d: u32) {
        self._suppress_depth = d
    }

    /// Drop warnings with policy key \p key located inside \p scope: from
    /// now on at emit, and those already buffered here. The second half is
    /// what lets the parser apply a `@no_warn` to the declaration it has
    /// just parsed (ASTParse::apply_annotations_to_decl): a warning
    /// inside it was reported before its range was known.
    pub fn quiet_in(self, key: u32, scope: SourceRange) {
        var q = Self::QuietScope{}
        q.key   = key
        q.scope = scope
        self._quiet.push_back(q)

        var kept: usize = 0
        for var i: usize = 0; i < self._diags.size(); ++i {
            var unsafe *d = self._diags[i]
            if self._quieted_by(d, key, scope) {
                kairo::std::destroy(d)
                if self._warn_count > 0 {
                    self._warn_count -= 1
                }

                continue
            }

            self._diags[kept] = d
            kept += 1
        }

        while self._diags.size() > kept {
            self._diags.pop_back()
        }
    }

    priv fn _quieted_by(self, diag: unsafe *Diagnostic, key: u32, scope: SourceRange) -> bool {
        if !diag->has_loc || diag->code.severity() != DiagSeverity::Warning {
            return false
        }

        return diag_policy_key(diag->code.category(), diag->code.number()) == key
            && scope.contains(diag->loc)
    }

    priv fn _quieted(self, diag: unsafe *Diagnostic) -> bool {
        if self._quiet.size() == 0 || !diag->has_loc {
            return false
        }

        if diag->code.severity() != DiagSeverity::Warning {
            return false
        }

        var key = diag_policy_key(diag->code.category(), diag->code.number())
        for var i: usize = 0; i < self._quiet.size(); ++i {
            if self._quiet[i].key == key && self._quiet[i].scope.contains(diag->loc) {
                return true
            }
        }

        return false
    }

    /// # emit: called by DiagBuilder::emit()

    fn emit(self, diag: unsafe *Diagnostic) {
        if self._suppress_depth > 0 {
            kairo::std::destroy(diag)
            return
        }

        if self._quieted(diag) {
            kairo::std::destroy(diag)
            return
        }

        var sev = diag->code.severity()
        match sev {
            case DiagSeverity::Error {
                self._error_count += 1
            } case DiagSeverity::Fatal {
                self._error_count += 1
            } case DiagSeverity::Warning {
                self._warn_count += 1
            } default { }
        }

        self._diags.push_back(diag)
    }

    pub fn error_count(self) -> u32 {
        return self._error_count
    }

    pub fn warn_count(self) -> u32 {
        return self._warn_count
    }

    /// Every buffered diagnostic, of any severity.
    pub fn size(self) -> usize {
        return self._diags.size()
    }

    /// Drops every buffered diagnostic unreported (a parse whose findings
    /// another parse reports instead: HeaderSetCache::start_shared).
    pub fn discard(self) {
        for var i: usize = 0; i < self._diags.size(); ++i {
            kairo::std::destroy(self._diags[i])
        }

        self._diags.clear()
        self._error_count = 0
        self._warn_count  = 0
    }

    /// Drops, unreported, every diagnostic after the first \p n: a second
    /// run of the same work that reports them again (the incremental
    /// cache's stream hash before a TU's real fill, CodegenJob::hash_stream).
    pub fn truncate(self, n: usize) {
        if n >= self._diags.size() {
            return
        }

        for var i: usize = n; i < self._diags.size(); ++i {
            kairo::std::destroy(self._diags[i])
        }

        while self._diags.size() > n {
            self._diags.pop_back()
        }

        self._error_count = 0
        self._warn_count  = 0
        for var i: usize = 0; i < self._diags.size(); ++i {
            var sev = self._diags[i]->code.severity()
            if sev == DiagSeverity::Error || sev == DiagSeverity::Fatal {
                self._error_count += 1
            } else if sev == DiagSeverity::Warning {
                self._warn_count += 1
            }
        }
    }

    /// # drain: single-threaded, at the join. transfers ownership.
    ///
    /// Drains in SOURCE order, not the order diagnostics happened to be
    /// reported in (parse recovery, multi-pass sema, etc. don't emit
    /// strictly left-to-right). Only the top-level diagnostics are reordered;
    /// each one's note children (e.g. "previous declaration is here", which
    /// legitimately points *backwards*) travel with their parent untouched.

    /// \brief the files the buffered diagnostics name a position in: each
    ///        one's location, labels and fix-its, and its notes'. Incremental
    ///        Sema records them (Sema/Incremental/Plan.k, R8): a rendered
    ///        note into another file is stale once that file's text moves.
    ///        Before drain_into, which gives the diagnostics away.
    pub fn named_fids(self, sm: unsafe *SourceManager, out: unsafe *cxx::std::vector<u32>) {
        for var i: usize = 0; i < self._diags.size(); ++i {
            BufferedDiagSink::_named_in(self._diags[i], sm, out)
            for var k: usize = 0; k < self._diags[i]->children.size(); ++k {
                BufferedDiagSink::_named_in(self._diags[i]->children[k], sm, out)
            }
        }
    }

    priv static fn _named_at(loc: SourceLocation, sm: unsafe *SourceManager, out: unsafe *cxx::std::vector<u32>) {
        if !loc.is_valid() {
            return
        }

        var fid = (sm->resolve(loc).fid as u32)
        for var i: usize = 0; i < out->size(); ++i {
            if (*out)[i] == fid {
                return
            }
        }

        out->push_back(fid)
    }

    priv static fn _named_in(d: unsafe *Diagnostic, sm: unsafe *SourceManager, out: unsafe *cxx::std::vector<u32>) {
        if d == &null {
            return
        }

        if d->has_loc {
            BufferedDiagSink::_named_at(d->loc, sm, out)
        }

        for var i: usize = 0; i < d->labels.size(); ++i {
            BufferedDiagSink::_named_at(d->labels[i].range.start, sm, out)
        }

        for var i: usize = 0; i < d->fixits.size(); ++i {
            BufferedDiagSink::_named_at(d->fixits[i].range.start, sm, out)
        }
    }

    pub fn drain_into(self, engine: unsafe *DiagEngine, sm: unsafe *SourceManager) {
        self._sort_by_source_order(sm)
        for var i: usize = 0; i < self._diags.size(); ++i {
            engine->emit(self._diags[i]) // engine now owns + frees
        }

        self._diags.clear() // drops pointer values only; pointees owned by engine
    }

    // Stable insertion sort (buffers here are one file/one pass, not a TU's
    // worth of diagnostics) over `_diags` and a parallel `keys` array kept
    // in lockstep, so `keys[i]` always describes `_diags[i]`.
    priv fn _sort_by_source_order(self, sm: unsafe *SourceManager) {
        var n                                   = self._diags.size()
        var keys: cxx::std::vector<DiagSortKey>
        keys.reserve(n)
        for var i: usize = 0; i < n; ++i {
            var key = DiagSortKey()
            key.seq = i
            var res = sm->resolve(self._diags[i]->loc)
            key.fid    = res.fid
            key.offset = res.offset
            keys.push_back(key)
        }

        for var i: usize = 1; i < n; ++i {
            var j = i
            while j > 0 && self._key_less(keys[j], keys[j - 1]) {
                var unsafe *td = self._diags[j - 1]
                self._diags[j - 1] = self._diags[j]
                self._diags[j]     = td

                var tk = keys[j - 1]
                keys[j - 1] = keys[j]
                keys[j]     = tk

                j -= 1
            }
        }
    }

    priv fn _key_less(self, a: DiagSortKey, b: DiagSortKey) -> bool {
        if a.fid != b.fid {
            return a.fid < b.fid
        }

        if a.offset != b.offset {
            return a.offset < b.offset
        }

        return a.seq < b.seq
    }
}
