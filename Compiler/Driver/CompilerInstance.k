/// --- The Kairo Project -------------------- Driver/CompilerInstance.k --- ///
///
///   Driver Layer 2 shared resource owner and pipeline dispatcher.
///
///   This file holds the class: its fields, construction and destruction,
///   accessors, initialize() and execute(). The rest of its methods are
///   `extend CompilerInstance` blocks, one file per concern, reaching the
///   fields as `prot` (Driver/module.k makes Driver/ one module):
///     CompilerSetup.k   target/sysroot selection, backend config, invocation
///     CompilerInfo.k    --help, --version, --explain, --print-*
///     CompilerGraph.k   input order, included .k discovery, incremental API
///     CompilerNative.k  the runtime and C/C++ inputs through clang
///     CompilerCache.k   runtime object cache, the Kairo library (--kairo-lib)
///     CompilerLink.k    output planning and the link
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
///   Three-layer driver map
///   ----------------------
///   Layer 1  CompilerInvocation   Strongly-typed options         (Options::*)
///   Layer 2  CompilerInstance     Shared resource hub            (this file)
///   Layer 3  FrontendAction       Per-file pipeline executor     (Driver/FrontendAction.k)
///
///   Ownership
///   ---------
///   Resources are constructed in dependency order and destroyed in reverse.
///   No resource is accessed after its destructor runs.
///
///   Constructed here:
///     ThreadPool, VirtualFileManager, DiagEngine, SourceManager,
///     TokenCacheManager, PrettyDiagConsumer, BasicDiagConsumer, Command
///
///   Constructed in execute():
///     ImportResolver - needs cwd and invocation paths; short-lived per call.
///     FrontendAction - one per input file; heap-allocated for future async dispatch.
///
///   CLI integration
///   ---------------
///   _apply_invocation() maps every invocation field that has a live subsystem
///   setter. Fields without a live subsystem are stored in the invocation for
///   when those subsystems are implemented.
///
///   Thread count
///   ------------
///   ThreadPool is constructed after CLI parsing so thread_count from invocation
///   can be applied at construction time.
///
///   Async upgrade path (FrontendAction)
///   -------------------------------------
///   Phase 1 (current): Load and lex touch shared SM/TCM and run on the driver
///   thread. Subsequent stages (preprocess -> codegen) are per-file and will be
///   dispatchable to the pool once SM/TCM are read-only from that point forward.
///   The execute() loop below is where pool enqueueing will be inserted.
///
///   Driver Layer 3 FrontendAction
///   ===============================
///
///   FrontendAction owns the compilation pipeline for a single source file.
///   CompilerInstance constructs one per input file and calls run(), which
///   advances the file through every requested stage in order:
///
///     Load -> Lex -> Preprocess -> Parse -> Sema -> Codegen
///
///   Each stage is gated by FrontendOptions. A stop-at flag (stops_at_preprocess,
///   stops_at_parse, stops_at_sema) causes run() to mark the TU Done and return
///   without running later stages. A stage returning false halts the pipeline
///   and marks the TU Failed. A fatal diagnostic additionally sets
///   BatchResult::aborted, causing execute() to skip remaining input files.
///
///   Post-stage dump flags (print_tokens, print_macros, print_imports, print_ast,
///   print_cg, print_bcir) are checked at each stage boundary and are orthogonal
///   to the stop-at flags they do not halt the pipeline.
///
///   Clang-style layer map
///   ----------------------
///     Layer 1  CompilerInvocation   Strongly-typed options     (Options::*)
///     Layer 2  CompilerInstance     Shared resource hub        (Driver::CompilerInstance)
///     Layer 3  FrontendAction       Per-file pipeline executor (this file)
///
///   Ownership
///   ----------
///     Borrows (non-owning, valid for the lifetime of CompilerInstance::execute):
///       CompilerInstance  - DiagEngine, SourceManager, TCM, ThreadPool, invocation
///       ImportResolver    - fully indexed before the first action is dispatched
///
///     Owns:
///       PreProcessor      - allocated at _preprocess(), freed by the destructor.
///                           Kept alive after preprocessing so _dump_macros() and
///                           _dump_imports() can access it.
///
///   Sync-free design
///   -----------------
///     FrontendAction contains no mutexes, atomics, or condition variables.
///
///   Async-ready path (future)
///   --------------------------
///     Phase 1 - Load and lex write to shared SM and TCM; they must run on the
///     driver thread.
///
///     Phase 2 - Preprocess through codegen read SM/TCM and own all mutable
///     state privately. Once SM/TCM are read-only from that point forward, each
///     FrontendAction can be handed to the ThreadPool after Phase 1 completes.
///     DiagEngine writes will be replaced by a per-action capture + merge step.
///

ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "llvm/Object/ObjectFile.h"
ffi "c++" import "llvm/Support/FileSystem.h"
ffi "c++" import "llvm/Support/Path.h"
ffi "c++" import "llvm/TargetParser/Host.h"
ffi "c++" import "llvm/Support/raw_ostream.h"
ffi "c++" import "llvm/Support/Threading.h"
ffi "c++" import "llvm/Support/xxhash.h"
ffi "c++" import "llvm/Support/Process.h"
ffi "c++" import "llvm/ADT/StringExtras.h"
ffi "c++" import "llvm/TargetParser/Triple.h"
ffi "c++" import "llvm/MC/TargetRegistry.h"
ffi "c++" import "llvm/MC/MCSubtargetInfo.h"
ffi "c++" import "llvm/Support/TargetSelect.h"
ffi "c++" import "llvm/Target/TargetMachine.h"
ffi "c++" import "llvm/Target/TargetOptions.h"
ffi "c++" import "llvm/Support/CodeGen.h"
ffi "c++" import "llvm/ADT/APFloat.h"
ffi "c++" import "llvm/ADT/IntrusiveRefCntPtr.h"
ffi "c++" import "clang/Basic/Diagnostic.h"
ffi "c++" import "clang/Basic/DiagnosticIDs.h"
ffi "c++" import "clang/Basic/DiagnosticOptions.h"
ffi "c++" import "clang/Basic/TargetInfo.h"
ffi "c++" import "clang/Basic/TargetOptions.h"
ffi "c++" import "clang/Frontend/FrontendActions.h"
ffi "c++" import "Native/KTimeReport.hh"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/KShims.hh"
ffi "c++" import "Native/KLog.hh"
ffi "c++" import "Native/GlobalRecycler.hh"
ffi "c++" import "vector"
ffi "c++" import "memory"
ffi "c++" import "string"
ffi "c++" import "utility"
ffi "c++" import "algorithm"
ffi "c++" import "cstring"
ffi "c++" import "optional"
ffi "c++" import "chrono"
ffi "c++" import "system_error"
ffi "c++" import "set"
ffi "c++" import "atomic"
ffi "c++" import "thread"
ffi "c++" import "cstdlib"

import API::FS::LinkFS
import AST::Context::GlobalDisambigTable::GlobalDisambigTable
import AST::DeclFacts::PackSetOrder
import AST::LangItems::{
    builtin_root_name,
    std_root_name,
    std_root_spelling,
}
import Command::Command::Command
import Command::FlagRegistry::register_kairo_flags
import Config::Invocation::CompilerInvocation
import Config::Target::TargetOptions
import Diagnostic::BasicConsumer::BasicDiagConsumer
import Diagnostic::Code::DiagCode
import Diagnostic::Engine::DiagEngine
import Diagnostic::PrettyConsumer::PrettyDiagConsumer
import Diagnostic::Registry::DiagID
import Driver::BatchResult::BatchResult
import Driver::CompilerCache
import Driver::CompilerGraph
import Driver::CompilerInfo
import Driver::CompilerLink
import Driver::CompilerNative
import Driver::CompilerSetup
import Driver::FrontendAction::FrontendAction
import Driver::InputKinds::{
    InputClass,
    InputKind,
}
import Driver::KairoIncludes::DriverIncludeSource
import Driver::Progress::progress_finish
import Interop::Clang::ClangBackend::{
    CLANG_STARTUP_GROUP,
    ClangBackend,
}
import Interop::Clang::ClangJobs::ClangJobs
import Interop::Clang::HeaderSet::{
    CODEGEN_PCH_GROUP,
    HEADER_BUILD_GROUP,
}
import Interop::Clang::HeaderSetCache::HeaderSetCache
import Location::SourceManager::SourceManager
import Preprocessor::Preprocessor::PreProcessor
import Resolution::ImportProbe::ImportResolver
import Resolution::ModulePath::ModulePath
import Sema::Foreign::BuiltinImport::BuiltinImport
import Sema::Foreign::ForeignInstantiate::ForeignInstantiate
import Sema::Foreign::ForeignRegistry::ForeignRegistry
import Sema::Foreign::HeaderIndex::HeaderIndex
import Sema::Type::PanicSets::PanicTypeIds
import Support::FileIO::Path::Path
import Support::FileIO::VirtualFileManager::VirtualFileManager
import Support::TimeReport::{
    TimeRegion,
    time_set_pool_size,
}
import Threading::ThreadPool::ThreadPool
import Token::IdentifierToken::IdentifierToken
import Token::TokenCacheManager::TokenCacheManager
import std::c_char

/// Shared resource hub for a single compilation.
///
/// Owns all subsystems and drives \c FrontendAction execution via
/// \c execute(). Destruction releases all resources in reverse-dependency
/// order.
///
/// Built either from argv (the driver's path) or from a \c CompilerInvocation
/// the caller filled in (the tooling path). The invocation is an INPUT, not an
/// output of construction: argv parsing lives in
/// \c CompilerInvocation::from_args, and the argv constructor is a caller of
/// it. Same split as clang's CreateFromArgs / setInvocation.
pub class CompilerInstance {
    /// # Owned resources
    ///   Listed in construction order; destroyed in reverse. Each starts
    ///   null: a run that answers early (--explain, --print-dirs) never
    ///   builds the batch-scoped ones, and the destructor frees whatever is
    ///   not null. Left uninitialized, it freed stack garbage, and whether
    ///   that crashed depended on the environment's size (an unset LANG did).

    prot var _pool:     *ThreadPool
    priv var _vfm:      *VirtualFileManager
    prot var _diag:     *DiagEngine
    prot var _sm:       *SourceManager
    prot var _tcm:      *TokenCacheManager
    prot var _pretty:   *PrettyDiagConsumer
    prot var _basic:    *BasicDiagConsumer
    prot var _cmd:      unsafe *Command            = &null
    prot var _pp:       unsafe *PreProcessor       = &null
    prot var _imp:      unsafe *ImportResolver     = &null
    prot var _g_scope:  *GlobalDisambigTable
    prot var _backend:  unsafe *ClangBackend       = &null ///< shared clang backend; owned
    priv var _headers:  unsafe *HeaderSetCache     = &null ///< phase-A C++ header parses; owned, destroyed BEFORE _backend
    priv var _hindex:   unsafe *HeaderIndex        = &null ///< header set -> Kairo TUs; owned
    priv var _freg:     unsafe *ForeignRegistry    = &null ///< USR -> imported decl, build-wide; owned
    priv var _finst:    unsafe *ForeignInstantiate = &null ///< fills instances of imported templates from clang; owned
    priv var _ptids:    unsafe *PanicTypeIds       = &null ///< the Panic set order every type formation applies (Compiler/Spec/Panic.md#canonical-sets); owned.
    priv var _builtins: unsafe *BuiltinImport      = &null ///< clang builtins as foreign decls, build-wide; owned
    /// P001W message/note pairs from _discover_roots and _check_sysroot,
    /// reported by initialize() (_report_root_warnings).
    prot var _root_warnings: cxx::std::vector<string>
    prot var _link_out:      string                   = "" ///< executable/library path; "" = this run does not link
    prot var _obj_dir:       string                   = "" ///< where objects go; always set by _plan_outputs
    prot var _obj_tmp:       bool                     = false ///< _obj_dir is a temp dir this run owns and removes
    /// A linking run whose --emit lists more than the object: the entry
    /// TUs' outputs are the user's, so they go beside the executable rather
    /// than into a temp _obj_dir (emit_beside).
    prot var _emit_beside:   bool  = false
    prot var _obj_listed:    bool  = true ///< --emit named obj itself (an _emit_beside run forces it on)
    prot var _kairo_inputs:  usize = 0 ///< Kairo (non-native, non-linker) inputs; set by _plan_outputs
    prot var _source_inputs: usize = 0 ///< C/C++/ObjC/IR inputs clang compiles; set by _plan_outputs
    prot var _header_inputs: usize = 0 ///< headers clang precompiles (one .pch each); set by _plan_outputs
    /// clang's driver, run in-process, for the C/C++ inputs (made on first
    /// use: a pure-Kairo build never builds a driver).
    prot var _jobs:      unsafe *ClangJobs           = &null
    prot var _kincludes: unsafe *DriverIncludeSource = &null ///< owned; _jobs borrows it
    /// Every fid an earlier input's FrontendAction took (claim_fid). Widened
    /// to u64: u32(-1) is DenseSet<u32>'s empty key.
    priv var _claimed: llvm::DenseSet<u64>
    /// A C/C++ input includes a .k (_discover_includes).
    prot var _includes_kairo: bool = false
    /// The sysroot generator refused (or failed) for this --target
    /// (_sysroot_from_generator): the run exits 2 (3 on a failed build)
    /// rather than 1, as `ksys ensure` would (Compiler/Spec/SysRoot.md 8).
    prot var _sysroot_status: i32 = 0
    /// The Kairo library's objects for this link (_kairo_lib): lazily, after
    /// everything else (LinkJob::lazy_objects).
    prot var _lib_lazy: cxx::std::vector<string>
    /// The same objects as an archive, for a MinGW link; "" otherwise.
    prot var _lib_archive: string
    /// The library build's entry file (_build_kairo_lib).
    prot var _lib_text: string = "pub import std\n"
    /// The bytes of the placeholder that takes fid 0 (_kairo_order).
    prot var _fid0_text:   string                   = "\n"
    prot var _native_objs: cxx::std::vector<string> ///< objects from _compile_sources / _compile_runtime, in order
    // _start_runtime's work list, read by _finish_runtime (the runtime
    // compiles on the pool during Sema). Parallel vectors, one row per source.
    prot var _rt_invs:  cxx::std::vector<cxx::std::shared_ptr<clang::CompilerInvocation>>
    prot var _rt_objs:  cxx::std::vector<string>
    prot var _rt_logs:  cxx::std::vector<string>
    prot var _rt_oks:   cxx::std::vector<u8> // not vec<bool>: its bits share bytes across threads
    prot var _rt_ents:  cxx::std::vector<string> // the cache entry a compiled object is stored to; "" for none
    prot var _rt_cache: string
    prot var _rt_started:        bool                     = false
    prot var _rt_prestart_tried: bool                     = false
    prot var _link_inputs:       cxx::std::vector<string> ///< .o/.a/.so given on the command line, in order
    /// Every command-line input, classified once by _plan_outputs (in
    /// command-line order, with the -x each was given under). execute() and
    /// the output rules read this; nothing re-derives a kind from a path.
    prot var _inputs: cxx::std::vector<InputKind>

    /// # CLI state
    ///   The invocation IS the CLI state. Flag-level queries go through
    ///   _inv.args, which is empty (and answers "not asked" to everything) when
    ///   the instance was built from a hand-made invocation.

    prot var _inv: CompilerInvocation

    /// # Constructors

    /// Constructs all subsystems from \p argv.
    ///
    /// A thin delegator: every line of argv handling lives in
    /// \c CompilerInvocation::from_args, and this hands the result to the
    /// invocation constructor below. Observable behaviour   including
    /// \c args_ok()   is unchanged from when the parsing was inline here.
    ///
    /// Construction order rationale:
    ///   - DiagEngine before consumers: consumers register into it.
    ///   - DiagEngine before parsing: CLI errors are reported into it.
    ///   - Pool before SM/TCM: they hold a pointer to it.
    ///   - SM before consumers are attached: they need it for source context.
    fn CompilerInstance(self, argc: i32, argv: unsafe *(unsafe *c_char)) {
        self._boot_diagnostics()

        // Kept for print_help() alone   it needs the flag table and argv[0] for
        // the USAGE line. It is never parsed; from_args below owns that, and
        // parsing here as well would double-report every flag error.
        self._cmd = kairo::std::create<Command>(argc, argv, self._diag)
        register_kairo_flags(self._cmd)

        var inv = CompilerInvocation::from_args(
            argc,
            argv,
            unsafe (self._diag as unsafe *DiagEngine),
        )

        self._adopt(unsafe &inv)
    }

    /// \brief constructs from kairo CLI words that did not come from main's
    ///        argv: kcc's translation of a clang command line (Driver/Kcc.k,
    ///        FlagTranslator::from_driver). The same parser as the argv
    ///        path, reporting into this instance's engine, so args_ok() and
    ///        flush_errors() behave as they do for `kairo`.
    fn CompilerInstance(self, @inout words: cxx::std::vector<string>) {
        self._boot_diagnostics()
        self._cmd = kairo::std::create<Command>(0, &null, self._diag)
        register_kairo_flags(self._cmd)
        var parsed = self._cmd->parse_words(&words)
        var inv    = CompilerInvocation()
        if parsed.ok {
            inv = CompilerInvocation::from_args(&parsed)
        } else {
            inv.args   = parsed
            inv.ok     = false
            inv.target = TargetOptions::from_args(&parsed)
        }

        self._adopt(unsafe &inv)
    }

    /// \brief constructs from a caller-built invocation. Reads no argv.
    ///
    /// \details The programmatic entry point. A tool that already knows its
    ///          options fills a \c CompilerInvocation and passes it here rather
    ///          than rendering the options back into flag strings for the CLI
    ///          parser to re-read.
    ///
    /// \par OWNERSHIP: \p inv is COPIED.
    ///      The instance holds its own \c CompilerInvocation, so \p inv may be
    ///      a stack temporary and may be modified or destroyed the moment this
    ///      returns. Copied rather than borrowed on purpose: the invocation is
    ///      a handful of small value types with no non-copyable state, the copy
    ///      happens once per compilation, and a borrowed one with no stated
    ///      lifetime is a dangler waiting to happen. Read the live copy back
    ///      through \c invocation(); mutations to \p inv afterwards are NOT
    ///      seen.
    ///
    /// \par Diagnostics
    ///      Do not depend on argv. The engine and its consumers are stood up
    ///      here exactly as on the argv path, and \c _apply_invocation() maps
    ///      the same policy fields onto them.
    ///
    /// \param inv  may be null, in which case \c args_ok() reports false and
    ///             the instance is inert   the same shape as a failed CLI
    ///             parse.
    ///
    /// \note \c print_help() is a no-op here: there is no flag table and no
    ///       argv[0] to name in the USAGE line.
    fn CompilerInstance(self, inv: unsafe *CompilerInvocation) {
        self._boot_diagnostics()
        self._cmd = &null
        self._adopt(inv)
    }

    /// Engine, file manager and the two consumers   everything needed before
    /// an invocation exists, because building one may report flag errors.
    priv fn _boot_diagnostics(self) {
        self._diag = unsafe (kairo::std::create<DiagEngine>() as *DiagEngine)
        self._vfm = unsafe (kairo::std::create<VirtualFileManager>(
            self._diag,
        ) as *VirtualFileManager)
        self._pretty = unsafe (kairo::std::create<PrettyDiagConsumer>() as *PrettyDiagConsumer)
        self._basic  = unsafe (kairo::std::create<BasicDiagConsumer>() as *BasicDiagConsumer)
        self._diag->add_consumer(unsafe (self._pretty as unsafe *PrettyDiagConsumer)) // pretty is the default consumer
    }

    /// Takes ownership of \p inv (by copy) and stands up everything whose
    /// construction depends on it. Shared tail of both constructors.
    priv fn _adopt(self, inv: unsafe *CompilerInvocation) {
        if inv != &null {
            *self.invocation() = *inv
        } else {
            self.invocation()->ok = false
        }

        // Unusable invocation: leave subsystems at their defaults, exactly as
        // the CLI path has always done for a failed parse. args_ok() is what
        // the caller is expected to check before going further.
        if self.invocation()->ok {
            self._apply_invocation()
        }

        var want_threads: i32 = if (self.invocation()->frontend.thread_count == 0) => (llvm::hardware_concurrency().compute_thread_count() as i32)
                                else => self.invocation()->frontend.thread_count
        // --cmax-threads is a hard cap over --threads AND the hardware default;
        // 0 means no cap. Clamping after the choice (not before) is what makes
        // it "regardless of --threads".
        var cap_threads: i32 = self.invocation()->frontend.max_threads
        if cap_threads > 0 && want_threads > cap_threads {
            want_threads = cap_threads
        }

        self._pool = unsafe (kairo::std::create<ThreadPool>(want_threads as usize) as *ThreadPool)

        time_set_pool_size(self._pool->get_thread_count() as i32)

        self._sm = unsafe (kairo::std::create<SourceManager>(
            self._pool,
            self._vfm,
            self._diag,
        ) as *SourceManager)
        self._tcm = unsafe (kairo::std::create<TokenCacheManager>(
            self._sm,
            self._pool,
            self._diag,
        ) as *TokenCacheManager)
        self._g_scope = unsafe (kairo::std::create<GlobalDisambigTable>() as *GlobalDisambigTable)
        self._basic->attach_source_manager(unsafe (self._sm as unsafe *SourceManager))
        self._pretty->attach_source_manager(unsafe (self._sm as unsafe *SourceManager))
    }

    /// # Destructor

    // Not transferable: it owns the whole compile (threads, managers, tables) and its parts point back at it; a copy would free them twice.
    @copy fn CompilerInstance(self, const other: Self) = delete

    /// Destroys all resources in reverse-construction order.
    fn op finally (self) {
        // The driver bridge borrows the backend: it goes first.
        if self._jobs != &null {
            kairo::std::destroy(self._jobs)
            self._jobs = &null
        }

        if self._kincludes != &null {
            kairo::std::destroy(self._kincludes)
            self._kincludes = &null
        }

        // Header sets before the backend: a build in flight is using the
        // backend's invocation and VFS, and a live set's clang instance
        // shares that VFS. Drain the group so no set is mid-parse when it
        // dies; destroying the cache releases every set.
        if self._headers != &null {
            self._pool->wait_group(HEADER_BUILD_GROUP)
            self._pool->wait_group(CODEGEN_PCH_GROUP)
            // Early-exit paths skip both Sema's drain and release_all's.
            if self._diag != &null {
                self._headers->drain_all(
                    unsafe (self._diag as unsafe *DiagEngine),
                    unsafe (self._sm as unsafe *SourceManager),
                )
            }

            kairo::std::destroy(self._headers)
            self._headers = &null
        }

        // Borrows _hindex's target, _freg and the backend's oracle: first out.
        if self._builtins != &null {
            kairo::std::destroy(self._builtins)
            self._builtins = &null
        }

        if self._finst != &null {
            kairo::std::destroy(self._finst)
            self._finst = &null
        } // borrows _hindex.

        if self._ptids != &null {
            if self._g_scope != &null {
                self._g_scope->types()->pack_order     = &null
                self._g_scope->instances()->pack_order = &null
            }

            kairo::std::destroy(self._ptids)
            self._ptids = &null
        }

        if self._hindex != &null {
            kairo::std::destroy(self._hindex)
            self._hindex = &null
        }

        if self._freg != &null {
            kairo::std::destroy(self._freg)
            self._freg = &null
        }

        // backend first: its ClangLocMap borrows _sm, and its clang SM holds
        // MemoryBufferRef views into _vfm's mmaps. The startup task must be
        // drained before teardown.
        if self._backend != &null {
            self._pool->wait_group(CLANG_STARTUP_GROUP)
            kairo::std::destroy(self._backend)
            self._backend = &null
        }

        if self._cmd != &null {
            kairo::std::destroy(self._cmd)
            self._cmd = &null
        }

        if self._pp != &null {
            kairo::std::destroy(self._pp)
            self._pp = &null
        }

        if self._g_scope != &null {
            kairo::std::destroy(unsafe (self._g_scope as unsafe *GlobalDisambigTable))
        }

        if self._tcm != &null {
            kairo::std::destroy(unsafe (self._tcm as unsafe *TokenCacheManager))
        }

        if self._imp != &null {
            kairo::std::destroy(self._imp)
            self._imp = &null
        }

        if self._pretty != &null {
            self._diag->remove_consumer(unsafe (self._pretty as unsafe *PrettyDiagConsumer))
            kairo::std::destroy(unsafe (self._pretty as unsafe *PrettyDiagConsumer))
        }

        if self._basic != &null {
            self._diag->remove_consumer(unsafe (self._basic as unsafe *BasicDiagConsumer))
            kairo::std::destroy(unsafe (self._basic as unsafe *BasicDiagConsumer))
        }

        if self._sm != &null {
            kairo::std::destroy(unsafe (self._sm as unsafe *SourceManager))
        }

        if self._diag != &null {
            kairo::std::destroy(unsafe (self._diag as unsafe *DiagEngine))
        }

        if self._vfm != &null {
            kairo::std::destroy(unsafe (self._vfm as unsafe *VirtualFileManager))
        }

        if self._pool != &null {
            kairo::std::destroy(unsafe (self._pool as unsafe *ThreadPool))
        }
    }

    /// # Accessors

    pub fn diag(self) -> unsafe *DiagEngine {
        return unsafe (self._diag as unsafe *DiagEngine)
    }

    pub fn sm(self) -> unsafe *SourceManager {
        return unsafe (self._sm as unsafe *SourceManager)
    }

    fn tcm(self) -> unsafe *TokenCacheManager {
        return unsafe (self._tcm as unsafe *TokenCacheManager)
    }

    fn pool(self) -> unsafe *ThreadPool {
        return unsafe (self._pool as unsafe *ThreadPool)
    }

    pub fn global_scope(self) -> unsafe *GlobalDisambigTable {
        return unsafe (self._g_scope as unsafe *GlobalDisambigTable)
    }

    pub fn invocation(self) -> *CompilerInvocation {
        return &self._inv
    }

    pub fn pp(self) -> unsafe *PreProcessor {
        return self._pp
    }

    pub fn imp(self) -> unsafe *ImportResolver {
        return self._imp
    }

    fn backend(self) -> unsafe *ClangBackend {
        return self._backend
    }

    fn headers(self) -> unsafe *HeaderSetCache {
        return self._headers
    }

    fn header_index(self) -> unsafe *HeaderIndex {
        return self._hindex
    }

    fn foreign_instantiate(self) -> unsafe *ForeignInstantiate {
        return self._finst
    }

    fn panic_type_ids(self) -> unsafe *PanicTypeIds {
        return self._ptids
    }

    fn foreign_registry(self) -> unsafe *ForeignRegistry {
        return self._freg
    }

    fn builtins(self) -> unsafe *BuiltinImport {
        return self._builtins
    }

    /// \brief true if \p fid is a C++ header Sema/Foreign imported: a TU whose
    ///        decls came from clang, with no Kairo source behind it.
    fn is_foreign_fid(self, fid: u32) -> bool {
        var unsafe *ctx = self._g_scope->get_context(fid)
        if ctx == &null {
            return false
        }

        var unsafe *tu = ctx->tu
        return tu != &null && tu->is_foreign
    }

    /// \brief the name a Kairo TU's outputs take under the object dir when
    ///        its module path is one segment (or none, by its file stem):
    ///        that name, or `<stem>.k` when a C/C++ input of the build has
    ///        that stem and so writes `<stem>.o` itself (_plan_outputs).
    fn kairo_object_stem(self, stem: string) -> string {
        for *k in self._inputs {
            if k->cls != InputClass::Source {
                continue
            }

            if Path::stem_of(k->path) == stem {
                return stem + ".k"
            }
        }

        return stem
    }

    /// \brief true when a C++ or Objective-C++ input includes a .k
    ///        (_discover_includes found one): the include is emitted from
    ///        its analysed and lowered tree, so the Kairo inputs go through
    ///        sema even when the action stops earlier for C++ (--preprocess,
    ///        --syntax-only). All of them, not only the included ones: an
    ///        included file may be claimed by an importer's action.
    fn kairo_feeds_includes(self) -> bool {
        return self._includes_kairo
    }

    /// \brief true the first time \p fid is asked for: the asking action
    ///        parses, checks and emits it. Inputs share their imports (every
    ///        one reaches builtin), and the PP hands each action its whole
    ///        graph; a fid an earlier action took is already through every
    ///        stage, its tables frozen and its object written.
    fn claim_fid(self, fid: u32) -> bool {
        var k = (fid as u64)
        if self._claimed.contains(k) {
            return false
        }

        self._claimed.insert(k)
        return true
    }

    /// # CLI query helpers

    fn wants_help(self) -> bool {
        return self.invocation()->args.get_bool("help")
            || self.invocation()->args.get_bool("help-hidden")
    }

    fn wants_version(self) -> bool {
        return self.invocation()->args.get_bool("version")
    }

    fn wants_explain(self) -> bool {
        return !self.invocation()->args.get_string("explain").empty()
    }

    /// \brief whether this instance's invocation is usable.
    ///
    /// \details On the argv path this is exactly "did the flags parse". On the
    ///          invocation path there are no flags to parse, so it reports
    ///          whether the supplied invocation was usable   false for a null
    ///          one, or for one a caller explicitly marked not-ok.
    pub fn args_ok(self) -> bool {
        return self.invocation()->ok
    }

    /// The exit status of a run args_ok() rejected: 1, or the sysroot
    /// generator's own 2 (refusal) / 3 (failure).
    pub fn failure_status(self) -> i32 {
        return if (self._sysroot_status != 0) => (self._sysroot_status) else => 1
    }

    /// True when any info flag is present whose subsystem is not yet live.
    fn wants_info_query(self) -> bool {
        return self.invocation()->args.get_bool("print-targets")
            || self.invocation()->args.get_bool("print-cpus")
            || self.invocation()->args.get_bool("print-dirs")
            || self.invocation()->args.get_bool("print-clang-args")
            || self.invocation()->args.get_bool("print-jobs")
            || self.invocation()->args.get_bool("print-from-clang")
            || self.invocation()->args.get_bool("print-target-info")
            || self.invocation()->args.get_bool("print-cfg")
            || self.invocation()->args.get_bool("print-runtimes-revision")
    }

    /// The ICE hook: drain every TU's buffered sink into the engine, then
    /// render the engine's console consumer, as the end of a run would.
    /// \p ci is the CompilerInstance execute() registered.
    priv static fn _flush_for_ice(ci: unsafe *void) {
        var unsafe *self_ = unsafe (ci as unsafe *CompilerInstance)
        if self_ == &null || self_->_diag == &null {
            return
        }

        // The process aborts next: a pinned line would stay on the screen.
        progress_finish()
        if self_->_g_scope != &null {
            self_->_g_scope->drain_sinks_for_ice(unsafe (self_->_diag as unsafe *DiagEngine))
        }

        self_->_diag->flush_consumers_for_ice()
    }

    fn flush_errors(self) {
        if self.invocation()->diag.format == "basic" || self.invocation()->diag.format == "json" {
            self._basic->finalize_to_stderr()
        } else {
            self._pretty->finalize_to_stderr()
        }
    }

    /// # Compilation pipeline

    /// One `-I` (or --macro-search-path) entry: an UNNAMED search dir, as
    /// the cwd is. A file under it is its path relative to it, unless a
    /// pinned module.k (`module foo`) above the file names a library; that
    /// pin is the only way a directory gets a name (Compiler/Spec/Imports.md#path-resolution).
    ///
    /// `-I name=dir` used to be a second way to say it, and the two could
    /// disagree. It is an error that says where the name goes now, not a
    /// silently missing directory literally called `name=dir`. A path that
    /// does contain `=` and exists is a path; every other spec with an `=`
    /// is the old form, whatever the part before it looks like -- a
    /// `geo-lib=vendor/geometry` used to slip past a "name-shaped" test and
    /// vanish as a nonexistent directory, leaving only an R011E at the
    /// import with nothing pointing at the flag.
    priv fn _add_root(self, @inout rb: ImportResolver::Builder, const spec: string) {
        var pos = kairo::std::to_std_string(spec).find(('=' as u8) as c_char)
        if pos != usize::MAX && !Path(spec).is_directory() {
            var name = string(unsafe ((spec.raw() as unsafe *const u8) as *const u8), pos)
            var dir = string(
                unsafe (((spec.raw() as unsafe *const u8) + pos + 1) as *const u8),
                spec.size() - pos - 1,
            )

            var name_shaped = pos > 0
            for var i: usize = 0; i < name.size(); ++i {
                var c = name[i]
                var ok = c >= ('a' as u8) && c <= ('z' as u8)
                    || c >= ('A' as u8) && c <= ('Z' as u8)
                    || c >= ('0' as u8) && c <= ('9' as u8)
                    || c == ('_' as u8)
                    || c == (':' as u8)
                if !ok {
                    name_shaped = false
                    break
                }
            }

            // The shape only picks the hint: a pin to copy when the part
            // before `=` could be one, the rule alone when it could not.
            if name_shaped {
                self._diag->report(
                    DiagID::U007E,
                    f"-I {spec}: no such directory, and the name=dir form is gone; -I takes a directory only. To name the library, " + f"make `module {name}` the first line of {dir}/module.k and pass -I {dir}",
                ).emit()
            } else {
                self._diag->report(
                    DiagID::U007E,
                    f"-I {spec}: no such directory; -I takes a directory only, and the name=dir form is gone: " + "a library is named by the `module` declaration on the first line of its module.k",
                ).emit()
            }

            return
        }

        rb.add_include(Path(spec))
    }

    /// Two roots under one name make a module path mean two files. Fatal, and
    /// reported before anything is parsed. A pinned directory found later
    /// (canonical_module_path's walk up) is reported by the PP walk, with
    /// the same text (RootNameCollision::message).
    priv fn _report_root_collisions(self) {
        if self._imp == &null {
            return
        }

        var found = self._imp->take_root_collisions()
        for var i: usize = 0; i < found.size(); ++i {
            var c = found[i]
            // Placeholder code for the mismatch: no real code covers a
            // registration disagreeing with the pin (verified against
            // Resolution.diag.toml).
            var id = if (c.mismatch) => (DiagID::R059E) else => DiagID::R018E
            self._diag->report(DiagCode(id), c.message()).emit()
        }
    }

    /// Two inputs one module path names (decision E): `./a.k` and `inc/a.k`
    /// under `-I inc` are both module `a`, and each would write `a.o`, the
    /// second over the first. An import of that path is already R017E, but
    /// inputs are modules too now (decision C) and nothing imports them, so
    /// they are claimed here, every one before any is compiled. False when
    /// two collided (reported).
    priv fn _claim_input_identities(self) -> bool {
        if self._imp == &null {
            return true
        }

        for *k in self._inputs {
            if k->cls == InputClass::LinkInput
                || k->cls == InputClass::Source
                || k->cls == InputClass::Header {
                continue
            }

            var p = Path(k->path)
            self._imp->claim_identity(self._imp->input_module_path(p), p)
        }

        // Two inputs on one path, and any pin the walk up found claiming a
        // registered library's name.
        var ok = true
        for var msg: string in self._imp->take_late_collisions() {
            self._diag->report(DiagCode(DiagID::R018E), msg).emit()
            ok = false
        }

        return ok
    }

    /// Applies the two process-level input flags, before initialize() reads
    /// the current directory: --working-dir (every relative path in the run,
    /// source files included, resolves against it) and --input-encoding (the
    /// lexer only reads UTF-8, so any other value would be silently
    /// mis-decoded rather than honoured).
    ///
    /// \return false after reporting; the caller must stop.
    fn apply_input_options(self) -> bool {
        var enc = self.invocation()->input_encoding
        var is_utf8 = enc.empty()
            || enc == "utf-8"
            || enc == "UTF-8"
            || enc == "utf8"
            || enc == "UTF8"
        if !is_utf8 {
            self._diag->report(
                DiagID::U009E,
                f"--input-encoding={enc}: only utf-8 input is supported",
            ).emit()
            return false
        }

        var wd = self.invocation()->working_dir
        if wd.empty() {
            return true
        }

        if !Path::set_cwd(wd) {
            self._diag->report(
                DiagID::U010E,
                f"--working-dir: cannot change to '{wd}': no such directory",
            ).emit()
            return false
        }

        return true
    }

    /// \brief wires the batch-scoped subsystems: ImportResolver, PreProcessor,
    ///        and the shared ClangBackend.
    ///
    /// \details Must run before execute() or any Frontend/ parse entry point;
    ///          execute() asserts on it. Named to match that assert   it was
    ///          `index()`, which collided with the unrelated ASTParse Index
    ///          pass and described neither of the three things it builds.
    pub fn initialize(self, const cwd: Path) {
        self._report_root_warnings()
        {
            var _t = TimeRegion("ImportIndex")
            var rb = *ImportResolver::Builder().cwd(cwd)
            for *dir in self.invocation()->include_dirs {
                self._add_root(&rb, (*dir))
            }

            for *dir in self.invocation()->macro_paths {
                self._add_root(&rb, (*dir))
            }

            // The builtin root, registered under the NAME `builtin` so every
            // module beneath it carries that leading segment -- the lang-item
            // fill addresses decls by qualified path, and an unnamed root would
            // give them the directory's basename instead.
            //
            // --builtins-dir wins; otherwise <resource-dir>/builtin. With
            // neither there is no builtin root at all, the prelude resolves to
            // nothing, and the lang items stay unbound -- which is diagnosed at
            // USE by whichever pass needs one, never here.
            var broot = self.invocation()->pp.builtins_dir
            if broot.empty() && !self.invocation()->target.resource_dir.empty() {
                broot = (Path(self.invocation()->target.resource_dir) / "builtin").full_path()
            }

            if !broot.empty() {
                rb.add_include(Path(broot), builtin_root_name())
            }

            // The std root, NAMED `kairo::std` and SPELLED `std`. The name is
            // its identity: `Lib/std/io.k` is `kairo::std::io` and emits into
            // `::kairo::std`, which can never collide with C++'s own `std`
            // (that one is reached through `cxx::std`). The spelling is what
            // source writes -- `import std::io` -- and nothing reaches std
            // without writing it: there is no prelude for std, only builtin.
            //
            // --std-dir wins; otherwise <resource-dir>/std. --no-stdlib skips
            // the root entirely, and `import std::...` is then an ordinary
            // unresolved import.
            if !self.invocation()->pp.no_stdlib {
                var sroot = self.invocation()->pp.std_dir
                if sroot.empty() && !self.invocation()->target.resource_dir.empty() {
                    sroot = (Path(self.invocation()->target.resource_dir) / "std").full_path()
                }

                if !sroot.empty() {
                    rb.add_include(Path(sroot), std_root_name(), std_root_spelling())
                }
            }

            self._imp = rb.create_ptr(unsafe (self._pool as unsafe *ThreadPool))
            self._report_root_collisions()
        }

        // Shared clang backend: kick the expensive startup (invocation parse,
        // TargetInfo, FileManager/SourceManager) onto the pool NOW so it runs
        // concurrently with lex/preprocess. Joined via CLANG_STARTUP_GROUP
        // before codegen. Kairo fids are NOT registered here   that happens in
        // ClangLocMap::rebind(), inside the codegen action window.
        //
        // Built BEFORE the PreProcessor now: the PP hands every file's ffi
        // header list to the HeaderSetCache, whose builds copy this backend's
        // invocation.
        var bcfg = self._backend_config()

        self._backend = kairo::std::create<ClangBackend>(self._sm, bcfg)

        var unsafe *be  = self._backend
        var unsafe *rec = kairo::TimeReport::region(r"ClangStartup")
        self._pool->enqueue(
            kairo::SmallFunction<64>(
                fn () |be, rec| {
                    var _kt = kairo::TimeReport::Worker(rec)
                    be->startup()
                },
            ),
            CLANG_STARTUP_GROUP,
        )

        // C++ header import. Parse on the pool (HeaderSetCache), index on the
        // driver (HeaderIndex writes the SM, the TCM and the global table),
        // one USR -> decl identity for the build (ForeignRegistry).
        self._headers = kairo::std::create<HeaderSetCache>(
            self._backend,
            self._pool,
            self.invocation()->frontend.shared_header_set,
        )

        self._freg = kairo::std::create<ForeignRegistry>()
        // `T?` crosses into and out of a header as `::builtin::Nullable<T>`
        // (TypeExport / TypeImport): both ask the registry for the lang item.
        self._freg->well_known = self._g_scope->well_known()
        self._hindex = kairo::std::create<HeaderIndex>(
            self._sm,
            self._tcm,
            self._diag,
            self._imp,
            self.invocation(),
            self._g_scope,
            self._freg,
        )

        self._finst = kairo::std::create<ForeignInstantiate>(
            self._hindex,
            self._freg,
            self._g_scope->instances(),
        )

        self._builtins = kairo::std::create<BuiltinImport>() // init()ed on the driver, after header indexing.

        self._pp = kairo::std::create<PreProcessor>(
            self._sm,
            self._tcm,
            self._imp,
            self._pool,
            self._diag,
            self._g_scope,
            self.invocation(),
            self.invocation()->pp,
            self._headers,
        )

        self._finst->psym = self._pp->get_symbol_table()
        // Panic<i32, B, A> IS Panic<i32, A, B> wherever a type is formed
        // (Compiler/Spec/Panic.md#canonical-sets): one stateless orderer for the build's type store
        // and registry, before any Sema pass forms one.
        self._ptids = kairo::std::create<PanicTypeIds>(
            self._finst->psym,
            self._g_scope->well_known(),
            self.invocation()->lang.test_panic_id_bits,
        )

        self._ptids->size_types(
            self.invocation()->target.pointer_width,
            self.invocation()->target.usize_is_fixed,
            self.invocation()->target.isize_is_fixed,
        )

        self._g_scope->types()->pack_order     = unsafe (self._ptids as unsafe *PackSetOrder)
        self._g_scope->instances()->pack_order = unsafe (self._ptids as unsafe *PackSetOrder)
    }

    /// Compiles all input files described by the invocation.
    ///
    /// Builds an \c ImportResolver from the search paths in the invocation,
    /// then runs a \c FrontendAction for each input file. A fatal diagnostic
    /// in any file sets \c BatchResult::aborted and skips remaining files.
    /// Results are collected into the returned \c BatchResult.
    fn execute(self) -> BatchResult {
        eval if defined!(DEBUG) {
            if !(self._imp != &null) {
                kairo::std::ice_fail(r"initialize() must be called before execute()")
            }
        }

        // An ICE aborts past every flush below; the hook prints what this
        // run has buffered first (Native/Types.hh, ice_abort).
        kairo::std::set_ice_flush_hook(
            CompilerInstance::_flush_for_ice,
            unsafe ((&self) as unsafe *void),
        )

        finally {
            kairo::std::clear_ice_flush_hook()
        }

        var result = BatchResult()
        var t0     = cxx::std::chrono::steady_clock::now()

        finally {
            var t1 = cxx::std::chrono::steady_clock::now()
            result.elapsed_ms = (cxx::std::chrono::duration_cast<cxx::std::chrono::microseconds>(
                t1 - t0,
            ).count() as f64) / 1000.0
        }

        if self.invocation()->input_files.empty() {
            self._diag->report(DiagID::I004F, "no input files").emit()
            result.aborted = true
            return result
        }

        if !self._plan_outputs() {
            result.aborted = true
            return result
        }

        self._discover_includes()
        if !self._claim_input_identities() {
            result.aborted = true
            return result
        }

        // Before the library: its objects are cached by this bit too.
        self._settle_global_allocator()
        if !self._link_out.empty() && self.invocation()->linker.kairo_lib {
            if !self._kairo_lib() {
                result.aborted = true
                return result
            }
        }

        kairo::Logger::info(
            kairo::Logger::Stage::Driver,
            f"CompilerInstance::execute: {self.invocation()->input_files.size()} file(s)",
        )

        result.tu_results.reserve(self.invocation()->input_files.size())

        // No umbrella region here: every stage below (Load .. Codegen, then
        // Link) is a root of the timing tree, so a stage's row is its own
        // time and Link is not reported as part of a frontend.

        // C and C++ inputs are not Kairo TUs: they compile after every Kairo
        // file, through the same clang backend (_compile_sources, through clang's driver).
        var natives             = cxx::std::vector<InputKind>()
        var kairo_inputs: usize = 0

        // Every input is compiled even after one fails, as clang does with
        // several: each reports its own errors, and the batch fails if any
        // did. `aborted` still stops what runs AFTER the loop (natives, the
        // link).
        var prev_errors: u32 = 0
        var prev_fatals: u32 = 0
        for var k: InputKind in self._kairo_order() {
            var path_str = k.path
            if k.cls == InputClass::LinkInput {
                self._link_inputs.push_back(path_str)
                continue
            }

            if k.cls == InputClass::Source || k.cls == InputClass::Header {
                natives.push_back(k)
                continue
            }

            kairo_inputs += 1

            var unsafe *action = kairo::std::create<FrontendAction>(
                Path(path_str),
                self._input_module_path(path_str),
                self._g_scope,
                self._imp,
                &self,
            )

            finally {
                kairo::std::destroy(action)
            }

            action->discovered      = k.discovered
            action->errors_at_start = prev_errors
            action->fatals_at_start = prev_fatals
            action->run()
            prev_errors = self._diag->error_count()
            prev_fatals = self._diag->fatal_count()

            if action->result.had_fatal {
                result.aborted = true
            }

            result.tu_results.push_back(action->result)
        }

        // Each input may be a script (Compiler/Spec/ScriptMode.md#which-file-is-a-script), and each script is a
        // `main`: two in one link are two programs, which the linker would
        // reject as a duplicate symbol naming neither file. Only a link joins
        // them, so `-c` and --type-check-only of several scripts stay legal.
        if !self._link_out.empty() {
            self._reject_second_script(&result)
        }

        if !self._link_out.empty() {
            self._reject_second_global_allocator(&result)
        }

        // C/C++ inputs follow the run's action (_compile_sources); the
        // runtime compiles to objects, and only when Kairo objects were
        // emitted -- an --emit without obj asks for none.
        if !result.aborted && self._diag->error_count() == 0 {
            var _t = TimeRegion("NativeCompile")
            if !self._compile_sources(&natives) {
                result.aborted = true
            }

            var *fe_rt = &self.invocation()->frontend
            if !result.aborted
                && kairo_inputs > 0
                && !fe_rt->stops_before_codegen()
                && fe_rt->emit_obj
                && !self.invocation()->linker.inputs_only() {
                if !self._compile_runtime() {
                    result.aborted = true
                }
            }
        }

        self._join_runtime() // an early start the batch did not get to use.

        // Every set's clang instance dies here, while _backend still lives:
        // imported decls' clang_decl point into those ASTContexts, and
        // nothing after this reads them (codegen ran inside the loop).
        // Releasing each set once its last importer passes Checked is the
        // refinement; the PCH bytes and include tree outlive the release.
        if self._headers != &null {
            self._headers->drain_all(
                unsafe (self._diag as unsafe *DiagEngine),
                unsafe (self._sm as unsafe *SourceManager),
            )

            self._headers->release_all()
        }

        // The link runs after every TU and native compile, and before the
        // totals are taken, so a link error fails the batch like any other.
        if !self._link_out.empty() {
            if !result.aborted && self._diag->error_count() == 0 {
                self._link(&result)
            }

            if self._obj_tmp && !self.invocation()->linker.save_temps {
                LinkFS::remove_tree(self._obj_dir)
            }
        } else if !self._link_inputs.empty() {
            for *p in self._link_inputs {
                self._diag->report(
                    DiagID::L006W,
                    f"linker input {(*p)} unused: this run does not link",
                ).emit()
            }
        }

        // `self._diag` is one engine shared across every TU in this batch
        // (never reset between files), so its final counts are already the
        // batch total - summing per-TU snapshots would double count errors
        // reported before a given TU started. This is the single source of
        // truth `BatchResult::ok()` uses to decide the process exit code:
        // any error anywhere in the pipeline -> non-zero exit; warnings
        // alone -> exit 0.
        result.total_errors   = self._diag->error_count()
        result.total_warnings = self._diag->warn_count()

        kairo::Logger::info(
            kairo::Logger::Stage::Driver,
            f"CompilerInstance::execute: {result.summary()}",
        )

        return result
    }

    /// \brief the module path \p path takes as an input: the one an import
    ///        of it gets (ImportResolver::input_module_path), so a file is one
    ///        module, one namespace and one object path whether it is
    ///        compiled, imported or included, and `kcc -c lib/y.k` emits the
    ///        `lib::y::f` an importer compiled in another run calls
    ///        (decision C). Empty for a pathless file -- one outside every
    ///        search dir, or one whose path a named library owns -- which
    ///        keeps the pathless rules (CXXSpell::is_entry_tu).
    /// The module path the driver gives input \p path (ParseAPI's as_module).
    pub fn input_module_path(self, const path: string) -> ModulePath {
        return self._input_module_path(path)
    }

    priv fn _input_module_path(self, const path: string) -> ModulePath {
        var mp = ModulePath()
        if self._imp == &null || self._pp == &null {
            return mp
        }

        var unsafe *sym = self._pp->get_symbol_table()
        for var seg: string in self._imp->input_module_path(Path(path)) {
            var ident = IdentifierToken()
            ident.name  = sym->intern(seg)
            ident.token = &null
            mp.segments.push_back(ident)
        }

        return mp
    }
}
