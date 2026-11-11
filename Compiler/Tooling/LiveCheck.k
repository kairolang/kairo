/// --- The Kairo Project -------------------------- Tooling/LiveCheck.k --- ///
///
///   \brief One entry point, checked and kept: the API a process that stays
///          up calls when a file of the graph changes
///          (Compiler/Spec/IncrementalSema.md, phase 4).
///
///   check() type-checks the entry's graph. replace_file(path) says that
///   file's text changed (on disk, or through set_overlay) and brings the
///   result up to date. After either, the diagnostics are per file, as
///   objects (file_diags()), and flush() prints them as `kairo` would.
///
///   TODAY EVERY replace_file IS A FULL CHECK in a new CompilerInstance:
///   \c mode is always "full" and \c why says so. That is the fallback the
///   design keeps for whatever cannot be retracted soundly, made the only
///   path, so the API and its oracle (--incr-replay, and
///   Scripts/incr_replay_check.py which compares every step with a clean
///   run) exist before any reuse does. A step that re-checks in place has to
///   pass the same oracle; \c mode is where it will say what it did.
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
ffi "c++" import "vector"

ffi "c++" import "cstdio"
ffi "c++" import "Native/KShims.hh"
ffi "c++" import "llvm/ADT/STLExtras.h"

import Diagnostic::Diagnostic::Diagnostic
import Diagnostic::FileDiagnostics::FileDiagConsumer
import Diagnostic::Severity::DiagSeverity
import Driver::CompilerInstance::CompilerInstance
import Driver::FrontendAction::FrontendAction
import Driver::TUStage::TUStage
import Resolution::ModulePath::ModulePath
import Support::FileIO::Path::Path
import Tooling::ParseAPI::{
    _apply_stop_at,
    release_all,
}
import std::io

pub class LiveCheck {
    /// What the last check() / replace_file() did: "full" (every file
    /// checked, in a new CompilerInstance) is the only mode there is.
    pub var mode: string = ""
    pub var why:  string = ""
    /// The last step's counts.
    pub var errors:   u32   = 0
    pub var warnings: u32   = 0
    pub var files:    usize = 0
    /// Name the entry as the driver does (its module path under the -I
    /// roots), so a result equals `kairo`'s. kals checks a pathless entry
    /// and sets this false.
    pub var as_module: bool = true
    /// Re-check in place where it is sound: the edited file and every
    /// file that imports it, however far (the refresh set), against the
    /// rest of the graph as it stands. Off, every replace_file is a full
    /// check. \c mode is then "refresh" and \c why the set's size; an edit
    /// that cannot be re-checked in place is still "full", with the reason.
    pub var in_place: bool = false
    /// The last refresh's registry retraction: instances dropped (they
    /// named a declaration of the set) and re-armed (made live by the set).
    pub var dropped_instances: usize = 0
    pub var rearmed_instances: usize = 0
    /// Refuse to re-check in place when a kept C++ template instance was
    /// filled on behalf of a file of the refresh set: the fill runs once,
    /// for that file, and is not run again. Sound, and on a graph that
    /// uses C++ containers nearly every edit is then a full check. Off,
    /// such edits are re-checked in place, which the oracle has shown
    /// WRONG once (Compiler/Spec/IncrementalSema.md, "Known wrong result"):
    /// a tool that cannot run the oracle sets this.
    pub var strict_cxx: bool = false
    /// Kept C++ template shells the last refresh found filled for the set.
    pub var fills_owned: usize = 0
    /// More about why the last step was a full check, when there is more
    /// (which instance moved): for a log, not part of \c why.
    pub var detail: string = ""
    /// When set, the next step writes --dump-interface there.
    pub var dump_interface: string = ""

    priv var _words:   cxx::std::vector<string>
    priv var _ci:      unsafe *CompilerInstance = &null
    priv var _fd:      unsafe *FileDiagConsumer = &null
    priv var _action:  unsafe *FrontendAction   = &null
    priv var _pre:     usize                    = 0 ///< console diagnostics from before the check
    priv var _ov_path: cxx::std::vector<string>
    priv var _ov_text: cxx::std::vector<string>

    /// \param words  the compile command without its program name: the entry
    ///               and its flags. --type-check-only is added.
    pub fn LiveCheck(self, const words: cxx::std::vector<string>) {
        self._words = words
        self._words.push_back("--type-check-only")
    }

    @copy fn LiveCheck(self, const other: Self) = delete

    fn op finally (self) {
        self._drop()
    }

    /// The first check of the entry's graph.
    pub fn check(self) -> bool {
        return self._full("the first check")
    }

    /// \p path's text changed. false when the command line was refused or
    /// names no entry; the diagnostics say which.
    pub fn replace_file(self, const path: string) -> bool {
        var why = "re-checking in place is not built"
        self.detail = ""
        if self.in_place {
            why = "no live check"
            if self._ci != &null && self._action != &null {
                why = self._refresh(path)
            }
        }

        if !why.empty() {
            return self._full(why)
        }

        self.mode = "refresh"
        self._count()
        return true
    }

    /// The files of an import edge list, as fids, sorted.
    priv fn _imports_of(self, fid: u32) -> cxx::std::vector<u32> {
        var out = cxx::std::vector<u32>()
        var unsafe *ctx = self._ci->global_scope()->get_context(fid)
        if ctx == &null || ctx->tu == &null {
            return out
        }

        for var i: usize = 0; i < ctx->tu->import_edges.size(); ++i {
            var unsafe *e = ctx->tu->import_edges.get(i)
            // The prelude edge is the driver's (injected when Sema
            // starts), not the text's.
            if e == &null || self._ci->is_foreign_fid(e->target_fid) {
                continue
            }

            if e->decl != &null && e->decl->is_prelude {
                continue
            }

            out.push_back(e->target_fid)
        }

        llvm::sort(out.begin(), out.end())
        return out
    }

    /// Re-checks \p path's refresh set in place. "" when done (\c why then
    /// says how many files); otherwise the reason this edit takes a full
    /// check, with the instance possibly left half-refreshed: the caller
    /// replaces it.
    priv fn _refresh(self, const path: string) -> string {
        var format = self._ci->invocation()->diag.format
        if format != "basic" && format != "json" {
            return "the pretty renderer coalesces across files"
        }

        if self._ci->invocation()->pp.prelude_path.size() > 0 || self._ci->invocation()->pp.force_includes.size() > 0 {
            return "--prelude or --force-include"
        }

        var fid = self._ci->sm()->find_fid(Path(path))
        if fid == u32::MAX {
            return "not a checked file of the graph"
        }

        var unsafe *ctx = self._ci->global_scope()->get_context(fid)
        if ctx == &null || ctx->tu == &null {
            return "not a checked file of the graph"
        }

        if self._ci->is_foreign_fid(fid) {
            return "a C or C++ header"
        }

        // The refresh set: the file and every file that imports it,
        // however far. Nothing outside it points into it.
        var set = cxx::std::vector<u32>()
        set.push_back(fid)
        for var d: u32 in self._ci->transitive_importers(fid) {
            set.push_back(d)
        }

        // A file whose record a file of the set extends sees the
        // extension without importing it: it joins, with its importers.
        var more = true
        while more {
            more = false
            var extra = cxx::std::vector<u32>()
            self._action->refresh_extends(set, &extra)
            for var x: u32 in extra {
                var add = self._ci->transitive_importers(x)
                add.push_back(x)
                for var a: u32 in add {
                    var have = false
                    for var f: u32 in set {
                        if f == a {
                            have = true
                        }
                    }

                    if !have {
                        set.push_back(a)
                        more = true
                    }
                }
            }
        }

        var blocked = self._action->refresh_blocker(set)
        if !blocked.empty() {
            return blocked
        }

        for var f: u32 in set {
            if self._ci->global_scope()->is_builtin_fid(f) {
                return "a builtin file"
            }
        }

        // A diagnostic of one of the files that no Sema drain delivered
        // (the preprocessor's, the parser's) has no owner to replace it by.
        var names = cxx::std::vector<string>()
        for var f: u32 in set {
            names.push_back(self._ci->sm()->get_filename(f))
        }

        for var i: usize = 0; i < self._fd->diags.size(); ++i {
            var unsafe *d = self._fd->diags[i]
            if !d->has_loc {
                continue
            }

            var at     = self._ci->sm()->get_filename(d->loc)
            var inside = false
            for var n: string in names {
                if n == at {
                    inside = true
                }
            }

            if self._fd->owners[i].empty() {
                if inside {
                    return "a diagnostic from before Sema"
                }

                continue
            }

            // A diagnostic a file of the set owns that is located outside
            // the set came out of an instance it was first to name. The
            // instance stays checked, so a re-check would not report it
            // again.
            var mine = false
            for var n: string in names {
                if n == self._fd->owners[i] {
                    mine = true
                }
            }

            if mine && !inside {
                return "a diagnostic from inside an instance"
            }
        }

        var old_imports = cxx::std::vector<cxx::std::vector<u32>>()
        var old_headers = cxx::std::vector<unsafe *void>()
        var mods        = cxx::std::vector<ModulePath>()
        for var f: u32 in set {
            old_headers.push_back(self._action->header_set_of(f))
            old_imports.push_back(self._imports_of(f))
            mods.push_back(self._ci->global_scope()->get_context(f)->module_base)
        }

        // The files' diagnostics go with their trees.
        var kd = cxx::std::vector<unsafe *Diagnostic>()
        var ko = cxx::std::vector<string>()
        for var i: usize = 0; i < self._fd->diags.size(); ++i {
            var mine = false
            for var n: string in names {
                if n == self._fd->owners[i] {
                    mine = true
                }
            }

            if !mine {
                kd.push_back(self._fd->diags[i])
                ko.push_back(self._fd->owners[i])
            }
        }

        self._fd->diags  = kd
        self._fd->owners = ko
        var n0 = self._fd->diags.size()

        // The engine forgets the files too: its duplicate filter, its
        // counts, and the poison scopes inside them.
        var scopes = self._ci->diag()->poison_scopes()
        var keep   = cxx::std::vector<u8>()
        for var i: usize = 0; i < scopes.size(); ++i {
            var at     = self._ci->sm()->get_filename(scopes[i].start)
            var inside = false
            for var n: string in names {
                if n == at {
                    inside = true
                }
            }

            keep.push_back(if (inside) => (0 as u8) else => (1 as u8))
        }

        self._ci->diag()->begin_recheck(&kd, &keep)

        // Out of the instantiation registry, while the old trees can
        // still say which declarations are theirs.
        var rs = self._action->retract(set)
        self.dropped_instances = rs.dropped
        self.rearmed_instances = rs.rearmed
        self.fills_owned = rs.fills_owned
        if self.strict_cxx && rs.fills_owned > 0 {
            self.detail = f"{rs.fills_owned} such instances"
            return "a C++ template instance was first filled for an edited file"
        }

        // Importers first: no live tree may point into a file being re-read.
        for var i: usize = set.size(); i > 0; --i {
            if !self._ci->detach_for_refresh(set[i - 1]) {
                return "a file could not be re-read"
            }
        }

        for var i: usize = 0; i < set.size(); ++i {
            if !self._ci->pp()->preprocess_one(set[i], mods[i]) {
                return "the preprocessor refused a file"
            }
        }

        // Every hoisted table before any full parse: a file's parser reads
        // those of the files it imports, in whatever order they come here.
        for var i: usize = 0; i < set.size(); ++i {
            self._ci->index_one(set[i])
        }

        for var i: usize = 0; i < set.size(); ++i {
            if !self._ci->parse_one(set[i]) {
                return "a file did not parse"
            }

            var unsafe *nctx = self._ci->global_scope()->get_context(set[i])
            if nctx == &null || nctx->tu == &null {
                return "a file did not parse"
            }

            nctx->diag_sink.drain_into(self._ci->diag(), nctx->sm)
        }

        if self._fd->diags.size() != n0 {
            return "a diagnostic from before Sema"
        }

        // Another list of C or C++ headers is another header set, which
        // this instance never parsed.
        for var i: usize = 0; i < set.size(); ++i {
            if self._action->header_set_of(set[i]) != old_headers[i] {
                return "a C or C++ import was added or removed"
            }
        }

        for var i: usize = 0; i < set.size(); ++i {
            var now = self._imports_of(set[i])
            if now.size() != old_imports[i].size() || self._ci->unresolved_import_count(set[i]) > 0 {
                return "an import was added or removed"
            }

            for var k: usize = 0; k < now.size(); ++k {
                if now[k] != old_imports[i][k] {
                    return "an import was added or removed"
                }
            }
        }

        if !self.dump_interface.empty() {
            self._ci->invocation()->frontend.dump_interface = self.dump_interface
        }

        var moved = self._action->refresh(set)
        if !moved.empty() {
            self.detail = self._action->refresh_detail
            return moved
        }

        self.why = f"{set.size()} of {self.files} files"
        return ""
    }

    /// The counts of the result as it stands, from the per-file list.
    priv fn _count(self) {
        self.errors   = 0
        self.warnings = 0
        for var i: usize = 0; i < self._fd->diags.size(); ++i {
            var sev = self._fd->diags[i]->code.severity()
            if sev == DiagSeverity::Error || sev == DiagSeverity::Fatal {
                self.errors += 1
            } else if sev == DiagSeverity::Warning {
                self.warnings += 1
            }
        }
    }

    /// The bytes to read wherever \p path would be read, from the next
    /// check() or replace_file() on.
    pub fn set_overlay(self, const path: string, const text: string) {
        for var i: usize = 0; i < self._ov_path.size(); ++i {
            if self._ov_path[i] == path {
                self._ov_text[i] = text
                return
            }
        }

        self._ov_path.push_back(path)
        self._ov_text.push_back(text)
    }

    /// The live instance; null before check() and after a refused command.
    pub fn ci(self) -> unsafe *CompilerInstance {
        return self._ci
    }

    /// Every diagnostic of the current result with its owning file. The
    /// objects die with the next check() / replace_file().
    pub fn file_diags(self) -> unsafe *FileDiagConsumer {
        return self._fd
    }

    /// Prints the current result's diagnostics as `kairo` does at its end.
    pub fn flush(self) {
        if self._ci == &null {
            return
        }

        if self.mode == "full" {
            self._ci->flush_errors()
            return
        }

        // After a refresh the console consumer still holds the replaced
        // files' old diagnostics: the per-file list is the result, printed
        // as a run delivers it: what the instance reported while it was
        // set up, the driver's own, then each file's in the order the files
        // were first drained.
        io::eprint(f"{self._ci->incr_diag_text(0, self._pre)}")
        for var i: usize = 0; i < self._fd->diags.size(); ++i {
            if self._fd->owners[i].empty() {
                io::eprint(f"{self._ci->incr_render(self._fd->diags[i])}")
            }
        }

        for var k: usize = 0; k < self._fd->order.size(); ++k {
            for var i: usize = 0; i < self._fd->diags.size(); ++i {
                if self._fd->owners[i] == self._fd->order[k] {
                    io::eprint(f"{self._ci->incr_render(self._fd->diags[i])}")
                }
            }
        }

        cxx::std::fflush(kairo::std_err())
    }

    priv fn _drop(self) {
        if self._ci == &null {
            return
        }

        if self._fd != &null {
            self._ci->diag()->remove_consumer(self._fd)
        }

        if self._action != &null {
            kairo::std::destroy(self._action)
            self._action = &null
        }

        // A check that stops at Sema never reaches the driver's header
        // release (FrontendAction::run does it before codegen), and the
        // instance's end does not free the sets' clang ASTs.
        if self._ci->headers() != &null {
            self._ci->headers()->release_all()
        }

        // Every tree, token run and buffer the check made: nothing else
        // reclaims them before the instance dies, and its end leaves some.
        release_all(self._ci, TUStage::Lexing)
        self._ci->diag()->clear_retained()
        kairo::std::destroy(self._ci)
        self._ci = &null
        if self._fd != &null {
            kairo::std::destroy(self._fd)
            self._fd = &null
        }
    }

    priv fn _full(self, const why: string) -> bool {
        self._drop()
        self.mode     = "full"
        self.why      = why
        self.errors   = 0
        self.warnings = 0
        self.files    = 0
        var words = self._words
        self._ci = kairo::std::create<CompilerInstance>(words)
        if !self._ci->args_ok() {
            return false
        }

        self._ci->initialize(Path::cwd())
        var inputs = self._ci->invocation()->input_files
        if inputs.empty() {
            return false
        }

        // What the instance reported while it was set up (a note about the
        // toolchain) is before the per-file list and is printed before it.
        self._pre = self._ci->incr_diag_count()
        self._fd  = kairo::std::create<FileDiagConsumer>()
        self._ci->diag()->add_consumer(self._fd)
        self._ci->invocation()->frontend.file_diags = unsafe (self._fd as unsafe *void)
        if !self.dump_interface.empty() {
            self._ci->invocation()->frontend.dump_interface = self.dump_interface
        }

        // The source manager keeps a VIEW of an overlay's bytes: they are
        // this object's, and are not touched while the instance lives.
        for var i: usize = 0; i < self._ov_path.size(); ++i {
            var unsafe *bytes = unsafe ((self._ov_text[i].raw() as unsafe *const u8) as kairo::std::ConstPtr<u8>)
            self._ci->sm()->load_overlay(Path(self._ov_path[i]), bytes, self._ov_text[i].size())
        }

        // parse_file's steps, with the action kept: a refresh runs Sema
        // again through it.
        self._ci->invocation()->frontend.live_check = true
        // The interface facts of every file: a refresh compares a re-read
        // record's layout with the one it had (FrontendAction::refresh).
        self._ci->invocation()->frontend.incremental_sema = true
        _apply_stop_at(self._ci, TUStage::Sema)
        var mp = ModulePath()
        if self.as_module {
            mp = self._ci->input_module_path(Path(inputs[0]).full_path())
        }

        self._action = kairo::std::create<FrontendAction>(
            Path(inputs[0]),
            mp,
            self._ci->global_scope(),
            self._ci->imp(),
            self._ci,
        )

        self._action->run()
        self.errors   = self._ci->diag()->error_count()
        self.warnings = self._ci->diag()->warn_count()
        self.files    = self._action->fids().size()
        return true
    }
}
