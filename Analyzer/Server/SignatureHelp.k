/// --- The Kairo Project --------------- Analyzer/Server/SignatureHelp.k --- ///
///
///   Signature help.
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
import Server::Structure::*
import Server::TextUtil::*
import Server::Tokens::*
import Server::Workers::*

extend Server {
    /// The signatures of the function whose argument list the cursor is in.
    ///
    /// The call is found in the text (it is usually half typed, so no
    /// snapshot has it); its name is then looked up among the declarations
    /// the snapshots have hover text for. Every `fn name(` found is offered,
    /// which is exactly the overload set a reader wants to see.
    fn signature_help(self, d: *const JsonDoc, params: u32, const id: string) {
        // Scans the whole text: materialise the edited buffers (O(document),
        // once per request, never per keystroke).
        self.docs.sync_all()
        var i = self.docs.index_of(text_document_uri(d, params))
        if i == usize::MAX {
            self.respond(id, "null")
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

        var site = call_at(*text, at)
        if site.open == usize::MAX {
            self.respond(id, "null")
            return
        }

        var e = site.open
        while (e > 0) && (((*text)[e - 1] == 32) || ((*text)[e - 1] == 9)) {
            e -= 1
        }

        var b = e
        while (b > 0) && is_ident_byte((*text)[b - 1]) {
            b -= 1
        }

        if b == e {
            self.respond(id, "null")
            return
        }

        var name   = text->subslice(b, e - b)
        var prefix = "fn " + name + "("

        var labels: [string]
        var docs:   [string]
        for var ei: usize = 0; ei < self.entries.size(); ++ei {
            if !self.entries[ei].has_idx {
                continue
            }

            var *o = &self.entries[ei].idx
            var of = o->first(o->get(o->root, SK_FILES))
            while of != JSON_NONE() {
                var h = o->first(o->get(of, SK_HOVERS))
                while h != JSON_NONE() {
                    var md = o->str(h)
                    // The signature is the code block's one line, after its
                    // head (attributes, visibility, modifiers): from `fn`.
                    var ls: usize = 9
                    var le = ls
                    while (le < md.size()) && (md[le] != 10) {
                        le += 1
                    }

                    var at = usize::MAX
                    if md.starts_with("```kairo\n") {
                        at = find_from(md.subslice(ls, le - ls), prefix, 0)
                    }

                    // `fn` as a word: not the tail of a longer one.
                    if (at != usize::MAX) && (at > 0) && (md[ls + at - 1] != 32) {
                        at = usize::MAX
                    }

                    if at != usize::MAX {
                        var label = md.subslice(ls + at, le - ls - at)
                        var cut = find_from(label, "  //", 0)
                        if cut != usize::MAX {
                            label = label.subslice(0, cut)
                        }

                        // `= default` / `= delete` / `= virtual` are the
                        // body, not the call's shape.
                        cut = find_from(label, " = ", 0)
                        if cut != usize::MAX {
                            label = label.subslice(0, cut)
                        }

                        var dup = false
                        for var q: usize = 0; q < labels.size(); ++q {
                            if labels[q] == label {
                                dup = true
                            }
                        }

                        if !dup {
                            labels.push_back(label)
                            var sep = find_from(md, "\n---\n\n", 0)
                            if sep != usize::MAX {
                                docs.push_back(md.subslice(sep + 6, md.size() - sep - 6))
                            } else {
                                docs.push_back("")
                            }
                        }
                    }

                    h = o->next(h)
                }

                of = o->next(of)
            }
        }

        if labels.empty() {
            // No snapshot has seen this function declared or used (it is
            // being called for the first time). Its declaration is still in
            // some file the entry reads: find `fn name(` in their text.
            var ei = self.entry_of(self.docs.docs[i].path)
            if ei != usize::MAX {
                var needle = "fn " + name + "("
                for var fidx: usize = 0; (fidx < self.entries[ei].files.size()) && (labels.size() < MAX_SIGNATURES); ++fidx {
                    var src: string = ""
                    var di = self.docs.index_of_path(self.entries[ei].files[fidx])
                    if di != usize::MAX {
                        src = self.docs.docs[di].text
                    } else if !LinkFS::read(self.entries[ei].files[fidx], &src) {
                        continue
                    }

                    var from: usize = 0
                    while labels.size() < MAX_SIGNATURES {
                        var hit = find_from(src, needle, from)
                        if hit == usize::MAX {
                            break
                        }

                        from = hit + needle.size()
                        // The signature runs to the body, an `=`, a `where`
                        // / `requires` clause, or the end of the line.
                        var e2 = hit
                        var depth: usize = 0
                        while e2 < src.size() {
                            var ch = src[e2]
                            if ch == 40 {
                                depth += 1
                            } else if (ch == 41) && (depth > 0) {
                                depth -= 1
                            } else if (depth == 0) && ((ch == 123) || (ch == 10) || (ch == 61)) {
                                break
                            }

                            e2 += 1
                        }

                        var label = src.subslice(hit, e2 - hit)
                        var cut = find_from(label, " where ", 0)
                        if cut == usize::MAX {
                            cut = find_from(label, " requires ", 0)
                        }

                        if cut != usize::MAX {
                            label = label.subslice(0, cut)
                        }

                        while (label.size() > 0) && (label[label.size() - 1] == 32) {
                            label = label.subslice(0, label.size() - 1)
                        }

                        var dup = false
                        for var q: usize = 0; q < labels.size(); ++q {
                            if labels[q] == label {
                                dup = true
                            }
                        }

                        if !dup {
                            labels.push_back(label)
                            docs.push_back("")
                        }
                    }
                }
            }
        }

        if labels.empty() {
            self.respond(id, "null")
            return
        }

        var active_sig: usize = 0
        var picked = false
        var w = JsonWriter()
        w.begin_object()
        w.key("signatures")
        w.begin_array()
        for var q: usize = 0; q < labels.size(); ++q {
            w.begin_object()
            w.field(K_LABEL, labels[q])
            if !docs[q].empty() {
                w.key(K_DOCUMENTATION)
                w.begin_object()
                w.field(K_KIND, MARKUP_MARKDOWN)
                w.field(K_VALUE, docs[q])
                w.end_object()
            }

            // Parameters as [start, end) offsets into the label: the text
            // between the outer parentheses, split at top-level commas. A
            // leading `self` is not something the caller writes.
            w.key("parameters")
            w.begin_array()
            var lp = find_from(labels[q], "(", 0)
            var count: usize = 0
            if lp != usize::MAX {
                var depth: usize = 0
                var start = lp + 1
                for var c: usize = lp + 1; c < labels[q].size(); ++c {
                    var ch = labels[q][c]
                    if (ch == 40) || (ch == 91) || (ch == 60) {
                        depth += 1
                    } else if ((ch == 41) || (ch == 93) || (ch == 62)) && (depth > 0) {
                        // `->` is not a closing angle bracket.
                        if !((ch == 62) && (c > 0) && (labels[q][c - 1] == 45)) {
                            depth -= 1
                        }
                    } else if ((ch == 44) || (ch == 41)) && (depth == 0) {
                        var ps = start
                        while (ps < c) && (labels[q][ps] == 32) {
                            ps += 1
                        }

                        var piece = labels[q].subslice(ps, c - ps)
                        if (c > ps) && (piece != "self") && (piece != "const self") {
                            w.begin_object()
                            w.key(K_LABEL)
                            w.begin_array()
                            w.uint(ps)
                            w.uint(c)
                            w.end_array()
                            w.end_object()
                            count += 1
                        }

                        start = c + 1
                        if ch == 41 {
                            break
                        }
                    }
                }
            }

            w.end_array()
            w.end_object()

            // The first overload with room for the argument being typed.
            if (!picked) && (count > site.commas) {
                active_sig = q
                picked     = true
            }
        }

        w.end_array()
        w.field_uint("activeSignature", active_sig)
        w.field_uint("activeParameter", site.commas)
        w.end_object()
        self.respond(id, w.out)
    }
}
