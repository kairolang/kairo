/// --- The Kairo Project ------------------ Analyzer/Server/Formatting.k --- ///
///
///   Formatting through kfmt: whole document, range, on type.
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
import Resolution::ModulePath::*
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
import Server::Lifecycle::*
import Server::Lookup::*
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
    /// A `}` was typed: put it in the column of the line that opened its
    /// block. The one on-type edit that is unambiguous from the text alone.
    fn on_type(self, d: *const JsonDoc, params: u32, const id: string) {
        // Scans the whole text: materialise the edited buffers (O(document),
        // once per request, never per keystroke).
        self.docs.sync_all()
        var i = self.docs.index_of(text_document_uri(d, params))
        if (i == usize::MAX) || (d->get_str(params, "ch") != "}") {
            self.respond(id, "[]")
            return
        }

        var *text = &self.docs.docs[i].text
        var pos = d->get(params, K_POSITION)
        var at = self.docs.docs[i].lines.offset(
            *text,
            d->get_int(pos, K_LINE) as usize,
            d->get_int(pos, K_CHARACTER) as usize,
            false,
        )

        if (at == 0) || ((*text)[at - 1] != ('}' as u8)) {
            self.respond(id, "[]")
            return
        }

        var close = at - 1
        var ls = self.docs.docs[i].lines.starts[self.docs.docs[i].lines.line_of(close)]
        // Only when the brace is the first thing on its line.
        for var p: usize = ls; p < close; ++p {
            if ((*text)[p] != (' ' as u8)) && ((*text)[p] != ('\t' as u8)) {
                self.respond(id, "[]")
                return
            }
        }

        var sp = spans(*text)
        var open = usize::MAX
        for var k: usize = 0; k < sp.size(); ++k {
            if (sp[k].kind == 0) && (sp[k].close == close) {
                open = sp[k].open
            }
        }

        if open == usize::MAX {
            self.respond(id, "[]")
            return
        }

        var os = self.docs.docs[i].lines.starts[self.docs.docs[i].lines.line_of(open)]
        var oe = os
        while (oe < text->size()) && (((*text)[oe] == (' ' as u8)) || ((*text)[oe] == ('\t' as u8))) {
            oe += 1
        }

        var want = text->subslice(os, oe - os)
        if want == text->subslice(ls, close - ls) {
            self.respond(id, "[]")
            return
        }

        var w = JsonWriter()
        w.begin_array()
        w.begin_object()
        w.key(K_RANGE)
        self.write_buf_range(&w, i, ls, close)
        w.field(K_NEW_TEXT, want)
        w.end_object()
        w.end_array()
        self.respond(id, w.out)
    }

    /// Formatting is kfmt's, run as the same binary a terminal would run, so
    /// the editor and `kfmt --write` can never disagree.
    fn formatting(self, d: *const JsonDoc, params: u32, const id: string) {
        // Scans the whole text: materialise the edited buffers (O(document),
        // once per request, never per keystroke).
        self.docs.sync_all()
        var i = self.docs.index_of(text_document_uri(d, params))
        if i == usize::MAX {
            self.respond(id, "null")
            return
        }

        var kfmt = self.tool("kfmt")
        if kfmt.empty() {
            self.respond_error(id, ERR_REQUEST_FAILED, "kfmt was not found beside kals or on PATH")
            return
        }

        var src = self.scratch(kairo_dot_ext())
        var out = self.scratch(".fmt")
        LinkFS::write(src, self.docs.docs[i].text)

        var argv: [string]
        argv.push_back(kfmt)
        argv.push_back("--stdout")
        argv.push_back(src)
        var rc = self.run_and_wait(&argv, out)

        var text: string = ""
        var read = LinkFS::read(out, &text)
        Path::remove_file(src)
        Path::remove_file(out)

        if (rc != 0) || (!read) {
            // kfmt refuses a file that does not parse, and says where: its
            // first line is the reason, with the scratch name taken out.
            var why: string = ""
            for var k: usize = 0; (k < text.size()) && (text[k] != ('\n' as u8)) && (k < 300); ++k {
                why.push_back(text[k])
            }

            if why.starts_with(src) {
                why = why.subslice(src.size(), why.size() - src.size())
            }

            self.say(MSG_WARNING, "kfmt did not format " + self.docs.docs[i].path + why)
            self.respond_error(id, ERR_REQUEST_FAILED, "kfmt did not format this file" + why)
            return
        }

        var *old = &self.docs.docs[i].text
        if text == *old {
            self.respond(id, "[]")
            return
        }

        // The smallest whole-line edit that turns the buffer into kfmt's
        // output: an editor keeps cursors, folds and marks outside it, which
        // a replace-everything edit throws away.
        var a: usize = 0
        while (a < old->size()) && (a < text.size()) && ((*old)[a] == text[a]) {
            a += 1
        }

        while (a > 0) && ((*old)[a - 1] != ('\n' as u8)) {
            a -= 1
        }

        var oe = old->size()
        var ne = text.size()
        while (oe > a) && (ne > a) && ((*old)[oe - 1] == text[ne - 1]) {
            oe -= 1
            ne -= 1
        }

        while (oe < old->size()) && ((*old)[oe - 1] != ('\n' as u8)) && (oe > 0) {
            oe += 1
            ne += 1
        }

        if oe > old->size() {
            oe = old->size()
        }

        if ne > text.size() {
            ne = text.size()
        }

        if ne < a {
            ne = a
        }

        // Range formatting: kfmt formats a file, so the answer is its edit
        // when that edit lies inside the lines asked for, and nothing
        // otherwise (never a change the user did not select).
        var rr = d->get(params, K_RANGE)
        if d->is_object(rr) {
            var lo = d->get_int(d->get(rr, K_START), K_LINE) as usize
            var hi = d->get_int(d->get(rr, K_END), K_LINE) as usize
            var el = self.docs.docs[i].lines.line_of(a)
            var eh = self.docs.docs[i].lines.line_of(if oe > a => (oe - 1) else => a)
            if (el < lo) || (eh > hi) {
                self.respond(id, "[]")
                return
            }
        }

        var w = JsonWriter()
        w.begin_array()
        w.begin_object()
        w.key(K_RANGE)
        self.write_buf_range(&w, i, a, oe)
        w.field(K_NEW_TEXT, text.subslice(a, ne - a))
        w.end_object()
        w.end_array()
        self.respond(id, w.out)
    }
}
