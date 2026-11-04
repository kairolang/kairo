/// --- The Kairo Project ---------------- Diagnostic/BufferedDiagSink.k --- ///
///
///   A diagnostic sink that buffers diagnostics in memory until explicitly drained.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Location::SourceRange::*;
import Location::SourceManager::*;
import Diagnostic::Registry::*;
import Diagnostic::Diagnostic::*;
import Diagnostic::Engine::*;

/// Sort key for draining in source order: (file, offset, insertion order).
/// A diagnostic with no resolvable location (has_loc == false, or a location
/// SourceManager can't map, e.g. a synthesized/recovery token) gets
/// `fid == usize(-1)` back from \c SourceManager::resolve, which this key's
/// ordering puts after every diagnostic with a real location. `seq` is the
/// diagnostic's original push_back position; it breaks ties for diagnostics
/// that share a location (two checks anchoring the same token) so the sort
/// is stable even if the sort routine itself ever stops being one.
struct DiagSortKey {
    pub var fid:    usize = 0;
    pub var offset: usize = 0;
    pub var seq:    usize = 0;
}

class BufferedDiagSink derives DiagEngineVBase {
    priv var _diags:         vec::<own::<Diagnostic>>;
    priv var _error_count:   u32 = 0;
    priv var _suppress_depth: u32 = 0;
    priv var _warn_count: u32 = 0;
    /// `@no_warn(CODE)` scopes (AttributeCheck::register_suppressions): a
    /// warning whose code is `key` (diag_policy_key) and whose location is
    /// inside `scope` is dropped at emit, before it is counted. Warnings
    /// only: an error is never suppressed by a source attribute, as `-A`
    /// never drops one.
    struct QuietScope {
        var key:   u32;
        var scope: SourceRange;
    }
    priv var _quiet: vec::<QuietScope>;

    fn BufferedDiagSink(self) {
        self._diags.reserve(16);
    }

    // sink does NOT own-free on dtor assert on bug
    fn op delete (self) {
        ICE_IF(self._diags.size() != 0, "BufferedDiagSink dropped without drain");
    }

    // --- report: mirror DiagEngine exactly so DiagBuilder binds to us -------
    fn report(self, code: DiagCode, loc: SourceLocation, msg: string) -> DiagBuilder {
        if loc == SourceLocation::invalid() {
            return self.report(code, msg);
        }
        return DiagBuilder(&self, code, loc, msg);
    }
    fn report(self, code: DiagCode, msg: string) -> DiagBuilder {
        return DiagBuilder(&self, code, msg);
    }
    fn report(self, id: DiagID, loc: SourceLocation, msg: string) -> DiagBuilder {
        if loc == SourceLocation::invalid() {
            return DiagBuilder(&self, DiagCode(id), msg);
        }
        return DiagBuilder(&self, DiagCode(id), loc, msg);
    }
    fn report(self, id: DiagID, msg: string) -> DiagBuilder {
        return DiagBuilder(&self, DiagCode(id), msg);
    }

    // --- suppression: parse-local, immediate (TentativeGuard drives this) ---
    fn push_suppress(self) { self._suppress_depth += 1; }
    fn pop_suppress(self)  {
        if self._suppress_depth > 0 { self._suppress_depth -= 1; }
    }

    /// Lets one diagnostic through a push_suppress region, returning the depth
    /// to hand restore_suppress. For an error that holds for EVERY instance of
    /// a region checked once on purpose (the branch of a generic `eval if
    /// typeof T == U`): dropping it left a poisoned node for codegen to ICE
    /// on with no diagnostic at all (O23).
    fn lift_suppress(self) -> u32 {
        var d = self._suppress_depth;
        self._suppress_depth = 0;
        return d;
    }
    fn restore_suppress(self, d: u32) { self._suppress_depth = d; }

    /// Drop warnings with policy key \p key located inside \p scope.
    fn quiet_in(self, key: u32, scope: SourceRange) {
        var q = QuietScope{};
        q.key   = key;
        q.scope = scope;
        self._quiet.push_back(q);
    }

    priv fn _quieted(self, diag: *Diagnostic) -> bool {
        if (self._quiet.size() == 0) || (!diag->has_loc) { return false; }
        if diag->code.severity() != DiagSeverity::Warning { return false; }
        var key = diag_policy_key(diag->code.category(), diag->code.number());
        for var i: usize = 0; i < self._quiet.size(); ++i {
            if (self._quiet[i].key == key) && self._quiet[i].scope.contains(diag->loc) { return true; }
        }
        return false;
    }

    // --- emit: called by DiagBuilder::emit() --------------------------------
    fn emit(self, diag: *Diagnostic) {
        if self._suppress_depth > 0 {
            std::destroy(diag);
            return;
        }
        if self._quieted(diag) {
            std::destroy(diag);
            return;
        }
        var sev = diag->code.severity();
        switch sev {
            case DiagSeverity::Error   { self._error_count += 1; }
            case DiagSeverity::Fatal   { self._error_count += 1; }
            case DiagSeverity::Warning { self._warn_count  += 1; }
            default {}
        }
        self._diags.push_back(diag);
    }

    fn error_count(self) -> u32 { return self._error_count; }
    fn warn_count(self) -> u32 { return self._warn_count; }

    // --- drain: single-threaded, at the join. transfers ownership. ----------
    //
    // Drains in SOURCE order, not the order diagnostics happened to be
    // reported in (parse recovery, multi-pass sema, etc. don't emit
    // strictly left-to-right). Only the top-level diagnostics are reordered;
    // each one's note children (e.g. "previous declaration is here", which
    // legitimately points *backwards*) travel with their parent untouched.
    fn drain_into(self, engine: *DiagEngine, sm: *SourceManager) {
        self._sort_by_source_order(sm);
        for var i: usize = 0; i < self._diags.size(); ++i {
            engine->emit(self._diags[i]);   // engine now owns + frees
        }
        self._diags.clear();   // drops pointer values only; pointees owned by engine
    }

    // Stable insertion sort (buffers here are one file/one pass, not a TU's
    // worth of diagnostics) over `_diags` and a parallel `keys` array kept
    // in lockstep, so `keys[i]` always describes `_diags[i]`.
    priv fn _sort_by_source_order(self, sm: *SourceManager) {
        var n = self._diags.size();
        var keys: vec::<DiagSortKey>;
        keys.reserve(n);
        for var i: usize = 0; i < n; ++i {
            var key = DiagSortKey();
            key.seq = i;
            var res = sm->resolve(self._diags[i]->loc);
            key.fid    = res.fid;
            key.offset = res.offset;
            keys.push_back(key);
        }

        for var i: usize = 1; i < n; ++i {
            var j = i;
            while (j > 0) && self._key_less(keys[j], keys[j - 1]) {
                var td = self._diags[j - 1];
                self._diags[j - 1] = self._diags[j];
                self._diags[j] = td;

                var tk = keys[j - 1];
                keys[j - 1] = keys[j];
                keys[j] = tk;

                j -= 1;
            }
        }
    }

    priv fn _key_less(self, a: DiagSortKey, b: DiagSortKey) -> bool {
        if a.fid != b.fid { return a.fid < b.fid; }
        if a.offset != b.offset { return a.offset < b.offset; }
        return a.seq < b.seq;
    }
}