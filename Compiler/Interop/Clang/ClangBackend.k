/// --- The Kairo Project ----------------- Interop/Clang/ClangBackend.k --- ///
///
///   Persistent, shared clang backend state for the whole batch.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
///
/// \file  Interop/Clang/ClangBackend.k
/// \brief Owns the ONE clang CompilerInstance shared across all Kairo TUs:
///        invocation, target, FileManager, SourceManager. Kairo fids are
///        mirrored into the clang SM via ClangLocMap straight from the VFM
///        mmaps, and the per-TU diagnostic client is a ClangDiagAdapter.
///
/// \par Lifecycle
///   1. Driver constructs this in initialize() and enqueues startup() on the
///      ThreadPool (group CLANG_STARTUP_GROUP) clang's expensive setup
///      (invocation parse, TargetInfo, FileManager/SourceManager) runs
///      concurrently with Kairo lex/preprocess.
///   2. Codegen joins that group, then wraps each TU in begin_tu() / end_tu(),
///      which install/remove the ClangDiagAdapter as the DiagnosticsEngine
///      client.
///   3. Kairo fids enter the clang SM in exactly ONE place:
///      ClangLocMap::rebind(), called from
///      KairoEmitAction::BeginSourceFileAction. It has to be there, not on a
///      pool task: FrontendAction::BeginSourceFile calls
///      SourceManager::clearIDTables() on the SM-reuse path, so any FileID
///      minted before ExecuteAction is dead by the time codegen runs.
///
///      There is no preload step. The old one registered from a pool task
///      after preprocess and never re-registered, which meant every FileID it
///      handed out was stale from the first ExecuteAction onward. Registering
///      per action also removes the need for tail-tracking: rebind() rebuilds
///      the whole block, so fids loaded since the last action are picked up
///      for free.
///
/// \par Threading
///   startup() is serialized on an internal mutex against itself. Everything
///   else (begin_tu/end_tu/ExecuteAction/rebind) is driver-thread only
///   clang's Preprocessor/Sema/SourceManager are not shareable across
///   concurrent parses, and createFileID is not thread-safe. Parallel backend
///   TUs later means one CompilerInstance per worker, not locks here.
///
/// \par PP/Sema per TU
///   Only FileManager/SourceManager/TargetInfo persist. clang creates a
///   fresh Preprocessor + Sema per ExecuteAction over the shared SM that
///   is the point: header ContentCaches and Kairo fid buffers are loaded
///   exactly once for the whole batch.
///

ffi "c++" import "Native/Types.hh";
ffi "c++" import "clang/Basic/Diagnostic.h";
ffi "c++" import "clang/Basic/DiagnosticOptions.h";
ffi "c++" import "clang/Basic/SourceManager.h";
ffi "c++" import "clang/Basic/TargetInfo.h";
ffi "c++" import "clang/Frontend/CompilerInstance.h";
ffi "c++" import "clang/Frontend/CompilerInvocation.h";
ffi "c++" import "clang/Frontend/TextDiagnosticPrinter.h";
ffi "c++" import "clang/Lex/PreprocessorOptions.h";
ffi "c++" import "llvm/ADT/IntrusiveRefCntPtr.h";
ffi "c++" import "llvm/Support/TargetSelect.h";
ffi "c++" import "llvm/Support/VirtualFileSystem.h";
ffi "c++" import "llvm/Support/raw_ostream.h";

import Location::SourceLocation::*;
import Location::SourceRange::*;
import Location::SourceManager::*;
import Diagnostic::BufferedDiagSink::*;
import Diagnostic::ClangDiagAdapter::*;
import Interop::Clang::ClangLocMap::*;
import Config::Diagnostic::*;

/// ThreadPool group ids used by the driver for backend tasks.
/// (5 = index, 6 = parse are taken by FrontendAction::_parse.)
eval fn CLANG_STARTUP_GROUP() -> u8 { return 9;  }


/// Extracts the numeric part of a diagnostic code string, used as the
/// severity-letter-agnostic key into the DiagEngine policy table. Scans for
/// the run of decimal digits and parses it; category prefix (S, SC, CL, ...)
/// and trailing severity letter (W, E, F, ...) are ignored. Returns 0 if the
/// string contains no digits (never a valid diagnostic number).
///
///   "S025"  -> 25    "S025W" -> 25    "s025" -> 25    "C889" -> 889
fn _diag_code_to_number(code: string) -> u32 {
    var n = code.length();
    var i: usize = 0;
    var val: u32 = 0;
    var seen: bool = false;
    while i < n {
        var c = code[i];
        if c >= '0' && c <= '9' {
            seen = true;
            val = val * 10 + static_cast::<u32>(c - '0');
        } else if seen {
            break; // digit run ended; ignore any trailing severity letter
        }
        i += 1;
    }
    return val;
}


/// True if \p code is a clang-sourced C-code (category prefix \c C followed by
/// a digit, e.g. \c C889 / \c C889W). Excludes \c CL... (Lowering) and native
/// categories, which have no clang warning group.
fn _is_clang_c_code(code: string) -> bool {
    var n = code.length();
    var i: usize = 0;
    // skip leading whitespace defensively
    while i < n && (code[i] == ' ' || code[i] == '\t') { i += 1; }
    if i >= n { return false; }
    if !(code[i] == 'C' || code[i] == 'c') { return false; }
    i += 1;
    if i >= n { return false; }
    return code[i] >= '0' && code[i] <= '9'; // C<digit>; 'CL' fails here
}

/// Translates the user's per-code diagnostic policy into clang cc1 warning
/// arguments for the subset that maps to clang warning groups (C-codes).
///   allow  -> -Wno-<grp>   deny/--error -> -Werror=<grp>
///   forbid -> -Werror=<grp>  warn/enable -> -W<grp>
/// Native (non-C) codes are skipped here; they are governed by the emit layer.
/// \p suppress_all adds a bare \c -w so clang also honours global -w.
fn _clang_wargs_from_policy(d: ref!(DiagnosticOptions)) -> vec::<string> {
    var out: vec::<string>;
    if d.suppress_warnings { out.push_back("-w"); }
    // Warning-group bulk switches map straight to their clang spellings so
    // clang enables the same group sets it would under a normal driver.
    if d.Wall     { out.push_back("-Wall");      }
    if d.Wextra   { out.push_back("-Wextra");    }
    if d.Wpedantic { out.push_back("-Wpedantic"); }
    for c: string in d.allow_list {
        if _is_clang_c_code(c) {
            var g = clang_diag_group(_diag_code_to_number(c));
            if !g.empty() { out.push_back(f"-Wno-{g}"); }
        }
    }
    for c: string in d.warn_list {
        if _is_clang_c_code(c) {
            var g = clang_diag_group(_diag_code_to_number(c));
            if !g.empty() { out.push_back(f"-W{g}"); }
        }
    }
    for c: string in d.deny_list {
        if _is_clang_c_code(c) {
            var g = clang_diag_group(_diag_code_to_number(c));
            if !g.empty() { out.push_back(f"-Werror={g}"); }
        }
    }
    for c: string in d.forbid_list {
        if _is_clang_c_code(c) {
            var g = clang_diag_group(_diag_code_to_number(c));
            if !g.empty() { out.push_back(f"-Werror={g}"); }
        }
    }
    return out;
}

struct ClangBackendConfig {
    var triple:       string;              ///< effective target triple
    var resource_dir: string;              ///< clang resource dir ("" = skip)
    var sysroot:      string;              ///< sysroot dir ("" = host headers)
    var cxx_std:      string = "c++26";
    var includes:     vec::<string>;       ///< -include names (predefines buffer)
    var extra_cc1:    vec::<string>;       ///< platform extras (exception model, PIC, CPU, ...)
    var wargs:        vec::<string>;       ///< diagnostic -W/-Wno-/-Werror= args from user policy, injected pre-CreateFromArgs
}

class ClangBackend {
    priv var _ksm:    obs::<SourceManager>;         ///< driver-owned, outlives this
    priv var _cfg:    ClangBackendConfig;
    priv var _locmap: own::<ClangLocMap>;           ///< freed in op delete

    // --- persistent clang state (built once in _startup_locked) ----------
    priv var _vfs:       llvm::IntrusiveRefCntPtr::<llvm::vfs::FileSystem>;
    priv var _diag_opts: clang::DiagnosticOptions;  ///< plain value type in 22.x
    priv var _diags0:    llvm::IntrusiveRefCntPtr::<clang::DiagnosticsEngine>; ///< arg-parse engine
    priv var _cinv:      libcxx::shared_ptr::<clang::CompilerInvocation>;
    priv var _ci:        opt::<clang::CompilerInstance> = &null; ///< owned; freed in op delete
    priv var _printer:   opt::<clang::TextDiagnosticPrinter> = &null; ///< owned; engine borrows

    /// cc1 argv backing store deque: stable addresses under growth,
    /// clang keeps no references past CreateFromArgs but c_str()s must
    /// stay valid for the duration of the call.
    priv var _owned: libcxx::deque::<libcxx::string>;

    priv var _mu:      std::Mutex;   ///< serializes startup against itself
    priv var _started: bool = false;
    priv var _failed:  bool = false;

    // --- Construction ------------------------------------------------------

    fn ClangBackend(self, ksm: *SourceManager, cfg: ClangBackendConfig) {
        if ksm == &null {
            std::crash(std::Error::RuntimeError(
                "ClangBackend: a valid Kairo SourceManager is required"));
        }
        self._ksm    = ksm;
        self._cfg    = cfg;
        self._locmap = std::create::<ClangLocMap>(ksm);
    }

    fn op delete (self) {
        // CI's engine borrows _printer (ShouldOwnClient=false everywhere):
        // release the CI and the arg-parse engine BEFORE the printer dies.
        if self._ci != &null {
            std::destroy(self._ci);
            self._ci = &null;
        }
        self._diags0 = llvm::IntrusiveRefCntPtr::<clang::DiagnosticsEngine>();

        if self._printer != &null {
            std::destroy(self._printer);
            self._printer = &null;
        }
        if self._locmap != &null {
            std::destroy(self._locmap);
            self._locmap = &null;
        }
    }

    // --- State -------------------------------------------------------------

    /// Ready to RUN an action. Deliberately not gated on _locmap->ready():
    /// the map is bound inside the action window by rebind(), so requiring it
    /// here would be a chicken-and-egg deadlock on the very first TU.
    fn ready(self)  -> bool { return (self._started) && (!self._failed); }
    fn failed(self) -> bool { return self._failed; }

    fn ci(self)     -> *clang::CompilerInstance { return self._ci; }
    fn locmap(self) -> *ClangLocMap             { return self._locmap; }

    fn csm(self) -> *clang::SourceManager {
        if (self._ci == &null) || (!self._started) {
            return &null;
        }
        return &self._ci->getSourceManager();
    }

    // --- Startup (pool task, group CLANG_STARTUP_GROUP) ---------------------

    /// All of clang's expensive one-time setup. Idempotent and mutex-guarded
    /// against itself; no other task touches clang state off-thread.
    fn startup(self) {
        var lock = std::LockGuard(self._mu);
        self._startup_locked();
    }

    // --- Per-TU diagnostic wiring (driver thread only) -----------------------

    /// Installs a fresh ClangDiagAdapter as the DiagnosticsEngine client for
    /// one TU's backend run. Counters are Reset() so pass/fail is per-TU.
    /// Returned adapter is owned by the CALLER via end_tu().
    ///
    /// The adapter is handed the locmap itself, not a snapshotted clang fid.
    /// It is constructed BEFORE ExecuteAction, so any fid captured here would
    /// be invalidated by clearIDTables before the first diagnostic arrives.
    fn begin_tu(self, sink: *BufferedDiagSink, kfid: FileID) -> *ClangDiagAdapter {
        std::ICE(self.ready(), "ClangBackend::begin_tu before ready()");

        var a = std::create::<ClangDiagAdapter>();
        a->sink   = sink;
        a->ksm    = self._ksm;
        a->kfid   = kfid;
        a->locmap = self._locmap;

        self._ci->getDiagnostics().Reset();

        // Reset() (soft=false) wipes the per-diagnostic warning MAPPINGS set up
        // by CreateFromArgs, so the -W/-Wno-/-Werror= args we injected for the
        // user's diagnostic policy would be lost every TU. Reinstall them from
        // the invocation's DiagnosticOptions after each reset. ReportDiags=false:
        // arg-parse errors were already reported at startup.
        clang::ProcessWarningOptions(
            self._ci->getDiagnostics(),
            self._ci->getInvocation().getDiagnosticOpts(),
            *(self._vfs.get()),
            false);

        self._ci->getDiagnostics().setClient(a, false);
        a->BeginSourceFile(self._ci->getLangOpts(), &null);

        return a;
    }

    /// Flushes any open builder, detaches the adapter, and frees it.
    /// The engine falls back to the startup TextDiagnosticPrinter between TUs.
    fn end_tu(self, a: *ClangDiagAdapter) {
        if a == &null {
            return;
        }

        a->EndSourceFile();
        a->finish();

        self._ci->getDiagnostics().setClient(self._printer, false);
        std::destroy(a);
    }

    /// Per-TU pass/fail as clang saw it (base DiagnosticConsumer counters
    /// are maintained by the adapter's mandatory base call).
    fn clang_error_count(self) -> u32 {
        if (self._ci == &null) || (!self._started) {
            return 0;
        }
        return self._ci->getDiagnostics().getNumErrors();
    }

    // --- Internals -----------------------------------------------------------

    priv fn _arg(self, argv: *libcxx::vector::<std::ConstPtr::<std::Legacy::char>>, s: string) {
        self._owned.push_back(libcxx::string(std::string_to_nstring(s).raw_string()));
        argv->push_back(self._owned.back().c_str());
    }

    priv fn _startup_locked(self) {
        if (self._started) || (self._failed) {
            return;
        }

        llvm::InitializeNativeTarget();
        llvm::InitializeNativeTargetAsmPrinter();

        self._vfs     = llvm::vfs::getRealFileSystem();
        self._printer = std::create::<clang::TextDiagnosticPrinter>(
            llvm::errs(), self._diag_opts);

        // Standalone engine for cc1 arg parsing; the CI builds its own below.
        self._diags0 = clang::CompilerInstance::createDiagnostics(
            *(self._vfs.get()), self._diag_opts, self._printer, false);

        // cc1 argv: mirrors what `clang --target=<triple> -###` emits for the
        // configured sysroot target setup, predefines, header search all
        // come from CreateFromArgs instead of hand-set option fields.
        var argv: libcxx::vector::<std::ConstPtr::<std::Legacy::char>>;

        self._arg(&argv, "-triple");
        self._arg(&argv, self._cfg.triple);
        self._arg(&argv, "-emit-obj");
        self._arg(&argv, f"-std={self._cfg.cxx_std}");
        self._arg(&argv, "-fgnuc-version=4.2.1");

        if !self._cfg.resource_dir.empty() {
            self._arg(&argv, "-resource-dir");
            self._arg(&argv, self._cfg.resource_dir);
            self._arg(&argv, "-internal-isystem"); // builtin <stdint.h> -> uintptr_t
            self._arg(&argv, f"{self._cfg.resource_dir}/include");
        }

        if !self._cfg.sysroot.empty() {
            self._arg(&argv, "-nostdsysteminc");   // cc1 spelling of -nostdlibinc
            self._arg(&argv, "-nostdinc++");
            self._arg(&argv, "-isystem");
            self._arg(&argv, f"{self._cfg.sysroot}/include/c++/v1");
            self._arg(&argv, "-isystem");
            self._arg(&argv, f"{self._cfg.sysroot}/include");
            self._arg(&argv, "-isysroot");
            self._arg(&argv, self._cfg.sysroot);
        }

        for a: string in self._cfg.extra_cc1 {
            self._arg(&argv, a);
        }

        // User diagnostic policy for clang-sourced diagnostics: -W<grp> (enable),
        // -Wno-<grp> (silence), -Werror=<grp> (promote/forbid). Resolved from
        // Kairo C-codes to clang warning groups by the driver. Injected here so
        // clang honours them at analysis time, not just post-hoc at emit.
        for a: string in self._cfg.wargs {
            self._arg(&argv, a);
        }

        // Placeholder input; per-TU runs replace FrontendOpts.Inputs with the
        // injected in-memory buffer before ExecuteAction.
        self._arg(&argv, "-x");
        self._arg(&argv, "c++");
        self._arg(&argv, "<injected>");

        self._cinv = libcxx::make_shared::<clang::CompilerInvocation>();

        if !clang::CompilerInvocation::CreateFromArgs(
                *(self._cinv.get()), argv, *(self._diags0.get())) {
            Logger::error(Logger::Stage::Driver,
                "ClangBackend: CompilerInvocation::CreateFromArgs failed");
            self._failed = true;
            return;
        }

        // -include names travel via the predefines buffer.
        for inc: string in self._cfg.includes {
            self._cinv.get()->getPreprocessorOpts().Includes.push_back(
                libcxx::string(std::string_to_nstring(inc).raw_string()));
        }

        self._ci = std::create::<clang::CompilerInstance>(self._cinv);
        self._ci->setVirtualFileSystem(self._vfs);
        self._ci->createDiagnostics(self._printer, false);

        if !self._ci->hasDiagnostics() {
            self._failed = true;
            return;
        }

        self._ci->setTarget(clang::TargetInfo::CreateTargetInfo(
            self._ci->getDiagnostics(),
            self._ci->getInvocation().getTargetOpts()));

        if !self._ci->hasTarget() {
            Logger::error(Logger::Stage::Driver,
                f"ClangBackend: no target for triple '{self._cfg.triple}\x27");
            self._failed = true;
            return;
        }

        self._ci->getTarget().adjust(
            self._ci->getDiagnostics(), self._ci->getLangOpts(), &null);

        // Persistent FileManager + SourceManager: the whole point. Header
        // ContentCaches and Kairo fid buffers load once for the batch.
        self._ci->createFileManager();
        self._ci->createSourceManager();

        // No locmap wiring here: ClangLocMap binds its SourceManager in
        // rebind(), inside the action window. Binding at startup was only ever
        // meaningful because registration also happened outside the window,
        // and that is exactly what produced the stale-FileID bug.
        self._started = true;

        Logger::info(Logger::Stage::Driver,
            f"ClangBackend: started (triple={self._cfg.triple})");
    }
}
