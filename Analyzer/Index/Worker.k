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
import Index::Indexer::{
    FileText,
    IndexWalker,
}
import Json::JsonWriter
import Location::SourceLocation::SourceLocation
import Location::SourceManager::SourceManager
import Location::SourceRange::SourceRange
import Sema::SemaContext::SemaContext
import Support::FileIO::Path::Path
import Tooling::ParseAPI::{
    ParseOptions,
    parse_file,
}
import Tooling::SemaObserver::SemaObserver

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

    priv var mu_: kairo::std::Mutex

    pub fn IndexObserver(self) = default

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
        if (sc == &null) || (sc->ctx == &null) || (sc->tu == &null) {
            return
        }

        var fid  = sc->ctx->fid
        var path = sc->ctx->sm->get_filename(fid)
        var named = self.is_named_(path)
        if (!named) && (self.root.empty() || (!path.starts_with(self.root))) {
            return
        }

        var walker = IndexWalker(sc)
        walker.run(fid)

        var w = JsonWriter()
        walker.write(&w)

        var lock = kairo::std::LockGuard(self.mu_)
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

/// Above this many files in the import graph, only the editor's open buffers
/// are indexed. References and rename then cover the open files only: the
/// alternative is a snapshot of every file of a large tree on every pause in
/// typing, most of it never asked about.
pub fn WIDE_INDEX_LIMIT() -> usize {
    return 96
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
    priv fn range_(self, w: *JsonWriter, r: SourceRange) -> usize {
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
        if eo == so {
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
            var fi = self.range_(&rw, d->fixits[i].range)
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
            lsp = 1
        } else if sev == DiagSeverity::Warning {
            lsp = 2
        } else if sev == DiagSeverity::Remark {
            lsp = 3
        } else if sev == DiagSeverity::Note {
            lsp = 4
        } else {
            return
        }

        var w = JsonWriter()
        w.begin_object()

        var path: string = ""
        var dw = JsonWriter()
        dw.begin_object()
        if diag->has_loc && diag->loc.is_valid() {
            var rw = JsonWriter()
            var fi = self.range_(&rw, self.span_(diag))
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
                var fi = self.range_(&rw, self.span_(c))
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

/// \brief the worker's whole run. \p args is argv past `--worker`.
pub fn worker_main(@inout args: [string]) -> i32 {
    if args.size() < 1 {
        return 2
    }

    var out_path = args[0]
    var root: string = ""
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

    observer->root  = root
    observer->named = real

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

    var opts = ParseOptions{}
    opts.stop_at       = TUStage::Sema
    opts.capture_diags = false
    var unit = parse_file(ci, Path(inputs[0]), opts)

    ci->diag()->restore_consumers(saved)

    var w = JsonWriter()
    w.begin_object()
    w.field_bool("ok", true)
    var files = observer->out
    var wide  = unit.fids.size() <= WIDE_INDEX_LIMIT()
    if wide && (observer->rest_count > 0) {
        if observer->count > 0 {
            files += ","
        }

        files += observer->rest
    }

    w.field_raw("files", "[" + files + "]")
    w.field_bool("wide", wide)
    w.field_raw("diagnostics", "[" + collector->out + "]")
    w.key("deps")
    w.begin_array()
    for var k: usize = 0; k < unit.fids.size(); ++k {
        w.str(ci->sm()->get_filename(unit.fids[k]))
    }

    w.end_array()
    w.end_object()

    if !LinkFS::write(out_path, w.out) {
        return 1
    }

    return 0
}
