/// --- The Kairo Project ---------------------- Analyzer/Server/Lookup.k --- ///
///
///   Reading a snapshot: file nodes, the decoded ref and token tables, ranges, every use of a declaration.
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
ffi "c++" import "llvm/ADT/StringRef.h"
ffi "c++" import "llvm/Support/Program.h"
ffi "c++" import "optional"
ffi "c++" import "string"
ffi "c++" import "llvm/ADT/SmallVector.h"
ffi "c++" import "chrono"

import API::FS::LinkFS
import DocumentStore::{
    DocumentStore,
    fnv1a,
    path_to_uri,
    uri_to_path,
}
import Index::Legend::*
import Index::Snapshot::*
import Protocol::*
import Tuning::*
import Json::{
    JSON_NONE,
    JsonDoc,
    JsonWriter,
}
import JsonRpc::Transport
import Support::FileIO::Path::Path
import TextScan::{
    InterfacePlan,
    Span,
    call_at,
    interface_for,
    spans,
}
import Workspace::CompileCommandsLoader::{
    Project,
    project_file_name,
}
import std::io
import Server::ClangdBridge::*
import Server::CodeActions::*
import Server::Completion::*
import Server::Diagnostics::*
import Server::Features::*
import Server::Formatting::*
import Server::Lifecycle::*
import Server::Navigation::*
import Server::Output::*
import Server::Scheduling::*
import Server::Server::*
import Server::SignatureHelp::*
import Server::Structure::*
import Server::TextUtil::*
import Server::Tokens::*
import Server::Workers::*

/// \class LineShift
/// \brief one buffer's lines against the text its (older) index was computed
///        from (Document::idx_text): LanguageServer.md section 9.
///
/// \details The lines both texts start with (`pre`) are the same lines in
///          both; so are the lines both end with (`suf`), moved by the
///          difference in length. A line in neither is in the changed middle
///          and has no counterpart. Each mapped line is byte for byte the
///          same in the two texts, so a column on it needs no conversion.
///          Inactive: no shift is needed (the index is of this text) or none
///          is known; every line then maps to itself.
pub class LineShift {
    pub var active: bool   = false
    pub var path:   string = ""          ///< the buffer
    pub var entry:  usize  = usize::MAX  ///< the entry whose index the old text is
    pub var changed_at: u64 = 0          ///< the buffer's last change: an index at least this new is of its current text
    pub var pre:   i64 = 0
    pub var suf:   i64 = 0
    pub var old_n: i64 = 0
    pub var new_n: i64 = 0

    fn LineShift(self) = default

    /// Buffer line \p line as a line of the indexed text; -1: none.
    fn to_old(const self, line: i64) -> i64 {
        if !self.active {
            return line
        }

        if (line >= 0) && (line < self.pre) {
            return line
        }

        if (line >= (self.new_n - self.suf)) && (line < self.new_n) {
            return line - self.new_n + self.old_n
        }

        return -1
    }

    /// Indexed-text lines \p a to \p b are all on one side of the changed
    /// middle, so the span between them is the same text in the buffer.
    fn kept(const self, a: i64, b: i64) -> bool {
        if !self.active {
            return true
        }

        return ((a >= 0) && (b < self.pre)) || ((a >= (self.old_n - self.suf)) && (b < self.old_n))
    }

    /// Indexed-text line \p line as a line of the buffer; -1: none.
    fn to_new(const self, line: i64) -> i64 {
        if !self.active {
            return line
        }

        if (line >= 0) && (line < self.pre) {
            return line
        }

        if (line >= (self.old_n - self.suf)) && (line < self.old_n) {
            return line - self.old_n + self.new_n
        }

        return -1
    }
}

extend Server {
    /// Whether run output \p doc, which indexed files, replaces entry \p ei's
    /// last good index. A run over a graph with syntax errors indexes only
    /// what they leave sound: a file is `unchecked` (no rows) or `partial`
    /// (no rows inside the bodies its errors are in) (LanguageServer.md
    /// section 9). With no index yet, that is all there is. Over an index
    /// that has COMPLETE rows for such a file, it would erase answers the
    /// old one still gives on the lines the edits did not touch (mapped
    /// through LineShift): the old index stays, as it does for a run that
    /// indexed nothing at all, until the file parses again.
    fn index_installs(self, ei: usize, doc: *const JsonDoc) -> bool {
        if !self.entries[ei].has_idx {
            return true
        }

        var *old = &self.entries[ei].idx
        return self.keeps_old_(ei, doc, old, "unchecked") && self.keeps_old_(ei, doc, old, "partial")
    }

    /// No path of \p doc's list \p key has complete rows in entry \p ei's
    /// index \p old (rows there, and \p old not naming it either).
    priv fn keeps_old_(self, ei: usize, doc: *const JsonDoc, old: *const JsonDoc, const key: string) -> bool {
        var u = doc->first(doc->get(doc->root, key))
        while u != JSON_NONE() {
            var path = doc->str(u)
            if (self.file_node(ei, path) != JSON_NONE())
                && (!self.in_list_(old, "unchecked", path)) && (!self.in_list_(old, "partial", path)) {
                return false
            }

            u = doc->next(u)
        }

        return true
    }

    /// Some entry's index has a file without all its rows (`unchecked` or
    /// `partial`, section 9): what is asked of every use is not known.
    fn any_incomplete_index(self) -> bool {
        for var ei: usize = 0; ei < self.entries.size(); ++ei {
            if !self.entries[ei].has_idx {
                continue
            }

            var *s = &self.entries[ei].idx
            if (s->count(s->get(s->root, SK_UNCHECKED)) > 0) || (s->count(s->get(s->root, SK_PARTIAL)) > 0) {
                return true
            }
        }

        return false
    }

    priv fn in_list_(self, s: *const JsonDoc, const key: string, const path: string) -> bool {
        var u = s->first(s->get(s->root, key))
        while u != JSON_NONE() {
            if s->str(u) == path {
                return true
            }

            u = s->next(u)
        }

        return false
    }

    /// Node of \p path's object in entry \p ei's snapshot, or JSON_NONE.
    fn file_node(self, ei: usize, const path: string) -> u32 {
        if (ei >= self.entries.size()) || (!self.entries[ei].has_idx) {
            return JSON_NONE()
        }

        var *s = &self.entries[ei].idx
        var f = s->first(s->get(s->root, SK_FILES))
        while f != JSON_NONE() {
            if s->get_str(f, SK_PATH) == path {
                return f
            }

            f = s->next(f)
        }

        return JSON_NONE()
    }

    /// The \p n-th element of array node \p arr.
    fn nth(const self, s: *const JsonDoc, arr: u32, n: i64) -> u32 {
        var c = s->first(arr)
        var k: i64 = 0
        while (c != JSON_NONE()) && (k < n) {
            c = s->next(c)
            k += 1
        }

        return c
    }

    /// Decodes entry \p ei's `idx` into the cf_/cr_/ct_ tables. Once per
    /// installed index: what every request after it reads.
    fn index_cache(self, ei: usize) {
        var *e = &self.entries[ei]
        e->cf_node.clear()
        e->cf_lo.clear()
        e->cf_hi.clear()
        e->cr_row.clear()
        e->cr_line.clear()
        e->cr_ch.clear()
        e->cr_len.clear()
        e->ct_lo.clear()
        e->ct_hi.clear()
        e->ct_data.clear()
        var *s = &e->idx
        var f = s->first(s->get(s->root, SK_FILES))
        while f != JSON_NONE() {
            e->cf_node.push_back(f)
            e->cf_lo.push_back(e->cr_row.size())
            var r = s->first(s->get(f, SK_REFS))
            while r != JSON_NONE() {
                var a = s->first(r)
                var b = s->next(a)
                var c = s->next(b)
                e->cr_row.push_back(r)
                e->cr_line.push_back(s->as_int(a))
                e->cr_ch.push_back(s->as_int(b))
                e->cr_len.push_back(s->as_int(c))
                r = s->next(r)
            }

            e->cf_hi.push_back(e->cr_row.size())
            e->ct_lo.push_back(e->ct_data.size())
            // `panics` is in every snapshot; it is sent only to a client
            // that asked (initializationOptions.highlightPanics).
            var t = s->first(s->get(f, SK_TOKENS))
            var at: usize = 0
            while t != JSON_NONE() {
                var v = s->as_int(t)
                if (!self.highlight_panics) && ((at % SEMTOK_STRIDE) == SEMTOK_MODS) {
                    v = v & (~(TM_PANICS() as i64))
                }

                e->ct_data.push_back(v)
                t = s->next(t)
                at += 1
            }

            e->ct_hi.push_back(e->ct_data.size())
            f = s->next(f)
        }
    }

    /// Slot of file node \p f in entry \p ei's cache, or usize::MAX.
    fn cache_slot(const self, ei: usize, f: u32) -> usize {
        for var k: usize = 0; k < self.entries[ei].cf_node.size(); ++k {
            if self.entries[ei].cf_node[k] == f {
                return k
            }
        }

        return usize::MAX
    }

    /// The ref row of file node \p f covering (line, ch), or JSON_NONE. The
    /// rows are sorted by position: a binary search for the line, then the
    /// few rows on it.
    fn ref_at(const self, ei: usize, f: u32, line: i64, ch: i64) -> u32 {
        var k = self.cache_slot(ei, f)
        if k != usize::MAX {
            var e: *const Entry = &self.entries[ei]
            var lo = e->cf_lo[k]
            var hi = e->cf_hi[k]
            while lo < hi {
                var mid = (lo + hi) / 2
                if e->cr_line[mid] < line {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }

            var q = lo
            while (q < e->cf_hi[k]) && (e->cr_line[q] == line) && (e->cr_ch[q] <= ch) {
                if ch <= (e->cr_ch[q] + e->cr_len[q]) {
                    return e->cr_row[q]
                }

                q += 1
            }

            return JSON_NONE()
        }

        var s: *const JsonDoc = &self.entries[ei].idx
        var r = s->first(s->get(f, SK_REFS))
        while r != JSON_NONE() {
            var a = s->first(r)
            var b = s->next(a)
            var c = s->next(b)
            if (s->as_int(a) == line) && (s->as_int(b) <= ch) && (ch <= (s->as_int(b) + s->as_int(c))) {
                return r
            }

            r = s->next(r)
        }

        return JSON_NONE()
    }

    /// The shift for a request on buffer \p di answered from entry \p ei's
    /// index, which is older than the buffer. Inactive when the text that
    /// index read for the buffer is not known (the buffer was not overlaid
    /// for that run, or another entry's run recorded it since).
    fn line_shift(self, ei: usize, di: usize) -> LineShift {
        var sh = LineShift()
        if self.docs.docs[di].idx_entry.empty() || (self.docs.docs[di].idx_entry != self.entries[ei].entry)
            || (self.docs.docs[di].idx_rev != self.entries[ei].idx_rev) {
            return sh
        }

        self.docs.docs[di].sync()
        var *doc = &self.docs.docs[di]
        var on = doc->idx_lines.line_count()
        var nn = doc->lines.line_count()
        var pre: usize = 0
        while (pre < on) && (pre < nn) && self.same_line_(di, pre, pre) {
            pre += 1
        }

        // Never past the prefix: `a` then `a` with one more `a` inserted
        // would otherwise count its lines twice.
        var suf: usize = 0
        while ((pre + suf) < on) && ((pre + suf) < nn) && self.same_line_(di, on - 1 - suf, nn - 1 - suf) {
            suf += 1
        }

        sh.active     = true
        sh.path       = doc->path
        sh.entry      = ei
        sh.changed_at = doc->changed_at
        sh.pre        = pre as i64
        sh.suf        = suf as i64
        sh.old_n      = on as i64
        sh.new_n      = nn as i64
        return sh
    }

    /// Line \p a of buffer \p di's indexed text and line \p b of its text are
    /// the same bytes (line terminators aside).
    priv fn same_line_(self, di: usize, a: usize, b: usize) -> bool {
        var *doc = &self.docs.docs[di]
        var a0 = doc->idx_lines.starts[a]
        var ae  = doc->idx_lines.line_end(doc->idx_text, a)
        var bs  = doc->lines.starts[b]
        var be  = doc->lines.line_end(doc->text, b)
        if (ae - a0) != (be - bs) {
            return false
        }

        for var k: usize = 0; k < (ae - a0); ++k {
            if doc->idx_text[a0 + k] != doc->text[bs + k] {
                return false
            }
        }

        return true
    }

    /// Line \p line of \p path as entry \p e's index has it, placed on the
    /// buffer's lines: -1 when it cannot be (the changed middle, or another
    /// entry's index of an older text of the buffer).
    fn shift_out(const self, sh: *const LineShift, e: usize, const path: string, line: i64) -> i64 {
        if (!sh->active) || (path != sh->path) {
            return line
        }

        if e == sh->entry {
            return sh->to_new(line)
        }

        if self.entries[e].idx_rev >= sh->changed_at {
            return line
        }

        return -1
    }

    /// Line \p line of \p path as \p sh's entry's index has it, as entry \p e's
    /// index has it: -1 when \p e's index has no counterpart of the line.
    fn shift_across(const self, sh: *const LineShift, e: usize, const path: string, line: i64) -> i64 {
        if (!sh->active) || (path != sh->path) || (e == sh->entry) {
            return line
        }

        if self.entries[e].idx_rev >= sh->changed_at {
            return sh->to_new(line)
        }

        return -1
    }

    /// The one-line Range of \p len characters at (\p line, \p ch).
    fn write_range(self, w: *JsonWriter, line: i64, ch: i64, len: i64) {
        write_lsp_range(w, line, ch, line, ch + len)
    }

    /// Every use of the declaration ref row \p row names, across every
    /// snapshot, as (uri, line, ch, len) written through \p emit_kind:
    /// 0 = Location objects, 1 = DocumentHighlight (same file only),
    /// 2 = TextEdit grouped by uri (rename). \p s's positions are \p sh's
    /// index's, and every use is placed on the buffers' lines through it;
    /// one with no place there is left out.
    fn uses(self,
            s:              *const JsonDoc,
            f:              u32,
            row:            u32,
            w:              *JsonWriter,
            mode:           u32,
            const only:     string,
            const new_name: string,
            with_decl:      bool,
            sh:             *const LineShift) {
        var def_file = s->as_int(self.nth(s, row, REF_DEF_FILE))
        if def_file < 0 {
            return
        }

        var def_path = s->str(self.nth(s, s->get(f, SK_FILES), def_file))
        var def_line = s->as_int(self.nth(s, row, REF_DEF_LINE))
        var def_ch   = s->as_int(self.nth(s, row, REF_DEF_CHAR))

        // A file can be indexed under more than one entry; report each
        // location once.
        var seen: [string]

        for var ei: usize = 0; ei < self.entries.size(); ++ei {
            if !self.entries[ei].has_idx {
                continue
            }

            var dl = self.shift_across(sh, ei, def_path, def_line)
            if dl < 0 {
                continue // this index has another text of the declaration's line
            }

            var *o = &self.entries[ei].idx
            var of = o->first(o->get(o->root, SK_FILES))
            while of != JSON_NONE() {
                var path = o->get_str(of, SK_PATH)
                if (!only.empty()) && (path != only) {
                    of = o->next(of)
                    continue
                }

                var uri   = self.uri_of(path)
                var opened = false
                var r = o->first(o->get(of, SK_REFS))
                while r != JSON_NONE() {
                    var fi = o->as_int(self.nth(o, r, REF_DEF_FILE))
                    var same = (fi >= 0)
                        && (o->as_int(self.nth(o, r, REF_DEF_LINE)) == dl)
                        && (o->as_int(self.nth(o, r, REF_DEF_CHAR)) == def_ch)
                        && (o->str(self.nth(o, o->get(of, SK_FILES), fi)) == def_path)
                    if same && (with_decl || (o->as_int(self.nth(o, r, REF_IS_DECL)) == 0)) {
                        var line = self.shift_out(sh, ei, path, o->as_int(self.nth(o, r, REF_LINE)))
                        var ch   = o->as_int(self.nth(o, r, REF_CHAR))
                        var len  = o->as_int(self.nth(o, r, REF_LEN))
                        var key  = f"{path}:{line}:{ch}"
                        var dup  = line < 0 // no place on the buffer's lines
                        for var k: usize = 0; k < seen.size(); ++k {
                            if seen[k] == key {
                                dup = true
                            }
                        }

                        if !dup {
                            seen.push_back(key)
                            if mode == 0 {
                                w->begin_object()
                                w->field(K_URI, uri)
                                w->key(K_RANGE)
                                self.write_range(w, line, ch, len)
                                w->end_object()
                            } else if mode == 1 {
                                w->begin_object()
                                w->key(K_RANGE)
                                self.write_range(w, line, ch, len)
                                w->field_int(K_KIND, DHK_TEXT)
                                w->end_object()
                            } else {
                                if !opened {
                                    w->key(uri)
                                    w->begin_array()
                                    opened = true
                                }

                                w->begin_object()
                                w->key(K_RANGE)
                                self.write_range(w, line, ch, len)
                                w->field(K_NEW_TEXT, new_name)
                                w->end_object()
                            }
                        }
                    }

                    r = o->next(r)
                }

                if opened {
                    w->end_array()
                }

                of = o->next(of)
            }
        }
    }

    // --- the syntax-only pass ---------------------------------------------
}
