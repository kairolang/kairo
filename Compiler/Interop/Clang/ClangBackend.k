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

ffi "c++" import "llvm/Support/Allocator.h";
ffi "c++" import "llvm/Support/StringSaver.h";
ffi "c++" import "Native/Types.hh";
ffi "c++" import "clang/Basic/Diagnostic.h";
ffi "c++" import "clang/Basic/DiagnosticOptions.h";
ffi "c++" import "clang/Basic/SourceManager.h";
ffi "c++" import "clang/Basic/TargetInfo.h";
ffi "c++" import "clang/Frontend/CompilerInstance.h";
ffi "c++" import "clang/Frontend/CompilerInvocation.h";
ffi "c++" import "clang/Frontend/TextDiagnosticPrinter.h";
ffi "c++" import "clang/Driver/CreateInvocationFromArgs.h";
ffi "c++" import "clang/CodeGen/CodeGenAction.h";
ffi "c++" import "clang/Lex/PreprocessorOptions.h";
ffi "c++" import "llvm/ADT/IntrusiveRefCntPtr.h";
ffi "c++" import "llvm/ADT/Twine.h";
ffi "c++" import "llvm/Support/CommandLine.h";
ffi "c++" import "llvm/Support/MemoryBuffer.h";
ffi "c++" import "llvm/Support/TargetSelect.h";
ffi "c++" import "llvm/Support/VirtualFileSystem.h";
ffi "c++" import "llvm/Support/raw_ostream.h";

import Location::SourceLocation::*;
import Location::SourceRange::*;
import Location::SourceManager::*;
import Diagnostic::BufferedDiagSink::*;
import Diagnostic::ClangDiagAdapter::*;
import Interop::Clang::ClangLocMap::*;
import Interop::Clang::BuiltinsSet::*;
import Config::Diagnostic::*;
import Command::FlagTranslator::*;

/// ThreadPool group ids used by the driver for backend tasks.
/// (5 = index, 6 = parse are taken by FrontendAction::_parse.)
eval fn CLANG_STARTUP_GROUP() -> u8 { return 9;  }


struct ClangBackendConfig {
    var triple:       string;              ///< effective target triple
    var resource_dir: string;              ///< clang resource dir ("" = skip)
    var sysroot:      string;              ///< sysroot dir ("" = host headers): -isysroot
    /// Header roots a SYSROOT.toml declares (or an Apple SDK implies), already
    /// absolute. libc++ dirs are split out because they go BEFORE the clang
    /// builtin headers and are skipped for C. Both empty = the prefix model:
    /// <sysroot>/include/c++/v1 and <sysroot>/include.
    var cxx_include_dirs: vec::<string>;
    var include_dirs:     vec::<string>;
    var framework_dirs:   vec::<string>;   ///< -iframework (Apple: System/Library/Frameworks)
    /// Macros a SYSROOT.toml's cc_defines requires (-D<name>): the ones its
    /// prebuilt libc++ was compiled with, which the TU must match to link.
    var defines:          vec::<string>;
    var cxx_std:      string = "c++26";
    var c_std:        string = "c17";      ///< -std for C inputs (--c-std)
    var includes:     vec::<string>;       ///< -include names (predefines buffer)
    var extra_cc1:    vec::<string>;       ///< platform extras (exception model, PIC, CPU, ...)
    var wargs:        vec::<string>;       ///< diagnostic -W/-Wno-/-Werror= args from user policy, injected pre-CreateFromArgs
    var opt_level:    i32  = 0;            ///< -O level, 0-3 (s and z are 2)
    var opt_size:     i32  = 0;            ///< 0 none, 1 -Os, 2 -Oz
    var vectorize:    bool = true;         ///< loop + SLP vectorizers above -O0 (-f[no-]vectorize)
    /// -g and its modifiers. Handed to the driver probe, never spelled as
    /// cc1 flags here: the driver picks CodeView or DWARF, the debugger
    /// tuning and the info kind per target (see _driver_target_args).
    var debug_info:    bool = false;
    var dwarf_version: i32  = 0;           ///< 0 = the target's default (MSVC: CodeView)
    var debug_macros:  bool = false;       ///< -fdebug-macro
    var embed_source:  bool = false;       ///< -gembed-source
    /// Extra words for the driver probe in _driver_target_args (--march). They
    /// go to the clang DRIVER, never to cc1: cc1 has no -march, and what the
    /// driver makes of one (-target-cpu plus a -target-feature per implied
    /// extension) is only right per architecture.
    var driver_words:  vec::<string>;
}

class ClangBackend {
    priv var _ksm:    obs::<SourceManager>;         ///< driver-owned, outlives this
    priv var _cfg:    ClangBackendConfig;
    priv var _locmap: own::<ClangLocMap>;           ///< freed in op delete

    // --- persistent clang state (built once in _startup_locked) ----------
    priv var _vfs:       llvm::IntrusiveRefCntPtr::<llvm::vfs::FileSystem>;
    /// Top layer of _vfs: phase-A PCH bytes mounted at /kairo/pch/<id>.pch so
    /// phase B loads them by path without ever touching disk.
    priv var _mem:       llvm::IntrusiveRefCntPtr::<llvm::vfs::InMemoryFileSystem>;
    priv var _diag_opts: clang::DiagnosticOptions;  ///< plain value type in 22.x
    priv var _diags0:    llvm::IntrusiveRefCntPtr::<clang::DiagnosticsEngine>; ///< arg-parse engine
    priv var _cinv:      libcxx::shared_ptr::<clang::CompilerInvocation>;
    priv var _ci:        opt::<clang::CompilerInstance> = &null; ///< owned; freed in op delete
    priv var _printer:   opt::<clang::TextDiagnosticPrinter> = &null; ///< owned; engine borrows

    /// cc1 argv backing store deque: stable addresses under growth,
    /// clang keeps no references past CreateFromArgs but c_str()s must
    /// stay valid for the duration of the call.
    /// Bytes behind every argv pointer handed to clang. A bump arena, not a
    /// container of strings: argv keeps raw pointers while more are added,
    /// and a vector would move its strings (SSO bytes live inside them).
    /// StringSaver NUL-terminates, which argv needs.
    priv var _owned: llvm::BumpPtrAllocator;

    priv var _target_args:  vec::<string>;  ///< see _driver_target_args
    priv var _target_known: bool = false;
    /// The driver's C++ FP defaults for this target, which probe_filter
    /// drops (Kairo's line has its own): what an ffi header region is
    /// restored to (header_fp_pragmas).
    priv var _cxx_contract:   string = "";
    priv var _cxx_math_errno: bool   = false;

    priv var _mu:      std::Mutex;   ///< serializes startup against itself
    priv var _started: bool = false;
    priv var _failed:  bool = false;
    priv var _oracle:  BuiltinsSet;

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
        // The oracle's own CI borrows _printer too: it goes first.
        self._oracle.release();

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
    fn ksm(self)    -> *SourceManager           { return self._ksm; }

    fn invocation(self) -> *clang::CompilerInvocation { return self._cinv.get(); }
    fn vfs(self)        -> llvm::IntrusiveRefCntPtr::<llvm::vfs::FileSystem> { return self._vfs; }

    /// \brief the pragma lines around every ffi header region, phase A's
    ///        PCH buffer and phase B's textual wrapper alike: see
    ///        FlagTranslator::header_fp_pragmas.
    ///        After startup() only: the probe that fills the C++ defaults runs
    ///        there, under its mutex, and pool threads call this.
    fn header_fp_pragmas(self, open: *vec::<string>, close: *vec::<string>) {
        FlagTranslator::header_fp_pragmas(self._cxx_contract, self._cxx_math_errno,
                                          self._cfg.extra_cc1, open, close);
    }
    fn mem_fs(self)     -> *llvm::vfs::InMemoryFileSystem { return self._mem.get(); }

    fn oracle(self) -> *BuiltinsSet {
        if !self.ready() { return &null; }
        if !self._oracle.ready() { return &null; }
        return &(self._oracle);
    }

    /// \brief compiles one C or C++ source file to an object, on the same
    ///        target, roots and VFS as Kairo's own codegen.
    ///
    /// \details a FRESH invocation from the shared cc1 arguments rather than
    ///          a copy of the backend's: a copy carries C++ LangOptions, and a
    ///          .c file must get clang's C defaults. Own CompilerInstance per
    ///          file, the backend's shared VFS (so an in-memory mount is
    ///          visible), and the backend's printer: these files have no
    ///          Kairo fid, so clang reports them in its own format.
    ///
    ///          The later `#include "foo.k"` work installs the patched
    ///          FileTokenizer hook on this instance's Preprocessor; nothing
    ///          else about the shape changes.
    ///
    ///          Driver thread only. False on any failure, with clang's
    ///          diagnostics already printed.
    fn compile_native(self, src: string, out: string, xlang: string, is_c: bool) -> bool {
        self.startup();
        if !self.ready() { return false; }

        var argv: libcxx::vector::<std::ConstPtr::<std::Legacy::char>>;
        // Lib/rt is C/C++ source: it keeps clang's C/C++ FP defaults.
        self._cc1_common(&argv, is_c, false);
        // -std only for the languages it names: IR has none, and an ObjC or
        // OpenCL standard is not a C++ one.
        if (xlang == "c") || (xlang == "cpp-output") {
            self._arg(&argv, f"-std={self._cfg.c_std}");
        } else if (xlang == "c++") || (xlang == "c++-cpp-output") {
            self._arg(&argv, f"-std={self._cfg.cxx_std}");
        }
        self._arg(&argv, "-x");
        self._arg(&argv, xlang);
        self._arg(&argv, src);
        self._arg(&argv, "-o");
        self._arg(&argv, out);

        var inv = libcxx::make_shared::<clang::CompilerInvocation>();
        if !clang::CompilerInvocation::CreateFromArgs(*(inv.get()), argv, *(self._diags0.get())) {
            Logger::error(Logger::Stage::Driver, f"ClangBackend: cannot build an invocation for {src}");
            return false;
        }

        var ci = std::create::<clang::CompilerInstance>(inv);
        finally { std::destroy(ci); }
        ci->setVirtualFileSystem(self._vfs);
        ci->createDiagnostics(self._printer, false);
        if !ci->hasDiagnostics() { return false; }
        ci->setTarget(clang::TargetInfo::CreateTargetInfo(
            ci->getDiagnostics(), ci->getInvocation().getTargetOpts()));
        if !ci->hasTarget() { return false; }

        var act = clang::EmitObjAction();
        var ok  = ci->ExecuteAction(act);
        return ok && (ci->getDiagnostics().getNumErrors() == 0);
    }

    /// Driver thread only. A generated header, copied in; addFile keeps the
    /// first mount of a path, so a second call is a no-op.
    fn mount_text(self, path: string, text: string) {
        var buf = llvm::MemoryBuffer::getMemBufferCopy(
            sref(text), sref(path));
        self._mem->addFile(llvm::Twine(sref(path)), 0, libcxx::move(buf));
    }

    /// Driver thread only. Idempotent per path.
    fn mount_pch(self, path: string, data: *llvm::SmallVector::<std::Legacy::char, 0>) {
        var buf = llvm::MemoryBuffer::getMemBuffer(
            llvm::StringRef(data->data(), data->size()), sref(path), false);
        self._mem->addFile(llvm::Twine(sref(path)), 0, libcxx::move(buf));
    }

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
        ICE_IF(!self.ready(), "ClangBackend::begin_tu before ready()");

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

    /// The cc1 argv of the shared invocation, which every compile copies.
    /// One builder for _startup_locked and invocation_args, so what
    /// --print-clang-args shows is what runs.
    priv fn _shared_argv(self, argv: *libcxx::vector::<std::ConstPtr::<std::Legacy::char>>) {
        self._cc1_common(argv, false, true);
        self._arg(argv, f"-std={self._cfg.cxx_std}");

        // Placeholder input; per-TU runs replace FrontendOpts.Inputs with the
        // injected in-memory buffer before ExecuteAction.
        self._arg(argv, "-x");
        self._arg(argv, "c++");
        self._arg(argv, "<injected>");
    }

    /// \brief the shared invocation's cc1 arguments, for --print-clang-args.
    ///
    /// \details the argv _startup_locked parses, then each configured
    ///          -include, which the backend hands to the preprocessor options
    ///          directly and cc1 would take as the flag. Nothing is started.
    fn invocation_args(self) -> vec::<string> {
        var argv: libcxx::vector::<std::ConstPtr::<std::Legacy::char>>;
        self._shared_argv(&argv);
        var out = vec::<string>();
        for var i: usize = 0; i < argv.size(); ++i {
            out.push_back(string(argv[i]));
        }
        for inc: string in self._cfg.includes {
            out.push_back("-include");
            out.push_back(inc);
        }
        return out;
    }

    priv fn _arg(self, argv: *libcxx::vector::<std::ConstPtr::<std::Legacy::char>>, s: string) {
        argv->push_back(llvm::StringSaver(self._owned).save(sref(s)).data());
    }

    /// \brief the cc1 arguments clang's own driver derives from the triple
    ///        alone: CPU, features, ABI, float ABI, char signedness,
    ///        exception model, init/atexit and unwind-table defaults.
    ///
    /// \details cc1 has no defaults of its own for any of these, and there is
    ///          no driver here: without them armhf compiled as soft-float,
    ///          riscv64 as lp64, i686 without SSE2 (so no _Float16 or __bf16),
    ///          and char was signed on ARM and RISC-V. Each is an ABI break
    ///          against the sysroot's C libraries. So the driver is run once,
    ///          for this triple, and its cc1 line is filtered to the flags
    ///          that decide the target -- never a table here, which would
    ///          drift from clang.
    ///
    ///          The MSVC language-mode flags (-fms-extensions,
    ///          -fms-compatibility[-version=], -fms-volatile) are taken too:
    ///          the CRT and SDK headers do not parse without them. They are
    ///          LangOpts, so Kairo's own lowered C++ parses in that mode as
    ///          well, as it would under clang-cl. -fgnuc-version comes from
    ///          the driver for the same reason: it omits it for MSVC, and a
    ///          __GNUC__ beside _MSC_VER sends those headers down GCC paths.
    ///          The probe carries -std so standard-dependent defaults
    ///          (-fdelayed-template-parsing before C++20) match the TU's,
    ///          and -g with its modifiers so the debug format is the
    ///          driver's call: CodeView on MSVC, DWARF tuned for gdb or
    ///          lldb elsewhere, standalone info kind on Darwin.
    ///          --mcpu still wins: extra_cc1 comes later and cc1 takes the
    ///          last -target-cpu.
    priv fn _driver_target_args(self) -> vec::<string> {
        if self._target_known { return self._target_args; }
        self._target_known = true;

        var owned: llvm::BumpPtrAllocator;   ///< argv bytes, for this call (see _owned).
        var dargv: libcxx::vector::<std::ConstPtr::<std::Legacy::char>>;
        var words = vec::<string>();
        words.push_back("clang");
        words.push_back(f"--target={self._cfg.triple}");
        words.push_back(f"-std={self._cfg.cxx_std}");
        for w: string in self._cfg.driver_words { words.push_back(w); }
        for w: string in FlagTranslator::debug_driver(self._cfg.debug_info, self._cfg.dwarf_version,
                                                      self._cfg.debug_macros, self._cfg.embed_source) {
            words.push_back(w);
        }
        words.push_back("-fsyntax-only");
        words.push_back("-x");
        words.push_back("c++");
        words.push_back("-");
        for w: string in words {
            dargv.push_back(llvm::StringSaver(owned).save(sref(w)).data());
        }

        var cc1: libcxx::vector::<libcxx::string>;
        var opts: clang::CreateInvocationOptions;
        opts.CC1Args = &cc1;
        var inv = clang::createInvocation(dargv, opts);
        if cc1.empty() {
            Logger::error(Logger::Stage::Driver,
                f"ClangBackend: clang\x27s driver gave no cc1 line for {self._cfg.triple} (a bad --march fails this probe); compiling without target defaults");
            return self._target_args;
        }

        // C++'s FP defaults, before the filter drops them: an ffi header
        // region is put back to these (header_fp_pragmas).
        for var i: usize = 0; i < cc1.size(); ++i {
            var a = string(cc1[i]);
            if a.starts_with("-ffp-contract=") { self._cxx_contract = string(a.raw() + 14, a.size() - 14); }
            if a == "-fmath-errno" { self._cxx_math_errno = true; }
        }

        // Which of the driver's cc1 words decide the target is the
        // translator's call (FlagTranslator::probe_filter).
        for a: string in FlagTranslator::probe_filter(cc1) { self._target_args.push_back(a); }
        return self._target_args;
    }

    /// \brief the header-search model and the sysroot's required macros,
    ///        in either spelling: kairo's own cc1 line (_cc1_common) and the
    ///        clang driver line C/C++ inputs compile with (ClangJobs) search
    ///        exactly the same roots, in the same order.
    ///
    /// \details ONE explicit model for every target, the host included.
    ///          clang is told exactly which roots to search and never falls
    ///          back to whatever the machine has: the roots are exactly
    ///          --sysroot and --resource-dir, never discovered
    ///          (CompilerInstance::initialize copies them), and the same
    ///          layout is what every kbld SYSROOT.toml declares (include_dirs
    ///          = include/c++/v1, include; cc_isolation = -nostdlibinc
    ///          -nostdinc++).
    ///
    ///            <sysroot>/include/c++/v1   libc++
    ///            <resource>/include         clang builtins (stddef.h, intrinsics)
    ///            <sysroot>/include          libc
    ///
    ///          A root that did not resolve is left out rather than guessed;
    ///          the resolver has already logged which one and why. \p is_c
    ///          leaves libc++ off: its C-named wrappers (<stdlib.h>,
    ///          <stddef.h>) are C++ headers, and C must reach the libc and
    ///          clang builtin ones directly.
    ///
    ///          The sysroot's -D macros are here, not per TU: every compile
    ///          copies this invocation, and the header-set PCH reader rejects
    ///          a predefines mismatch.
    fn sysroot_words(self, is_c: bool, sp: ClangSpelling) -> vec::<string> {
        var o   = vec::<string>();
        var cc1 = sp == ClangSpelling::CC1;
        var sr = self._cfg.sysroot;
        var rd = self._cfg.resource_dir;
        var declared = (!self._cfg.include_dirs.empty()) || (!self._cfg.cxx_include_dirs.empty());
        o.push_back(("-nostdsysteminc") if (cc1) else ("-nostdlibinc"));
        o.push_back("-nostdinc++");
        if !rd.empty() { o.push_back("-resource-dir"); o.push_back(rd); }
        if declared {
            if !is_c {
                for d: string in self._cfg.cxx_include_dirs { o.push_back("-isystem"); o.push_back(d); }
            }
            if !rd.empty() { o.push_back("-isystem"); o.push_back(f"{rd}/include"); }
            for d: string in self._cfg.include_dirs { o.push_back("-isystem"); o.push_back(d); }
        } else {
            if (!sr.empty()) && (!is_c) { o.push_back("-isystem"); o.push_back(f"{sr}/include/c++/v1"); }
            if !rd.empty() { o.push_back("-isystem"); o.push_back(f"{rd}/include"); }
            if !sr.empty() { o.push_back("-isystem"); o.push_back(f"{sr}/include"); }
        }
        for d: string in self._cfg.framework_dirs { o.push_back("-iframework"); o.push_back(d); }
        if !sr.empty() { o.push_back("-isysroot"); o.push_back(sr); }
        // The driver also anchors its toolchain search (crt, gcc install
        // detection) on --sysroot; without it that search is the host's.
        if (!cc1) && (!sr.empty()) { o.push_back(f"--sysroot={sr}"); }
        // The driver adds the builtin directory itself, as an internal
        // system root; cc1 has to be told (builtin <stdint.h> -> uintptr_t).
        if cc1 && (!rd.empty()) {
            o.push_back("-internal-isystem");
            o.push_back(f"{rd}/include");
        }
        for d: string in self._cfg.defines { o.push_back(f"-D{d}"); }
        return o;
    }

    /// The effective target triple every compile in this build uses.
    fn triple(self) -> string { return self._cfg.triple; }

    /// The printer clang's own diagnostics go to (C/C++ inputs have no Kairo
    /// fid, so they are reported in clang's format). Null before startup().
    fn printer(self) -> *clang::TextDiagnosticPrinter { return self._printer; }

    /// The engine clang's driver and cc1 argument parsing report through.
    fn arg_diags(self) -> *clang::DiagnosticsEngine { return self._diags0.get(); }

    /// \brief the cc1 arguments every clang compile in this build shares:
    ///        target, object emission, the explicit header-search model,
    ///        platform extras and the user's -W policy. The Kairo backend and
    ///        native .c/.cpp compiles both start here, so they cannot drift
    ///        onto different targets or roots.
    ///
    /// \details \p is_c leaves libc++ off the search path: its C-named
    ///          wrappers (<stdlib.h>, <stddef.h>) are C++ headers, and C
    ///          must reach the libc and clang builtin ones directly.
    /// \p kairo: the line Kairo's own code compiles with (and every header
    ///    set, whose PCH must match it), as opposed to Lib/rt's C/C++.
    priv fn _cc1_common(self, argv: *libcxx::vector::<std::ConstPtr::<std::Legacy::char>>, is_c: bool, kairo: bool) {
        self._arg(argv, "-triple");
        self._arg(argv, self._cfg.triple);
        for a: string in self._driver_target_args() { self._arg(argv, a); }
        // Kairo's i128 and f128 exist on every target. clang offers __int128
        // only at 64-bit pointer width unless told; the backend expands it
        // (and compiler-rt's tf routines need it) on 32-bit targets too.
        self._arg(argv, "-fforce-enable-int128");
        // C++ lets the optimizer assume a side-effect-free loop terminates
        // and delete it; Kairo makes no such promise. `loop {}` as a
        // firmware idle or a spin on a register must stay a loop.
        self._arg(argv, "-fno-finite-loops");
        self._arg(argv, "-emit-obj");

        // Header search and the sysroot's macros: the one root model,
        // shared with C/C++ inputs (sysroot_words says why it is explicit).
        for a: string in self.sysroot_words(is_c, ClangSpelling::CC1) { self._arg(argv, a); }

        // Kairo's FP semantics, ahead of extra_cc1 so the user's own FP
        // flags (cc1 takes the last) still win.
        if kairo { for a: string in FlagTranslator::kairo_fp_cc1() { self._arg(argv, a); } }
        for a: string in self._cfg.extra_cc1 {
            self._arg(argv, a);
        }

        // Optimization level, as cc1 flags rather than CodeGenOpts fields:
        // cc1's own parsing then sets everything that hangs off the level
        // (OptimizationLevel, OptimizeSize, the inliner mode, LangOpts
        // Optimize/OptimizeSize, no optnone above -O0) in step. Here, not per
        // TU, because every compile copies this invocation: the header-set
        // PCHs (whose reader rejects an __OPTIMIZE__ mismatch), the native
        // runtime objects and every TU's codegen run alike -- so builtin,
        // std and the user's code are always built at one level.
        var fvec: i32 = (1) if (self._cfg.vectorize) else (0);
        for a: string in FlagTranslator::optimization(self._cfg.opt_level, self._cfg.opt_size, fvec, ClangSpelling::CC1) {
            self._arg(argv, a);
        }
        // (The vectorizers come with the level: FlagTranslator::optimization
        // says why kairo asks for them at every level above -O0.)

        // User diagnostic policy for clang-sourced diagnostics: -W<grp> (enable),
        // -Wno-<grp> (silence), -Werror=<grp> (promote/forbid). Resolved from
        // Kairo C-codes to clang warning groups by the driver. Injected here so
        // clang honours them at analysis time, not just post-hoc at emit.
        for a: string in self._cfg.wargs {
            self._arg(argv, a);
        }
    }

    /// \brief hands the invocation's -mllvm words to LLVM's option parser.
    ///
    /// \details CreateFromArgs only RECORDS them in FrontendOptions::LLVMArgs;
    ///          the parse is done by clang's cc1_main (ExecuteCompilerInvocation),
    ///          which this backend never goes through, so without this every
    ///          --mllvm (and the flags lowered to one) would be accepted and
    ///          dropped. Once per process: the options are global state.
    priv fn _apply_llvm_args(self) {
        var n = self._cinv.get()->getFrontendOpts().LLVMArgs.size();
        if n == 0 { return; }
        var av: libcxx::vector::<std::ConstPtr::<std::Legacy::char>>;
        self._arg(&av, "kairo (LLVM option parsing)");
        for var i: usize = 0; i < n; ++i {
            self._arg(&av, string(self._cinv.get()->getFrontendOpts().LLVMArgs[i]));
        }
        // Errors go to a stream and come back as false: without one LLVM calls
        // exit(1), here on a pool thread, for a mistyped --mllvm word.
        var ov = "kairo";
        var es = &(llvm::errs());
        if !llvm::cl::ParseCommandLineOptions(static_cast::<i32>(av.size()), av.data(),
                                              sref(ov), es) {
            Logger::error(Logger::Stage::Driver, "ClangBackend: an --mllvm word was not accepted by LLVM");
            self._failed = true;
        }
    }

    priv fn _startup_locked(self) {
        if (self._started) || (self._failed) {
            return;
        }

        llvm::InitializeNativeTarget();
        llvm::InitializeNativeTargetAsmPrinter();

        var overlay = llvm::makeIntrusiveRefCnt::<llvm::vfs::OverlayFileSystem>(llvm::vfs::getRealFileSystem());
        self._mem = llvm::makeIntrusiveRefCnt::<llvm::vfs::InMemoryFileSystem>();
        overlay->pushOverlay(self._mem);
        self._vfs = overlay;
        self._printer = std::create::<clang::TextDiagnosticPrinter>(
            llvm::errs(), self._diag_opts);

        // Standalone engine for cc1 arg parsing; the CI builds its own below.
        self._diags0 = clang::CompilerInstance::createDiagnostics(
            *(self._vfs.get()), self._diag_opts, self._printer, false);

        // cc1 argv: mirrors what `clang --target=<triple> -###` emits for the
        // configured sysroot target setup, predefines, header search all
        // come from CreateFromArgs instead of hand-set option fields.
        var argv: libcxx::vector::<std::ConstPtr::<std::Legacy::char>>;

        self._shared_argv(&argv);

        self._cinv = libcxx::make_shared::<clang::CompilerInvocation>();

        if !clang::CompilerInvocation::CreateFromArgs(
                *(self._cinv.get()), argv, *(self._diags0.get())) {
            Logger::error(Logger::Stage::Driver,
                "ClangBackend: CompilerInvocation::CreateFromArgs failed");
            self._failed = true;
            return;
        }
        self._apply_llvm_args();

        // -include names travel via the predefines buffer.
        for inc: string in self._cfg.includes {
            self._cinv.get()->getPreprocessorOpts().Includes.push_back(
                inc.std_string());
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

        // Failure is not fatal: every builtin then misses into R020E.
        if !self._oracle.build(self._cinv.get(), self._vfs, self._printer) {
            Logger::info(Logger::Stage::Driver, "ClangBackend: builtin oracle unavailable");
        }

        Logger::info(Logger::Stage::Driver,
            f"ClangBackend: started (triple={self._cfg.triple})");
    }
}
