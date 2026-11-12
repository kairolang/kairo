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
import Json::{
    JSON_NONE,
    JsonDoc,
    JsonWriter,
}
import JsonRpc::Transport
import Protocol::*
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
import Support::FileIO::Path::Path
import TextScan::{
    InterfacePlan,
    Span,
    call_at,
    interface_for,
    spans,
}
import Tuning::*
import Workspace::CompileCommandsLoader::{
    Project,
    project_file_name,
}
import std::io

extend Server {
    /// A CallHierarchyItem / TypeHierarchyItem: both have this shape.
    fn hierarchy_item(self,
                      w:          *JsonWriter,
                      const name: string,
                      kind:       i64,
                      const path: string,
                      line:       i64,
                      ch:         i64,
                      len:        i64) {
        w->begin_object()
        w->field(K_NAME, name)
        w->field_int(K_KIND, kind)
        w->field(K_URI, self.uri_of(path))
        w->key(K_RANGE)
        self.write_range(w, line, ch, len)
        w->key(K_SELECTION_RANGE)
        self.write_range(w, line, ch, len)
        w->end_object()
    }

    /// The function symbol of file node \p f whose body holds (line, ch).
    fn enclosing_fn(const self, s: *const JsonDoc, f: u32, line: i64, ch: i64) -> u32 {
        var best = JSON_NONE()
        var c    = s->first(s->get(f, SK_SYMBOLS))
        while c != JSON_NONE() {
            var k = s->get_int(c, K_KIND)
            if (k == SYM_FUNCTION) || (k == SYM_METHOD) {
                var r  = s->get(c, K_RANGE)
                var st = s->get(r, K_START)
                var en = s->get(r, K_END)
                var sl = s->get_int(st, K_LINE)
                var el = s->get_int(en, K_LINE)
                var after = (line > sl) || ((line == sl) && (ch >= s->get_int(st, K_CHARACTER)))
                var before = (line < el) || ((line == el) && (ch <= s->get_int(en, K_CHARACTER)))
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
        var path = self.path_of(d->get_str(item, K_URI))
        var sel  = d->get(d->get(item, K_SELECTION_RANGE), K_START)
        var line = d->get_int(sel, K_LINE)
        var ch   = d->get_int(sel, K_CHARACTER)

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
            var of = o->first(o->get(o->root, SK_FILES))
            while of != JSON_NONE() {
                var fpath = o->get_str(of, SK_PATH)
                if (!incoming) && (fpath != path) {
                    of = o->next(of)
                    continue
                }

                // Outgoing: the body is the symbol whose name is the item.
                var body = JSON_NONE()
                if !incoming {
                    var c = o->first(o->get(of, SK_SYMBOLS))
                    while c != JSON_NONE() {
                        var ss = o->get(o->get(c, K_SELECTION_RANGE), K_START)
                        if (o->get_int(ss, K_LINE) == line) && (o->get_int(ss, K_CHARACTER) == ch) {
                            body = c
                        }

                        c = o->next(c)
                    }

                    if body == JSON_NONE() {
                        of = o->next(of)
                        continue
                    }
                }

                var r = o->first(o->get(of, SK_REFS))
                while r != JSON_NONE() {
                    var fi   = o->as_int(self.nth(o, r, REF_DEF_FILE))
                    var kind = o->as_int(self.nth(o, r, REF_KIND))
                    var rl   = o->as_int(self.nth(o, r, REF_LINE))
                    var rc   = o->as_int(self.nth(o, r, REF_CHAR))
                    var use = (fi >= 0)
                        && (o->as_int(self.nth(o, r, REF_IS_DECL)) == 0)
                        && ((kind == 11) || (kind == 12))
                    if !use {
                        r = o->next(r)
                        continue
                    }

                    var dpath = o->str(self.nth(o, o->get(of, SK_FILES), fi))
                    var dl    = o->as_int(self.nth(o, r, REF_DEF_LINE))
                    var dc    = o->as_int(self.nth(o, r, REF_DEF_CHAR))

                    var key: string = ""
                    var head        = JsonWriter()
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

                        var fs = o->get(
                            o->get(from, K_SELECTION_RANGE),
                            K_START,
                        )

                        var fe = o->get(o->get(from, K_SELECTION_RANGE), K_END)
                        key = fpath + ":" + o->dump(fs)
                        self.hierarchy_item(
                            &head,
                            o->get_str(from, K_NAME),
                            SYM_FUNCTION,
                            fpath,
                            o->get_int(fs, K_LINE),
                            o->get_int(fs, K_CHARACTER),
                            o->get_int(fe, K_CHARACTER) - o->get_int(
                                fs,
                                K_CHARACTER,
                            ),
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
                            self.name_in_hover(
                                o->str(
                                    self.nth(
                                        o,
                                        o->get(of, SK_HOVERS),
                                        o->as_int(self.nth(o, r, REF_HOVER)),
                                    ),
                                ),
                            ),
                            12,
                            dpath,
                            dl,
                            dc,
                            o->as_int(self.nth(o, r, REF_DEF_LEN)),
                        )
                    }

                    var rw = JsonWriter()
                    self.write_range(
                        &rw,
                        rl,
                        rc,
                        o->as_int(self.nth(o, r, REF_LEN)),
                    )

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
    /// Locations for "go to implementation". (path, line) is in \p sh's
    /// index's lines when \p sh is active, and every result is placed on the
    /// buffer's lines through it (Lookup.k, LineShift).
    fn related_types(self,
                     const path: string,
                     line:       i64,
                     ch:         i64,
                     up:         bool,
                     w:          *JsonWriter,
                     items:      bool,
                     sh:         *const LineShift) {
        var seen: [string]
        for var ei: usize = 0; ei < self.entries.size(); ++ei {
            if !self.entries[ei].has_idx {
                continue
            }

            var ql = self.shift_across(sh, ei, path, line)
            if ql < 0 {
                continue // this index has a different text of the queried line
            }

            var *o = &self.entries[ei].idx
            var of = o->first(o->get(o->root, SK_FILES))
            while of != JSON_NONE() {
                var fpath = o->get_str(of, SK_PATH)
                var b     = o->first(o->get(of, SK_BASES))
                while b != JSON_NONE() {
                    var bpath = o->str(
                        self.nth(
                            o,
                            o->get(of, SK_FILES),
                            o->as_int(self.nth(o, b, BASE_BASE_FILE)),
                        ),
                    )

                    var dl = o->as_int(self.nth(o, b, BASE_LINE))
                    var dc = o->as_int(self.nth(o, b, BASE_CHAR))
                    var bl = o->as_int(self.nth(o, b, BASE_BASE_LINE))
                    var bc = o->as_int(self.nth(o, b, BASE_BASE_CHAR))

                    var hit          = false
                    var rp:   string = ""
                    var rl:   i64    = 0
                    var rc:   i64    = 0
                    var rn:   i64    = 0
                    var name: string = ""
                    var kind: i64    = SYM_CLASS
                    if up && (fpath == path) && (dl == ql) && (dc == ch) {
                        hit  = true
                        rp   = bpath
                        rl   = bl
                        rc   = bc
                        rn   = o->as_int(self.nth(o, b, BASE_BASE_LEN))
                        name = o->str(self.nth(o, b, BASE_BASE_NAME))
                        kind = o->as_int(self.nth(o, b, BASE_BASE_KIND))
                    } else if (!up) && (bpath == path) && (bl == ql) && (bc == ch) {
                        hit  = true
                        rp   = fpath
                        rl   = dl
                        rc   = dc
                        rn   = o->as_int(self.nth(o, b, BASE_LEN))
                        name = o->str(self.nth(o, b, BASE_NAME))
                        kind = o->as_int(self.nth(o, b, BASE_KIND))
                    }

                    if hit {
                        rl = self.shift_out(sh, ei, rp, rl)
                    }

                    if hit && (rl >= 0) {
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
                                self.hierarchy_item(
                                    w,
                                    name,
                                    kind,
                                    rp,
                                    rl,
                                    rc,
                                    rn,
                                )
                            } else {
                                w->begin_object()
                                w->field(K_URI, self.uri_of(rp))
                                w->key(K_RANGE)
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
    /// \param sh  the index is of an older text of the buffer (inactive: it
    ///            is not): a lens is placed on the buffer's line, and one
    ///            whose line the edits changed is not sent.
    fn code_lens(self,
                 s:          *const JsonDoc,
                 f:          u32,
                 const path: string,
                 const id:   string,
                 sh:         *const LineShift) {
        // One pass over every snapshot's refs, counting uses per declaration
        // of THIS file; a use is counted once however many entries index it.
        var decl_keys: [string]
        var counts:    [usize]
        var sites:     [string]
        var c                   = s->first(s->get(f, SK_SYMBOLS))
        while c != JSON_NONE() {
            var ss = s->get(s->get(c, K_SELECTION_RANGE), K_START)
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
            var of = o->first(o->get(o->root, SK_FILES))
            while of != JSON_NONE() {
                var fpath = o->get_str(of, SK_PATH)
                var r     = o->first(o->get(of, SK_REFS))
                while r != JSON_NONE() {
                    var fi = o->as_int(self.nth(o, r, REF_DEF_FILE))
                    if (fi >= 0)
                        && (o->as_int(self.nth(o, r, REF_IS_DECL)) == 0)
                        && (o->str(self.nth(o, o->get(of, SK_FILES), fi)) == path) {
                        var dl = o->as_int(self.nth(o, r, REF_DEF_LINE))
                        var dc = o->as_int(self.nth(o, r, REF_DEF_CHAR))
                        // Written as the snapshot writes a position, so it
                        // compares equal to the dumped selectionRange starts.
                        var kw = JsonWriter()
                        write_lsp_position(&kw, dl, dc)
                        var key = kw.out
                        var site = fpath + ":" + f"{o->as_int(self.nth(o, r, REF_LINE))}" + ":" + f"{o->as_int(self.nth(o, r, REF_CHAR))}" + ";"
                        for var k: usize = 0; k < decl_keys.size(); ++k {
                            if (decl_keys[k] == key)
                                && (find_from(sites[k], site, 0) == usize::MAX) {
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
        c = s->first(s->get(f, SK_SYMBOLS))
        while c != JSON_NONE() {
            var kind = s->get_int(c, K_KIND)
            var wanted = (kind == SYM_FUNCTION)
                || (kind == SYM_METHOD)
                || (kind == SYM_CLASS)
                || (kind == SYM_STRUCT)
                || (kind == SYM_INTERFACE)
                || (kind == SYM_ENUM)
            var sel = s->get(c, K_SELECTION_RANGE)
            var l0  = s->get_int(s->get(sel, K_START), K_LINE)
            var l1  = s->get_int(s->get(sel, K_END), K_LINE)
            if wanted && sh->active && (!sh->kept(l0, l1)) {
                wanted = false
            }

            if wanted && sh->active {
                w.begin_object()
                w.key(K_RANGE)
                write_lsp_range(
                    &w,
                    sh->to_new(l0),
                    s->get_int(s->get(sel, K_START), K_CHARACTER),
                    sh->to_new(l1),
                    s->get_int(s->get(sel, K_END), K_CHARACTER),
                )
            } else if wanted {
                w.begin_object()
                w.field_raw(K_RANGE, s->dump(s->get(c, K_SELECTION_RANGE)))
            }

            if wanted {
                w.key(K_COMMAND)
                w.begin_object()
                var n = counts[k]
                w.field(
                    K_TITLE,
                    if n == 1 => "1 reference" else => (f"{n}" + " references"),
                )

                // No command id: the lens is information. An editor that
                // wants a click wires its own "show references" to it.
                w.field(K_COMMAND, "")
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
