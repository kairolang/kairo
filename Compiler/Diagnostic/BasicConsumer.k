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

ffi "c++" import "Native/KShims.hh" // std_out / std_err
ffi "c++" import "Native/KProgress.hh"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "llvm/Support/FileSystem.h"
ffi "c++" import "llvm/Support/raw_ostream.h"
ffi "c++" import "vector"
ffi "c++" import "cstdio"
ffi "c++" import "system_error"

import Diagnostic::Consumer::DiagConsumer
import Diagnostic::Diagnostic::Diagnostic
import Diagnostic::Severity::DiagSeverity
import Location::SourceLocation::SourceLocation
import Location::SourceManager::SourceManager
import Support::FileIO::Path::Path
import std::io

/// Plain-text diagnostic consumer no color, no ANSI codes.
///
/// Buffers all received \c Diagnostic pointers and renders them on demand
/// via one of the \c finalize_* methods. The consumer does not own the
/// diagnostics; lifetime is managed by \c DiagEngine.
///
/// \c _sm may be null. When null, source snippets and \c --> location lines
/// are omitted from output.
///
/// \par Output format
/// \code
///   error [SC041E]: message
///     --> file.k:10:5
///     10 | <source line>
///            ^^^ label text
///      > fix: suggestion
///      > note [SC021N]: child message
///         --> file.k:8:1
/// \endcode
///
/// \par Fix-its
/// Every fix-it that carries a range is printed on its own line directly after
/// its diagnostic and before the diagnostic's notes (a note's own fix-its follow
/// that note), in clang's
/// `-fdiagnostics-parseable-fixits` form (1-based columns, end exclusive),
/// so tests can pin the exact edit and scripts can apply it:
/// \code
///   fix-it:"file.k":{3:14-3:16}:"=> "
/// \endcode
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

    /// Constructs without a \c SourceManager. Source snippets will be omitted.
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
        if !self._abs_paths || p.empty() {
            return p
        }

        if p[0] == ('<' as u8) {
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
        kairo::ProgressMeter::hold()
        // A run incremental Sema skipped replays the frontend's diagnostics
        // as the run that recorded them rendered them, ahead of whatever
        // this run reported itself (Driver/ModuleRecords.k).
        if !self.replay.empty() {
            io::eprint(f"{self.replay}")
        }

        for var i: usize = 0; i < self._diags.size(); ++i {
            self.emit_diag(self._diags[i])
        }

        kairo::ProgressMeter::release()
    }

    fn finalize_to_stdout(self) {
        for var i: usize = 0; i < self._diags.size(); ++i {
            io::println(f"{self.render_diag(self._diags[i])}")
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
            var line = self.render_diag(self._diags[i])
            f.write(line.c_str(), line.size())
        }
    }

    fn finalize_to_string(self) -> string {
        var out: string
        for var i: usize = 0; i < self._diags.size(); ++i {
            out += self.render_diag(self._diags[i])
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

    priv fn severity_string(self, sev: DiagSeverity) -> string {
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

    /// `"` and `\` escaped, and the control characters an edit can carry,
    /// so every fix-it stays one line.
    priv fn escape_fixit_text(self, const s: string) -> string {
        var out = ""
        for var i: usize = 0; i < s.size(); ++i {
            var c = s[i]
            if c == 0x5C {
                out += "\\\\"
            } else if c == 0x22 {
                out += "\\\""
            } else if c == 0x0A {
                out += "\\n"
            } else if c == 0x09 {
                out += "\\t"
            } else if c == 0x0D {
                out += "\\r"
            } else {
                out.push_back(c)
            }
        }

        return out
    }

    /// One `fix-it:` line per ranged edit of \p diag; see the class comment.
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
            var fi = diag->fixits[i]
            if !fi.range.is_valid() {
                continue
            }

            var b    = sm->get_line_col(fi.range.start)
            var e    = sm->get_line_col(fi.range.end)
            var file = self.display_path(sm->get_filename(fi.range.start))
            var text = self.escape_fixit_text(fi.replacement)
            out += f"fix-it:\"{file}\":\x7B{b.line}:{b.column}-{e.line}:{e.column}\x7D:\"{text}\"\n"
        }

        return out
    }

    /// One JSON object for \p diag. escape_fixit_text already produces valid
    /// JSON string escapes for the characters a message or path can carry.
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

        var sev  = self.severity_string(diag->code.severity())
        var code = diag->code as string
        var msg  = self.escape_fixit_text(diag->message)
        var f2   = self.escape_fixit_text(file)
        return f"\x7B\"file\":\"{f2}\",\"line\":{line},\"col\":{col},\"severity\":\"{sev}\",\"code\":\"{code}\",\"message\":\"{msg}\"\x7D\n"
    }

    priv fn render_one(self, diag: unsafe *Diagnostic) -> string {
        if self._json {
            return self.render_json(diag)
        }

        var loc_prefix = if diag->has_loc => (self.format_loc(diag->loc)) else => ""
        var sev  = self.severity_string(diag->code.severity())
        var code = diag->code as string
        return f"{loc_prefix}{sev} [{code}]: {diag->message}\n"
    }

    /// Renders a diagnostic and all its children, one line each.
    priv fn render_diag(self, diag: unsafe *Diagnostic) -> string {
        var out = self.render_one(diag) + self.render_fixits(diag)
        for var i: usize = 0; i < diag->children.size(); ++i {
            out += self.render_one(diag->children[i]) + self.render_fixits(
                diag->children[i],
            )
        }

        return out
    }

    priv fn emit_diag(self, diag: unsafe *Diagnostic) {
        io::eprint(f"{self.stderr_text(diag)}")
    }

    /// Exactly what finalize_to_stderr writes for \p diag and its notes.
    priv fn stderr_text(self, diag: unsafe *Diagnostic) -> string {
        var out = self.render_one(diag) + self.render_fixits(diag)
        for var i: usize = 0; i < diag->children.size(); ++i {
            out += self.render_one(diag->children[i]) + self.render_fixits(
                diag->children[i],
            )
        }

        return out
    }

    /// What finalize_to_stderr would write for \p diag, for a tool that
    /// keeps the diagnostics itself (Tooling/LiveCheck.k).
    pub fn render(self, diag: unsafe *Diagnostic) -> string {
        return self.stderr_text(diag)
    }

    /// How many diagnostics are buffered.
    pub fn count(self) -> usize {
        return self._diags.size()
    }

    /// The stderr text of buffered diagnostics [\p a, \p b).
    pub fn render_range(self, a: usize, b: usize) -> string {
        var out = ""
        for var i: usize = a; i < b && i < self._diags.size(); ++i {
            out += self.stderr_text(self._diags[i])
        }

        return out
    }
}
