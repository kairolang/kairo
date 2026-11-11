/// --- The Kairo Project ------------------ Analyzer/Server/Navigation.k --- ///
///
///   Hierarchies and lenses: call and type hierarchy, code lens counts.
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
import Server::Output::*
import Server::Scheduling::*
import Server::Server::*
import Server::SignatureHelp::*
import Server::Structure::*
import Server::TextUtil::*
import Server::Tokens::*
import Server::Workers::*

extend Server {
    /// A CallHierarchyItem / TypeHierarchyItem: both have this shape.
    fn hierarchy_item(self,
                      w:           *JsonWriter,
                      const name:  string,
                      kind:        i64,
                      const path:  string,
                      line:        i64,
                      ch:          i64,
                      len:         i64) {
        w->begin_object()
        w->field("name", name)
        w->field_int("kind", kind)
        w->field("uri", self.uri_of(path))
        w->key("range")
        self.write_range(w, line, ch, len)
        w->key("selectionRange")
        self.write_range(w, line, ch, len)
        w->end_object()
    }

    /// The function symbol of file node \p f whose body holds (line, ch).
    fn enclosing_fn(const self, s: *const JsonDoc, f: u32, line: i64, ch: i64) -> u32 {
        var best = JSON_NONE()
        var c = s->first(s->get(f, "symbols"))
        while c != JSON_NONE() {
            var k = s->get_int(c, "kind")
            if (k == SK_FUNCTION) || (k == SK_METHOD) {
                var r  = s->get(c, "range")
                var st = s->get(r, "start")
                var en = s->get(r, "end")
                var sl = s->get_int(st, "line")
                var el = s->get_int(en, "line")
                var after  = (line > sl) || ((line == sl) && (ch >= s->get_int(st, "character")))
                var before = (line < el) || ((line == el) && (ch <= s->get_int(en, "character")))
                if after && before {
                    best = c // source order: a later match is nested deeper
                }
            }

            c = s->next(c)
        }

        return best
    }

    /// Incoming or outgoing calls of the function \p item names.
    fn calls(self, d: *const JsonDoc, item: u32, incoming: bool, const id: string) {
        var path = self.path_of(d->get_str(item, "uri"))
        var sel  = d->get(d->get(item, "selectionRange"), "start")
        var line = d->get_int(sel, "line")
        var ch   = d->get_int(sel, "character")

        // Results are grouped by the function on the other end; `keys` holds
        // one entry per group, the parallel vectors its parts.
        var keys:   [string]
        var heads:  [string] // the item JSON
        var ranges: [string] // comma-joined fromRanges

        for var ei: usize = 0; ei < self.entries.size(); ++ei {
            if !self.entries[ei].has_idx {
                continue
            }

            var *o = &self.entries[ei].idx
            var of = o->first(o->get(o->root, "files"))
            while of != JSON_NONE() {
                var fpath = o->get_str(of, "path")
                if (!incoming) && (fpath != path) {
                    of = o->next(of)
                    continue
                }

                // Outgoing: the body is the symbol whose name is the item.
                var body = JSON_NONE()
                if !incoming {
                    var c = o->first(o->get(of, "symbols"))
                    while c != JSON_NONE() {
                        var ss = o->get(o->get(c, "selectionRange"), "start")
                        if (o->get_int(ss, "line") == line) && (o->get_int(ss, "character") == ch) {
                            body = c
                        }

                        c = o->next(c)
                    }

                    if body == JSON_NONE() {
                        of = o->next(of)
                        continue
                    }
                }

                var r = o->first(o->get(of, "refs"))
                while r != JSON_NONE() {
                    var fi   = o->as_int(self.nth(o, r, REF_DEF_FILE))
                    var kind = o->as_int(self.nth(o, r, REF_KIND))
                    var rl   = o->as_int(self.nth(o, r, REF_LINE))
                    var rc   = o->as_int(self.nth(o, r, REF_CHAR))
                    var use  = (fi >= 0) && (o->as_int(self.nth(o, r, REF_IS_DECL)) == 0) && ((kind == 11) || (kind == 12))
                    if !use {
                        r = o->next(r)
                        continue
                    }

                    var dpath = o->str(self.nth(o, o->get(of, "files"), fi))
                    var dl    = o->as_int(self.nth(o, r, REF_DEF_LINE))
                    var dc    = o->as_int(self.nth(o, r, REF_DEF_CHAR))

                    var key:  string = ""
                    var head = JsonWriter()
                    if incoming {
                        if (dpath != path) || (dl != line) || (dc != ch) {
                            r = o->next(r)
                            continue
                        }

                        var from = self.enclosing_fn(o, of, rl, rc)
                        if from == JSON_NONE() {
                            r = o->next(r)
                            continue
                        }

                        var fs = o->get(o->get(from, "selectionRange"), "start")
                        var fe = o->get(o->get(from, "selectionRange"), "end")
                        key = fpath + ":" + o->dump(fs)
                        self.hierarchy_item(
                            &head,
                            o->get_str(from, "name"),
                            SK_FUNCTION,
                            fpath,
                            o->get_int(fs, "line"),
                            o->get_int(fs, "character"),
                            o->get_int(fe, "character") - o->get_int(fs, "character"),
                        )
                    } else {
                        var inside = self.enclosing_fn(o, of, rl, rc)
                        if inside != body {
                            r = o->next(r)
                            continue
                        }

                        key = f"{dpath}:{dl}:{dc}"
                        self.hierarchy_item(
                            &head,
                            self.name_in_hover(o->str(self.nth(o, o->get(of, "hovers"), o->as_int(self.nth(o, r, REF_HOVER))))),
                            12,
                            dpath,
                            dl,
                            dc,
                            o->as_int(self.nth(o, r, REF_DEF_LEN)),
                        )
                    }

                    var rw = JsonWriter()
                    self.write_range(&rw, rl, rc, o->as_int(self.nth(o, r, REF_LEN)))
                    var g = keys.size()
                    for var q: usize = 0; q < keys.size(); ++q {
                        if keys[q] == key {
                            g = q
                        }
                    }

                    if g == keys.size() {
                        keys.push_back(key)
                        heads.push_back(head.out)
                        ranges.push_back(rw.out)
                    } else if find_from(ranges[g], rw.out, 0) == usize::MAX {
                        ranges[g] = ranges[g] + "," + rw.out
                    }

                    r = o->next(r)
                }

                of = o->next(of)
            }
        }

        var w = JsonWriter()
        w.begin_array()
        for var g: usize = 0; g < keys.size(); ++g {
            w.begin_object()
            w.field_raw(if incoming => "from" else => "to", heads[g])
            w.field_raw("fromRanges", "[" + ranges[g] + "]")
            w.end_object()
        }

        w.end_array()
        self.respond(id, w.out)
    }

    /// Types one edge from the declaration at (path, line, ch): what it
    /// derives (\p up) or what derives it. As hierarchy items, or as plain
    /// Locations for "go to implementation".
    fn related_types(self, const path: string, line: i64, ch: i64, up: bool, w: *JsonWriter, items: bool) {
        var seen: [string]
        for var ei: usize = 0; ei < self.entries.size(); ++ei {
            if !self.entries[ei].has_idx {
                continue
            }

            var *o = &self.entries[ei].idx
            var of = o->first(o->get(o->root, "files"))
            while of != JSON_NONE() {
                var fpath = o->get_str(of, "path")
                var b = o->first(o->get(of, "bases"))
                while b != JSON_NONE() {
                    var bpath = o->str(self.nth(o, o->get(of, "files"), o->as_int(self.nth(o, b, BASE_BASE_FILE))))
                    var dl = o->as_int(self.nth(o, b, BASE_LINE))
                    var dc = o->as_int(self.nth(o, b, BASE_CHAR))
                    var bl = o->as_int(self.nth(o, b, BASE_BASE_LINE))
                    var bc = o->as_int(self.nth(o, b, BASE_BASE_CHAR))

                    var hit = false
                    var rp: string = ""
                    var rl: i64 = 0
                    var rc: i64 = 0
                    var rn: i64 = 0
                    var name: string = ""
                    var kind: i64 = SK_CLASS
                    if up && (fpath == path) && (dl == line) && (dc == ch) {
                        hit  = true
                        rp   = bpath
                        rl   = bl
                        rc   = bc
                        rn   = o->as_int(self.nth(o, b, BASE_BASE_LEN))
                        name = o->str(self.nth(o, b, BASE_BASE_NAME))
                        kind = o->as_int(self.nth(o, b, BASE_BASE_KIND))
                    } else if (!up) && (bpath == path) && (bl == line) && (bc == ch) {
                        hit  = true
                        rp   = fpath
                        rl   = dl
                        rc   = dc
                        rn   = o->as_int(self.nth(o, b, BASE_LEN))
                        name = o->str(self.nth(o, b, BASE_NAME))
                        kind = o->as_int(self.nth(o, b, BASE_KIND))
                    }

                    if hit {
                        var key = f"{rp}:{rl}:{rc}"
                        var dup = false
                        for var q: usize = 0; q < seen.size(); ++q {
                            if seen[q] == key {
                                dup = true
                            }
                        }

                        if !dup {
                            seen.push_back(key)
                            if items {
                                self.hierarchy_item(w, name, kind, rp, rl, rc, rn)
                            } else {
                                w->begin_object()
                                w->field("uri", self.uri_of(rp))
                                w->key("range")
                                self.write_range(w, rl, rc, rn)
                                w->end_object()
                            }
                        }
                    }

                    b = o->next(b)
                }

                of = o->next(of)
            }
        }
    }

    /// "N references" above each function and type of the file.
    fn code_lens(self, s: *const JsonDoc, f: u32, const path: string, const id: string) {
        // One pass over every snapshot's refs, counting uses per declaration
        // of THIS file; a use is counted once however many entries index it.
        var decl_keys: [string]
        var counts:    [usize]
        var sites:     [string]
        var c = s->first(s->get(f, "symbols"))
        while c != JSON_NONE() {
            var ss = s->get(s->get(c, "selectionRange"), "start")
            decl_keys.push_back(s->dump(ss))
            counts.push_back(0)
            sites.push_back("")
            c = s->next(c)
        }

        for var ei: usize = 0; ei < self.entries.size(); ++ei {
            if !self.entries[ei].has_idx {
                continue
            }

            var *o = &self.entries[ei].idx
            var of = o->first(o->get(o->root, "files"))
            while of != JSON_NONE() {
                var fpath = o->get_str(of, "path")
                var r = o->first(o->get(of, "refs"))
                while r != JSON_NONE() {
                    var fi = o->as_int(self.nth(o, r, REF_DEF_FILE))
                    if (fi >= 0) && (o->as_int(self.nth(o, r, REF_IS_DECL)) == 0)
                        && (o->str(self.nth(o, o->get(of, "files"), fi)) == path) {
                        var dl = o->as_int(self.nth(o, r, REF_DEF_LINE))
                        var dc = o->as_int(self.nth(o, r, REF_DEF_CHAR))
                        var key  = "{\"line\":" + f"{dl}" + ",\"character\":" + f"{dc}" + "}"
                        var site = fpath + ":" + f"{o->as_int(self.nth(o, r, REF_LINE))}" + ":" + f"{o->as_int(self.nth(o, r, REF_CHAR))}" + ";"
                        for var k: usize = 0; k < decl_keys.size(); ++k {
                            if (decl_keys[k] == key) && (find_from(sites[k], site, 0) == usize::MAX) {
                                sites[k] += site
                                counts[k] += 1
                            }
                        }
                    }

                    r = o->next(r)
                }

                of = o->next(of)
            }
        }

        var w = JsonWriter()
        w.begin_array()
        var k: usize = 0
        c = s->first(s->get(f, "symbols"))
        while c != JSON_NONE() {
            var kind = s->get_int(c, "kind")
            var wanted = (kind == SK_FUNCTION) || (kind == SK_METHOD) || (kind == SK_CLASS) || (kind == SK_STRUCT) ||
                (kind == SK_INTERFACE) || (kind == SK_ENUM)
            if wanted {
                w.begin_object()
                w.field_raw("range", s->dump(s->get(c, "selectionRange")))
                w.key("command")
                w.begin_object()
                var n = counts[k]
                w.field("title", if n == 1 => "1 reference" else => (f"{n}" + " references"))
                // No command id: the lens is information. An editor that
                // wants a click wires its own "show references" to it.
                w.field("command", "")
                w.end_object()
                w.end_object()
            }

            k += 1
            c = s->next(c)
        }

        w.end_array()
        self.respond(id, w.out)
    }

    // --- answered from the text -------------------------------------------
}
