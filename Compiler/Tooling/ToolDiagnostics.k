/// --- The Kairo Project -------------------- Tooling/ToolDiagnostics.k --- ///
///
///   Diagnostic capture for the compiler-as-a-library surface.
///
///   WHY A CONSUMER AND NOT THE CONTEXT SINK: diagnostics reach the engine by
///   two different routes. Parser and Sema report into ctx->diag_sink (a
///   BufferedDiagSink) which FrontendAction drains into the engine. The
///   PREPROCESSOR reports straight to the engine and never touches a buffer
///   (Preprocessor.k:142 and friends). So capturing at the context sink would
///   silently miss every unresolved-import and macro error   exactly the ones
///   a tool most needs to report itself.
///
///   Everything converges on DiagEngine, so that is where capture belongs.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Diagnostic::Engine::*;
import Diagnostic::Consumer::*;
import Diagnostic::Diagnostic::*;
import Diagnostic::Severity::*;
import Location::SourceManager::*;
import Location::SourceLocation::*;

/// \class ToolDiag
/// \brief one captured diagnostic, flattened to plain values.
///
/// \details Deliberately NOT a *Diagnostic. The engine owns those and their
///          lifetime is tied to the run that produced them; a tool wants to
///          report after the parse is torn down. Everything here is a copy.
class ToolDiag {
    pub var code:     string = "";   ///< e.g. "S047E". Empty if the code had no spelling.
    pub var message:  string = "";
    pub var severity: DiagSeverity = DiagSeverity::Error;

    pub var has_loc:  bool  = false;
    pub var file:     string = "";
    pub var line:     usize = 0;     ///< 1-based; 0 when has_loc is false.
    pub var column:   usize = 0;     ///< 1-based; 0 when has_loc is false.

    default fn ToolDiag(self);

    fn is_error(self) -> bool {
        return (self.severity == DiagSeverity::Error) || (self.severity == DiagSeverity::Fatal);
    }

    /// `path:line:col: CODE: message`, or `CODE: message` with no location.
    fn format(self) -> string {
        var head: string = "";
        if self.has_loc { head = f"{self.file}:{self.line}:{self.column}: "; }
        if self.code.empty() { return f"{head}{self.message}"; }
        return f"{head}{self.code}: {self.message}";
    }
}

/// \class ToolDiagConsumer
/// \brief a DiagConsumer that collects instead of printing.
///
/// \details Install with DiagEngine::take_consumers() +
///          add_consumer(this), restore with restore_consumers(). While
///          attached, NOTHING reaches the terminal   which is the point: a
///          formatter meeting a syntax error should report its own failure,
///          not emit compiler-shaped errors mid-run.
class ToolDiagConsumer derives DiagConsumer {
    pub var diags: vec::<ToolDiag>;
    priv var _sm:  obs::<SourceManager>;

    fn ToolDiagConsumer(self, sm: *SourceManager) {
        self._sm = sm;
        self.diags.reserve(32);
    }

    /* OVERRIDE */ fn handle(self, diag: *Diagnostic) {
        if diag == &null { return; }
        self._collect(diag);
    }

    /// Notes are children of their parent, and a tool that only prints the
    /// parents loses the "declared here" half of most diagnostics. Flatten the
    /// whole tree in emission order.
    priv fn _collect(self, diag: *Diagnostic) {
        var d = ToolDiag{};
        d.message  = diag->message;
        d.code     = (diag->code) as string;
        d.severity = diag->code.severity();
        d.has_loc  = diag->has_loc;

        if diag->has_loc && (self._sm != &null) {
            var full = self._sm->get_line_col(diag->loc);
            d.file   = self._sm->get_filename(diag->loc);
            d.line   = full.line;
            d.column = full.column;
        }

        self.diags.push_back(d);

        for var i: usize = 0; i < diag->children.size(); ++i {
            var c = diag->children[i];
            if c != &null { self._collect(c); }
        }
    }

    fn error_count(self) -> u32 {
        var n: u32 = 0;
        for var i: usize = 0; i < self.diags.size(); ++i {
            if self.diags[i].is_error() { n += 1; }
        }
        return n;
    }

    fn clear(self) { self.diags.clear(); }
}
