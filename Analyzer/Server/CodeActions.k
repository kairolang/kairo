/// --- The Kairo Project ----------------- Analyzer/Server/CodeActions.k --- ///
///
///   Code actions: quick fixes, macro expansion, generate interface.
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
import Server::Tokens::*
import Server::Workers::*

extend Server {
    /// Quick fixes: the compiler's fix-its for the diagnostics the requested
    /// range touches, each as an edit the editor applies.
    fn code_action(self,
                   d:          *const JsonDoc,
                   params:     u32,
                   const id:   string,
                   s:          *const JsonDoc,
                   const path: string,
                   ei:         usize,
                   mf:         u32) {
        var rr = d->get(params, "range")
        var rs = d->get_int(d->get(rr, "start"), "line")
        var re = d->get_int(d->get(rr, "end"), "line")

        var w = JsonWriter()
        w.begin_array()
        var x = s->first(s->get(s->root, "diagnostics"))
        while x != JSON_NONE() {
            var diag = s->get(x, "diag")
            var dr   = s->get(diag, "range")
            var ds   = s->get_int(s->get(dr, "start"), "line")
            var de   = s->get_int(s->get(dr, "end"), "line")
            if (s->get_str(x, "path") == path) && (ds <= re) && (de >= rs) {
                var fix = s->first(s->get(x, "fixes"))
                var first = true
                while fix != JSON_NONE() {
                    w.begin_object()
                    w.field("title", s->get_str(fix, "title"))
                    w.field("kind", KIND_QUICKFIX)
                    w.field_raw("diagnostics", "[" + s->dump(diag) + "]")
                    // The compiler lists its preferred fix first.
                    w.field_bool("isPreferred", first)
                    first = false
                    w.key("edit")
                    w.begin_object()
                    w.key("changes")
                    w.begin_object()
                    var e = s->first(s->get(fix, "edits"))
                    while e != JSON_NONE() {
                        w.key(self.uri_of(s->get_str(e, "path")))
                        w.begin_array()
                        w.begin_object()
                        w.field_raw("range", s->dump(s->get(e, "range")))
                        w.field("newText", s->get_str(e, "newText"))
                        w.end_object()
                        w.end_array()
                        e = s->next(e)
                    }

                    w.end_object()
                    w.end_object()
                    w.end_object()
                    fix = s->next(fix)
                }
            }

            x = s->next(x)
        }

        // On a macro invocation: show what it expands to beside the editor
        // (a command the kairo-lsp clients implement), or replace it with
        // that text (an edit: works in any client).
        if (mf != JSON_NONE()) && (ei < self.entries.size()) && self.entries[ei].has_idx {
            var *xs = &self.entries[ei].idx
            var cs = d->get_int(d->get(rr, "start"), "character")
            var ce = d->get_int(d->get(rr, "end"), "character")
            var uri = self.uri_of(path)
            var m = xs->first(xs->get(mf, "macros"))
            while m != JSON_NONE() {
                var ml = xs->as_int(self.nth(xs, m, MACRO_LINE))
                var mc = xs->as_int(self.nth(xs, m, MACRO_CHAR))
                var el = xs->as_int(self.nth(xs, m, MACRO_END_LINE))
                var ec = xs->as_int(self.nth(xs, m, MACRO_END_CHAR))
                // the request range [rs:cs, re:ce] touches [ml:mc, el:ec]
                var before = (re < ml) || ((re == ml) && (ce < mc))
                var after  = (rs > el) || ((rs == el) && (cs > ec))
                if (!before) && (!after) {
                    var text = xs->str(self.nth(xs, m, MACRO_TEXT))
                    var rw = JsonWriter()
                    rw.begin_object()
                    rw.key("start")
                    rw.begin_object()
                    rw.field_int("line", ml)
                    rw.field_int("character", mc)
                    rw.end_object()
                    rw.key("end")
                    rw.begin_object()
                    rw.field_int("line", el)
                    rw.field_int("character", ec)
                    rw.end_object()
                    rw.end_object()

                    w.begin_object()
                    w.field("title", "View expanded macro")
                    w.field("kind", KIND_QUICKFIX)
                    w.key("command")
                    w.begin_object()
                    w.field("title", "View expanded macro")
                    w.field("command", CMD_SHOW_MACRO_EXPANSION)
                    w.key("arguments")
                    w.begin_array()
                    w.str(uri)
                    w.raw(rw.out)
                    w.str(text)
                    w.end_array()
                    w.end_object()
                    w.end_object()

                    w.begin_object()
                    w.field("title", "Expand macro here")
                    w.field("kind", KIND_REFACTOR_INLINE)
                    w.key("edit")
                    w.begin_object()
                    w.key("changes")
                    w.begin_object()
                    w.key(uri)
                    w.begin_array()
                    w.begin_object()
                    w.field_raw("range", rw.out)
                    w.field("newText", text)
                    w.end_object()
                    w.end_array()
                    w.end_object()
                    w.end_object()
                    w.end_object()
                }

                m = xs->next(m)
            }
        }

        self.interface_action_(d, params, s, path, &w)
        w.end_array()
        self.respond(id, w.out)
    }

    /// An empty LSP range at (line, ch): where an insert goes.
    fn point_range_(const self, line: i64, ch: i64) -> string {
        var rw = JsonWriter()
        rw.begin_object()
        rw.key("start")
        rw.begin_object()
        rw.field_int("line", line)
        rw.field_int("character", ch)
        rw.end_object()
        rw.key("end")
        rw.begin_object()
        rw.field_int("line", line)
        rw.field_int("character", ch)
        rw.end_object()
        rw.end_object()
        return rw.out
    }

    /// True when a file of snapshot \p s declares something called \p name.
    fn snapshot_declares_(const self, s: *const JsonDoc, const name: string) -> bool {
        var f = s->first(s->get(s->root, "files"))
        while f != JSON_NONE() {
            var y = s->first(s->get(f, "symbols"))
            while y != JSON_NONE() {
                if s->get_str(y, "name") == name {
                    return true
                }

                y = s->next(y)
            }

            f = s->next(f)
        }

        return false
    }

    /// "Generate interface for 'Name'" (`refactor.extract`) with the cursor on
    /// a class or struct name where it is declared: the interface above the
    /// type, and `impl` in the type's header (classes-interfaces spells
    /// conformance `class Name impl I`), as one edit. The plan comes from the
    /// buffer's text (TextScan::interface_for); the snapshot only says whether
    /// `IName` is taken, in which case it is `NameInterface`.
    fn interface_action_(self, d: *const JsonDoc, params: u32, s: *const JsonDoc, const path: string, w: *JsonWriter) {
        self.docs.sync_all()
        var di = self.docs.index_of_path(path)
        if di == usize::MAX {
            return
        }

        var *text = &self.docs.docs[di].text
        var st = d->get(d->get(params, "range"), "start")
        var at = self.docs.docs[di].lines.offset(*text, d->get_int(st, "line") as usize, d->get_int(st, "character") as usize, false)
        var plan = interface_for(*text, at, "")
        if !plan.ok {
            return
        }

        var iname = "I" + plan.name
        var taken = self.snapshot_declares_(s, iname)
        if !taken {
            var spaced = "interface " + iname
            var k = text->rfind(spaced)
            while (k != usize::MAX) && (!taken) {
                var e = k + spaced.size()
                if (e >= text->size()) || ((*text)[e] == 32) || ((*text)[e] == 123) || ((*text)[e] == 60) || ((*text)[e] == 10) {
                    taken = true
                }

                if k == 0 {
                    break
                }

                k = text->subslice(0, k).rfind(spaced)
            }
        }

        if taken {
            iname = plan.name + "Interface"
            plan = interface_for(*text, at, iname)
            if !plan.ok {
                return
            }
        }

        var il = self.docs.docs[di].lines.line_of(plan.insert_at) as i64
        var hl = self.docs.docs[di].lines.line_of(plan.impl_at) as i64
        var hc = self.docs.docs[di].lines.character(*text, plan.impl_at, false) as i64
        var uri = self.uri_of(path)

        w->begin_object()
        w->field("title", "Generate interface for \x27" + plan.name + "\x27")
        w->field("kind", KIND_REFACTOR_EXTRACT)
        w->key("edit")
        w->begin_object()
        w->key("changes")
        w->begin_object()
        w->key(uri)
        w->begin_array()
        // Header first: both are inserts, at different lines, so their order
        // in the array does not move either one.
        w->begin_object()
        w->field_raw("range", self.point_range_(hl, hc))
        w->field("newText", plan.impl_text)
        w->end_object()
        w->begin_object()
        w->field_raw("range", self.point_range_(il, 0))
        w->field("newText", plan.text)
        w->end_object()
        w->end_array()
        w->end_object()
        w->end_object()
        w->end_object()
    }

    /// The macro row of file node \p f (in \p s) whose invocation holds
    /// (line, ch), or JSON_NONE.
    fn macro_at(const self, s: *const JsonDoc, f: u32, line: i64, ch: i64) -> u32 {
        var m = s->first(s->get(f, "macros"))
        while m != JSON_NONE() {
            var ml = s->as_int(self.nth(s, m, MACRO_LINE))
            var mc = s->as_int(self.nth(s, m, MACRO_CHAR))
            var el = s->as_int(self.nth(s, m, MACRO_END_LINE))
            var ec = s->as_int(self.nth(s, m, MACRO_END_CHAR))
            var after_start = (line > ml) || ((line == ml) && (ch >= mc))
            var before_end  = (line < el) || ((line == el) && (ch <= ec))
            if after_start && before_end {
                return m
            }

            m = s->next(m)
        }

        return JSON_NONE()
    }

    // --- hierarchies ------------------------------------------------------

    /// The declared name inside a hover's code line: `fn NAME(`, `class NAME`.
    fn name_in_hover(const self, const md: string) -> string {
        var ls: usize = 9 // past "```kairo\n"
        if md.size() <= ls {
            return "?"
        }

        var le = ls
        while (le < md.size()) && (md[le] != 10) {
            le += 1
        }

        var line = md.subslice(ls, le - ls)
        // The head comes first: attributes, whose arguments have their own
        // `(` (`@align(8) struct P`), so they are stepped over whole.
        while line.starts_with("@") {
            var k: usize = 1
            while (k < line.size()) && (line[k] != 32) && (line[k] != 40) {
                k += 1
            }

            if (k < line.size()) && (line[k] == 40) {
                var depth: usize = 0
                while k < line.size() {
                    if line[k] == 40 {
                        depth += 1
                    } else if line[k] == 41 {
                        depth -= 1
                        if depth == 0 {
                            k += 1
                            break
                        }
                    }

                    k += 1
                }
            }

            while (k < line.size()) && (line[k] == 32) {
                k += 1
            }

            line = line.subslice(k, line.size() - k)
        }

        // A type's hover opens its body on the same line: `class Box {`.
        var brace = find_from(line, " {", 0)
        if brace != usize::MAX {
            line = line.subslice(0, brace)
        }

        // A type's head names its bases after its own name
        // (`class Box derives Base impl Add`): the name is before them.
        var bases = find_from(line, " derives ", 0)
        var impls = find_from(line, " impl ", 0)
        if impls < bases {
            bases = impls
        }

        if (bases != usize::MAX) && (!line.starts_with("fn ")) && (find_from(line, " fn ", 0) == usize::MAX) {
            line = line.subslice(0, bases)
        }

        // the word before `(`, or the last word of the line
        var stop = find_from(line, "(", 0)
        if (stop == usize::MAX) || line.starts_with("(") {
            stop = line.size()
            var colon = find_from(line, ":", 0)
            if colon != usize::MAX {
                stop = colon
            }
        }

        var b = stop
        while (b > 0) && (line[b - 1] != 32) {
            b -= 1
        }

        if stop <= b {
            return line
        }

        return line.subslice(b, stop - b)
    }
}
