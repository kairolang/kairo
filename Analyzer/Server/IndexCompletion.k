/// --- The Kairo Project ------------ Analyzer/Server/IndexCompletion.k --- ///
///
///   Completion answered from what the server holds: the entry's
///   declaration tables, the file's scope rows, the buffer's text. No
///   compile and no worker.
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
import AST::Node::CanonicalNodes::BuiltinKind
import CompletionSite::*
import DocumentStore::{
    DocumentStore,
    fnv1a,
    path_to_uri,
    uri_to_path,
}
import Index::Legend::*
import Index::Primitives::{
    primitive_consts,
    primitive_of,
    primitive_spelling,
}
import Index::Snapshot::*
import Json::{
    JSON_NONE,
    JsonDoc,
    JsonWriter,
}
import JsonRpc::Transport
import Protocol::*
import Resolution::ModulePath::*
import Server::ClangdBridge::*
import Server::CodeActions::*
import Server::Completion::*
import Server::CompletionWords::*
import Server::DeclTables::*
import Server::Diagnostics::*
import Server::Features::*
import Server::Formatting::*
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
import Support::FileIO::Path::Path
import TextScan::classify
import Tuning::*
import Workspace::CompileCommandsLoader::{
    Project,
    project_file_name,
}
import std::io

// The order of a list is the walker's (Index/CompletionItems.k): locals,
// the enclosing type, the file, what it imports, the builtin library; then
// what only this path offers.
pub const SORT_LOCAL:   u32 = 0
pub const SORT_TYPE:    u32 = 1
pub const SORT_FILE:    u32 = 2
pub const SORT_IMPORT:  u32 = 3
pub const SORT_PRELUDE: u32 = 4
pub const SORT_MACRO:   u32 = 7
pub const SORT_BUILTIN: u32 = 8
pub const SORT_KEYWORD: u32 = 9

/// What a receiver is: a row that opens a scope (a type, a module block),
/// or a whole file taken as the module it is (`file`).
pub struct Recv {
    var ok:   bool  = false
    var t:    usize = usize::MAX
    var r:    i64   = -1
    var file: bool  = false
}

/// One candidate of a list.
pub struct Cand {
    var label:   string = ""
    var kind:    i64    = CIK_TEXT
    var detail:  string = ""
    var sort:    u32    = 0
    var insert:  string = ""       ///< what is inserted, when not the label
    var snippet: bool   = false    ///< `insert` is a snippet
    var doc:     string = ""       ///< documentation sent with the item (a builtin's one line)
    /// Where it is declared, for its `///` block on resolve and for the
    /// type of a receiver: a table row (`t` usize::MAX: none).
    var t: usize = usize::MAX
    var r: i64   = -1
    /// A local the text declares and the index has not seen: its type as
    /// written, or what initialises it.
    var type_: string = ""
    var init:  string = ""
    /// A local of the index: the record its type is.
    var ty:    Recv
    var local: bool = false
    /// A local: where the buffer declares it (what is in scope there is
    /// what its initialiser names).
    var at: usize = usize::MAX
}

/// \class CompReq
/// \brief one completion request being answered from the index.
pub class CompReq {
    pub var di:     usize     = 0          ///< the buffer
    pub var ei:     usize     = 0          ///< its entry
    pub var f:      u32       = 0          ///< the file's node in the entry's index
    pub var ti:     usize     = usize::MAX ///< the file's own table
    pub var path:   string    = ""
    pub var site:   Site
    pub var cls:    [u8]
    pub var blocks: [Block]
    pub var sh:     LineShift

    /// The files whose `extend` blocks this file sees (the block's `sees`).
    pub var sees: [string]
    /// The types the cursor is inside, innermost last: an access is judged
    /// from them (AccessCheck's "use classes").
    pub var users: [Recv]

    /// How many initialisers deep a receiver's type is being read off the
    /// text (`var a = b.c()` with `var b = d()`): bounded.
    pub var depth: u32 = 0

    /// The lookups type a receiver the text already names (`a.b_.`), not
    /// a list to offer: a member that would not be OFFERED here (a name
    /// with a leading or trailing underscore from another file, one the
    /// cursor may not name) is still the step the text wrote, and the
    /// compiler's walk types through it.
    pub var typing: bool = false

    pub var out:   [Cand]
    var     seen_: {u64: u32}

    pub fn CompReq(self) = default

    /// Adds \p c unless a candidate has its label already: overloads share
    /// one item, and the first found is the nearest.
    pub fn add(self, const c: Cand) -> bool {
        if c.label.empty() {
            return false
        }

        var h   = fnv1a(c.label)
        var hit = self.seen_.get(h)
        if hit != null {
            if self.out[(*hit) as usize].label == c.label {
                return false
            }

            for var i: usize = 0; i < self.out.size(); ++i {
                if self.out[i].label == c.label {
                    return false
                }
            }
        } else {
            self.seen_[h] = self.out.size() as u32
        }

        self.out.push_back(c)
        return true
    }

    pub fn find(self, const label: string) -> i64 {
        var hit = self.seen_.get(fnv1a(label))
        if hit == null {
            return -1
        }

        if self.out[(*hit) as usize].label == label {
            return (*hit) as i64
        }

        for var i: usize = 0; i < self.out.size(); ++i {
            if self.out[i].label == label {
                return i as i64
            }
        }

        return -1
    }

    pub fn reset(self) {
        self.out.clear()
        self.seen_.clear()
    }
}

/// A number literal's type with no type expected (primitives.mdx,
/// "Literal inference"): its suffix's (`42u8`, `1.5f32`), else `f64` for a
/// float and `i32` for an integer that fits it; "" for an integer past
/// `i32` (the smallest signed type holding it: not worth guessing here)
/// and anything that is not one number.
fn number_type_(const x: string) -> string {
    var hex = (x.size() > 2)
        && (x[0] == ('0' as u8))
        && ((x[1] == ('x' as u8)) || (x[1] == ('X' as u8)))
    var bin = (x.size() > 2)
        && (x[0] == ('0' as u8))
        && ((x[1] == ('b' as u8)) || (x[1] == ('B' as u8)))
    var p:       usize = if (hex || bin) => (2 as usize) else => (0 as usize)
    var is_float       = false
    var value:   u64   = 0
    var big            = false
    var base: u64 = if (hex) => (16 as u64) else => (if (bin) => (2 as u64) else => (10 as u64))
    while p < x.size() {
        var c      = x[p]
        var d: u64 = 99
        if (c >= ('0' as u8)) && (c <= ('9' as u8)) {
            d = (c - ('0' as u8)) as u64
        } else if hex && (c >= ('a' as u8)) && (c <= ('f' as u8)) {
            d = ((c - ('a' as u8)) as u64) + 10
        } else if hex && (c >= ('A' as u8)) && (c <= ('F' as u8)) {
            d = ((c - ('A' as u8)) as u64) + 10
        } else if c == ('_' as u8) {
            p += 1
            continue
        } else if (c == ('.' as u8))
            && (!hex)
            && (!bin)
            && ((p + 1) < x.size())
            && (x[p + 1] >= ('0' as u8))
            && (x[p + 1] <= ('9' as u8)) {
            is_float = true
            p += 1
            continue
        } else if ((c == ('e' as u8)) || (c == ('E' as u8))) && (!hex) && (!bin) {
            is_float = true
            p += 1
            if (p < x.size()) && ((x[p] == ('+' as u8)) || (x[p] == ('-' as u8))) {
                p += 1
            }

            continue
        } else {
            break
        }

        if d >= base {
            break
        }

        if !is_float {
            if value > 0x7FFFFFFF {
                big = true
            } else {
                value = value * base + d
            }
        }

        p += 1
    }

    if p < x.size() {
        // A suffix: a primitive's name, and nothing after it.
        var sfx       = x.subslice(p, x.size() - p)
        var q:  usize = 1
        var known = (sfx[0] == ('i' as u8)) || (sfx[0] == ('u' as u8)) || (sfx[0] == ('f' as u8))
        while known && (q < sfx.size()) {
            known = (sfx[q] >= ('0' as u8)) && (sfx[q] <= ('9' as u8))
            q += 1
        }

        if (!known) || (sfx.size() < 2) || (primitive_of(sfx) == BuiltinKind::COUNT) {
            return ""
        }

        return sfx
    }

    if is_float {
        return "f64"
    }

    if big || (value > 0x7FFFFFFF) {
        return ""
    }

    return "i32"
}

/// One past the quoted literal that opens at byte \p q of \p x (its quote
/// is `x[q]`): escapes skipped, and an f-string's `{...}` too, which may
/// hold quotes of its own. x.size() + 1 when it does not close.
fn literal_end_(const x: string, q: usize) -> usize {
    var quote      = x[q]
    var depth: i64 = 0
    var k          = q + 1
    while k < x.size() {
        var c = x[k]
        if c == ('\\' as u8) {
            k += 2
            continue
        }

        if (quote == ('"' as u8)) && (q > 0) && (c == ('{' as u8)) {
            depth += 1
        } else if (depth > 0) && (c == ('}' as u8)) {
            depth -= 1
        } else if (depth == 0) && (c == quote) {
            return k + 1
        }

        k += 1
    }

    return x.size() + 1
}

fn is_type_word(const w: string) -> bool {
    return (w == "class")
        || (w == "struct")
        || (w == "enum")
        || (w == "union")
        || (w == "interface")
}

fn is_type_kind(k: i64) -> bool {
    return (k == CIK_CLASS)
        || (k == CIK_STRUCT)
        || (k == CIK_ENUM)
        || (k == CIK_INTERFACE)
        || (k == CIK_MODULE)
        || (k == CIK_TYPE_PARAMETER)
        || (k == CIK_TEXT)
}

/// The first line of the code block of hover text \p md: a declaration as
/// hover prints it.
fn hover_head(const md: string) -> string {
    var p: usize = 0
    if md.starts_with("```") {
        while (p < md.size()) && (md[p] != ('\n' as u8)) {
            p += 1
        }

        p += 1
    }

    var e = p
    while (e < md.size()) && (md[e] != ('\n' as u8)) {
        e += 1
    }

    if p >= md.size() {
        return ""
    }

    return md.subslice(p, e - p)
}

extend Server {
    // --- the request ------------------------------------------------------

    /// \brief answers completion request \p id on buffer \p di from the
    ///        index. False when it cannot: the caller asks the compiler
    ///        (the live worker's copy, or a run).
    ///
    /// \details It cannot when the entry has no tables yet (its first check
    ///          has not landed), when the file has no rows, and for a member
    ///          whose receiver the tables do not type: an index, a literal,
    ///          a C or C++ value, a call of a generic function.
    fn index_complete_(self,
                       di:       usize,
                       d:        *const JsonDoc,
                       params:   u32,
                       const id: string,
                       t0:       i64) -> bool {
        if !self.index_completion {
            return false
        }

        var req = CompReq()
        req.di   = di
        req.path = self.docs.docs[di].path
        var pos   = d->get(params, K_POSITION)
        var *text = &self.docs.docs[di].text
        var at = self.docs.docs[di].lines.offset(
            *text,
            d->get_int(pos, K_LINE) as usize,
            d->get_int(pos, K_CHARACTER) as usize,
            false,
        )

        req.cls  = classify(*text)
        req.site = site_at(*text, req.cls, at)
        var ew = JsonWriter()
        self.write_buf_range(&ew, di, req.site.start, at)

        // Sent because a trigger character was typed: answered only where
        // that character means what it is a trigger for. `/` is also a
        // division and `"` any string's quote, `>` a comparison and `:` a
        // type's colon: a list after each of those would be noise.
        var tc = d->get_str(d->get(params, K_CONTEXT), K_TRIGGER_CHARACTER)
        if !tc.empty() {
            var meant = true
            if (tc == "/") || (tc == "\"") {
                meant = req.site.what == SITE_HEADER
            } else if tc == "@" {
                meant = req.site.what == SITE_ATTR
            } else if (tc == ".") || (tc == ":") || (tc == ">") {
                meant = req.site.what == SITE_MEMBER
            }

            if !meant {
                req.site.what = SITE_NONE
            }
        }

        if req.site.what == SITE_NONE {
            self.respond(id, "{\"isIncomplete\":false,\"items\":[]}")
            self.completed_(HOW_INDEX, WHAT_NONE, 0, t0)
            return true
        }

        if req.site.what == SITE_HEADER {
            self.header_candidates_(&req, at)
            self.respond_candidates_(&req, id, ew.out, false)
            self.completed_(HOW_INDEX, WHAT_HEADER, req.out.size(), t0)
            return true
        }

        if req.site.what == SITE_ATTR {
            self.attribute_candidates_(&req)
            self.respond_candidates_(&req, id, ew.out, false)
            self.completed_(HOW_INDEX, WHAT_ATTRIBUTE, req.out.size(), t0)
            return true
        }

        // A Kairo import's path and names: from the filesystem.
        var ei0 = self.entry_of(req.path)
        if self.complete_import(di, ei0, at, ew.out, id) {
            self.completed_(HOW_TEXT, WHAT_IMPORT, 0, t0)
            return true
        }

        // The rest reads the index: the tables, and this file's rows.
        if ei0 == usize::MAX {
            return false
        }

        req.ei = ei0
        var *e = &self.entries[ei0]
        if (!e->has_idx) || e->tb.t.empty() {
            return false
        }

        req.f = self.file_node(ei0, req.path)
        if req.f == JSON_NONE() {
            return false
        }

        req.ti     = e->tb.find(req.path)
        req.sh     = self.line_shift(ei0, di)
        req.blocks = blocks_before(*text, req.cls, req.site.start)
        var s = e->idx.first(e->idx.get(req.f, SK_SEES))
        while s != JSON_NONE() {
            req.sees.push_back(e->idx.str(s))
            s = e->idx.next(s)
        }

        self.use_classes_(&req)
        if req.site.what == SITE_MEMBER {
            if !self.member_candidates_(&req) {
                return false
            }

            self.respond_candidates_(&req, id, ew.out, true)
            self.completed_(HOW_INDEX, WHAT_MEMBER, req.out.size(), t0)
            return true
        }

        self.name_candidates_(&req)
        self.respond_candidates_(&req, id, ew.out, true)
        self.completed_(HOW_INDEX, WHAT_NAME, req.out.size(), t0)
        return true
    }

    /// Sends \p req's candidates as the answer to \p id. \p edit is the
    /// range each replaces: stated once for the list where the client
    /// reads it there (`itemDefaults.editRange`), else on every item. An
    /// item of a declared name carries where (`data`), for its `///` block
    /// on resolve.
    fn respond_candidates_(self,
                           req:        *CompReq,
                           const id:   string,
                           const edit: string,
                           with_data:  bool) {
        self.item_labels.clear()
        self.item_docs.clear()
        self.comp_paths.clear()
        var w = JsonWriter()
        w.begin_object()
        // The whole set for this position: the client filters it as the
        // word grows or shrinks, and need not ask again.
        w.field_bool(K_IS_INCOMPLETE, false)
        if self.edit_default_ok {
            w.key(K_ITEM_DEFAULTS)
            w.begin_object()
            w.field_raw(K_EDIT_RANGE, edit)
            w.end_object()
        }

        // A macro's name typed before an invocation that is already there
        // (`tw|!(a)`, the `!` after the name): a macro item replaces the
        // name AND that `!`, with its name and `!` alone, or the edit
        // leaves `twice!!(a)`. Its own range, on the item.
        var *txt              = &self.docs.docs[req->di].text
        var bang_edit: string = ""
        if (req->site.what == SITE_NAME)
            && (req->site.end < txt->size())
            && ((*txt)[req->site.end] == ('!' as u8))
            && (!(((req->site.end + 1) < txt->size())
                && ((*txt)[req->site.end + 1] == ('=' as u8)))) { // not `a!=b`
            var bw = JsonWriter()
            self.write_buf_range(
                &bw,
                req->di,
                req->site.start,
                req->site.end + 1,
            )

            bang_edit = bw.out
        }

        w.key(K_ITEMS)
        w.begin_array()
        for var i: usize = 0; i < req->out.size(); ++i {
            var *c = &req->out[i]
            w.begin_object()
            w.field(K_LABEL, c->label)
            w.field_int(K_KIND, c->kind)
            if !c->detail.empty() {
                w.field(K_DETAIL, c->detail)
            }

            // sortText orders groups; within one the editor sorts by label.
            w.field(K_SORT_TEXT, f"{c->sort}{c->label}")
            var text: string = c->label
            var snip         = c->snippet && self.snippet_ok
            var over_bang = (!bang_edit.empty()) && c->label.ends_with("!")
            if over_bang {
                snip = false
            } else if (!c->insert.empty()) && (snip || (!c->snippet)) {
                text = c->insert
            }

            if snip {
                w.field_int(K_INSERT_TEXT_FORMAT, ITF_SNIPPET)
            }

            if over_bang {
                w.key(K_TEXT_EDIT)
                write_lsp_text_edit_raw(&w, bang_edit, text)
            } else if !self.edit_default_ok {
                w.key(K_TEXT_EDIT)
                write_lsp_text_edit_raw(&w, edit, text)
            } else if text != c->label {
                w.field(K_TEXT_EDIT_TEXT, text)
            }

            if !c->doc.empty() {
                w.key(K_DOCUMENTATION)
                w.begin_object()
                w.field(K_KIND, MARKUP_MARKDOWN)
                w.field(K_VALUE, c->doc)
                w.end_object()
            } else if with_data && (c->t != usize::MAX) && (c->r >= 0) {
                var *tb = &self.entries[req->ei].tb.t[c->t]
                if tb->off[c->r as usize] >= 0 {
                    var pi = usize::MAX
                    for var k: usize = 0; k < self.comp_paths.size(); ++k {
                        if self.comp_paths[k] == tb->path {
                            pi = k
                        }
                    }

                    if pi == usize::MAX {
                        self.comp_paths.push_back(tb->path)
                        pi = self.comp_paths.size() - 1
                    }

                    w.key(K_DATA)
                    w.begin_array()
                    w.uint(pi)
                    w.integer(tb->line[c->r as usize])
                    w.end_array()
                }
            }

            w.end_object()
        }

        w.end_array()
        w.end_object()
        self.respond(id, w.out)
    }

    /// `completionItem/resolve` of an item this path sent: its `///` block,
    /// read from the declaring file's text (the buffer's, when it is open).
    /// "" when the item names no declaration or has no block.
    fn resolve_doc_(self, d: *const JsonDoc, params: u32) -> string {
        var data = d->get(params, K_DATA)
        var a    = d->first(data)
        if a == JSON_NONE() {
            return ""
        }

        var pi   = d->as_int(a) as usize
        var line = d->as_int(d->next(a))
        if (pi >= self.comp_paths.size()) || (line < 0) {
            return ""
        }

        var text: string = ""
        var bi           = self.docs.index_of_path(self.comp_paths[pi])
        if bi != usize::MAX {
            self.docs.docs[bi].sync()
            // The table's line is the indexed text's.
            if !self.docs.docs[bi].idx_text.empty() {
                text = self.docs.docs[bi].idx_text
            } else {
                text = self.docs.docs[bi].text
            }
        } else if !LinkFS::read(self.comp_paths[pi], &text) {
            return ""
        }

        return doc_above(text, line as usize)
    }

    // --- rows -------------------------------------------------------------

    /// Row \p r of table \p ti as a candidate.
    fn row_cand_(self, req: *CompReq, ti: usize, r: i64, sort: u32) -> Cand {
        var *tb = &self.entries[req->ei].tb
        var c   = Cand{}
        c.label  = tb->t[ti].name[r as usize]
        c.kind   = tb->t[ti].kind[r as usize]
        c.detail = tb->t[ti].detail[r as usize]
        c.sort   = sort
        c.t      = ti
        c.r      = r
        if (tb->t[ti].flags[r as usize] & DF_ALIAS) != 0 {
            // Another file, as a module: the candidate is that file.
            var tf = tb->t[ti].tfile[r as usize]
            if (tb->t[ti].toff[r as usize] < 0)
                && (tf >= 0)
                && ((tf as usize) < tb->t[ti].files.size()) {
                var mt = tb->find(tb->t[ti].files[tf as usize])
                if mt != usize::MAX {
                    c.t = mt
                    c.r = -1
                }

                return c
            }

            // Declared in another file: its row there says what it is.
            var to = tb->follow(
                ti,
                tb->t[ti].tfile[r as usize],
                tb->t[ti].toff[r as usize],
            )

            if to.t != usize::MAX {
                c.detail = tb->t[to.t].detail[to.r as usize]
                c.t      = to.t
                c.r      = to.r
            }
        }

        return c
    }

    /// What a use of candidate \p c is, as a receiver: the scope it opens
    /// (a type, a module), or the record its type is. Not ok when the
    /// tables do not say (a C or C++ type, a generic's parameter).
    ///
    /// \param called the name is followed by its arguments. A function's
    ///               name is its result only when it is called, and only
    ///               when every function of that name there returns the
    ///               same record: which overload a call picks is the
    ///               compiler's to say.
    fn cand_recv_(self, req: *CompReq, const c: Cand, called: bool) -> Recv {
        var out = Recv{}
        if c.local {
            if called {
                return out // a closure's result
            }

            if c.ty.ok {
                return c.ty
            }

            // A local the text declares: `var x: T`, `var x = T(...)`.
            if !c.type_.empty() {
                return self.type_name_recv_(req, type_head(c.type_))
            }

            var init       = c.init
            var p:   usize = 0
            while (p < init.size()) && ((init[p] == (' ' as u8)) || (init[p] == ('\t' as u8))) {
                p += 1
            }

            var e = p
            while (e < init.size()) && (is_ident_byte(init[e]) || (init[e] == (':' as u8))) {
                e += 1
            }

            // Only a construction: `T(`, `T<..>(`, `T {`. A call's result is
            // the function's to say.
            var after = e
            while (after < init.size()) && (init[after] == (' ' as u8)) {
                after += 1
            }

            if (e > p)
                && (after < init.size())
                && ((init[after] == ('(' as u8))
                    || (init[after] == ('<' as u8))
                    || (init[after] == ('{' as u8))) {
                var head = self.type_name_recv_(req, init.subslice(p, e - p))
                if head.ok && (!head.file) {
                    var k = self.entries[req->ei].tb.t[head.t].kind[head.r as usize]
                    if (k == CIK_CLASS) || (k == CIK_STRUCT) {
                        return head
                    }
                }
            }

            // A chain of names and calls (`make()`, `self.docs.first()`,
            // `&other.field`): what the chain's last step is, read as a
            // receiver is read. The index has no type for an inferred
            // local of a file that was checked with an error in it (a name
            // still being typed is one), and none for a local typed since.
            if (req->depth >= 4) || (c.at == usize::MAX) {
                return out
            }

            var b = p
            while b < init.size() {
                var ch = init[b]
                if (ch == (' ' as u8)) || (ch == ('&' as u8)) || (ch == ('*' as u8)) {
                    b += 1
                    continue
                }

                if init.subslice(b, 7) == "unsafe " {
                    b += 7
                    continue
                }

                break
            }

            var end = init.size()
            while (end > b)
                && ((init[end - 1] == (' ' as u8))
                    || (init[end - 1] == ('\t' as u8))
                    || (init[end - 1] == ('\r' as u8))) {
                end -= 1
            }

            if end <= b {
                return out
            }

            var expr  = init.subslice(b, end - b)
            var steps = receiver_steps(expr, classify(expr), expr.size())
            // The whole initialiser, not the tail of a larger expression.
            if steps.empty() || (steps[0].off != 0) {
                return out
            }

            // In scope where the declaration stands.
            steps[0].off = c.at
            var sub = CompReq()
            sub.di     = req->di
            sub.ei     = req->ei
            sub.f      = req->f
            sub.ti     = req->ti
            sub.cls    = req->cls
            sub.blocks = req->blocks
            sub.sh     = req->sh
            sub.sees   = req->sees
            sub.users  = req->users
            sub.site   = req->site
            sub.depth  = req->depth + 1
            sub.typing = true
            return self.chain_recv_(&sub, &steps)
        }

        if c.t == usize::MAX {
            return out
        }

        var *tb = &self.entries[req->ei].tb
        if c.r < 0 {
            out.ok   = true
            out.t    = c.t
            out.file = true
            return out
        }

        var fl = tb->t[c.t].flags[c.r as usize]
        if (fl & DF_SCOPE) != 0 {
            out.ok = true
            out.t  = c.t
            out.r  = c.r
            return out
        }

        var *t = &tb->t[c.t]
        var kd = t->kind[c.r as usize]
        if (kd == CIK_FUNCTION) || (kd == CIK_METHOD) {
            if !called {
                return out // the function itself, not what it returns
            }

            // Its overloads (the rows of its name beside it) must agree.
            for var r: usize = 0; r < t->rows(); ++r {
                if (t->parent[r] == t->parent[c.r as usize])
                    && (t->name[r] == t->name[c.r as usize])
                    && ((t->kind[r] == CIK_FUNCTION) || (t->kind[r] == CIK_METHOD))
                    && ((t->tfile[r] != t->tfile[c.r as usize])
                        || (t->toff[r] != t->toff[c.r as usize])) {
                    return out
                }
            }
        } else if called {
            return out // a value that is called: its result is not in the tables
        }

        var to = tb->follow(
            c.t,
            tb->t[c.t].tfile[c.r as usize],
            tb->t[c.t].toff[c.r as usize],
        )

        if to.t == usize::MAX {
            return out
        }

        out.ok = true
        out.t  = to.t
        out.r  = to.r
        return out
    }

    /// What \p n subscripts of candidate \p c (called first when \p called)
    /// are, as a receiver (`boxes[0].`, `self.rows[i].`, `make()[k].`):
    /// cand_recv_ when there is none. A declaration of a table says it
    /// itself (`DC_EFILE`, from the compiler's type: one subscript of a
    /// `[T]`, `[T; N]`, `[T;]`, `{K: V}`); a local, whose rows carry its type
    /// but not its element's, by its type as written or as hover prints it,
    /// read in this file, where the local is declared. Not ok for anything
    /// else (a type's own `op []`, a pointer): the compiler is asked.
    fn subscript_recv_(self, req: *CompReq, const c: Cand, called: bool, n: usize) -> Recv {
        var out = Recv{}
        if n == 0 {
            return self.cand_recv_(req, c, called)
        }

        var cur          = Recv{}
        var text: string = ""     // while known: the type, as text
        var k:    usize  = 0
        if c.local {
            if called {
                return out
            }

            text = c.type_
            if text.empty() {
                text = decl_type_text(c.detail, c.label, false)
            }

            // Element types as text while they are collections; at a named
            // type, its record (the index's type of the local when it has
            // one) and from there its `op []`.
            while (k < n) && (!text.empty()) {
                var e = elem_type_text(text)
                if e.empty() {
                    cur = if (c.ty.ok && (k == 0)) => (c.ty)
                          else => (self.type_name_recv_(req, type_head(text)))
                    text = ""
                    break
                }

                text = e
                k += 1
            }

            // No type as text (an inferred local): the record cand_recv_
            // reads (the index's type, or the initialiser), and its `op []`.
            if (k == 0) && text.empty() && (!cur.ok) {
                cur = self.cand_recv_(req, c, false)
            }

            if k == n {
                if text.empty() {
                    return out
                }

                return self.type_name_recv_(req, type_head(text))
            }

            if !cur.ok {
                return out
            }

            cur = self.op_index_recv_(req, cur)
            k += 1
        } else {
            if (c.t == usize::MAX) || (c.r < 0) {
                return out
            }

            // The value (or, called, the result) must be what cand_recv_
            // would take: the same checks of a function's overloads and of
            // a called value, on the element's record.
            var *tb = &self.entries[req->ei].tb
            var *t  = &tb->t[c.t]
            var kd  = t->kind[c.r as usize]
            if (kd == CIK_FUNCTION) || (kd == CIK_METHOD) {
                if !called {
                    return out
                }

                for var r: usize = 0; r < t->rows(); ++r {
                    if (t->parent[r] == t->parent[c.r as usize])
                        && (t->name[r] == t->name[c.r as usize])
                        && ((t->kind[r] == CIK_FUNCTION) || (t->kind[r] == CIK_METHOD))
                        && ((t->efile[r] != t->efile[c.r as usize])
                            || (t->eoff[r] != t->eoff[c.r as usize])
                            || (t->tfile[r] != t->tfile[c.r as usize])
                            || (t->toff[r] != t->toff[c.r as usize])) {
                        return out
                    }
                }
            } else if called || ((t->flags[c.r as usize] & DF_SCOPE) != 0) {
                return out
            }

            // A collection's element (the value's own row); else the
            // `op []` of the record its type is.
            if t->efile[c.r as usize] >= 0 {
                var to = tb->follow(
                    c.t,
                    t->efile[c.r as usize],
                    t->eoff[c.r as usize],
                )

                if to.t != usize::MAX {
                    cur.ok = true
                    cur.t  = to.t
                    cur.r  = to.r
                }
            } else {
                cur = self.op_index_recv_(req, self.cand_recv_(req, c, called))
            }

            k = 1
        }

        while (k < n) && cur.ok {
            cur = self.op_index_recv_(req, cur)
            k += 1
        }

        return cur
    }

    /// What a subscript of a value of record \p rec is: the result its
    /// `op []` overloads agree on, which its own row carries (`DC_EFILE`
    /// of a type's row, Tables.k). Not ok when it declares none, they
    /// differ, or the result is no record of the tables.
    fn op_index_recv_(self, req: *CompReq, rec: Recv) -> Recv {
        var out = Recv{}
        if (!rec.ok) || rec.file || (rec.r < 0) {
            return out
        }

        var *tb = &self.entries[req->ei].tb
        var *t  = &tb->t[rec.t]
        if t->efile[rec.r as usize] < 0 {
            return out
        }

        var to = tb->follow(
            rec.t,
            t->efile[rec.r as usize],
            t->eoff[rec.r as usize],
        )

        if to.t == usize::MAX {
            return out
        }

        out.ok = true
        out.t  = to.t
        out.r  = to.r
        return out
    }

    /// The module directory of the file that asks.
    fn use_mod_(self, req: *CompReq) -> string {
        if req->ti == usize::MAX {
            return ""
        }

        return self.entries[req->ei].tb.t[req->ti].mod
    }

    /// Whether the file that asks is in the module of table \p ti's file
    /// (VisibilityFacts.k, same_module: one module directory, not none).
    fn same_module_(self, req: *CompReq, ti: usize) -> bool {
        var m = self.entries[req->ei].tb.t[ti].mod
        return (!m.empty()) && (m == self.use_mod_(req))
    }

    /// \brief whether the cursor may name member row \p r of table \p ti.
    ///
    /// \details AccessCheck's rule (Sema/Resolve/AccessCheck.k), read off
    ///          the rows: `pub` everywhere; `priv` in the member's file and
    ///          in its own class; `prot` also in the files of its module
    ///          and in a class deriving from the member's, which reaches an
    ///          instance member only through an object of its own kind
    ///          (\p through). A member of an `extend` block answers from
    ///          the block's file and the type it extends. \p owner is that
    ///          type's row.
    fn may_name_(self, req: *CompReq, ti: usize, r: i64, owner: Recv, through: Recv) -> bool {
        var *tb = &self.entries[req->ei].tb
        var v   = tb->t[ti].vis[r as usize]
        if (v != VIS_PRIV) && (v != VIS_PROT) {
            return true
        }

        if ti == req->ti {
            return true // the member's own file
        }

        if owner.file || (!owner.ok) {
            // Reached through a module: `priv` is its file's, `prot` its module's.
            return (v == VIS_PROT) && self.same_module_(req, ti)
        }

        for var i: usize = 0; i < req->users.size(); ++i {
            if (req->users[i].t == owner.t) && (req->users[i].r == owner.r) {
                return true
            }
        }

        if v != VIS_PROT {
            return false
        }

        if self.same_module_(req, ti) {
            return true
        }

        var fl       = tb->t[ti].flags[r as usize]
        var instance = ((fl & DF_METHOD) != 0) || ((fl & DF_STATIC) == 0)
        var orow     = RowRef{}
        orow.t = owner.t
        orow.r = owner.r
        for var i: usize = 0; i < req->users.size(); ++i {
            var u = RowRef{}
            u.t = req->users[i].t
            u.r = req->users[i].r
            if !tb->derives_from(u, orow, 0) {
                continue
            }

            if (!instance) || (!through.ok) || through.file {
                return true
            }

            var from = RowRef{}
            from.t = through.t
            from.r = through.r
            if ((from.t == u.t) && (from.r == u.r)) || tb->derives_from(from, u, 0) {
                return true
            }
        }

        return false
    }

    /// Whether a member reached through a `derives` edge of visibility
    /// \p ev written by class \p holder may be named: a `priv` edge is the
    /// holder's file and class, a `prot` one also its module and the
    /// classes deriving from it (AccessCheck::_check_edges).
    fn edge_ok_(self, req: *CompReq, holder: Recv, ev: i64) -> bool {
        if (ev != VIS_PRIV) && (ev != VIS_PROT) {
            return true
        }

        if (holder.t == req->ti) || ((ev == VIS_PROT) && self.same_module_(req, holder.t)) {
            return true
        }

        var *tb = &self.entries[req->ei].tb
        var h   = RowRef{}
        h.t = holder.t
        h.r = holder.r
        for var i: usize = 0; i < req->users.size(); ++i {
            if (req->users[i].t == holder.t) && (req->users[i].r == holder.r) {
                return true
            }

            var u = RowRef{}
            u.t = req->users[i].t
            u.r = req->users[i].r
            if (ev == VIS_PROT) && tb->derives_from(u, h, 0) {
                return true
            }
        }

        return false
    }

    /// Whether this file sees the `extend` blocks of table \p et's file,
    /// for a record of table \p target: its own, the builtin library's,
    /// those it imports (the block's `sees`), and one written beside the
    /// type it extends (MemberLookup.k, extension_visible).
    fn sees_ext_(self, req: *CompReq, et: usize, target: usize) -> bool {
        var *tb = &self.entries[req->ei].tb
        if (et == req->ti) || (et == target) || tb->t[et].builtin {
            return true
        }

        for var i: usize = 0; i < req->sees.size(); ++i {
            if req->sees[i] == tb->t[et].path {
                return true
            }
        }

        return false
    }

    /// \brief adds what receiver \p recv declares to \p req: its own
    ///        members, the members of the `extend` blocks this file sees,
    ///        then its bases', each when the cursor may name it.
    ///
    /// \param through the receiver the list was asked of (\p recv itself at
    ///                depth 0); \p edge_ok false: a `derives` edge on the
    ///                way hides everything behind it from here.
    fn members_into_(self, req: *CompReq, recv: Recv, through: Recv, depth: u32, sort: u32) {
        if (!recv.ok) || (depth > 8) {
            return
        }

        var *tb = &self.entries[req->ei].tb
        if recv.t >= tb->t.size() {
            return
        }

        var *t = &tb->t[recv.t]
        var n  = t->rows()
        // The children of the receiver's row; a file's top level for a
        // file. Table order is the walker's order of the same members.
        var parent: i64   = if (recv.file) => (-1 as i64) else => recv.r
        var first:  usize = if (recv.file) => (0 as usize) else => ((recv.r + 1) as usize)
        for var r: usize = first; r < n; ++r {
            if t->parent[r] != parent {
                // A child row is after its parent and before the parent's
                // next sibling: rows nested deeper are skipped, a row that
                // is no descendant ends the receiver's.
                if (!recv.file) && (t->parent[r] < recv.r) {
                    break
                }

                continue
            }

            self.member_row_(req, recv.t, r as i64, recv, through, sort)
        }

        if recv.file {
            return
        }

        // The extensions of the type, where this file sees them.
        var *exts = tb->extensions()
        for var x: usize = 0; x < exts->size(); ++x {
            var et = ((*exts)[x] >> 32) as usize
            var er = ((*exts)[x] & 0xFFFFFFFF) as i64
            var to = tb->follow(
                et,
                tb->t[et].tfile[er as usize],
                tb->t[et].toff[er as usize],
            )

            if (to.t != recv.t) || (to.r != recv.r) || (!self.sees_ext_(req, et, recv.t)) {
                continue
            }

            var *xt = &tb->t[et]
            for var r: usize = (er + 1) as usize; r < xt->rows(); ++r {
                if xt->parent[r] != er {
                    if xt->parent[r] < er {
                        break
                    }

                    continue
                }

                self.member_row_(req, et, r as i64, recv, through, sort)
            }
        }

        // Its bases, each a step further away.
        var b: usize = 0
        while (b + 3) < t->bases.size() {
            if t->bases[b] == recv.r {
                var to = tb->follow(recv.t, t->bases[b + 1], t->bases[b + 2])
                if (to.t != usize::MAX) && self.edge_ok_(req, recv, t->bases[b + 3]) {
                    var base = Recv{}
                    base.ok = true
                    base.t  = to.t
                    base.r  = to.r
                    self.members_into_(req, base, through, depth + 1, sort + 1)
                }
            }

            b += 4
        }
    }

    /// One member row, when it is a name to offer and the cursor may name it.
    fn member_row_(self, req: *CompReq, ti: usize, r: i64, owner: Recv, through: Recv, sort: u32) {
        var *t = &self.entries[req->ei].tb.t[ti]
        var fl = t->flags[r as usize]
        if ((fl & DF_EXT) != 0) || ((fl & DF_MACRO) != 0) {
            return
        }

        var name: string = t->name[r as usize]
        // A leading underscore is reserved for interop and a trailing one
        // marks a file's private helper: neither is offered from another
        // file (CompletionItems.k, item_).
        if (!req->typing)
            && (name.starts_with("_") || name.ends_with("_"))
            && (ti != req->ti)
            && ((fl & DF_ALIAS) == 0) {
            return
        }

        if (!req->typing)
            && ((fl & DF_ALIAS) == 0)
            && (!self.may_name_(req, ti, r, owner, through)) {
            return
        }

        req->add(self.row_cand_(req, ti, r, sort))
    }

    // --- where the cursor is ----------------------------------------------

    /// The row of the type that block \p bi of \p req declares, through the
    /// types it is nested in; of the type an `extend` block extends.
    fn block_type_(self, req: *CompReq, bi: usize) -> Recv {
        var out = Recv{}
        var *b  = &req->blocks[bi]
        if b->word == "extend" {
            // The target as written, read off the header.
            var *text = &self.docs.docs[req->di].text
            var p     = b->hstart
            while (p < b->open) && (text->subslice(p, 6) != "extend") {
                p += 1
            }

            p += 6
            while (p < b->open) && (((*text)[p] == (' ' as u8)) || ((*text)[p] == ('\t' as u8))) {
                p += 1
            }

            if (p < b->open) && ((*text)[p] == ('<' as u8)) {
                while (p < b->open) && ((*text)[p] != ('>' as u8)) {
                    p += 1
                }

                p += 1
                while (p < b->open) && ((*text)[p] == (' ' as u8)) {
                    p += 1
                }
            }

            var e = p
            while (e < b->open) && (is_ident_byte((*text)[e]) || ((*text)[e] == (':' as u8))) {
                e += 1
            }

            return self.type_name_recv_(req, text->subslice(p, e - p))
        }

        if (!is_type_word(b->word)) || (req->ti == usize::MAX) {
            return out
        }

        // The enclosing type blocks, outermost first, name the path.
        var parent: i64 = -1
        var *t          = &self.entries[req->ei].tb.t[req->ti]
        for var k: usize = 0; k <= bi; ++k {
            var *o = &req->blocks[k]
            if (o->close != usize::MAX) || (!(is_type_word(o->word) || (o->word == "module"))) {
                continue
            }

            var found: i64 = -1
            for var r: usize = 0; r < t->rows(); ++r {
                if (t->parent[r] == parent)
                    && (t->name[r] == o->name)
                    && ((t->flags[r] & DF_SCOPE) != 0) {
                    found = r as i64
                    break
                }
            }

            if found < 0 {
                return out
            }

            parent = found
        }

        out.ok = true
        out.t  = req->ti
        out.r  = parent
        return out
    }

    /// The types the cursor is inside: a class body's own class; the target
    /// of an `extend` block only when the block is in the target's own file
    /// (an extension written anywhere else reads what its file may).
    fn use_classes_(self, req: *CompReq) {
        for var k: usize = 0; k < req->blocks.size(); ++k {
            var *b = &req->blocks[k]
            if b->close != usize::MAX {
                continue
            }

            if is_type_word(b->word) || (b->word == "extend") {
                var r = self.block_type_(req, k)
                if r.ok && (!r.file) && ((b->word != "extend") || (r.t == req->ti)) {
                    req->users.push_back(r)
                }
            }
        }
    }

    /// The receiver a type or module NAME \p path (`a::B`) names from this
    /// file: the file's own declarations, then what it imports.
    fn type_name_recv_(self, req: *CompReq, const path: string) -> Recv {
        var out            = Recv{}
        var segs: [string]
        var cur:  string   = ""
        var i:    usize    = 0
        while i < path.size() {
            if (path[i] == (':' as u8)) && ((i + 1) < path.size()) && (path[i + 1] == (':' as u8)) {
                segs.push_back(cur)
                cur = ""
                i += 2
                continue
            }

            cur.push_back(path[i])
            i += 1
        }

        segs.push_back(cur)
        if segs[0].empty() {
            return out
        }

        var tmp = CompReq()
        tmp.di = req->di
        tmp.ei = req->ei
        tmp.f  = req->f
        tmp.ti = req->ti
        self.file_candidates_(&tmp, false)
        self.scope_candidates_(&tmp, false)
        var at = tmp.find(segs[0])
        if at < 0 {
            return out
        }

        var recv = self.cand_recv_(&tmp, tmp.out[at as usize], false)
        for var k: usize = 1; (k < segs.size()) && recv.ok; ++k {
            tmp.reset()
            tmp.users  = req->users
            tmp.sees   = req->sees
            tmp.typing = true
            self.members_into_(&tmp, recv, recv, 0, 0)
            var m = tmp.find(segs[k])
            if m < 0 {
                return out
            }

            recv = self.cand_recv_(&tmp, tmp.out[m as usize], false)
        }

        // A name of a VALUE is no type: only a scope answers.
        if recv.ok && (!recv.file) {
            var fl = self.entries[req->ei].tb.t[recv.t].flags[recv.r as usize]
            if (fl & DF_SCOPE) == 0 {
                return out
            }
        }

        return recv
    }

    // --- names ------------------------------------------------------------

    /// The locals and parameters in scope at the cursor, nearest first.
    ///
    /// \details From the index, the declarations on the lines of the
    ///          enclosing function that the buffer still has as the index
    ///          read them (LineShift); from the text, the ones on the lines
    ///          typed since (`var` / `const` / `for .. in` / `catch`, and
    ///          the header's parameters when the header changed). A
    ///          declaration is in scope when the block it is declared in,
    ///          or the block its header opens, is still open at the cursor.
    fn local_candidates_(self, req: *CompReq) {
        var *text = &self.docs.docs[req->di].text
        var *lm   = &self.docs.docs[req->di].lines
        // The outermost function the cursor is in.
        var fi = function_block(req->blocks)
        if fi == usize::MAX {
            return
        }

        var from           = req->blocks[fi].hstart
        var to             = req->site.start
        var found: [Cand]
        var offs:  [usize]

        // The headers of the types around it: their type parameters.
        var l0       = lm->line_of(from)
        var l1       = lm->line_of(to)
        var *e       = &self.entries[req->ei]
        var *s       = &e->idx
        var slot     = self.cache_slot(req->ei, req->f)
        var hovers   = s->get(req->f, SK_HOVERS)
        var files    = s->get(req->f, SK_FILES)
        var gap_from = usize::MAX
        for var pass: usize = 0; pass < 2; ++pass {
            // pass 0: the enclosing types' header lines (type parameters
            // only); pass 1: the function's lines.
            for var k: usize = 0; k < req->blocks.size(); ++k {
                var a = l0
                var b = l1
                if pass == 0 {
                    if (k >= fi)
                        || (req->blocks[k].close != usize::MAX)
                        || (!(is_type_word(req->blocks[k].word)
                            || (req->blocks[k].word == "extend"))) {
                        continue
                    }

                    a = lm->line_of(req->blocks[k].hstart)
                    b = lm->line_of(req->blocks[k].open)
                } else if k > 0 {
                    break
                }

                for var line: usize = a; line <= b; ++line {
                    var old = req->sh.to_old(line as i64)
                    if (old < 0) || (slot == usize::MAX) {
                        // No rows for this line: read below from the text.
                        if (pass == 1) && (gap_from == usize::MAX) {
                            gap_from = lm->starts[line]
                            if gap_from < from {
                                gap_from = from
                            }
                        }

                        if (pass == 1) && (line == b) && (gap_from != usize::MAX) {
                            self.lex_locals_(req, gap_from, to, &found, &offs)
                            gap_from = usize::MAX
                        }

                        continue
                    }

                    if (pass == 1) && (gap_from != usize::MAX) {
                        self.lex_locals_(
                            req,
                            gap_from,
                            lm->starts[line],
                            &found,
                            &offs,
                        )

                        gap_from = usize::MAX
                    }

                    // The rows of the indexed line: a binary search for it.
                    var lo = e->cf_lo[slot]
                    var hi = e->cf_hi[slot]
                    while lo < hi {
                        var mid = (lo + hi) / 2
                        if e->cr_line[mid] < old {
                            lo = mid + 1
                        } else {
                            hi = mid
                        }
                    }

                    var q = lo
                    while (q < e->cf_hi[slot]) && (e->cr_line[q] == old) {
                        var row = e->cr_row[q]
                        var kd  = s->as_int(self.nth(s, row, REF_KIND)) as u32
                        var local = (kd == TT_VARIABLE())
                            || (kd == TT_PARAMETER())
                            || (kd == TT_SELF())
                            || (kd == TT_TYPE_PARAM())
                        if (pass == 0) && (kd != TT_TYPE_PARAM()) {
                            local = false
                        }

                        if local && (s->as_int(self.nth(s, row, REF_IS_DECL)) != 0) {
                            var off = lm->offset(
                                *text,
                                line,
                                e->cr_ch[q] as usize,
                                false,
                            )

                            var end = lm->offset(
                                *text,
                                line,
                                (e->cr_ch[q] + e->cr_len[q]) as usize,
                                false,
                            )

                            if (end <= to) && (end > off) {
                                var c = Cand{}
                                c.label = text->subslice(off, end - off)
                                c.sort  = SORT_LOCAL
                                c.local = true
                                c.kind  = CIK_VARIABLE
                                if kd == TT_TYPE_PARAM() {
                                    c.kind = CIK_TYPE_PARAMETER
                                }

                                var hv = s->as_int(self.nth(s, row, REF_HOVER))
                                if hv >= 0 {
                                    c.detail = hover_head(
                                        s->str(self.nth(s, hovers, hv)),
                                    )

                                    if c.detail.starts_with("const ")
                                        || c.detail.starts_with("eval ") {
                                        c.kind = CIK_CONSTANT
                                    }
                                }

                                c.at = off
                                var tf = s->as_int(
                                    self.nth(s, row, REF_TYPE_FILE),
                                )

                                if tf < 0 {
                                    // No type in the index (the file was
                                    // checked with an error in it): what
                                    // the text says of the declaration.
                                    var ds = lex_decls(
                                        *text,
                                        req->cls,
                                        lm->starts[line],
                                        lm->line_end(*text, line),
                                    )

                                    for var dk: usize = 0; dk < ds.size(); ++dk {
                                        if ds[dk].off == off {
                                            c.type_ = ds[dk].type_
                                            c.init  = ds[dk].init
                                        }
                                    }
                                }

                                if tf >= 0 {
                                    var tt = e->tb.find(
                                        s->str(self.nth(s, files, tf)),
                                    )

                                    if tt != usize::MAX {
                                        var tr = e->tb.t[tt].row_at_pos(
                                            s->as_int(
                                                self.nth(s, row, REF_TYPE_LINE),
                                            ),
                                            s->as_int(
                                                self.nth(s, row, REF_TYPE_CHAR),
                                            ),
                                        )

                                        if tr >= 0 {
                                            c.ty.ok = true
                                            c.ty.t  = tt
                                            c.ty.r  = tr
                                        }
                                    }
                                }

                                found.push_back(c)
                                offs.push_back(off)
                            }
                        }

                        q += 1
                    }
                }
            }
        }

        // In scope: the block it belongs to is open at the cursor. Nearest
        // declaration first, so a shadowing name is the one kept.
        var order: [usize]
        for var k: usize = 0; k < found.size(); ++k {
            order.push_back(k)
        }

        // Insertion sort by offset, descending: a function's locals are few.
        for var a: usize = 1; a < order.size(); ++a {
            var x = order[a]
            var b = a
            while (b > 0) && (offs[order[b - 1]] < offs[x]) {
                order[b] = order[b - 1]
                b -= 1
            }

            order[b] = x
        }

        for var k: usize = 0; k < order.size(); ++k {
            if declared_in_scope(req->blocks, fi, offs[order[k]]) {
                req->add(found[order[k]])
            }
        }
    }

    /// The names the text declares in [\p from, \p to) of the buffer.
    fn lex_locals_(self, req: *CompReq, from: usize, to: usize, found: *[Cand], offs: *[usize]) {
        if from >= to {
            return
        }

        var *text = &self.docs.docs[req->di].text
        var decls = lex_decls(*text, req->cls, from, to)
        // The function's own header, when it is among those lines.
        for var k: usize = 0; k < req->blocks.size(); ++k {
            var *b = &req->blocks[k]
            if ((b->word == "fn") || (b->word == "test"))
                && (b->hstart >= from)
                && (b->open <= to) {
                var ps = lex_params(*text, req->cls, b->hstart, b->open)
                for var q: usize = 0; q < ps.size(); ++q {
                    decls.push_back(ps[q])
                }
            }
        }

        for var k: usize = 0; k < decls.size(); ++k {
            var c = Cand{}
            c.label = decls[k].name
            c.kind  = CIK_VARIABLE
            c.sort  = SORT_LOCAL
            c.local = true
            c.type_ = decls[k].type_
            c.init  = decls[k].init
            c.at    = decls[k].off
            if !c.type_.empty() {
                c.detail = c.label + ":" + c.type_
            } else {
                // No type written: the one its initialiser plainly has, a
                // construction's or a literal's.
                var ty = self.init_type_(req, c.init)
                if !ty.empty() {
                    c.detail = c.label + ": " + ty
                }
            }

            found->push_back(c)
            offs->push_back(decls[k].off)
        }
    }

    /// The type initialiser \p init plainly has, as text, "" when that is
    /// not plain from the text alone: a construction of a class or struct
    /// (`T(...)`, `T<U>(...)`, `T { ... }`, the head looked up as cand_recv_
    /// looks it up, so `make(...)` is no construction) as written, or a
    /// literal at its default type (primitives.mdx, "Literal inference":
    /// an integer that fits `i32`, else nothing; a float `f64`; a suffix
    /// names its type), `string`, `bool`, `char`.
    fn init_type_(self, req: *CompReq, const init: string) -> string {
        var p: usize = 0
        while (p < init.size()) && ((init[p] == (' ' as u8)) || (init[p] == ('\t' as u8))) {
            p += 1
        }

        var end = init.size()
        while (end > p)
            && ((init[end - 1] == (' ' as u8))
                || (init[end - 1] == ('\t' as u8))
                || (init[end - 1] == ('\r' as u8))) {
            end -= 1
        }

        if end <= p {
            return ""
        }

        var x = init.subslice(p, end - p)
        if (x == "true") || (x == "false") {
            return "bool"
        }

        // One string or char literal, the whole of it (`"a" == "b"` is no
        // string): its closing quote is the initialiser's last byte.
        if (x[0] == ('"' as u8))
            || ((x.size() > 1) && (x[0] == ('f' as u8)) && (x[1] == ('"' as u8))) {
            return if (literal_end_(
                       x,
                       if (x[0] == ('f' as u8)) => (1 as usize) else => (0 as usize),
                   ) == x.size()) => ("string")
                   else => ("")
        }

        if x[0] == ('\x27' as u8) {
            return if (literal_end_(x, 0) == x.size()) => ("char") else => ("")
        }

        if (x[0] >= ('0' as u8)) && (x[0] <= ('9' as u8)) {
            return number_type_(x)
        }

        // A construction: a name (a path), its generic arguments, then `(`
        // or `{`.
        var e: usize = 0
        while (e < x.size()) && (is_ident_byte(x[e]) || (x[e] == (':' as u8))) {
            e += 1
        }

        if e == 0 {
            return ""
        }

        var head  = x.subslice(0, e)
        var after = e
        if (after < x.size()) && (x[after] == ('<' as u8)) {
            var depth: i64 = 0
            while after < x.size() {
                if x[after] == ('<' as u8) {
                    depth += 1
                } else if x[after] == ('>' as u8) {
                    depth -= 1
                    if depth == 0 {
                        after += 1
                        break
                    }
                }

                after += 1
            }
        }

        var written = x.subslice(0, after)
        while (after < x.size()) && (x[after] == (' ' as u8)) {
            after += 1
        }

        if (after >= x.size()) || ((x[after] != ('(' as u8)) && (x[after] != ('{' as u8))) {
            return ""
        }

        var rec = self.type_name_recv_(req, head)
        if (!rec.ok) || rec.file {
            return ""
        }

        var k = self.entries[req->ei].tb.t[rec.t].kind[rec.r as usize]
        if (k != CIK_CLASS) && (k != CIK_STRUCT) {
            return ""
        }

        return written
    }

    /// The file's own declarations: its top level and what its `module`
    /// blocks hold. \p lexical adds the names the text declares at its top
    /// level that the table (of the last text that was checked) lacks.
    fn file_candidates_(self, req: *CompReq, lexical: bool) {
        if req->ti != usize::MAX {
            var *t = &self.entries[req->ei].tb.t[req->ti]
            for var r: usize = 0; r < t->rows(); ++r {
                var fl = t->flags[r]
                if ((fl & DF_EXT) != 0) || ((fl & DF_MACRO) != 0) {
                    continue
                }

                // The file, or module blocks all the way up.
                var p  = t->parent[r]
                var ok = true
                while p >= 0 {
                    if !((t->kind[p as usize] == CIK_MODULE)
                        && ((t->flags[p as usize] & DF_SCOPE) != 0)) {
                        ok = false
                        break
                    }

                    p = t->parent[p as usize]
                }

                if ok {
                    req->add(self.row_cand_(req, req->ti, r as i64, SORT_FILE))
                }
            }
        }

        if !lexical {
            return
        }

        var names = top_level_names(self.docs.docs[req->di].text)
        for var k: usize = 0; k < names.size(); ++k {
            // A macro's name is offered as `name!`, with the macros.
            var is_macro = false
            if req->ti != usize::MAX {
                var *t = &self.entries[req->ei].tb.t[req->ti]
                for var r: usize = 0; r < t->rows(); ++r {
                    if ((t->flags[r] & DF_MACRO) != 0) && (t->name[r] == names[k]) {
                        is_macro = true
                    }
                }
            }

            if is_macro {
                continue
            }

            var c = Cand{}
            c.label = names[k]
            c.kind  = CIK_TEXT
            c.sort  = SORT_FILE
            req->add(c)
        }
    }

    /// What the file's imports bring in: its block's scope rows, each with
    /// the signature its declaration's table row has.
    fn scope_candidates_(self, req: *CompReq, types_only: bool) {
        var *e = &self.entries[req->ei]
        var *s = &e->idx
        // The tables of the files the rows name, found once.
        var tabs: [usize]
        var sf            = s->first(s->get(req->f, SK_SFILES))
        while sf != JSON_NONE() {
            tabs.push_back(e->tb.find(s->str(sf)))
            sf = s->next(sf)
        }

        var row = s->first(s->get(req->f, SK_SCOPE))
        while row != JSON_NONE() {
            // the SCOPE_* columns, in order
            var a = s->first(row)
            var c = Cand{}
            c.label = s->str(a)
            a       = s->next(a)
            c.kind  = s->as_int(a)
            a       = s->next(a)
            c.sort  = s->as_int(a) as u32
            a       = s->next(a)
            var fi = s->as_int(a)
            a = s->next(a)
            var off = s->as_int(a)
            a = s->next(a)
            if a != JSON_NONE() {
                c.detail = s->str(a)
            }

            if (!types_only) || is_type_kind(c.kind) {
                if (fi >= 0) && ((fi as usize) < tabs.size()) && (tabs[fi as usize] != usize::MAX) {
                    var tt = tabs[fi as usize]
                    if off < 0 {
                        c.t = tt
                        c.r = -1 // the file itself, a module
                    } else {
                        var r = e->tb.t[tt].row_at(off)
                        if r >= 0 {
                            c.t      = tt
                            c.r      = r
                            c.detail = e->tb.t[tt].detail[r as usize]
                        }
                    }
                }

                req->add(c)
            }

            row = s->next(row)
        }
    }

    /// The macros a `name!` can be here: the file's own, the `pub` ones of
    /// the files it imports and of the builtin library, and the compiler's.
    fn macro_candidates_(self, req: *CompReq) {
        var *e            = &self.entries[req->ei]
        var *s            = &e->idx
        var from: [usize]
        if req->ti != usize::MAX {
            from.push_back(req->ti)
        }

        var l = s->first(s->get(req->f, SK_LINKS))
        while l != JSON_NONE() {
            var tt = e->tb.find(s->str(self.nth(s, l, LINK_TARGET)))
            if tt != usize::MAX {
                from.push_back(tt)
            }

            l = s->next(l)
        }

        for var k: usize = 0; k < e->tb.t.size(); ++k {
            if e->tb.t[k].builtin {
                from.push_back(k)
            }
        }

        for var k: usize = 0; k < from.size(); ++k {
            var *t = &e->tb.t[from[k]]
            for var r: usize = 0; r < t->rows(); ++r {
                if (t->flags[r] & DF_MACRO) == 0 {
                    continue
                }

                if (from[k] != req->ti) && (t->vis[r] != VIS_PUB) {
                    continue
                }

                var c = Cand{}
                c.label   = t->name[r] + "!"
                c.kind    = CIK_SNIPPET
                c.detail  = t->detail[r]
                c.sort    = SORT_MACRO
                c.t       = from[k]
                c.r       = r as i64
                c.insert  = usage_snippet(t->detail[r])
                c.snippet = c.insert != t->detail[r]
                req->add(c)
            }
        }

        if self.macro_rows.empty() {
            self.macro_rows = builtin_macros()
        }

        for var k: usize = 0; k < self.macro_rows.size(); ++k {
            var *m = &self.macro_rows[k]
            var c  = Cand{}
            c.label   = m->word + "!"
            c.kind    = CIK_SNIPPET
            c.detail  = m->usage
            c.doc     = m->summary
            c.sort    = SORT_BUILTIN
            c.insert  = usage_snippet(m->usage)
            c.snippet = c.insert != m->usage
            req->add(c)
        }
    }

    /// A bare name: locals, the enclosing type, the file, its imports,
    /// macros, and the keywords that can stand there.
    fn name_candidates_(self, req: *CompReq) {
        var kc = req->site.kc
        // A parameter being named: only the words that can stand there.
        if kc != KC_PARAM {
            var types_only = kc == KC_TYPE
            self.local_candidates_(req)
            if types_only {
                // Of the locals, a type parameter is a type.
                var kept: [Cand]
                for var k: usize = 0; k < req->out.size(); ++k {
                    if req->out[k].kind == CIK_TYPE_PARAMETER {
                        kept.push_back(req->out[k])
                    }
                }

                req->reset()
                for var k: usize = 0; k < kept.size(); ++k {
                    req->add(kept[k])
                }
            }

            // The members of the types the cursor is inside, innermost first.
            var k = req->blocks.size()
            while k > 0 {
                k -= 1
                if (req->blocks[k].close == usize::MAX) && is_type_word(req->blocks[k].word) {
                    var recv = self.block_type_(req, k)
                    if recv.ok {
                        var before = req->out.size()
                        self.members_into_(req, recv, recv, 0, SORT_TYPE)
                        if types_only {
                            self.keep_types_(req, before)
                        }
                    }
                }
            }

            var before = req->out.size()
            self.file_candidates_(
                req,
                self.docs.docs[req->di].text != self.docs.docs[req->di].idx_text,
            )

            if types_only {
                self.keep_types_(req, before)
            }

            self.scope_candidates_(req, types_only)
            if !types_only {
                self.macro_candidates_(req)
            }
        }

        if self.words.empty() {
            self.words = language_words()
        }

        for var k: usize = 0; k < self.words.size(); ++k {
            if (self.words[k].kc & kc) == 0 {
                continue
            }

            var c = Cand{}
            c.label = self.words[k].text
            c.kind  = CIK_KEYWORD
            c.sort  = SORT_KEYWORD
            req->add(c)
        }
    }

    /// Drops the candidates from \p from on that are not types.
    fn keep_types_(self, req: *CompReq, from: usize) {
        var all = req->out
        req->reset()
        for var k: usize = 0; k < all.size(); ++k {
            if (k < from) || is_type_kind(all[k].kind) {
                req->add(all[k])
            }
        }
    }

    // --- members ----------------------------------------------------------

    /// What the head of a receiver names: `self`, a local, a member of the
    /// enclosing type, a name of the file or of its imports.
    fn head_recv_(self, req: *CompReq, const st: RecvStep) -> Recv {
        var none = Recv{}
        if (st.name == "self") || (st.name == "Self") {
            if st.call || ((st.name == "Self") && (st.index > 0)) {
                return none // `Self(...)`, `Self[..]`: not a value of the type
            }

            var k = req->blocks.size()
            while k > 0 {
                k -= 1
                if (req->blocks[k].close == usize::MAX)
                    && (is_type_word(req->blocks[k].word) || (req->blocks[k].word == "extend")) {
                    // `self[i]`: the enclosing type's own `op []`, which
                    // its row carries as for any record.
                    var recv = self.block_type_(req, k)
                    for var n: usize = 0; (n < st.index) && recv.ok; ++n {
                        recv = self.op_index_recv_(req, recv)
                    }

                    return recv
                }
            }

            return none
        }

        var tmp = CompReq()
        tmp.di     = req->di
        tmp.ei     = req->ei
        tmp.f      = req->f
        tmp.ti     = req->ti
        tmp.cls    = req->cls
        tmp.blocks = req->blocks
        tmp.sh     = req->sh
        tmp.sees   = req->sees
        tmp.users  = req->users
        tmp.site   = req->site
        tmp.depth  = req->depth
        tmp.typing = true
        // In scope where the HEAD stands, not where the cursor is.
        tmp.site.start = st.off
        self.local_candidates_(&tmp)
        var k = tmp.blocks.size()
        while k > 0 {
            k -= 1
            if (tmp.blocks[k].close == usize::MAX) && is_type_word(tmp.blocks[k].word) {
                var recv = self.block_type_(&tmp, k)
                if recv.ok {
                    self.members_into_(&tmp, recv, recv, 0, SORT_TYPE)
                }
            }
        }

        self.file_candidates_(&tmp, false)
        self.scope_candidates_(&tmp, false)
        var at = tmp.find(st.name)
        if at < 0 {
            return none
        }

        return self.subscript_recv_(
            &tmp,
            tmp.out[at as usize],
            st.call,
            st.index,
        )
    }

    /// The members of the receiver before the cursor. False when the
    /// tables do not type it, or it has none to offer: the compiler is
    /// asked.
    fn member_candidates_(self, req: *CompReq) -> bool {
        var *text = &self.docs.docs[req->di].text
        var steps = receiver_steps(*text, req->cls, req->site.recv_end)
        if steps.empty() {
            return false
        }

        // `usize::`: a primitive's name before `::` is its type whatever
        // the file declares (a primitive's name is no name lookup finds,
        // ChainBinding reads it first). Typed here, as the compiler's own
        // list, even when that list is empty: there is nothing more the
        // compiler would offer.
        if (steps.size() == 1)
            && (!steps[0].call)
            && (steps[0].index == 0)
            && (text->subslice(req->site.recv_end, 2) == "::") {
            var pb = primitive_of(steps[0].name)
            if pb != BuiltinKind::COUNT {
                self.primitive_members_(req, pb)
                return true
            }
        }

        var recv = self.chain_recv_(req, &steps)
        if !recv.ok {
            return false
        }

        self.members_into_(req, recv, recv, 0, 0)
        return !req->out.empty()
    }

    /// After `b::`, \p b a primitive: its associated constants (the
    /// compiler's table, Index/Primitives.k), then the members of the
    /// `extend` blocks of it this file sees, whose rows spell the
    /// primitive (`DC_DETAIL` of a DF_EXT row, Tables.k). As the marker
    /// path lists them (CompletionItems.k, complete_primitive_).
    fn primitive_members_(self, req: *CompReq, b: BuiltinKind) {
        var cs = primitive_consts(b)
        for var i: usize = 0; i < cs.size(); ++i {
            var c = Cand{}
            c.label  = cs[i].name
            c.kind   = CIK_CONSTANT
            c.detail = cs[i].detail
            req->add(c)
        }

        var sp    = primitive_spelling(b)
        var none  = Recv{}
        var *tb   = &self.entries[req->ei].tb
        var *exts = tb->extensions()
        for var x: usize = 0; x < exts->size(); ++x {
            var et = ((*exts)[x] >> 32) as usize
            var er = ((*exts)[x] & 0xFFFFFFFF) as i64
            if (tb->t[et].detail[er as usize] != sp) || (!self.sees_ext_(req, et, usize::MAX)) {
                continue
            }

            var *xt = &tb->t[et]
            for var r: usize = (er + 1) as usize; r < xt->rows(); ++r {
                if xt->parent[r] != er {
                    if xt->parent[r] < er {
                        break
                    }

                    continue
                }

                self.member_row_(req, et, r as i64, none, none, 0)
            }
        }
    }

    /// What the chain \p steps is, as a receiver: its head, then each
    /// further step looked up among the members of what is before it. Not
    /// ok when a step is not found or the tables do not type it.
    fn chain_recv_(self, req: *CompReq, steps: *const [RecvStep]) -> Recv {
        var none = Recv{}
        var recv = self.head_recv_(req, (*steps)[0])
        for var k: usize = 1; (k < steps->size()) && recv.ok; ++k {
            var tmp = CompReq()
            tmp.di     = req->di
            tmp.ei     = req->ei
            tmp.f      = req->f
            tmp.ti     = req->ti
            tmp.sees   = req->sees
            tmp.users  = req->users
            tmp.depth  = req->depth
            tmp.typing = true
            self.members_into_(&tmp, recv, recv, 0, 0)
            var m = tmp.find((*steps)[k].name)
            if m < 0 {
                return none
            }

            recv = self.subscript_recv_(
                &tmp,
                tmp.out[m as usize],
                (*steps)[k].call,
                (*steps)[k].index,
            )
        }

        return recv
    }

    // --- attributes, headers ----------------------------------------------

    /// After `@`: the attributes the compiler gives a meaning, those that
    /// can stand before what follows when that is written already.
    fn attribute_candidates_(self, req: *CompReq) {
        if self.attr_rows.empty() {
            self.attr_rows = builtin_attributes()
        }

        var nw:   string = req->site.next_word
        var want: string = ""
        if nw == "fn" {
            want = "fn"
        } else if (nw == "class") || (nw == "struct") || (nw == "union") {
            want = "type"
        } else if nw == "enum" {
            want = "enum"
        } else if nw == "var" {
            want = "var"
        } else if (nw == "if") || (nw == "else") {
            want = "stmt"
        }

        for var k: usize = 0; k < self.attr_rows.size(); ++k {
            var *a = &self.attr_rows[k]
            if (!want.empty()) && (!has_word(a->targets, want)) && (!has_word(a->targets, "any")) {
                continue
            }

            var c = Cand{}
            c.label   = a->word
            c.kind    = CIK_KEYWORD
            c.detail  = "@" + a->usage
            c.doc     = a->summary
            c.insert  = usage_snippet(a->usage)
            c.snippet = c.insert != a->usage
            if (!c.snippet) && (c.insert == c.label) {
                c.insert = ""
            }

            req->add(c)
        }
    }

    /// The directories an `ffi import "..."` of buffer \p di is looked up
    /// in: the file's own, then the include directories of its entry's
    /// compile (the driver words a snapshot carries: `-I`, `-isystem` and
    /// their kin), C++'s for \p cxx.
    fn include_dirs_(self, di: usize, cxx: bool) -> [string] {
        var out: [string]
        out.push_back(Path::parent_of(self.docs.docs[di].path))
        var ei = self.entry_of(self.docs.docs[di].path)
        if (ei == usize::MAX) || (!self.entries[ei].has_snap) {
            return out
        }

        var *s = &self.entries[ei].snap
        var a = s->first(
            s->get(s->root, if (cxx) => (SK_CXX_FLAGS) else => SK_C_FLAGS),
        )

        while a != JSON_NONE() {
            var w           = s->str(a)
            var dir: string = ""
            if (w == "-I")
                || (w == "-isystem")
                || (w == "-internal-isystem")
                || (w == "-internal-externc-isystem")
                || (w == "-cxx-isystem")
                || (w == "-idirafter")
                || (w == "-iquote") {
                a = s->next(a)
                if a == JSON_NONE() {
                    break
                }

                dir = s->str(a)
            } else if w.starts_with("-I") && (w.size() > 2) {
                dir = w.subslice(2, w.size() - 2)
            } else if w.starts_with("-isystem") && (w.size() > 8) {
                dir = w.subslice(8, w.size() - 8)
            }

            if !dir.empty() {
                dir = Path::absolute_if_exists(dir, self.entries[ei].dir)
                var dup = false
                for var k: usize = 0; k < out.size(); ++k {
                    if out[k] == dir {
                        dup = true
                    }
                }

                if !dup {
                    out.push_back(dir)
                }
            }

            a = s->next(a)
        }

        return out
    }

    /// Inside the string of `ffi "c++" import "dir/na|`: the files and
    /// directories `dir` holds under each include directory.
    fn header_candidates_(self, req: *CompReq, at: usize) {
        var *text = &self.docs.docs[req->di].text
        var typed = text->subslice(
            req->site.path_at,
            req->site.start - req->site.path_at,
        )

        var cxx = req->site.lang != "c"
        // The listing made a moment ago for the same directory of the same
        // buffer: a dozen directories are read and each entry is asked
        // whether it is one.
        var key = self.docs.docs[req->di].path + "\n" + req->site.lang + "\n" + typed
        if (key == self.hdr_key) && ((now_ms() - self.hdr_ms) < HEADER_LIST_KEEP_MS) {
            for var k: usize = 0; k < self.hdr_cands.size(); ++k {
                req->add(self.hdr_cands[k])
            }

            return
        }

        var dirs = self.include_dirs_(req->di, cxx)
        for var k: usize = 0; k < dirs.size(); ++k {
            var dir = dirs[k]
            if !typed.empty() {
                dir = Path::join_str(dir, typed)
            }

            var names = LinkFS::list_dir(dir)
            for var n: usize = 0; n < names.size(); ++n {
                var name: string = names[n]
                if name.starts_with(".") {
                    continue
                }

                var c = Cand{}
                c.label = name
                c.sort  = if (k == 0) => (0 as u32) else => (1 as u32)
                if LinkFS::is_dir(Path::join_str(dir, name)) {
                    c.kind   = CIK_FOLDER
                    c.insert = name + "/"
                } else {
                    // A header: no extension (the C++ library's), or a
                    // header's; a Kairo file is imported, not included.
                    var dot         = name.rfind('.' as u8)
                    var ext: string = ""
                    if dot != usize::MAX {
                        ext = lower(
                            name.subslice(dot + 1, name.size() - dot - 1),
                        )
                    }

                    if !((dot == usize::MAX)
                        || (ext == "h")
                        || (ext == "hh")
                        || (ext == "hpp")
                        || (ext == "hxx")
                        || (ext == "inc")
                        || (ext == "def")
                        || (ext == "ipp")) {
                        continue
                    }

                    if (dot == usize::MAX) && (!cxx) {
                        continue
                    }

                    c.kind   = CIK_FILE
                    c.detail = dirs[k]
                }

                req->add(c)
            }
        }

        self.hdr_key   = key
        self.hdr_ms    = now_ms()
        self.hdr_cands = req->out
    }
}
