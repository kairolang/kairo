/// --- The Kairo Project ------------------ Diagnostic/PrettyConsumer.k --- ///
///
///   ANSI-colored diagnostic consumer.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh";

import Diagnostic::Diagnostic::*;
import Diagnostic::Consumer::*;
import Location::SourceManager::*;
import Support::TermRenderer::*;

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
struct DiagGroupKey {
    pub var file_id: u32;
    pub var line:    u32;

    fn op== (self, other: DiagGroupKey) -> bool {
        return (self.file_id == other.file_id) && (self.line == other.line);
    }

    fn op< (self, other: DiagGroupKey) -> bool {
        if self.file_id != other.file_id { return self.file_id < other.file_id; }
        return self.line < other.line;
    }
}

/// Key for grouping diagnostics by code AND message.
struct DiagCodeMsgKey {
    pub var code: DiagCode;
    pub var msg:  string;
    pub var sev:  DiagSeverity;

    fn op== (self, other: DiagCodeMsgKey) -> bool {
        return (self.code == other.code) && (self.msg == other.msg);
    }
}

/// Entry tracking a caret span for coalesced rendering.
struct CaretSpan {
    pub var start_col: usize;  ///< 0-indexed column start
    pub var end_col:   usize;  ///< 0-indexed column end (exclusive)
    pub var code:      DiagCode;
    pub var sev:       DiagSeverity;
    pub var style:     DiagLabel::Style;
}

/// Group of diagnostics on the same file:line, to be rendered together.
struct DiagGroup {
    pub var key:      DiagGroupKey;
    pub var diags:    vec::<obs::<Diagnostic>>;
    pub var filename: string;
    pub var line_num: u32;
}

/// ANSI-colored diagnostic consumer with same-line coalescing.
///
/// When multiple diagnostics target the same source line, they are merged:
/// - Same code + same message: single header line
/// - Same code + different message: stacked headers with severity label only on first
/// - Different codes: partitioned underline rows with [CODE] suffixes
///
/// Overlapping caret spans use the color of the highest severity diagnostic.
class PrettyDiagConsumer derives DiagConsumer {
    priv var _diags: vec::<obs::<Diagnostic>>;
    priv var _sm:    opt::<SourceManager>;

    // --- ANSI escape codes --------------------------------------------------
    priv var RESET:    string = "\x1b[0m";
    priv var BOLD:     string = "\x1b[1m";
    priv var DIM:      string = "\x1b[2;37m";
    priv var BOLD_RED: string = "\x1b[1;31m";
    priv var RED:      string = "\x1b[31m";
    priv var YELLOW:   string = "\x1b[33m";
    priv var CYAN:     string = "\x1b[36m";
    priv var BLUE:     string = "\x1b[34m";
    priv var MAGENTA:  string = "\x1b[35m";
    priv var WHITE:    string = "\x1b[37m";

    // --- Constructors --------------------------------------------------------

    fn PrettyDiagConsumer(self, sm: *SourceManager) {
        self._diags.reserve(32);
        self._sm = sm;
    }

    fn PrettyDiagConsumer(self) {
        self._diags.reserve(32);
        self._sm = &null;
    }

    // --- DiagConsumer interface ----------------------------------------------

    fn handle(self, diag: *Diagnostic) {
        self._diags.push_back(diag);
    }

    fn attach_source_manager(self, sm: *SourceManager) {
        self._sm = sm;
    }

    fn finalize_to_stderr(self) {
        var color = self.detect_color_stderr();
        var out = self.render_all(color);
        std::eprint("");
        std::eprint(out);
    }

    fn finalize_to_stdout(self) {
        var color = self.detect_color_stdout();
        var out = self.render_all(color);
        std::print("", std::endl(""));
        std::print(out, std::endl(""));
    }

    fn finalize_to_file(self, path: string) {
        var out = self.render_all(false);
        var f = libcxx::wofstream(libcxx::filesystem::path(path.raw()));
        f << out.raw();
        f.close();
    }

    fn finalize_to_string(self) -> string {
        return self.render_all(false);
    }

    fn set_color(self, enable: bool) {
        if !enable {
            self.RESET    = "";
            self.BOLD     = "";
            self.DIM      = "";
            self.BOLD_RED = "";
            self.RED      = "";
            self.YELLOW   = "";
            self.CYAN     = "";
            self.BLUE     = "";
            self.MAGENTA  = "";
            self.WHITE    = "";
        }
    }

    // --- Coalescing & Rendering ----------------------------------------------

    priv fn render_all_uncoalesced(self, color: bool) -> string {
        var out: string;
        for var i: usize = 0; i < self._diags.size(); ++i {
            out += self.render_single(self._diags[i], color, "");
        }
        return out;
    }

    /// Returns numeric priority for severity (lower = more severe).
    priv fn severity_priority(self, sev: DiagSeverity) -> u8 {
        switch sev {
        case DiagSeverity::Fatal   { return 0; }
        case DiagSeverity::Error   { return 1; }
        case DiagSeverity::Warning { return 2; }
        case DiagSeverity::Note    { return 3; }
        case DiagSeverity::Remark  { return 4; }
        case DiagSeverity::Debug   { return 5; }
        case DiagSeverity::Verbose { return 6; }
        case DiagSeverity::Ignored { return 7; }
        default                    { return 8; }
        }
    }

    /// Returns the fixed-width severity label (padded to 7 chars for alignment).
    priv fn severity_label_padded(self, sev: DiagSeverity) -> string {
        switch sev {
        case DiagSeverity::Fatal   { return "fatal"; }
        case DiagSeverity::Error   { return "error"; }
        case DiagSeverity::Warning { return "warning"; }
        case DiagSeverity::Note    { return "note"; }
        case DiagSeverity::Remark  { return "remark"; }
        case DiagSeverity::Debug   { return "debug"; }
        case DiagSeverity::Verbose { return "verbose"; }
        case DiagSeverity::Ignored { return "ignored"; }
        default                    { return "unknown"; }
        }
    }

    priv fn severity_label_raw(self, sev: DiagSeverity) -> string {
        switch sev {
        case DiagSeverity::Fatal   { return "fatal"; }
        case DiagSeverity::Error   { return "error"; }
        case DiagSeverity::Warning { return "warning"; }
        case DiagSeverity::Note    { return "note"; }
        case DiagSeverity::Remark  { return "remark"; }
        case DiagSeverity::Debug   { return "debug"; }
        case DiagSeverity::Verbose { return "verbose"; }
        case DiagSeverity::Ignored { return "ignored"; }
        default                    { return "unknown"; }
        }
    }
    
    priv fn render_all(self, color: bool) -> string {
        if self._sm == &null {
            return self.render_all_uncoalesced(color);
        }

        var sm = self._sm;
        var groups: vec::<DiagGroup>;

        for var i: usize = 0; i < self._diags.size(); ++i {
            var diag = self._diags[i];
            if (!diag->has_loc) {
                var g: DiagGroup;
                g.key.file_id = 0xFFFFFFFF;
                g.key.line    = static_cast::<u32>(i);
                g.diags.push_back(diag);
                g.filename = "";
                g.line_num = 0;
                groups.push_back(g);
                continue;
            }

            var loc_info = sm->get_line_col(diag->loc);
            var res      = sm->resolve(diag->loc);
            var key: DiagGroupKey;
            key.file_id = res.fid;
            key.line    = loc_info.line;

            var found: isize = -1;
            for var j: usize = 0; j < groups.size(); ++j {
                if groups[j].key == key {
                    found = static_cast::<isize>(j);
                    break;
                }
            }

            if found >= 0 {
                groups[static_cast::<usize>(found)].diags.push_back(diag);
            } else {
                var g: DiagGroup;
                g.key      = key;
                g.filename = sm->get_filename(diag->loc);
                g.line_num = loc_info.line;
                g.diags.push_back(diag);
                groups.push_back(g);
            }
        }

        var out: string;
        for var i: usize = 0; i < groups.size(); ++i {
            out += self.render_group(groups[i], sm, color);
        }

        return out;
    }

    /// Codes render on standalone diagnostics regardless of severity a
    /// top-level note is independently suppressible and greppable. Children are
    /// supporting evidence for their parent and have no independent existence,
    /// so a code there is noise.
    priv fn code_prefix(self, code: DiagCode, sev: DiagSeverity, color: bool, is_child: bool) -> string {
        if is_child { return ""; }
        if color {
            return f"{self.severity_color(sev)}[{(code) as string}]{RESET} ";
        }
        return f"[{(code) as string}] ";
    }

    priv fn render_group(self, group: ref!(DiagGroup), sm: *SourceManager, color: bool) -> string {
        const var NL = "\n";
        var out: string;
        var renderer = TermRenderer(color, 80);

        if group.key.file_id == 0xFFFFFFFF {
            for var i: usize = 0; i < group.diags.size(); ++i {
                out += self.render_single(group.diags[i], color, "");
            }
            return out;
        }

        // Determine the highest severity present in the group
        var highest_sev = DiagSeverity::Ignored;
        for var i: usize = 0; i < group.diags.size(); ++i {
            var sev = group.diags[i]->code.severity();
            if self.severity_priority(sev) < self.severity_priority(highest_sev) {
                highest_sev = sev;
            }
        }

        var sev_name = self.severity_label_raw(highest_sev);
        var sev_col  = self.severity_color(highest_sev);
        var sev_str  = (f"{sev_col}{BOLD}{sev_name}{RESET}") if color else sev_name;

        // Context window properties
        var ctx_before: u32 = 2;
        var ctx_after:  u32 = 0;
        var first_line = (group.line_num - ctx_before) if (group.line_num > ctx_before) else 1;

        // Skip leading blank lines in context window
        while first_line < group.line_num {
            var text = sm->get_line_text(group.key.file_id, first_line);
            if self.is_line_blank(text) {
                first_line += 1;
            } else {
                break;
            }
        }

        var last_line = group.line_num + ctx_after;
        var max_num_len: usize = f"{last_line}".length();

        // Calculate unified indentation padding so gutter pipe aligns below '@'
        var left_pad = sev_name.length();
        if max_num_len > left_pad {
            left_pad = max_num_len;
        }

        var pad_len = left_pad - sev_name.length();
        var header_pad = string(' ', pad_len);

        // Header format: "severity @ filename:line"
        out += f"{sev_str}{header_pad} @ {group.filename}:{group.line_num}" + NL;

        // --- Build caret spans -------------------------------------------------

        var first_diag = group.diags[0];
        var line_text  = sm->get_full_line(first_diag->loc);

        var spans: vec::<CaretSpan>;
        var span_text: vec::<string>;

        for var i: usize = 0; i < group.diags.size(); ++i {
            var diag = group.diags[i];

            var loc_info = sm->get_line_col(diag->loc);
            var span: CaretSpan;
            span.start_col = loc_info.column;
            span.end_col   = loc_info.column + 4;
            span.code      = diag->code;
            span.sev       = diag->code.severity();
            span.style     = DiagLabel::Style::Primary;

            var ltext: string;
            var has_custom_text = false;

            if diag->labels.size() > 0 {
                var label    = diag->labels[0];
                var start_lc = sm->get_line_col(label.range.start);
                var end_lc   = sm->get_line_col(label.range.end);

                if start_lc.line == group.line_num {
                    span.start_col = start_lc.column;
                    span.end_col   = end_lc.column;
                    span.style     = label.style;
                    if label.text.length() > 0 {
                        ltext = label.text;
                        has_custom_text = true;
                    }
                }
            }

            if !has_custom_text {
                var code_prefix = (f"{self.severity_color(span.sev)}[{(diag->code) as string}]{RESET} ") if color else f"[{(diag->code) as string}] ";
                ltext = code_prefix + diag->message;
            }

            if span.start_col > 0 { span.start_col -= 1; }
            if span.end_col   > 0 { span.end_col   -= 1; }
            if span.end_col <= span.start_col { span.end_col = span.start_col + 1; }
            if span.start_col > line_text.length() { span.start_col = line_text.length(); }
            if span.end_col   > line_text.length() { span.end_col   = line_text.length(); }

            spans.push_back(span);
            span_text.push_back(ltext);
        }

        // Sort spans (and their labels) by start column, left to right
        for var i: usize = 1; i < spans.size(); ++i {
            var key_span = spans[i];
            var key_text = span_text[i];
            var j: isize = static_cast::<isize>(i) - 1;
            while (j >= 0) && (spans[static_cast::<usize>(j)].start_col > key_span.start_col) {
                spans[static_cast::<usize>(j + 1)]     = spans[static_cast::<usize>(j)];
                span_text[static_cast::<usize>(j + 1)] = span_text[static_cast::<usize>(j)];
                j -= 1;
            }
            spans[static_cast::<usize>(j + 1)]     = key_span;
            span_text[static_cast::<usize>(j + 1)] = key_text;
        }

        // Per-column severity map (for overlap coloring on the caret row)
        var max_col: usize = 0;
        for var s: usize = 0; s < spans.size(); ++s {
            if spans[s].end_col > max_col { max_col = spans[s].end_col; }
        }

        var col_sev:   vec::<DiagSeverity>;
        var col_style: vec::<DiagLabel::Style>;
        col_sev.resize(max_col + 1, DiagSeverity::Ignored);
        col_style.resize(max_col + 1, DiagLabel::Style::Primary);

        for var s: usize = 0; s < spans.size(); ++s {
            var span = spans[s];
            for var col: usize = span.start_col; col < span.end_col; ++col {
                if self.severity_priority(span.sev) < self.severity_priority(col_sev[col]) {
                    col_sev[col]   = span.sev;
                    col_style[col] = span.style;
                }
            }
        }

        var pipe         = ( f"{BOLD}{WHITE}|{RESET}" ) if ( color ) else ( "|" );
        var line_col_esc = ( f"{BOLD}{WHITE}"        ) if ( color ) else ( ""  );
        var reset_esc    = ( RESET                   ) if ( color ) else ( ""  );

        // Gutter aligned precisely to left_pad
        var conn_gutter = f"{string(' ', left_pad)} {pipe} ";

        for var ln: u32 = first_line; ln <= last_line; ++ln {
            var text    = sm->get_line_text(group.key.file_id, ln);
            var num_str = f"{ln}";
            var npad    = string(' ', left_pad - num_str.length());
            var prefix  = f"{npad}{line_col_esc}{num_str} {pipe} {reset_esc}";

            out += prefix + renderer.highlight_snippet(text) + NL;

            if ln != group.line_num { continue; }

            // === Caret row: ^^^  for each span, severity-colored ==============
            var caret_row: string;
            var cursor: usize = 0;
            for var s: usize = 0; s < spans.size(); ++s {
                var span = spans[s];
                if span.start_col >= cursor {
                    caret_row += string(' ', span.start_col - cursor);
                    var glyph = self.label_char(span.style);
                    for var c: usize = span.start_col; c < span.end_col; ++c {
                        if color {
                            caret_row += f"{self.severity_color(col_sev[c])}{string(glyph, 1)}{RESET}";
                        } else {
                            caret_row += string(glyph, 1);
                        }
                    }
                    cursor = span.end_col;
                }
            }
            out += conn_gutter + caret_row + NL;

            // === Stacked label rows ===========================================
            var active_spans: vec::<CaretSpan>;
            var active_texts: vec::<string>;
            for var s: usize = 0; s < spans.size(); ++s {
                if span_text[s].length() > 0 {
                    active_spans.push_back(spans[s]);
                    active_texts.push_back(span_text[s]);
                }
            }

            var n_active = active_spans.size();

            // Print one label per row, from rightmost span to leftmost.
            for var r: isize = static_cast::<isize>(n_active) - 1; r >= 0; r -= 1 {
                var ri = static_cast::<usize>(r);
                var msg_anchor = active_spans[ri].start_col;

                var row: string;
                var col: usize = 0;

                // connectors for spans strictly to the LEFT of this row's message
                for var s: usize = 0; s < ri; ++s {
                    var anchor = active_spans[s].start_col;
                    if anchor >= msg_anchor { continue; }
                    if anchor < col         { continue; }
                    row += string(' ', anchor - col);
                    if color {
                        var ce = self.severity_color(active_spans[s].sev);
                        row += f"{ce}|{RESET}";
                    } else {
                        row += "|";
                    }
                    col = anchor + 1;
                }

                // the message, always padded to its own anchor
                if msg_anchor > col { row += string(' ', msg_anchor - col); }
                var msg = active_texts[ri];
                row += (f"{RESET}{msg}") if color else msg;

                out += conn_gutter + row + NL;
            }
        }

        // --- Fix-its -----------------------------------------------------------
        for var i: usize = 0; i < group.diags.size(); ++i {
            var diag = group.diags[i];
            for var j: usize = 0; j < diag->fixits.size(); ++j {
                var fi      = diag->fixits[j];
                var fix_pfx = ( f"{BOLD}{CYAN}fix{RESET}" ) if ( color ) else ( "fix" );
                out += f"  > {fix_pfx}: {fi.message}" + NL;
            }
        }

        // --- Children (deduped: identical child notes render once) --------------
        var seen_children: vec::<string>;
        for var i: usize = 0; i < group.diags.size(); ++i {
            var diag = group.diags[i];
            for var j: usize = 0; j < diag->children.size(); ++j {
                var c = diag->children[j];

                var key = f"{(c->code) as string}|{c->message}|{c->loc.id}";

                var dup = false;
                for var k: usize = 0; k < seen_children.size(); ++k {
                    if seen_children[k] == key { dup = true; break; }
                }
                if dup { continue; }

                seen_children.push_back(key);
                out += self.render_single(c, color, "    ", true);
            }
        }

        return out + NL;
    }

    priv fn render_single(self, diag: *Diagnostic, color: bool, indent: string, is_child: bool = false) -> string {
        const var NL = "\n";
        var out: string;

        var sev      = diag->code.severity();
        var sev_name = self.severity_label_raw(sev);
        var sev_col  = self.severity_color(sev);
        var sev_str  = (f"{sev_col}{BOLD}{sev_name}{RESET}") if (color) else sev_name;

        if (!diag->has_loc) || (self._sm == &null) {
            if is_child {
                out += indent + f"{sev_str}: {diag->message}" + NL;
            } else {
                var the_code = diag->code;
                var code_str = (sev_col + ((the_code) as string) + RESET) if (color) else ((the_code) as string);
                out += indent + f"{sev_str} [{code_str}]: {diag->message}" + NL;
            }

            for var i: usize = 0; i < diag->fixits.size(); ++i {
                var fi      = diag->fixits[i];
                var fix_pfx = ( f"{BOLD}{CYAN}fix{RESET}" ) if ( color ) else ( "fix" );
                out += indent + f"  > {fix_pfx}: {fi.message}" + NL;
            }

            for var i: usize = 0; i < diag->children.size(); ++i {
                out += self.render_single(diag->children[i], color, indent + "    ", true);
            }

            return out;
        }

        var sm       = self._sm;
        var loc_info = sm->get_line_col(diag->loc);
        var filename = sm->get_filename(diag->loc);

        // Find the maximum line width in the target labels to calculate padding
        var max_num_len = f"{loc_info.line}".length();
        var temp_labels: vec::<DiagLabel>;

        if diag->labels.size() > 0 {
            for var i: usize = 0; i < diag->labels.size(); ++i {
                temp_labels.push_back(diag->labels[i]);
                var l_line = sm->get_line_col(diag->labels[i].range.start).line;
                var l_len = f"{l_line}".length();
                if l_len > max_num_len { max_num_len = l_len; }
            }

            // The message is on the Diagnostic, not the label. If no label carries
            // text, attach it to the first primary one or it is never rendered.
            var has_text = false;
            for var i: usize = 0; i < temp_labels.size(); ++i {
                if temp_labels[i].text.length() > 0 { has_text = true; break; }
            }
            if !has_text {
                temp_labels[0].text = self.code_prefix(diag->code, sev, color, is_child) + diag->message;
            }
        } else {
            var label: DiagLabel;
            label.range.start = diag->loc;
            label.range.end   = diag->loc;
            label.style       = DiagLabel::Style::Primary;
            label.text        = self.code_prefix(diag->code, sev, color, is_child) + diag->message;
            temp_labels.push_back(label);
        }

        var sev_len = sev_name.length();
        var left_pad = sev_len;
        if max_num_len > left_pad {
            left_pad = max_num_len;
        }

        var pad_len = left_pad - sev_len;
        var header_pad = string(' ', pad_len);

        out += indent + f"{sev_str}{header_pad} @ {filename}:{loc_info.line}" + NL;

        // Render the source context snippet and label lines
        out += self.render_labels(temp_labels, sm, indent, sev_col, color, left_pad);

        for var i: usize = 0; i < diag->fixits.size(); ++i {
            var fi      = diag->fixits[i];
            var fix_pfx = ( f"{BOLD}{CYAN}fix{RESET}" ) if ( color ) else ( "fix" );
            out += indent + f"  > {fix_pfx}: {fi.message}" + NL;
        }

        for var i: usize = 0; i < diag->children.size(); ++i {
            out += self.render_single(diag->children[i], color, indent + "    ", true);
        }

        return out;
    }

    priv fn render_labels(
        self,
        labels:   ref!(vec::<DiagLabel>),
        sm:       *SourceManager,
        indent:   string,
        sev_col:  string,
        color:    bool,
        left_pad: usize
    ) -> string {
        const var NL = "\n";
        var out: string;

        var pipe = ( f"{BOLD}{WHITE}|{RESET}" ) if ( color ) else ( "|" );
        var renderer = TermRenderer(color, 80);

        var order: vec::<usize>;
        order.reserve(labels.size());
        for var i: usize = 0; i < labels.size(); ++i {
            order.push_back(i);
        }

        for var i: usize = 1; i < order.size(); ++i {
            var key      = order[i];
            var key_line = sm->get_line_col(labels[key].range.start).line;
            var j: isize = static_cast::<isize>(i) - 1;
            while j >= 0 {
                var cmp_line = sm->get_line_col(labels[order[static_cast::<usize>(j)]].range.start).line;
                if cmp_line <= key_line { break; }
                order[static_cast::<usize>(j + 1)] = order[static_cast::<usize>(j)];
                j -= 1;
            }
            order[static_cast::<usize>(j + 1)] = key;
        }

        for var i: usize = 0; i < order.size(); ++i {
            var label     = labels[order[i]];
            if label.range.is_invalid() { continue; }

            var start_lc  = sm->get_line_col(label.range.start);
            var end_lc    = sm->get_line_col(label.range.end);
            var line_text = sm->get_full_line(label.range.start);

            var glyph_col  = ((sev_col) if (label.style == DiagLabel::Style::Primary) else (DIM))
                if color else "";

            var line_num_str = f"{start_lc.line}";
            var pad_count    = left_pad - line_num_str.length();
            var num_pad      = string(' ', pad_count);
            var line_col     = ( f"{BOLD}{WHITE}" ) if ( color ) else ( "" );
            var reset_col    = ( RESET            ) if ( color ) else ( "" );

            var prefix_raw = f"{indent}{num_pad}{line_num_str} | ";
            var prefix_vis = f"{indent}{num_pad}{line_col}{line_num_str} {pipe} {reset_col}";

            // --- leading context window (same policy as render_group) ---------
            var ctx_before: u32 = 2;
            var res  = sm->resolve(label.range.start);
            var fid  = res.fid;
            var first_line = (start_lc.line - ctx_before) if (start_lc.line > ctx_before) else 1;

            while first_line < start_lc.line {
                var t = sm->get_line_text(fid, first_line);
                if self.is_line_blank(t) { first_line += 1; } else { break; }
            }

            for var ln: u32 = first_line; ln < start_lc.line; ++ln {
                var t       = sm->get_line_text(fid, ln);
                var num_str = f"{ln}";
                var npad    = string(' ', left_pad - num_str.length());
                out += f"{indent}{npad}{line_col}{num_str} {pipe} {reset_col}"
                     + renderer.highlight_snippet(t) + NL;
            }
            // ------------------------------------------------------------------

            out += prefix_vis + renderer.highlight_snippet(line_text) + NL;

            var pad       = string(' ', prefix_raw.length());
            var start_col = start_lc.column;
            var end_col   = end_lc.column;

            if start_col > 0 { start_col -= 1; }
            if end_col   > 0 { end_col   -= 1; }

            if start_col > line_text.length() { start_col = line_text.length(); }
            if end_col   > line_text.length() { end_col   = line_text.length(); }
            if end_col   <= start_col         { end_col   = start_col + 1;      }

            var glyph     = self.label_char(label.style);
            var underline = string(' ', start_col) + string(glyph, end_col - start_col);

            out += pad + ( f"{glyph_col}{underline}{RESET}" if color else underline );

            if label.text.length() > 0 {
                out += " " + label.text;
            }

            out += NL;
        }

        return out;
    }

    // --- Helpers -------------------------------------------------------------

    priv fn severity_color(self, sev: DiagSeverity) -> string {
        switch sev {
        case DiagSeverity::Fatal   { return BOLD_RED; }
        case DiagSeverity::Error   { return RED;      }
        case DiagSeverity::Warning { return YELLOW;   }
        case DiagSeverity::Note    { return CYAN;     }
        case DiagSeverity::Remark  { return BLUE;     }
        case DiagSeverity::Debug   { return MAGENTA;  }
        case DiagSeverity::Verbose { return DIM;      }
        case DiagSeverity::Ignored { return DIM;      }
        default                    { return "";       }
        }
    }

    priv fn severity_string(self, sev: DiagSeverity, color: bool) -> string {
        var label: string = self.severity_label_raw(sev);
        if !color { return label; }
        return f"{self.severity_color(sev)}{BOLD}{label}{RESET}";
    }

    priv fn label_char(self, style: DiagLabel::Style) -> char {
        switch style {
        case DiagLabel::Style::Primary       { return '^'; }
        case DiagLabel::Style::Secondary     { return '+'; }
        case DiagLabel::Style::Highlight     { return '-'; }
        case DiagLabel::Style::StrikeThrough { return '~'; }
        default                              { return '?'; }
        }
    }

    priv fn is_line_blank(self, s: string) -> bool {
        for var i: usize = 0; i < s.length(); ++i {
            var c = s[i];
            if c != ' ' && c != '\t' && c != '\r' && c != '\n' {
                return false;
            }
        }
        return true;
    }

    priv fn detect_color_stdout(self) -> bool {
        if libcxx::getenv(r"NO_COLOR") { return false; }
        if !(isatty(fileno(stdout)))   { return false; }
        return true;
    }

    priv fn detect_color_stderr(self) -> bool {
        if libcxx::getenv(r"NO_COLOR") { return false; }
        if !(isatty(fileno(stderr)))   { return false; }
        return true;
    }
}