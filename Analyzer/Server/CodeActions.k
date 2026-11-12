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
        var rr = d->get(params, K_RANGE)
        var rs = d->get_int(d->get(rr, K_START), K_LINE)
        var re = d->get_int(d->get(rr, K_END), K_LINE)

        var w = JsonWriter()
        w.begin_array()
        var x = s->first(s->get(s->root, SK_DIAGNOSTICS))
        while x != JSON_NONE() {
            var diag = s->get(x, SK_DIAG)
            var dr   = s->get(diag, K_RANGE)
            var ds   = s->get_int(s->get(dr, K_START), K_LINE)
            var de   = s->get_int(s->get(dr, K_END), K_LINE)
            if (s->get_str(x, SK_PATH) == path) && (ds <= re) && (de >= rs) {
                var fix = s->first(s->get(x, SK_FIXES))
                var first = true
                while fix != JSON_NONE() {
                    w.begin_object()
                    w.field(K_TITLE, s->get_str(fix, K_TITLE))
                    w.field(K_KIND, KIND_QUICKFIX)
                    w.field_raw(K_DIAGNOSTICS, "[" + s->dump(diag) + "]")
                    // The compiler lists its preferred fix first.
                    w.field_bool("isPreferred", first)
                    first = false
                    w.key(K_EDIT)
                    w.begin_object()
                    w.key(K_CHANGES)
                    w.begin_object()
                    var e = s->first(s->get(fix, SK_EDITS))
                    while e != JSON_NONE() {
                        w.key(self.uri_of(s->get_str(e, SK_PATH)))
                        w.begin_array()
                        write_lsp_text_edit_raw(&w, s->dump(s->get(e, K_RANGE)), s->get_str(e, K_NEW_TEXT))
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
            var cs = d->get_int(d->get(rr, K_START), K_CHARACTER)
            var ce = d->get_int(d->get(rr, K_END), K_CHARACTER)
            var uri = self.uri_of(path)
            var m = xs->first(xs->get(mf, SK_MACROS))
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
                    write_lsp_range(&rw, ml, mc, el, ec)

                    w.begin_object()
                    w.field(K_TITLE, "View expanded macro")
                    w.field(K_KIND, KIND_QUICKFIX)
                    w.key(K_COMMAND)
                    w.begin_object()
                    w.field(K_TITLE, "View expanded macro")
                    w.field(K_COMMAND, CMD_SHOW_MACRO_EXPANSION)
                    w.key("arguments")
                    w.begin_array()
                    w.str(uri)
                    w.raw(rw.out)
                    w.str(text)
                    w.end_array()
                    w.end_object()
                    w.end_object()

                    w.begin_object()
                    w.field(K_TITLE, "Expand macro here")
                    w.field(K_KIND, KIND_REFACTOR_INLINE)
                    w.key(K_EDIT)
                    w.begin_object()
                    w.key(K_CHANGES)
                    w.begin_object()
                    w.key(uri)
                    w.begin_array()
                    write_lsp_text_edit_raw(&w, rw.out, text)
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
        write_lsp_range(&rw, line, ch, line, ch)
        return rw.out
    }

    /// True when a file of snapshot \p s declares something called \p name.
    fn snapshot_declares_(const self, s: *const JsonDoc, const name: string) -> bool {
        var f = s->first(s->get(s->root, SK_FILES))
        while f != JSON_NONE() {
            var y = s->first(s->get(f, SK_SYMBOLS))
            while y != JSON_NONE() {
                if s->get_str(y, K_NAME) == name {
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
        var st = d->get(d->get(params, K_RANGE), K_START)
        var at = self.docs.docs[di].lines.offset(*text, d->get_int(st, K_LINE) as usize, d->get_int(st, K_CHARACTER) as usize, false)
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
                if (e >= text->size()) || ((*text)[e] == (' ' as u8)) || ((*text)[e] == ('{' as u8)) || ((*text)[e] == ('<' as u8)) || ((*text)[e] == ('\n' as u8)) {
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
        w->field(K_TITLE, "Generate interface for \x27" + plan.name + "\x27")
        w->field(K_KIND, KIND_REFACTOR_EXTRACT)
        w->key(K_EDIT)
        w->begin_object()
        w->key(K_CHANGES)
        w->begin_object()
        w->key(uri)
        w->begin_array()
        // Header first: both are inserts, at different lines, so their order
        // in the array does not move either one.
        write_lsp_text_edit_raw(w, self.point_range_(hl, hc), plan.impl_text)
        write_lsp_text_edit_raw(w, self.point_range_(il, 0), plan.text)
        w->end_array()
        w->end_object()
        w->end_object()
        w->end_object()
    }

    /// The macro row of file node \p f (in \p s) whose invocation holds
    /// (line, ch), or JSON_NONE.
    fn macro_at(const self, s: *const JsonDoc, f: u32, line: i64, ch: i64) -> u32 {
        var m = s->first(s->get(f, SK_MACROS))
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
        while (le < md.size()) && (md[le] != ('\n' as u8)) {
            le += 1
        }

        var line = md.subslice(ls, le - ls)
        // The head comes first: attributes, whose arguments have their own
        // `(` (`@align(8) struct P`), so they are stepped over whole.
        while line.starts_with("@") {
            var k: usize = 1
            while (k < line.size()) && (line[k] != (' ' as u8)) && (line[k] != ('(' as u8)) {
                k += 1
            }

            if (k < line.size()) && (line[k] == ('(' as u8)) {
                var depth: usize = 0
                while k < line.size() {
                    if line[k] == ('(' as u8) {
                        depth += 1
                    } else if line[k] == (')' as u8) {
                        depth -= 1
                        if depth == 0 {
                            k += 1
                            break
                        }
                    }

                    k += 1
                }
            }

            while (k < line.size()) && (line[k] == (' ' as u8)) {
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
        while (b > 0) && (line[b - 1] != (' ' as u8)) {
            b -= 1
        }

        if stop <= b {
            return line
        }

        return line.subslice(b, stop - b)
    }
}
