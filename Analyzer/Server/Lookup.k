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

extend Server {
    /// Node of \p path's object in entry \p ei's snapshot, or JSON_NONE.
    fn file_node(self, ei: usize, const path: string) -> u32 {
        if (ei >= self.entries.size()) || (!self.entries[ei].has_idx) {
            return JSON_NONE()
        }

        var *s = &self.entries[ei].idx
        var f = s->first(s->get(s->root, "files"))
        while f != JSON_NONE() {
            if s->get_str(f, "path") == path {
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
        var f = s->first(s->get(s->root, "files"))
        while f != JSON_NONE() {
            e->cf_node.push_back(f)
            e->cf_lo.push_back(e->cr_row.size())
            var r = s->first(s->get(f, "refs"))
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
            var t = s->first(s->get(f, "tokens"))
            while t != JSON_NONE() {
                e->ct_data.push_back(s->as_int(t))
                t = s->next(t)
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
        var r = s->first(s->get(f, "refs"))
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

    fn write_range(self, w: *JsonWriter, line: i64, ch: i64, len: i64) {
        w->begin_object()
        w->key("start")
        w->begin_object()
        w->field_int("line", line)
        w->field_int("character", ch)
        w->end_object()
        w->key("end")
        w->begin_object()
        w->field_int("line", line)
        w->field_int("character", ch + len)
        w->end_object()
        w->end_object()
    }

    /// Every use of the declaration ref row \p row names, across every
    /// snapshot, as (uri, line, ch, len) written through \p emit_kind:
    /// 0 = Location objects, 1 = DocumentHighlight (same file only),
    /// 2 = TextEdit grouped by uri (rename).
    fn uses(self,
            s:              *const JsonDoc,
            f:              u32,
            row:            u32,
            w:              *JsonWriter,
            mode:           u32,
            const only:     string,
            const new_name: string,
            with_decl:      bool) {
        var def_file = s->as_int(self.nth(s, row, REF_DEF_FILE))
        if def_file < 0 {
            return
        }

        var def_path = s->str(self.nth(s, s->get(f, "files"), def_file))
        var def_line = s->as_int(self.nth(s, row, REF_DEF_LINE))
        var def_ch   = s->as_int(self.nth(s, row, REF_DEF_CHAR))

        // A file can be indexed under more than one entry; report each
        // location once.
        var seen: [string]

        for var ei: usize = 0; ei < self.entries.size(); ++ei {
            if !self.entries[ei].has_idx {
                continue
            }

            var *o = &self.entries[ei].idx
            var of = o->first(o->get(o->root, "files"))
            while of != JSON_NONE() {
                var path = o->get_str(of, "path")
                if (!only.empty()) && (path != only) {
                    of = o->next(of)
                    continue
                }

                var uri   = self.uri_of(path)
                var opened = false
                var r = o->first(o->get(of, "refs"))
                while r != JSON_NONE() {
                    var fi = o->as_int(self.nth(o, r, REF_DEF_FILE))
                    var same = (fi >= 0)
                        && (o->as_int(self.nth(o, r, REF_DEF_LINE)) == def_line)
                        && (o->as_int(self.nth(o, r, REF_DEF_CHAR)) == def_ch)
                        && (o->str(self.nth(o, o->get(of, "files"), fi)) == def_path)
                    if same && (with_decl || (o->as_int(self.nth(o, r, REF_IS_DECL)) == 0)) {
                        var line = o->as_int(self.nth(o, r, REF_LINE))
                        var ch   = o->as_int(self.nth(o, r, REF_CHAR))
                        var len  = o->as_int(self.nth(o, r, REF_LEN))
                        var key  = f"{path}:{line}:{ch}"
                        var dup  = false
                        for var k: usize = 0; k < seen.size(); ++k {
                            if seen[k] == key {
                                dup = true
                            }
                        }

                        if !dup {
                            seen.push_back(key)
                            if mode == 0 {
                                w->begin_object()
                                w->field("uri", uri)
                                w->key("range")
                                self.write_range(w, line, ch, len)
                                w->end_object()
                            } else if mode == 1 {
                                w->begin_object()
                                w->key("range")
                                self.write_range(w, line, ch, len)
                                w->field_int("kind", 1)
                                w->end_object()
                            } else {
                                if !opened {
                                    w->key(uri)
                                    w->begin_array()
                                    opened = true
                                }

                                w->begin_object()
                                w->key("range")
                                self.write_range(w, line, ch, len)
                                w->field("newText", new_name)
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
