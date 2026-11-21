/// --- The Kairo Project ------------------- Diagnostic/BasicConsumer.k --- ///
///
///   Machine-readable single-line-per-diagnostic consumer.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
///
///   Output format (one line per diagnostic, children included):
///
///     <file>:<line>:<col>: <severity> [<code>]: <message>
///
///   When no source location is available:
///
///     <severity> [<code>]: <message>
///
///   No color, no snippets, no underlines. Parseable by make, grep, editors,
///   and FileCheck. For human output use PrettyDiagConsumer. For structured
///   output use JsonDiagConsumer (not yet implemented).
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Shims.hh" // std_out / std_err
ffi "c++" import "Native/Types.hh"
ffi "c++" import "llvm/Support/FileSystem.h"
ffi "c++" import "llvm/Support/raw_ostream.h"
ffi "c++" import "vector"
ffi "c++" import "cstdio"
ffi "c++" import "system_error"

import Diagnostic::Consumer::DiagConsumer
import Diagnostic::Diagnostic::Diagnostic
import Diagnostic::Severity::diag_severity_name
import Location::SourceLocation::SourceLocation
import Location::SourceManager::SourceManager
import Native::Progress::ProgressMeter
import Support::Escape::{
    CEscapeStyle,
    c_escape,
    json_string,
}
import Support::FileIO::Path::Path
import std::io

/// Plain-text diagnostic consumer no color, no ANSI codes.
///
/// Buffers all received `Diagnostic` pointers and renders them on demand
/// via one of the `finalize_*` methods. The consumer does not own the
/// diagnostics; lifetime is managed by `DiagEngine`.
///
/// `_sm` may be null. When null, source snippets and `-->` location lines
/// are omitted from output.
///
/// \par Output format
///
/// ### Example
/// ```kairo
/// error [SC041E]: message
///   --> file.k:10:5
///   10 | <source line>
///          ^^^ label text
///    > fix: suggestion
///    > note [SC021N]: child message
///       --> file.k:8:1
/// ```
///
/// \par Fix-its
/// Every fix-it that carries a range is printed on its own line directly after
/// its diagnostic and before the diagnostic's notes (a note's own fix-its follow
/// that note), in clang's
/// `-fdiagnostics-parseable-fixits` form (1-based columns, end exclusive),
/// so tests can pin the exact edit and scripts can apply it:
///
/// ### Example
/// ```kairo
/// fix-it:"file.k":{3:14-3:16}:"=> "
/// ```
///
/// A fix that carries only a message prints nothing extra.
pub class BasicDiagConsumer derives DiagConsumer {
    /// Pre-rendered text written before the buffer (ModuleRecords' replay).
    pub var  replay:     string                               = ""
    priv var _diags:     cxx::std::vector<unsafe *Diagnostic>
    priv var _sm:        unsafe *SourceManager
    priv var _abs_paths: bool                                 = false ///< --diag-absolute-paths
    priv var _json:      bool                                 = false ///< --error-format=json: one object per line

    fn BasicDiagConsumer(self, sm: unsafe *SourceManager) {
        self._diags.reserve(32)
        self._sm = sm
    }

    /// Constructs without a `SourceManager`. Source snippets will be omitted.
    fn BasicDiagConsumer(self) {
        self._diags.reserve(32)
        self._sm = &null
    }

    /// # DiagConsumer interface

    fn handle(self, diag: unsafe *Diagnostic) {
        self._diags.push_back(diag)
    }

    pub fn attach_source_manager(self, sm: unsafe *SourceManager) {
        self._sm = sm
    }

    pub fn set_absolute_paths(self, val: bool) {
        self._abs_paths = val
    }

    /// JSON lines instead of the text form: {"file","line","col","severity",
    /// "code","message"}, one object per diagnostic, notes as their own objects.
    /// Fix-it lines are not emitted in this mode.
    pub fn set_json(self, val: bool) {
        self._json = val
    }

    /// The path as the user asked to see it. "<...>" names are synthetic
    /// buffers, not files, and must not be joined onto the cwd.
    priv fn display_path(self, p: string) -> string {
        if !self._abs_paths || p.is_empty() {
            return p
        }

        if p.data()[0] == ('<' as u8) {
            return p
        }

        return Path(p).full_path()
    }

    pub fn finalize_to_stderr(self) {
        // stdout is block-buffered when piped and stderr is not: without
        // this a diagnostic lands in the middle of a dump line under 2>&1.
        cxx::std::fflush(kairo::std_out())
        // The pinned progress line goes first and stays off until the last
        // diagnostic is out: diagnostic text never shares its row.
        ProgressMeter::hold()
        // A run incremental Sema skipped replays the frontend's diagnostics
        // as the run that recorded them rendered them, ahead of whatever
        // this run reported itself (Driver/ModuleRecords.k).
        if !self.replay.is_empty() {
            io::eprint(f"{self.replay}")
        }

        for var i: usize = 0; i < self._diags.size(); ++i {
            self.emit_diag(self._diags[i])
        }

        ProgressMeter::release()
    }

    fn finalize_to_stdout(self) {
        for var i: usize = 0; i < self._diags.size(); ++i {
            io::println(f"{self.stderr_text(self._diags[i])}")
        }
    }

    fn finalize_to_file(self, const path: string) {
        // Streamed one diagnostic at a time: each renders independently, so
        // there is no reason to hold the whole report as one string first.
        // OF_None: binary -- the bytes are already UTF-8.
        var ec: cxx::std::error_code
        var f = llvm::raw_fd_ostream(
            kairo::sref(path),
            &ec,
            llvm::sys::fs::OF_None,
        )

        if ec.value() != 0 {
            return
        }

        for var i: usize = 0; i < self._diags.size(); ++i {
            var line = self.stderr_text(self._diags[i])
            f.write(line.c_str(), line.size())
        }
    }

    fn finalize_to_string(self) -> string {
        var out: string
        for var i: usize = 0; i < self._diags.size(); ++i {
            out += self.stderr_text(self._diags[i])
        }

        return out
    }

    /// # Rendering

    priv fn format_loc(self, loc: SourceLocation) -> string {
        if self._sm == &null {
            return ""
        }

        var unsafe *sm      = self._sm
        var        loc_info = sm->get_line_col(loc)
        var        filename = self.display_path(sm->get_filename(loc))
        return f"{filename}:{loc_info.line}:{loc_info.column}: "
    }

    /// One `fix-it:` line per ranged edit of `diag`; see the class comment.
    priv fn render_fixits(self, diag: unsafe *Diagnostic) -> string {
        if self._sm == &null {
            return ""
        }

        if self._json {
            return ""
        }

        var unsafe *sm = self._sm
        var        out = ""
        for var i: usize = 0; i < diag->fixits.size(); ++i {
            var *fi = &diag->fixits[i]
            if !fi->range.is_valid() {
                continue
            }

            var b    = sm->get_line_col(fi->range.start)
            var e    = sm->get_line_col(fi->range.end)
            var file = self.display_path(sm->get_filename(fi->range.start))
            var text = c_escape(fi->replacement, CEscapeStyle::Readable)
            out += f"fix-it:\"{file}\":\x7B{b.line}:{b.column}-{e.line}:{e.column}\x7D:\"{text}\"\n"
        }

        return out
    }

    /// One JSON object for `diag`, its strings escaped as RFC 8259 asks
    /// (a control byte in a message, from quoted source text, included).
    priv fn render_json(self, diag: unsafe *Diagnostic) -> string {
        var file: string = ""
        var line: u32    = 0
        var col:  u32    = 0
        if diag->has_loc && self._sm != &null {
            var unsafe *sm = self._sm
            var        li  = sm->get_line_col(diag->loc)
            file = self.display_path(sm->get_filename(diag->loc))
            line = (li.line as u32)
            col  = (li.column as u32)
        }

        var sev  = diag_severity_name(diag->code.severity())
        var code = diag->code as string
        var msg  = json_string(diag->message)
        var f2   = json_string(file)
        return f"\x7B\"file\":{f2},\"line\":{line},\"col\":{col},\"severity\":\"{sev}\",\"code\":\"{code}\",\"message\":{msg}\x7D\n"
    }

    priv fn render_one(self, diag: unsafe *Diagnostic) -> string {
        if self._json {
            return self.render_json(diag)
        }

        var loc_prefix = if diag->has_loc => (self.format_loc(diag->loc)) else => ""
        var sev  = diag_severity_name(diag->code.severity())
        var code = diag->code as string
        return f"{loc_prefix}{sev} [{code}]: {diag->message}\n"
    }

    priv fn emit_diag(self, diag: unsafe *Diagnostic) {
        io::eprint(f"{self.stderr_text(diag)}")
    }

    /// `diag` and its notes, one line each, every ranged fix-it after the
    /// line it belongs to: what each finalize_* writes for it.
    priv fn stderr_text(self, diag: unsafe *Diagnostic) -> string {
        var out = self.render_one(diag) + self.render_fixits(diag)
        for var i: usize = 0; i < diag->children.size(); ++i {
            out += self.render_one(diag->children[i]) + self.render_fixits(
                diag->children[i],
            )
        }

        return out
    }

    /// What finalize_to_stderr would write for `diag`, for a tool that
    /// keeps the diagnostics itself (Tooling/LiveCheck.k).
    pub fn render(self, diag: unsafe *Diagnostic) -> string {
        return self.stderr_text(diag)
    }

    /// How many diagnostics are buffered.
    pub fn count(self) -> usize {
        return self._diags.size()
    }

    /// The stderr text of buffered diagnostics [`a`, `b`).
    pub fn render_range(self, a: usize, b: usize) -> string {
        var out = ""
        for var i: usize = a; i < b && i < self._diags.size(); ++i {
            out += self.stderr_text(self._diags[i])
        }

        return out
    }
}
