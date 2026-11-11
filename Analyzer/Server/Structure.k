/// --- The Kairo Project ------------------- Analyzer/Server/Structure.k --- ///
///
///   Document structure: symbols, folding, selection ranges, workspace symbols.
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
import Server::Lookup::*
import Server::Navigation::*
import Server::Output::*
import Server::Scheduling::*
import Server::Server::*
import Server::SignatureHelp::*
import Server::TextUtil::*
import Server::Tokens::*
import Server::Workers::*

extend Server {
    /// Writes symbol \p c with the symbols its range contains as children.
    /// Returns the next symbol that is NOT inside it. The snapshot lists
    /// symbols flat in source order, a parent before its members.
    fn symbol(self, s: *const JsonDoc, c: u32, w: *JsonWriter) -> u32 {
        var range = s->get(c, "range")
        var end   = s->get(range, "end")
        var el    = s->get_int(end, "line")
        var ec    = s->get_int(end, "character")

        w->begin_object()
        w->field("name", s->get_str(c, "name"))
        var detail = s->get_str(c, "detail")
        if !detail.empty() {
            w->field("detail", detail)
        }

        w->field_int("kind", s->get_int(c, "kind"))
        w->field_raw("range", s->dump(range))
        w->field_raw("selectionRange", s->dump(s->get(c, "selectionRange")))
        w->key("children")
        w->begin_array()
        var n = s->next(c)
        while n != JSON_NONE() {
            var st = s->get(s->get(n, "range"), "start")
            var sl = s->get_int(st, "line")
            var sc = s->get_int(st, "character")
            if (sl > el) || ((sl == el) && (sc >= ec)) {
                break
            }

            n = self.symbol(s, n, w)
        }

        w->end_array()
        w->end_object()
        return n
    }

    /// Writes `{"line":L,"character":C}` for byte \p off of buffer \p i.
    fn write_pos(self, w: *JsonWriter, i: usize, off: usize) {
        w->begin_object()
        w->field_uint("line", self.docs.docs[i].lines.line_of(off))
        w->field_uint("character", self.docs.docs[i].lines.character(self.docs.docs[i].text, off, false))
        w->end_object()
    }

    fn folding(self, d: *const JsonDoc, params: u32, const id: string) {
        // Scans the whole text: materialise the edited buffers (O(document),
        // once per request, never per keystroke).
        self.docs.sync_all()
        var i = self.docs.index_of(d->get_str(d->get(params, "textDocument"), "uri"))
        if i == usize::MAX {
            self.respond(id, "[]")
            return
        }

        var sp = spans(self.docs.docs[i].text)
        var w = JsonWriter()
        w.begin_array()
        for var k: usize = 0; k < sp.size(); ++k {
            if sp[k].close == usize::MAX {
                continue
            }

            var a = self.docs.docs[i].lines.line_of(sp[k].open)
            var b = self.docs.docs[i].lines.line_of(sp[k].close)
            if sp[k].kind == 3 {
                // The run's end is one past its last byte.
                b = self.docs.docs[i].lines.line_of(sp[k].close - 1)
            } else if b > a {
                b -= 1 // keep the closing bracket's line visible
            }

            if b <= a {
                continue
            }

            w.begin_object()
            w.field_uint("startLine", a)
            w.field_uint("endLine", b)
            if sp[k].kind == 3 {
                w.field("kind", "comment")
            }

            w.end_object()
        }

        w.end_array()
        self.respond(id, w.out)
    }

    fn selection(self, d: *const JsonDoc, params: u32, const id: string) {
        // Scans the whole text: materialise the edited buffers (O(document),
        // once per request, never per keystroke).
        self.docs.sync_all()
        var i = self.docs.index_of(d->get_str(d->get(params, "textDocument"), "uri"))
        if i == usize::MAX {
            self.respond(id, "[]")
            return
        }

        var *text = &self.docs.docs[i].text
        var sp = spans(*text)
        var w = JsonWriter()
        w.begin_array()
        var p = d->first(d->get(params, "positions"))
        while p != JSON_NONE() {
            var at = self.docs.docs[i].lines.offset(
                *text,
                d->get_int(p, "line") as usize,
                d->get_int(p, "character") as usize,
                false,
            )

            // Innermost first: the word, then each bracket's inside and
            // outside, then the file. Each is the "parent" of the one before.
            var los: [usize]
            var his: [usize]
            var ws = at
            while (ws > 0) && is_ident_byte((*text)[ws - 1]) {
                ws -= 1
            }

            var we = at
            while (we < text->size()) && is_ident_byte((*text)[we]) {
                we += 1
            }

            if we > ws {
                los.push_back(ws)
                his.push_back(we)
            }

            var k = sp.size()
            while k > 0 {
                k -= 1
                if (sp[k].kind == 3) || (sp[k].close == usize::MAX) {
                    continue
                }

                if (sp[k].open < at) && (at <= sp[k].close) {
                    los.push_back(sp[k].open + 1)
                    his.push_back(sp[k].close)
                    los.push_back(sp[k].open)
                    his.push_back(sp[k].close + 1)
                }
            }

            los.push_back(0)
            his.push_back(text->size())

            // A parent must contain its child; drop any range that does not
            // strictly grow, then nest from the outside in.
            var keep_lo: [usize]
            var keep_hi: [usize]
            for var q: usize = 0; q < los.size(); ++q {
                if keep_lo.empty() {
                    keep_lo.push_back(los[q])
                    keep_hi.push_back(his[q])
                    continue
                }

                var pl = keep_lo[keep_lo.size() - 1]
                var ph = keep_hi[keep_hi.size() - 1]
                if (los[q] <= pl) && (his[q] >= ph) && ((los[q] < pl) || (his[q] > ph)) {
                    keep_lo.push_back(los[q])
                    keep_hi.push_back(his[q])
                }
            }

            for var q: usize = 0; q < keep_lo.size(); ++q {
                w.begin_object()
                w.key("range")
                w.begin_object()
                w.key("start")
                self.write_pos(&w, i, keep_lo[q])
                w.key("end")
                self.write_pos(&w, i, keep_hi[q])
                w.end_object()
                if (q + 1) < keep_lo.size() {
                    w.key("parent")
                }
            }

            for var q: usize = 0; q < keep_lo.size(); ++q {
                w.end_object()
            }

            p = d->next(p)
        }

        w.end_array()
        self.respond(id, w.out)
    }

    /// Declarations whose name contains \p query, across every snapshot.
    fn workspace_symbols(self, const query: string, const id: string) {
        var needle = lower(query)
        var seen: [string]
        var w = JsonWriter()
        w.begin_array()
        var total: usize = 0
        for var ei: usize = 0; (ei < self.entries.size()) && (total < WORKSPACE_SYMBOL_CAP); ++ei {
            if !self.entries[ei].has_idx {
                continue
            }

            var *o = &self.entries[ei].idx
            var of = o->first(o->get(o->root, "files"))
            while (of != JSON_NONE()) && (total < WORKSPACE_SYMBOL_CAP) {
                var path = o->get_str(of, "path")
                var sy = o->first(o->get(of, "symbols"))
                while (sy != JSON_NONE()) && (total < WORKSPACE_SYMBOL_CAP) {
                    var name = o->get_str(sy, "name")
                    if needle.empty() || (find_from(lower(name), needle, 0) != usize::MAX) {
                        var range = o->dump(o->get(sy, "selectionRange"))
                        var key = path + range
                        var dup = false
                        for var q: usize = 0; q < seen.size(); ++q {
                            if seen[q] == key {
                                dup = true
                            }
                        }

                        if !dup {
                            seen.push_back(key)
                            w.begin_object()
                            w.field("name", name)
                            w.field_int("kind", o->get_int(sy, "kind"))
                            w.key("location")
                            w.begin_object()
                            w.field("uri", self.uri_of(path))
                            w.field_raw("range", range)
                            w.end_object()
                            w.end_object()
                            total += 1
                        }
                    }

                    sy = o->next(sy)
                }

                of = o->next(of)
            }
        }

        w.end_array()
        self.respond(id, w.out)
    }
}
