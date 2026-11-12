/// --- The Kairo Project ---------------------- Analyzer/Server/Tokens.k --- ///
///
///   Semantic tokens: full, delta and range.
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
import Server::Structure::*
import Server::TextUtil::*
import Server::Workers::*

extend Server {
    /// Answers a semanticTokens request (full, delta or range) from \p now,
    /// the five-integer encoding of the whole file: the index's (decoded once
    /// per snapshot), or the lexical tokens of a buffer that does not parse.
    fn send_tokens(self, d: *const JsonDoc, params: u32, const id: string, const method: string, now: *const [i64]) {
        if method == M_SEMANTIC_TOKENS_RANGE {
            // Cut to the lines asked for and re-based: the encoding is
            // relative, so the first one kept restarts it.
            var rr = d->get(params, K_RANGE)
            var lo = d->get_int(d->get(rr, K_START), K_LINE)
            var hi = d->get_int(d->get(rr, K_END), K_LINE)
            var w = JsonWriter()
            w.begin_object()
            w.key(K_DATA)
            w.begin_array()
            var tl: i64 = 0
            var tc: i64 = 0
            var pl: i64 = 0
            var pc: i64 = 0
            var t: usize = 0
            while (t + SEMTOK_STRIDE) <= now->size() {
                var dl = (*now)[t]
                var dc = (*now)[t + 1]
                if dl != 0 {
                    tl += dl
                    tc = dc
                } else {
                    tc += dc
                }

                if tl > hi {
                    break
                }

                if tl >= lo {
                    w.integer(tl - pl)
                    w.integer(if tl == pl => (tc - pc) else => tc)
                    w.integer((*now)[t + 2])
                    w.integer((*now)[t + 3])
                    w.integer((*now)[t + 4])
                    pl = tl
                    pc = tc
                }

                t += SEMTOK_STRIDE
            }

            w.end_array()
            w.end_object()
            self.respond(id, w.out)
            return
        }

        var uri = text_document_uri(d, params)
        var slot = self.tok_uri.size()
        for var q: usize = 0; q < self.tok_uri.size(); ++q {
            if self.tok_uri[q] == uri {
                slot = q
            }
        }

        if slot == self.tok_uri.size() {
            self.tok_uri.push_back(uri)
            self.tok_id.push_back(0)
            var none: [i64]
            self.tok_data.push_back(none)
        }

        self.tok_seq += 1
        var rid  = self.tok_seq
        var prev = d->get_str(params, "previousResultId")
        var have = f"{self.tok_id[slot]}"
        var w = JsonWriter()
        w.begin_object()
        w.field("resultId", f"{rid}")
        if (method == M_SEMANTIC_TOKENS_DELTA) && (prev == have) && (self.tok_id[slot] != 0) {
            // One edit: what lies between the longest common prefix and
            // suffix of the two integer arrays. Cut on token boundaries
            // (multiples of five) so a relative position is never split.
            var *old = &self.tok_data[slot]
            var a: usize = 0
            while (a < old->size()) && (a < now->size()) && ((*old)[a] == (*now)[a]) {
                a += 1
            }

            a = (a / SEMTOK_STRIDE) * SEMTOK_STRIDE
            var oe = old->size()
            var ne = now->size()
            while (oe > a) && (ne > a) && ((*old)[oe - 1] == (*now)[ne - 1]) {
                oe -= 1
                ne -= 1
            }

            while ((oe % SEMTOK_STRIDE) != 0) && (oe < old->size()) {
                oe += 1
                ne += 1
            }

            w.key(K_EDITS)
            w.begin_array()
            if (oe > a) || (ne > a) {
                w.begin_object()
                w.field_uint(K_START, a)
                w.field_uint("deleteCount", oe - a)
                w.key(K_DATA)
                w.begin_array()
                for var q: usize = a; q < ne; ++q {
                    w.integer((*now)[q])
                }

                w.end_array()
                w.end_object()
            }

            w.end_array()
        } else {
            w.key(K_DATA)
            w.begin_array()
            for var q: usize = 0; q < now->size(); ++q {
                w.integer((*now)[q])
            }

            w.end_array()
        }

        w.end_object()
        self.tok_id[slot]   = rid
        self.tok_data[slot] = *now
        self.respond(id, w.out)
    }
}
