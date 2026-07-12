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
import Diagnostic::Registry::*;
import Diagnostic::Diagnostic::*;
import Diagnostic::Engine::*;

class BufferedDiagSink derives DiagEngineVBase {
    priv var _diags:         vec::<own::<Diagnostic>>;
    priv var _error_count:   u32 = 0;
    priv var _suppress_depth: u32 = 0;
    priv var _warn_count: u32 = 0;

    fn BufferedDiagSink(self) {
        self._diags.reserve(16);
    }

    // sink does NOT own-free on dtor assert on bug
    fn op delete (self) {
        std::ICE(self._diags.size() == 0, "BufferedDiagSink dropped without drain");
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

    // --- emit: called by DiagBuilder::emit() --------------------------------
    fn emit(self, diag: *Diagnostic) {
        if self._suppress_depth > 0 {
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
    fn drain_into(self, engine: *DiagEngine) {
        for var i: usize = 0; i < self._diags.size(); ++i {
            engine->emit(self._diags[i]);   // engine now owns + frees
        }
        self._diags.clear();   // drops pointer values only; pointees owned by engine
    }
}