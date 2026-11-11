/// --- The Kairo Project ---------------------- Analyzer/Index/Worker.k --- ///
///
///   `kals --worker`: one analysis of one entry point, as a process.
///
///   The server never runs the compiler in its own address space. A language
///   server spends its life on half-typed code, which is where a compiler's
///   remaining crashes live, and a crash here must cost one stale answer, not
///   the editor's connection. So analysis is a child process: it type-checks
///   the entry with the editor's unsaved buffers laid over the disk, writes
///   ONE JSON document, and exits. If it dies, the server keeps the previous
///   answer.
///
///   Command line:
///
///     kals --worker <out.json> [--cwd <dir>] [--root <dir>] [--overlay <real> <tmp>]...
///          -- <kairo arguments, entry file included>
///
///   Output (one object):
///
///     { "ok": true,
///       "files":       [ <Indexer.k's object per indexed file> ],
///       "wide":        false when the graph was too large to index every
///                      file under --root (only the overlaid buffers are in
///                      "files" then),
///       "diagnostics": [ { "path", "diag": <LSP Diagnostic>,
///                          "fixes": [ { "title", "edits": [ { "path", "range", "newText" } ] } ] } ],
///       "deps":        [ every file the compile read ] }
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
ffi "c++" import "string"
ffi "c++" import "vector"
ffi "c++" import "chrono"
ffi "c++" import "cstdlib"
ffi "c++" import "cstring"
ffi "c++" import "thread"

import API::FS::LinkFS
import Diagnostic::Consumer::DiagConsumer
import Diagnostic::Diagnostic::{
    Diagnostic,
    DiagLabel,
    FixKind,
}
import Diagnostic::Severity::DiagSeverity
import DocumentStore::{
    LineMap,
    path_to_uri,
}
import Driver::CompilerInstance::CompilerInstance
import Driver::TUStage::TUStage
import Index::Snapshot::FileText
import Index::Indexer::IndexWalker
import Index::Tokens::lexical_tokens
import Protocol::*
import Tuning::WIDE_INDEX_LIMIT
import Json::{
    JsonDoc,
    JsonWriter,
}
import JsonRpc::Transport
import Location::SourceLocation::SourceLocation
import Location::SourceManager::SourceManager
import Location::SourceRange::SourceRange
import Resolution::ModulePath::ModulePath
import Sema::SemaContext::SemaContext
import Support::FileIO::Path::Path
import Tooling::ParseAPI::{
    ParseOptions,
    parse_file,
}
import Tooling::SemaObserver::SemaObserver

fn worker_us() -> i64 {
    var t = cxx::std::chrono::steady_clock::now()
    var d = cxx::std::chrono::duration_cast<cxx::std::chrono::microseconds>(t.time_since_epoch())
    return d.count() as i64
}

/// \class IndexObserver
/// \brief runs the indexer over each wanted TU as Sema finishes checking it.
pub class IndexObserver derives SemaObserver {
    /// Files to index: an absolute path prefix, and paths named outright (the
    /// editor's open buffers). Everything else in the graph, the standard
    /// library above all, is only ever a jump TARGET and needs no index.
    pub var root:  string = ""
    pub var named: [string]

    /// The files' objects, comma-joined: Sema may check TUs on several
    /// threads, so each walk renders to its own writer and appends under the
    /// lock.
    pub var out:   string = ""
    pub var count: usize  = 0

    /// The same, for files indexed only because they are under `root`. Kept
    /// apart so the run can drop them once it knows how large the graph is.
    pub var rest:       string = ""
    pub var rest_count: usize  = 0

    /// `--progress <file>`: every TU Sema finishes checking is counted
    /// into it (the server reads it for its progress report).
    pub var progress: string = ""
    pub var checked:  usize  = 0

    /// Phase timers (section 11, scenario 3): microseconds in the walker and
    /// in rendering its rows, summed over TUs (threads add up).
    pub var walk_us:  i64 = 0
    pub var write_us: i64 = 0

    priv var mu_: kairo::std::Mutex

    /// Walked at on_checked, written at on_lowered (or by flush).
    priv var held_: [unsafe *IndexWalker]

    pub fn IndexObserver(self) = default

    priv fn count_(self) {
        if self.progress.empty() {
            return
        }

        var lock = kairo::std::LockGuard(self.mu_)
        self.checked += 1
        LinkFS::write(self.progress, f"{self.checked}\n")
    }

    priv fn is_named_(self, const path: string) -> bool {
        for var i: usize = 0; i < self.named.size(); ++i {
            if self.named[i] == path {
                return true
            }
        }

        return false
    }

    /* OVERRIDE */
    pub fn on_checked(self, sc: unsafe *SemaContext) {
        self.count_()
        if (sc == &null) || (sc->ctx == &null) || (sc->tu == &null) {
            return
        }

        var fid  = sc->ctx->fid
        var path = sc->ctx->sm->get_filename(fid)
        var named = self.is_named_(path)
        if (!named) && (self.root.empty() || (!path.starts_with(self.root))) {
            return
        }

        var t0 = worker_us()
        var unsafe *walker = kairo::std::create<IndexWalker>(sc)
        walker->run(fid)
        walker->named_ = named
        var t1 = worker_us()

        // Held until on_lowered: a type's size is the compiler's layout
        // query, and an ADT has no layout before EnumLayoutLowering builds
        // it (Hovers.k, fill_layouts_).
        var lock = kairo::std::LockGuard(self.mu_)
        self.walk_us += t1 - t0
        self.held_.push_back(walker)
    }

    /* OVERRIDE */
    pub fn on_lowered(self, sc: unsafe *SemaContext) {
        var walker: unsafe *IndexWalker = &null
        {
            var lock = kairo::std::LockGuard(self.mu_)
            for var i: usize = 0; i < self.held_.size(); ++i {
                if self.held_[i]->sc == sc {
                    walker = self.held_[i]
                    self.held_[i] = self.held_[self.held_.size() - 1]
                    self.held_.pop_back()
                    break
                }
            }
        }

        if walker == &null {
            return
        }

        walker->fill_layouts_()
        self.finish_(walker)
    }

    /// Whatever on_lowered never got back (a run that stopped between the
    /// two calls): written without the layout lines, after the compile.
    pub fn flush(self) {
        while !self.held_.empty() {
            var unsafe *walker = self.held_[self.held_.size() - 1]
            self.held_.pop_back()
            walker->sc = &null
            self.finish_(walker)
        }
    }

    priv fn finish_(self, walker: unsafe *IndexWalker) {
        var t1 = worker_us()
        var w = JsonWriter()
        walker->write(&w)
        var named = walker->named_
        kairo::std::destroy(walker)
        var t2 = worker_us()

        var lock = kairo::std::LockGuard(self.mu_)
        self.write_us += t2 - t1
        if named {
            if self.count > 0 {
                self.out += ","
            }

            self.out   += w.out
            self.count += 1
        } else {
            if self.rest_count > 0 {
                self.rest += ","
            }

            self.rest       += w.out
            self.rest_count += 1
        }
    }
}

/// \class DiagCollector
/// \brief every diagnostic of the run, rendered as LSP JSON as it arrives.
///
/// \details ToolDiagConsumer keeps a line and a column; an editor needs the
///          range, the notes as related locations, and the fix-its as edits,
///          so this reads the Diagnostic itself.
pub class DiagCollector derives DiagConsumer {
    pub var out:   string = ""
    pub var count: usize  = 0

    /// The syntax-only pass: keep only what the parser reports (`S<n>`,
    /// not `SC<n>`) and fatals; anything else a one-file parse says (an
    /// import it did not resolve) is not about the text. `errors` counts
    /// the kept errors: none means the buffer parses.
    pub var syntax_only: bool  = false
    pub var errors:      usize = 0

    priv var sm_:    unsafe *SourceManager
    priv var files_: [FileText]

    pub fn DiagCollector(self, sm: unsafe *SourceManager) {
        self.sm_ = sm
    }

    priv fn file_(self, fid: u32) -> usize {
        for var i: usize = 0; i < self.files_.size(); ++i {
            if self.files_[i].fid == fid {
                return i
            }
        }

        var f = FileText()
        f.fid  = fid
        f.path = self.sm_->get_filename(fid)
        var size = self.sm_->get_file_size(fid)
        if size > 0 {
            // The raw bytes. get_text() decodes UTF-8 and keeps one byte per
            // code point (P800), which both corrupts the text and shifts
            // every offset after the first non-ASCII character.
            var view = self.sm_->get_view(self.sm_->get_range(fid, 0, size))
            f.text = string(unsafe ((view.data() as unsafe *const u8) as *const u8), view.size())
        }

        f.lines.build(f.text)
        self.files_.push_back(f)
        return self.files_.size() - 1
    }

    /// Writes an LSP range for \p r and returns its file's index.
    ///
    /// \p widen: a zero-width range becomes the character it points at, for
    /// a range that is DRAWN. Never for an edit: widened, an insertion
    /// replaced the character after it (`const ther` for `const other`, P860).
    priv fn range_(self, w: *JsonWriter, r: SourceRange, widen: bool) -> usize {
        var a  = self.sm_->resolve(r.start)
        var fi = self.file_(a.fid as u32)
        var so = a.offset as usize
        var eo = so
        if r.end.is_valid() && (r.end.raw() >= r.start.raw()) {
            eo = so + ((r.end.raw() - r.start.raw()) as usize)
        }

        if eo > self.files_[fi].text.size() {
            eo = self.files_[fi].text.size()
        }

        if so > eo {
            so = eo
        }

        // A zero-width range draws nothing in most editors: widen it to the
        // character it points at, staying on the line.
        if widen && (eo == so) {
            var line = self.files_[fi].lines.line_of(so)
            if so < self.files_[fi].lines.line_end(self.files_[fi].text, line) {
                eo = so + 1
            }
        }

        w->begin_object()
        w->key("start")
        w->begin_object()
        w->field_uint("line", self.files_[fi].lines.line_of(so))
        w->field_uint("character", self.files_[fi].lines.character(self.files_[fi].text, so, false))
        w->end_object()
        w->key("end")
        w->begin_object()
        w->field_uint("line", self.files_[fi].lines.line_of(eo))
        w->field_uint("character", self.files_[fi].lines.character(self.files_[fi].text, eo, false))
        w->end_object()
        w->end_object()
        return fi
    }

    /// The span a diagnostic underlines: its primary label when it has one,
    /// else the point it was reported at.
    priv fn span_(self, d: unsafe *Diagnostic) -> SourceRange {
        for var i: usize = 0; i < d->labels.size(); ++i {
            if (d->labels[i].style == DiagLabel::Style::Primary) && d->labels[i].range.start.is_valid() {
                return d->labels[i].range
            }
        }

        var r = SourceRange::invalid()
        r.start = d->loc
        r.end   = d->loc
        return r
    }

    priv fn fixes_(self, w: *JsonWriter, d: unsafe *Diagnostic) {
        for var i: usize = 0; i < d->fixits.size(); ++i {
            // A message-only fix-it is advice, not an edit: nothing to apply.
            if !d->fixits[i].range.start.is_valid() {
                continue
            }

            w->begin_object()
            var title = d->fixits[i].message
            if title.empty() {
                title = "apply fix"
            }

            w->field("title", title)
            w->key("edits")
            w->begin_array()
            w->begin_object()
            var rw = JsonWriter()
            var fi = self.range_(&rw, d->fixits[i].range, false)
            w->field("path", self.files_[fi].path)
            w->field_raw("range", rw.out)
            w->field("newText", d->fixits[i].replacement)
            w->end_object()
            w->end_array()
            w->end_object()
        }

        for var i: usize = 0; i < d->children.size(); ++i {
            if d->children[i] != &null {
                self.fixes_(w, d->children[i])
            }
        }
    }

    /* OVERRIDE */
    pub fn handle(self, diag: unsafe *Diagnostic) {
        if diag == &null {
            return
        }

        var sev = diag->code.severity()
        var lsp: usize = 0
        if (sev == DiagSeverity::Error) || (sev == DiagSeverity::Fatal) {
            lsp = DS_ERROR
        } else if sev == DiagSeverity::Warning {
            lsp = DS_WARNING
        } else if sev == DiagSeverity::Remark {
            lsp = DS_INFORMATION
        } else if sev == DiagSeverity::Note {
            lsp = DS_HINT
        } else {
            return
        }

        if self.syntax_only {
            var code = diag->code as string
            var syn = (code.size() > 1) && (code[0] == 83) && (code[1] != 67)
            if (!syn) && (sev != DiagSeverity::Fatal) {
                return
            }

            if lsp == 1 {
                self.errors += 1
            }
        }

        var w = JsonWriter()
        w.begin_object()

        var path: string = ""
        var dw = JsonWriter()
        dw.begin_object()
        if diag->has_loc && diag->loc.is_valid() {
            var rw = JsonWriter()
            var fi = self.range_(&rw, self.span_(diag), true)
            path = self.files_[fi].path
            dw.field_raw("range", rw.out)
        } else {
            // No location (a bad flag, a missing root): the editor still has
            // to show it somewhere, and the top of the entry is that place.
            dw.field_raw(
                "range",
                "{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}}",
            )
        }

        dw.field_uint("severity", lsp)
        dw.field("code", diag->code as string)
        dw.field("source", "kairo")

        var msg = diag->message
        var related = JsonWriter()
        related.begin_array()
        var nrel: usize = 0
        for var i: usize = 0; i < diag->children.size(); ++i {
            var unsafe *c = diag->children[i]
            if c == &null {
                continue
            }

            if c->has_loc && c->loc.is_valid() {
                related.begin_object()
                var rw = JsonWriter()
                var fi = self.range_(&rw, self.span_(c), true)
                related.key("location")
                related.begin_object()
                related.field("uri", path_to_uri(self.files_[fi].path))
                related.field_raw("range", rw.out)
                related.end_object()
                related.field("message", c->message)
                related.end_object()
                nrel += 1
            } else {
                msg += "\nnote: "
                msg += c->message
            }
        }

        related.end_array()

        // A label's text is the short "this is what is wrong here" line the
        // terminal prints under the caret; an editor has no caret line, so
        // it joins the message.
        for var i: usize = 0; i < diag->labels.size(); ++i {
            if (diag->labels[i].style == DiagLabel::Style::Primary) && (!diag->labels[i].text.empty()) {
                msg += "\n"
                msg += diag->labels[i].text
                break
            }
        }

        dw.field("message", msg)
        if nrel > 0 {
            dw.field_raw("relatedInformation", related.out)
        }

        dw.end_object()

        w.field("path", path)
        w.field_raw("diag", dw.out)
        w.key("fixes")
        w.begin_array()
        self.fixes_(&w, diag)
        w.end_array()
        w.end_object()

        if self.count > 0 {
            self.out += ","
        }

        self.out   += w.out
        self.count += 1
    }
}

fn worker_fail(const out_path: string, const why: string) -> i32 {
    var w = JsonWriter()
    w.begin_object()
    w.field_bool("ok", false)
    w.field("error", why)
    w.end_object()
    LinkFS::write(out_path, w.out)
    return 1
}

/// `kals --worker <out> --syntax-only <file> ...`: \p file parsed on its own,
/// with its buffer overlaid. No import is resolved and nothing is checked,
/// so this costs one file's lex, preprocess and parse; its answer is the
/// parser's diagnostics, whether the text parses, and the lexical tokens
/// (keywords, literals, comments) for an editor to draw while it does not.
///
///   { "ok": true, "parsed": bool, "diagnostics": [ as above ], "tokens": [ ... ] }
fn syntax_main(const out_path: string,
               const file:     string,
               real:           *const [string],
               tmps:           *const [string],
               @inout words:   cxx::std::vector<string>) -> i32 {
    var held: [string]
    held.reserve(real->size())
    var named: [string]
    for var k: usize = 0; k < real->size(); ++k {
        var text: string = ""
        if !LinkFS::read((*tmps)[k], &text) {
            continue
        }

        held.push_back(text)
        named.push_back((*real)[k])
    }

    var out = syntax_answer(file, &named, &held, &words)
    if !LinkFS::write(out_path, out) {
        return 1
    }

    return 0
}

/// One syntax pass, as the JSON `syntax_main` writes: \p file parsed with
/// each of \p real overlaid by the text beside it in \p texts. A fresh
/// CompilerInstance per pass, so a long-lived caller (the syntax server)
/// carries nothing from one buffer to the next.
fn syntax_answer(const file:   string,
                 real:         *const [string],
                 texts:        *const [string],
                 @inout words: cxx::std::vector<string>) -> string {
    var unsafe *ci = kairo::std::create<CompilerInstance>(words)
    finally {
        kairo::std::destroy(ci)
    }

    var unsafe *collector = kairo::std::create<DiagCollector>(ci->sm())
    finally {
        kairo::std::destroy(collector)
    }

    collector->syntax_only = true
    if !ci->args_ok() {
        return fail_json("the syntax pass was refused its command line")
    }

    ci->initialize(Path::cwd())
    var saved = ci->diag()->take_consumers()
    ci->diag()->add_consumer(collector)

    // The bytes must outlive the pass: the source manager keeps a view.
    for var k: usize = 0; k < real->size(); ++k {
        var unsafe *bytes = unsafe (((*texts)[k].raw() as unsafe *const u8) as kairo::std::ConstPtr<u8>)
        ci->sm()->load_overlay(Path((*real)[k]), bytes, (*texts)[k].size())
    }

    var fid = ci->sm()->load_file(Path(file))
    if fid == u32::MAX {
        ci->diag()->restore_consumers(saved)
        return fail_json("cannot read " + file)
    }

    // kfmt's single-file path: preprocess this file alone, parse it, and
    // hand the parser's buffered diagnostics to the engine.
    if ci->pp()->preprocess_one(fid, ModulePath()) {
        var unsafe *ctx = ci->global_scope()->get_context(fid)
        if ctx != &null {
            ci->parse_one(fid)
            ctx->diag_sink.drain_into(ci->diag(), ctx->sm)
        }
    }

    ci->diag()->restore_consumers(saved)

    var ft = FileText()
    ft.fid  = fid
    ft.path = file
    var size = ci->sm()->get_file_size(fid)
    if size > 0 {
        var view = ci->sm()->get_view(ci->sm()->get_range(fid, 0, size))
        ft.text = string(unsafe ((view.data() as unsafe *const u8) as *const u8), view.size())
    }

    ft.lines.build(ft.text)

    var w = JsonWriter()
    w.begin_object()
    w.field_bool("ok", true)
    w.field_bool("parsed", collector->errors == 0)
    w.field_raw("diagnostics", "[" + collector->out + "]")
    lexical_tokens(ci->sm(), fid, &ft, &w)
    w.end_object()
    return w.out
}

fn fail_json(const why: string) -> string {
    var w = JsonWriter()
    w.begin_object()
    w.field_bool("ok", false)
    w.field("error", why)
    w.end_object()
    return w.out
}

/// `kals --worker --syntax-server -- [kairo args]`: the syntax pass of
/// section 11 item 2a without a process per keystroke. Requests and answers
/// are LSP-framed JSON (Content-Length) on stdin and stdout, the same
/// Transport the server speaks to the editor:
///
///   in:  { "id": n, "file": path, "text": buffer }
///   out: { "id": n, "ok", "parsed", "diagnostics", "tokens" } as syntax_main
///
/// Requests queued behind the one being parsed are coalesced per file: only
/// the newest buffer of a file is parsed, the older ones are answered
/// `{ "id": n, "superseded": true }` at once. Exits at EOF.
fn syntax_server_main(@inout base: cxx::std::vector<string>) -> i32 {
    var t = Transport()
    while !t.closed {
        if !t.wait(1000) {
            continue
        }

        // Everything already buffered, so a newer buffer of the same file
        // supersedes an older one before either is parsed.
        var ids:   [i64]
        var files: [string]
        var texts: [string]
        while t.wait(0) {
            var d = JsonDoc()
            if !d.parse(t.take()) {
                continue
            }

            var f = d.get_str(d.root, "file")
            for var k: usize = 0; k < files.size(); ++k {
                if (files[k] == f) && (ids[k] >= 0) {
                    var sw = JsonWriter()
                    sw.begin_object()
                    sw.field_int("id", ids[k])
                    sw.field_bool("superseded", true)
                    sw.end_object()
                    t.send(sw.out)
                    ids[k] = -1
                }
            }

            ids.push_back(d.get_int(d.root, "id"))
            files.push_back(f)
            texts.push_back(d.get_str(d.root, "text"))
        }

        for var k: usize = 0; k < files.size(); ++k {
            if ids[k] < 0 {
                continue
            }

            var words: cxx::std::vector<string>
            for var i: usize = 0; i < base.size(); ++i {
                words.push_back(base[i])
            }

            words.push_back(files[k])
            words.push_back("--type-check-only")
            words.push_back("--threads=1")
            var real: [string]
            real.push_back(files[k])
            var txt: [string]
            txt.push_back(texts[k])
            var body = syntax_answer(files[k], &real, &txt, &words)
            var idn = ids[k]
            // `{"id":N,` spliced before the answer's own members.
            var msg: string = "{\"id\":"
            msg += f"{idn}"
            msg += ","
            msg += body.subslice(1, body.size() - 1)
            t.send(msg)
        }
    }

    return 0
}

/// \brief the worker's whole run. \p args is argv past `--worker`.
pub fn worker_main(@inout args: [string]) -> i32 {
    if args.size() < 1 {
        return 2
    }

    if args[0] == "--syntax-server" {
        var base: cxx::std::vector<string>
        var i: usize = 1
        if (i < args.size()) && (args[i] == "--") {
            i += 1
        }

        while i < args.size() {
            base.push_back(args[i])
            i += 1
        }

        return syntax_server_main(&base)
    }

    var out_path = args[0]
    var root: string = ""
    var syntax_file: string = ""
    var progress: string = ""
    var as_module = false
    var real: [string]
    var tmps: [string]
    // The one C++ container in the Analyzer: CompilerInstance's word
    // constructor takes a std::vector, and that signature is the compiler's.
    var words: cxx::std::vector<string>

    var i: usize = 1
    while i < args.size() {
        var a = args[i]
        if a == "--" {
            i += 1
            break
        }

        if (a == "--cwd") && ((i + 1) < args.size()) {
            // Before anything reads a path: the command's relative -I
            // directories and its entry are relative to this.
            Path::set_cwd(args[i + 1])
            i += 2
            continue
        }

        if (a == "--root") && ((i + 1) < args.size()) {
            root = args[i + 1]
            i += 2
            continue
        }

        if (a == "--syntax-only") && ((i + 1) < args.size()) {
            syntax_file = args[i + 1]
            i += 2
            continue
        }

        // The clangd bridge's header job (LanguageServer.md section 15): the
        // file is checked as the module the driver names it, so
        // --emit-headers writes its header, and the snapshot says where.
        if a == "--as-module" {
            as_module = true
            i += 1
            continue
        }

        if (a == "--progress") && ((i + 1) < args.size()) {
            progress = args[i + 1]
            i += 2
            continue
        }

        if (a == "--overlay") && ((i + 2) < args.size()) {
            real.push_back(args[i + 1])
            tmps.push_back(args[i + 2])
            i += 3
            continue
        }

        return worker_fail(out_path, "unknown worker argument: " + a)
    }

    while i < args.size() {
        words.push_back(args[i])
        i += 1
    }

    // An editor never wants an object file out of a keystroke.
    words.push_back("--type-check-only")

    if !syntax_file.empty() {
        // One file has nothing to share out: a thread pool of every core
        // costs more to start and stop (and to schedule on a busy machine)
        // than the parse it would run.
        words.push_back("--threads=1")
        return syntax_main(out_path, syntax_file, &real, &tmps, &words)
    }

    // A test knob: a run that takes at least this long, so a test can order
    // a syntax pass before the run of an older text (smoke.py).
    var unsafe *delay = cxx::std::getenv(r"KALS_DEBUG_INDEX_DELAY_MS")
    if delay != &null {
        var ms = cxx::std::atoi(delay)
        if ms > 0 {
            cxx::std::this_thread::sleep_for(cxx::std::chrono::milliseconds(ms))
        }
    }

    var unsafe *ci = kairo::std::create<CompilerInstance>(words)
    finally {
        kairo::std::destroy(ci)
    }

    var unsafe *collector = kairo::std::create<DiagCollector>(ci->sm())
    var unsafe *observer  = kairo::std::create<IndexObserver>()
    finally {
        kairo::std::destroy(observer)
        kairo::std::destroy(collector)
    }

    if !ci->args_ok() {
        return worker_fail(out_path, "the compile command was rejected: check its flags in kairo_compile.json")
    }

    var inputs = ci->invocation()->input_files
    if inputs.empty() {
        return worker_fail(out_path, "the compile command names no entry file")
    }

    observer->root     = root
    observer->named    = real
    observer->progress = progress

    ci->invocation()->frontend.sema_observer = unsafe (observer as unsafe *void)

    ci->initialize(Path::cwd())

    var saved = ci->diag()->take_consumers()
    ci->diag()->add_consumer(collector)

    // The editor's buffers, over the disk. The bytes must outlive the
    // compile (the source manager keeps a VIEW), so they are held here, in a
    // vector that never grows after this loop.
    var held: [string]
    held.reserve(real.size())
    for var k: usize = 0; k < real.size(); ++k {
        var text: string = ""
        if !LinkFS::read(tmps[k], &text) {
            continue
        }

        held.push_back(text)
        var unsafe *bytes = unsafe ((held[held.size() - 1].raw() as unsafe *const u8) as kairo::std::ConstPtr<u8>)
        ci->sm()->load_overlay(Path(real[k]), bytes, held[held.size() - 1].size())
    }

    var t_run = worker_us()
    var opts = ParseOptions{}
    opts.stop_at       = TUStage::Sema
    opts.capture_diags = false
    opts.as_module     = as_module
    var unit = parse_file(ci, Path(inputs[0]), opts)
    observer->flush()
    var t_parsed = worker_us()

    ci->diag()->restore_consumers(saved)

    var w = JsonWriter()
    w.begin_object()
    w.field_bool("ok", true)
    var files = observer->out
    var wide  = unit.fids.size() <= WIDE_INDEX_LIMIT
    if wide && (observer->rest_count > 0) {
        if observer->count > 0 {
            files += ","
        }

        files += observer->rest
    }

    w.field_raw("files", "[" + files + "]")
    w.field_bool("wide", wide)
    if as_module {
        // Where EmitCXXHeader put the entry's header under --emit-headers:
        // `<module path>.hh` (CXXSpell::header_path).
        var rel: string = ""
        for var seg: string in ci->imp()->input_module_path(Path(inputs[0])) {
            if !rel.empty() {
                rel += "/"
            }

            rel += seg
        }

        w.field("header", rel + ".hh")
        w.field_int("errors", collector->errors as i64)
        // What kcc gives a C++ file that includes this module: the bridge
        // hands it to clangd, which otherwise parses the header's prelude
        // against the host's standard library and none of kcc's roots.
        w.key("cxx_flags")
        w.begin_array()
        for var a: string in ci->cxx_driver_words() {
            w.str(a)
        }

        w.end_array()
    }

    w.field_raw("diagnostics", "[" + collector->out + "]")
    w.key("deps")
    w.begin_array()
    for var k: usize = 0; k < unit.fids.size(); ++k {
        w.str(ci->sm()->get_filename(unit.fids[k]))
    }

    w.end_array()
    // Phase timers: the whole compile (Sema with the walker inside it), the
    // walker's and the row writer's share of it, and the snapshot assembly.
    w.key("timing")
    w.begin_object()
    w.field_int("run_us", t_parsed - t_run)
    w.field_int("walk_us", observer->walk_us)
    w.field_int("write_us", observer->write_us)
    w.field_int("assemble_us", worker_us() - t_parsed)
    w.field_uint("unit_fids", unit.fids.size())
    w.end_object()
    w.end_object()

    if !LinkFS::write(out_path, w.out) {
        return 1
    }

    return 0
}
