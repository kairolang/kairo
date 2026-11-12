/// --- The Kairo Project -------------------- Analyzer/Server/Features.k --- ///
///
///   The requests answered straight from a snapshot's rows: hover, definition, references, highlights, links, inlays, rename.
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
    /// Can entry \p ei (usize::MAX: none known yet) answer a request now?
    /// The first rows of LanguageServer.md section 9, in one place; a pure
    /// query (feature() calls ensure_entry first).
    fn answerability(const self, ei: usize, const path: string) -> Answer {
        if ei == usize::MAX {
            // ensure_entry gives a Kairo file no entry only while a
            // candidate's FIRST run is due or going (the one that will say
            // whether it holds the file; failing all, the file's own entry
            // is made and returned). That is a first index on its way, and
            // waits as one: as NoEntry it was answered from no snapshot
            // after PARK_LIMIT_MS, a null hover in the middle of the run
            // that was about to answer it.
            if path.ends_with(kairo_dot_ext()) {
                return Answer::FirstPending
            }

            return Answer::NoEntry
        }

        if self.entries[ei].fresh() {
            return Answer::Fresh
        }

        if (!self.entries[ei].has_idx) && (self.entries[ei].running || self.entries[ei].dirty) {
            return Answer::FirstPending
        }

        if self.entries[ei].slow && self.entries[ei].has_idx {
            return Answer::StaleSlow
        }

        return Answer::StaleWaitable
    }

    /// The features answered from a snapshot. False: not answerable yet (the
    /// entry is stale or unknown) and \p stale_ok is off, so park it.
    fn feature(self, const msg: string, stale_ok: bool, give_up: bool) -> bool {
        var d = JsonDoc()
        if !d.parse(msg) {
            return true
        }

        var method = d.get_str(d.root, K_METHOD)
        var idn    = d.get(d.root, K_ID)
        if idn == JSON_NONE() {
            return true
        }

        var id     = d.dump(idn)
        var params = d.get(d.root, K_PARAMS)
        var path   = self.path_of(text_document_uri(&d, params))

        // A buffer that does not parse has no index for its current text,
        // and may not get one until it parses again. Its syntax pass lexed
        // exactly this text: keywords, comments, strings and numbers at
        // their current positions are a correct answer, where the old index
        // would be off by the edits (and ContentModified would leave the
        // editor's colours drifting for as long as the code is broken).
        if method.starts_with(M_SEMANTIC_TOKENS_PREFIX) {
            var ldi = self.docs.index_of_path(path)
            if (ldi != usize::MAX) && self.docs.docs[ldi].syn.current(self.docs.docs[ldi].changed_at)
                && (!self.docs.docs[ldi].syn.parsed) {
                var lei = self.entry_of(path)
                // Fresh FOR THIS FILE: an index of a graph with syntax errors
                // is current but may have no rows for the broken file
                // (`unchecked`, section 9), and that file still wants colour.
                var idx_fresh = (lei != usize::MAX) && self.entries[lei].has_idx
                    && (self.entries[lei].idx_rev >= self.docs.docs[ldi].changed_at)
                    && (self.file_node(lei, path) != JSON_NONE())
                if !idx_fresh {
                    // With the last good index's colours on every line the
                    // edits left alone, when the text it read is known:
                    // only the broken lines fall back to the lexical ones.
                    var lf = JSON_NONE()
                    if (lei != usize::MAX) && self.entries[lei].has_idx {
                        lf = self.file_node(lei, path)
                    }

                    if lf != JSON_NONE() {
                        var lsh = self.line_shift(lei, ldi)
                        var lk  = self.cache_slot(lei, lf)
                        if lsh.active && (lk != usize::MAX) {
                            var merged = self.merged_tokens(lei, lk, ldi, &lsh)
                            self.send_tokens(&d, params, id, method, &merged)
                            return true
                        }
                    }

                    self.send_tokens(&d, params, id, method, &self.docs.docs[ldi].syn.tokens)
                    return true
                }
            }
        }

        // Which entry answers: found, or a run of one started, here (a
        // request is what starts the analysis of a file no entry holds yet).
        var ei = self.ensure_entry(path)
        var can = self.answerability(ei, path)
        if can != Answer::Fresh {
            // "Answer from the last snapshot" needs a last snapshot. Until
            // an entry's FIRST index exists there is nothing to answer from,
            // and an empty answer would tell the editor the file has no
            // tokens, no hints and no symbols: wait for it, however slow
            // (give_up bounds that, FIRST_INDEX_LIMIT_MS).
            if (can == Answer::FirstPending) && (!give_up) {
                return false
            }

            if (!stale_ok) && (can != Answer::StaleSlow) {
                return false
            }

            if ei != usize::MAX {
                self.entries[ei].owe_refresh = true
            }
        }

        // Files of this entry are still to be re-checked after an edit
        // (a live worker's second tier): their rows are from before it. A
        // rename's edits come from every file's rows, so it waits; what is
        // asked about one position is answered from what there is, and the
        // editor is told to ask again when the rest lands.
        if (ei != usize::MAX) && (self.entries[ei].live_pending > 0) {
            if (method == M_RENAME) || (method == M_PREPARE_RENAME) {
                self.respond(id, "null")
                return true
            }

            self.entries[ei].owe_refresh = true
        }

        var f = JSON_NONE()
        if ei != usize::MAX {
            f = self.file_node(ei, path)
        }

        if (method == M_CODE_ACTION) && (ei != usize::MAX) && self.entries[ei].has_snap {
            // Macro actions carry positions: only from an index of this text.
            var mf = JSON_NONE()
            var mdi = self.docs.index_of_path(path)
            if (f != JSON_NONE()) && ((mdi == usize::MAX) || (self.entries[ei].idx_rev >= self.docs.docs[mdi].changed_at)) {
                mf = f
            }

            self.code_action(&d, params, id, &self.entries[ei].snap, path, ei, mf)
            return true
        }

        if f == JSON_NONE() {
            // No index for this file: it did not parse, or never has. An
            // empty answer, of the shape each method expects.
            if (method == M_SEMANTIC_TOKENS_FULL) || (method == M_SEMANTIC_TOKENS_DELTA) {
                self.respond(id, "{\"data\":[]}")
            } else if (method == M_SEMANTIC_TOKENS_RANGE) {
                self.respond(id, "{\"data\":[]}")
            } else if (method == M_HOVER) || (method == M_DEFINITION)
                || (method == M_PREPARE_CALL_HIERARCHY) || (method == M_PREPARE_TYPE_HIERARCHY)
                || (method == M_RENAME) || (method == M_PREPARE_RENAME)
                || (method == M_TYPE_DEFINITION) || (method == M_DECLARATION) {
                self.respond(id, "null")
            } else {
                self.respond(id, "[]")
            }

            return true
        }

        // The index may be older than the buffer: the run for this text has
        // not landed, or the text does not parse and the last good index was
        // kept. Its positions are then off by the edits since. Sending them
        // makes the editor draw hints, lenses and colours in the wrong
        // places until the next answer (the flicker). The protocol's answer
        // is ContentModified: the editor keeps what it has, which it has
        // been moving with the text itself, and asks again.
        //
        // Except at a position on a line the edits did not touch. Typing
        // one broken line keeps the last good index for as long as it stays
        // broken, and blanking every hover and jump in the file for that
        // long is the cost of not knowing where the old lines went. The
        // text that index read is known (Document::idx_text): a request on
        // a line both texts share is answered from it, its position moved
        // to that text and every same-file position in the answer moved
        // back (LineShift). Only what is asked for by hand at a position,
        // and only what stays right on the shared lines: rename and the
        // hierarchy items do not (a rename's edits would miss the uses in
        // the changed middle, and an item is asked about again later).
        var di = self.docs.index_of_path(path)
        var sh = LineShift()
        var stale = (di != usize::MAX) && (self.entries[ei].idx_rev < self.docs.docs[di].changed_at)
        if stale && ((method == M_HOVER) || (method == M_DEFINITION) || (method == M_DECLARATION)
            || (method == M_TYPE_DEFINITION) || (method == M_IMPLEMENTATION)
            || (method == M_REFERENCES) || (method == M_DOCUMENT_HIGHLIGHT)) {
            sh = self.line_shift(ei, di)
            var spos = d.get(params, K_POSITION)
            stale = (!sh.active) || (sh.to_old(d.get_int(spos, K_LINE)) < 0)
        }

        // What the editor DRAWS (hints, lenses, colours) is answered the same
        // way, for every line the edits left alone: each such row is sent
        // at its line in the buffer, and the rows of the changed lines are
        // not (colours: the syntax pass's lexical ones there, so they wait
        // for that pass). One broken line then costs that line's hints and
        // no other's, where ContentModified left it to each editor how
        // long it kept which of them. The editor is told to ask again when
        // an index of this text lands.
        var is_tokens = (method == M_SEMANTIC_TOKENS_FULL) || (method == M_SEMANTIC_TOKENS_DELTA)
            || (method == M_SEMANTIC_TOKENS_RANGE)
        //
        // Only when no index of this text is about to land: the buffer does
        // not parse, or the entry has nothing due (its last run kept the
        // older index). While a run of a text that parses is on its way the
        // editor keeps what it has for those few milliseconds, as before: a
        // mapped answer there would turn the names of the line being typed
        // lexical on every keystroke.
        var syn_now = (di != usize::MAX) && self.docs.docs[di].syn.current(self.docs.docs[di].changed_at)
        var settled = (can == Answer::Fresh) || (syn_now && (!self.docs.docs[di].syn.parsed))
        if stale && settled && (is_tokens || (method == M_INLAY_HINT) || (method == M_CODE_LENS)) {
            sh = self.line_shift(ei, di)
            stale = (!sh.active) || (is_tokens && (!syn_now))
            if !stale {
                self.entries[ei].owe_refresh = true
            } else {
                sh = LineShift()
            }
        }

        if stale {
            if (method == M_HOVER) || (method == M_DEFINITION)
                || (method == M_DECLARATION) || (method == M_TYPE_DEFINITION)
                || (method == M_PREPARE_RENAME) || (method == M_RENAME)
                || (method == M_IMPLEMENTATION) || (method == M_PREPARE_CALL_HIERARCHY)
                || (method == M_PREPARE_TYPE_HIERARCHY) {
                // Asked for by hand at a position: no answer beats a wrong one.
                self.respond(id, "null")
            } else if (method == M_CODE_ACTION) {
                self.code_action(&d, params, id, &self.entries[ei].snap, path, ei, JSON_NONE())
            } else {
                self.respond_error(id, ERR_CONTENT_MODIFIED, "content modified")
            }

            return true
        }

        var *s   = &self.entries[ei].idx
        var pos  = d.get(params, K_POSITION)
        var line = sh.to_old(d.get_int(pos, K_LINE)) // inactive: the line itself
        var ch   = d.get_int(pos, K_CHARACTER)

        if (method == M_SEMANTIC_TOKENS_FULL) || (method == M_SEMANTIC_TOKENS_DELTA)
            || (method == M_SEMANTIC_TOKENS_RANGE) {
            var now: [i64]
            var k = self.cache_slot(ei, f)
            if sh.active && (k != usize::MAX) {
                now = self.merged_tokens(ei, k, di, &sh)
            } else if k != usize::MAX {
                now.reserve(self.entries[ei].ct_hi[k] - self.entries[ei].ct_lo[k])
                for var q = self.entries[ei].ct_lo[k]; q < self.entries[ei].ct_hi[k]; ++q {
                    now.push_back(self.entries[ei].ct_data[q])
                }
            }

            self.send_tokens(&d, params, id, method, &now)
            return true
        }

        if method == M_CODE_LENS {
            self.code_lens(s, f, path, id, &sh)
            return true
        }

        if method == M_DOCUMENT_SYMBOL {
            var w = JsonWriter()
            w.begin_array()
            var c = s->first(s->get(f, SK_SYMBOLS))
            while c != JSON_NONE() {
                c = self.symbol(s, c, &w)
            }

            w.end_array()
            self.respond(id, w.out)
            return true
        }

        if method == M_INLAY_HINT {
            if !sh.active {
                self.respond(id, s->dump(s->get(f, SK_INLAYS)))
                return true
            }

            // An older text's hints: each on its line in the buffer.
            var iw = JsonWriter()
            iw.begin_array()
            var h = s->first(s->get(f, SK_INLAYS))
            while h != JSON_NONE() {
                var hp = s->get(h, K_POSITION)
                var hl = sh.to_new(s->get_int(hp, K_LINE))
                if hl >= 0 {
                    iw.begin_object()
                    iw.key(K_POSITION)
                    write_lsp_position(&iw, hl, s->get_int(hp, K_CHARACTER))
                    iw.field(K_LABEL, s->get_str(h, K_LABEL))
                    if s->get(h, K_KIND) != JSON_NONE() {
                        iw.field_int(K_KIND, s->get_int(h, K_KIND))
                    }

                    if s->get_bool(h, K_PADDING_LEFT) {
                        iw.field_bool(K_PADDING_LEFT, true)
                    }

                    if s->get_bool(h, K_PADDING_RIGHT) {
                        iw.field_bool(K_PADDING_RIGHT, true)
                    }

                    iw.end_object()
                }

                h = s->next(h)
            }

            iw.end_array()
            self.respond(id, iw.out)
            return true
        }

        if method == M_CODE_ACTION {
            // Fix-its belong to the CURRENT diagnostics, not to the last
            // run that happened to index.
            self.code_action(&d, params, id, &self.entries[ei].snap, path, ei, f)
            return true
        }

        var row = self.ref_at(ei, f, line, ch)

        if method == M_HOVER {
            // On a macro invocation the question is what it turns into; the
            // names inside it are the expansion's, at the invocation's place.
            var mrow = self.macro_at(s, f, line, ch)
            var ml0 = s->as_int(self.nth(s, mrow, MACRO_LINE))
            var me0 = s->as_int(self.nth(s, mrow, MACRO_END_LINE))
            var ml  = sh.to_new(ml0)
            var me  = sh.to_new(me0)
            if (mrow != JSON_NONE()) && (!sh.kept(ml0, me0)) {
                // An invocation the edits cut through: what it expands to now
                // is not known.
                self.respond(id, "null")
                return true
            }

            if mrow != JSON_NONE() {
                var mw = JsonWriter()
                mw.begin_object()
                mw.key(K_CONTENTS)
                mw.begin_object()
                mw.field(K_KIND, MARKUP_MARKDOWN)
                var mtext = s->str(self.nth(s, mrow, MACRO_TEXT))
                mw.field(K_VALUE, "**Expands to**\n\n```kairo\n" + mtext + "\n```")
                mw.end_object()
                mw.key(K_RANGE)
                write_lsp_range(&mw, ml, s->as_int(self.nth(s, mrow, MACRO_CHAR)), me, s->as_int(self.nth(s, mrow, MACRO_END_CHAR)))
                mw.end_object()
                self.respond(id, mw.out)
                return true
            }

            var h = s->as_int(self.nth(s, row, REF_HOVER))
            if (row == JSON_NONE()) || (h < 0) {
                self.respond(id, "null")
                return true
            }

            var w = JsonWriter()
            w.begin_object()
            w.key(K_CONTENTS)
            w.begin_object()
            w.field(K_KIND, MARKUP_MARKDOWN)
            w.field(K_VALUE, s->str(self.nth(s, s->get(f, SK_HOVERS), h)))
            w.end_object()
            w.key(K_RANGE)
            self.write_range(&w, self.shift_out(&sh, ei, path, s->as_int(self.nth(s, row, REF_LINE))), s->as_int(self.nth(s, row, REF_CHAR)), s->as_int(self.nth(s, row, REF_LEN)))
            w.end_object()
            self.respond(id, w.out)
            return true
        }

        if (method == M_PREPARE_CALL_HIERARCHY) || (method == M_PREPARE_TYPE_HIERARCHY) {
            var fi = s->as_int(self.nth(s, row, REF_DEF_FILE))
            var k  = s->as_int(self.nth(s, row, REF_KIND))
            var is_fn = (k == (TT_FUNCTION() as i64)) || (k == (TT_METHOD() as i64))
            var is_ty = (k == (TT_CLASS() as i64)) || (k == (TT_ENUM() as i64)) || (k == (TT_INTERFACE() as i64)) ||
                (k == (TT_STRUCT() as i64)) || (k == (TT_UNION() as i64))
            var call = method == M_PREPARE_CALL_HIERARCHY
            if (row == JSON_NONE()) || (fi < 0) || (call && (!is_fn)) || ((!call) && (!is_ty)) {
                self.respond(id, "null")
                return true
            }

            var w = JsonWriter()
            w.begin_array()
            self.hierarchy_item(
                &w,
                self.name_in_hover(s->str(self.nth(s, s->get(f, SK_HOVERS), s->as_int(self.nth(s, row, REF_HOVER))))),
                if call => SYM_FUNCTION else => SYM_CLASS,
                s->str(self.nth(s, s->get(f, SK_FILES), fi)),
                s->as_int(self.nth(s, row, REF_DEF_LINE)),
                s->as_int(self.nth(s, row, REF_DEF_CHAR)),
                s->as_int(self.nth(s, row, REF_DEF_LEN)),
            )

            w.end_array()
            self.respond(id, w.out)
            return true
        }

        if method == M_IMPLEMENTATION {
            // The types that derive or implement the one under the cursor.
            var fi = s->as_int(self.nth(s, row, REF_DEF_FILE))
            if (row == JSON_NONE()) || (fi < 0) {
                self.respond(id, "null")
                return true
            }

            var w = JsonWriter()
            w.begin_array()
            self.related_types(
                s->str(self.nth(s, s->get(f, SK_FILES), fi)),
                s->as_int(self.nth(s, row, REF_DEF_LINE)),
                s->as_int(self.nth(s, row, REF_DEF_CHAR)),
                false,
                &w,
                false,
                &sh,
            )

            w.end_array()
            self.respond(id, w.out)
            return true
        }

        if method == M_DOCUMENT_LINK {
            var w = JsonWriter()
            w.begin_array()
            var l = s->first(s->get(f, SK_LINKS))
            while l != JSON_NONE() {
                w.begin_object()
                w.key(K_RANGE)
                self.write_range(&w, s->as_int(self.nth(s, l, LINK_LINE)), s->as_int(self.nth(s, l, LINK_CHAR)), s->as_int(self.nth(s, l, LINK_LEN)))
                w.field(K_TARGET, self.uri_of(s->str(self.nth(s, l, LINK_TARGET))))
                w.end_object()
                l = s->next(l)
            }

            w.end_array()
            self.respond(id, w.out)
            return true
        }

        if method == M_PREPARE_RENAME {
            // Only a name the index resolved can be renamed: every one of
            // its uses is then known, and nothing else is.
            // Nor while an index holds a file a syntax error left without
            // rows (section 9): the uses there are unknown, and a rename
            // would miss them without saying so.
            if (row == JSON_NONE()) || (s->as_int(self.nth(s, row, REF_DEF_FILE)) < 0) || self.any_incomplete_index() {
                self.respond(id, "null")
                return true
            }

            var w = JsonWriter()
            self.write_range(&w, s->as_int(self.nth(s, row, REF_LINE)), s->as_int(self.nth(s, row, REF_CHAR)), s->as_int(self.nth(s, row, REF_LEN)))
            self.respond(id, w.out)
            return true
        }

        if method == M_TYPE_DEFINITION {
            var ti = s->as_int(self.nth(s, row, REF_TYPE_FILE))
            if (row == JSON_NONE()) || (ti < 0) || (self.nth(s, row, REF_TYPE_FILE) == JSON_NONE()) {
                self.respond(id, "null")
                return true
            }

            var tpath = s->str(self.nth(s, s->get(f, SK_FILES), ti))
            var tl = self.shift_out(&sh, ei, tpath, s->as_int(self.nth(s, row, REF_TYPE_LINE)))
            if tl < 0 {
                self.respond(id, "null") // declared in the changed middle
                return true
            }

            var w = JsonWriter()
            w.begin_object()
            w.field(K_URI, self.uri_of(tpath))
            w.key(K_RANGE)
            self.write_range(&w, tl, s->as_int(self.nth(s, row, REF_TYPE_CHAR)), s->as_int(self.nth(s, row, REF_TYPE_LEN)))
            w.end_object()
            self.respond(id, w.out)
            return true
        }

        if (method == M_DEFINITION) || (method == M_DECLARATION) {
            var fi = s->as_int(self.nth(s, row, REF_DEF_FILE))
            if (row == JSON_NONE()) || (fi < 0) {
                // No name here, but perhaps a link: an import's module path
                // or an ffi header string. Its definition is the file it
                // names, at its start, as clangd answers on an `#include`.
                var l = s->first(s->get(f, SK_LINKS))
                while l != JSON_NONE() {
                    var lc = s->as_int(self.nth(s, l, LINK_CHAR))
                    if (s->as_int(self.nth(s, l, LINK_LINE)) == line) && (lc <= ch)
                        && (ch <= (lc + s->as_int(self.nth(s, l, LINK_LEN)))) {
                        var lw = JsonWriter()
                        lw.begin_object()
                        lw.field(K_URI, self.uri_of(s->str(self.nth(s, l, LINK_TARGET))))
                        lw.key(K_RANGE)
                        self.write_range(&lw, 0, 0, 0)
                        lw.end_object()
                        self.respond(id, lw.out)
                        return true
                    }

                    l = s->next(l)
                }

                self.respond(id, "null")
                return true
            }

            var dpath = s->str(self.nth(s, s->get(f, SK_FILES), fi))
            var dl = self.shift_out(&sh, ei, dpath, s->as_int(self.nth(s, row, REF_DEF_LINE)))
            if dl < 0 {
                self.respond(id, "null") // declared in the changed middle
                return true
            }

            var w = JsonWriter()
            w.begin_object()
            w.field(K_URI, self.uri_of(dpath))
            w.key(K_RANGE)
            self.write_range(&w, dl, s->as_int(self.nth(s, row, REF_DEF_CHAR)), s->as_int(self.nth(s, row, REF_DEF_LEN)))
            w.end_object()
            self.respond(id, w.out)
            return true
        }

        if method == M_DOCUMENT_HIGHLIGHT {
            var w = JsonWriter()
            w.begin_array()
            if row != JSON_NONE() {
                self.uses(s, f, row, &w, 1, path, "", true, &sh)
            }

            w.end_array()
            self.respond(id, w.out)
            return true
        }

        if method == M_REFERENCES {
            var with_decl = d.get_bool(d.get(params, "context"), "includeDeclaration")
            var w = JsonWriter()
            w.begin_array()
            if row != JSON_NONE() {
                self.uses(s, f, row, &w, 0, "", "", with_decl, &sh)
            }

            w.end_array()
            self.respond(id, w.out)
            return true
        }

        if method == M_RENAME {
            if (row == JSON_NONE()) || self.any_incomplete_index() {
                self.respond(id, "null")
                return true
            }

            var w = JsonWriter()
            w.begin_object()
            w.key(K_CHANGES)
            w.begin_object()
            self.uses(s, f, row, &w, 2, "", d.get_str(params, K_NEW_NAME), true, &sh)
            w.end_object()
            w.end_object()
            self.respond(id, w.out)
            return true
        }

        self.respond_error(id, ERR_METHOD_NOT_FOUND, "method not found: " + method)
        return true
    }
}
