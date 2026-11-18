/// --- The Kairo Project ---------------- Analyzer/Server/DocComments.k --- ///
///
///   Documentation comments in the editor: the markup kind each answer is
///   written in, completion inside a `///` comment, and the "Generate
///   documentation" stub (a code action, and a completion on `///`).
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

import DocComment::{
    DeclHead, decl_head, doc_comment_text, doc_stub, headings_for, inline_labels, markdown_to_plain,
}
import DocumentStore::DocumentStore
import Json::{
    JSON_NONE,
    JsonDoc,
    JsonWriter,
}
import Protocol::*
import Server::Output::*
import Server::Server::*
import TextScan::classify

/// True unless `formats` (a client's MarkupKind list for one kind of
/// answer) is there and leaves Markdown out: a client that sends no list
/// gets Markdown.
pub fn markdown_ok(d: *const JsonDoc, formats: u32) -> bool {
    if formats == JSON_NONE() {
        return true
    }

    var x = d->first(formats)
    if x == JSON_NONE() {
        return true
    }

    while x != JSON_NONE() {
        if d->str(x) == MARKUP_MARKDOWN {
            return true
        }

        x = d->next(x)
    }

    return false
}

/// Where the line holding `at` starts.
fn line_start_of(const text: string, at: usize) -> usize {
    var p = at
    while (p > 0) && (text[p - 1] != ('\n' as u8)) {
        p -= 1
    }

    return p
}

/// One past the end of the line starting at `ls` (its `\n`, or the end).
fn line_end_of(const text: string, ls: usize) -> usize {
    var p = ls
    while (p < text.size()) && (text[p] != ('\n' as u8)) {
        p += 1
    }

    return p
}

/// Where a `///` line's marker starts, or usize::MAX when the line at `ls`
/// is not one (`////` is a rule).
fn doc_marker_at(const text: string, ls: usize) -> usize {
    var p = ls
    while (p < text.size()) && ((text[p] == (' ' as u8)) || (text[p] == ('\t' as u8))) {
        p += 1
    }

    if ((p + 3) <= text.size())
        && (text[p] == ('/' as u8))
        && (text[p + 1] == ('/' as u8))
        && (text[p + 2] == ('/' as u8))
        && (((p + 3) == text.size()) || (text[p + 3] != ('/' as u8))) {
        return p
    }

    return usize::MAX
}

/// One completion item that replaces `[sl:sc, sl:ec)` with `text`.
fn doc_item(w:            *JsonWriter,
            const label:  string,
            kind:         i64,
            sort:         usize,
            sl:           i64,
            sc:           i64,
            ec:           i64,
            const text:   string,
            const filter: string,
            snippet:      bool) {
    w->begin_object()
    w->field(K_LABEL, label)
    w->field_int(K_KIND, kind)
    var st = f"{sort}"
    while st.size() < 4 {
        st = "0" + st
    }

    w->field("sortText", st)
    w->field("filterText", filter)
    w->field_int("insertTextFormat", if (snippet) => (2) else => 1)
    // As written: the text carries its own indentation.
    w->field_int("insertTextMode", 1)
    w->key("textEdit")
    w->begin_object()
    w->key(K_RANGE)
    write_lsp_range(w, sl, sc, sl, ec)
    w->field(K_NEW_TEXT, text)
    w->end_object()
    w->end_object()
}

extend Server {
    /// `md` as a MarkupContent: Markdown when `md_ok`, else the same text
    /// as plain text (DocComment.k, markdown_to_plain).
    fn write_markup_(const self, w: *JsonWriter, md_ok: bool, const md: string) {
        w->begin_object()
        if md_ok {
            w->field(K_KIND, MARKUP_MARKDOWN)
            w->field(K_VALUE, md)
        } else {
            w->field(K_KIND, MARKUP_PLAINTEXT)
            w->field(K_VALUE, markdown_to_plain(md))
        }

        w->end_object()
    }

    /// The `///` lines around line start `ls` (the run it is in), each
    /// line's content after the marker, trimmed; the line at `ls` left out.
    fn doc_block_lines_(const self, const text: string, ls: usize) -> [string] {
        var out: [string]
        var cur           = ls
        while cur > 0 {
            var ps = line_start_of(text, cur - 1)
            var m  = doc_marker_at(text, ps)
            if m == usize::MAX {
                break
            }

            out.push(trim_doc_(text.subslice(m + 3, cur - 1 - m - 3)))
            cur = ps
        }

        var nl = line_end_of(text, ls) + 1
        while nl < text.size() {
            var m = doc_marker_at(text, nl)
            if m == usize::MAX {
                break
            }

            var ne = line_end_of(text, nl)
            out.push(trim_doc_(text.subslice(m + 3, ne - m - 3)))
            nl = ne + 1
        }

        return out
    }

    /// The declaration below the `///` run that holds line start `ls`.
    fn decl_below_(const self, const text: string, ls: usize) -> DeclHead {
        var nl = line_end_of(text, ls) + 1
        while (nl < text.size()) && (doc_marker_at(text, nl) != usize::MAX) {
            nl = line_end_of(text, nl) + 1
        }

        if nl >= text.size() {
            return DeclHead{}
        }

        return decl_head(text, nl)
    }

    /// Completion in a documentation comment (P1294): `#` offers the
    /// section headings that fit the declaration below and are not there
    /// yet, `**` the inline labels, `- ` under `### Parameters` (or
    /// `### Type parameters`) the names not yet listed, and `///` typed on
    /// the line directly above an undocumented declaration the whole stub.
    /// True when it answered. A request that a `#`, `*` or `-` triggered
    /// anywhere else is answered with nothing: those characters trigger
    /// only for this.
    fn doc_complete_(self, i: usize, d: *const JsonDoc, params: u32, const id: string) -> bool {
        var ctx     = d->get(params, "context")
        var trig    = d->get_str(ctx, "triggerCharacter")
        var by_char = d->get_int(ctx, "triggerKind") == 2
        var own     = by_char && ((trig == "#") || (trig == "*") || (trig == "-"))
        var none    = "{\"isIncomplete\":false,\"items\":[]}"

        var pos   = d->get(params, K_POSITION)
        var line  = d->get_int(pos, K_LINE)
        var *text = &self.docs.docs[i].text
        var at = self.docs.docs[i].lines.offset(
            *text,
            line as usize,
            d->get_int(pos, K_CHARACTER) as usize,
            false,
        )

        var ls = line_start_of(*text, at)
        var m  = doc_marker_at(*text, ls)
        if (m == usize::MAX) || (at < (m + 3)) {
            if own {
                self.respond(id, none)
                return true
            }

            return false
        }

        // A `///` inside a block comment or a string is not one.
        var cls = classify(*text)
        if (cls[m] != 1) || ((ls > 0) && (cls[ls - 1] == 1)) {
            if own {
                self.respond(id, none)
                return true
            }

            return false
        }

        var before = text->subslice(m + 3, at - m - 3)
        var le     = line_end_of(*text, ls)
        var after  = text->subslice(at, le - at)
        var w      = JsonWriter()
        w.begin_object()
        w.field_bool("isIncomplete", false)
        w.key("items")
        w.begin_array()
        var n: usize = 0

        // `///` alone, typed on the line above a declaration: the stub.
        var prev_doc = (ls > 0)
            && (doc_marker_at(*text, line_start_of(*text, ls - 1)) != usize::MAX)
        if before.is_empty() && trim_doc_(after).is_empty() && (!prev_doc) && (le < text->size()) {
            var h = decl_head(*text, le + 1)
            if h.ok && doc_comment_text(*text, h.head).is_empty() {
                var stub         = doc_stub(h, self.snippet_ok)
                var body: string = ""
                for var k: usize = 0; k < stub.size(); ++k {
                    if k > 0 {
                        body += "\n" + h.indent
                    }

                    body += stub[k]
                }

                var sc = self.docs.docs[i].lines.character(*text, m, false) as i64
                var ec = self.docs.docs[i].lines.character(*text, at, false) as i64
                doc_item(
                    &w,
                    "/// Generate documentation",
                    CIK_SNIPPET,
                    0,
                    line,
                    sc,
                    ec,
                    body,
                    "///",
                    self.snippet_ok,
                )

                n += 1
            }
        }

        var t  = before.copy()
        var t0 = m + 3
        while (!t.is_empty()) && ((t[0] == (' ' as u8)) || (t[0] == ('\t' as u8))) {
            t = t.subslice(1, t.size() - 1)
            t0 += 1
        }

        var block = self.doc_block_lines_(*text, ls)

        // `#`, `##`, `### Pa`: the headings.
        if t.starts_with("#") {
            var k: usize = 0
            while (k < t.size()) && (t[k] == ('#' as u8)) {
                k += 1
            }

            var tail_ok = true
            for var q: usize = k; q < t.size(); ++q {
                if !((t[q] == (' ' as u8))
                    || ((t[q] >= ('a' as u8)) && (t[q] <= ('z' as u8)))
                    || ((t[q] >= ('A' as u8)) && (t[q] <= ('Z' as u8)))) {
                    tail_ok = false
                }
            }

            if (k <= 3) && tail_ok {
                var present: [string]
                for var q: usize = 0; q < block.size(); ++q {
                    if block[q].starts_with("### ") {
                        present.push(block[q].copy())
                    }
                }

                var hs = headings_for(self.decl_below_(*text, ls), present)
                var sc = self.docs.docs[i].lines.character(*text, t0, false) as i64
                var ec = self.docs.docs[i].lines.character(*text, at, false) as i64
                for var q: usize = 0; q < hs.size(); ++q {
                    doc_item(
                        &w,
                        hs[q],
                        CIK_KEYWORD,
                        q,
                        line,
                        sc,
                        ec,
                        hs[q],
                        hs[q],
                        false,
                    )

                    n += 1
                }
            }
        }

        // `*`, `**`, `**No`: the inline labels, where a word can start.
        var e = at
        while (e > t0)
            && ((((*text)[e - 1] >= ('a' as u8)) && ((*text)[e - 1] <= ('z' as u8)))
                || (((*text)[e - 1] >= ('A' as u8)) && ((*text)[e - 1] <= ('Z' as u8)))) {
            e -= 1
        }

        var s = e
        while (s > t0) && ((*text)[s - 1] == ('*' as u8)) && ((e - s) < 2) {
            s -= 1
        }

        if (s < e)
            && ((s == t0) || ((*text)[s - 1] == (' ' as u8)) || ((*text)[s - 1] == ('\t' as u8))) {
            var labels = inline_labels()
            var sc = self.docs.docs[i].lines.character(*text, s, false) as i64
            var ec = self.docs.docs[i].lines.character(*text, at, false) as i64
            for var q: usize = 0; q < labels.size(); ++q {
                doc_item(
                    &w,
                    labels[q],
                    CIK_KEYWORD,
                    q,
                    line,
                    sc,
                    ec,
                    labels[q] + " ",
                    labels[q],
                    false,
                )

                n += 1
            }
        }

        // `-`, `- `, `` - `na ``: an item of the list the line is under.
        if t.starts_with("-")
            && ((t.size() == 1) || t.starts_with("- "))
            && (find_doc_(t, ":") == usize::MAX) {
            var sec:    string   = ""
            var listed: [string]
            var cur              = ls
            while cur > 0 {
                var ps = line_start_of(*text, cur - 1)
                var pm = doc_marker_at(*text, ps)
                if pm == usize::MAX {
                    break
                }

                var c = trim_doc_(text->subslice(pm + 3, cur - 1 - pm - 3))
                if c.starts_with("### ") {
                    sec = c.copy()
                    break
                }

                cur = ps
            }

            for var q: usize = 0; q < block.size(); ++q {
                if block[q].starts_with("- `") {
                    var r = block[q].subslice(3, block[q].size() - 3)
                    var b = find_doc_(r, "`")
                    if b != usize::MAX {
                        listed.push(r.subslice(0, b))
                    }
                }
            }

            if (sec == "### Parameters") || (sec == "### Type parameters") {
                var h = self.decl_below_(*text, ls)
                var names = if (sec == "### Parameters") => (h.params.copy())
                            else => h.tparams.copy()
                var sc = self.docs.docs[i].lines.character(*text, t0, false) as i64
                var ec = self.docs.docs[i].lines.character(*text, at, false) as i64
                for var q: usize = 0; q < names.size(); ++q {
                    var have = false
                    for var k: usize = 0; k < listed.size(); ++k {
                        if listed[k] == names[q] {
                            have = true
                        }
                    }

                    if !have {
                        var item = "- `" + names[q] + "`: "
                        doc_item(
                            &w,
                            "`" + names[q] + "`",
                            CIK_FIELD,
                            q,
                            line,
                            sc,
                            ec,
                            item,
                            item,
                            false,
                        )

                        n += 1
                    }
                }
            }
        }

        w.end_array()
        w.end_object()
        if (n == 0) && (!own) {
            return false
        }

        self.respond(id, w.out)
        return true
    }

    /// "Generate documentation" (`refactor.rewrite`) on a function, method,
    /// class, struct, enum, union, interface or type alias with no
    /// documentation comment, the cursor on its head line or an attribute
    /// line above it: the stub (DocComment.k, doc_stub) above the
    /// declaration and its attributes, indented as it is. A snippet with
    /// tab stops when the client takes snippet edits in a workspace edit,
    /// else plain text.
    fn doc_action_(self, d: *const JsonDoc, params: u32, const path: string, w: *JsonWriter) {
        self.docs.sync_all()
        var di = self.docs.index_of_path(path)
        if di == usize::MAX {
            return
        }

        var *text = &self.docs.docs[di].text
        var st    = d->get(d->get(params, K_RANGE), K_START)
        var at = self.docs.docs[di].lines.offset(
            *text,
            d->get_int(st, K_LINE) as usize,
            d->get_int(st, K_CHARACTER) as usize,
            false,
        )

        var ls = line_start_of(*text, at)
        var p  = ls
        while (p < text->size()) && (((*text)[p] == (' ' as u8)) || ((*text)[p] == ('\t' as u8))) {
            p += 1
        }

        if p >= text->size() {
            return
        }

        // Not in a comment or a string: the head's first byte is code.
        var cls = classify(*text)
        if cls[p] != 0 {
            return
        }

        var h = decl_head(*text, ls)
        if (!h.ok) || (h.head < ls) {
            return
        }

        // The attribute lines above belong to it: the stub goes above them.
        var first = ls
        while first > 0 {
            var ps = line_start_of(*text, first - 1)
            var q  = ps
            while (q < first) && (((*text)[q] == (' ' as u8)) || ((*text)[q] == ('\t' as u8))) {
                q += 1
            }

            if (q < first) && ((*text)[q] == ('@' as u8)) && (cls[q] == 0) {
                first = ps
                continue
            }

            break
        }

        if (!doc_comment_text(*text, first).is_empty())
            || (!doc_comment_text(*text, h.head).is_empty()) {
            return
        }

        var fp = first
        while (fp < text->size())
            && (((*text)[fp] == (' ' as u8)) || ((*text)[fp] == ('\t' as u8))) {
            fp += 1
        }

        var indent         = text->subslice(first, fp - first)
        var snippet        = self.snippet_edit_exp || self.snippet_edit_lsp
        var stub           = doc_stub(h, snippet)
        var body:   string = ""
        for var k: usize = 0; k < stub.size(); ++k {
            body += indent + stub[k] + "\n"
        }

        var il  = self.docs.docs[di].lines.line_of(first) as i64
        var uri = self.uri_of(path)
        var rw  = JsonWriter()
        write_lsp_range(&rw, il, 0, il, 0)

        w->begin_object()
        w->field(K_TITLE, "Generate documentation")
        w->field(K_KIND, KIND_REFACTOR_REWRITE)
        w->key(K_EDIT)
        w->begin_object()
        if snippet {
            // A snippet edit is a TextDocumentEdit's, never a `changes` map's.
            w->key("documentChanges")
            w->begin_array()
            w->begin_object()
            w->key("textDocument")
            w->begin_object()
            w->field("uri", uri)
            w->field_int(K_VERSION, self.docs.docs[di].version)
            w->end_object()
            w->key("edits")
            w->begin_array()
            w->begin_object()
            w->field_raw(K_RANGE, rw.out)
            if self.snippet_edit_lsp {
                // LSP 3.18: SnippetTextEdit.
                w->key("snippet")
                w->begin_object()
                w->field(K_KIND, "snippet")
                w->field(K_VALUE, body)
                w->end_object()
            } else {
                // `experimental.snippetTextEdit`: a TextEdit marked as a snippet.
                w->field(K_NEW_TEXT, body)
                w->field_int("insertTextFormat", 2)
            }

            w->end_object()
            w->end_array()
            w->end_object()
            w->end_array()
        } else {
            w->key(K_CHANGES)
            w->begin_object()
            w->key(uri)
            w->begin_array()
            write_lsp_text_edit_raw(w, rw.out, body)
            w->end_array()
            w->end_object()
        }

        w->end_object()
        w->end_object()
    }
}

fn trim_doc_(const s: string) -> string {
    var b: usize = 0
    var e        = s.size()
    while (b < e) && ((s[b] == (' ' as u8)) || (s[b] == ('\t' as u8)) || (s[b] == ('\r' as u8))) {
        b += 1
    }

    while (e > b)
        && ((s[e - 1] == (' ' as u8)) || (s[e - 1] == ('\t' as u8)) || (s[e - 1] == ('\r' as u8))) {
        e -= 1
    }

    return s.subslice(b, e - b)
}

fn find_doc_(const s: string, const needle: string) -> usize {
    for var i: usize = 0; (i + needle.size()) <= s.size(); ++i {
        if s.subslice(i, needle.size()) == needle {
            return i
        }
    }

    return usize::MAX
}
