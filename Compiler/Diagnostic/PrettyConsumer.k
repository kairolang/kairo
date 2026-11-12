/// --- The Kairo Project ------------------ Diagnostic/PrettyConsumer.k --- ///
///
///   ANSI-colored diagnostic consumer.
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
ffi "c++" import "llvm/Support/FileSystem.h"
ffi "c++" import "llvm/Support/raw_ostream.h"
ffi "c++" import "Native/KShims.hh"
ffi "c++" import "Native/KProgress.hh"
ffi "c++" import "vector"
ffi "c++" import "cstdio"
ffi "c++" import "system_error"
ffi "c++" import "cstdlib"

import Diagnostic::Code::DiagCode
import Diagnostic::Consumer::DiagConsumer
import Diagnostic::Diagnostic::{
    DiagLabel,
    Diagnostic,
    FixIt,
}
import Diagnostic::Severity::DiagSeverity
import Location::SourceLocation::SourceLocation
import Location::SourceManager::SourceManager
import Location::SourceRange::SourceRange
import Support::FileIO::Path::Path
import Support::TermRenderer::TermRenderer
import std::io

/// ANSI-colored diagnostic consumer.
///
/// Extends \c BasicDiagConsumer with color, bold text, and right-aligned
/// line numbers. Color is automatically disabled when writing to a file or
/// non-tty stream, or when the \c NO_COLOR environment variable is set.
///
/// \c StrikeThrough labels are rendered with Unicode combining strikethrough
/// characters in addition to the \c ~ glyph underline.
///
/// Color can be forced off at any time via \c set_color(false), which zeroes
/// all ANSI escape fields. This cannot be reversed construct a new consumer
/// if re-enabling is needed.
///
/// \c _sm may be null; source snippets and \c --> lines are omitted when so.
/// Key for grouping diagnostics by file and line.
pub struct DiagGroupKey {
    pub var file_id: u32
    pub var line:    u32

    fn op== (self, other: DiagGroupKey) -> bool {
        return self.file_id == other.file_id && self.line == other.line
    }

    fn op< (self, other: DiagGroupKey) -> bool {
        if self.file_id != other.file_id {
            return self.file_id < other.file_id
        }

        return self.line < other.line
    }
}

/// Key for grouping diagnostics by code AND message.
pub struct DiagCodeMsgKey {
    pub var code: DiagCode
    pub var msg:  string
    pub var sev:  DiagSeverity

    fn op== (self, const other: DiagCodeMsgKey) -> bool {
        return self.code == other.code && self.msg == other.msg
    }
}

/// Entry tracking a caret span for coalesced rendering.
pub struct CaretSpan {
    pub var start_col: usize            ///< 0-indexed column start
    pub var end_col:   usize            ///< 0-indexed column end (exclusive)
    pub var code:      DiagCode
    pub var sev:       DiagSeverity
    pub var style:     DiagLabel::Style
}

/// Group of diagnostics on the same file:line, to be rendered together.
pub struct DiagGroup {
    pub var key:      DiagGroupKey
    pub var diags:    cxx::std::vector<unsafe *Diagnostic>
    pub var filename: string
    pub var line_num: u32
    pub var col_num:  u32 ///< 1-based column of the group's first diagnostic (the header's :col)
}

/// ANSI-colored diagnostic consumer with same-line coalescing.
///
/// When multiple diagnostics target the same source line, they are merged:
/// - Same code + same message: single header line
/// - Same code + different message: stacked headers with severity label only on first
/// - Different codes: partitioned underline rows with [CODE] suffixes
///
/// Overlapping caret spans use the color of the highest severity diagnostic.
pub class PrettyDiagConsumer derives DiagConsumer {
    /// Pre-rendered text written before the buffer (ModuleRecords' replay).
    pub var replay: string = ""
    priv var _diags:        cxx::std::vector<unsafe *Diagnostic>
    priv var _sm:           unsafe *SourceManager
    priv var _show_context: bool                                 = true ///< --diag-show-context: false hides the source snippet
    priv var _ctx_lines:    u32                                  = 3 ///< --cmax-diag-context-lines: lines shown up to the caret line; 0 = no limit
    priv var _abs_paths:    bool                                 = false ///< --diag-absolute-paths

    /// # ANSI escape codes

    priv var RESET:    string = "\x1b[0m"
    priv var BOLD:     string = "\x1b[1m"
    priv var DIM:      string = "\x1b[2;37m"
    priv var BOLD_RED: string = "\x1b[1;31m"
    priv var RED:      string = "\x1b[31m"
    priv var YELLOW:   string = "\x1b[33m"
    priv var CYAN:     string = "\x1b[36m"
    priv var BLUE:     string = "\x1b[34m"
    priv var MAGENTA:  string = "\x1b[35m"
    priv var WHITE:    string = "\x1b[37m"
    priv var GREEN:    string = "\x1b[32m"
    priv var STRIKE:   string = "\x1b[9m"    ///< strikethrough (SGR 9) for removed text

    /// # Constructors

    fn PrettyDiagConsumer(self, sm: unsafe *SourceManager) {
        self._diags.reserve(32)
        self._sm = sm
    }

    fn PrettyDiagConsumer(self) {
        self._diags.reserve(32)
        self._sm = &null
    }

    /// # DiagConsumer interface

    fn handle(self, diag: unsafe *Diagnostic) {
        self._diags.push_back(diag)
    }

    /// Hands every buffered diagnostic to \p other and forgets it. The flag
    /// parser reports into this consumer (it is the default one, and the
    /// output format is not known until the flags are parsed); when the
    /// driver then swaps in the basic/json consumer, dropping this buffer
    /// with it lost every parse-time warning under --error-format=basic.
    pub fn drain_into(self, other: unsafe *DiagConsumer) {
        for var i: usize = 0; i < self._diags.size(); ++i {
            other->handle(self._diags[i])
        }

        self._diags.clear()
    }

    pub fn attach_source_manager(self, sm: unsafe *SourceManager) {
        self._sm = sm
    }

    pub fn configure(self, show_context: bool, ctx_lines: u32, abs_paths: bool) {
        self._show_context = show_context
        self._ctx_lines    = ctx_lines
        self._abs_paths    = abs_paths
    }

    /// Lines shown BEFORE the caret line. The window is _ctx_lines including
    /// the caret line itself, so 3 (the default) is the two-line lead-in the
    /// renderer always had. 0 is "no limit": everything above the caret.
    priv fn ctx_before(self) -> u32 {
        if self._ctx_lines == 0 {
            return 0xFFFFFF
        }

        return self._ctx_lines - 1
    }

    /// "<...>" names are synthetic buffers, not files; never join them onto
    /// the cwd.
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
        var color = self.detect_color_stderr()
        // stdout is block-buffered when piped and stderr is not: without
        // this a diagnostic lands in the middle of a dump line under 2>&1.
        cxx::std::fflush(kairo::std_out())
        var out = self.replay + self.render_all(color)
        // See BasicConsumer::finalize_to_stderr: clear the pinned line first.
        kairo::ProgressMeter::hold()
        io::eprint("")
        io::eprint(f"{out}")
        kairo::ProgressMeter::release()
    }

    /// How many diagnostics are buffered.
    pub fn count(self) -> usize {
        return self._diags.size()
    }

    /// The colour finalize_to_stderr would use.
    pub fn stderr_color(self) -> bool {
        return self.detect_color_stderr()
    }

    /// The stderr text of buffered diagnostics [\p a, \p b), rendered as
    /// a set of their own: coalescing never crosses the range's ends, so a
    /// replay is exact only when nothing outside it shares a line with it
    /// (Compiler/Spec/IncrementalSema.md#phase-2).
    pub fn render_range(self, a: usize, b: usize) -> string {
        var all  = self._diags
        var part = cxx::std::vector<unsafe *Diagnostic>()
        for var i: usize = a; i < b && i < all.size(); ++i {
            part.push_back(all[i])
        }

        self._diags = part
        var out = self.render_all(self.detect_color_stderr())
        self._diags = all
        return out
    }

    fn finalize_to_stdout(self) {
        var color = self.detect_color_stdout()
        var out   = self.render_all(color)
        io::print("")
        io::print(f"{out}")
    }

    fn finalize_to_file(self, const path: string) {
        // render_all coalesces across the whole set, so the text exists only
        // once it is complete; it goes out in one write. OF_None: binary --
        // the bytes are already UTF-8, nothing to translate.
        var out                      = self.render_all(false)
        var ec: cxx::std::error_code
        var f = llvm::raw_fd_ostream(kairo::sref(path), &ec, llvm::sys::fs::OF_None)
        if ec.value() != 0 {
            return
        }

        f.write(out.c_str(), out.size())
    }

    fn finalize_to_string(self) -> string {
        return self.render_all(false)
    }

    pub fn set_color(self, enable: bool) {
        if !enable {
            self.RESET    = ""
            self.BOLD     = ""
            self.DIM      = ""
            self.BOLD_RED = ""
            self.RED      = ""
            self.YELLOW   = ""
            self.CYAN     = ""
            self.BLUE     = ""
            self.MAGENTA  = ""
            self.WHITE    = ""
            self.GREEN    = ""
            self.STRIKE   = ""
        }
    }

    /// # Coalescing & Rendering

    priv fn render_all_uncoalesced(self, color: bool) -> string {
        var out: string
        for var i: usize = 0; i < self._diags.size(); ++i {
            out += self.render_single(self._diags[i], color, "")
        }

        return out
    }

    /// Returns numeric priority for severity (lower = more severe).
    priv fn severity_priority(self, sev: DiagSeverity) -> u8 {
        match sev {
            case DiagSeverity::Fatal {
                return 0
            } case DiagSeverity::Error {
                return 1
            } case DiagSeverity::Warning {
                return 2
            } case DiagSeverity::Note {
                return 3
            } case DiagSeverity::Remark {
                return 4
            } case DiagSeverity::Debug {
                return 5
            } case DiagSeverity::Verbose {
                return 6
            } case DiagSeverity::Ignored {
                return 7
            } default {
                return 8
            }
        }
    }

    /// Returns the fixed-width severity label (padded to 7 chars for alignment).
    priv fn severity_label_padded(self, sev: DiagSeverity) -> string {
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

    priv fn severity_label_raw(self, sev: DiagSeverity) -> string {
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

    priv fn render_all(self, color: bool) -> string {
        if self._sm == &null {
            return self.render_all_uncoalesced(color)
        }

        var unsafe *sm                                 = self._sm
        var        groups: cxx::std::vector<DiagGroup>

        for var i: usize = 0; i < self._diags.size(); ++i {
            var unsafe *diag = self._diags[i]
            if !diag->has_loc {
                var g: DiagGroup
                g.key.file_id = 0xFFFFFFFF
                g.key.line    = (i as u32)
                g.diags.push_back(diag)
                g.filename = ""
                g.line_num = 0
                groups.push_back(g)
                continue
            }

            var loc_info              = sm->get_line_col(diag->loc)
            var res                   = sm->resolve(diag->loc)
            var key:     DiagGroupKey
            key.file_id = (res.fid as u32)
            key.line    = (loc_info.line as u32)

            var found: isize = -1
            for var j: usize = 0; j < groups.size(); ++j {
                if groups[j].key == key {
                    found = (j as isize)
                    break
                }
            }

            if found >= 0 {
                groups[found as usize].diags.push_back(diag)
            } else {
                var g: DiagGroup
                g.key      = key
                g.filename = self.display_path(sm->get_filename(diag->loc))
                g.line_num = (loc_info.line as u32)
                g.col_num  = (loc_info.column as u32)
                g.diags.push_back(diag)
                groups.push_back(g)
            }
        }

        var out: string
        for var i: usize = 0; i < groups.size(); ++i {
            out += self.render_group(&groups[i], sm, color)
        }

        return out
    }

    /// Codes render on standalone diagnostics regardless of severity a
    /// top-level note is independently suppressible and greppable. Children are
    /// supporting evidence for their parent and have no independent existence,
    /// so a code there is noise.
    priv fn code_prefix(self,
                        code:     DiagCode,
                        sev:      DiagSeverity,
                        color:    bool,
                        is_child: bool) -> string {
        if is_child {
            return ""
        }

        if color {
            return f"{self.severity_color(sev)}[{(code) as string}]{self.RESET} "
        }

        return f"[{(code) as string}] "
    }

    /// Fix-it message lines and deduped child notes of a group; shared by the
    /// snippet and the snippet-less (--diag-show-context=false) renderings.
    priv fn render_group_tail(self, @inout group: DiagGroup, color: bool) -> string {
        const NL          = "\n"
        var   out: string
        // --- Fix-its: the edit is already shown inline on the primary line;
        // here we only print the trailing "> fix: <message>" line.
        for var i: usize = 0; i < group.diags.size(); ++i {
            var unsafe *diag = group.diags[i]
            for var j: usize = 0; j < diag->fixits.size(); ++j {
                var fi      = diag->fixits[j]
                var fix_pfx = if (color) => (f"{self.BOLD}{self.CYAN}fix{self.RESET}") else => "fix"
                if fi.message.length() > 0 {
                    out += f" > {fix_pfx}: {fi.message}" + NL
                }
            }
        }

        /// ## Children (deduped: identical child notes render once)
        var seen_children: cxx::std::vector<string>
        for var i: usize = 0; i < group.diags.size(); ++i {
            var unsafe *diag = group.diags[i]
            for var j: usize = 0; j < diag->children.size(); ++j {
                var unsafe *c = diag->children[j]

                var key = f"{(c->code) as string}|{c->message}|{c->loc.id}"

                var dup = false
                for var k: usize = 0; k < seen_children.size(); ++k {
                    if seen_children[k] == key {
                        dup = true
                        break
                    }
                }

                if dup {
                    continue
                }

                seen_children.push_back(key)
                out += self.render_single(c, color, "    ", true)
            }
        }

        return out
    }

    /// True when \p d's caret rows on \p line would not carry its
    /// "[CODE] message": render_group gives the message to the first label on
    /// the line only when that label has no text of its own.
    priv fn _labels_hide_message(self,
                                 d:    unsafe *Diagnostic,
                                 sm:   unsafe *SourceManager,
                                 fid:  u32,
                                 line: usize) -> bool {
        for var li: usize = 0; li < d->labels.size(); ++li {
            if d->labels[li].range.is_invalid() {
                continue
            }

            if !self._on_line(d->labels[li].range.start, sm, fid, line) {
                continue
            }

            return d->labels[li].text.length() > 0
        }

        return false
    }

    priv fn render_group(self,
                         @inout group: DiagGroup,
                         sm:           unsafe *SourceManager,
                         color:        bool) -> string {
        const NL              = "\n"
        var   out:     string
        var   renderer        = TermRenderer(color, 80)

        if group.key.file_id == 0xFFFFFFFF {
            for var i: usize = 0; i < group.diags.size(); ++i {
                out += self.render_single(group.diags[i], color, "")
            }

            return out
        }

        // Determine the highest severity present in the group
        var highest_sev = DiagSeverity::Ignored
        for var i: usize = 0; i < group.diags.size(); ++i {
            var sev = group.diags[i]->code.severity()
            if self.severity_priority(sev) < self.severity_priority(highest_sev) {
                highest_sev = sev
            }
        }

        var sev_name = self.severity_label_raw(highest_sev)
        var sev_col  = self.severity_color(highest_sev)
        var sev_str  = if color => (f"{sev_col}{self.BOLD}{sev_name}{self.RESET}") else => sev_name

        // Context window properties
        var ctx_before: u32 = self.ctx_before()
        var ctx_after:  u32 = 0
        var first_line = if (group.line_num > ctx_before) => (group.line_num - ctx_before) else => 1

        // Skip leading blank lines in context window
        while first_line < group.line_num {
            var text = sm->get_line_text(group.key.file_id, first_line)
            if self.is_line_blank(text) {
                first_line += 1
            } else {
                break
            }
        }

        var last_line          = group.line_num + ctx_after
        var max_num_len: usize = f"{last_line}".length()

        // Calculate unified indentation padding so gutter pipe aligns below '@'
        var left_pad = sev_name.length()
        if max_num_len > left_pad {
            left_pad = max_num_len
        }

        var pad_len    = left_pad - sev_name.length()
        var header_pad = string(' ' as u8, pad_len)

        // Header format: "severity @ filename:line:col"
        out += f"{sev_str}{header_pad} @ {group.filename}:{group.line_num}:{group.col_num}" + NL

        // A diagnostic whose every label on this line has its own text has no
        // row left to carry "[CODE] message" (the caret rows below use the
        // label text), so it gets the line the no-snippet form prints. Without
        // it an OPT002R showed only "every payload at most 8 bytes keeps it at
        // 16": no code, no message.
        if self._show_context {
            for var i: usize = 0; i < group.diags.size(); ++i {
                var unsafe *nd = group.diags[i]
                if self._labels_hide_message(nd, sm, group.key.file_id, group.line_num as usize) {
                    out += "  " + self.code_prefix(
                        nd->code,
                        nd->code.severity(),
                        color,
                        false,
                    ) + nd->message + NL
                }
            }
        }

        // No snippet: one "[CODE] message" line per diagnostic, in place of the
        // caret rows that normally carry the message.
        if !self._show_context {
            for var i: usize = 0; i < group.diags.size(); ++i {
                var unsafe *nd = group.diags[i]
                out += "  " + self.code_prefix(
                    nd->code,
                    nd->code.severity(),
                    color,
                    false,
                ) + nd->message + NL
            }

            out += self.render_group_tail(&group, color)
            return out + NL
        }

        /// ## Build caret spans

        var unsafe *first_diag = group.diags[0]
        var        line_text   = sm->get_full_line(first_diag->loc)
        var        lang        = self.snippet_lang(group.filename)

        var spans:     cxx::std::vector<CaretSpan>
        var span_text: cxx::std::vector<string>

        for var i: usize = 0; i < group.diags.size(); ++i {
            var unsafe *diag = group.diags[i]
            var        dsev  = diag->code.severity()

            var default_text = if color => (f"{self.severity_color(dsev)}[{(diag->code) as string}]{self.RESET} ")
                               else => f"[{(diag->code) as string}] "
            default_text += diag->message

            var emitted_any = false

            for var li: usize = 0; li < diag->labels.size(); ++li {
                var label = diag->labels[li]
                if label.range.is_invalid() {
                    continue
                }

                // A label in another file can share this line NUMBER: a note
                // label on a header declaration at the call's line once drew
                // the whole declaration's width from column 1 under the call
                // (P961). Only labels in this group's file belong here.
                if !self._on_line(label.range.start, sm, group.key.file_id, group.line_num as usize) {
                    continue
                }

                var span: CaretSpan
                span.code  = diag->code
                span.sev   = dsev
                span.style = label.style
                self._place_span(&span, line_text, label.range, sm)

                var ltext: string = label.text
                if (ltext.length() == 0) && (!emitted_any) {
                    ltext = default_text
                }

                emitted_any = true

                spans.push_back(span)
                span_text.push_back(ltext)
            }

            if !emitted_any {
                // no label on this line: fall back to the diag loc itself
                var span: CaretSpan
                span.code  = diag->code
                span.sev   = dsev
                span.style = DiagLabel::Style::Primary
                var at     = SourceRange::invalid()
                at.start = diag->loc
                at.end   = diag->loc
                self._place_span(&span, line_text, at, sm)

                spans.push_back(span)
                span_text.push_back(default_text)
            }
        }

        // Sort spans (and their labels) by start column, left to right
        for var i: usize = 1; i < spans.size(); ++i {
            var key_span       = spans[i]
            var key_text       = span_text[i]
            var j:       isize = (i as isize) - 1
            while j >= 0 && spans[j as usize].start_col > key_span.start_col {
                spans[(j + 1) as usize]     = spans[j as usize]
                span_text[(j + 1) as usize] = span_text[j as usize]
                j -= 1
            }

            spans[(j + 1) as usize]     = key_span
            span_text[(j + 1) as usize] = key_text
        }

        // Find a fix-it anchored on the primary line. If present, the fix is
        // rendered IN PLACE: the primary source line shows the edited text
        // (removed span struck red, inserted text green, rest syntax-
        // highlighted) and the caret row carries '-'/'+' change markers at the
        // edit columns. Caret, label-message rows, and every other line render
        // exactly as they would without a fix-it.
        var has_primary_fix: bool  = false
        var primary_fix:     FixIt
        for var di: usize = 0; di < group.diags.size(); ++di {
            var unsafe *dg = group.diags[di]
            for var fj: usize = 0; fj < dg->fixits.size(); ++fj {
                var pf = dg->fixits[fj]
                if pf.range.is_valid()
                    && self._on_line(pf.range.start, sm, group.key.file_id, group.line_num as usize) {
                    primary_fix     = pf
                    has_primary_fix = true
                }
            }
        }

        // Fix-it geometry, 0-based byte columns clamped to the primary line
        // (render_fixed_line slices the text with them), and the same edit in
        // terminal cells for the '-'/'+' markers on the caret row.
        var fix_start_col:  usize  = 0
        var fix_mid_len:    usize  = 0 ///< removed span bytes
        var fix_start_cell: usize  = 0
        var fix_mid_cells:  usize  = 0 ///< removed span width ('-' markers)
        var fix_ins_cells:  usize  = 0 ///< inserted text width ('+' markers)
        var shown_text:     string = line_text ///< the primary line as printed
        if has_primary_fix {
            var fb        = self._byte_span(primary_fix.range, line_text.length(), sm)
            fix_start_col = fb.start_col
            var f_end_col = fb.end_col
            fix_mid_len   = f_end_col - fix_start_col
            var rep     = primary_fix.replacement

            fix_start_cell = self._cells(line_text, fix_start_col)
            fix_mid_cells  = self._cells(line_text, f_end_col) - fix_start_cell
            fix_ins_cells  = self._cells(rep, rep.length())

            // The fixed line keeps the removed text (struck) AND adds the
            // inserted text, so every column past the edit moves right by
            // the insert width. Shift labels there, or a label after an
            // insert (`fn f(self) const` -> strike on const) lands under
            // the wrong token. A label that runs across the edit stretches
            // over the insert, or it stops that many cells short of its end.
            var edit_end = fix_start_cell + fix_mid_cells
            for var s: usize = 0; s < spans.size(); ++s {
                if spans[s].start_col >= edit_end {
                    spans[s].start_col += fix_ins_cells
                    spans[s].end_col += fix_ins_cells
                } else if spans[s].end_col > edit_end {
                    spans[s].end_col += fix_ins_cells
                }
            }

            // The caret rows sit under the line as printed, insert included.
            var fixed: string
            for var i: usize = 0; i < f_end_col; ++i {
                fixed.push_back(line_text[i])
            }

            fixed += rep
            for var i: usize = f_end_col; i < line_text.length(); ++i {
                fixed.push_back(line_text[i])
            }

            shown_text = fixed
        }

        // Per-column severity map (for overlap coloring on the caret row)
        var max_col: usize = 0
        for var s: usize = 0; s < spans.size(); ++s {
            if spans[s].end_col > max_col {
                max_col = spans[s].end_col
            }
        }

        var col_sev:   cxx::std::vector<DiagSeverity>
        var col_style: cxx::std::vector<DiagLabel::Style>
        col_sev.resize(max_col + 1, DiagSeverity::Ignored)
        col_style.resize(max_col + 1, DiagLabel::Style::Primary)

        for var s: usize = 0; s < spans.size(); ++s {
            var span = spans[s]
            for var col: usize = span.start_col; col < span.end_col; ++col {
                if self.severity_priority(span.sev) < self.severity_priority(col_sev[col]) {
                    col_sev[col]   = span.sev
                    col_style[col] = span.style
                }
            }
        }

        var pipe         = if (color) => (f"{self.BOLD}{self.WHITE}|{self.RESET}") else => "|"
        var line_col_esc = if (color) => (f"{self.BOLD}{self.WHITE}") else => ""
        var reset_esc    = if (color) => (self.RESET) else => ""

        // Gutter aligned precisely to left_pad
        var conn_gutter = f"{string((' ' as u8), left_pad)} {pipe} "

        for var ln: u32 = first_line; ln <= last_line; ++ln {
            var text    = sm->get_line_text(group.key.file_id, ln)
            var num_str = f"{ln}"
            var npad    = string(' ' as u8, left_pad - num_str.length())
            var prefix  = f"{npad}{line_col_esc}{num_str} {pipe} {reset_esc}"

            if ln == group.line_num && has_primary_fix {
                out += prefix + self.render_fixed_line(
                    &renderer,
                    line_text,
                    fix_start_col,
                    fix_mid_len,
                    primary_fix.replacement,
                    color,
                    lang,
                ) + NL
            } else {
                out += prefix + renderer.highlight_snippet(text, lang) + NL
            }

            if ln != group.line_num {
                continue
            }

            /// ### Caret row: ^^^ per span + fix-it change markers
            /// Column-addressed so fix markers can overlay carets: '-' (red)
            /// over removed columns, '+' (green) under inserted text, both in
            /// fixed-line coordinates.
            var fix_end_cell: usize = fix_start_cell + fix_mid_cells + fix_ins_cells
            var row_cols:     usize = max_col
            if has_primary_fix && fix_end_cell > row_cols {
                row_cols = fix_end_cell
            }

            var row_glyph: cxx::std::vector<u8>
            var row_color: cxx::std::vector<string>
            row_glyph.resize(row_cols, ' ' as u8)
            row_color.resize(row_cols, string())

            for var s: usize = 0; s < spans.size(); ++s {
                var span  = spans[s]
                var glyph = self.label_char(span.style)
                for var c: usize = span.start_col; c < span.end_col; ++c {
                    row_glyph[c] = glyph
                    row_color[c] = self.severity_color(col_sev[c])
                }
            }

            if has_primary_fix {
                var mc: usize = fix_start_cell
                for var c: usize = 0; c < fix_mid_cells; ++c {
                    row_glyph[mc] = ('-' as u8)
                    row_color[mc] = self.RED
                    mc += 1
                }

                for var c: usize = 0; c < fix_ins_cells; ++c {
                    row_glyph[mc] = ('+' as u8)
                    row_color[mc] = self.GREEN
                    mc += 1
                }
            }

            var under = self._blank(shown_text, 0, row_cols) ///< one byte per cell
            var caret_row: string
            for var c: usize = 0; c < row_cols; ++c {
                if row_glyph[c] == (' ' as u8) {
                    caret_row.push_back(under[c])
                    continue
                }

                // One glyph byte, appended: string(ch, 1) is lib-helix's (char, count)
                // repeat ctor, which the migration misread as (pointer, length).
                var mark = string()
                mark.push_back(row_glyph[c])
                if color {
                    var mcol = row_color[c]
                    caret_row += f"{mcol}{mark}{self.RESET}"
                } else {
                    caret_row += mark
                }
            }

            out += conn_gutter + caret_row + NL

            /// ### Stacked label rows
            var active_spans: cxx::std::vector<CaretSpan>
            var active_texts: cxx::std::vector<string>
            for var s: usize = 0; s < spans.size(); ++s {
                if span_text[s].length() > 0 {
                    active_spans.push_back(spans[s])
                    active_texts.push_back(span_text[s])
                }
            }

            var n_active = active_spans.size()

            // Print one label per row, from rightmost span to leftmost.
            for var r: isize = (n_active as isize) - 1; r >= 0; r -= 1 {
                var ri         = (r as usize)
                var msg_anchor = active_spans[ri].start_col

                var row: string
                var col: usize  = 0

                // connectors for spans strictly to the LEFT of this row's message
                for var s: usize = 0; s < ri; ++s {
                    var anchor = active_spans[s].start_col
                    if anchor >= msg_anchor {
                        continue
                    }

                    if anchor < col {
                        continue
                    }

                    row += self._blank(shown_text, col, anchor)
                    if color {
                        var ce = self.severity_color(active_spans[s].sev)
                        row += f"{ce}|{self.RESET}"
                    } else {
                        row += "|"
                    }

                    col = anchor + 1
                }

                // the message, always padded to its own anchor
                if msg_anchor > col {
                    row += self._blank(shown_text, col, msg_anchor)
                }

                var msg = active_texts[ri]
                row += if color => (f"{self.RESET}{msg}") else => msg

                out += conn_gutter + row + NL
            }
        }

        out += self.render_group_tail(&group, color)

        return out + NL
    }

    priv fn render_single(self,
                          diag:     unsafe *Diagnostic,
                          color:    bool,
                          indent:   string,
                          is_child: bool = false) -> string {
        const NL          = "\n"
        var   out: string

        var sev      = diag->code.severity()
        var sev_name = self.severity_label_raw(sev)
        var sev_col  = self.severity_color(sev)
        var sev_str = if (color) => (f"{sev_col}{self.BOLD}{sev_name}{self.RESET}") else => sev_name

        if !diag->has_loc || self._sm == &null {
            if is_child {
                out += indent + f"{sev_str}: {diag->message}" + NL
            } else {
                var the_code = diag->code
                var code_str = if (color) => (sev_col + (the_code as string) + self.RESET)
                               else => (the_code as string)
                out += indent + f"{sev_str} [{code_str}]: {diag->message}" + NL
            }

            for var i: usize = 0; i < diag->fixits.size(); ++i {
                var fi      = diag->fixits[i]
                var fix_pfx = if (color) => (f"{self.BOLD}{self.CYAN}fix{self.RESET}") else => "fix"
                if fi.message.length() > 0 {
                    out += indent + f"  > {fix_pfx}: {fi.message}" + NL
                }
            }

            for var i: usize = 0; i < diag->children.size(); ++i {
                out += self.render_single(diag->children[i], color, indent + "    ", true)
            }

            return out
        }

        var unsafe *sm      = self._sm
        var        loc_info = sm->get_line_col(diag->loc)
        var        filename = self.display_path(sm->get_filename(diag->loc))

        // Find the maximum line width in the target labels to calculate padding
        var max_num_len                              = f"{loc_info.line}".length()
        var temp_labels: cxx::std::vector<DiagLabel>

        var has_own_text = false
        if diag->labels.size() > 0 {
            for var i: usize = 0; i < diag->labels.size(); ++i {
                temp_labels.push_back(diag->labels[i])
                var l_line = sm->get_line_col(diag->labels[i].range.start).line
                var l_len  = f"{l_line}".length()
                if l_len > max_num_len {
                    max_num_len = l_len
                }
            }

            // The message is on the Diagnostic, not the label. If no label carries
            // text, attach it to the first primary one or it is never rendered.
            var has_text = false
            for var i: usize = 0; i < temp_labels.size(); ++i {
                if temp_labels[i].text.length() > 0 {
                    has_text = true
                    break
                }
            }

            has_own_text = has_text
            if !has_text {
                temp_labels[0].text = self.code_prefix(
                    diag->code,
                    sev,
                    color,
                    is_child,
                ) + diag->message
            }
        } else {
            var label: DiagLabel
            label.range.start = diag->loc
            label.range.end   = diag->loc
            label.style       = DiagLabel::Style::Primary
            label.text        = self.code_prefix(diag->code, sev, color, is_child) + diag->message
            temp_labels.push_back(label)
        }

        var sev_len  = sev_name.length()
        var left_pad = sev_len
        if max_num_len > left_pad {
            left_pad = max_num_len
        }

        var pad_len    = left_pad - sev_len
        var header_pad = string(' ' as u8, pad_len)

        out += indent + f"{sev_str}{header_pad} @ {filename}:{loc_info.line}:{loc_info.column}" + NL
        // Every label carries its own text, so none carries the message: give
        // it its own line, as render_group does.
        if self._show_context && has_own_text {
            out += indent + "  " + self.code_prefix(
                diag->code,
                sev,
                color,
                is_child,
            ) + diag->message + NL
        }

        // Render the source context snippet and label lines. With the snippet
        // hidden the message still has to appear: it normally rides on a label.
        if self._show_context {
            out += self.render_labels(&temp_labels, sm, indent, sev_col, color, left_pad)
        } else {
            out += indent + "  " + self.code_prefix(
                diag->code,
                sev,
                color,
                is_child,
            ) + diag->message + NL
        }

        for var i: usize = 0; i < diag->fixits.size(); ++i {
            var fi      = diag->fixits[i]
            var fix_pfx = if (color) => (f"{self.BOLD}{self.CYAN}fix{self.RESET}") else => "fix"
            if fi.message.length() > 0 {
                out += indent + f"  > {fix_pfx}: {fi.message}" + NL
            }
        }

        for var i: usize = 0; i < diag->children.size(); ++i {
            out += self.render_single(diag->children[i], color, indent + "    ", true)
        }

        return out
    }

    priv fn render_labels(self,
                          @inout labels: cxx::std::vector<DiagLabel>,
                          sm:            unsafe *SourceManager,
                          indent:        string,
                          sev_col:       string,
                          color:         bool,
                          left_pad:      usize) -> string {
        const NL          = "\n"
        var   out: string

        var pipe     = if (color) => (f"{self.BOLD}{self.WHITE}|{self.RESET}") else => "|"
        var renderer = TermRenderer(color, 80)

        var order: cxx::std::vector<usize>
        order.reserve(labels.size())
        for var i: usize = 0; i < labels.size(); ++i {
            order.push_back(i)
        }

        for var i: usize = 1; i < order.size(); ++i {
            var key            = order[i]
            var key_line       = sm->get_line_col(labels[(key)].range.start).line
            var j:       isize = (i as isize) - 1
            while j >= 0 {
                var cmp_line = sm->get_line_col(labels[order[j as usize]].range.start).line
                if cmp_line <= key_line {
                    break
                }

                order[(j + 1) as usize] = order[j as usize]
                j -= 1
            }

            order[(j + 1) as usize] = key
        }

        for var i: usize = 0; i < order.size(); ++i {
            var label = labels[order[i]]
            if label.range.is_invalid() {
                continue
            }

            var start_lc  = sm->get_line_col(label.range.start)
            var line_text = sm->get_full_line(label.range.start)

            var glyph_col = if color => (if (label.style == DiagLabel::Style::Primary) => (sev_col)
                                         else => self.DIM)
                            else => ""

            var line_num_str = f"{start_lc.line}"
            var pad_count    = left_pad - line_num_str.length()
            var num_pad      = string(' ' as u8, pad_count)
            var line_col     = if (color) => (f"{self.BOLD}{self.WHITE}") else => ""
            var reset_col    = if (color) => (self.RESET) else => ""

            var prefix_vis = f"{indent}{num_pad}{line_col}{line_num_str} {pipe} {reset_col}"

            /// ### leading context window (same policy as render_group)
            var ctx_before: u32 = self.ctx_before()
            var res             = sm->resolve(label.range.start)
            var fid             = res.fid
            var lang            = self.snippet_lang(sm->get_filename(label.range.start))
            var first_line = if (start_lc.line > (ctx_before as usize)) => (start_lc.line - (ctx_before as usize))
                             else => 1

            while (first_line) < start_lc.line {
                var t = sm->get_line_text((fid as u32), (first_line as u32))
                if self.is_line_blank(t) {
                    first_line += 1
                } else {
                    break
                }
            }

            for var ln: u32 = (first_line as u32); (ln as usize) < start_lc.line; ++ln {
                var t       = sm->get_line_text((fid as u32), ln)
                var num_str = f"{ln}"
                var npad    = string(' ' as u8, left_pad - num_str.length())
                out += f"{indent}{npad}{line_col}{num_str} {pipe} {reset_col}" + renderer.highlight_snippet(
                    t,
                    lang,
                ) + NL
            }

            out += prefix_vis + renderer.highlight_snippet(line_text, lang) + NL

            // The caret row keeps the gutter rail, exactly like render_group's
            // conn_gutter. Padding with a plain blank run the width of the
            // line-number prefix leaves note carets floating with no '|'
            // under the source line.
            var pad = f"{indent}{string((' ' as u8), left_pad)} {pipe} "
            var cells: CaretSpan
            self._place_span(&cells, line_text, label.range, sm)

            var glyph     = self.label_char(label.style)
            var lead      = self._blank(line_text, 0, cells.start_col)
            var underline = lead + string(glyph, cells.end_col - cells.start_col)

            out += pad + (if color => f"{glyph_col}{underline}{self.RESET}" else => underline)

            if label.text.length() > 0 {
                out += " " + label.text
            }

            out += NL
        }

        return out
    }

    /// # Helpers

    /// True when \p loc is on \p line of file \p fid. A line number alone is
    /// not a place: the call and the header declaration a note points at
    /// can both be on line 7.
    priv fn _on_line(self,
                     loc:  SourceLocation,
                     sm:   unsafe *SourceManager,
                     fid:  u32,
                     line: usize) -> bool {
        if (sm->resolve(loc).fid as u32) != fid {
            return false
        }

        return sm->get_line_col(loc).line == line
    }

    /// Puts \p span under \p range on \p line_text (the range's start line),
    /// in terminal cells: 0-based, end exclusive, inside the line and at
    /// least one cell wide (a point at the end of the line gets the cell
    /// just past it). A range that ends on a later line, or in another
    /// file, runs to the end of this one: its end column is that other
    /// line's, and measured against this one it stopped the underline short
    /// of the range or ran it past the text.
    priv fn _place_span(self,
                        @inout span:     CaretSpan,
                        const line_text: string,
                        range:           SourceRange,
                        sm:              unsafe *SourceManager) {
        var bytes = self._byte_span(range, line_text.length(), sm)
        span.start_col = self._cells(line_text, bytes.start_col)
        span.end_col   = self._cells(line_text, bytes.end_col)
        if span.end_col <= span.start_col {
            span.end_col = span.start_col + 1
        }
    }

    /// \p range on its start line of \p len bytes, as 0-based byte columns
    /// (end exclusive, possibly empty) clamped to the line; a range ending
    /// on another line or in another file runs to the line's end. Shared by
    /// labels and fix-its, whose removal markers had the same mismeasured
    /// end (`x = Tok(2)` struck five columns of ten).
    priv fn _byte_span(self, range: SourceRange, len: usize, sm: unsafe *SourceManager) -> CaretSpan {
        var start_lc  = sm->get_line_col(range.start)
        var end_lc    = sm->get_line_col(range.end)
        var b0: usize = if (start_lc.column > 0) => (start_lc.column - 1) else => 0
        var b1: usize = if (end_lc.column > 0) => (end_lc.column - 1) else => 0
        var same_file = sm->resolve(range.end).fid == sm->resolve(range.start).fid
        if (end_lc.line != start_lc.line) || (!same_file) {
            b1 = len
        }

        if b0 > len {
            b0 = len
        }

        if b1 > len {
            b1 = len
        }

        if b1 < b0 {
            b1 = b0
        }

        var out: CaretSpan
        out.start_col = b0
        out.end_col   = b1
        return out
    }

    /// Bytes of the one terminal cell that starts at byte \p i of \p text: a
    /// whole well-formed UTF-8 sequence, or else the maximal ill-formed
    /// subpart, which a terminal shows as one U+FFFD (Unicode's
    /// "substitution of maximal subparts"): `F4 90 80 80` is four cells,
    /// `E2 82 61` is two (`E2 82`, then `a`). Never 0.
    priv fn _cell_bytes(self, const text: string, i: usize) -> usize {
        var b = text[i] as u8
        if b < (0x80 as u8) {
            return 1
        }

        var need: usize = 0
        var lo:   u8    = 0x80 as u8 ///< the second byte's range; later ones are 80..BF
        var hi:   u8    = 0xBF as u8
        if (b >= (0xC2 as u8)) && (b <= (0xDF as u8)) {
            need = 1
        } else if b == (0xE0 as u8) {
            need = 2
            lo   = 0xA0 as u8
        } else if b == (0xED as u8) {
            need = 2
            hi   = 0x9F as u8
        } else if (b >= (0xE1 as u8)) && (b <= (0xEF as u8)) {
            need = 2
        } else if b == (0xF0 as u8) {
            need = 3
            lo   = 0x90 as u8
        } else if b == (0xF4 as u8) {
            need = 3
            hi   = 0x8F as u8
        } else if (b >= (0xF1 as u8)) && (b <= (0xF3 as u8)) {
            need = 3
        }

        var n: usize = 1
        while (n <= need) && ((i + n) < text.length()) {
            var c = text[i + n] as u8
            if n == 1 {
                if (c < lo) || (c > hi) {
                    break
                }
            } else if (c < (0x80 as u8)) || (c > (0xBF as u8)) {
                break
            }

            n += 1
        }

        return n
    }

    /// Terminal cells the first \p bytes bytes of \p text take (see
    /// _cell_bytes). Source columns are bytes; used as cells they put a
    /// caret after "é" one cell right of its token for every multi-byte
    /// character before it. A wide (East Asian) character still counts as
    /// one cell.
    priv fn _cells(self, const text: string, bytes: usize) -> usize {
        var n: usize = 0
        var i: usize = 0
        while (i < bytes) && (i < text.length()) {
            i += self._cell_bytes(text, i)
            n += 1
        }

        return n
    }

    /// The blank run under cells [\p from, \p to) of \p text: a tab under
    /// each tab, a space under everything else. The source row and the
    /// caret row have gutters of one width, so the terminal expands a tab
    /// in both to the same stop; a space under a tab left every caret after
    /// it short by the tab's width.
    priv fn _blank(self, const text: string, from: usize, to: usize) -> string {
        var out:  string
        var cell: usize = 0
        var i:    usize = 0
        while (i < text.length()) && (cell < to) {
            var b = text[i] as u8
            i += self._cell_bytes(text, i)
            if cell >= from {
                if b == ('\t' as u8) {
                    out.push_back('\t' as u8)
                } else {
                    out.push_back(' ' as u8)
                }
            }

            cell += 1
        }

        // Cells past the end of the text (a caret after the last character).
        if to > from {
            var want = to - from
            if out.length() < want {
                out += string(' ' as u8, want - out.length())
            }
        }

        return out
    }

    /// The highlighter language for a snippet of \p path: its extension, so
    /// a C/C++ input (or a header a clang note points into) is coloured as
    /// what it is. An extensionless file under an include directory is a
    /// C++ standard header (<string>, <vector>); anything else without an
    /// extension, a virtual buffer included, stays Kairo.
    priv fn snippet_lang(self, path: string) -> string {
        var ext = Path::extension_of(path)
        if ext.length() > 1 {
            return ext.subslice(1, ext.length() - 1)
        }

        var inc = "/include/"
        if kairo::sref(path).contains(kairo::sref(inc)) {
            return "c++"
        }

        return "kairo"
    }

    /// Renders the primary source line WITH its fix-it applied inline:
    ///
    ///   head (highlighted) + removed span (red, struck) +
    ///   inserted text (green) + tail (highlighted)
    ///
    /// Add has an empty removed span; Remove has an empty insertion; Replace
    /// has both. The change markers ('-'/'+') live on the caret row, not here.
    ///
    /// head/mid/tail are rebuilt char-by-char from the source line rather than
    /// via string(raw_string().substr(...)) rewrapping identical construction
    /// to SourceManager::get_text, so the highlighter's tokenizer sees exactly
    /// the same kind of string as any normal source line.
    priv fn render_fixed_line(self,
                              @inout renderer: TermRenderer,
                              const line_text: string,
                              start_col:       usize,
                              mid_len:         usize,
                              ins:             string,
                              color:           bool,
                              lang:            string) -> string {
        var head: string
        var mid:  string
        var tail: string
        head.reserve(start_col)
        for var i: usize = 0; i < start_col; ++i {
            head.push_back(line_text[i])
        }

        for var i: usize = start_col; i < start_col + mid_len; ++i {
            mid.push_back(line_text[i])
        }

        for var i: usize = start_col + mid_len; i < line_text.length(); ++i {
            tail.push_back(line_text[i])
        }

        var head_hl = renderer.highlight_snippet(head, lang)
        var tail_hl = renderer.highlight_snippet(tail, lang)
        var del_vis = if (color) => (f"{self.RED}{self.STRIKE}{mid}{self.RESET}") else => mid
        var ins_vis = if (color) => (f"{self.GREEN}{ins}{self.RESET}") else => ins

        if mid.length() == 0 {
            del_vis = ""
        }

        if ins.length() == 0 {
            ins_vis = ""
        }

        return head_hl + del_vis + ins_vis + tail_hl
    }

    priv fn severity_color(self, sev: DiagSeverity) -> string {
        match sev {
            case DiagSeverity::Fatal {
                return self.BOLD_RED
            } case DiagSeverity::Error {
                return self.RED
            } case DiagSeverity::Warning {
                return self.YELLOW
            } case DiagSeverity::Note {
                return self.CYAN
            } case DiagSeverity::Remark {
                return self.BLUE
            } case DiagSeverity::Debug {
                return self.MAGENTA
            } case DiagSeverity::Verbose {
                return self.DIM
            } case DiagSeverity::Ignored {
                return self.DIM
            } default {
                return ""
            }
        }
    }

    priv fn severity_string(self, sev: DiagSeverity, color: bool) -> string {
        var label: string = self.severity_label_raw(sev)
        if !color {
            return label
        }

        return f"{self.severity_color(sev)}{self.BOLD}{label}{self.RESET}"
    }

    priv fn label_char(self, style: DiagLabel::Style) -> u8 {
        match style {
            case DiagLabel::Style::Primary {
                return '^' as u8
            } case DiagLabel::Style::Secondary {
                return '+' as u8
            } case DiagLabel::Style::Highlight {
                return '-' as u8
            } case DiagLabel::Style::StrikeThrough {
                return '~' as u8
            }
        }
    }

    priv fn is_line_blank(self, const s: string) -> bool {
        for var i: usize = 0; i < s.length(); ++i {
            var c = s[i]
            if c != (' ' as u8) && c != ('\t' as u8) && c != ('\r' as u8) && c != ('\n' as u8) {
                return false
            }
        }

        return true
    }

    priv fn detect_color_stdout(self) -> bool {
        if cxx::std::getenv(r"NO_COLOR") != &null {
            return false
        }

        if isatty(fileno(kairo::std_out())) == 0 {
            return false
        }

        return true
    }

    priv fn detect_color_stderr(self) -> bool {
        if cxx::std::getenv(r"NO_COLOR") != &null {
            return false
        }

        if isatty(fileno(kairo::std_err())) == 0 {
            return false
        }

        return true
    }
}
