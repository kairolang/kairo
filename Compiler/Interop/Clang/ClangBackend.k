/// --- The Kairo Project ----------------- Interop/Clang/ClangBackend.k --- ///
///
///   The one clang CompilerInstance shared by every TU in the batch.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
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
///   2. Codegen joins that group, then compiles each TU on a CompilerInstance
///      of its own (CodegenBackend::run): a copy of this invocation, a VFS
///      from codegen_vfs(), the TU's ClangDiagAdapter as the client. The
///      shared instance here is the template and the oracle's, not a TU's.
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
///   startup() is serialized on an internal mutex against itself. Codegen
///   TUs run on several pool workers at once, so nothing a TU's
///   compile touches is shared and mutable: each gets its own
///   CompilerInvocation copy, CompilerInstance (FileManager, SourceManager,
///   TargetInfo, DiagnosticsEngine), ClangLocMap and VFS overlay. What they
///   share is read-only once the fan-out starts: the invocation they copy,
///   the in-memory layer holding the PCH bytes (views, never copies) and
///   wrapper texts, filled and frozen before the first TU
///   (CodegenMounts::freeze; InMemoryFileSystem::addFile is not
///   thread-safe, its reads are, and each TU reaches it through a proxy that
///   drops the working-directory write), and the real file system.
///

ffi "c++" import "llvm/Support/Allocator.h"
ffi "c++" import "llvm/Support/StringSaver.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "clang/Basic/Diagnostic.h"
ffi "c++" import "clang/Basic/DiagnosticOptions.h"
ffi "c++" import "clang/Basic/SourceManager.h"
ffi "c++" import "clang/Basic/TargetInfo.h"
ffi "c++" import "clang/Frontend/CompilerInstance.h"
ffi "c++" import "clang/Frontend/CompilerInvocation.h"
ffi "c++" import "clang/Frontend/TextDiagnosticPrinter.h"
ffi "c++" import "clang/Driver/CreateInvocationFromArgs.h"
ffi "c++" import "clang/CodeGen/CodeGenAction.h"
ffi "c++" import "clang/Lex/PreprocessorOptions.h"
ffi "c++" import "llvm/ADT/IntrusiveRefCntPtr.h"
ffi "c++" import "llvm/ADT/Twine.h"
ffi "c++" import "llvm/Support/CommandLine.h"
ffi "c++" import "llvm/Support/MemoryBuffer.h"
ffi "c++" import "llvm/Support/TargetSelect.h"
ffi "c++" import "llvm/Support/VirtualFileSystem.h"
ffi "c++" import "llvm/Support/raw_ostream.h"
ffi "c++" import "llvm/TargetParser/Triple.h"
ffi "c++" import "Native/KSharedVFS.hh"
ffi "c++" import "Native/KLog.hh"
ffi "c++" import "vector"
ffi "c++" import "memory"
ffi "c++" import "string"
ffi "c++" import "utility"

import Command::FlagTranslator::{
    ClangSpelling,
    FlagTranslator,
}
import Interop::Clang::BuiltinsSet::BuiltinsSet
import Interop::Clang::ClangLocMap::ClangLocMap
import Location::SourceManager::SourceManager
import std::c_char

/// ThreadPool group ids used by the driver for backend tasks.
/// (5 = index, 6 = parse are taken by FrontendAction::_parse.)
pub
const CLANG_STARTUP_GROUP: u8 = 9
/// The runtime's native compiles (run_native), side by side.
pub
const NATIVE_GROUP: u8 = 13


pub struct ClangBackendConfig {
    pub var triple: string ///< effective target triple
    /// SYSROOT.toml's clang_triple: what clang is handed for this sysroot,
    /// so the driver no longer derives it. "" (an older root, no root)
    /// keeps FlagTranslator::clang_triple.
    pub var clang_triple: string
    pub var resource_dir: string ///< clang resource dir ("" = skip)
    pub var sysroot:      string ///< sysroot dir ("" = host headers): -isysroot
    /// Header roots a SYSROOT.toml declares (or an Apple SDK implies), already
    /// absolute. libc++ dirs are split out because they go BEFORE the clang
    /// builtin headers and are skipped for C. Both empty = the prefix model:
    /// <sysroot>/include/c++/v1 and <sysroot>/include.
    pub var cxx_include_dirs: cxx::std::vector<string>
    pub var include_dirs:     cxx::std::vector<string>
    pub var framework_dirs:   cxx::std::vector<string> ///< -iframework (Apple: System/Library/Frameworks)
    /// The host's system include dirs in the default build (TargetOptions::
    /// host_mode "floor"): -idirafter, so they are searched after every
    /// sysroot root and only supply headers the sysroot lacks.
    pub var after_dirs: cxx::std::vector<string>
    /// Hermetic (--target): the C/C++ input driver line drops the dirs
    /// clang's driver takes from CPATH, C_INCLUDE_PATH and
    /// CPLUS_INCLUDE_PATH itself (ClangJobs), as Kairo's own line never
    /// adds them.
    pub var strip_env: bool = false
    /// Macros a SYSROOT.toml's cc_defines requires (-D<name>): the ones its
    /// prebuilt libc++ was compiled with, which the TU must match to link.
    pub var defines:   cxx::std::vector<string>
    pub var cxx_std:   string                   = "c++26"
    var     c_std:     string                   = "c17" ///< -std for C inputs (--c-std)
    var     includes:  cxx::std::vector<string> ///< -include names (predefines buffer)
    pub var extra_cc1: cxx::std::vector<string> ///< platform extras (exception model, PIC, CPU, ...)
    pub var wargs:     cxx::std::vector<string> ///< diagnostic -W/-Wno-/-Werror= args from user policy, injected pre-CreateFromArgs
    pub var opt_level: i32                      = 0 ///< -O level, 0-3 (s and z are 2)
    pub var opt_size:  i32                      = 0 ///< 0 none, 1 -Os, 2 -Oz
    pub var vectorize: bool                     = true ///< loop + SLP vectorizers above -O0 (-f[no-]vectorize)
    /// -g and its modifiers. Handed to the driver probe, never spelled as
    /// cc1 flags here: the driver picks CodeView or DWARF, the debugger
    /// tuning and the info kind per target (see _driver_target_args).
    pub var debug_info:    bool = false
    pub var dwarf_version: i32  = 0     ///< 0 = the target's default (MSVC: CodeView)
    pub var debug_macros:  bool = false ///< -fdebug-macro
    pub var embed_source:  bool = false ///< -gembed-source
    /// Extra words for the driver probe in _driver_target_args (--march). They
    /// go to the clang DRIVER, never to cc1: cc1 has no -march, and what the
    /// driver makes of one (-target-cpu plus a -target-feature per implied
    /// extension) is only right per architecture.
    pub var driver_words: cxx::std::vector<string>
}

/// \class CodegenMounts
/// \brief What every codegen TU's VFS holds on top of the real file system:
///        the PCH bytes phase B loads, and the wrapper headers that replay a
///        set textually. Filled on the driver thread before the fan-out and
///        read-only after it.
///
/// \details freeze() builds the in-memory layer once, right before the
///          fan-out, and every TU's VFS (codegen_vfs) shares it. Before the
///          freeze -- the interface PCH builds, each of which adds its own
///          PCH after it is built -- codegen_vfs builds a layer of its own per
///          call, as every TU used to: InMemoryFileSystem::addFile hashes the
///          whole of each file's contents into its UniqueID, so per TU that
///          was ~50 MB of PCH hashed and every wrapper text copied, ~2% of the
///          fan-out's CPU (gdb samples).
///
///          Sharing it is safe because nothing writes it after the freeze:
///          add_* refuses, and the reads clang makes through it (status,
///          openFileForRead, dir_begin, getRealPath) only walk the node tree
///          and hand out views of the buffers. Its one write a TU reaches is
///          setCurrentWorkingDirectory, which OverlayFileSystem::pushOverlay
///          makes on every layer pushed: a TU therefore pushes a proxy that
///          drops it (Native/KSharedVFS.hh), and freeze() sets the layer's
///          working directory once, to what pushOverlay would have copied.
pub class CodegenMounts {
    pub var pch_paths:  cxx::std::vector<string>
    pub var pch_data:   cxx::std::vector<unsafe *llvm::SmallVector<c_char, 0>> ///< owned by the set / CodegenPCH
    pub var text_paths: cxx::std::vector<string>
    pub var texts:      cxx::std::vector<string>
    /// The layer every TU shares once frozen; null before freeze() and after
    /// release().
    priv var _shared: llvm::IntrusiveRefCntPtr<llvm::vfs::InMemoryFileSystem>
    priv var _frozen: bool                                                    = false

    pub fn add_pch(self, const path: string, data: unsafe *llvm::SmallVector<c_char, 0>) {
        if self._frozen {
            kairo::std::ice_fail("CodegenMounts::add_pch after freeze()")
        }

        for *p in self.pch_paths {
            if *p == path {
                return
            }
        }

        self.pch_paths.push_back(path)
        self.pch_data.push_back(data)
    }

    pub fn add_text(self, const path: string, const text: string) {
        if self._frozen {
            kairo::std::ice_fail("CodegenMounts::add_text after freeze()")
        }

        for *p in self.text_paths {
            if *p == path {
                return
            }
        }

        self.text_paths.push_back(path)
        self.texts.push_back(text)
    }

    /// Driver thread, after the last add_* and before the fan-out: the one
    /// in-memory layer every TU's VFS then shares.
    pub fn freeze(self) {
        if self._frozen {
            return
        }

        self._shared = self.layer()
        kairo::shared_layer_sync_cwd(self._shared, llvm::vfs::getRealFileSystem())
        self._frozen = true
    }

    /// Driver thread, after the fan-out's join: drops the shared layer, whose
    /// PCH views point into buffers the driver frees next.
    pub fn release(self) {
        self._shared.reset()
    }

    fn frozen(self) -> bool {
        return self._frozen && self._shared.get() != &null
    }

    /// The shared layer (freeze()). Any thread; read-only.
    fn shared_layer(self) -> llvm::IntrusiveRefCntPtr<llvm::vfs::InMemoryFileSystem> {
        return self._shared
    }

    /// \brief a fresh in-memory layer holding every mount.
    ///
    /// \details The PCH bytes are mounted as views of the buffers this
    ///          lists (they outlive every TU); the small wrapper texts are
    ///          copied.
    fn layer(self) -> llvm::IntrusiveRefCntPtr<llvm::vfs::InMemoryFileSystem> {
        var mem = llvm::makeIntrusiveRefCnt<llvm::vfs::InMemoryFileSystem>()
        for var i: usize = 0; i < self.pch_paths.size(); ++i {
            var unsafe *d = self.pch_data[i]
            var buf = llvm::MemoryBuffer::getMemBuffer(
                llvm::StringRef(d->data(), d->size()),
                kairo::sref(self.pch_paths[i]),
                false,
            )

            mem->addFile(llvm::Twine(kairo::sref(self.pch_paths[i])), 0, cxx::std::move(buf))
        }

        for var i: usize = 0; i < self.text_paths.size(); ++i {
            var buf = llvm::MemoryBuffer::getMemBufferCopy(
                kairo::sref(self.texts[i]),
                llvm::Twine(kairo::sref(self.text_paths[i])),
            )

            mem->addFile(llvm::Twine(kairo::sref(self.text_paths[i])), 0, cxx::std::move(buf))
        }

        return mem
    }
}

pub class ClangBackend {
    priv var _ksm:    unsafe *SourceManager ///< driver-owned, outlives this
    priv var _cfg:    ClangBackendConfig
    priv var _locmap: unsafe *ClangLocMap   ///< freed in op finally

    /// # persistent clang state (built once in _startup_locked)

    priv var _vfs: llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem>
    /// Top layer of _vfs. Phase B does not mount here: codegen TUs read
    /// CodegenMounts' layer (codegen_vfs), filled before the fan-out.
    priv var _mem:       llvm::IntrusiveRefCntPtr<llvm::vfs::InMemoryFileSystem>
    priv var _diag_opts: clang::DiagnosticOptions ///< plain value type in 22.x
    priv var _diags0:    llvm::IntrusiveRefCntPtr<clang::DiagnosticsEngine> ///< arg-parse engine
    priv var _cinv:      cxx::std::shared_ptr<clang::CompilerInvocation>
    priv var _ci:        unsafe *clang::CompilerInstance                         = &null ///< owned; freed in op finally
    priv var _printer:   unsafe *clang::TextDiagnosticPrinter                    = &null ///< owned; engine borrows

    /// cc1 argv backing store deque: stable addresses under growth,
    /// clang keeps no references past CreateFromArgs but c_str()s must
    /// stay valid for the duration of the call.
    /// Bytes behind every argv pointer handed to clang. A bump arena, not a
    /// container of strings: argv keeps raw pointers while more are added,
    /// and a vector would move its strings (SSO bytes live inside them).
    /// StringSaver NUL-terminates, which argv needs.
    priv var _owned: llvm::BumpPtrAllocator

    priv var _target_args:  cxx::std::vector<string>         ///< see _driver_target_args
    priv var _target_known: bool                     = false
    /// The driver's C++ FP defaults for this target, which probe_filter
    /// drops (Kairo's line has its own): what an ffi header region is
    /// restored to (header_fp_pragmas).
    priv var _cxx_contract:   string = ""
    priv var _cxx_math_errno: bool   = false

    priv var _mu:      kairo::std::Mutex         ///< serializes startup against itself
    priv var _started: bool              = false
    priv var _failed:  bool              = false
    priv var _oracle:  BuiltinsSet

    /// # Construction

    fn ClangBackend(self, ksm: unsafe *SourceManager, const cfg: ClangBackendConfig) {
        if ksm == &null {
            kairo::std::ice_fail("ClangBackend: a valid Kairo SourceManager is required")
        }

        self._ksm    = ksm
        self._cfg    = cfg
        self._locmap = kairo::std::create<ClangLocMap>(ksm)
    }

    fn op finally (self) {
        // The oracle's own CI borrows _printer too: it goes first.
        self._oracle.release()

        // CI's engine borrows _printer (ShouldOwnClient=false everywhere):
        // release the CI and the arg-parse engine BEFORE the printer dies.
        if self._ci != &null {
            kairo::std::destroy(self._ci)
            self._ci = &null
        }

        self._diags0 = llvm::IntrusiveRefCntPtr<clang::DiagnosticsEngine>()

        if self._printer != &null {
            kairo::std::destroy(self._printer)
            self._printer = &null
        }

        if self._locmap != &null {
            kairo::std::destroy(self._locmap)
            self._locmap = &null
        }
    }

    /// # State

    /// Ready to RUN an action. Deliberately not gated on _locmap->ready():
    /// the map is bound inside the action window by rebind(), so requiring it
    /// here would be a chicken-and-egg deadlock on the very first TU.
    pub fn ready(self) -> bool {
        return self._started && !self._failed
    }

    fn failed(self) -> bool {
        return self._failed
    }

    fn ci(self) -> unsafe *clang::CompilerInstance {
        return self._ci
    }

    fn locmap(self) -> unsafe *ClangLocMap {
        return self._locmap
    }

    pub fn ksm(self) -> unsafe *SourceManager {
        return self._ksm
    }

    pub fn invocation(self) -> unsafe *clang::CompilerInvocation {
        return self._cinv.get()
    }

    fn vfs(self) -> llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem> {
        return self._vfs
    }

    /// \brief the pragma lines around every ffi header region, phase A's
    ///        PCH buffer and phase B's textual wrapper alike: see
    ///        FlagTranslator::header_fp_pragmas.
    ///        After startup() only: the probe that fills the C++ defaults runs
    ///        there, under its mutex, and pool threads call this.
    pub fn header_fp_pragmas(self,
                             open:  unsafe *cxx::std::vector<string>,
                             close: unsafe *cxx::std::vector<string>) {
        // clang ignores float_control (C459W per region) on a target
        // without strict FP support unless the experimental flag forces it.
        var fc = true
        if self._ci != &null && self._ci->hasTarget() {
            fc = self._ci->getTarget().hasStrictFP() || self._ci->getLangOpts().ExpStrictFP != 0
        }

        FlagTranslator::header_fp_pragmas(
            self._cxx_contract,
            self._cxx_math_errno,
            &self._cfg.extra_cc1,
            fc,
            &*open,
            &*close,
        )
    }

    fn mem_fs(self) -> unsafe *llvm::vfs::InMemoryFileSystem {
        return self._mem.get()
    }

    pub fn oracle(self) -> unsafe *BuiltinsSet {
        if !self.ready() {
            return &null
        }

        if !self._oracle.ready() {
            return &null
        }

        return unsafe &self._oracle
    }

    /// \brief the invocation for compiling one C or C++ source file to an
    ///        object, on the same target and roots as Kairo's own codegen: a
    ///        FRESH one from the shared cc1 arguments rather than a copy of
    ///        the backend's. run_native() compiles it.
    ///
    /// \details a copy carries C++ LangOptions, and a .c file must get
    ///          clang's C defaults. Only the runtime (Lib/rt) is built here;
    ///          the user's C/C++ inputs go through clang's driver
    ///          (ClangJobs). \p extra is appended after the shared
    ///          arguments: the runtime's own header roots (the vendored
    ///          mimalloc's include/), which no other TU may see. Driver
    ///          thread only: the argv bytes come from this backend's arena
    ///          and a bad argument reports through the shared arg-parse
    ///          engine. Null on failure.
    ///
    ///          \p key, when not null, receives every argument but the
    ///          trailing `-o <out>`, one per line: what the object's bytes
    ///          depend on besides the files it reads, so the driver's runtime
    ///          object cache (CompilerInstance::_compile_runtime) can key on
    ///          the exact line rather than a re-derivation of it that could
    ///          miss a flag. The output path is left out because it is a
    ///          per-build temp directory and does not reach the object; so
    ///          is the working directory, unless debug info or coverage
    ///          mapping records it.
    pub fn native_invocation(self, const src: string, const out: string, const xlang: string, is_c: bool, extra: cxx::std::vector<string>, key: unsafe *string)
            -> cxx::std::shared_ptr<clang::CompilerInvocation> {
        var none = cxx::std::shared_ptr<clang::CompilerInvocation>()
        self.startup()
        if !self.ready() {
            return none
        }

        var argv: cxx::std::vector<kairo::std::ConstPtr<c_char>>
        // Lib/rt is C/C++ source: it keeps clang's C/C++ FP defaults.
        self._cc1_common(unsafe &argv, is_c, false)
        // The runtime is the allocator (mimalloc) and every program's hot
        // path: built at -O0 with the user's code, each allocation costs
        // several times what it does at -O2. So -O2 at least; a higher
        // level or a size level the user asked for is kept. cc1 takes the
        // last -O. Debug info is unaffected (it comes with the target words).
        if self._cfg.opt_size == 0 && self._cfg.opt_level < 2 {
            var rt_fvec: i32 = if (self._cfg.vectorize) => (1) else => 0
            for var a: string in FlagTranslator::optimization(2, 0, rt_fvec, ClangSpelling::CC1) {
                self._arg(&argv, a)
            }
        }

        for *a in extra {
            self._arg(&argv, (*a))
        }

        // -std only for the languages it names: IR has none, and an ObjC or
        // OpenCL standard is not a C++ one.
        if xlang == "c" || xlang == "cpp-output" {
            self._arg(&argv, f"-std={self._cfg.c_std}")
        } else if xlang == "c++" || xlang == "c++-cpp-output" {
            self._arg(&argv, f"-std={self._cfg.cxx_std}")
        }

        self._arg(&argv, "-x")
        self._arg(&argv, xlang)
        self._arg(&argv, src)
        if key != &null {
            // The working directory reaches the line as the debug and
            // coverage compilation dirs (clang's driver adds them always),
            // but the object only records it under debug info or coverage
            // mapping. Left out otherwise, or every directory a program is
            // linked from would hold its own copy of the runtime.
            var dbg = false
            var cov = false
            for var i: usize = 0; i < argv.size(); ++i {
                var a = string(unsafe ((argv[i] as unsafe *const u8) as *const u8))
                if a.starts_with("-debug-info-kind=") {
                    dbg = true
                }

                if a == "-fcoverage-mapping" {
                    cov = true
                }
            }

            for var i: usize = 0; i < argv.size(); ++i {
                var a = string(unsafe ((argv[i] as unsafe *const u8) as *const u8))
                if !dbg && a.starts_with("-fdebug-compilation-dir") {
                    continue
                }

                if !cov && a.starts_with("-fcoverage-compilation-dir") {
                    continue
                }

                *key += a + "\n"
            }
        }

        self._arg(&argv, "-o")
        self._arg(&argv, out)
        // The whole line under -v: nothing else shows what the runtime was
        // built with (its -O is not the user's, see above).
        var line = "cc1"
        for var i: usize = 0; i < argv.size(); ++i {
            line += " " + string(unsafe ((argv[i] as unsafe *const u8) as *const u8))
        }

        kairo::Logger::info(kairo::Logger::Stage::Driver, line)

        var inv = cxx::std::make_shared<clang::CompilerInvocation>()
        if !clang::CompilerInvocation::CreateFromArgs(
            &*inv.get(),
            llvm::ArrayRef<unsafe *const c_char>(argv),
            &*self._diags0.get(),
        ) {
            kairo::Logger::error(
                kairo::Logger::Stage::Driver,
                f"ClangBackend: cannot build an invocation for {src}",
            )

            return none
        }

        return inv
    }

    /// \brief runs one native_invocation() to its object. Any thread.
    ///
    /// \details Own CompilerInstance and own printer, writing to \p log
    ///          rather than stderr, so the runtime's files compile side by
    ///          side and the caller prints what they said in input order.
    ///          These files have no Kairo fid, so they are reported in
    ///          clang's own format. The backend's VFS is only read here: no
    ///          mount happens while native compiles run.
    ///
    ///          The later `#include "foo.k"` work installs the patched
    ///          FileTokenizer hook on this instance's Preprocessor; nothing
    ///          else about the shape changes.
    pub fn run_native(self,
                      inv:        cxx::std::shared_ptr<clang::CompilerInvocation>,
                      @inout log: string) -> bool {
        var text: cxx::std::string
        var ok                     = false
        {
            var        os      = llvm::raw_string_ostream(&text)
            var        printer = clang::TextDiagnosticPrinter(&os, &inv.get()->getDiagnosticOpts())
            var unsafe *ci     = kairo::std::create<clang::CompilerInstance>(inv)
            ci->setVirtualFileSystem(self._vfs)
            ci->createDiagnostics(unsafe &printer, false)
            if ci->hasDiagnostics() {
                ci->setTarget(
                    clang::TargetInfo::CreateTargetInfo(
                        &ci->getDiagnostics(),
                        &ci->getInvocation().getTargetOpts(),
                    ),
                )

                if ci->hasTarget() {
                    var act = clang::EmitObjAction()
                    ok = ci->ExecuteAction(&act) && ci->getDiagnostics().getNumErrors() == 0
                }
            }

            // The engine borrows the printer: the instance goes first.
            kairo::std::destroy(ci)
            os.flush()
        }

        (log) += string(unsafe ((text.data() as unsafe *const u8) as *const u8), text.size())
        return ok
    }

    /// \brief a codegen TU's own VFS: the real file system under the
    ///        in-memory layer of \p m.
    ///
    /// \details Any thread. The overlay is the TU's own; the layer is the one
    ///          \p m shares once frozen (CodegenMounts::freeze), pushed
    ///          through a proxy that keeps pushOverlay's working-directory
    ///          write off it (Native/KSharedVFS.hh), else a fresh one for this
    ///          call.
    pub fn codegen_vfs(self, m: *CodegenMounts) -> llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem> {
        var overlay = llvm::makeIntrusiveRefCnt<llvm::vfs::OverlayFileSystem>(
            llvm::vfs::getRealFileSystem(),
        )

        if m->frozen() {
            overlay->pushOverlay(kairo::shared_layer_view(m->shared_layer()))
        } else {
            var mem = m->layer()
            overlay->pushOverlay(llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem>(mem))
        }

        var fs: llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem> = llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem>(
            overlay,
        )

        return fs
    }

    fn csm(self) -> unsafe *clang::SourceManager {
        if self._ci == &null || !self._started {
            return &null
        }

        return unsafe &self._ci->getSourceManager()
    }

    /// # Startup (pool task, group CLANG_STARTUP_GROUP)

    /// All of clang's expensive one-time setup. Idempotent and mutex-guarded
    /// against itself; no other task touches clang state off-thread.
    pub fn startup(self) {
        var lock = kairo::std::LockGuard(self._mu)
        self._startup_locked()
    }

    /// # Internals

    /// The cc1 argv of the shared invocation, which every compile copies.
    /// One builder for _startup_locked and invocation_args, so what
    /// --print-clang-args shows is what runs.
    priv fn _shared_argv(self, argv: unsafe *cxx::std::vector<kairo::std::ConstPtr<c_char>>) {
        self._cc1_common(argv, false, true)
        self._arg(&*argv, f"-std={self._cfg.cxx_std}")

        // Placeholder input; per-TU runs replace FrontendOpts.Inputs with the
        // injected in-memory buffer before ExecuteAction.
        self._arg(&*argv, "-x")
        self._arg(&*argv, "c++")
        self._arg(&*argv, "<injected>")
    }

    /// \brief the shared invocation's cc1 arguments, for --print-clang-args.
    ///
    /// \details the argv _startup_locked parses, then each configured
    ///          -include, which the backend hands to the preprocessor options
    ///          directly and cc1 would take as the flag. Nothing is started.
    pub fn invocation_args(self) -> cxx::std::vector<string> {
        var argv: cxx::std::vector<kairo::std::ConstPtr<c_char>>
        self._shared_argv(unsafe &argv)
        var out = cxx::std::vector<string>()
        for var i: usize = 0; i < argv.size(); ++i {
            out.push_back(string(unsafe ((argv[i] as unsafe *const u8) as *const u8)))
        }

        for *inc in self._cfg.includes {
            out.push_back("-include")
            out.push_back(*inc)
        }

        return out
    }

    priv fn _arg(self,
                 @inout argv: cxx::std::vector<kairo::std::ConstPtr<c_char>>,
                 const s:     string) {
        argv.push_back(llvm::StringSaver(&self._owned).save(kairo::sref(s)).data())
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
    /// The driver's cc1 line for this target and the build's driver words.
    /// Empty when the driver gives none.
    priv fn _probe_cc1(self) -> cxx::std::vector<string> {
        var owned: llvm::BumpPtrAllocator ///< argv bytes, for this call (see _owned).
        var dargv: cxx::std::vector<kairo::std::ConstPtr<c_char>>
        var words                                                 = cxx::std::vector<string>()
        words.push_back("clang")
        words.push_back("--target=" + self._clang_triple())
        words.push_back(f"-std={self._cfg.cxx_std}")
        for *w in self._cfg.driver_words {
            words.push_back(*w)
        }

        var macro_triple = self._clang_triple()
        var macro_info   = FlagTranslator::macros_for(self._cfg.debug_macros, macro_triple)
        for var w: string in FlagTranslator::debug_driver(self._cfg.debug_info, self._cfg.dwarf_version,
                                                      macro_info, self._cfg.embed_source) {
            words.push_back(w)
        }

        words.push_back("-fsyntax-only")
        words.push_back("-x")
        words.push_back("c++")
        words.push_back("-")
        for *w in words {
            dargv.push_back(llvm::StringSaver(&owned).save(kairo::sref(*w)).data())
        }

        var cc1:  cxx::std::vector<cxx::std::string>
        var opts: clang::CreateInvocationOptions
        opts.CC1Args = unsafe &cc1
        var inv = clang::createInvocation(llvm::ArrayRef<unsafe *const c_char>(dargv), opts)
        var out = cxx::std::vector<string>()
        for var i: usize = 0; i < cc1.size(); ++i {
            out.push_back(
                string(unsafe ((cc1[i].data() as unsafe *const u8) as *const u8), cc1[i].size()),
            )
        }

        return out
    }

    priv fn _driver_target_args(self) -> cxx::std::vector<string> {
        if self._target_known {
            return self._target_args
        }

        self._target_known = true

        var cc1 = self._probe_cc1()
        if cc1.empty() {
            kairo::Logger::error(
                kairo::Logger::Stage::Driver,
                f"ClangBackend: clang's driver gave no cc1 line for {self._cfg.triple} (a bad --march fails this probe); compiling without target defaults",
            )

            return self._target_args
        }

        // C++'s FP defaults, before the filter drops them: an ffi header
        // region is put back to these (header_fp_pragmas).
        for var i: usize = 0; i < cc1.size(); ++i {
            var a = string(&cc1[i])
            if a.starts_with("-ffp-contract=") {
                self._cxx_contract = string(
                    unsafe (((a.raw() as unsafe *const u8) + 14) as *const u8),
                    a.size() - 14,
                )
            }

            if a == "-fmath-errno" {
                self._cxx_math_errno = true
            }
        }

        // Which of the driver's cc1 words decide the target is the
        // translator's call (FlagTranslator::probe_filter).
        for var a: string in FlagTranslator::probe_filter(&cc1) {
            self._target_args.push_back(a)
        }

        return self._target_args
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
    ///          layout is what every sysroot's SYSROOT.toml declares (include_dirs
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
    pub fn sysroot_words(self, is_c: bool, sp: ClangSpelling) -> cxx::std::vector<string> {
        var o        = cxx::std::vector<string>()
        var cc1      = sp == ClangSpelling::CC1
        var sr       = self._cfg.sysroot
        var rd       = self._cfg.resource_dir
        var declared = !self._cfg.include_dirs.empty() || !self._cfg.cxx_include_dirs.empty()
        o.push_back(if (cc1) => ("-nostdsysteminc") else => "-nostdlibinc")
        o.push_back("-nostdinc++")
        if !rd.empty() {
            o.push_back("-resource-dir")
            o.push_back(rd)
        }

        if declared {
            if !is_c {
                for *d in self._cfg.cxx_include_dirs {
                    o.push_back("-isystem")
                    o.push_back(*d)
                }
            }

            if !rd.empty() {
                o.push_back("-isystem")
                o.push_back(f"{rd}/include")
            }

            for *d in self._cfg.include_dirs {
                o.push_back("-isystem")
                o.push_back(*d)
            }
        } else {
            if !sr.empty() && !is_c {
                o.push_back("-isystem")
                o.push_back(f"{sr}/include/c++/v1")
            }

            if !rd.empty() {
                o.push_back("-isystem")
                o.push_back(f"{rd}/include")
            }

            if !sr.empty() {
                o.push_back("-isystem")
                o.push_back(f"{sr}/include")
            }
        }

        for *d in self._cfg.after_dirs {
            o.push_back("-idirafter")
            o.push_back(*d)
        }

        // Those dirs sit beside a sysroot on purpose; clang reads any
        // /usr/include next to a --sysroot as a cross-compile accident and
        // says so under -Weverything (-Wpoison-system-directories).
        if !self._cfg.after_dirs.empty() {
            o.push_back("-Wno-poison-system-directories")
        }

        for *d in self._cfg.framework_dirs {
            o.push_back("-iframework")
            o.push_back(*d)
        }

        if !sr.empty() {
            o.push_back("-isysroot")
            o.push_back(sr)
        }

        // The driver also anchors its toolchain search (crt, gcc install
        // detection) on --sysroot; without it that search is the host's.
        if !cc1 && !sr.empty() {
            o.push_back(f"--sysroot={sr}")
        }

        // The driver adds the builtin directory itself, as an internal
        // system root; cc1 has to be told (builtin <stdint.h> -> uintptr_t).
        if cc1 && !rd.empty() {
            o.push_back("-internal-isystem")
            o.push_back(f"{rd}/include")
        }

        for *d in self._cfg.defines {
            o.push_back(f"-D{(*d)}")
        }

        return o
    }

    /// The effective target triple every compile in this build uses.
    pub fn triple(self) -> string {
        return self._cfg.triple
    }

    /// The sysroot's clang_triple, "" when its SYSROOT.toml has none.
    pub fn sysroot_clang_triple(self) -> string {
        return self._cfg.clang_triple
    }

    /// The triple clang's words carry: the sysroot's own clang_triple when
    /// it names one, else derived from the build's triple. The sysroot's
    /// spelling still goes through FlagTranslator::clang_triple: its
    /// wasm32-unknown-wasi names the compiler-rt dir, and clang wants wasip1.
    priv fn _clang_triple(self) -> string {
        if !self._cfg.clang_triple.empty() {
            return FlagTranslator::clang_triple(self._cfg.clang_triple)
        }

        return FlagTranslator::clang_triple(self._cfg.triple)
    }

    /// Whether host env search paths are dropped from driver lines.
    fn strip_env(self) -> bool {
        return self._cfg.strip_env
    }

    /// The printer clang's own diagnostics go to (C/C++ inputs have no Kairo
    /// fid, so they are reported in clang's format). Null before startup().
    fn printer(self) -> unsafe *clang::TextDiagnosticPrinter {
        return self._printer
    }

    /// The engine clang's driver and cc1 argument parsing report through.
    fn arg_diags(self) -> unsafe *clang::DiagnosticsEngine {
        return self._diags0.get()
    }

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
    priv fn _cc1_common(self,
                        argv:    unsafe *cxx::std::vector<kairo::std::ConstPtr<c_char>>,
                        is_c:    bool,
                        kairo_v: bool) {
        self._arg(&*argv, "-triple")
        self._arg(&*argv, self._clang_triple())
        for var a: string in self._driver_target_args() {
            self._arg(&*argv, a)
        }

        // Kairo's i128 and f128 exist on every target. clang offers __int128
        // only at 64-bit pointer width unless told; the backend expands it
        // (and compiler-rt's tf routines need it) on 32-bit targets too.
        self._arg(&*argv, "-fforce-enable-int128")
        // C++ lets the optimizer assume a side-effect-free loop terminates
        // and delete it; Kairo makes no such promise. `loop {}` as a
        // firmware idle or a spin on a register must stay a loop.
        self._arg(&*argv, "-fno-finite-loops")
        self._arg(&*argv, "-emit-obj")

        // Header search and the sysroot's macros: the one root model,
        // shared with C/C++ inputs (sysroot_words says why it is explicit).
        for var a: string in self.sysroot_words(is_c, ClangSpelling::CC1) {
            self._arg(&*argv, a)
        }

        // Kairo's FP semantics, ahead of extra_cc1 so the user's own FP
        // flags (cc1 takes the last) still win.
        if kairo_v {
            for var a: string in FlagTranslator::kairo_fp_cc1() {
                self._arg(&*argv, a)
            }
        }

        // Devirtualization clang leaves off by default, both semantics-
        // preserving: a speculative direct call guarded by a vtable compare,
        // and vtables emitted in every TU that can see them, so more calls
        // resolve. Not -fstrict-vtable-pointers (assumes storage holding a
        // polymorphic object is never reused without launder, which a
        // byte-relocating container breaks) nor -fstrict-enums (a C enum
        // from a header may hold flag combinations). Above -O0 only, and
        // ahead of extra_cc1 so the user's -fno-... still wins.
        if !is_c && (self._cfg.opt_level > 0 || self._cfg.opt_size > 0) {
            self._arg(&*argv, "-fdevirtualize-speculatively")
            self._arg(&*argv, "-fforce-emit-vtables")
        }

        // The address-significance table safe ICF needs (the linker folds
        // only what no one takes the address of; Config/Linker.k turns ICF
        // on above -O0): where clang's own driver emits it, ELF and COFF
        // minus Android, NetBSD, PS4 and VE. Harmless without ICF.
        var tri = llvm::Triple(llvm::Triple::normalize(kairo::sref(self._cfg.triple)))
        if (tri.isOSBinFormatELF() || tri.isOSBinFormatCOFF())
            && !tri.isAndroid()
            && !tri.isOSNetBSD()
            && !tri.isPS4()
            && tri.getArch() != llvm::Triple::ve {
            self._arg(&*argv, "-faddrsig")
        }

        // Not -mconstructor-aliases, though clang's own driver passes it on
        // most targets: with it the complete constructor becomes an alias of
        // the base one, and the base-object constructor of a Kairo template
        // (Uninitialized<T> in destroy) stopped inlining -- Tests/alloc/perf.k
        // and the container perf pins went from no call to one.
        for *a in self._cfg.extra_cc1 {
            self._arg(&*argv, (*a))
        }

        // Optimization level, as cc1 flags rather than CodeGenOpts fields:
        // cc1's own parsing then sets everything that hangs off the level
        // (OptimizationLevel, OptimizeSize, the inliner mode, LangOpts
        // Optimize/OptimizeSize, no optnone above -O0) in step. Here, not per
        // TU, because every compile copies this invocation: the header-set
        // PCHs (whose reader rejects an __OPTIMIZE__ mismatch), the native
        // runtime objects and every TU's codegen run alike -- so builtin,
        // std and the user's code are always built at one level.
        var fvec: i32 = if (self._cfg.vectorize) => (1) else => 0
        for var a: string in FlagTranslator::optimization(self._cfg.opt_level, self._cfg.opt_size, fvec, ClangSpelling::CC1) {
            self._arg(&*argv, a)
        }

        // (The vectorizers come with the level: FlagTranslator::optimization
        // says why kairo asks for them at every level above -O0.)

        // User diagnostic policy for clang-sourced diagnostics: -W<grp> (enable),
        // -Wno-<grp> (silence), -Werror=<grp> (promote/forbid). Resolved from
        // Kairo C-codes to clang warning groups by the driver. Injected here so
        // clang honours them at analysis time, not just post-hoc at emit.
        for *a in self._cfg.wargs {
            self._arg(&*argv, (*a))
        }
    }

    /// \brief hands the invocation's -mllvm words to LLVM's option parser.
    ///
    /// \details CreateFromArgs only RECORDS them in FrontendOptions::LLVMArgs;
    ///          the parse is done by clang's cc1_main (ExecuteCompilerInvocation),
    ///          which this backend never goes through, so without this every
    ///          --mllvm (and the flags lowered to one) would be accepted and
    ///          dropped. Once per process: the options are global state.
    ///
    /// \return false when LLVM rejected a word; LLVM has printed why.
    priv fn _apply_llvm_args(self) -> bool {
        var n = self._cinv.get()->getFrontendOpts().LLVMArgs.size()
        if n == 0 {
            return true
        }

        var av: cxx::std::vector<kairo::std::ConstPtr<c_char>>
        self._arg(&av, "kairo (LLVM option parsing)")
        for var i: usize = 0; i < n; ++i {
            self._arg(
                &av,
                kairo::std::from_std_string<string>(
                    self._cinv.get()->getFrontendOpts().LLVMArgs[i],
                ),
            )
        }

        // Errors go to a stream and come back as false: without one LLVM calls
        // exit(1), here on a pool thread, for a mistyped --mllvm word.
        var        ov  = "kairo"
        var unsafe *es = unsafe &llvm::errs()
        if !llvm::cl::ParseCommandLineOptions(av.size() as i32, av.data(), kairo::sref(ov), es) {
            kairo::Logger::error(
                kairo::Logger::Stage::Driver,
                "ClangBackend: an --mllvm word was not accepted by LLVM",
            )

            return false
        }

        return true
    }

    priv fn _startup_locked(self) {
        if self._started || self._failed {
            return
        }

        llvm::InitializeNativeTarget()
        llvm::InitializeNativeTargetAsmPrinter()

        var overlay = llvm::makeIntrusiveRefCnt<llvm::vfs::OverlayFileSystem>(
            llvm::vfs::getRealFileSystem(),
        )

        self._mem = llvm::makeIntrusiveRefCnt<llvm::vfs::InMemoryFileSystem>()
        overlay->pushOverlay(llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem>(self._mem))
        self._vfs = llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem>(overlay)
        self._printer = kairo::std::create<clang::TextDiagnosticPrinter>(
            llvm::errs(),
            self._diag_opts,
        )

        // Standalone engine for cc1 arg parsing; the CI builds its own below.
        self._diags0 = clang::CompilerInstance::createDiagnostics(
            &*self._vfs.get(),
            &self._diag_opts,
            self._printer,
            false,
        )

        // cc1 argv: mirrors what `clang --target=<triple> -###` emits for the
        // configured sysroot target setup, predefines, header search all
        // come from CreateFromArgs instead of hand-set option fields.
        var argv: cxx::std::vector<kairo::std::ConstPtr<c_char>>

        self._shared_argv(unsafe &argv)

        self._cinv = cxx::std::make_shared<clang::CompilerInvocation>()

        if !clang::CompilerInvocation::CreateFromArgs(
            &*self._cinv.get(),
            llvm::ArrayRef<unsafe *const c_char>(argv),
            &*self._diags0.get(),
        ) {
            kairo::Logger::error(
                kairo::Logger::Stage::Driver,
                "ClangBackend: CompilerInvocation::CreateFromArgs failed",
            )

            self._failed = true
            return
        }

        // A rejected word fails the startup HERE, like every other failure in
        // this function: carrying on built the instance and the oracle and set
        // _started, so the backend was failed and started at once and csm()
        // answered for a backend ready() refused.
        if !self._apply_llvm_args() {
            self._failed = true
            return
        }

        // -include names travel via the predefines buffer.
        for *inc in self._cfg.includes {
            self._cinv.get()->getPreprocessorOpts().Includes.push_back(
                kairo::std::to_std_string(*inc),
            )
        }

        self._ci = kairo::std::create<clang::CompilerInstance>(self._cinv)
        self._ci->setVirtualFileSystem(self._vfs)
        self._ci->createDiagnostics(self._printer, false)

        if !self._ci->hasDiagnostics() {
            self._failed = true
            return
        }

        self._ci->setTarget(
            clang::TargetInfo::CreateTargetInfo(
                &self._ci->getDiagnostics(),
                &self._ci->getInvocation().getTargetOpts(),
            ),
        )

        if !self._ci->hasTarget() {
            kairo::Logger::error(
                kairo::Logger::Stage::Driver,
                f"ClangBackend: no target for triple '{self._cfg.triple}'",
            )

            self._failed = true
            return
        }

        self._ci->getTarget().adjust(&self._ci->getDiagnostics(), &self._ci->getLangOpts(), &null)

        // Persistent FileManager + SourceManager: the whole point. Header
        // ContentCaches and Kairo fid buffers load once for the batch.
        self._ci->createFileManager()
        self._ci->createSourceManager()

        // No locmap wiring here: ClangLocMap binds its SourceManager in
        // rebind(), inside the action window. Binding at startup was only ever
        // meaningful because registration also happened outside the window,
        // and that is exactly what produced the stale-FileID bug.
        self._started = true

        // Failure is not fatal: every builtin then misses into R020E.
        if !self._oracle.build(self._cinv.get(), self._vfs, self._printer) {
            kairo::Logger::info(
                kairo::Logger::Stage::Driver,
                "ClangBackend: builtin oracle unavailable",
            )
        }

        kairo::Logger::info(
            kairo::Logger::Stage::Driver,
            f"ClangBackend: started (triple={self._cfg.triple})",
        )
    }
}
