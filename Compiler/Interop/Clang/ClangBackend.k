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
///   1. Driver constructs this in index() and enqueues startup() on the
///      ThreadPool (group CLANG_STARTUP_GROUP) clang's expensive setup
///      (invocation parse, TargetInfo, FileManager/SourceManager) runs
///      concurrently with Kairo lex/preprocess.
///   2. After each TU's preprocess, the driver enqueues preload() (group
///      CLANG_PRELOAD_GROUP): every fid known by then gets a clang FileID
///      created from the SAME mmap Kairo reads. Idempotent later TUs map
///      only the tail.
///   3. Codegen joins both groups, then wraps each TU in
///      begin_tu() / end_tu(), which install/remove the ClangDiagAdapter
///      as the DiagnosticsEngine client.
///
/// \par Threading
///   startup() and preload() are serialized on an internal mutex; preload()
///   self-heals by running startup first if its task won the race. Everything
///   else (begin_tu/end_tu/ExecuteAction) is driver-thread only clang's
///   Preprocessor/Sema are not shareable across concurrent parses. Parallel
///   backend TUs later means one CompilerInstance per worker, not locks here.
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

/// ThreadPool group ids used by the driver for backend tasks.
/// (5 = index, 6 = parse are taken by FrontendAction::_parse.)
eval fn CLANG_STARTUP_GROUP() -> u8 { return 9;  }
eval fn CLANG_PRELOAD_GROUP() -> u8 { return 10; }

struct ClangBackendConfig {
    var triple:       string;              ///< effective target triple
    var resource_dir: string;              ///< clang resource dir ("" = skip)
    var sysroot:      string;              ///< sysroot dir ("" = host headers)
    var cxx_std:      string = "c++26";
    var includes:     vec::<string>;       ///< -include names (predefines buffer)
    var extra_cc1:    vec::<string>;       ///< platform extras (exception model, PIC, CPU, ...)
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

    priv var _mu:      std::Mutex;   ///< serializes startup/preload
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

    fn ready(self)  -> bool { return (self._started) && (!self._failed) && (self._locmap->ready()); }
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

    /// All of clang's expensive one-time setup. Idempotent; safe to race
    /// with preload() both serialize on _mu.
    fn startup(self) {
        var lock = std::LockGuard(self._mu);
        self._startup_locked();
    }

    // --- Preload (pool task, group CLANG_PRELOAD_GROUP) ----------------------

    /// Mirrors every currently-loaded Kairo fid into the shared clang SM.
    /// Runs startup first if that task hasn't landed yet. Idempotent:
    /// re-invocations map only fids loaded since the last call.
    fn preload(self) {
        var lock = std::LockGuard(self._mu);
        self._startup_locked();

        if !self._started {
            return; // startup failed; codegen will see !ready() and skip
        }

        self._locmap->preload();
    }

    // --- Per-TU diagnostic wiring (driver thread only) -----------------------

    /// Installs a fresh ClangDiagAdapter as the DiagnosticsEngine client for
    /// one TU's backend run. Counters are Reset() so pass/fail is per-TU.
    /// Returned adapter is owned by the CALLER via end_tu().
    fn begin_tu(self, sink: *BufferedDiagSink, kfid: FileID) -> *ClangDiagAdapter {
        std::ICE(self.ready(), "ClangBackend::begin_tu before ready()");

        var a = std::create::<ClangDiagAdapter>();
        a->sink       = sink;
        a->ksm        = self._ksm;
        a->kfid       = kfid;
        a->clang_kfid = self._locmap->clang_fid(kfid);

        self._ci->getDiagnostics().Reset();
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

        self._locmap->attach(&self._ci->getSourceManager());
        self._started = true;

        Logger::info(Logger::Stage::Driver,
            f"ClangBackend: started (triple={self._cfg.triple})");
    }
}
