/// --- The Kairo Project ------------------ Analyzer/Server/Completion.k --- ///
///
///   Completion: the worker run at the cursor, import paths, the item list.
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
import Server::Diagnostics::*
import Server::CompletionWords::language_words
import Server::Features::*
import Server::Formatting::*
import Server::IndexCompletion::*
import Server::Lifecycle::*
import Server::LiveIndex::*
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
    /// Completion runs its own worker on a copy of the buffer with a marker
    /// identifier where the cursor is (Indexer.k: completion_marker).
    fn completion(self, d: *const JsonDoc, params: u32, const id: string) {
        var t0 = now_us()
        // Scans the whole text: materialise the edited buffers (O(document),
        // once per request, never per keystroke).
        self.docs.sync_all()
        var i = self.docs.index_of(text_document_uri(d, params))
        if i == usize::MAX {
            self.respond(id, "[]")
            return
        }

        // From the index when it can be: no compile, no worker, and not
        // behind a completion that is one (IndexCompletion.k).
        if self.index_complete_(i, d, params, id, t0) {
            return
        }

        if self.running(JobKind::Complete) > 0 {
            if !self.comp_wait_id.empty() {
                self.respond(self.comp_wait_id, "{\"isIncomplete\":true,\"items\":[]}")
            }

            self.comp_wait    = d->dump(d->root)
            self.comp_wait_id = id
            return
        }

        var path = self.docs.docs[i].path
        var ei   = self.ensure_entry(path)
        if ei == usize::MAX {
            self.respond(id, "{\"isIncomplete\":true,\"items\":[]}")
            return
        }

        var pos  = d->get(params, K_POSITION)
        var *text = &self.docs.docs[i].text
        var at = self.docs.docs[i].lines.offset(
            *text,
            d->get_int(pos, K_LINE) as usize,
            d->get_int(pos, K_CHARACTER) as usize,
            false,
        )

        // The identifier under the cursor, both halves: the marker replaces
        // all of it, and the editor filters the items by what was typed.
        var start = at
        while (start > 0) && is_ident_byte((*text)[start - 1]) {
            start -= 1
        }

        var end = at
        while (end < text->size()) && is_ident_byte((*text)[end]) {
            end += 1
        }

        var before = start
        while (before > 0) && (((*text)[before - 1] == (' ' as u8)) || ((*text)[before - 1] == ('\t' as u8))) {
            before -= 1
        }

        var member = false
        if before > 0 {
            var c = (*text)[before - 1]
            member = (c == ('.' as u8)) || (c == (':' as u8)) || ((c == ('>' as u8)) && (before > 1) && ((*text)[before - 2] == ('-' as u8)))
        }

        // What an accepted item replaces: the identifier under the cursor.
        var ew = JsonWriter()
        self.write_buf_range(&ew, i, start, at)

        if self.complete_import(i, ei, at, ew.out, id) {
            self.completed_(HOW_TEXT, WHAT_IMPORT, 0, t0)
            return
        }

        var marked = text->subslice(0, start)
        marked += completion_marker()
        marked += text->subslice(end, text->size() - end)

        var mpath = self.scratch(kairo_dot_ext())
        LinkFS::write(mpath, marked)

        // The live worker of the entry tries the marked buffer aside: one
        // file's re-check in a copy of it, where a process is a whole
        // compile of the graph. A process only when there is no worker to
        // ask (LiveIndex.k).
        if self.live_complete_(ei, id, path, member, ew.out, mpath, t0) {
            return
        }

        self.complete_by_run_(ei, id, path, member, ew.out, mpath, t0)
    }

    /// `$/kals/completed` (Protocol.k).
    fn completed_(self, const how: string, const what: string, count: usize, t0_us: i64) {
        var w = JsonWriter()
        w.begin_object()
        w.field(K_HOW, how)
        w.field(K_WHAT, what)
        w.field_uint(K_COUNT, count)
        w.field_int(K_US, now_us() - t0_us)
        w.end_object()
        self.notify(M_KALS_COMPLETED, w.out)
    }

    /// A completion as a process of its own: a compile of entry \p ei's
    /// graph with the marked buffer \p mpath in \p path's place.
    fn complete_by_run_(self,
                        ei:           usize,
                        const id:     string,
                        const path:   string,
                        member:       bool,
                        const edit:   string,
                        const mpath:  string,
                        t0_us:        i64) {
        var j = Job()
        j.kind   = JobKind::Complete
        j.entry_id = self.entries[ei].id
        j.out    = self.scratch(".json")
        j.log    = self.scratch(".log")
        j.rev    = self.rev
        j.id     = id
        j.path   = path
        j.member = member
        j.edit   = edit
        j.marked = mpath
        j.t0_us  = t0_us

        var argv = self.worker_argv(ei, j.out, path, j.marked)
        if self.launch_job(&argv, &j, "complete") != LaunchResult::Started {
            // Nothing is due after a completion: the request is answered.
            self.garbage.push_back(j.marked)
            self.respond(id, "[]")
            return
        }

        self.jobs.push_back(j)
    }

    /// One completion item. \p edit is the range it replaces: stated on every
    /// item, because an editor left to guess the range guesses by its own
    /// idea of a word, which is not Kairo's inside a string or after `::`
    /// (Zed drops such items as "out of expected range").
    fn item(self,
            w:            *JsonWriter,
            const label:  string,
            kind:         i64,
            const detail: string,
            const sort:   string,
            const edit:   string) {
        w->begin_object()
        w->field(K_LABEL, label)
        w->field_int(K_KIND, kind)
        if !detail.empty() {
            w->field(K_DETAIL, detail)
        }

        if !sort.empty() {
            w->field(K_SORT_TEXT, sort)
        }

        if !edit.empty() {
            w->key(K_TEXT_EDIT)
            write_lsp_text_edit_raw(w, edit, label)
        }

        w->end_object()
    }

    /// `import a::b::|` and `import a::b::{x, |`: answered from the
    /// filesystem, with no compile. A path names directories and `.k` files
    /// under the search roots, and after a file, what that file declares.
    /// True when the cursor was in an import (and the request is answered).
    fn complete_import(self, i: usize, ei: usize, at: usize, const edit: string, const id: string) -> bool {
        var *text = &self.docs.docs[i].text
        var ls = self.docs.docs[i].lines.starts[self.docs.docs[i].lines.line_of(at)]

        // An import may span lines inside its braces: start from the nearest
        // line above that begins the statement.
        var stmt = ls
        var guard: usize = 0
        while guard < 64 {
            var p = stmt
            while (p < at) && (((*text)[p] == (' ' as u8)) || ((*text)[p] == ('\t' as u8))) {
                p += 1
            }

            var line = text->subslice(p, at - p)
            if line.starts_with("import ") || line.starts_with("pub import ") || line.starts_with("priv import ")
                || line.starts_with("prot import ") {
                stmt = p
                break
            }

            if stmt == 0 {
                return false
            }

            // Only keep walking up while inside an open `{`.
            var prev = self.docs.docs[i].lines.line_of(stmt - 1)
            stmt = self.docs.docs[i].lines.starts[prev]
            guard += 1
        }

        if guard >= 64 {
            return false
        }

        var head = text->subslice(stmt, at - stmt)
        var k = find_from(head, "import ", 0)
        if k == usize::MAX {
            return false
        }

        var spec = head.subslice(k + 7, head.size() - k - 7)
        // A closed brace list, or a statement that already ended, is not an
        // import being typed.
        if (find_from(spec, "}", 0) != usize::MAX) || (find_from(spec, ";", 0) != usize::MAX) {
            return false
        }

        // On a later line only inside the brace list the import's own line
        // opens: a `{` further down is a body's, and every name typed in
        // the first function under the imports was taken for an import
        // path (and answered with nothing).
        if stmt != ls {
            var brace = find_from(spec, "{", 0)
            var nl    = find_from(spec, "\n", 0)
            if (brace == usize::MAX) || ((nl != usize::MAX) && (nl < brace)) {
                return false
            }
        }

        // Split at `::` into path segments; inside braces the last segment is
        // an item being typed, not part of the path.
        var segs: [string]
        var cur = string()
        var in_items = false
        var q: usize = 0
        while q < spec.size() {
            var c = spec[q]
            if in_items {
                q += 1
                continue
            }

            if (c == (':' as u8)) && ((q + 1) < spec.size()) && (spec[q + 1] == (':' as u8)) {
                segs.push_back(cur)
                cur = string()
                q += 2
                continue
            }

            if c == ('{' as u8) {
                in_items = true
            } else if is_ident_byte(c) {
                cur.push_back(c)
            }

            q += 1
        }

        // Where a path can start: the file's own directory, the entry's
        // directory and its -I roots, and the parent of every library root
        // the last run read (a directory holding a module.k is a module, so
        // its parent is where its name resolves from).
        var roots: [string]
        roots.push_back(Path::parent_of(self.docs.docs[i].path))
        if ei != usize::MAX {
            roots.push_back(self.entries[ei].dir)
            for var a: usize = 0; (a + 1) < self.entries[ei].args.size(); ++a {
                if self.entries[ei].args[a] == "-I" {
                    roots.push_back(Path::absolute_if_exists(self.entries[ei].args[a + 1], self.entries[ei].dir))
                }
            }

            for var f: usize = 0; f < self.entries[ei].files.size(); ++f {
                if Path::filename_of(self.entries[ei].files[f]) == module_file_name() {
                    var lib = Path::parent_of(self.entries[ei].files[f])
                    roots.push_back(Path::parent_of(lib))
                }
            }
        }

        var seen: [string]
        var w = JsonWriter()
        w.begin_object()
        w.field_bool(K_IS_INCOMPLETE, false)
        w.key(K_ITEMS)
        w.begin_array()

        var rel: string = ""
        for var g: usize = 0; g < segs.size(); ++g {
            rel = Path::join_str(rel, segs[g])
        }

        for var r: usize = 0; r < roots.size(); ++r {
            var dir = roots[r]
            if !rel.empty() {
                dir = Path::join_str(roots[r], rel)
            }

            // The path so far names a FILE: offer what it declares.
            var file = dir + kairo_dot_ext()
            if (!rel.empty()) && (!Path::exists_at(file)) {
                file = Path::join_str(dir, module_file_name())
            }

            if (!rel.empty()) && Path::exists_at(file) {
                var src: string = ""
                if LinkFS::read(file, &src) {
                    var names = top_level_names(src)
                    for var n: usize = 0; n < names.size(); ++n {
                        var dup = false
                        for var z: usize = 0; z < seen.size(); ++z {
                            if seen[z] == names[n] {
                                dup = true
                            }
                        }

                        if !dup {
                            seen.push_back(names[n])
                            self.item(&w, names[n], CIK_FUNCTION, Path::filename_of(file), "1" + names[n], edit)
                        }
                    }
                }
            }

            if in_items {
                continue
            }

            // And a DIRECTORY: its files and sub-directories are the next
            // segment.
            var names = LinkFS::list_dir(dir)
            for var n: usize = 0; n < names.size(); ++n {
                var name = names[n]
                var kind: i64 = CIK_FOLDER
                if name.ends_with(kairo_dot_ext()) {
                    name = name.subslice(0, name.size() - kairo_dot_ext().size())
                    kind = CIK_MODULE
                    if name == module_file_stem() {
                        continue
                    }
                } else if (!LinkFS::is_dir(Path::join_str(dir, name))) || name.starts_with(".") {
                    continue
                }

                // At the top level only library roots are offered from a
                // library's parent directory, not everything beside them.
                if rel.empty() && (r >= 2) {
                    // A library is a directory with a module.k: `std` sits
                    // beside `builtin` and is one whether or not this file
                    // has imported it yet.
                    var is_lib = (kind == CIK_FOLDER) && LinkFS::is_file(Path::join_str(Path::join_str(dir, name), module_file_name()))

                    var from_i = (ei != usize::MAX) && (r < (2 + (self.entries[ei].args.size() / 2)))
                    if (!is_lib) && (!from_i) {
                        continue
                    }
                }

                var dup = false
                for var z: usize = 0; z < seen.size(); ++z {
                    if seen[z] == name {
                        dup = true
                    }
                }

                if !dup {
                    seen.push_back(name)
                    self.item(&w, name, kind, "", "0" + name, edit)
                }
            }
        }

        w.end_array()
        w.end_object()
        self.respond(id, w.out)
        return true
    }

    fn finish_complete(self, j: *Job, rc: i32) {
        if j->cancelled {
            return
        }

        var text: string = ""
        var doc = JsonDoc()
        var w = JsonWriter()
        w.begin_object()
        w.field_bool(K_IS_INCOMPLETE, false)
        w.key(K_ITEMS)
        w.begin_array()

        var found = false
        var nitems: usize = 0
        if LinkFS::read(j->out, &text) && doc.parse(text) {
            var f = doc.first(doc.get(doc.root, SK_FILES))
            while f != JSON_NONE() {
                if doc.get_str(f, SK_PATH) == j->path {
                    var it = doc.first(doc.get(f, SK_ITEMS))
                    self.item_labels.clear()
                    self.item_docs.clear()
                    while it != JSON_NONE() {
                        var idoc = doc.get_str(it, SK_DOC)
                        if !idoc.empty() {
                            self.item_labels.push_back(doc.get_str(it, K_LABEL))
                            self.item_docs.push_back(idoc)
                        }

                        self.item(
                            &w,
                            doc.get_str(it, K_LABEL),
                            doc.get_int(it, K_KIND),
                            doc.get_str(it, K_DETAIL),
                            doc.get_str(it, K_SORT_TEXT),
                            j->edit,
                        )

                        found = true
                        nitems += 1
                        it = doc.next(it)
                    }
                }

                f = doc.next(f)
            }
        }

        // The entry it ran for, if it is still there: a reload or a retire
        // under the run leaves the request answered, without the outline.
        var cei = self.entry_by_id(j->entry_id)
        if (!found) && (!j->member) && (cei != usize::MAX) {
            // The marked buffer did not get as far as Sema (it does not
            // parse yet). The last good outline of the file is better than
            // nothing for a bare name.
            var fn_ = self.file_node(cei, j->path)
            if fn_ != JSON_NONE() {
                var *s = &self.entries[cei].idx
                var c = s->first(s->get(fn_, SK_SYMBOLS))
                while c != JSON_NONE() {
                    self.item(&w, s->get_str(c, K_NAME), CIK_VARIABLE, "", "", j->edit)
                    c = s->next(c)
                }
            }
        }

        if !j->member {
            // Every word of the language: this path does not know where the
            // name stands (the index path does, CompletionSite.k).
            if self.words.empty() {
                self.words = language_words()
            }

            for var k: usize = 0; k < self.words.size(); ++k {
                self.item(&w, self.words[k].text, CIK_KEYWORD, "", "9" + self.words[k].text, j->edit)
            }
        }

        w.end_array()
        w.end_object()
        self.respond(j->id, w.out)
        self.completed_(j->how, if (j->member) => (WHAT_MEMBER) else => WHAT_NAME, nitems, j->t0_us)
    }

    // --- the loop --------------------------------------------------------
}
