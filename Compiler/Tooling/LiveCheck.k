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

import Diagnostic::FileDiagnostics::FileDiagConsumer
import Driver::CompilerInstance::CompilerInstance
import Driver::TUStage::TUStage
import Support::FileIO::Path::Path
import Tooling::ParseAPI::{
    ParseOptions,
    parse_file,
    release_all,
}

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
    /// When set, the next step writes --dump-interface there.
    pub var dump_interface: string = ""

    priv var _words:   cxx::std::vector<string>
    priv var _ci:      unsafe *CompilerInstance = &null
    priv var _fd:      unsafe *FileDiagConsumer = &null
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
        return self._full("re-checking in place is not built")
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
        if self._ci != &null {
            self._ci->flush_errors()
        }
    }

    priv fn _drop(self) {
        if self._ci == &null {
            return
        }

        if self._fd != &null {
            self._ci->diag()->remove_consumer(self._fd)
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

        self._fd = kairo::std::create<FileDiagConsumer>()
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

        var opts = ParseOptions{}
        opts.stop_at       = TUStage::Sema
        opts.capture_diags = false
        opts.as_module     = self.as_module
        var unit = parse_file(self._ci, Path(inputs[0]), opts)
        self.errors   = self._ci->diag()->error_count()
        self.warnings = self._ci->diag()->warn_count()
        self.files    = unit.fids.size()
        return true
    }
}
