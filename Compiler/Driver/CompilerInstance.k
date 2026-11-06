/// --- The Kairo Project -------------------- Driver/CompilerInstance.k --- ///
///
///   Driver Layer 2 shared resource owner and pipeline dispatcher.
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
///   Three-layer driver map
///   ----------------------
///   Layer 1  CompilerInvocation   Strongly-typed options         (Options::*)
///   Layer 2  CompilerInstance     Shared resource hub            (this file)
///   Layer 3  FrontendAction       Per-file pipeline executor     (Driver::FrontendAction)
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

ffi "c++" import "llvm/ADT/DenseSet.h";
ffi "c++" import "llvm/Object/ObjectFile.h";
import Diagnostic::Engine::*;
import Diagnostic::Registry::*;
import Diagnostic::Code::*;
import Diagnostic::PrettyConsumer::*;
import Diagnostic::BasicConsumer::*;
import Location::SourceManager::*;
import Support::TermRenderer::*;
import Support::TimeReport::*;
import Token::TokenCacheManager::*;
import Token::TokenText::*;
import Token::TokenKind::*;
import Token::IdentifierToken::*;
import Command::Command::*;
import Command::FlagRegistry::*;
import Codegen::Backend::CodegenBackend::*;
import Codegen::Backend::CodegenAction::*;
import Codegen::EmitPlan::*;
import Codegen::Backend::EmitCXXHeader::*;
import Codegen::Emit::CXXSpell::*;
import Codegen::Sink::TextSink::*;
import Support::FileIO::Path::*;
import Support::FileIO::FileSystem::*;
import Codegen::Emit::InterfaceEmitter::*;
import Codegen::CodegenContext::*;
import Config::Invocation::*;
import Driver::BatchResult::*;
import Driver::TUResult::*;
import Driver::TUStage::*;
import Driver::InputKinds::*;
import Command::FlagTranslator::*;
import Preprocessor::Preprocessor::*;
import Parser::ASTParse::*;
import AST::Context::GlobalDisambigTable::*;
import AST::Printer::ASTPrinter::*;
import AST::Printer::PrintCore::*;
import AST::Context::DeclContext::*;
import AST::Context::SymbolTable::*;
import AST::Node::Declarations::*;
import AST::LangItems::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import Token::TokenPrinter::*;
import Sema::Type::PanicSets::*;
import Sema::Sema::*;
import Sema::Resolve::ImportResolution::*;
import Sema::Resolve::NameLookup::*;
import Sema::SemaDump::*;
import Sema::SemaContext::*;
import Sema::Check::EffectPropagation::*;
import AST::Context::ImportOverlay::*;
import Interop::Clang::ClangBackend::*;
import Interop::Clang::ClangJobs::*;
import Driver::KairoIncludes::*;
import Interop::Clang::HeaderSet::*;
import Interop::Clang::KairoIncludeScan::*;
import Sema::Foreign::HeaderIndex::*;
import Sema::Foreign::ForeignRegistry::*;
import Sema::Foreign::ForeignInstantiate::*;
import Sema::Foreign::BuiltinImport::*;
import Diagnostic::ClangDiagLookup::*;
import Linker::API::Link::*;
import Linker::API::HostSystem::*;
import Linker::API::LinkJob::*;
import Linker::API::LinkDiag::*;
import Linker::API::Toolchain::*;
import Linker::API::FS::*;
import Linker::API::Text::*;
import Linker::API::SysrootManifest::*;
import Linker::API::LinkABI::*;

ffi "c++" import "llvm/Support/FileSystem.h";
ffi "c++" import "llvm/Support/Path.h";
ffi "c++" import "llvm/TargetParser/Host.h";
ffi "c++" import "llvm/Support/raw_ostream.h";
ffi "c++" import "llvm/Support/Threading.h";
ffi "c++" import "llvm/Support/xxhash.h";
ffi "c++" import "llvm/Support/Process.h";
ffi "c++" import "llvm/ADT/StringExtras.h";
ffi "c++" import "llvm/TargetParser/Triple.h";
ffi "c++" import "llvm/MC/TargetRegistry.h";
ffi "c++" import "llvm/MC/MCSubtargetInfo.h";
ffi "c++" import "llvm/Support/TargetSelect.h";
ffi "c++" import "llvm/Target/TargetMachine.h";
ffi "c++" import "llvm/Target/TargetOptions.h";
ffi "c++" import "llvm/Support/CodeGen.h";
ffi "c++" import "llvm/ADT/APFloat.h";
ffi "c++" import "llvm/ADT/IntrusiveRefCntPtr.h";
ffi "c++" import "clang/Basic/Diagnostic.h";
ffi "c++" import "clang/Basic/DiagnosticIDs.h";
ffi "c++" import "clang/Basic/DiagnosticOptions.h";
ffi "c++" import "clang/Basic/TargetInfo.h";
ffi "c++" import "clang/Basic/TargetOptions.h";
ffi "c++" import "clang/Frontend/FrontendActions.h";
ffi "c++" import "Native/KTimeReport.hh";

class CompilerInstance; // forward breaks the CI <-> FrontendAction cycle

/// Per-file pipeline executor.
///
/// Owned by \c CompilerInstance::execute() for the lifetime of one input file.
/// Advances through \c TUStage in order, honouring \c FrontendOptions stop-at
/// points and post-stage dump flags at each boundary.
///
/// Stages are strictly sequential on the calling thread. Load and lex must run
/// on the driver thread (shared SM/TCM writes). Preprocess through codegen are
/// per-file and will be async-dispatchable to the \c ThreadPool in a future
/// phase once SM/TCM are read-only.
///
/// \c _ci and \c _resolver are non-owning borrows valid for the lifetime of
/// \c execute(). \c _pp is owned and destroyed with the action.
class FrontendAction {
    pub var path:           Path;
    pub var module_base:    ModulePath;
    priv var _ci:           obs::<CompilerInstance>;   ///< non-owning borrow from execute()
    priv var _resolver:     obs::<ImportResolver>;     ///< non-owning borrow from execute()
    priv var _global_scope: obs::<GlobalDisambigTable>; ///< non-owning borrow from CompilerInstance
    priv var _file_id:      u32;
    priv var _fids:         vec::<u32>;   ///< the graph's fids this action claimed (claim_fid)
    priv var _graph:        vec::<u32>;   ///< every fid of the graph, an earlier input's too
    pub var result:         TUResult;
    priv var _stage:        TUStage;
    /// The shared engine's counts this input is judged against (see run()):
    /// what the previous input left, 0 for the first. Set by execute().
    pub var errors_at_start: u32 = 0;
    pub var fatals_at_start: u32 = 0;
    /// Found through an include, not named on the command line
    /// (InputKind::discovered): its object never goes to -o.
    pub var discovered:     bool = false;

    fn FrontendAction(
        self,
        path:        Path,
        module_base: ModulePath,
        g_scope:    *GlobalDisambigTable,
        resolver:   *ImportResolver, // one single import resolver for the full
                                     // batch; shared among all actions and threads,
                                     // fully indexed before the first action runs
        ci:         *CompilerInstance
    ) {
        self.path          = path;
        self.module_base   = module_base;
        self._ci           = ci;
        self._resolver     = resolver;
        self._global_scope = g_scope;
        self._stage        = TUStage::Pending;
        self._file_id      = u32(-1);
        self.result.path   = path.full_path();
    }

    default fn op delete (self);

    /// Executes the pipeline. See \c FrontendAction::run() below.
    fn run(self);

    fn stage(self)   -> TUStage { return self._stage;                  }
    fn file_id(self) -> u32     { return self._file_id;                }
    fn fids(self)    -> vec::<u32> { return self._fids;                }
    fn ok(self)      -> bool    { return self._stage == TUStage::Done; }
    fn failed(self)  -> bool    { return self._stage == TUStage::Failed; }
    priv static fn _ensure_parent_dir(path: string) {
        Path::make_parent_dirs(path);
    }

    /// --print-panic-sets (FrontendAction::_dump_panic_sets).
    priv fn _dump_panic_sets(self);

    priv fn _fatal(self, id: DiagID, msg: string) -> bool;
    /// --syntax-only, unless a C++ input includes Kairo (the include needs
    /// the whole program analysed, kairo_feeds_includes).
    priv fn _syntax_only(self) -> bool;
    priv fn _load(self)        -> bool;
    priv fn _preprocess(self)  -> bool;
    priv fn _parse(self)       -> bool;
    priv fn _sema(self)        -> bool;
    priv fn _attach_ffi_edges(self, tu: *TranslationUnit, ctx: *ASTContext, hs: *HeaderSet, view: *HeaderSet);
    priv fn _import_order(self) -> vec::<u32>;
    priv fn _sema_group(self, fids: *vec::<u32>, effects: *EffectTable, print_sema: bool, print_lowered: bool, sema_opts: PrintOptions);
    priv fn _codegen(self)     -> bool;
    priv fn _graph_header_sets(self) -> vec::<*HeaderSet>;
    fn _tu_is_empty(self, fid: u32) -> bool;   // not priv: _codegen's pool tasks call it (P380).
    priv fn _dump_tokens(self);
    priv fn _dump_preprocessed_source(self);
    priv fn _dump_macros(self);
    priv fn _dump_imports(self);
    priv fn _dump_overlays(self);
    priv fn _dump_symbols(self, tu: *TranslationUnit, ctx: *ASTContext, opts: PrintOptions);
    priv fn _dump_symbols_dc(self, dc: *DeclContext, ctx: *ASTContext, opts: PrintOptions, qual: string);
    priv fn _dump_mem_stats(self);
}

/// \p s as one shell word: unchanged when no shell would split or expand
/// it, otherwise in single quotes, each quote inside spelled '\''.
fn _shell_quote(s: string) -> string {
    if s.empty() { return "\x27\x27"; }
    var r = s;
    var plain = true;
    for var i: usize = 0; i < r.size(); ++i {
        var c = r[i];
        var ok = ((c >= 'a') && (c <= 'z')) || ((c >= 'A') && (c <= 'Z')) || ((c >= '0') && (c <= '9'))
              || (c == '-') || (c == '_') || (c == '=') || (c == '/') || (c == '.') || (c == ',')
              || (c == ':') || (c == '+') || (c == '@') || (c == '%');
        if !ok { plain = false; break; }
    }
    if plain { return s; }
    var out: string = "\x27";
    for var i: usize = 0; i < r.size(); ++i {
        if r[i] == static_cast::<char>(39) { out = out + "\x27\\\x27\x27"; continue; }
        var one: string = r.subslice(i, 1);
        out = out + one;
    }
    return out + "\x27";
}

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
class CompilerInstance {
    // --- Owned resources -------------------------------------------------
    //   Listed in construction order; destroyed in reverse. Each starts
    //   null: a run that answers early (--explain, --print-dirs) never
    //   builds the batch-scoped ones, and the destructor frees whatever is
    //   not null. Left uninitialized, it freed stack garbage, and whether
    //   that crashed depended on the environment's size (an unset LANG did).
    priv var _pool:    *ThreadPool = &null;
    priv var _vfm:     *VirtualFileManager = &null;
    priv var _diag:    *DiagEngine = &null;
    priv var _sm:      *SourceManager = &null;
    priv var _tcm:     *TokenCacheManager = &null;
    priv var _pretty:  *PrettyDiagConsumer = &null;
    priv var _basic:   *BasicDiagConsumer = &null;
    priv var _cmd:     *Command = &null;
    priv var _pp:      *PreProcessor = &null;
    priv var _imp:     *ImportResolver = &null;
    priv var _g_scope: *GlobalDisambigTable = &null;
    priv var _backend: *ClangBackend = &null; ///< shared clang backend; owned
    priv var _headers: *HeaderSetCache  = &null; ///< phase-A C++ header parses; owned, destroyed BEFORE _backend
    priv var _hindex:  *HeaderIndex     = &null; ///< header set -> Kairo TUs; owned
    priv var _freg:    *ForeignRegistry = &null; ///< USR -> imported decl, build-wide; owned
    priv var _finst:   *ForeignInstantiate = &null; ///< fills instances of imported templates from clang; owned
    priv var _ptids:   *PanicTypeIds = &null;       ///< the Panic set order every type formation applies (PANIC.md §1.3); owned.
    priv var _builtins: *BuiltinImport     = &null; ///< clang builtins as foreign decls, build-wide; owned
    /// P001W message/note pairs from _discover_roots and _check_sysroot,
    /// reported by initialize() (_report_root_warnings).
    priv var _root_warnings: vec::<string>;
    priv var _link_out:    string = "";   ///< executable/library path; "" = this run does not link
    priv var _obj_dir:     string = "";   ///< where objects go; always set by _plan_outputs
    priv var _obj_tmp:     bool   = false;///< _obj_dir is a temp dir this run owns and removes
    /// A linking run whose --emit lists more than the object: the entry
    /// TUs' outputs are the user's, so they go beside the executable rather
    /// than into a temp _obj_dir (emit_beside).
    priv var _emit_beside: bool   = false;
    priv var _obj_listed:  bool   = true; ///< --emit named obj itself (an _emit_beside run forces it on)
    priv var _kairo_inputs: usize = 0;    ///< Kairo (non-native, non-linker) inputs; set by _plan_outputs
    priv var _source_inputs: usize = 0;   ///< C/C++/ObjC/IR inputs clang compiles; set by _plan_outputs
    priv var _header_inputs: usize = 0;   ///< headers clang precompiles (one .pch each); set by _plan_outputs
    /// clang's driver, run in-process, for the C/C++ inputs (made on first
    /// use: a pure-Kairo build never builds a driver).
    priv var _jobs: opt::<ClangJobs> = &null;
    priv var _kincludes: opt::<DriverIncludeSource> = &null;   ///< owned; _jobs borrows it
    /// Every fid an earlier input's FrontendAction took (claim_fid). Widened
    /// to u64: u32(-1) is DenseSet<u32>'s empty key.
    priv var _claimed: llvm::DenseSet::<u64>;
    /// A C/C++ input includes a .k (_discover_includes).
    priv var _includes_kairo: bool = false;
    /// The Kairo library's objects for this link (_kairo_lib): lazily, after
    /// everything else (LinkJob::lazy_objects).
    priv var _lib_lazy: vec::<string>;
    /// The same objects as an archive, for a MinGW link; "" otherwise.
    priv var _lib_archive: string;
    /// The library build's entry file (_build_kairo_lib).
    priv var _lib_text: string = "pub import std\n";
    /// The bytes of the placeholder that takes fid 0 (_kairo_order).
    priv var _fid0_text: string = "\n";
    priv var _native_objs: vec::<string>; ///< objects from _compile_sources / _compile_runtime, in order
    // _start_runtime's work list, read by _finish_runtime (P380: the runtime
    // compiles on the pool during Sema). Parallel vectors, one row per source.
    priv var _rt_invs: vec::<libcxx::shared_ptr::<clang::CompilerInvocation>>;
    priv var _rt_objs: vec::<string>;
    priv var _rt_logs: vec::<string>;
    priv var _rt_oks:  vec::<u8>;      // not vec<bool>: its bits share bytes across threads
    priv var _rt_ents: vec::<string>;  // the cache entry a compiled object is stored to; "" for none
    priv var _rt_cache: string;
    priv var _rt_started: bool = false;
    priv var _rt_prestart_tried: bool = false;
    priv var _link_inputs: vec::<string>; ///< .o/.a/.so given on the command line, in order
    /// Every command-line input, classified once by _plan_outputs (in
    /// command-line order, with the -x each was given under). execute() and
    /// the output rules read this; nothing re-derives a kind from a path.
    priv var _inputs: vec::<InputKind>;

    // --- CLI state -------------------------------------------------------
    //   The invocation IS the CLI state. Flag-level queries go through
    //   _inv.args, which is empty (and answers "not asked" to everything) when
    //   the instance was built from a hand-made invocation.
    priv var _inv:    CompilerInvocation;

    // --- Constructors ----------------------------------------------------

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
    fn CompilerInstance(self, argc: i32, argv: *(*kairo::std::Legacy::char)) {
        self._boot_diagnostics();

        // Kept for print_help() alone   it needs the flag table and argv[0] for
        // the USAGE line. It is never parsed; from_args below owns that, and
        // parsing here as well would double-report every flag error.
        self._cmd = std::create::<Command>(argc, argv, self._diag);
        register_kairo_flags(self._cmd);

        var inv = CompilerInvocation::from_args(argc, argv, self._diag);
        self._adopt(&inv);
    }

    /// \brief constructs from kairo CLI words that did not come from main's
    ///        argv: kcc's translation of a clang command line (Driver/Kcc.k,
    ///        FlagTranslator::from_driver). The same parser as the argv
    ///        path, reporting into this instance's engine, so args_ok() and
    ///        flush_errors() behave as they do for `kairo`.
    fn CompilerInstance(self, words: ref!(vec::<string>)) {
        self._boot_diagnostics();
        self._cmd = std::create::<Command>(0, &null, self._diag);
        register_kairo_flags(self._cmd);
        var parsed = self._cmd->parse_words(words);
        var inv = CompilerInvocation();
        if parsed.ok {
            inv = CompilerInvocation::from_args(parsed);
        } else {
            (inv.args)   = parsed;
            (inv.ok)     = false;
            (inv.target) = TargetOptions::from_args(parsed);
        }
        self._adopt(&inv);
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
    fn CompilerInstance(self, inv: *CompilerInvocation) {
        self._boot_diagnostics();
        self._cmd = &null;
        self._adopt(inv);
    }

    /// Engine, file manager and the two consumers   everything needed before
    /// an invocation exists, because building one may report flag errors.
    priv fn _boot_diagnostics(self) {
        self._diag   = std::create::<DiagEngine>        ();
        self._vfm    = std::create::<VirtualFileManager>(self._diag);
        self._pretty = std::create::<PrettyDiagConsumer>();
        self._basic  = std::create::<BasicDiagConsumer> ();
        self._diag->add_consumer(self._pretty); // pretty is the default consumer
    }

    /// Takes ownership of \p inv (by copy) and stands up everything whose
    /// construction depends on it. Shared tail of both constructors.
    priv fn _adopt(self, inv: *CompilerInvocation) {
        if inv != &null { self.invocation()    = *inv; }
        else            { self.invocation().ok = false; }

        // Unusable invocation: leave subsystems at their defaults, exactly as
        // the CLI path has always done for a failed parse. args_ok() is what
        // the caller is expected to check before going further.
        if self.invocation().ok { self._apply_invocation(); }

        var want_threads: i32 =
                    i32(llvm::hardware_concurrency().compute_thread_count())
            if   (self.invocation().frontend.thread_count == 0)
            else (self.invocation().frontend.thread_count);
        // --cmax-threads is a hard cap over --threads AND the hardware default;
        // 0 means no cap. Clamping after the choice (not before) is what makes
        // it "regardless of --threads".
        var cap_threads: i32 = self.invocation().frontend.max_threads;
        if (cap_threads > 0) && (want_threads > cap_threads) { want_threads = cap_threads; }
        self._pool = std::create::<ThreadPool>(usize(want_threads));

        time_set_pool_size(i32(self._pool->get_thread_count()));

        self._sm      = std::create::<SourceManager>     (self._pool, self._vfm, self._diag);
        self._tcm     = std::create::<TokenCacheManager> (self._sm, self._pool, self._diag);
        self._g_scope = std::create::<GlobalDisambigTable>();
        self._basic->attach_source_manager(self._sm);
        self._pretty->attach_source_manager(self._sm);
    }

    // --- Destructor ------------------------------------------------------

    /// Destroys all resources in reverse-construction order.
    fn op delete (self) {
        // The driver bridge borrows the backend: it goes first.
        if self._jobs != &null { std::destroy(self._jobs); self._jobs = &null; }
        if self._kincludes != &null { std::destroy(self._kincludes); self._kincludes = &null; }
        // Header sets before the backend: a build in flight is using the
        // backend's invocation and VFS, and a live set's clang instance
        // shares that VFS. Drain the group so no set is mid-parse when it
        // dies; destroying the cache releases every set.
        if self._headers != &null {
            self._pool->wait_group(HEADER_BUILD_GROUP());
            self._pool->wait_group(CODEGEN_PCH_GROUP());
            // Early-exit paths skip both Sema's drain and release_all's.
            if self._diag != &null { self._headers->drain_all(self._diag, self._sm); }
            std::destroy(self._headers);
            self._headers = &null;
        }
        // Borrows _hindex's target, _freg and the backend's oracle: first out.
        if self._builtins != &null { std::destroy(self._builtins); self._builtins = &null; }
        if self._finst  != &null { std::destroy(self._finst);  self._finst  = &null; }   // borrows _hindex.
        if self._ptids  != &null {
            if self._g_scope != &null {
                self._g_scope->types()->pack_order     = &null;
                self._g_scope->instances()->pack_order = &null;
            }
            std::destroy(self._ptids);
            self._ptids = &null;
        }
        if self._hindex != &null { std::destroy(self._hindex); self._hindex = &null; }
        if self._freg   != &null { std::destroy(self._freg);   self._freg   = &null; }

        // backend first: its ClangLocMap borrows _sm, and its clang SM holds
        // MemoryBufferRef views into _vfm's mmaps. The startup task must be
        // drained before teardown.
        if self._backend != &null {
            self._pool->wait_group(CLANG_STARTUP_GROUP());
            std::destroy(self._backend);
            self._backend = &null;
        }

        if self._cmd     != &null { std::destroy(self._cmd);     self._cmd     = &null; }
        if self._pp      != &null { std::destroy(self._pp);      self._pp      = &null; }
        if self._g_scope != &null { std::destroy(self._g_scope); self._g_scope = &null; }
        if self._tcm     != &null { std::destroy(self._tcm);     self._tcm     = &null; }
        if self._imp     != &null { std::destroy(self._imp);      self._imp      = &null; }
        
        if self._pretty != &null {
            self._diag->remove_consumer(self._pretty);
            std::destroy(self._pretty);
            self._pretty = &null;
        }

        if self._basic  != &null {
            self._diag->remove_consumer(self._basic);
            std::destroy(self._basic);
            self._basic  = &null;
        }

        if self._sm     != &null { std::destroy(self._sm);     self._sm     = &null; }
        if self._diag   != &null { std::destroy(self._diag);   self._diag   = &null; }
        if self._vfm    != &null { std::destroy(self._vfm);    self._vfm    = &null; }
        if self._pool   != &null { std::destroy(self._pool);   self._pool   = &null; }
    }

    // --- Accessors -------------------------------------------------------

    fn diag(self)         -> *DiagEngine              { return self._diag;    }
    fn sm(self)           -> *SourceManager           { return self._sm;      }
    fn tcm(self)          -> *TokenCacheManager       { return self._tcm;     }
    fn pool(self)         -> *ThreadPool              { return self._pool;    }
    fn global_scope(self) -> *GlobalDisambigTable     { return self._g_scope; }
    fn invocation(self)   -> ref!(CompilerInvocation) { return self._inv;     }
    fn pp(self)           -> *PreProcessor            { return self._pp;      }
    fn imp(self)          -> *ImportResolver          { return self._imp;     }
    fn backend(self)      -> *ClangBackend            { return self._backend; }
    fn headers(self)      -> *HeaderSetCache          { return self._headers; }
    fn header_index(self) -> *HeaderIndex             { return self._hindex;  }
    fn foreign_instantiate(self) -> *ForeignInstantiate { return self._finst; }
    fn panic_type_ids(self) -> *PanicTypeIds { return self._ptids; }
    fn foreign_registry(self) -> *ForeignRegistry     { return self._freg;    }
    fn builtins(self)     -> *BuiltinImport           { return self._builtins; }

    /// \brief true if \p fid is a C++ header Sema/Foreign imported: a TU whose
    ///        decls came from clang, with no Kairo source behind it.
    fn is_foreign_fid(self, fid: u32) -> bool {
        var ctx = self._g_scope->get_context(fid);
        if ctx == &null { return false; }
        var tu = reinterpret_cast::<*TranslationUnit>(ctx->tu);
        return (tu != &null) && tu->is_foreign;
    }
    /// \brief the name a Kairo TU's outputs take under the object dir when
    ///        its module path is one segment (or none, by its file stem):
    ///        that name, or `<stem>.k` when a C/C++ input of the build has
    ///        that stem and so writes `<stem>.o` itself (_plan_outputs).
    fn kairo_object_stem(self, stem: string) -> string {
        for k: InputKind in self._inputs {
            if k.cls != InputClass::Source { continue; }
            if Path::stem_of(k.path) == stem { return stem + ".k"; }
        }
        return stem;
    }

    /// \brief true when a C++ or Objective-C++ input includes a .k
    ///        (_discover_includes found one): the include is emitted from
    ///        its analysed and lowered tree, so the Kairo inputs go through
    ///        sema even when the action stops earlier for C++ (--preprocess,
    ///        --syntax-only). All of them, not only the included ones: an
    ///        included file may be claimed by an importer's action.
    fn kairo_feeds_includes(self) -> bool { return self._includes_kairo; }

    /// \brief true the first time \p fid is asked for: the asking action
    ///        parses, checks and emits it. Inputs share their imports (every
    ///        one reaches builtin), and the PP hands each action its whole
    ///        graph; a fid an earlier action took is already through every
    ///        stage, its tables frozen and its object written.
    fn claim_fid(self, fid: u32) -> bool {
        var k = static_cast::<u64>(fid);
        if self._claimed.contains(k) { return false; }
        self._claimed.insert(k);
        return true;
    }

    // --- CLI query helpers -----------------------------------------------

    fn wants_help(self)    -> bool { return self.invocation().args.get_bool("help");               }
    fn wants_version(self) -> bool { return self.invocation().args.get_bool("version");            }
    fn wants_explain(self) -> bool { return !self.invocation().args.get_string("explain").empty(); }

    /// \brief whether this instance's invocation is usable.
    ///
    /// \details On the argv path this is exactly "did the flags parse". On the
    ///          invocation path there are no flags to parse, so it reports
    ///          whether the supplied invocation was usable   false for a null
    ///          one, or for one a caller explicitly marked not-ok.
    fn args_ok(self) -> bool { return self.invocation().ok; }

    /// True when any info flag is present whose subsystem is not yet live.
    fn wants_info_query(self) -> bool {
        return self.invocation().args.get_bool("print-targets")
            || self.invocation().args.get_bool("print-cpus")
            || self.invocation().args.get_bool("print-dirs")
            || self.invocation().args.get_bool("print-clang-args")
            || self.invocation().args.get_bool("print-jobs")
            || self.invocation().args.get_bool("print-from-clang")
            || self.invocation().args.get_bool("print-target-info")
            || self.invocation().args.get_bool("print-cfg");
    }

    // --- Identity actions ------------------------------------------------

    fn get_target_triple(self) -> string {
        var triple = llvm::Triple(llvm::Triple::normalize(llvm::sys::getProcessTriple()));
        if (triple.getVendor()) == (llvm::Triple::UnknownVendor) && (triple.isOSLinux()) {
            triple.setVendor(llvm::Triple::PC);
        }

        return string(triple.getTriple());
    }

    /// The triple compiled for without --target: the host's arch and OS with
    /// a C library the compiler ships. Windows is <arch>-pc-windows-gnu,
    /// never msvc. Linux follows the C library the HOST runs (its dynamic
    /// loader, HostSystem::host_libc): <arch>-unknown-linux-gnu on a glibc
    /// host, built against the bundled glibc 2.31 sysroot (the floor, so the
    /// program runs on any glibc since), and <arch>-unknown-linux-musl
    /// otherwise; the eabi/eabihf float ABI is kept on 32-bit ARM. Any other
    /// host keeps its own triple. --native uses the same triple.
    fn get_default_target_triple(self) -> string {
        var triple = llvm::Triple(llvm::Triple::normalize(sref(self.get_target_triple())));
        if triple.isOSWindows() {
            triple.setVendor(llvm::Triple::PC);
            triple.setEnvironment(llvm::Triple::GNU);
        } else if triple.isOSLinux() {
            // Vendor `unknown`, not the host's: the bundled musl sysroots are
            // built for <arch>-unknown-linux-musl (clang's canonical spelling,
            // and the name of their compiler-rt directory). A host-derived
            // x86_64-pc-linux-musl names no directory any of them ships, so
            // every clang that is handed kairo's target -- the tests' link
            // driver, a user's build system -- misses libclang_rt.builtins.
            // The same rule holds for the glibc default: x86_64-unknown-linux-gnu.
            triple.setVendor(llvm::Triple::UnknownVendor);
            var env = triple.getEnvironment();
            var hf  = (env == llvm::Triple::GNUEABIHF) || (env == llvm::Triple::MuslEABIHF);
            var eabi = (env == llvm::Triple::GNUEABI) || (env == llvm::Triple::MuslEABI);
            var an: llvm::StringRef = triple.getArchName();
            var glibc = HostSystem::host_libc(Toolchain::canon_arch(string(an.data(), an.size())), hf) == "glibc";
            if hf {
                triple.setEnvironment((llvm::Triple::GNUEABIHF) if (glibc) else (llvm::Triple::MuslEABIHF));
            } else if eabi {
                triple.setEnvironment((llvm::Triple::GNUEABI) if (glibc) else (llvm::Triple::MuslEABI));
            } else {
                triple.setEnvironment((llvm::Triple::GNU) if (glibc) else (llvm::Triple::Musl));
            }
        }
        return string(triple.getTriple());
    }

    /// No-op when the instance was built from an invocation: there is no flag
    /// table to describe and no argv[0] to name in the USAGE line.
    fn print_help(self) {
        if self._cmd == &null { return; }
        self._cmd->print_help();
    }

    fn print_version(self) {
        std::print(f"installed version: {VERSION}");
        // "target" is what this run would compile for (--target when given),
        // "host" is the machine running the compiler; reporting only the host
        // misled anyone checking a cross invocation.
        std::print(f"target triple:     {self._effective_triple()}");
        std::print(f"host triple:       {self.get_target_triple()}");
        std::print(f"thread model:      {std::get_thread_model()}");
        std::print(f"installed at:      {Path::parent_of(std::get_exe_path())}");
        var sr = self._version_sysroot();
        if sr.empty() { sr = "could not find associated sysroot"; }
        std::print(f"sysroot:           {sr}");
    }

    /// The sysroot this run would compile against: the bundled one for the
    /// target (_use_bundled_sysroot's lookup, without its validation), else
    /// --sysroot, else "".
    priv fn _version_sysroot(self) -> string {
        var want = self._sysroot_target();
        if !want.empty() {
            var dir = self._bundled_sysroot_dir(want);
            if !dir.empty() { return dir; }
        }
        return self.invocation().target.sysroot;
    }

    /// Resolves and renders the long-form explanation for a diagnostic code.
    /// Returns 1 if the code is unknown.
    fn run_explain(self) -> i32 {
        var code = self.invocation().args.get_string("explain");

        var first: usize = code.view().find_first_not_of(r" \t\n\r\f\v");
        if !(string::npos == first) {
            var last: usize = code.view().find_last_not_of(r" \t\n\r\f\v");
            code = code.subslice(first, (last - first + 1));
        }

        var diag_id = diag_from_code(code);
        var explain = diag_explain(diag_id);
        if explain.empty() {
            std::eprintln(f"error: unknown diagnostic code '{code}\x27");
            return 1;
        }

        var r = TermRenderer(true, 80);
        std::print(r.render(explain));
        return 0;
    }

    /// Header roots for --sysroot, resolved the way the linker resolves the
    /// same flag (Toolchain::resolve), so the two halves cannot disagree.
    ///
    ///   SYSROOT.toml  its include_dirs under <dir>/<sysroot>; that root is
    ///                 also -isysroot.
    ///   Apple SDK     <sdk>/usr/include{/c++/v1}: --sysroot is the SDK root,
    ///                 as for ld's -syslibroot and SDKSettings.json.
    ///   otherwise     nothing here; ClangBackend keeps the prefix model.
    ///
    /// Apple roots of either kind also get System/Library/Frameworks. A
    /// manifest that fails to load is left to the linker to report.
    priv fn _sysroot_header_roots(self, bcfg: ref!(ClangBackendConfig)) {
        var sr = LinkText::strip_slash(bcfg.sysroot);
        if sr.empty() || (sr == "/") { return; }

        var tri    = llvm::Triple(llvm::Triple::normalize(sref(bcfg.triple)));
        var darwin = tri.isOSDarwin();

        var root = sr;
        var dirs = vec::<string>();
        var mpath = LinkText::join(sr, "SYSROOT.toml");
        if LinkFS::is_file(mpath) {
            var m = SysrootManifest();
            if !SysrootManifest::load(mpath, m) { return; }
            if (!m.sysroot.empty()) && (m.sysroot != ".") { root = LinkText::join(sr, m.sysroot); }
            for d: string in m.include_dirs { dirs.push_back(LinkText::join(root, d)); }
            for d: string in m.cc_defines   { bcfg.defines.push_back(d); }
        } else if darwin {
            dirs.push_back(LinkText::join(sr, "usr/include/c++/v1"));
            dirs.push_back(LinkText::join(sr, "usr/include"));
        } else {
            return;
        }

        (bcfg.sysroot) = root;
        for d: string in dirs {
            if LinkText::contains(d, "/c++/") { bcfg.cxx_include_dirs.push_back(d); }
            else                              { bcfg.include_dirs.push_back(d); }
        }
        if darwin {
            var fw = LinkText::join(root, "System/Library/Frameworks");
            if LinkFS::is_dir(fw) { bcfg.framework_dirs.push_back(fw); }
        }
    }

    /// A --target picks the sysroot bundled beside this binary,
    /// <prefix>/sysroot/<target> with <prefix> the directory above bin/, over
    /// --sysroot. One --sysroot then serves every host build while each
    /// --target gets headers and libraries for its own ABI; a single
    /// sysroot shared across targets makes clang reject the C library's
    /// typedefs (size_t is `unsigned long` in x86_64 musl and `unsigned int`
    /// on i386) and makes uint64_t 32 bits on Windows.
    ///
    /// A directory named exactly as --target is spelled wins. Otherwise any
    /// directory whose name is the same target in another spelling matches
    /// (Toolchain::same_target, plus the sub-arch so arm64e is not arm64):
    /// x86_64-pc-windows-msvc finds x86_64-windows-msvc, and llvm reads
    /// x86_64-linux-gnu-glibc2.31 as a gnu environment, so x86_64-linux-gnu
    /// finds that. Of several such, the first by name, so the pick never
    /// follows readdir order. -m32/-m64 look up the arch they switch to, as
    /// the rest of the driver does: --target=x86_64-linux-musl -m32 finds
    /// i686-linux-musl.
    ///
    /// Without --target the same lookup runs for the default target
    /// (get_default_target_triple), unless --sysroot was given: an explicit
    /// --sysroot outranks only an implicit target.
    ///
    /// No match is not an error: --sysroot is used if given, and otherwise
    /// there are no system headers. A match that is not a directory holding
    /// a loadable SYSROOT.toml is P007E: compiling against half a sysroot
    /// fails much later, far from the cause.
    ///
    /// \return false if a match was malformed (already reported).
    priv fn _use_bundled_sysroot(self) -> bool {
        var tg = &(self.invocation().target);
        // --native: the host is the sysroot. The bundle for the host's C
        // library is still found, by _apply_host_system, for its libc++ and
        // compiler-rt only.
        if tg->native {
            if tg->sysroot.empty() { (tg->sysroot) = "/"; }
            return true;
        }
        var want = self._sysroot_target();
        if want.empty() { return true; }
        var dir = self._bundled_sysroot_dir(want);
        if dir.empty() { return true; }

        var why = "";
        var mpath = LinkText::join(dir, "SYSROOT.toml");
        if !LinkFS::is_dir(dir) {
            why = "it is not a directory";
        } else if !LinkFS::is_file(mpath) {
            why = "it has no SYSROOT.toml";
        } else {
            var m = SysrootManifest();
            if !SysrootManifest::load(mpath, m) { why = f"SYSROOT.toml: {m.error}"; }
        }
        if !why.empty() {
            self._diag->report(DiagID::P007E,
                f"the bundled sysroot for '{want}\x27 is malformed: {dir}").emit();
            self._diag->report(DiagID::P007N, why).emit();
            return false;
        }

        (tg->sysroot) = dir;
        return true;
    }

    /// The triple whose bundled sysroot this run looks up: --target, else
    /// the default target unless --sysroot was given (""), switched by
    /// -m32/-m64.
    priv fn _sysroot_target(self) -> string {
        var tg = &(self.invocation().target);
        if tg->native { return ""; }
        var want = tg->triple;
        if want.empty() {
            if !tg->sysroot.empty() { return ""; }
            want = self.get_default_target_triple();
        }
        if tg->m32 || tg->m64 {
            var tt = llvm::Triple(llvm::Triple::normalize(sref(want)));
            tt = (tt.get32BitArchVariant()) if (tg->m32) else (tt.get64BitArchVariant());
            want = string(tt.getTriple());
        }
        return want;
    }

    /// <prefix>/sysroot/<want>, or the one directory there naming the same
    /// target in another spelling; "" for none.
    priv fn _bundled_sysroot_dir(self, want: string) -> string {
        var prefix = Path::parent_of(Path::parent_of(std::get_exe_path()));
        var root   = LinkText::join(prefix, "sysroot");
        var dir    = LinkText::join(root, want);
        if !LinkFS::exists(dir) {
            var pick = "";
            for name: string in LinkFS::list_dir(root) {
                // Only directories can be sysroots: the manifest file beside
                // them matched an unknown triple and was then reported as a
                // malformed sysroot instead of the real "unknown target".
                if !LinkFS::is_dir(LinkText::join(root, name)) { continue; }
                if !CompilerInstance::_same_bundled_target(name, want) { continue; }
                if pick.empty() || (name < pick) { pick = name; }
            }
            if pick.empty() { return ""; }
            dir = LinkText::join(root, pick);
        }
        return dir;
    }

    /// Whether the bundled sysroot directory \p name is for \p triple.
    priv static fn _same_bundled_target(name: string, triple: string) -> bool {
        if !Toolchain::same_target(name, triple) { return false; }
        var ta = llvm::Triple(llvm::Triple::normalize(sref(name)));
        var tb = llvm::Triple(llvm::Triple::normalize(sref(triple)));
        return ta.getSubArch() == tb.getSubArch();
    }

    /// Returns the effective target triple: --target if given, else the
    /// default target (get_default_target_triple).
    ///
    /// Reads the typed option rather than the raw flag so it works on the
    /// invocation path too. TargetOptions::triple is set verbatim from
    /// `--target`, so the argv path is unaffected.
    priv fn _effective_triple(self) -> string {
        var tg = &(self.invocation().target);
        var t  = tg->triple;
        var explicit_target = !t.empty();
        if !explicit_target { t = self.get_default_target_triple(); }

        // -m32/-m64 rewrite the ARCH of the triple, as clang does, so the cc1
        // `-triple` agrees with the sysroot _use_bundled_sysroot picked with
        // the same rewrite: left at x86_64, --m32 compiled 64-bit code against
        // the i686 headers and died on the size_t typedef mismatch. -m32 wins
        // when both are given (matches _use_bundled_sysroot). An arch with no
        // such variant has pointer width 0 after the rewrite and keeps its
        // own triple instead of becoming "unknown".
        if tg->m32 || tg->m64 {
            var tri0 = llvm::Triple(llvm::Triple::normalize(sref(t)));
            var wide = tri0;
            wide = (tri0.get32BitArchVariant()) if (tg->m32) else (tri0.get64BitArchVariant());
            if wide.getArchPointerBitWidth() != 0 {
                t = string(wide.getTriple());
            }
        }

        // Canonicalized here so clang, codegen and the linker all see the
        // same float ABI (see Toolchain::canonical_triple).
        if explicit_target {
            return Toolchain::canonical_triple(t);
        }

        return t;
    }

    /// Looks up a registered target by triple. Returns nullptr if not found
    /// and writes the LLVM error message to `err_out`.
    priv fn _lookup_target(self, triple: string, err_out: *string) -> *void {
        var result: *void = &null;
        var err:     libcxx::string;
        var triple_str = triple;

        var llvm_triple = llvm::Triple(llvm::Triple::normalize(sref(triple_str)));
        var T = llvm::TargetRegistry::lookupTarget(llvm_triple, err);

        if T == &null {
            (*err_out) = string(err.c_str());
        }

        result = const_cast::<*void>(static_cast::<const *void>(T));
        return result;
    }

    //  --print-targets

    /// Lists all targets registered in this LLVM build. Mirrors `llc -version`'s
    /// "Registered Targets" section.
    fn print_targets(self) -> i32 {
        std::print("Registered targets:");

        // collect into a vector so we can sort and align the output
        var rows: libcxx::vector::<libcxx::pair::<llvm::StringRef, llvm::StringRef>>;
        var max_name: size_t = 0;

        for T in llvm::TargetRegistry::targets() {
            rows.emplace_back(T.getName(), T.getShortDescription());
            max_name = libcxx::max(max_name, libcxx::strlen(T.getName()));
        }
        
        libcxx::sort(rows.begin(), rows.end(),
            fn (const a: ref!(libcxx::pair::<llvm::StringRef, llvm::StringRef>),
                const b: ref!(libcxx::pair::<llvm::StringRef, llvm::StringRef>)) || -> bool = a.first < b.first);

        for row in rows {
            var out = f"  {string(row.first.data(), row.first.size())}";
            for var i: usize = row.first.size(); (i < (max_name + 2)); ++i {
                out += " ";
            }
            
            out += f"- {string(row.second.data(), row.second.size())}";
            std::print(out);
        }

        return 0;
    }

    //  --print-cpus

    /// Lists CPUs supported by the effective target. Uses --target if given,
    /// otherwise the host triple. Mirrors `llc -mtriple=X -mcpu=help`.
    fn print_cpus(self) -> i32 {
        var triple = self._effective_triple();
        var llvm_triple = llvm::Triple(llvm::Triple::normalize(sref(triple)));
        var err:     libcxx::string;
    
        var T: *llvm::Target = const_cast::<*llvm::Target>(
            llvm::TargetRegistry::lookupTarget(llvm_triple, err)
        );

        if T == &null {
            // _apply_invocation already reported this triple (and cleared ok)
            // when it resolved the target; a second P004F here printed the
            // same line twice.
            if self.invocation().ok {
                self._diag->report(DiagID::P004F, f"unknown target triple '{triple}': {string(err)}").emit();
            }
            // Info queries exit before execute(), so nothing else drains the
            // engine; without this the error is built and never printed.
            self.flush_errors();
            return 1;
        }

        var TM: *llvm::TargetMachine = &null;
        var opts: llvm::TargetOptions;
        
        TM = T->createTargetMachine(
            llvm_triple,
            /*CPU=*/r"generic",
            /*Features=*/r"",
            opts,
            libcxx::nullopt
        );

        finally {
            delete TM;
        }

        if TM == &null {
            self._diag->report(DiagID::P005F, f"failed to create TargetMachine for '{string(triple.raw())}\x27").emit();
            return 1;
        }

        var STI: *llvm::MCSubtargetInfo = const_cast::<*llvm::MCSubtargetInfo>(TM->getMCSubtargetInfo());
        if STI == &null {
            self._diag->report(DiagID::P005F, f"no subtarget info for '{string(triple.raw())}\x27").emit();
            return 1;
        }

        std::print(f"Available CPUs for target '{string(triple.raw())}':");

        var cpu_rows: libcxx::vector::<libcxx::string>;
        var max_cpu:  size_t = 0;

        for cpu in STI->getAllProcessorDescriptions() {
            cpu_rows.emplace_back(cpu.Key);
            max_cpu = libcxx::max(max_cpu, libcxx::strlen(cpu.Key));
        }

        libcxx::sort(cpu_rows.begin(), cpu_rows.end(),
            fn (const a: ref!(libcxx::string), const b: ref!(libcxx::string)) || -> bool = a < b);

        for row in cpu_rows {
            std::print(f"  {string(row)}");
        }

        std::print("");
        std::print("Available features:");

        var feat_rows: libcxx::vector::<libcxx::pair::<libcxx::string, libcxx::string>>;
        var max_feat:  size_t = 0;

        for feat in STI->getAllProcessorFeatures() {
            var d    = feat.Desc;
            var desc = d if ((d != &null) && ((*d) != r'\0')) else r"";
            feat_rows.emplace_back(feat.Key, desc);
            max_feat = libcxx::max(max_feat, libcxx::strlen(feat.Key));
        }

        libcxx::sort(feat_rows.begin(), feat_rows.end(),
            fn (const a: ref!(libcxx::pair::<libcxx::string, libcxx::string>),
                const b: ref!(libcxx::pair::<libcxx::string, libcxx::string>)) || -> bool = a.first < b.first);

        for row in feat_rows {
            var out = f"  {string(row.first.c_str(), row.first.size())}";
            for var i: usize = row.first.size(); i < max_feat + 2; ++i {
                out += " ";
            }

            if row.second.size() > 0 {
                out += f"- {string(row.second.c_str(), row.second.size())}";
            }

            std::print(out);
        }

        return 0;
    }

    //  --print-target-info

    /// Prints triple, architecture, ABI, pointer width, endianness, object format,
    /// data layout, and default CPU for the effective target. Uses --target if
    /// given, otherwise the host triple.
    fn print_target_info(self) -> i32 {
        var triple = self._effective_triple();
        var llvm_triple = llvm::Triple(llvm::Triple::normalize(sref(triple)));
        var err: libcxx::string;

        var T: *llvm::Target = const_cast::<*llvm::Target>(
            llvm::TargetRegistry::lookupTarget(llvm_triple, err)
        );

        if T == &null {
            if self.invocation().ok { // see print_cpus: _apply_invocation may have reported it already
                self._diag->report(DiagID::P004F,
                    f"unknown target triple '{string(triple.raw())}': {string(err)}"
                ).emit();
            }
            self.flush_errors(); // see print_cpus: info queries never reach execute()
            return 1;
        }

        var full_triple: string          = string(llvm_triple.getTriple());
        var arch:        llvm::StringRef = llvm_triple.getArchName();
        var vendor:      llvm::StringRef = llvm_triple.getVendorName();
        var os_name:     llvm::StringRef = llvm_triple.getOSName();
        var environment: llvm::StringRef = llvm_triple.getEnvironmentName();

        var ptr_width: string;
        if      llvm_triple.isArch64Bit() { ptr_width = "64-bit";  }
        else if llvm_triple.isArch32Bit() { ptr_width = "32-bit";  }
        else if llvm_triple.isArch16Bit() { ptr_width = "16-bit";  }
        else                              { ptr_width = "unknown"; }

        var endian: string = ("little") if (llvm_triple.isLittleEndian()) else ("big");

        var os_family: string;
        if      llvm_triple.isOSLinux()          { os_family = "linux";        }
        else if llvm_triple.isOSDarwin()         { os_family = "darwin";       }
        else if llvm_triple.isOSWindows()        { os_family = "windows";      }
        else if llvm_triple.isOSFreeBSD()        { os_family = "freebsd";      }
        else if llvm_triple.isOSWASI()           { os_family = "wasi";         }
        else if llvm_triple.isOSBinFormatELF()   { os_family = "elf (other)";  }
        else if llvm_triple.isOSBinFormatMachO() { os_family = "macho (other)"; }
        else                                     { os_family = "unknown";      }

        var obj_format: string;
        switch llvm_triple.getObjectFormat() {
            case llvm::Triple::COFF { obj_format = "COFF"; }
            case llvm::Triple::ELF { obj_format = "ELF"; }
            case llvm::Triple::MachO { obj_format = "Mach-O"; }
            case llvm::Triple::Wasm { obj_format = "Wasm"; }
            case llvm::Triple::XCOFF { obj_format = "XCOFF"; }
            case llvm::Triple::GOFF { obj_format = "GOFF"; }
            case llvm::Triple::DXContainer { obj_format = "DXContainer"; }
            case llvm::Triple::SPIRV { obj_format = "SPIR-V"; }
            default { obj_format = "unknown"; }
        }

        std::print(f"Triple:          {full_triple}");
        std::print(f"Architecture:    {string(arch.data(), arch.size())}");
        std::print(f"Vendor:          {string(vendor.data(), vendor.size())}");
        std::print(f"OS:              {string(os_name.data(), os_name.size())}");
        std::print(f"Environment:     {string(environment.data(), environment.size())}");
        std::print(f"Pointer width:   {ptr_width}");
        std::print(f"Endianness:      {endian}");
        std::print(f"OS family:       {os_family}");
        std::print(f"Object format:   {obj_format}");

        // Data layout via TargetMachine
        var TM: *llvm::TargetMachine = &null;
        var opts: llvm::TargetOptions;

        TM = T->createTargetMachine(
            llvm_triple,
            /*CPU=*/r"generic",
            /*Features=*/r"",
            opts,
            libcxx::nullopt
        );

        if TM == &null {
            self._diag->report(DiagID::P005F,
                f"failed to create TargetMachine for '{string(triple.raw())}\x27"
            ).emit();
            return 1;
        }

        finally {
            delete TM;
        }

        var data_layout: string          = string(TM->createDataLayout().getStringRepresentation());
        var default_cpu: llvm::StringRef = TM->getTargetCPU();

        std::print(f"Data layout:     {data_layout}");
        std::print(f"Default CPU:     {string(default_cpu.data(), default_cpu.size())}");

        return 0;
    }

    /// Handles info-query flags. Currently implements \c --print-cfg;
    /// all other flags are no-ops until their subsystems exist.
    fn run_info_query(self) -> i32 {
        if self.invocation().args.get_bool("print-targets") {
            return self.print_targets();
        }

        if self.invocation().args.get_bool("print-cpus") {
            return self.print_cpus();
        }

        if self.invocation().args.get_bool("print-target-info") {
            return self.print_target_info();
        }

        if self.invocation().args.get_bool("print-dirs") {
            return self.print_dirs();
        }

        if self.invocation().args.get_bool("print-clang-args") {
            return self.print_clang_args(false);
        }
        if self.invocation().args.get_bool("print-jobs") {
            return self.print_clang_args(true);
        }

        if self.invocation().args.get_bool("print-from-clang") {
            return self.print_from_clang();
        }

        if self.invocation().args.get_bool("print-cfg") {
            for s: string in self.invocation().args.get_list("cfg") { std::print(s); }
            return 0;
        }
        return 0;
    }

    /// The ICE hook: drain every TU's buffered sink into the engine, then
    /// render the engine's console consumer, as the end of a run would.
    /// \p ci is the CompilerInstance execute() registered.
    priv static fn _flush_for_ice(ci: *void) {
        var self_ = reinterpret_cast::<*CompilerInstance>(ci);
        if (self_ == &null) || (self_->_diag == &null) { return; }
        if self_->_g_scope != &null { self_->_g_scope->drain_sinks_for_ice(self_->_diag); }
        self_->_diag->flush_consumers_for_ice();
    }

    fn flush_errors(self) {
        if (self.invocation().diag.format == "basic") || (self.invocation().diag.format == "json") {
            self._basic->finalize_to_stderr();
        } else {
            self._pretty->finalize_to_stderr();
        }
    }

    // --- Compilation pipeline --------------------------------------------
    // the step to index, and create the shared instance
    /// \brief wires the batch-scoped subsystems: ImportResolver, PreProcessor,
    ///        and the shared ClangBackend.
    ///
    /// \details Must run before execute() or any Frontend/ parse entry point;
    ///          execute() asserts on it. Named to match that assert   it was
    ///          `index()`, which collided with the unrelated ASTParse Index
    ///          pass and described neither of the three things it builds.
    /// One `-I` (or --macro-search-path) entry: an UNNAMED search dir, as
    /// the cwd is. A file under it is its path relative to it, unless a
    /// pinned module.k (`module foo`) above the file names a library; that
    /// pin is the only way a directory gets a name (IMPORTS.md §2.1).
    ///
    /// `-I name=dir` used to be a second way to say it, and the two could
    /// disagree. It is an error that says where the name goes now, not a
    /// silently missing directory literally called `name=dir`. A path that
    /// does contain `=` and exists is a path; every other spec with an `=`
    /// is the old form, whatever the part before it looks like -- a
    /// `geo-lib=vendor/geometry` used to slip past a "name-shaped" test and
    /// vanish as a nonexistent directory, leaving only an R011E at the
    /// import with nothing pointing at the flag.
    priv fn _add_root(self, rb: ref!(ImportResolver::Builder), spec: string) {
        var pos = spec.view().find('=');
        if (pos != usize(-1)) && (!Path(spec).is_directory()) {
            var name = string(spec.raw(), pos);
            var dir  = string(spec.raw() + pos + 1, spec.size() - pos - 1);
            var name_shaped = pos > 0;
            for var i: usize = 0; i < name.size(); ++i {
                var c = name[i];
                var ok = ((c >= 'a') && (c <= 'z')) || ((c >= 'A') && (c <= 'Z'))
                      || ((c >= '0') && (c <= '9')) || (c == '_') || (c == ':');
                if !ok { name_shaped = false; break; }
            }
            // The shape only picks the hint: a pin to copy when the part
            // before `=` could be one, the rule alone when it could not.
            if name_shaped {
                self._diag->report(DiagID::U001E,
                    f"-I {spec}: no such directory, and the name=dir form is gone; -I takes a directory only. To name the library, "
                    + f"make `module {name}` the first line of {dir}/module.k and pass -I {dir}").emit();
            } else {
                self._diag->report(DiagID::U001E,
                    f"-I {spec}: no such directory; -I takes a directory only, and the name=dir form is gone: "
                    + "a library is named by the `module` declaration on the first line of its module.k").emit();
            }
            return;
        }
        rb.add_include(Path(spec));
    }

    /// Two roots under one name make a module path mean two files. Fatal, and
    /// reported before anything is parsed. A pinned directory found later
    /// (canonical_module_path's walk up) is reported by the PP walk, with
    /// the same text (RootNameCollision::message).
    priv fn _report_root_collisions(self) {
        if self._imp == &null { return; }
        var found = self._imp->take_root_collisions();
        for var i: usize = 0; i < found.size(); ++i {
            var c = found[i];
            // Placeholder code for the mismatch: no real code covers a
            // registration disagreeing with the pin (verified against
            // Resolution.diag.toml).
            var id = (DiagID::R001E) if (c.mismatch) else (DiagID::R018E);
            self._diag->report(DiagCode(id), c.message()).emit();
        }
    }

    /// Two inputs one module path names (decision E): `./a.k` and `inc/a.k`
    /// under `-I inc` are both module `a`, and each would write `a.o`, the
    /// second over the first. An import of that path is already R017E, but
    /// inputs are modules too now (decision C) and nothing imports them, so
    /// they are claimed here, every one before any is compiled. False when
    /// two collided (reported).
    priv fn _claim_input_identities(self) -> bool {
        if self._imp == &null { return true; }
        for k: InputKind in self._inputs {
            if (k.cls == InputClass::LinkInput) || (k.cls == InputClass::Source) || (k.cls == InputClass::Header) { continue; }
            var p = Path(k.path);
            self._imp->claim_identity(self._imp->input_module_path(p), p);
        }
        // Two inputs on one path, and any pin the walk up found claiming a
        // registered library's name.
        var ok = true;
        for msg: string in self._imp->take_late_collisions() {
            self._diag->report(DiagCode(DiagID::R018E), msg).emit();
            ok = false;
        }
        return ok;
    }

    /// \brief the cc1 tokens `-ffast-math` stands for, as clang 22's driver
    ///        spells them (checked with `clang -### -ffast-math`). Shared by
    ///        -ffast-math and --fp-model=fast, which differ only in
    ///        -complex-range.
    ///
    /// \details Spelled out rather than taken from the driver probe: the probe
    ///          runs once per triple for target defaults, and its keep-list
    ///          would also have to carry a default-on `-ffp-contract=on`
    ///          that Kairo's cc1 line must not have.
    /// \brief the shared clang backend's configuration, from the
    ///        invocation: target, header roots, optimization and debug
    ///        info, the user's -W policy. initialize builds the backend from
    ///        it; --print-clang-args prints what it makes.
    priv fn _backend_config(self) -> ClangBackendConfig {
        var bcfg = ClangBackendConfig{};
        (bcfg.triple) = self._effective_triple();
        (bcfg.wargs)  = FlagTranslator::warnings(self.invocation().diag, ClangSpelling::CC1);

        // The target flags clang has a spelling for. Parsed into the
        // invocation long before this; until they are copied here they reach
        // nothing -- `--sysroot` used to be accepted and silently dropped.
        var tgt = self.invocation().target;
        if !tgt.cxx_std.empty() { (bcfg.cxx_std) = tgt.cxx_std; }
        // --march is a DRIVER spelling (cc1 has none): the probe turns it
        // into -target-cpu and the -target-feature pairs its extensions imply.
        for a: string in FlagTranslator::march_driver(tgt) { bcfg.driver_words.push_back(a); }
        // (bcfg.c_std stays c17: native_invocation builds only Lib/rt, Kairo's
        // own runtime; --c-std is for the user's C inputs.)
        // Every flag word below is spelled by FlagTranslator, the one home
        // of the kairo <-> clang mapping; this function only places them.
        for a: string in FlagTranslator::target(tgt, ClangSpelling::CC1) { bcfg.extra_cc1.push_back(a); }
        var missing_plugins = vec::<string>();
        for a: string in FlagTranslator::codegen(self.invocation(), bcfg.triple, ClangSpelling::CC1, &missing_plugins) {
            bcfg.extra_cc1.push_back(a);
        }
        for pl: string in missing_plugins {
            self._diag->report(DiagID::U001E,
                f"--pass-plugin: no such plugin file '{pl}\x27").emit();
        }
        // User header dirs and macros for C++ interop, ahead of the system
        // roots: -I / --ffi-include / --cxx-include (-I), --cxx-define (-D),
        // --cxx-undefine (-U).
        for a: string in FlagTranslator::preprocessor(self.invocation()) { bcfg.extra_cc1.push_back(a); }
        // The triple's environment as a macro (`__kairo_env_musl__`):
        // clang predefines the arch and OS, but nothing tells musl from
        // glibc, which `__builtin_target_info()` (Lib/builtin) must.
        var env_tt = llvm::Triple(llvm::Triple::normalize(sref(bcfg.triple)));
        var env_sr: llvm::StringRef = env_tt.getEnvironmentName();
        var env_nm = string(env_sr.data(), env_sr.size());
        if env_nm.empty() { env_nm = "unknown"; }
        bcfg.extra_cc1.push_back(f"-D{LowerTargets::reserved_prefix()}env_{env_nm}__=1");
        // The runtime root, after the user's: `rt/fmt.h` names the same file
        // from Lib/builtin/fmt/fmt_buf.k (an ffi header set copies this
        // invocation) and from Lib/rt/fmt_*.c (native_invocation shares these
        // arguments).
        var rt_root = self._runtime_root();
        if !rt_root.empty() { bcfg.extra_cc1.push_back("-I"); bcfg.extra_cc1.push_back(rt_root); }
        // The env search paths, where clang's driver puts them (Kairo's line
        // is built by hand, so nothing else would): CPATH as -I after every
        // command-line -I, C_INCLUDE_PATH / CPLUS_INCLUDE_PATH as the
        // per-language system groups, which clang searches after -isystem
        // and before -idirafter -- the sysroot's headers still win. Not in a
        // hermetic build, and not on a C/C++ input's driver line, where
        // clang's driver adds them itself (ClangJobs drops them when
        // hermetic).
        (bcfg.strip_env) = tgt.host_mode.empty();
        if !tgt.host_mode.empty() {
            for d: string in HostSystem::env_list("CPATH")              { bcfg.extra_cc1.push_back("-I");           bcfg.extra_cc1.push_back(d); }
            for d: string in HostSystem::env_list("C_INCLUDE_PATH")     { bcfg.extra_cc1.push_back("-c-isystem");   bcfg.extra_cc1.push_back(d); }
            for d: string in HostSystem::env_list("CPLUS_INCLUDE_PATH") { bcfg.extra_cc1.push_back("-cxx-isystem"); bcfg.extra_cc1.push_back(d); }
        }
        // The two header-search roots, exactly as given: no discovery. With
        // neither, clang searches no system headers at all (see the model in
        // ClangBackend::_startup_locked), which is the honest answer.
        (bcfg.sysroot)      = tgt.sysroot;
        (bcfg.resource_dir) = tgt.resource_dir;
        self._sysroot_header_roots(bcfg);
        // The host's system headers. Default ("floor"): after every sysroot
        // root, as -idirafter, so <stdio.h> is always the floor's and only a
        // header it lacks (zlib.h, curl/curl.h) is the host's. --native:
        // clang's native order -- the bundled libc++, the builtins, then the
        // host's dirs as the C library's -- with no sysroot at all.
        if tgt.host_mode == "floor" {
            for d: string in tgt.host_include_dirs { bcfg.after_dirs.push_back(d); }
        } else if tgt.host_mode == "native" {
            (bcfg.sysroot) = "";
            bcfg.cxx_include_dirs.clear();
            bcfg.include_dirs.clear();
            bcfg.defines.clear();
            if !tgt.native_bundle.empty() {
                var nb = ClangBackendConfig{};
                (nb.triple)  = bcfg.triple;
                (nb.sysroot) = tgt.native_bundle;
                self._sysroot_header_roots(nb);
                for d: string in nb.cxx_include_dirs { bcfg.cxx_include_dirs.push_back(d); }
                for d: string in nb.defines          { bcfg.defines.push_back(d); }
            } else if LinkFS::is_dir("/usr/include/c++/v1") {
                bcfg.cxx_include_dirs.push_back("/usr/include/c++/v1");
            }
            for d: string in tgt.host_include_dirs { bcfg.include_dirs.push_back(d); }
        }
        // One optimization level for the whole build: ClangBackend applies
        // it to the invocation every compile copies.
        var cgo = self.invocation().codegen;
        (bcfg.opt_level) = cgo.opt_level;
        if cgo.opt_size_z    { (bcfg.opt_size) = 2; }
        else if cgo.opt_size { (bcfg.opt_size) = 1; }
        (bcfg.vectorize) = cgo.f_vectorize != 0;
        // -g0 wins over -g wherever it sits. --dwarf-version always has a
        // value (default 5), so it cannot say whether DWARF was asked for;
        // on MSVC it is left out and the driver emits CodeView, which is
        // what link.exe-style PDBs need.
        (bcfg.debug_info)   = FlagTranslator::debug_on(cgo);
        (bcfg.debug_macros) = cgo.debug_macros;
        (bcfg.embed_source) = cgo.embed_source;
        (bcfg.dwarf_version) = FlagTranslator::dwarf_for(cgo, bcfg.triple);
        return bcfg;
    }

    /// Applies the two process-level input flags, before initialize() reads
    /// the current directory: --working-dir (every relative path in the run,
    /// source files included, resolves against it) and --input-encoding (the
    /// lexer only reads UTF-8, so any other value would be silently
    /// mis-decoded rather than honoured).
    ///
    /// \return false after reporting; the caller must stop.
    fn apply_input_options(self) -> bool {
        var enc = self.invocation().input_encoding;
        var is_utf8 = enc.empty() || (enc == "utf-8") || (enc == "UTF-8") || (enc == "utf8") || (enc == "UTF8");
        if !is_utf8 {
            self._diag->report(DiagID::U001E,
                f"--input-encoding={enc}: only utf-8 input is supported").emit();
            return false;
        }

        var wd = self.invocation().working_dir;
        if wd.empty() { return true; }

        if !Path::set_cwd(wd) {
            self._diag->report(DiagID::U001E,
                f"--working-dir: cannot change to '{wd}\x27: no such directory").emit();
            return false;
        }
        return true;
    }

    fn initialize(self, cwd: Path) {
        self._report_root_warnings();
        {
            var _t = TimeRegion("ImportIndex");
            var rb = ImportResolver::Builder().cwd(cwd);
            for dir: string in self.invocation().include_dirs { self._add_root(rb, dir); }
            for dir: string in self.invocation().macro_paths  { self._add_root(rb, dir); }

            // The builtin root, registered under the NAME `builtin` so every
            // module beneath it carries that leading segment -- the lang-item
            // fill addresses decls by qualified path, and an unnamed root would
            // give them the directory's basename instead.
            //
            // --builtins-dir wins; otherwise <resource-dir>/builtin. With
            // neither there is no builtin root at all, the prelude resolves to
            // nothing, and the lang items stay unbound -- which is diagnosed at
            // USE by whichever pass needs one, never here.
            var broot = self.invocation().pp.builtins_dir;
            if broot.empty() && (!self.invocation().target.resource_dir.empty()) {
                broot = (Path(self.invocation().target.resource_dir) / "builtin").full_path();
            }
            if !broot.empty() { rb.add_include(Path(broot), builtin_root_name()); }

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
            if !self.invocation().pp.no_stdlib {
                var sroot = self.invocation().pp.std_dir;
                if sroot.empty() && (!self.invocation().target.resource_dir.empty()) {
                    sroot = (Path(self.invocation().target.resource_dir) / "std").full_path();
                }
                if !sroot.empty() { rb.add_include(Path(sroot), std_root_name(), std_root_spelling()); }
            }

            self._imp = rb.create_ptr(self._pool);
            self._report_root_collisions();
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
        var bcfg = self._backend_config();

        self._backend = std::create::<ClangBackend>(self._sm, bcfg);

        var be  = self._backend;
        var rec = kairo::TimeReport::region(r"ClangStartup");
        self._pool->enqueue(fn () |be, rec| {
            var _kt = kairo::TimeReport::Worker(rec);
            be->startup();
        }, CLANG_STARTUP_GROUP());

        // C++ header import. Parse on the pool (HeaderSetCache), index on the
        // driver (HeaderIndex writes the SM, the TCM and the global table),
        // one USR -> decl identity for the build (ForeignRegistry).
        self._headers = std::create::<HeaderSetCache>(self._backend, self._pool);
        self._freg    = std::create::<ForeignRegistry>();
        // `T?` crosses into and out of a header as `::builtin::Nullable<T>`
        // (TypeExport / TypeImport): both ask the registry for the lang item.
        self._freg->well_known = self._g_scope->well_known();
        self._hindex  = std::create::<HeaderIndex>(self._sm, self._tcm, self._diag, self._imp,
                                                   &self.invocation(), self._g_scope, self._freg);
        self._finst   = std::create::<ForeignInstantiate>(self._hindex, self._freg, self._g_scope->instances());
        self._builtins = std::create::<BuiltinImport>();   // init()ed on the driver, after header indexing.

        self._pp = std::create::<PreProcessor>(
            self._sm, self._tcm, self._imp, self._pool,
            self._diag, self._g_scope, &self.invocation(), self.invocation().pp, self._headers);
        self._finst->psym = self._pp->get_symbol_table();
        // Panic<i32, B, A> IS Panic<i32, A, B> wherever a type is formed
        // (PANIC.md §1.3): one stateless orderer for the build's type store
        // and registry, before any Sema pass forms one.
        self._ptids = std::create::<PanicTypeIds>(self._finst->psym, self._g_scope->well_known(), self.invocation().lang.test_panic_id_bits);
        self._ptids->size_types(self.invocation().target.pointer_width, self.invocation().target.usize_is_fixed, self.invocation().target.isize_is_fixed);
        self._g_scope->types()->pack_order     = static_cast::<*PackSetOrder>(self._ptids);
        self._g_scope->instances()->pack_order = static_cast::<*PackSetOrder>(self._ptids);
    }

    /// Compiles all input files described by the invocation.
    ///
    /// Builds an \c ImportResolver from the search paths in the invocation,
    /// then runs a \c FrontendAction for each input file. A fatal diagnostic
    /// in any file sets \c BatchResult::aborted and skips remaining files.
    /// Results are collected into the returned \c BatchResult.

    /// \brief the runtime's C/C++ sources (Lib/rt), when Kairo objects were
    ///        emitted, into <dir>/kairo/<stem>.o beside kairo/std.o.
    ///
    /// \details On the hand-built cc1 line (ClangBackend::native_invocation and run_native),
    ///          not clang's driver: the runtime is Kairo's own code and is
    ///          built exactly as Kairo's TUs are (int128, no finite loops,
    ///          Kairo's exception model). Runtime objects never take -o.
    ///
    ///          Each object is taken from the toolchain's runtime cache
    ///          (_rt_cache_dir) when an entry for its exact cc1 line and
    ///          inputs is there, and stored into it after a compile: without
    ///          it every link rebuilt mimalloc at -O2, 1.6 s of a 2 s
    ///          trivial program. Copied in and out rather than linked from
    ///          the cache, so a link never holds a file another run may
    ///          replace or collect, and --kairo-lib's private build
    ///          directory still holds its own objects.
    /// \brief compiles the runtime's C sources (Lib/rt) to objects, for the
    ///        link: _start_runtime unless it already ran, then _finish_runtime.
    ///
    /// \details The runtime depends on no Kairo source, so the batch starts it
    ///          as soon as the first action reaches Sema (prestart_runtime),
    ///          on pool threads that the serial Sema leaves idle, instead of
    ///          after codegen, where a cache miss (every first link after a
    ///          compiler rebuild) put ~4 s of -O2 compiles on the critical
    ///          path (P380). The objects, logs and cache stores are the same.
    priv fn _compile_runtime(self) -> bool {
        if !self._rt_started {
            if !self._start_runtime() { return false; }
        }
        return self._finish_runtime();
    }

    /// The batch's early start (FrontendAction::_sema): only when this run
    /// will compile the runtime at all -- the same test as the batch's call.
    fn prestart_runtime(self) {
        if self._rt_started || self._rt_prestart_tried { return; }
        self._rt_prestart_tried = true;
        var fe_rt = &(self.invocation().frontend);
        if (self._kairo_inputs == 0) || fe_rt->stops_before_codegen() || (!fe_rt->emit_obj)
           || self.invocation().linker.inputs_only() || self._link_out.empty() { return; }
        if !self._start_runtime() { self._rt_started = false; }
    }

    /// Joins an early start the batch then did not use (an error stopped it
    /// before the link): the tasks write into members, so they must finish.
    priv fn _join_runtime(self) {
        if !self._rt_started { return; }
        self._pool->wait_group(NATIVE_GROUP());
    }

    priv fn _start_runtime(self) -> bool {
        self._rt_invs.clear(); self._rt_objs.clear(); self._rt_logs.clear();
        self._rt_oks.clear();  self._rt_ents.clear();
        self._rt_cache = "";
        self._rt_started = true;
        var runtime = self._runtime_sources();
        if runtime.size() == 0 { return true; }
        if self._backend == &null {
            self._rt_started = false;
            self._diag->report(DiagID::I004F, "cannot compile the runtime: no clang backend").emit();
            return false;
        }
        var dir = self.object_dir();
        var n   = runtime.size();
        // The vendored mimalloc's headers, for rt/mimalloc.c alone: rt/alloc.h
        // declares the mi_* entry points it calls itself, so neither Kairo
        // TUs nor the user's C/C++ see mimalloc's include/ (its mimalloc.h
        // would shadow a user's own copy).
        var extra = vec::<string>();
        extra.push_back("-I");
        extra.push_back(Path::join_str(self._runtime_root(), "rt/mimalloc/include"));

        // Side by side on the pool: each file is its own CompilerInstance
        // (ClangBackend::run_native) printing into its own log. The
        // invocations are built here first, because their argv bytes and
        // the arg-parse engine are the backend's; the logs, objects and
        // verdict are read back in input order, so the output is the
        // serial loop's whatever finishes first.

        var cache = self._rt_cache_dir();
        if (!cache.empty()) && (!LinkFS::make_dirs(cache)) { cache = ""; }
        self._rt_cache = cache;
        var fp = "";
        if !cache.empty() { fp = string(llvm::utohexstr(llvm::xxh3_64bits(sref(self._rt_fingerprint())))); }
        var force = self.invocation().frontend.force_recompile;
        var exe = std::get_exe_path();
        var none = libcxx::shared_ptr::<clang::CompilerInvocation>();

        for src: InputKind in runtime {
            var stem = Path(src.path).stem();
            var obj = dir + "/kairo/" + stem + ".o";
            Path::make_parent_dirs(obj);
            var key = "";
            var inv = self._backend->native_invocation(src.path, obj, src.type_name(), src.is_c_family_c(), extra, &key);
            var entry = "";
            var hit = false;
            if (!cache.empty()) && (inv.get() != &null) {
                // <stem>-<slot>-<inputs>.o: the slot is the compiler and the
                // cc1 line, the second hash every file the object is built
                // from. A store replaces its slot's older entries, so a
                // compiler rebuild or a Lib/rt edit replaces the entry
                // rather than adding one per build.
                var slot = string(llvm::utohexstr(llvm::xxh3_64bits(sref(exe + "\n" + key))));
                entry = cache + "/" + stem + "-" + slot + "-" + fp + ".o";
                if force {
                    Logger::info(Logger::Stage::Driver, f"runtime cache bypassed (--force-recompile): {entry}");
                } else if CompilerInstance::_rt_cache_fetch(entry, obj) {
                    Logger::info(Logger::Stage::Driver, f"runtime cache hit: {entry}");
                    hit = true;
                } else {
                    Logger::info(Logger::Stage::Driver, f"runtime cache miss: {entry}");
                }
            }
            if hit {
                self._rt_invs.push_back(none);
                self._rt_ents.push_back("");
                self._rt_oks.push_back(u8(1));
            } else {
                self._rt_invs.push_back(inv);
                self._rt_ents.push_back(entry);
                self._rt_oks.push_back(u8(0));
            }
            self._rt_objs.push_back(obj);
            self._rt_logs.push_back("");
        }
        var be     = self._backend;
        var inv_p  = self._rt_invs.data();
        var log_p  = self._rt_logs.data();
        var ok_p   = self._rt_oks.data();
        var rec    = kairo::TimeReport::current();
        for var i: usize = 0; i < n; ++i {
            if inv_p[i].get() == &null { continue; }
            self._pool->enqueue(fn () |be, inv_p, log_p, ok_p, i, rec| {
                var _kt = kairo::TimeReport::Worker(rec);
                if be->run_native(inv_p[i], &(log_p[i])) { ok_p[i] = u8(1); }
            }, NATIVE_GROUP());
        }
        return true;
    }

    priv fn _finish_runtime(self) -> bool {
        if !self._rt_started { return true; }
        self._rt_started = false;
        self._pool->wait_group(NATIVE_GROUP());
        var n = self._rt_objs.size();
        var ok = true;
        var stored = false;
        for var i: usize = 0; i < n; ++i {
            if !self._rt_logs[i].empty() { std::eprint(self._rt_logs[i]); }
            if self._rt_oks[i] == u8(0) { ok = false; continue; }
            if !self._rt_ents[i].empty() { stored = CompilerInstance::_rt_cache_store(self._rt_objs[i], self._rt_ents[i]) || stored; }
            self._native_objs.push_back(self._rt_objs[i]);
            Logger::info(Logger::Stage::Driver, f"emitted object {self._rt_objs[i]}");
        }
        if stored { CompilerInstance::_rt_cache_gc(self._rt_cache); }
        return ok;
    }

    // --- The runtime object cache ----------------------------------------

    /// \brief where _compile_runtime caches the runtime's objects:
    ///        <cache root>/rt (_cache_root), shared by every link of every
    ///        target and option set; "" when there is no cache root.
    priv fn _rt_cache_dir(self) -> string {
        if self._backend == &null { return ""; }
        var root = CompilerInstance::_cache_root();
        if root.empty() { return ""; }
        return root + "/rt";
    }

    /// `<path> <size> <mtime>` for one file, or `<path> -` when it cannot
    /// be stat'd (a file that appears later then changes the key too).
    priv static fn _rt_stamp(p: string) -> string {
        var st: llvm::sys::fs::file_status;
        var ec = llvm::sys::fs::status(llvm::Twine(sref(p)), st, true);
        if ec { return p + " -\n"; }
        var size  = static_cast::<u64>(st.getSize());
        var mtime = static_cast::<u64>(st.getLastModificationTime().time_since_epoch().count());
        return f"{p} {size} {mtime}\n";
    }

    /// \brief every file a runtime object may be built from, stamped: the
    ///        compiler (clang is linked into it, and it stages the sysroot
    ///        and resource dir beside itself), every file directly in
    ///        <runtime root>/rt (sources and the headers they share), and
    ///        the vendored mimalloc (_runtime_deps: a submodule bump never
    ///        touches rt/mimalloc.c).
    ///
    /// \details One set for all of the runtime's objects, not each one's own
    ///          includes: any change rebuilds all of them, which costs only
    ///          the first link after it, and no include an object reads can
    ///          be left out of its key. Sorted, so the key does not follow
    ///          readdir.
    priv fn _rt_fingerprint(self) -> string {
        var out = CompilerInstance::_rt_stamp(std::get_exe_path());
        var rroot = self._runtime_root();
        if rroot.empty() { return out; }
        var rt = Path::join_str(rroot, "rt");
        var files = vec::<string>();
        for name: string in LinkFS::list_dir(rt) {
            var p = rt + "/" + name;
            if LinkFS::is_file(p) { files.push_back(p); }
        }
        llvm::sort(files.begin(), files.end(),
            fn (const a: ref!(string), const b: ref!(string)) || -> bool = a < b);
        for p: string in files { out += CompilerInstance::_rt_stamp(p); }
        for p: string in self._runtime_deps() { out += CompilerInstance::_rt_stamp(p); }
        return out;
    }

    /// \brief copies the cache entry \p entry to \p obj; false (compile it)
    ///        when there is none or it does not read as an object file.
    ///
    /// \details Entries are only ever renamed into place whole
    ///          (_rt_cache_store), so a partial write is never seen; the
    ///          parse guards against what else can damage a file in a cache
    ///          directory (a full disk, a crash of the file system, a hand
    ///          edit), which would otherwise fail the link instead of
    ///          rebuilding the object.
    priv static fn _rt_cache_fetch(entry: string, obj: string) -> bool {
        if !LinkFS::is_file(entry) { return false; }
        {
            var o = llvm::object::ObjectFile::createObjectFile(sref(entry));
            if !o {
                llvm::consumeError(o.takeError());
                return false;
            }
        }
        var ec = llvm::sys::fs::copy_file(llvm::Twine(sref(entry)), llvm::Twine(sref(obj)));
        if ec {
            LinkFS::remove(obj);
            return false;
        }
        return true;
    }

    /// \brief stores the object \p obj as the cache entry \p entry: copied to
    ///        a private name and renamed into place, so a parallel link reads
    ///        the whole object or none; two runs that both missed write the
    ///        same bytes and the last rename wins. Then the slot's older
    ///        entries (`<stem>-<slot>-*.o`, other inputs) are removed.
    ///
    /// \return true when the entry was written.
    priv static fn _rt_cache_store(obj: string, entry: string) -> bool {
        var tmp = f"{entry}.tmp-{llvm::sys::Process::getProcessId()}";
        var ec = llvm::sys::fs::copy_file(llvm::Twine(sref(obj)), llvm::Twine(sref(tmp)));
        if ec {
            LinkFS::remove(tmp);
            return false;
        }
        if !LinkFS::rename(tmp, entry) {
            LinkFS::remove(tmp);
            return false;
        }
        var dir  = LinkFS::parent(entry);
        var name = LinkFS::filename(entry);
        // Through the last '-': <stem>-<slot>-. A stem may itself hold
        // '-', the two hashes never do.
        var cut = name.size();
        var found = false;
        while cut > 0 {
            cut -= 1;
            if name[cut] == '-' { found = true; break; }
        }
        if !found { return true; }
        var prefix = string(name.raw(), cut + 1);
        for other: string in LinkFS::list_dir(dir) {
            if (other == name) || (!other.starts_with(prefix)) || (!other.ends_with(".o")) { continue; }
            // Only <prefix><hash>.o; the slot hash already separates stems
            // that share a prefix, this is belt and braces.
            var rest = string(other.raw() + prefix.size(), other.size() - prefix.size());
            if !(string::npos == rest.view().find(r"-")) { continue; }
            LinkFS::remove(dir + "/" + other);
        }
        return true;
    }

    /// \brief removes the runtime cache's entries no store has refreshed for
    ///        30 days (a target or option set no longer used) and private
    ///        copies a crashed store left (a day old). Run after a store,
    ///        which is rare; a hit lists nothing.
    priv static fn _rt_cache_gc(dir: string) {
        if dir.empty() { return; }
        var now = static_cast::<u64>(libcxx::chrono::duration_cast::<libcxx::chrono::nanoseconds>(
            libcxx::chrono::system_clock::now().time_since_epoch()).count());
        var day: u64 = static_cast::<u64>(86400) * static_cast::<u64>(1000000000);   // ns
        for name: string in LinkFS::list_dir(dir) {
            var p = dir + "/" + name;
            if !LinkFS::is_file(p) { continue; }
            var partial = !(string::npos == name.view().find(r".tmp-"));
            var last = LinkFS::mtime(p);
            var limit = (day) if (partial) else (30 * day);
            if (last != 0) && (now > last) && ((now - last) > limit) { LinkFS::remove(p); }
        }
    }

    /// \brief the clang driver words for one C/C++ input, without the
    ///        action and the input/output: the backend's roots, everything
    ///        FlagTranslator::to_driver spells for this invocation (ending in
    ///        --cxx-flags, so those win), then the runtime root.
    priv fn _native_words(self, k: InputKind) -> vec::<string> {
        return self._native_words_for(self._backend, k);
    }

    /// _native_words against a given backend: --print-clang-args builds a
    /// throwaway one, the compile uses the build's.
    priv fn _native_words_for(self, be: *ClangBackend, k: InputKind) -> vec::<string> {
        var w = vec::<string>();
        // IR and already-preprocessed input search no headers: the roots would
        // only draw clang's "argument unused" warning, once per root.
        if k.needs_headers() {
            w = be->sysroot_words(k.is_c_family_c(), ClangSpelling::Driver);
        }
        // Plugins that do not exist were reported when the backend's
        // configuration was built; here they are only left out.
        var missing = vec::<string>();
        for a: string in FlagTranslator::to_driver(self.invocation(), be->triple(), k.type_name(), &missing) {
            w.push_back(a);
        }
        // `rt/fmt.h` resolves for a C/C++ input exactly as for Lib/rt, and
        // the runtime root comes AFTER the user's -I, as on the cc1 line
        // (_backend_config): a quoted include that exists under both Lib
        // and a user -I dir names the user's file in both clang lines and
        // in the `#include "x.k"` scan (clang_include_dirs). -I is not
        // last-wins, so following --cxx-flags takes nothing from them.
        if k.needs_headers() {
            var rt_root = self._runtime_root();
            if !rt_root.empty() { w.push_back("-I"); w.push_back(rt_root); }
        }
        return w;
    }

    priv fn _native_jobs(self) -> *ClangJobs {
        if self._jobs == &null {
            var exe = Path::join_str(Path::parent_of(std::get_exe_path()), "clang");
            self._jobs = std::create::<ClangJobs>(self._backend, exe);
            self._kincludes = std::create::<DriverIncludeSource>(
                self._sm, self._g_scope, (self._pp->get_symbol_table()) if (self._pp != &null) else (&null),
                (!self.invocation().frontend.stops_at_parse()) || self.kairo_feeds_includes());
            self._jobs->includes = self._kincludes;
        }
        return self._jobs;
    }

    /// One driver run for one input; a failure clang did not explain itself
    /// (an external tool, an empty plan) is reported here.
    priv fn _run_native(self, k: InputKind, words: ref!(vec::<string>)) -> bool {
        var jobs = self._native_jobs();
        var ok = jobs->run(words);
        jobs->diags.drain_into(self._diag, self._sm);
        if ok { return true; }
        if !jobs->error.empty() {
            self._diag->report(DiagID::U001E, f"{k.path}: {jobs->error}").emit();
        }
        return false;
    }

    /// \brief compiles the command line's C, C++, Objective-C and IR inputs
    ///        through clang's driver, for the run's action:
    ///
    ///          --preprocess       -E, to -o or stdout
    ///          --syntax-only,
    ///          --type-check-only  -fsyntax-only (C++ has no separate stage)
    ///          otherwise          each --emit kind: <dir>/<stem>.o .s .ll .bc
    ///                             (-c / -S / -S -emit-llvm / -c -emit-llvm);
    ///                             the .o files join the link.
    ///
    ///        -o names the output only when it is the build's one output.
    priv fn _compile_sources(self, natives: ref!(vec::<InputKind>)) -> bool {
        if natives.size() == 0 { return true; }
        if self._backend == &null {
            self._diag->report(DiagID::I004F, "cannot compile C/C++ sources: no clang backend").emit();
            return false;
        }
        var fe = &(self.invocation().frontend);
        var single = self.single_object();

        if fe->stops_at_preprocess() || fe->stops_at_sema() {
            var pp = fe->stops_at_preprocess();
            var ok = true;
            for k: InputKind in natives {
                // An input with no such phase is skipped with a warning, as
                // clang does (-E: input unused): IR and .i/.ii for -E, IR for
                // -fsyntax-only.
                var skip = (pp && (!k.needs_headers())) || ((!pp) && k.is_ir());
                if skip {
                    var what = ("--preprocess") if (pp) else ("a check-only run");
                    self._diag->report(DiagID::U001W, f"{k.path}: nothing to do for this input under {what}").emit();
                    continue;
                }
                var w = self._native_words(k);
                w.push_back(("-E") if (pp) else ("-fsyntax-only"));
                if pp && (!single.empty()) {
                    if natives.size() != 1 {
                        self._diag->report(DiagID::I004F,
                            f"-o {single} names one output, but this build preprocesses {natives.size()} inputs").emit();
                        return false;
                    }
                    w.push_back("-o"); w.push_back(single);
                }
                w.push_back("-x"); w.push_back(k.type_name()); w.push_back(k.path);
                ok = self._run_native(k, w) && ok;
            }
            return ok;
        }

        // What each input writes (--emit), the same kinds and extensions a
        // Kairo TU writes, one driver run each.
        var kinds = vec::<EmitKind>();
        var exts  = vec::<string>();
        if fe->emit_obj     { kinds.push_back(EmitKind::Obj);    exts.push_back(".o");  }
        if fe->emit_asm     { kinds.push_back(EmitKind::Asm);    exts.push_back(".s");  }
        if fe->emit_llvm_ir { kinds.push_back(EmitKind::LLVMIR); exts.push_back(".ll"); }
        if fe->emit_llvm_bc { kinds.push_back(EmitKind::LLVMBC); exts.push_back(".bc"); }

        // A header writes one .pch whatever --emit says.
        var n_out = self.kairo_input_count() * kinds.size() + self._header_inputs;
        if (!single.empty()) && (n_out > 1) {
            self._diag->report(DiagID::I004F,
                f"-o {single} names one output, but this build emits {n_out}; use --cache-dir <dir> for them").emit();
            return false;
        }
        var dir = self.object_dir();

        var ok = true;
        for k: InputKind in natives {
            if k.cls == InputClass::Header {
                // clang's own answer to a header input: a precompiled header,
                // named after the whole file (foo.h -> foo.h.pch) so foo.h
                // and foo.c never collide. Never linked.
                var pch = single;
                // A linking run's object dir may be a temporary one it
                // deletes; the .pch is an output the user asked for, so it is
                // kept: --cache-dir if given, else the working directory.
                var pdir = dir;
                if self._obj_tmp { pdir = "."; }
                if pch.empty() { pch = pdir + "/" + Path(k.path).filename() + ".pch"; }
                Path::make_parent_dirs(pch);
                var hw = self._native_words(k);
                hw.push_back("-c");
                hw.push_back("-x"); hw.push_back(k.type_name()); hw.push_back(k.path);
                hw.push_back("-o"); hw.push_back(pch);
                ok = self._run_native(k, hw) && ok;
                continue;
            }
            for var i: usize = 0; i < kinds.size(); ++i {
                var out = single;
                if out.empty() { out = dir + "/" + Path(k.path).stem() + exts[i]; }
                Path::make_parent_dirs(out);
                var w = self._native_words(k);
                var kind = kinds[i];
                if kind == EmitKind::Asm         { w.push_back("-S"); }
                else if kind == EmitKind::LLVMIR { w.push_back("-S"); w.push_back("-emit-llvm"); }
                else if kind == EmitKind::LLVMBC { w.push_back("-c"); w.push_back("-emit-llvm"); }
                else                             { w.push_back("-c"); }
                w.push_back("-x"); w.push_back(k.type_name()); w.push_back(k.path);
                w.push_back("-o"); w.push_back(out);
                var one = self._run_native(k, w);
                ok = one && ok;
                if one && (kind == EmitKind::Obj) {
                    self._native_objs.push_back(out);
                    Logger::info(Logger::Stage::Driver, f"emitted object {out}");
                }
            }
        }
        return ok;
    }

    /// \brief the directory the runtime is included and compiled from: the
    ///        builtin root's parent -- Lib/ in the tree, <resource-dir>
    ///        installed -- so `rt/fmt.h` names Lib/rt/fmt.h from anywhere. The
    ///        builtin root is found as the import resolver finds it:
    ///        --builtins-dir, else <resource-dir>/builtin. "" when none.
    priv fn _runtime_root(self) -> string {
        var broot = self.invocation().pp.builtins_dir;
        if broot.empty() && (!self.invocation().target.resource_dir.empty()) {
            broot = (Path(self.invocation().target.resource_dir) / "builtin").full_path();
        }
        if broot.empty() { return ""; }
        // A trailing '/' would make parent_path answer "a/builtin" for
        // "a/builtin/"; strip it so both spellings name Lib/.
        return Path::parent_of(LinkText::strip_slash(broot));
    }

    /// \brief the runtime's C/C++ sources: every one directly in
    ///        <runtime root>/rt. No root, no runtime. Sorted, so object
    ///        order does not follow readdir.
    priv fn _runtime_sources(self) -> vec::<InputKind> {
        var out = vec::<InputKind>();
        var rroot = self._runtime_root();
        if rroot.empty() { return out; }
        var root = Path::join_str(rroot, "rt");
        var ec: libcxx::error_code;
        var it  = llvm::sys::fs::directory_iterator(llvm::Twine(sref(root)), ec, true);
        var end = llvm::sys::fs::directory_iterator();

        for (; (!ec) && (it != end); it.increment(ec)) {
            if Path::type_of_entry(*it) != FileType::regular_file { continue; }
            var p = it->path();
            // The same classifier as a command-line input: rt holds C and
            // C++ only, and a stray header or README must not compile.
            var k = classify_input(string(p.data(), p.size()), "");
            if k.cls == InputClass::Source { out.push_back(k); }
        }

        llvm::sort(out.begin(), out.end(),
            fn (const a: ref!(InputKind), const b: ref!(InputKind)) || -> bool = a.path < b.path);
        return out;
    }

    /// \brief every file the runtime's sources include from the vendored
    ///        mimalloc (<runtime root>/rt/mimalloc/{src,include}, recursive),
    ///        for the library manifest.
    ///
    /// \details rt/mimalloc.c is one line of #include into the submodule:
    ///          a submodule bump changes these and never mimalloc.c, so a
    ///          manifest of _runtime_sources() alone would keep a cached
    ///          runtime object built from the old mimalloc. Sorted, so the
    ///          manifest does not follow readdir.
    priv fn _runtime_deps(self) -> vec::<string> {
        var out = vec::<string>();
        var rroot = self._runtime_root();
        if rroot.empty() { return out; }
        var subs = vec::<string>();
        subs.push_back("rt/mimalloc/src");
        subs.push_back("rt/mimalloc/include");
        for sub: string in subs {
            var root = Path::join_str(rroot, sub);
            var ec: libcxx::error_code;
            var it  = llvm::sys::fs::recursive_directory_iterator(llvm::Twine(sref(root)), ec, true);
            var end = llvm::sys::fs::recursive_directory_iterator();
            for (; (!ec) && (it != end); it.increment(ec)) {
                if Path::type_of_entry(*it) != FileType::regular_file { continue; }
                var p = it->path();
                out.push_back(string(p.data(), p.size()));
            }
        }
        llvm::sort(out.begin(), out.end(),
            fn (const a: ref!(string), const b: ref!(string)) || -> bool = a < b);
        return out;
    }

    priv static fn _parent_dir(path: string) -> string {
        return Path::parent_of(path);
    }

    // --- Linking ---------------------------------------------------------

    /// \brief decides once per batch what -o names and where objects go.
    ///
    /// \details -o is always ONE output file: the executable or library when
    ///          this run links, the single object under -c. Objects go to
    ///          --cache-dir (kept); without it, a linking run uses a temp dir
    ///          it removes afterwards (`<output>.kobj` under --save-temps),
    ///          and a -c run uses the working directory. -o naming a
    ///          directory is an error: that is --cache-dir's job.
    ///
    /// \return false on a fatal planning error; nothing may compile.
    priv fn _plan_outputs(self) -> bool {
        var lk  = &(self.invocation().linker);
        var out = self.invocation().frontend.output;
        self._link_out = "";
        self._obj_dir  = lk->cache_dir;
        self._obj_tmp  = false;
        self._emit_beside = false;
        self._obj_listed  = true;

        // Classified and counted here, before any TU runs: -o under -c names
        // the one USER translation unit, and codegen of the first input must
        // already know whether a second one is coming. An input nothing can
        // build stops the run before anything compiles, every one reported.
        self._kairo_inputs = 0;
        self._inputs.clear();
        var bad = false;
        var n_in = self.invocation().input_files.size();
        for var i: usize = 0; i < n_in; ++i {
            var path_str = self.invocation().input_files[i];
            var k = classify_input(path_str, self.invocation().input_lang(i));
            if (k.cls == InputClass::Unsupported) || (k.cls == InputClass::Unknown) || (k.cls == InputClass::BadLanguage) {
                self._diag->report(DiagID::U001E, f"{path_str}: {k.why}").emit();
                bad = true;
            }
            if k.cls == InputClass::Kairo  { self._kairo_inputs += 1; }
            if k.cls == InputClass::Source { self._source_inputs += 1; }
            if k.cls == InputClass::Header { self._header_inputs += 1; }
            self._inputs.push_back(k);
        }
        if bad { return false; }

        // A C/C++ input's outputs are named <dir>/<stem>.<ext>, and a
        // header's <dir>/<file>.pch. Two inputs that name one output would
        // write one file; clang silently overwrites, this says so (a
        // deliberate deviation). A Kairo entry TU of the same stem is no
        // clash: it writes <stem>.k.<ext> instead (kairo_object_stem), which
        // is the common case of a foo.cc that includes foo.k. Only for runs that write
        // files: --preprocess goes to stdout, the check-only runs write none.
        var fe_plan = &(self.invocation().frontend);
        if !fe_plan->stops_before_codegen() {
            for var a: usize = 0; a < self._inputs.size(); ++a {
                var ka = self._inputs[a];
                var a_hdr = ka.cls == InputClass::Header;
                if (ka.cls != InputClass::Source) && (!a_hdr) { continue; }
                var na = (Path(ka.path).filename()) if (a_hdr) else (Path(ka.path).stem());
                for var b: usize = 0; b < self._inputs.size(); ++b {
                    if b == a { continue; }
                    var kb = self._inputs[b];
                    var b_hdr = kb.cls == InputClass::Header;
                    var nb = "";
                    if a_hdr {
                        if !b_hdr { continue; }
                        nb = Path(kb.path).filename();
                    } else {
                        if kb.cls != InputClass::Source { continue; }
                        nb = Path(kb.path).stem();
                    }
                    if nb != na { continue; }
                    if b < a { continue; }  // reported once
                    self._diag->report(DiagID::U001E,
                        f"{ka.path} and {kb.path} both write '{na}\x27 outputs; rename one, or compile them in separate runs").emit();
                    bad = true;
                }
            }
        }
        if bad { return false; }

        if (!out.empty()) && (LinkText::ends_with(out, "/") || LinkFS::is_dir(out)) {
            self._diag->report(DiagID::I004F,
                f"-o {out} is a directory; -o names the output file, and object files go to --cache-dir <dir>").emit();
            return false;
        }

        if (lk->emit_scope != "graph") && (lk->emit_scope != "inputs") {
            self._diag->report(DiagID::U003E,
                f"invalid --emit-scope value '{lk->emit_scope}'; accepted: graph, inputs").emit();
            return false;
        }

        // --emit: an item that is no kind at all is an error naming the set;
        // one the flag accepts but codegen does not produce yet is an error
        // too, rather than a run that silently writes nothing for it.
        var fe = &(self.invocation().frontend);
        for it: string in fe->emit_unknown {
            self._diag->report(DiagID::U003E,
                f"invalid --emit value '{it}'; accepted: obj, asm, llvm-ir, llvm-bc").emit();
        }
        for it: string in fe->emit_unsupported {
            self._diag->report(DiagID::U003E,
                f"--emit={it} is not implemented yet; implemented: obj, asm, llvm-ir, llvm-bc").emit();
        }
        if (fe->emit_unknown.size() > 0) || (fe->emit_unsupported.size() > 0) { return false; }

        // Nothing to link unless an input makes an object or is one: a build
        // of headers alone writes their .pch files and stops, as under clang,
        // and its -o names that one output.
        var linkable = false;
        for k: InputKind in self._inputs {
            if (k.cls == InputClass::Kairo) || (k.cls == InputClass::Source) || (k.cls == InputClass::LinkInput) {
                linkable = true;
            }
        }
        var links = (!lk->compile_only) && (!self.invocation().frontend.stops_before_codegen()) && linkable;
        if !links {
            if self._obj_dir.empty() { self._obj_dir = "."; }
            // -o names this run's one output. Checked here, once, with every
            // count known: a check inside codegen would already have written
            // the first TU's object to -o before a later input proved there
            // were two. A header writes one .pch whatever --emit says.
            if (!out.empty()) && (!fe->stops_before_codegen()) {
                var n_kinds: usize = 0;
                if fe->emit_obj     { n_kinds += 1; }
                if fe->emit_asm     { n_kinds += 1; }
                if fe->emit_llvm_ir { n_kinds += 1; }
                if fe->emit_llvm_bc { n_kinds += 1; }
                var n_out = (self._kairo_inputs + self._source_inputs) * n_kinds + self._header_inputs;
                if n_out > 1 {
                    self._diag->report(DiagID::I004F,
                        f"-o {out} names one output, but this build emits {n_out}; use --cache-dir <dir> for them").emit();
                    return false;
                }
            }
            return true;
        }

        self._link_out = (out) if (!out.empty()) else ("a.out");
        // `--emit obj,asm -o app` (Linker.k's compile_only): the link needs
        // objects whether or not obj was listed, and the listed kinds are
        // outputs. Under --cache-dir they are kept there with everything
        // else; otherwise the object dir may be a temp one, and the entry
        // TUs write beside the executable instead (emit_beside).
        if fe->emit_asm || fe->emit_llvm_ir || fe->emit_llvm_bc {
            self._obj_listed = fe->emit_obj;
            (fe->emit_obj) = true;
            self._emit_beside = self._obj_dir.empty();
        }
        if !self._obj_dir.empty() { return true; }
        if lk->save_temps {
            self._obj_dir = self._link_out + ".kobj";
            return true;
        }

        self._obj_dir = LinkFS::temp_dir("kairo-obj");
        self._obj_tmp = true;
        if self._obj_dir.empty() {
            self._diag->report(DiagID::L001F, "cannot create a temporary directory for object files").emit();
            return false;
        }
        return true;
    }

    /// Where objects go. Always a directory, always set after _plan_outputs.
    fn object_dir(self) -> string { return self._obj_dir; }

    /// The file -o names when it names an object: a -c run with -o. "" when
    /// this run links (-o is the executable then) or there is no -o. Valid
    /// only if the build emits exactly one object; each emitter checks.
    fn kairo_input_count(self) -> usize { return self._kairo_inputs + self._source_inputs; }
    fn kairo_only_input_count(self) -> usize { return self._kairo_inputs; }

    /// \brief the path, minus its extension, an entry TU of input stem
    ///        \p stem writes its --emit outputs to in a linking run that
    ///        listed more kinds than the object, or "" to use the object dir.
    ///
    /// \details `kairo app.k --emit obj,asm -o out/app` writes out/app.o and
    ///          out/app.s, named after the executable; with several Kairo
    ///          inputs each is named after its own stem, in -o's directory.
    ///          Imported modules and the prelude stay in the object dir:
    ///          they are link inputs, not what the user asked to see.
    fn emit_beside(self, stem: string) -> string {
        if (!self._emit_beside) || self._link_out.empty() { return ""; }
        var dir = Path::parent_of(self._link_out);
        var name = (Path::stem_of(self._link_out)) if (self._kairo_inputs == 1) else (self.kairo_object_stem(stem));
        if dir.empty() { return name; }
        return dir + "/" + name;
    }

    /// False when the objects of an emit_beside run are only link inputs:
    /// --emit did not list obj, so they stay in the object dir, unprinted.
    fn obj_listed(self) -> bool { return self._obj_listed; }

    /// True when this run links and --emit listed kinds beyond the object.
    fn emits_beside_link(self) -> bool {
        var fe = &(self.invocation().frontend);
        return (!self._link_out.empty()) && (fe->emit_asm || fe->emit_llvm_ir || fe->emit_llvm_bc);
    }

    fn single_object(self) -> string {
        if !self._link_out.empty() { return ""; }
        return self.invocation().frontend.output;
    }

    /// kld beside this binary: the out-of-process fallback, used only after
    /// the in-process linker poisons itself or for an -mllvm link.
    priv fn _kld_path(self) -> string {
        var dir = Path::parent_of(std::get_exe_path());
        var exe = "kld";
        if llvm::Triple(llvm::sys::getProcessTriple()).isOSWindows() { exe = "kld.exe"; }
        return dir + "/" + exe;
    }

    /// The second script of a link is an error at its first statement,
    /// with a note at the first script's (TUResult::script_at). One error
    /// per extra script; the first one found in input order is the one the
    /// others are measured against.
    priv fn _reject_second_script(self, result: ref!(BatchResult)) {
        var first: isize = -1;
        for var i: usize = 0; i < result.tu_results.size(); ++i {
            var r = result.tu_results[i];
            if !r.script_at.is_valid() { continue; }
            if first < 0 { first = static_cast::<isize>(i); continue; }
            var p = result.tu_results[static_cast::<usize>(first)];
            var a = Path(p.path).filename();
            var b = Path(r.path).filename();
            var d = self._diag->report(DiagID::SC001E, r.script_at.start,
                f"two script files in one program: '{b}' and '{a}' each run top-level statements as 'main\x27");
            d.first(r.script_at);
            d.note(DiagID::SC001N, p.script_at.start, f"'{a}' is a script: its first top-level statement is here").first(p.script_at);
            d.emit();
        }
    }

    /// Decides, before any file is walked, whether this program's Kairo
    /// files are compiled with __KAIRO_GLOBAL_ALLOCATOR_SET: the builtin's
    /// Global is System inlined without it, and the kairo_global_* symbols
    /// (whatever file set them) with it. Every TU of one program must agree,
    /// the builtin's too, or the ones that inlined System bypass the
    /// program's allocator; so the answer is one bit for the run, settled
    /// here rather than when the setting file is parsed, which may be after
    /// the builtin and earlier inputs were already compiled.
    ///
    /// On with --global-allocator-set or a -D naming the macro (same
    /// meaning), or when a linked object's ABI note says its file set it,
    /// else when a file the inputs reach writes
    /// `@set_global_allocator` at the start of a line (the parser takes it
    /// nowhere else, so a comment or a doc line naming it does not count).
    /// That scan reads the import graph the preprocessor would walk, which is
    /// the whole program under --emit-scope=graph; under inputs (kcc -c) it
    /// is only this run's share, and a file set apart needs the flag -- the
    /// ABI note check at the link catches a build that forgot it.
    priv fn _settle_global_allocator(self) {
        var pp = &(self.invocation().pp);
        var mac = LowerTargets::global_alloc_set_macro();
        var hand = false;
        for d: string in pp->defines { if (d == mac) || LinkText::starts_with(d, mac + "=") { hand = true; } }
        if hand { (pp->global_allocator_set) = true; }
        if (!pp->global_allocator_set) && (self._pp != &null) {
            var nk: usize = 0;
            for k: InputKind in self._inputs {
                if (k.cls == InputClass::LinkInput) || (k.cls == InputClass::Source) || (k.cls == InputClass::Header) { continue; }
                nk += 1;
            }
            // _kairo_order's fid-0 placeholder, which it can only add while
            // nothing is loaded: loading the inputs here first must leave
            // fid 0 where it would have been.
            if (nk >= 2) && (self._sm->file_count() == 0) {
                self._sm->load_virtual(Path(r"<kairo-batch>"),
                    reinterpret_cast::<std::ConstPtr::<u8>>(self._fid0_text.raw()), self._fid0_text.size());
            }
            var checked = llvm::DenseSet::<u64>();
            for k: InputKind in self._inputs {
                if pp->global_allocator_set { break; }
                // An object of a file that set it (its ABI note says so): a
                // link of separately built objects needs the library built
                // with the define as much as a graph build does.
                if k.cls == InputClass::LinkInput {
                    if LinkABI::sets_global_allocator(k.path) { (pp->global_allocator_set) = true; }
                    continue;
                }
                if (k.cls == InputClass::Source) || (k.cls == InputClass::Header) { continue; }
                if CompilerInstance::_file_sets_global_allocator(k.path) { (pp->global_allocator_set) = true; break; }
                // A missing input is its action's error to report, once.
                if !LinkFS::is_file(k.path) { continue; }
                var f = static_cast::<u32>(self._sm->load_file(Path(k.path)));
                if f == u32(-1) { continue; }
                var r = self._pp->reach(f);
                for g in r {
                    // Each file once: inputs share most of their closures,
                    // and re-reading every file per input was quadratic (P373).
                    if checked.contains(static_cast::<u64>(g)) { continue; }
                    checked.insert(static_cast::<u64>(g));
                    if CompilerInstance::_file_sets_global_allocator(self._sm->get_filename(g)) { (pp->global_allocator_set) = true; break; }
                }
            }
        }
        // A -D the user wrote is registered already, by the constructor.
        if pp->global_allocator_set && (!hand) && (self._pp != &null) { self._pp->define_late(mac); }
    }

    /// true when \p path's text has a line starting (after blanks) with
    /// `@set_global_allocator`. An unreadable path (a virtual file) is false.
    priv static fn _file_sets_global_allocator(path: string) -> bool {
        var text = "";
        if !LinkFS::read(path, text) { return false; }
        var pat = "@" + LangAttrs::set_global_allocator();
        var n = text.size();
        var i: usize = 0;
        while i < n {
            while (i < n) && ((text[i] == ' ') || (text[i] == '\t')) { i += 1; }
            var hit = (i + pat.size()) <= n;
            for var j: usize = 0; hit && (j < pat.size()); ++j { if text[i + j] != pat[j] { hit = false; } }
            if hit { return true; }
            while (i < n) && (text[i] != '\n') { i += 1; }
            i += 1;
        }
        return false;
    }

    /// A program has one global allocator: a second file of the link that
    /// writes `@set_global_allocator` is an error at it, with a note at the
    /// first (TUResult::global_alloc_at). kld would refuse the link anyway
    /// (both define the kairo_global_* symbols strongly), but naming the
    /// two lines beats naming two objects. Objects built apart still reach
    /// kld, which _global_alloc_clash words the same way.
    priv fn _reject_second_global_allocator(self, result: ref!(BatchResult)) {
        var first: isize = -1;
        for var i: usize = 0; i < result.tu_results.size(); ++i {
            var r = result.tu_results[i];
            if !r.global_alloc_at.is_valid() { continue; }
            if first < 0 { first = static_cast::<isize>(i); continue; }
            var p = result.tu_results[static_cast::<usize>(first)];
            // Two inputs that import one module that sets it: one file.
            if p.global_alloc_file == r.global_alloc_file { continue; }
            var a = Path(p.global_alloc_file).filename();
            var b = Path(r.global_alloc_file).filename();
            var d = self._diag->report(DiagID::SC001E, r.global_alloc_at.start,
                f"two files set the global allocator: '{b}' and '{a}'; a program has one");
            d.first(r.global_alloc_at);
            d.note(DiagID::SC001N, p.global_alloc_at.start, f"'{a}' sets it here").first(p.global_alloc_at);
            d.emit();
        }
    }

    /// kld's duplicate-symbol errors for the kairo_global_* symbols (one per
    /// symbol, five in all) as ONE error saying what they mean: two of the
    /// linked objects were built from files that set the global allocator.
    /// The objects are named as kld names them (LinkDiag::definers), and
    /// each as its source file when this run compiled it. Every other
    /// message passes through unchanged.
    priv fn _global_alloc_clash(self, result: ref!(BatchResult), msgs: ref!(vec::<LinkMessage>)) {
        var out  = vec::<LinkMessage>();
        var said = false;
        var sym  = LowerTargets::global_alloc_symbol_prefix();
        for m: LinkMessage in msgs {
            var hit = (m.severity == LinkSeverity::Error)
                && (LinkText::find(m.text, "duplicate symbol: ", 0) < m.text.size())
                && (LinkText::find(m.text, sym, 0) < m.text.size());
            if !hit { out.push_back(m); continue; }
            if said { continue; }
            said = true;
            var who = LinkDiag::definers(m.text);
            var names = vec::<string>();
            for o: string in who { names.push_back(self._object_module(o)); }
            var text = "the global allocator is set twice (@set_global_allocator)";
            if names.size() >= 2 { text = text + f": by {names[0]} and by {names[1]}"; }
            text = text + "; a program has one, so exactly one linked file may set it";
            out.push_back(LinkDiag::make(LinkSeverity::Error, text));
        }
        msgs = out;
    }

    /// An object kld named, as the module it was built from when this run
    /// built it: <object dir>/a/b.o is module `a::b` (each module's object
    /// sits at its path under the object dir). Any other object, as given.
    priv fn _object_module(self, o: string) -> string {
        var dir = self.object_dir();
        if dir.empty() || (!LinkText::starts_with(o, dir + "/")) || (!LinkText::ends_with(o, ".o")) { return o; }
        var rel = LinkText::slice(o, dir.size() + 1, o.size() - 2);
        var m = "";
        for var i: usize = 0; i < rel.size(); ++i {
            if (rel[i] == '/') || (rel[i] == '\\') { m += "::"; } else { m += rel[i]; }
        }
        return f"module '{m}' ({o})";
    }

    /// Plans, echoes under -v, runs. The object list is exactly what this
    /// run emitted, never a directory glob: a reused --cache-dir can hold
    /// objects from modules that no longer exist.
    priv fn _link(self, result: ref!(BatchResult)) {
        var _t  = TimeRegion("Link");

        // lld::lldMain is not reentrant and resets process-global state
        // (CommonLinkerContext, cl options, parallel::strategy); it must run
        // with nothing else in the process inside clang/LLVM. Every group is
        // drained here, not just the ones this driver knows it enqueued, so a
        // late pool task (a header build, a clang startup) can never overlap
        // the link, and no object's writer is still open when lld mmaps it.
        self._pool->wait_all();

        // MinGW's pthreads are not in its libc: a program whose Kairo code
        // imports pthread.h links winpthread, as `-l winpthread` written by
        // hand would (`pthread` is MinGW's alias for the same archive, so a
        // hand-written one already covers it). A copy of the options, so
        // the invocation stays what the user asked for.
        var lk_eff = self.invocation().linker;
        if self._backend != &null {
            var wnorm = llvm::Triple::normalize(sref(self._backend->triple()));
            var wants = false;
            for tr: TUResult in result.tu_results { if tr.ffi_pthread { wants = true; } }
            if wants && llvm::Triple(llvm::Twine(wnorm)).isWindowsGNUEnvironment() {
                var have = false;
                for l: string in lk_eff.link_libs {
                    if LinkText::ends_with(l, "winpthread") || LinkText::ends_with(l, "pthread") { have = true; }
                }
                if !have { lk_eff.link_libs.push_back("winpthread"); }
            }
        }
        var lk  = &lk_eff;
        var job = LinkJob(&(self.invocation().target), lk);
        job.output   = self._link_out;
        job.threads  = u32(self._pool->get_thread_count());
        job.kld_path = self._kld_path();
        // lld's LTO backend defaults to -O2 regardless of how the bitcode was
        // produced; the link must be told the level the objects were built at.
        job.lto       = self.invocation().codegen.lto;
        job.opt_level = self.invocation().codegen.opt_level;
        {
            // As the runtime cache: a cache root that cannot be made (a
            // read-only home, a sandbox) means no cache, not a failed link --
            // lld errors on a cache dir it cannot create.
            var croot = CompilerInstance::_cache_root();
            if !croot.empty() {
                var ldir = croot + "/lto";
                if LinkFS::make_dirs(ldir) { job.lto_cache_dir = ldir; }
            }
        }

        for tr: TUResult in result.tu_results {
            for obj: string in tr.objects { job.add_object(obj); }
        }
        for obj: string in self._native_objs { job.add_object(obj); }
        for obj: string in self._link_inputs { job.add_object(obj); }
        for obj: string in self._lib_lazy { job.lazy_objects.push_back(obj); }
        job.lazy_archive = self._lib_archive;

        // Emission is synchronous (ExecuteAction closes the output through
        // clearOutputFiles before returning), so a missing object here is a
        // driver bug, not a race. Say so instead of letting lld mmap nothing.
        var missing = false;
        for obj: string in job.objects {
            if !LinkFS::is_file(obj) {
                self._diag->report(DiagID::L001E, f"object {obj} was never written; not linking").emit();
                missing = true;
            }
        }
        if missing { return; }

        var tc      = Toolchain();
        var argv    = vec::<string>();
        var msgs    = vec::<LinkMessage>();
        var planned = Link::plan(job, tc, argv, msgs);
        self._report_link(msgs);
        if !planned { return; }

        if lk->print_ld_args {
            std::print(Link::render(argv));
            return;
        }
        if self.invocation().frontend.verbose {
            self._diag->report(DiagID::L001V, Link::render(argv)).emit();
        }

        var res = LinkResult{};
        Link::execute(job, argv, res);
        self._global_alloc_clash(result, res.messages);
        self._report_link(res.messages);
        if !res.stdout_text.empty() { std::print(res.stdout_text); }
        if res.ok { Logger::info(Logger::Stage::Driver, f"linked {self._link_out}"); }
    }

    /// LinkMessage -> the placeholder L001 codes. Verbose and Debug only
    /// under -v.
    priv fn _report_link(self, msgs: ref!(vec::<LinkMessage>)) {
        var verbose = self.invocation().frontend.verbose;
        for m: LinkMessage in msgs {
            if m.severity == LinkSeverity::Fatal        { self._diag->report(DiagID::L001F, m.text).emit(); }
            else if m.severity == LinkSeverity::Error   { self._diag->report(DiagID::L001E, m.text).emit(); }
            else if m.severity == LinkSeverity::Warning { self._diag->report(DiagID::L001W, m.text).emit(); }
            else if m.severity == LinkSeverity::Note    { self._diag->report(DiagID::L001N, m.text).emit(); }
            else if m.severity == LinkSeverity::Remark  { self._diag->report(DiagID::L001R, m.text).emit(); }
            else if m.severity == LinkSeverity::Info    { self._diag->report(DiagID::L001I, m.text).emit(); }
            else if m.severity == LinkSeverity::Verbose { if verbose { self._diag->report(DiagID::L001V, m.text).emit(); } }
            else if m.severity == LinkSeverity::Debug   { if verbose { self._diag->report(DiagID::L001D, m.text).emit(); } }
        }
    }

    //  --print-dirs

    /// Resolves the link toolchain for the effective target and sysroot and
    /// prints where everything was found. Exit 1 if resolution failed.
    fn print_dirs(self) -> i32 {
        var tc   = Toolchain();
        var msgs = vec::<LinkMessage>();
        var ok   = tc.resolve(&(self.invocation().target), &(self.invocation().linker), msgs);
        for line: string in tc.describe() { std::print(line); }
        self._report_link(msgs);
        // Info queries return before execute(), so nothing else drains the
        // engine; without this a failed resolve exits 1 silently.
        self.flush_errors();
        return (0) if (ok) else (1);
    }

    //  --print-clang-args

    /// Prints the cc1 invocation every compile copies, as one shell line:
    /// `clang -cc1` and the arguments, each quoted when the shell would
    /// split or expand it. The input is a placeholder; a real compile hands
    /// clang each TU as an in-memory buffer. Builds the backend's
    /// configuration and starts nothing.
    //  --print-from-clang

    /// \brief the reverse map, made visible: the clang command line given as
    ///        the inputs (after `--`) as kairo CLI words, and the words kairo
    ///        has no flag for. The kairo words are then parsed by the real
    ///        kairo parser, so a row that maps to a flag that does not exist
    ///        fails here, not first in kcc.
    ///
    /// \details Two lines, each word shell-quoted:
    ///            kairo: <kairo words>
    ///            clang-only: <clang words>
    ///          Exit 1 if clang's table or kairo's parser rejected a word.
    fn print_from_clang(self) -> i32 {
        var clang_argv = self.invocation().input_files;
        var kw  = vec::<string>();
        var cw  = vec::<string>();
        var err = "";
        if !FlagTranslator::from_driver(clang_argv, &kw, &cw, &err) {
            self._diag->report(DiagID::U001E, err).emit();
            self.flush_errors();
            return 1;
        }
        var line = "kairo:";
        for w: string in kw { line = line + " " + _shell_quote(w); }
        std::print(line);
        var cline = "clang-only:";
        for w: string in cw { cline = cline + " " + _shell_quote(w); }
        std::print(cline);

        var cmd = std::create::<Command>(0, &null, self._diag);
        finally { std::destroy(cmd); }
        register_kairo_flags(cmd);
        // Validated, not run: a placeholder input after `--` (from_driver
        // never emits one) satisfies "at least one input" for a clang line
        // that names only flags.
        var check = kw;
        check.push_back("--");
        check.push_back("<from-clang>");
        var parsed = cmd->parse_words(check);
        self.flush_errors();
        return (0) if (parsed.ok) else (1);
    }

    /// \p with_link: --print-jobs, which also prints the planned link.
    fn print_clang_args(self, with_link: bool) -> i32 {
        // A failed parse leaves the invocation at its defaults, so the line
        // would show a target and level the user did not ask for.
        if !self.args_ok() {
            self.flush_errors();
            return 1;
        }
        var be   = std::create::<ClangBackend>(self._sm, self._backend_config());
        finally { std::destroy(be); }
        var line = "clang -cc1";
        for a: string in be->invocation_args() { line = line + " " + _shell_quote(a); }
        std::print(line);

        // Then, per C/C++ input, the cc1 line clang's driver plans for it
        // (its -###), as the input's object would be compiled. Only these
        // start clang: a Kairo-only line still starts nothing.
        var n_in = self.invocation().input_files.size();
        var exe  = Path::join_str(Path::parent_of(std::get_exe_path()), "clang");
        for var i: usize = 0; i < n_in; ++i {
            var k = classify_input(self.invocation().input_files[i], self.invocation().input_lang(i));
            if k.cls != InputClass::Source { continue; }
            var w = self._native_words_for(be, k);
            w.push_back("-c"); w.push_back("-x"); w.push_back(k.type_name()); w.push_back(k.path);
            w.push_back("-o"); w.push_back(Path(k.path).stem() + ".o");
            var jobs = ClangJobs(be, exe);
            if !jobs.plan(w) {
                if !jobs.error.empty() { self._diag->report(DiagID::U001E, f"{k.path}: {jobs.error}").emit(); }
                self.flush_errors();
                return 1;
            }
            for pl: string in jobs.planned { std::print(pl); }
        }

        // Then, for --print-jobs (kcc's -###), the link as the run would
        // plan it, when the run links. Objects are named as the run would write them; a Kairo
        // input's imports are only known after preprocessing, so a graph
        // run lists its entries and the library, not each module it reaches.
        var lk = &(self.invocation().linker);
        if with_link && (!lk->compile_only) && (!self.invocation().frontend.stops_before_codegen()) {
            var job = LinkJob(&(self.invocation().target), lk);
            job.output = (self.invocation().frontend.output) if (!self.invocation().frontend.output.empty()) else ("a.out");
            for var i: usize = 0; i < n_in; ++i {
                var k = classify_input(self.invocation().input_files[i], self.invocation().input_lang(i));
                if k.cls == InputClass::Source     { job.add_object(Path(k.path).stem() + ".o"); }
                else if k.cls == InputClass::Kairo {
                    // kairo_object_stem's rule; _inputs is not built for an info query.
                    var stem = Path(k.path).stem();
                    var taken = false;
                    for var j: usize = 0; j < n_in; ++j {
                        var o = classify_input(self.invocation().input_files[j], self.invocation().input_lang(j));
                        if (o.cls == InputClass::Source) && (Path::stem_of(o.path) == stem) { taken = true; }
                    }
                    job.add_object(stem + ((".k.o") if (taken) else (".o")));
                }
                else if k.cls == InputClass::LinkInput { job.add_object(k.path); }
            }
            if lk->kairo_lib { job.lazy_objects.push_back("<kairo-library>/*.o"); }
            var tc   = Toolchain();
            var argv = vec::<string>();
            var msgs = vec::<LinkMessage>();
            var ok   = Link::plan(job, tc, argv, msgs);
            self._report_link(msgs);
            if ok { std::print(Link::render(argv)); }
        }
        self.flush_errors();
        return 0;
    }

    fn execute(self) -> BatchResult {
        assert((self._imp != &null) && r"initialize() must be called before execute()");

        // An ICE aborts past every flush below; the hook prints what this
        // run has buffered first (Native/Types.hh, ice_abort).
        std::set_ice_flush_hook(&CompilerInstance::_flush_for_ice, reinterpret_cast::<*void>(&self));
        finally { std::set_ice_flush_hook(&null, &null); }

        var result = BatchResult();
        var t0     = libcxx::chrono::steady_clock::now();

        finally {
            var t1 = libcxx::chrono::steady_clock::now();
            result.elapsed_ms = static_cast::<f64>(
                libcxx::chrono::duration_cast::<libcxx::chrono::microseconds>(
                    t1 - t0
                ).count()
            ) / 1000.0;
        }

        if self.invocation().input_files.empty() {
            self._diag->report(DiagID::I004F, "no input files").emit();
            result.aborted = true;
            return result;
        }

        if !self._plan_outputs() {
            result.aborted = true;
            return result;
        }
        self._discover_includes();
        if !self._claim_input_identities() {
            result.aborted = true;
            return result;
        }
        // Before the library: its objects are cached by this bit too.
        self._settle_global_allocator();
        if (!self._link_out.empty()) && self.invocation().linker.kairo_lib {
            if !self._kairo_lib() {
                result.aborted = true;
                return result;
            }
        }

        Logger::info(Logger::Stage::Driver,
            f"CompilerInstance::execute: {self.invocation().input_files.size()} file(s)");

        result.tu_results.reserve(self.invocation().input_files.size());

        // No umbrella region here: every stage below (Load .. Codegen, then
        // Link) is a root of the timing tree, so a stage's row is its own
        // time and Link is not reported as part of a frontend.

        // C and C++ inputs are not Kairo TUs: they compile after every Kairo
        // file, through the same clang backend (_compile_sources, through clang's driver).
        var natives = vec::<InputKind>();
        var kairo_inputs: usize = 0;

        // Every input is compiled even after one fails, as clang does with
        // several: each reports its own errors, and the batch fails if any
        // did. `aborted` still stops what runs AFTER the loop (natives, the
        // link).
        var prev_errors: u32 = 0;
        var prev_fatals: u32 = 0;
        for k: InputKind in self._kairo_order() {
            var path_str = k.path;
            if k.cls == InputClass::LinkInput {
                self._link_inputs.push_back(path_str);
                continue;
            }
            if (k.cls == InputClass::Source) || (k.cls == InputClass::Header) {
                natives.push_back(k);
                continue;
            }
            kairo_inputs += 1;

            var action = std::create::<FrontendAction>(
                Path(path_str),
                self._input_module_path(path_str),
                self._g_scope,
                self._imp,
                &self
            );

            finally { std::destroy(action); }

            action->discovered = k.discovered;
            action->errors_at_start = prev_errors;
            action->fatals_at_start = prev_fatals;
            action->run();
            prev_errors = self._diag->error_count();
            prev_fatals = self._diag->fatal_count();

            if action->result.had_fatal { result.aborted = true; }
            result.tu_results.push_back(action->result);
        }

        // Each input may be a script (SCRIPT.md 1.1), and each script is a
        // `main`: two in one link are two programs, which the linker would
        // reject as a duplicate symbol naming neither file. Only a link joins
        // them, so `-c` and --type-check-only of several scripts stay legal.
        if !self._link_out.empty() { self._reject_second_script(result); }
        if !self._link_out.empty() { self._reject_second_global_allocator(result); }

        // C/C++ inputs follow the run's action (_compile_sources); the
        // runtime compiles to objects, and only when Kairo objects were
        // emitted -- an --emit without obj asks for none.
        if (!result.aborted) && (self._diag->error_count() == 0) {
            var _t = TimeRegion("NativeCompile");
            if !self._compile_sources(natives) { result.aborted = true; }
            var fe_rt = &(self.invocation().frontend);
            if (!result.aborted) && (kairo_inputs > 0) && (!fe_rt->stops_before_codegen()) && fe_rt->emit_obj
               && (!self.invocation().linker.inputs_only()) {
                if !self._compile_runtime() { result.aborted = true; }
            }
        }
        self._join_runtime();   // an early start the batch did not get to use.

        // Every set's clang instance dies here, while _backend still lives:
        // imported decls' clang_decl point into those ASTContexts, and
        // nothing after this reads them (codegen ran inside the loop).
        // Releasing each set once its last importer passes Checked is the
        // refinement; the PCH bytes and include tree outlive the release.
        if self._headers != &null {
            self._headers->drain_all(self._diag, self._sm);
            self._headers->release_all();
        }

        // The link runs after every TU and native compile, and before the
        // totals are taken, so a link error fails the batch like any other.
        if !self._link_out.empty() {
            if (!result.aborted) && (self._diag->error_count() == 0) { self._link(result); }
            if self._obj_tmp && (!self.invocation().linker.save_temps) { LinkFS::remove_tree(self._obj_dir); }
        } else if !self._link_inputs.empty() {
            for p: string in self._link_inputs {
                self._diag->report(DiagID::L001W, f"linker input {p} unused: this run does not link").emit();
            }
        }

        // `self._diag` is one engine shared across every TU in this batch
        // (never reset between files), so its final counts are already the
        // batch total - summing per-TU snapshots would double count errors
        // reported before a given TU started. This is the single source of
        // truth `BatchResult::ok()` uses to decide the process exit code:
        // any error anywhere in the pipeline -> non-zero exit; warnings
        // alone -> exit 0.
        result.total_errors   = self._diag->error_count();
        result.total_warnings = self._diag->warn_count();

        Logger::info(Logger::Stage::Driver,
            f"CompilerInstance::execute: {result.summary()}");

        return result;
    }

    /// \brief the module path \p path takes as an input: the one an import
    ///        of it gets (ImportResolver::input_module_path), so a file is one
    ///        module, one namespace and one object path whether it is
    ///        compiled, imported or included, and `kcc -c lib/y.k` emits the
    ///        `lib::y::f` an importer compiled in another run calls
    ///        (decision C). Empty for a pathless file -- one outside every
    ///        search dir, or one whose path a named library owns -- which
    ///        keeps the pathless rules (CXXSpell::is_entry_tu).
    priv fn _input_module_path(self, path: string) -> ModulePath {
        var mp = ModulePath();
        if (self._imp == &null) || (self._pp == &null) { return mp; }
        var sym = self._pp->get_symbol_table();
        for seg: string in self._imp->input_module_path(Path(path)) {
            var ident = IdentifierToken();
            ident.name  = sym->intern(seg);
            ident.token = &null;
            mp.segments.push_back(ident);
        }
        return mp;
    }

    /// \brief adds every .k a C++ or Objective-C++ input includes, and the
    ///        command line does not name, as a Kairo input after the named
    ///        ones (KairoIncludeScan). After _plan_outputs: a discovered
    ///        file is no output -o can name, and before _kairo_order, which
    ///        loads the inputs.
    priv fn _discover_includes(self) {
        var scan = KairoIncludeScan(self._quote_dirs(), self._angle_dirs());
        var any = false;
        for k: InputKind in self._inputs {
            if (k.cls != InputClass::Source) && (k.cls != InputClass::Header) { continue; }
            if !clang::driver::types::isCXX(k.ty) { continue; }
            scan.scan(k.path);
            any = true;
        }
        if !any { return; }
        self._includes_kairo = scan.found.size() > 0;
        for f: string in scan.found {
            var named = false;
            for k: InputKind in self._inputs {
                if k.cls != InputClass::Kairo { continue; }
                if Path::absolute_if_exists(k.path) == f { named = true; break; }
            }
            if named { continue; }
            var nk = classify_input(f, "");
            nk.discovered = true;
            Logger::info(Logger::Stage::Driver, f"CompilerInstance: {f} is included by a C++ input; building it");
            self._inputs.push_back(nk);
        }
    }

    /// The host's angled search path (-I): _quote_dirs without -iquote.
    priv fn _angle_dirs(self) -> vec::<string> {
        var out = self.invocation().clang_include_dirs();
        var fl = &(self.invocation().codegen.cxx_flags);
        for var i: usize = 0; i < fl->size(); ++i {
            var w = (*fl)[i];
            if w == "-iquote" { i += 1; continue; }
            if w == "-I" {
                if i + 1 < fl->size() { out.push_back((*fl)[i + 1]); }
                i += 1;
                continue;
            }
            if LinkText::starts_with(w, "-I") { out.push_back(string(w.raw() + 2, w.size() - 2)); }
        }
        return out;
    }

    /// The host's quoted search path after the includer's own directory:
    /// -iquote, then -I, as clang orders them. The -I come in the order
    /// FlagTranslator::to_driver writes them for a C/C++ input:
    /// clang_include_dirs (-I, --ffi-include, --cxx-include), then the words
    /// in --cxx-flags.
    priv fn _quote_dirs(self) -> vec::<string> {
        var quote = vec::<string>();
        var angle = self.invocation().clang_include_dirs();
        var fl = &(self.invocation().codegen.cxx_flags);
        for var i: usize = 0; i < fl->size(); ++i {
            var w = (*fl)[i];
            var next = ((*fl)[i + 1]) if (i + 1 < fl->size()) else (string(""));
            if w == "-iquote" { quote.push_back(next); i += 1; continue; }
            if w == "-I"      { angle.push_back(next); i += 1; continue; }
            if LinkText::starts_with(w, "-iquote") { quote.push_back(string(w.raw() + 7, w.size() - 7)); continue; }
            if LinkText::starts_with(w, "-I")      { angle.push_back(string(w.raw() + 2, w.size() - 2)); continue; }
        }
        for d: string in angle { quote.push_back(d); }
        return quote;
    }

    // --- The Kairo library (--kairo-lib) ---------------------------------

    /// \brief builtin, std and the runtime, as objects the link takes
    ///        lazily (_lib_lazy): what a link of objects from separate
    ///        `kcc -c` runs needs and none of those runs wrote.
    ///
    /// \details Cached per target and code generation options, under
    ///          the toolchain's cache root (_cache_root), and rebuilt when the compiler or any source
    ///          it was built from changes (the manifest records each one's
    ///          mtime). Built in THIS session, before the inputs, when the
    ///          cache has none: it claims builtin and std first (claim_fid),
    ///          so the inputs' actions emit no copy of their own, and the
    ///          link finds them here. Lazy, so a run that did emit its own
    ///          copy (a valid cache) keeps it, and an unused std module costs
    ///          nothing.
    priv fn _kairo_lib(self) -> bool {
        var dir = self._kairo_lib_dir();
        if dir.empty() { return true; }   // no cache root: the run's own objects are all there is
        if self._read_kairo_lib(dir) { return true; }
        if !self._build_kairo_lib(dir) {
            self._diag->report(DiagID::L001E, f"cannot build the Kairo library in {dir}").emit();
            return false;
        }
        if !self._read_kairo_lib(dir) {
            self._diag->report(DiagID::L001E, f"the Kairo library in {dir} is incomplete").emit();
            return false;
        }
        return true;
    }

    /// \brief the toolchain's cache root, shared by the Kairo library
    ///        (_kairo_lib_dir) and the runtime objects (_rt_cache_dir):
    ///        $KAIRO_CACHE_DIR, else $XDG_CACHE_HOME/kairo, else
    ///        ~/.cache/kairo, else %LOCALAPPDATA%/kairo (Windows, where HOME
    ///        is usually unset). "" when none is set: nothing is cached.
    priv static fn _cache_root() -> string {
        var root = LinkFS::env("KAIRO_CACHE_DIR");
        if root.empty() {
            var xdg = LinkFS::env("XDG_CACHE_HOME");
            if !xdg.empty() { root = xdg + "/kairo"; }
        }
        if root.empty() {
            var home = LinkFS::env("HOME");
            if !home.empty() { root = home + "/.cache/kairo"; }
        }
        if root.empty() {
            var local = LinkFS::env("LOCALAPPDATA");
            if !local.empty() { root = local + "/kairo"; }
        }
        return root;
    }

    /// The cache directory for this target and option set; "" without a root.
    priv fn _kairo_lib_dir(self) -> string {
        var root = CompilerInstance::_cache_root();
        if root.empty() || (self._backend == &null) { return ""; }
        // What the objects' code depends on: the compiler, the target and
        // its ISA words, the code generation and optimization words, debug
        // info, and where builtin and std are read from. Not the inputs'
        // own -D/-I/warnings: they never reach the library.
        var key = std::get_exe_path() + "\n" + self._backend->triple();
        var inv = &(self.invocation());
        var missing = vec::<string>();
        for w: string in FlagTranslator::target(inv->target, ClangSpelling::Driver) { key += "\n" + w; }
        for w: string in FlagTranslator::codegen(*inv, self._backend->triple(), ClangSpelling::Driver, &missing) { key += "\n" + w; }
        var osz: i32 = 0;
        if inv->codegen.opt_size_z    { osz = 2; }
        else if inv->codegen.opt_size { osz = 1; }
        for w: string in FlagTranslator::optimization(inv->codegen.opt_level, osz, inv->codegen.f_vectorize, ClangSpelling::Driver) { key += "\n" + w; }
        key += f"\ndebug={FlagTranslator::debug_on(inv->codegen)}";
        key += "\n" + self.invocation().pp.builtins_dir + "\n" + self.invocation().pp.std_dir;
        // The one macro that does reach the library: the builtin's Global is
        // System inlined, or the kairo_global_* symbols (_settle_global_allocator).
        if self.invocation().pp.global_allocator_set { key += "\nglobal-allocator-set"; }
        var h = llvm::xxh3_64bits(sref(key));
        var hex = llvm::utohexstr(h);
        return root + "/lib/" + self._backend->triple() + "-" + string(hex);
    }

    /// The library's objects from \p dir's manifest into _lib_lazy; false
    /// when there is none or a recorded source has changed.
    priv fn _read_kairo_lib(self, dir: string) -> bool {
        var text = "";
        if !LinkFS::read(dir + "/manifest", text) { return false; }
        var objs = vec::<string>();
        var archive = "";
        var start: usize = 0;
        for var i: usize = 0; i <= text.size(); ++i {
            if (i < text.size()) && (text[i] != '\n') { continue; }
            var line = string(text.raw() + start, i - start);
            start = i + 1;
            if line.starts_with("obj ") { objs.push_back(dir + "/" + string(line.raw() + 4, line.size() - 4)); continue; }
            if line.starts_with("ar ")  { archive = dir + "/" + string(line.raw() + 3, line.size() - 3); continue; }
            if line.starts_with("src ") {
                // `src <mtime> <path>`: the path may hold spaces, the mtime not.
                var rest = string(line.raw() + 4, line.size() - 4);
                var sp: usize = 0;
                while (sp < rest.size()) && (rest[sp] != ' ') { sp += 1; }
                if sp >= rest.size() { return false; }
                var want = string(rest.raw(), sp);
                var path = string(rest.raw() + sp + 1, rest.size() - sp - 1);
                if f"{LinkFS::mtime(path)}" != want { return false; }
            }
        }
        for o: string in objs { if !LinkFS::is_file(o) { return false; } }
        if (!archive.empty()) && (!LinkFS::is_file(archive)) { return false; }
        for o: string in objs { self._lib_lazy.push_back(o); }
        self._lib_archive = archive;
        // Last use, for _gc_kairo_libs.
        LinkFS::write(dir + "/used", "");
        return objs.size() > 0;
    }

    /// \brief builds the library into \p dir: a virtual entry that imports
    ///        std (so builtin and every std module are reached under their
    ///        own module paths), and the runtime, written to a private
    ///        directory and renamed into place, so parallel builds never see
    ///        half a library.
    priv fn _build_kairo_lib(self, dir: string) -> bool {
        var tmp = f"{dir}.tmp-{llvm::sys::Process::getProcessId()}";
        LinkFS::remove_tree(tmp);
        if !LinkFS::make_dirs(tmp) { return false; }

        var saved_dir  = self._obj_dir;
        var saved_objs = self._native_objs.size();
        self._obj_dir  = tmp;
        finally { self._obj_dir = saved_dir; }

        var built = false;
        finally { if !built { LinkFS::remove_tree(tmp); } }

        var errs = self._diag->error_count();
        // A real file in the private directory: an action loads its input by
        // path, and a virtual buffer is not found that way.
        if !LinkFS::write(tmp + "/kairo-lib.k", self._lib_text) { return false; }
        var entry = Path(tmp + "/kairo-lib.k");   // after the write: a Path stats on construction
        var action = std::create::<FrontendAction>(entry, ModulePath(), self._g_scope, self._imp, &self);
        finally { std::destroy(action); }
        action->run();
        if action->result.had_fatal || (self._diag->error_count() != errs) { return false; }
        var objs = action->result.objects;

        if !self._compile_runtime() { return false; }
        for var i: usize = saved_objs; i < self._native_objs.size(); ++i { objs.push_back(self._native_objs[i]); }
        while self._native_objs.size() > saved_objs { self._native_objs.pop_back(); }

        var man = "";
        // A MinGW link takes the library as an archive (LinkJob::lazy_archive).
        // Normalized first: kairo's spelling (x86_64-windows-gnu) has no
        // vendor, and llvm::Triple reads its second field as one.
        var norm = llvm::Triple::normalize(sref(self._backend->triple()));
        if llvm::Triple(llvm::Twine(norm)).isWindowsGNUEnvironment() {
            if !LinkFS::write_archive(tmp + "/libkairo.a", objs) { return false; }
            man += "ar libkairo.a\n";
        }
        for o: string in objs {
            if !o.starts_with(tmp + "/") { return false; }
            man += "obj " + string(o.raw() + tmp.size() + 1, o.size() - tmp.size() - 1) + "\n";
        }
        man += f"src {LinkFS::mtime(std::get_exe_path())} {std::get_exe_path()}\n";
        var n = self._sm->file_count();
        for var i: usize = 0; i < n; ++i {
            var p = self._sm->get_filename(static_cast::<FileID>(i));
            // Virtual buffers (-D) have no file; the entry is in tmp, which
            // the rename below moves.
            if p.empty() || (!LinkFS::is_file(p)) || p.starts_with(tmp + "/") { continue; }
            man += f"src {LinkFS::mtime(p)} {p}\n";
        }
        for k: InputKind in self._runtime_sources() { man += f"src {LinkFS::mtime(k.path)} {k.path}\n"; }
        for p: string in self._runtime_deps() { man += f"src {LinkFS::mtime(p)} {p}\n"; }
        if !LinkFS::write(tmp + "/manifest", man) { return false; }

        // A library already there is stale (_kairo_lib read it and refused
        // it): moved aside first, since a rename cannot replace a full
        // directory. If a parallel build renames its fresh one in between,
        // this rename fails and theirs is used.
        if LinkFS::is_dir(dir) {
            var old = f"{dir}.stale-{llvm::sys::Process::getProcessId()}";
            if LinkFS::rename(dir, old) { LinkFS::remove_tree(old); }
        }
        if LinkFS::rename(tmp, dir) {
            built = true;
            self._gc_kairo_libs(dir);
            return true;
        }
        // Another build got there first: theirs is as good as this one.
        return LinkFS::is_dir(dir);
    }

    /// \brief removes the cached libraries beside \p keep that no link has
    ///        used for 30 days, and what a crashed build left (a day old).
    ///
    /// \details Every compiler rebuild and every option set leaves a library
    ///          of its own, and nothing else removes them. Run when a library
    ///          is built, which is rare; a link only touches `used`
    ///          (_read_kairo_lib).
    priv fn _gc_kairo_libs(self, keep: string) {
        var root = LinkFS::parent(keep);
        var now  = static_cast::<u64>(libcxx::chrono::duration_cast::<libcxx::chrono::nanoseconds>(
            libcxx::chrono::system_clock::now().time_since_epoch()).count());
        var day: u64 = static_cast::<u64>(86400) * static_cast::<u64>(1000000000);   // ns
        for name: string in LinkFS::list_dir(root) {
            var p = root + "/" + name;
            if (p == keep) || (!LinkFS::is_dir(p)) { continue; }
            var partial = (!(string::npos == name.view().find(r".tmp-"))) || (!(string::npos == name.view().find(r".stale-")));
            var last = LinkFS::mtime(p + "/used");
            if last == 0 { last = LinkFS::mtime(p + "/manifest"); }
            if last == 0 { last = LinkFS::mtime(p); }
            var limit = (day) if (partial) else (30 * day);
            if (last != 0) && (now > last) && ((now - last) > limit) { LinkFS::remove_tree(p); }
        }
    }

    /// \brief _inputs, with every Kairo input another one imports moved
    ///        after the rest (stable otherwise).
    ///
    /// \details Written when an input was an ENTRY with no module path, and
    ///          a file's identity was set by its first walk: run first, the
    ///          importer walked it as module `foo` and claimed it
    ///          (claim_fid). An input now takes the path an import gives it
    ///          (_input_module_path), so the order no longer decides identity,
    ///          and this can go. Left in place for now: it is harmless, the
    ///          importer still claims the file it reaches first. The fid-0
    ///          placeholder below is still needed either way.
    priv fn _kairo_order(self) -> vec::<InputKind> {
        var nk: usize = 0;
        for k: InputKind in self._inputs {
            if (k.cls == InputClass::LinkInput) || (k.cls == InputClass::Source) || (k.cls == InputClass::Header) { continue; }
            nk += 1;
        }
        if (nk < 2) || (self._pp == &null) { return self._inputs; }

        // Fid 0 is "unresolved" to the import chain (FileImportIndex::record,
        // ImportDecl::resolved_fid, the TU's import edges). One input is never
        // imported, so it can hold fid 0; of several, the first loaded may be
        // the one another imports, whose import would then resolve to
        // nothing. A placeholder takes fid 0 instead. It relies on nothing
        // loading a Kairo input before this runs (_plan_outputs does not);
        // inputs found any other way (M3's include discovery) must be added
        // to _inputs ahead of this, not loaded.
        if self._sm->file_count() == 0 {
            self._sm->load_virtual(Path(r"<kairo-batch>"),
                reinterpret_cast::<std::ConstPtr::<u8>>(self._fid0_text.raw()), self._fid0_text.size());
        }

        var kfids = vec::<u32>();
        for k: InputKind in self._inputs {
            if (k.cls == InputClass::LinkInput) || (k.cls == InputClass::Source) || (k.cls == InputClass::Header) { continue; }
            kfids.push_back(static_cast::<u32>(self._sm->load_file(Path(k.path))));
        }

        // An input reached from ANOTHER input (not from itself).
        var reached = llvm::DenseSet::<u64>();
        for var i: usize = 0; i < kfids.size(); ++i {
            if kfids[i] == u32(-1) { continue; }
            var r = self._pp->reach(kfids[i]);
            for var j: usize = 0; j < kfids.size(); ++j {
                if (j != i) && (kfids[j] != kfids[i]) && r.contains(kfids[j]) { reached.insert(static_cast::<u64>(kfids[j])); }
            }
        }
        if reached.empty() { return self._inputs; }

        var first = vec::<InputKind>();
        var last  = vec::<InputKind>();
        var n: usize = 0;
        for k: InputKind in self._inputs {
            if (k.cls == InputClass::LinkInput) || (k.cls == InputClass::Source) || (k.cls == InputClass::Header) {
                first.push_back(k);
                continue;
            }
            var f = kfids[n];
            n += 1;
            if (f != u32(-1)) && reached.contains(static_cast::<u64>(f)) { last.push_back(k); } else { first.push_back(k); }
        }
        for k: InputKind in last { first.push_back(k); }
        return first;
    }

    /// \brief frees everything \p fid produced at \p from and every LATER stage.
    ///
    /// \details The one entry point tools should use to reclaim a file. Batch
    ///          compilation never needs it   the process exits   but anything
    ///          that walks many files (kfmt over a tree) or re-processes one
    ///          (LSP on edit) does, because nothing is otherwise reclaimed
    ///          until the CompilerInstance dies.
    ///
    /// ORDERING. Artifacts are torn down newest-stage-first, because every
    /// stage's output points into the stages before it:
    ///
    ///   Codegen/Sema/Parsing  -> ASTContext arenas   (via GlobalDisambigTable)
    ///   Preprocessing         -> the ASTContext itself
    ///   Lexing                -> TokenCacheManager slot (tokens + imm table)
    ///   Loading               -> SourceManager file buffer
    ///
    /// The cascade is mandatory, not a convenience: AST nodes address
    /// identifiers by `imm` index into the fid's ImmediateTable, so an AST that
    /// outlived its tokens has unresolvable names. Releasing at Lexing
    /// therefore MUST take the AST with it, and this ordering is what
    /// guarantees it.
    ///
    /// \return false if nothing was released   unknown fid, or the guard below
    ///         refused.
    ///
    /// \note REFUSES while another loaded file still imports \p fid.
    ///       TranslationUnit::import_edges holds a *Decl into the imported
    ///       file's arena, so releasing it out from under a live importer
    ///       dangles those edges. Release leaves of the import graph first, or
    ///       release the whole batch.
    fn release(self, fid: u32, from: TUStage) -> bool {
        // A header TU is nobody's to reclaim alone: its decls are shared by
        // every importer through the ForeignRegistry, and tearing down its
        // context would dangle all of them. It lives as long as the build.
        if self.is_foreign_fid(fid) {
            Logger::warn(Logger::Stage::Driver,
                f"CompilerInstance::release: fid={fid} is an imported C++ header; refusing");
            return false;
        }
        if self._has_inbound_edges(fid) {
            Logger::warn(Logger::Stage::Driver,
                f"CompilerInstance::release: fid={fid} still imported by a live TU; refusing");
            return false;
        }

        var did = self._g_scope->release_from(fid, from);

        // The PP's walked-set has to die with the context, not with the fid.
        // Preprocessing is what CREATES the ASTContext and TranslationUnit, so
        // a fid still marked walked after its context is gone never gets them
        // back   the next parse returns a null ctx. This was masked for as long
        // as release(Loading) re-minted the fid on every pass; see
        // PreProcessor::forget.
        if from <= TUStage::Preprocessing {
            if self._pp != &null { did = self._pp->forget(fid) || did; }
        }

        if from <= TUStage::Lexing {
            if self._tcm != &null { did = self._tcm->release(fid) || did; }
        }

        if from <= TUStage::Loading {
            if self._sm != &null { did = self._sm->release(fid) || did; }
        }

        Logger::info(Logger::Stage::Driver,
            f"CompilerInstance::release: fid={fid} released={did}");
        return did;
    }

    /// \brief re-reads \p fid from disk and drops everything derived from it.
    ///
    /// \details The edit path. Releases this fid's artifacts (AST, context,
    ///          tokens, imm table, walked mark, macros), then re-maps the file
    ///          so the next parse sees the new bytes.
    ///
    ///          Identity is KEPT: the fid, and every index keyed on it, is the
    ///          same afterwards. That is what makes an edit cheap   the rest of
    ///          the import graph keeps its mappings, line indices and (unless
    ///          separately released) its parsed state.
    ///
    ///          Releases at Lexing rather than Loading on purpose: Loading
    ///          would drop the SourceManager entry, and the file would come
    ///          back under a new fid on the next load, which is the churn this
    ///          whole path exists to avoid.
    ///
    /// \return false if \p fid is unknown, virtual, or could not be re-read.
    fn invalidate(self, fid: u32) -> bool {
        // Dependents FIRST, and this is not an optimization.
        //
        // Two independent reasons, either one fatal on its own:
        //
        //   1. release() REFUSES while another live TU imports this fid, because
        //      TranslationUnit::import_edges holds a *Decl into this file's
        //      arena. Releasing the importers is what clears that refusal.
        //   2. An importer's AST is DERIVED from this file: import edges point
        //      into its arena, and the parser resolved that file's generics and
        //      types through this file's hoisted DisambigTable. Once these bytes
        //      change, those ASTs describe text that no longer exists.
        //
        // Get this wrong and the failure is silent: the fid is stable, so the
        // buffer swaps underneath artifacts that still index into it by offset,
        // and every SourceRange into this file silently addresses different
        // text. Stale-but-coherent is recoverable; this is not.
        var dependents = self.transitive_importers(fid);

        // Importers can import each other, so a single sweep can hit a file
        // whose own importer has not gone yet and be refused. Repeat until a
        // full pass frees nothing   same shape as release_all.
        // Bounded by the worklist size: each sweep must free at least one more
        // file or there is nothing left to unblock, and a dependency chain can
        // be at most as long as the list. Belt-and-braces against a release()
        // that over-reports progress   an unbounded "until no progress" loop
        // over a FIXED list hangs outright if it ever does.
        var sweeps: usize = 0;
        var progress = true;
        while progress && (sweeps <= dependents.size()) {
            progress = false;
            sweeps  += 1;
            for d: u32 in dependents {
                if self.release(d, TUStage::Lexing) { progress = true; }
            }
        }

        // Only a REFUSAL aborts. release() returning false is ambiguous: it also
        // means "nothing to release", which is the normal state for a file whose
        // artifacts an earlier cascade already dropped   reparsing it again must
        // still work. Ask the guard directly instead of reading it off the
        // return value.
        if self._has_inbound_edges(fid) {
            // An importer we could not clear. Leave the bytes ALONE: a stale
            // parse is correct-if-old, whereas re-mapping now would leave live
            // artifacts describing replaced text.
            var ndep = dependents.size();
            Logger::warn(Logger::Stage::Driver,
                f"CompilerInstance::invalidate: fid={fid} still imported after releasing {ndep} dependent(s); not re-mapping");
            return false;
        }

        self.release(fid, TUStage::Lexing);

        if self._sm == &null { return false; }
        return self._sm->invalidate(fid);
    }

    /// \brief fids whose TU holds a resolved import edge directly into \p fid.
    fn importers_of(self, fid: u32) -> vec::<u32> {
        var out = vec::<u32>();

        for other: u32 in self._g_scope->all_fids() {
            if other == fid { continue; }

            var octx = self._g_scope->get_context(other);
            if octx == &null { continue; }

            var otu = reinterpret_cast::<*TranslationUnit>(octx->tu);
            if otu == &null { continue; }

            for var i: usize = 0; i < otu->import_edges.size(); ++i {
                var e = otu->import_edges.get(i);
                if e == &null { continue; }
                if e->target_fid == fid { out.push_back(other); break; }
            }
        }

        return out;
    }

    /// \brief every fid that transitively imports \p fid, nearest first.
    ///
    /// \details The blast radius of changing \p fid's bytes. Transitive because
    ///          the dependency is transitive: if C imports B and B imports A,
    ///          C's AST was built against A's symbols through B.
    ///
    ///          Excludes \p fid itself. Cycle-safe   a fid already queued is
    ///          not queued again, so an import cycle terminates.
    fn transitive_importers(self, fid: u32) -> vec::<u32> {
        var out  = vec::<u32>();
        var seen = set::<u32>();
        seen.insert(fid);

        var frontier = vec::<u32>();
        frontier.push_back(fid);

        while !frontier.empty() {
            var next = vec::<u32>();

            for f: u32 in frontier {
                for imp: u32 in self.importers_of(f) {
                    if seen.contains(imp) { continue; }
                    seen.insert(imp);
                    out.push_back(imp);
                    next.push_back(imp);
                }
            }

            frontier = next;
        }

        return out;
    }

    /// \brief drops \p fid completely, identity included. See SourceManager::evict.
    ///
    /// \details For a deleted file or reclaiming memory   NOT for an edit. The
    ///          fid is retired; loading the same path afterwards mints a new one.
    fn evict(self, fid: u32) -> bool {
        self.release(fid, TUStage::Lexing);

        if self._sm == &null { return false; }
        return self._sm->evict(fid);
    }

    /// \brief index-parses then full-parses a single \p fid, on this thread.
    ///
    /// \details The per-fid body of FrontendAction::_parse, without the fan-out.
    ///          The batch path spreads these across the pool and runs an ordered
    ///          diagnostic flusher behind them so a multi-file build reports in
    ///          fid order; with one file there is nothing to order or overlap,
    ///          and the caller drains the sink itself.
    ///
    /// \return false if \p fid has no context (not preprocessed).
    fn parse_one(self, fid: u32) -> bool {
        var ctx = self._g_scope->get_context(fid);
        if ctx == &null { return false; }

        var gs = self._g_scope;

        // Index first: the full parse disambiguates against the hoisted
        // table this builds. begin_index returns null if it is already
        // indexed, which is the case a reparse must NOT hit   release
        // cleared ctx->hoisted, so this rebuilds it.
        var ictx = gs->begin_index(fid);
        if ictx != &null {
            var indexer = ASTParse(ictx, &null, gs, ASTParse::ParseMode::Index);
            indexer.index();
            gs->finish_index(fid);
        }

        var parser = ASTParse(ctx, &null, gs, ASTParse::ParseMode::Full);
        var parsed_tu = parser.parse();
        ctx->tu = reinterpret_cast::<*void>(parsed_tu);

        return true;
    }

    /// \brief import edges of \p fid whose target has no live context.
    ///
    /// \details After a single-file reparse this counts imports the edit ADDED:
    ///          preprocess_one does not resolve them, so their targets were
    ///          never loaded. Non-zero means the unit is only partially
    ///          resolved and a full parse_file() is needed to make it whole.
    fn unresolved_import_count(self, fid: u32) -> usize {
        var ctx = self._g_scope->get_context(fid);
        if ctx == &null { return 0; }

        var tu = reinterpret_cast::<*TranslationUnit>(ctx->tu);
        if tu == &null { return 0; }

        var n: usize = 0;
        for var i: usize = 0; i < tu->import_edges.size(); ++i {
            var e = tu->import_edges.get(i);
            if e == &null { continue; }
            if e->target_fid == u32(-1) { n += 1; continue; }
            if self._g_scope->get_context(e->target_fid) == &null { n += 1; }
        }
        return n;
    }

    /// \brief true if any OTHER live context holds a resolved import edge into
    ///        \p fid.
    ///
    /// \details Lives here rather than on GlobalDisambigTable because walking
    ///          import_edges needs TranslationUnit, which that module cannot
    ///          import without a cycle.
    priv fn _has_inbound_edges(self, fid: u32) -> bool {
        var fids = self._g_scope->all_fids();

        for other: u32 in fids {
            if other == fid { continue; }

            var octx = self._g_scope->get_context(other);
            if octx == &null { continue; }

            var otu = reinterpret_cast::<*TranslationUnit>(octx->tu);
            if otu == &null { continue; }

            for var i: usize = 0; i < otu->import_edges.size(); ++i {
                var e = otu->import_edges.get(i);
                if e == &null { continue; }
                if e->target_fid == fid { return true; }
            }
        }

        return false;
    }

    /// Installs \p action for a user-spelled diagnostic code. A code the
    /// engine cannot key (no category prefix, no digits) is reported rather
    /// than dropped, so a typo does not look like it worked.
    priv fn _set_code_policy(self, code: string, action: DiagAction) {
        var key = diag_policy_key_from_string(code);
        if key == 0 {
            self._diag->report(DiagID::U001W,
                f"ignoring diagnostic code '{code}\x27: expected a category and number such as R020E").emit();
            return;
        }
        self._diag->set_policy(key, action);
    }

    /// Every input-side path option made absolute, once, before anything
    /// reads one. A relative spelling that survives into the pipeline gets
    /// resolved against whatever directory the reader happens to be in:
    /// headers under a relative --sysroot are re-included from
    /// /kairo/pch/<id>.h and resolve against the PCH's directory, and
    /// --working-dir only chdirs AFTER this runs (apply_input_options), so
    /// -I and --sysroot used to resolve against two different directories.
    ///
    /// Relative paths are taken against --working-dir when given, else the
    /// cwd -- the directory the user meant, on the CLI and programmatic paths
    /// alike. Only paths that EXIST are rewritten (Path::absolute_if_exists):
    /// a missing one keeps the user's spelling for the diagnostic that
    /// rejects it. Output paths and --rpath are deliberately absent -- the
    /// first may not exist yet, the second names a directory on the TARGET.
    priv fn _absolutize_paths(self) {
        var inv  = &(self.invocation());
        var base = Path::absolute_if_exists(inv->working_dir);

        CompilerInstance::_absolutize_all(&(inv->input_files),  base);
        CompilerInstance::_absolutize_all(&(inv->include_dirs), base);
        CompilerInstance::_absolutize_all(&(inv->ffi_includes), base);
        CompilerInstance::_absolutize_all(&(inv->cxx_includes), base);
        CompilerInstance::_absolutize_all(&(inv->macro_paths),  base);

        CompilerInstance::_absolutize_all(&(inv->pp.force_includes), base);
        (inv->pp.prelude_path) = Path::absolute_if_exists(inv->pp.prelude_path, base);
        (inv->pp.builtins_dir) = Path::absolute_if_exists(inv->pp.builtins_dir, base);
        (inv->pp.std_dir)      = Path::absolute_if_exists(inv->pp.std_dir,      base);

        (inv->target.sysroot)      = Path::absolute_if_exists(inv->target.sysroot,      base);
        (inv->target.resource_dir) = Path::absolute_if_exists(inv->target.resource_dir, base);

        CompilerInstance::_absolutize_all(&(inv->linker.lib_dirs), base);
        (inv->linker.linker_script)  = Path::absolute_if_exists(inv->linker.linker_script,  base);
        (inv->linker.version_script) = Path::absolute_if_exists(inv->linker.version_script, base);
        (inv->linker.macos_sdk)      = Path::absolute_if_exists(inv->linker.macos_sdk,      base);

        (inv->codegen.profile_use) = Path::absolute_if_exists(inv->codegen.profile_use, base);
    }

    /// The toolchain prefix: the directory above the one this binary is in
    /// (<prefix>/bin/kairo). get_exe_path is the resolved path, so a kairo
    /// on PATH that symlinks into a tree still finds that tree.
    priv static fn _toolchain_prefix() -> string {
        return Path::parent_of(Path::parent_of(std::get_exe_path()));
    }

    /// The highest-versioned directory under \p base holding the clang
    /// builtin headers (<ver>/include/stddef.h); "" for none. Highest, the
    /// rule lit.cfg.py and Scripts/stage_tree.py use, so a stale old version
    /// left beside the current one is never picked. Versions compare as
    /// numbers: longer first, then by spelling ("22" over "9").
    priv static fn _pick_resource_dir(base: string) -> string {
        var pick = "";
        for name: string in LinkFS::list_dir(base) {
            var cand = LinkText::join(base, name);
            if !LinkFS::is_file(LinkText::join(cand, "include/stddef.h")) { continue; }
            var better = pick.empty();
            if !better {
                var cur = LinkFS::filename(pick);
                better = (name.size() > cur.size())
                      || ((name.size() == cur.size()) && (name > cur));
            }
            if better { pick = cand; }
        }
        return pick;
    }

    /// Fills --resource-dir, --builtins-dir and --std-dir that were not
    /// given from the toolchain layout beside this binary, so a staged tree
    /// (Scripts/stage_tree.py) runs with no flags:
    ///
    ///   --resource-dir   <prefix>/lib/clang/<ver>
    ///   --builtins-dir   <prefix>/lib/builtin
    ///   --std-dir        <prefix>/lib/std
    ///
    /// A flag always wins. A GIVEN --resource-dir keeps its old meaning as
    /// well: its builtin/ and std/ are used when they exist, before the
    /// layout, so an install that put them there still works.
    ///
    /// A root that is still missing is a P001W (queued; initialize()
    /// reports it): without the builtin tree every lang item is unbound and
    /// `string` does not resolve, which otherwise reads as a sema bug rather
    /// than a missing directory. No std warning under --no-stdlib, and no
    /// builtin one under --no-prelude; --freestanding implies both.
    priv fn _discover_roots(self) {
        var inv    = &(self.invocation());
        var prefix = CompilerInstance::_toolchain_prefix();
        var lib    = LinkText::join(prefix, "lib");

        var rd_given = !inv->target.resource_dir.empty();
        if !rd_given {
            var rd = CompilerInstance::_pick_resource_dir(LinkText::join(lib, "clang"));
            if !rd.empty() {
                (inv->target.resource_dir) = rd;
            } else {
                self._queue_root_warning(
                    f"clang resource directory not found: searched {lib}/clang/<version>/include/stddef.h",
                    "pass --resource-dir=<dir> naming the directory whose include/ holds clang\x27s builtin headers (stddef.h)");
            }
        }

        // --no-prelude / --freestanding: "builtin is not linked", so none is
        // looked for either. A found one would also bring the hosted runtime
        // (lib/rt: stdlib.h) into a bare-metal build; --builtins-dir still
        // adds it on purpose.
        if inv->pp.builtins_dir.empty() && (!inv->pp.no_prelude) {
            var legacy = "";
            if rd_given { legacy = LinkText::join(inv->target.resource_dir, "builtin"); }
            var dir = LinkText::join(lib, "builtin");
            if (!legacy.empty()) && LinkFS::is_dir(legacy) {
                (inv->pp.builtins_dir) = legacy;
            } else if LinkFS::is_dir(dir) {
                (inv->pp.builtins_dir) = dir;
            } else {
                self._queue_root_warning(
                    f"builtin module tree not found: searched {dir}",
                    "pass --builtins-dir=<dir> naming the directory that holds builtin\x27s module.k; without it the prelude does not load and lang items such as `string` stay unbound");
            }
        }

        if inv->pp.std_dir.empty() && (!inv->pp.no_stdlib) {
            var legacy = "";
            if rd_given { legacy = LinkText::join(inv->target.resource_dir, "std"); }
            var dir = LinkText::join(lib, "std");
            if (!legacy.empty()) && LinkFS::is_dir(legacy) {
                (inv->pp.std_dir) = legacy;
            } else if LinkFS::is_dir(dir) {
                (inv->pp.std_dir) = dir;
            } else {
                self._queue_root_warning(
                    f"standard library not found: searched {dir}",
                    "pass --std-dir=<dir> naming the standard library tree, or --no-stdlib to build without it");
            }
        }
    }

    /// No usable sysroot is a P001W unless --freestanding asked for none:
    /// without one there are no C headers and no C library, and the failure
    /// otherwise surfaces far later as a missing <stddef.h> or an unresolved
    /// libc symbol. Runs after _use_bundled_sysroot, which has already put a
    /// bundled <prefix>/sysroot/<target> into --sysroot when there is one.
    /// --macos-sdk stands in for a sysroot on Darwin.
    priv fn _check_sysroot(self) {
        var inv = &(self.invocation());
        if inv->lang.freestanding || inv->linker.freestanding { return; }
        if !inv->linker.macos_sdk.empty() { return; }
        var sr = inv->target.sysroot;
        var note = "pass --sysroot=<dir>, or --freestanding to compile without system headers and libraries";
        if sr.empty() {
            var want = self._sysroot_target();
            if want.empty() { want = self._effective_triple(); }
            var root = LinkText::join(CompilerInstance::_toolchain_prefix(), "sysroot");
            self._queue_root_warning(
                f"no sysroot found for target \x27{want}\x27: searched {root}/{want}", note);
        } else if !LinkFS::is_dir(sr) {
            self._queue_root_warning(f"sysroot not found: {sr} is not a directory", note);
        }
    }

    /// --native's own rules, before any root is resolved: it cannot be
    /// combined with --target (one names this machine, the other a triple
    /// built hermetically), and it is only wired for Linux hosts.
    priv fn _check_host_flags(self) -> bool {
        var tg = &(self.invocation().target);
        if !tg->native { return true; }
        if !tg->triple.empty() {
            self._diag->report(DiagID::U001E,
                f"--native and --target={tg->triple} cannot be combined").emit();
            self._diag->report(DiagID::U001N,
                "--native builds for this machine against its own C library, headers and libraries; --target builds hermetically for the named triple against its bundled sysroot. Drop one of them").emit();
            return false;
        }
        var host = llvm::Triple(llvm::Triple::normalize(sref(self.get_target_triple())));
        if !host.isOSLinux() {
            self._diag->report(DiagID::U001E,
                "--native is only implemented for Linux hosts so far").emit();
            self._diag->report(DiagID::U001N,
                "build without it (the default) to use the bundled sysroot, or name the system root with --sysroot (on macOS, --macos-sdk)").emit();
            return false;
        }
        return true;
    }

    /// \brief decides how much of the host system this build sees
    ///        (TargetOptions::host_mode), finds those dirs, and applies
    ///        --pkg-config. Once, here; the backend config and the link only
    ///        read the result.
    ///
    /// \details "floor" is the default on a Linux host compiling for its own
    ///          arch with no --target, --sysroot or --freestanding: the
    ///          bundled sysroot is the C library, and the host's system dirs
    ///          come after it. --native is "native". Anything else is
    ///          hermetic: no host dirs and no host env search paths, so a
    ///          cross build is the same on every machine.
    ///
    ///          The env search paths are read where clang's driver would add
    ///          them (CPATH and friends in _backend_config, LIBRARY_PATH
    ///          here), and NIX_CFLAGS_COMPILE / NIX_LDFLAGS as Zig reads them:
    ///          on Nix the system dirs are not where the defaults look.
    ///
    /// \return false after reporting (a failed --pkg-config).
    priv fn _apply_host_system(self, sysroot_given: bool) -> bool {
        var inv = &(self.invocation());
        var tg  = &(inv->target);
        var host = llvm::Triple(llvm::Triple::normalize(sref(self.get_target_triple())));
        var eff  = llvm::Triple(llvm::Triple::normalize(sref(self._effective_triple())));
        var freestanding = inv->lang.freestanding || inv->linker.freestanding;
        var mode = "";
        if tg->native {
            mode = "native";
        } else if tg->triple.empty() && (!sysroot_given) && (!freestanding)
               && host.isOSLinux() && eff.isOSLinux() && (host.getArch() == eff.getArch()) {
            mode = "floor";
        }
        (tg->host_mode) = mode;

        if !mode.empty() {
            var an: llvm::StringRef = eff.getArchName();
            var arch = Toolchain::canon_arch(string(an.data(), an.size()));
            var en: llvm::StringRef = eff.getEnvironmentName();
            var env  = string(en.data(), en.size());
            var is64 = eff.isArch64Bit();

            var inc  = vec::<string>();
            var seen = vec::<string>();
            var nixc = HostSystem::split_words(LinkFS::env("NIX_CFLAGS_COMPILE"));
            for var i: usize = 0; (i + 1) < nixc.size(); ++i {
                if (nixc[i] == "-isystem") || (nixc[i] == "-idirafter") {
                    HostSystem::add_dir(inc, seen, nixc[i + 1]);
                    i += 1;
                }
            }
            for d: string in HostSystem::include_dirs(arch, env) { HostSystem::add_dir(inc, seen, d); }
            (tg->host_include_dirs) = inc;

            var libs  = vec::<string>();
            var seenl = vec::<string>();
            var nixl = HostSystem::split_words(LinkFS::env("NIX_LDFLAGS"));
            for var i: usize = 0; i < nixl.size(); ++i {
                var w = nixl[i];
                if ((w == "-L") || (w == "-rpath")) && ((i + 1) < nixl.size()) {
                    if w == "-L" { HostSystem::add_dir(libs, seenl, nixl[i + 1]); }
                    else         { inv->linker.rpath.push_back(nixl[i + 1]); }
                    i += 1;
                } else if LinkText::starts_with(w, "-L") {
                    HostSystem::add_dir(libs, seenl, LinkText::slice(w, 2, w.size()));
                }
            }
            for d: string in HostSystem::lib_dirs(arch, env, is64) { HostSystem::add_dir(libs, seenl, d); }
            (tg->host_lib_dirs) = libs;
            (tg->env_lib_dirs)  = HostSystem::env_list("LIBRARY_PATH");

            if mode == "native" {
                var t = string(eff.getTriple());
                (tg->native_bundle) = self._bundled_sysroot_dir(t);
                if tg->native_bundle.empty() {
                    self._queue_root_warning(
                        f"--native: no bundled sysroot for \x27{t}\x27 to take libc++ and compiler-rt from",
                        "the build uses whatever C++ runtime the host has (-lc++, libgcc)");
                }
            }
        }

        if tg->pkg_config.empty() { return true; }
        if (!tg->triple.empty()) && LinkFS::env("PKG_CONFIG_SYSROOT_DIR").empty() && LinkFS::env("PKG_CONFIG_LIBDIR").empty() {
            self._diag->report(DiagID::U001E,
                f"--pkg-config cannot be used with --target={tg->triple} as is: this machine\x27s .pc files describe this machine, not the target").emit();
            self._diag->report(DiagID::U001N,
                "point PKG_CONFIG_SYSROOT_DIR or PKG_CONFIG_LIBDIR at the target\x27s pkg-config tree").emit();
            return false;
        }
        var ok = true;
        for name: string in tg->pkg_config {
            var words = vec::<string>();
            var err   = "";
            if !HostSystem::pkg_config(name, words, err) {
                self._diag->report(DiagID::U001E, f"--pkg-config {name}: {err}").emit();
                ok = false;
                continue;
            }
            self._apply_pkg_words(name, words);
        }
        return ok;
    }

    /// One package's pkg-config words, into the lists the flags of the same
    /// spelling fill: -I/-isystem/-idirafter as --ffi-include, -D/-U as
    /// --cxx-define/--cxx-undefine, -L/-l/-pthread and -Wl, to the link. A
    /// -I or -L naming a host system dir is dropped: those are already
    /// searched after the sysroot, and as a -I/-L they would come before it
    /// (-I/usr/include ahead of libc++ is how <cstring> breaks).
    priv fn _apply_pkg_words(self, name: string, words: ref!(vec::<string>)) {
        var inv = &(self.invocation());
        var tg  = &(inv->target);
        var i: usize = 0;
        while i < words.size() {
            var w   = words[i];
            var nxt = "";
            if (i + 1) < words.size() { nxt = words[i + 1]; }
            var kind = "";
            var val  = "";
            var step: usize = 1;
            if (w == "-I") || (w == "-isystem") || (w == "-idirafter") { kind = "I"; val = nxt; step = 2; }
            else if LinkText::starts_with(w, "-isystem")   { kind = "I"; val = LinkText::slice(w, 8, w.size()); }
            else if LinkText::starts_with(w, "-idirafter") { kind = "I"; val = LinkText::slice(w, 10, w.size()); }
            else if w == "-D" { kind = "D"; val = nxt; step = 2; }
            else if w == "-U" { kind = "U"; val = nxt; step = 2; }
            else if w == "-L" { kind = "L"; val = nxt; step = 2; }
            else if w == "-l" { kind = "l"; val = nxt; step = 2; }
            else if w == "-pthread" { kind = "l"; val = "pthread"; }
            else if LinkText::starts_with(w, "-Wl,") { kind = "Wl"; val = LinkText::slice(w, 4, w.size()); }
            else if LinkText::starts_with(w, "-I") { kind = "I"; val = LinkText::slice(w, 2, w.size()); }
            else if LinkText::starts_with(w, "-D") { kind = "D"; val = LinkText::slice(w, 2, w.size()); }
            else if LinkText::starts_with(w, "-U") { kind = "U"; val = LinkText::slice(w, 2, w.size()); }
            else if LinkText::starts_with(w, "-L") { kind = "L"; val = LinkText::slice(w, 2, w.size()); }
            else if LinkText::starts_with(w, "-l") { kind = "l"; val = LinkText::slice(w, 2, w.size()); }
            else if LinkText::starts_with(w, "/") && (LinkText::ends_with(w, ".a") || HostSystem::is_shared(w)) { kind = "l"; val = w; }
            i += step;

            if kind.empty() {
                self._diag->report(DiagID::U001W,
                    f"--pkg-config {name}: ignoring \x27{w}\x27, which kairo has no place for").emit();
                continue;
            }
            if val.empty() { continue; }
            if kind == "I" {
                var sys = false;
                var rv  = LinkFS::real(val);
                for d: string in tg->host_include_dirs { if LinkFS::real(d) == rv { sys = true; } }
                if !sys { inv->ffi_includes.push_back(val); }
            } else if kind == "L" {
                var sys = false;
                var rv  = LinkFS::real(val);
                for d: string in tg->host_lib_dirs { if LinkFS::real(d) == rv { sys = true; } }
                if !sys { inv->linker.lib_dirs.push_back(val); }
            } else if kind == "D" {
                inv->cxx_defines.push_back(val);
            } else if kind == "U" {
                inv->cxx_undefines.push_back(val);
            } else if kind == "l" {
                inv->linker.link_libs.push_back(val);
            } else {
                var b: usize = 0;
                for var k: usize = 0; k <= val.size(); ++k {
                    if (k == val.size()) || (val[k] == ',') {
                        var part = LinkText::slice(val, b, k);
                        if !part.empty() { inv->linker.ld_flags.push_back(part); }
                        b = k + 1;
                    }
                }
            }
        }
    }

    priv fn _queue_root_warning(self, msg: string, note: string) {
        self._root_warnings.push_back(msg);
        self._root_warnings.push_back(note);
    }

    /// The warnings _discover_roots and _check_sysroot queued, reported once
    /// the run is really compiling: --help, --version, --explain and the
    /// info queries never reach initialize(), and do not need the roots.
    priv fn _report_root_warnings(self) {
        for var i: usize = 0; (i + 1) < self._root_warnings.size(); i += 2 {
            self._diag->report(DiagID::P001W, self._root_warnings[i]).emit();
            self._diag->report(DiagID::P001N, self._root_warnings[i + 1]).emit();
        }
        self._root_warnings.clear();
    }

    priv static fn _absolutize_all(list: *vec::<string>, base: string) {
        for var i: usize = 0; i < list->size(); ++i {
            ((*list)[i]) = Path::absolute_if_exists((*list)[i], base);
        }
    }

    /// Maps invocation fields to live subsystem setters. Called once after
    /// the invocation is built. Fields whose subsystem does not yet exist are
    /// silently accepted stored in the invocation for future use.
    priv fn _apply_invocation(self) {
        var d  = self.invocation().diag;
        var fe = self.invocation().frontend;

        // Only the formats a consumer exists for. json and msvc used to be
        // advertised and silently rendered as pretty; msvc still has no
        // consumer, so it is refused rather than faked.
        if (d.format != "pretty") && (d.format != "basic") && (d.format != "json") {
            if (d.format == "msvc") {
                self._diag->report(DiagID::U001E, "error format 'msvc' is not implemented").emit();
            } else {
                self._diag->report(DiagID::U001E,
                    f"unknown error format '{d.format}\x27 (expected pretty, basic or json)").emit();
            }
            self.invocation().ok = false;
            return;
        }

        if (d.format == "basic") || (d.format == "json") {
            self._diag->remove_consumer(self._pretty);
            self._diag->add_consumer(self._basic);
            self._basic->set_json(d.format == "json");
            // Flag-parse diagnostics (U005W, -D shape errors) are already in
            // the pretty buffer; carry them over or basic mode never shows them.
            self._pretty->drain_into(self._basic);
        }

        self._basic->set_absolute_paths(d.absolute_paths);
        self._pretty->configure(d.show_context, u32(d.max_context_lines), d.absolute_paths);

        if d.no_color { self._pretty->set_color(false); }

        // 0 = unlimited for the error, warning and note caps (Engine honours it).
        self._diag->set_error_limit(u32(d.max_errors));
        self._diag->set_warning_limit(u32(d.max_warnings));
        self._diag->set_note_limit(u32(d.max_notes));
        self._diag->set_fixit_limit(u32(d.max_suggestions));
        self._diag->set_warnings_as_errors(d.warnings_as_errors);
        self._diag->set_suppress_all_warnings(d.suppress_warnings);

        // Per-code diagnostic policy. A code is addressed by category prefix +
        // number (severity-letter-agnostic): R020, R020E and r020w are one key,
        // but SC005 and S005 are not. Applied in this order so the stronger
        // intent wins on a repeated code: allow < warn < deny < forbid, i.e.
        // `-A X -W X` leaves X enabled.
        for c in d.allow_list  { self._set_code_policy(c, DiagAction::Silence); }
        for c in d.warn_list   { self._set_code_policy(c, DiagAction::Warn);    }
        for c in d.deny_list   { self._set_code_policy(c, DiagAction::Promote); }
        for c in d.forbid_list { self._set_code_policy(c, DiagAction::Forbid);  }

        // --quiet: nothing but errors. Warnings, notes and remarks are dropped
        // at the engine; the logger stream follows so verbose chatter cannot
        // leak around it.
        if fe.quiet {
            self._diag->set_quiet(true);
            Logger::set_level(Logger::Level::Error);
        }

        // Logger was initialised at Trace in main(); quiet it down unless
        // the user asked for verbose output. The stream level controls what is
        // echoed to stderr live (default Error); --verbose turns the terminal
        // into a running trace instead of something you read out of kairo.log
        // after the fact.
        // Under --quiet the level is already pinned to Error above.
        if !fe.quiet {
            if !fe.verbose {
                Logger::set_level(Logger::Level::Warn);
            } else {
                Logger::set_stream_level(Logger::Level::Info);
            }
        }

        // Before _use_bundled_sysroot fills it: whether the user named the
        // root, which keeps a default build off the host's dirs.
        var sysroot_given = !self.invocation().target.sysroot.empty();
        if !self._check_host_flags() {
            self.invocation().ok = false;
            return;
        }

        // After the consumers are set up, so a malformed sysroot reports in
        // the format asked for.
        if !self._use_bundled_sysroot() {
            self.invocation().ok = false;
            return;
        }

        self._absolutize_paths();

        // After absolutizing: discovery fills only the roots still empty, and
        // what it fills is already absolute (it hangs off the exe's path).
        // Before real() below, so a discovered resource dir is made
        // symlink-free exactly like a given one.
        self._discover_roots();
        self._check_sysroot();

        // Both roots also symlink-free from here on, on top of absolute:
        // clang reports headers under the real path, and the header set keys
        // on clang's spelling. real() leaves a path that does not exist
        // unchanged; the resolvers report it.
        var tg = &(self.invocation().target);
        if !tg->sysroot.empty()      { (tg->sysroot)      = LinkFS::real(tg->sysroot); }
        if !tg->resource_dir.empty() { (tg->resource_dir) = LinkFS::real(tg->resource_dir); }
        // The module roots too. A builtin root reached through a symlink
        // (a debug tree's lib/builtin -> Lib/builtin, or any --builtins-dir
        // that is one) left the lang items unbound and ICEd in
        // NullTestLowering; resolved, a debug run with no flags sees exactly
        // the roots lit passes.
        var ppo = &(self.invocation().pp);
        if !ppo->builtins_dir.empty() { (ppo->builtins_dir) = LinkFS::real(ppo->builtins_dir); }
        if !ppo->std_dir.empty()      { (ppo->std_dir)      = LinkFS::real(ppo->std_dir); }

        // The host system: which mode, its dirs, --pkg-config. After the
        // roots are final, before anything (the backend config, the link,
        // --print-clang-args) reads them.
        if !self._apply_host_system(sysroot_given) {
            self.invocation().ok = false;
            return;
        }

        // Pointer width for usize/isize, off the effective triple. -m32/-m64
        // are applied as arch-variant rewrites first, matching clang: they
        // change WHICH triple we compile for, and the width follows from that.
        // Written onto the invocation so sema reads a plain number and Config/
        // never has to see LLVM.
        var triple_str = self._effective_triple();
        var width: usize = 64;
        
        var tt = llvm::Triple(llvm::Triple::normalize(sref(triple_str)));
        if self._inv.target.m32      {
            tt = tt.get32BitArchVariant();
        } else if (self._inv.target.m64) {
            tt = tt.get64BitArchVariant();
        }
        
        var w = tt.getArchPointerBitWidth();
        if w != 0 {
            width = static_cast<usize>(w);
        }
        
        (self.invocation().target.pointer_width) = width;

        // The rest of the derived target facts, off the SAME Triple, so
        // pointer width and ISA can never disagree about which target this
        // is. Sema reads these; Config/ still never sees LLVM.
        var full: string           = string(tt.getTriple());
        var arch: llvm::StringRef = tt.getArchName();
        var vend: llvm::StringRef = tt.getVendorName();
        var osn:  llvm::StringRef = tt.getOSName();
        var env:  llvm::StringRef = tt.getEnvironmentName();

        var objfmt: string;
        switch tt.getObjectFormat() {
            case llvm::Triple::COFF { objfmt = "COFF"; }
            case llvm::Triple::ELF { objfmt = "ELF"; }
            case llvm::Triple::MachO { objfmt = "Mach-O"; }
            case llvm::Triple::Wasm { objfmt = "Wasm"; }
            case llvm::Triple::XCOFF { objfmt = "XCOFF"; }
            case llvm::Triple::GOFF { objfmt = "GOFF"; }
            case llvm::Triple::DXContainer { objfmt = "DXContainer"; }
            case llvm::Triple::SPIRV { objfmt = "SPIR-V"; }
            default { objfmt = "unknown"; }
        }

        var t = &(self.invocation().target);
        (t->effective_triple) = full;
        (t->arch_name)        = string(arch.data(), arch.size());
        (t->vendor_name)      = string(vend.data(), vend.size());
        (t->os_name)          = string(osn.data(),  osn.size());
        (t->env_name)         = string(env.data(),  env.size());
        (t->object_format)    = objfmt;
        (t->is_little_endian) = tt.isLittleEndian();
        (t->is_x86)           = tt.isX86();
        (t->has_os)           = (tt.getOS() != llvm::Triple::UnknownOS);
        self._fill_clang_type_facts(tt);
        (t->resolved)         = true;

        var err: libcxx::string;
        var T = llvm::TargetRegistry::lookupTarget(tt, err);
        if T == &null {
            self._diag->report(DiagID::P004F,
                f"unknown target triple '{t->effective_triple}': {string(err)}").emit();
            self.invocation().ok = false;
            return;
        }
        if !self._inv.target.mcpu.empty() {
            var STI = T->createMCSubtargetInfo(tt, r"", r"");
            finally { delete STI; }
            if !STI->isCPUStringValid(sref(self._inv.target.mcpu)) {
                self._diag->report(DiagID::P006E,
                    f"unknown target CPU '{self._inv.target.mcpu}' for target '{t->effective_triple}\x27").emit();
                self._diag->report(DiagID::P006N, // Maybe add a new diagnostic catogery for this? like Driver?
                    f"run with --print-cpus --target={t->effective_triple} to list valid values").emit();
                self.invocation().ok = false;
                return;
            }
        }
    }

    /// Fill TargetOptions' `long double` block and int64_t spelling from
    /// clang::TargetInfo for \p tt, the same post -m32/-m64 Triple the rest
    /// of the derived facts came from.
    ///
    /// Asked of clang, not a triple list: both are ABI decisions clang already
    /// makes per triple, and every hand-written approximation has been wrong
    /// somewhere -- "is x86" for x87 on MSVC (binary64) and Android
    /// (binary128), "64-bit and not Windows" for `long` int64_t on Darwin,
    /// which is LP64 and still spells it `long long`. The TargetInfo is
    /// throwaway -- only the answers are kept, so Config/ and Sema still
    /// never see clang.
    priv fn _fill_clang_type_facts(self, tt: ref!(llvm::Triple)) {
        var t = &(self.invocation().target);

        var dopts = clang::DiagnosticOptions();
        var diags = clang::DiagnosticsEngine(clang::DiagnosticIDs::create(), dopts,
                                             std::create::<clang::IgnoringDiagConsumer>(), true);
        var topts = libcxx::make_shared::<clang::TargetOptions>();
        (topts->Triple) = tt.getTriple();
        var ti = llvm::IntrusiveRefCntPtr::<clang::TargetInfo>(
            clang::TargetInfo::CreateTargetInfo(diags, *topts));

        // No TargetInfo means clang does not know the triple, and the
        // lookupTarget check right after this reports P004F and fails the
        // invocation. Fall back to the ISA so f80 does not add a second,
        // misleading error on top of that one.
        if ti.get() == &null {
            (t->long_double_is_x87) = t->is_x86;
            (t->int64_is_long)      = (t->pointer_width == 64) && (!tt.isOSWindows());
            (t->usize_is_fixed)     = !tt.isOSDarwin();
            (t->isize_is_fixed)     = !tt.isOSDarwin();
            return;
        }

        // CanonicalTypes spells i64/u64 from this. Any other answer than
        // `long` is `long long`: no target clang knows makes int64_t an `int`.
        (t->int64_is_long) = ti->getInt64Type() == clang::TargetInfo::SignedLong;

        // RedeclMerge folds usize/isize into the fixed-width pair for the C++
        // collision check only when size_t / ptrdiff_t ARE that pair. Compared
        // as clang's IntType against the type kairo SPELLS for u<pw>/i<pw>:
        // Int64Type for 64 (the same answer int64_is_long came from, so u64's
        // spelling and size_t's cannot drift apart), `int` and `short` below
        // that (BuiltinTable's fixed rows). NOT getIntTypeByWidth: that walks
        // char/short/int/long/long long and answers `long` for 64 on every
        // LP64 target, Darwin included, where Int64Type is `long long` --
        // which is exactly the case this exists to tell apart.
        var pw_bits = ti->getPointerWidth(clang::LangAS::Default);
        var want_u: clang::TargetInfo::IntType = clang::TargetInfo::NoInt;
        var want_s: clang::TargetInfo::IntType = clang::TargetInfo::NoInt;
        if pw_bits == 64 { want_u = ti->getUInt64Type(); want_s = ti->getInt64Type(); }
        if pw_bits == 32 { want_u = clang::TargetInfo::UnsignedInt;   want_s = clang::TargetInfo::SignedInt;   }
        if pw_bits == 16 { want_u = clang::TargetInfo::UnsignedShort; want_s = clang::TargetInfo::SignedShort; }
        (t->usize_is_fixed) = ti->getSizeType() == want_u;
        (t->isize_is_fixed) = ti->getPtrDiffType(clang::LangAS::Default) == want_s;

        var fmt    = &(ti->getLongDoubleFormat());
        var is_x87 = fmt == &(llvm::APFloat::x87DoubleExtended());
        var name: string = "an unrecognized format";
        if is_x87                                     { name = "x87 extended"; }
        if fmt == &(llvm::APFloat::IEEEdouble())      { name = "binary64"; }
        if fmt == &(llvm::APFloat::IEEEquad())        { name = "binary128"; }
        if fmt == &(llvm::APFloat::PPCDoubleDouble()) { name = "IBM double-double"; }

        (t->long_double_is_x87)   = is_x87;
        (t->long_double_fmt_name) = name;
        (t->long_double_bits)     = static_cast::<usize>(ti->getLongDoubleWidth());
        (t->long_double_align)    = static_cast::<usize>(ti->getLongDoubleAlign());
        (t->has_float128)         = ti->hasFloat128Type();
    }
}

//  FrontendAction out-of-line definitions

/// Executes the full pipeline on the calling thread.
///
/// Stages are gated by \c FrontendOptions. A stage returning false halts the
/// pipeline and leaves \c _stage at \c Failed. An early-exit stop-at flag
/// advances \c _stage to \c Done and returns without running further stages.
///
/// Load and lex run on the driver thread (shared SM/TCM writes). Preprocess
/// through codegen are per-file and will be async-dispatchable in a future
/// phase.
fn FrontendAction::run() {
    var t0 = libcxx::chrono::steady_clock::now();
    finally {
        var t1 = libcxx::chrono::steady_clock::now();
        self.result.elapsed_ms = static_cast::<f64>(
            libcxx::chrono::duration_cast::<libcxx::chrono::microseconds>(
                t1 - t0
            ).count()
        ) / 1000.0;
        self.result.stage   = self._stage;
        self.result.file_id = self._file_id;

        // Snapshot AFTER every stage this TU reached, whichever one halted
        // it. `_preprocess()` used to be the only writer here, which meant
        // errors from parse/sema/codegen never made it into `result` and a
        // TU that failed there was silently reported as clean.
        self.result.error_count = self._ci->diag()->error_count();
        self.result.warn_count  = self._ci->diag()->warn_count();
    }

    Logger::info(Logger::Stage::Driver,
        f"FrontendAction: begin '{self.path.full_path()}\x27");

    // The engine is shared by every input of the batch and never reset, so
    // the gates below compare against what the PREVIOUS input left
    // (errors_at_start, set by execute(); 0 for the first). Testing the
    // batch total stopped every input after the first one that had an
    // error, right after its parse: `kairo --type-check-only a.k b.k` never
    // checked b.k when a.k failed, where clang (and a whole-tree check)
    // reports every input's errors. Not the count when run() starts: the
    // batch's dependency scan reports an input's own lexing errors (S072E)
    // before any run(), and they must still stop the first input's Sema.

    // Phase 1: shared-state stages driver thread only.
    if !self._load() { return; }

    // Phase 2: per-file stages async-dispatchable in a future phase.
    if !self._preprocess() { return; }
    var fe = ((self._ci->invocation()).frontend);
    // Past the action's own stop when a C++ input may include this file:
    // the include needs it analysed (CompilerInstance::kairo_feeds_includes).
    var feed = self._ci->kairo_feeds_includes();
    if fe.stops_at_preprocess() && (!feed) { self._stage = TUStage::Done; return; }
    if self._fids.empty() { self._stage = TUStage::Done; return; }

    if !self._parse() { return; }
    if self._ci->diag()->error_count() > self.errors_at_start { self._stage = TUStage::Failed; return; }
    if fe.stops_at_parse() && (!feed) { self._stage = TUStage::Done; return; }

    if !self._sema() { return; }
    if self._ci->diag()->error_count() > self.errors_at_start { self._stage = TUStage::Failed; return; }
    if fe.stops_at_sema() { self._stage = TUStage::Done; return; }

    self._dump_mem_stats();   // MEM_STATS: after Sema, before the header release.
    // Phase A's clang instances are Sema's (HeaderIndex, M2 fills, defined!):
    // codegen reads only the merged PCH and the sets' text. With one Kairo
    // input and no C++ input including a .k, no later action needs them, so
    // they are freed before the fan-out instead of at exit -- ~200 MB each,
    // the bulk of the peak (P380). Any later read is counted, not silent.
    if (self._ci->kairo_only_input_count() == 1) && (!self._ci->kairo_feeds_includes()) && (self._ci->headers() != &null) {
        var _tr = TimeRegion("HeaderRelease");
        self._ci->headers()->drain_all(self._ci->diag(), self._ci->sm());
        self._ci->headers()->release_all();
    }

    if !self._codegen() { return; }
    self._dump_mem_stats();
    {
        var late = kairo::header_set_late_uses().load();
        Logger::info(Logger::Stage::Driver, f"header sets revived after release_unused: {kairo::header_set_revivals().load()}");
        if late > 0 {
            Logger::warn(Logger::Stage::Driver, f"{late} use(s) of a header set's clang AST after its early release (P380)");
            std::eprintln(f"kairo: warning: {late} use(s) of a released header set (P380)");
        }
    }

    self._stage = TUStage::Done;
    Logger::info(Logger::Stage::Driver,
        f"FrontendAction: done '{self.path.full_path()}' ({self.result.elapsed_ms:.2}ms)");
}

//  Pipeline stages each returns true to continue, false to halt.

/// Emits a fatal diagnostic, marks the TU as failed, and returns false.
fn FrontendAction::_fatal(id: DiagID, msg: string) -> bool {
    self._ci->diag()->report(id, msg).emit();
    self.result.had_fatal = true;
    self._stage = TUStage::Failed;
    return false;
}

fn FrontendAction::_syntax_only() -> bool {
    var fe = ((self._ci->invocation()).frontend);
    return fe.is_syntax_only() && (!self._ci->kairo_feeds_includes());
}

/// Registers the source file with \c SourceManager and obtains a file ID.
fn FrontendAction::_load() -> bool {
    var _t = TimeRegion("Load");

    self._stage   = TUStage::Loading;
    self._file_id = self._ci->sm()->load_file(self.path);
    if self._file_id == u32(-1) {
        return self._fatal(DiagID::I005F, f"cannot open '{self.path.full_path()}\x27");
    }
    return true;
}

/// Runs the preprocessor walk for this file's dependency graph.
/// The PreProcessor is batch-scoped (owned by CompilerInstance): it walks
/// each fid exactly once across all input files, so a fid shared by two
/// inputs is preprocessed once. Its DAG visited-set does the dedup.
fn FrontendAction::_preprocess() -> bool {
    var _t = TimeRegion("Preprocess");

    self._stage = TUStage::Preprocessing;

    // --syntax-only is per file (P355): it parses its inputs and nothing they
    // import, and a C++ header is not syntax, so no clang parse either. The
    // import closure is still preprocessed -- an imported macro is expanded
    // in the input's own tokens, and that needs its definition.
    var syntax_only = self._syntax_only();
    if syntax_only { self._ci->pp()->drop_headers(); }

    var pp_res = self._ci->pp()->preprocess(self._file_id, self.module_base);
    // P417: the header lists this preprocess recorded are parsed as one set,
    // on the pool, overlapping the parse.
    if self._ci->headers() != &null { self._ci->headers()->start_shared(); }
    // Only what no earlier input took: the rest is done (claim_fid). An
    // input another one imports is left with nothing -- except under
    // --syntax-only, where the importer parsed only itself.
    self._graph = pp_res.fids;
    self._fids.clear();
    for f: u32 in pp_res.fids {
        var mine = self._ci->claim_fid(f);
        if mine || (syntax_only && (f == self._file_id)) { self._fids.push_back(f); }
    }
    // Which fid is the builtin module, recorded once for the build. Sema fills
    // the lang-item table from it (NameResolution); it cannot identify the fid
    // itself, because ModulePath segments are PP SymbolIDs and Sema has no
    // symbol table. 0 means no builtin root -- the lang items stay unbound and
    // whichever pass needs one diagnoses it at the use.
    if pp_res.builtin_fid != 0 { self._global_scope->set_builtin_fid(pp_res.builtin_fid); }

    // error_count/warn_count are snapshotted once in run()'s finally block,
    // after every stage this TU reaches - not here.

    if self._ci->diag()->fatal_count() > self.fatals_at_start {
        self.result.had_fatal = true;
        self._stage = TUStage::Failed;
        return false;
    }
    if !pp_res.ok {
        self._stage = TUStage::Failed;
        return false;
    }

    // NOTE: no clang preload here. Kairo fids are mirrored into the clang SM
    // by ClangLocMap::rebind(), inside the codegen action window   the only
    // place a FileID survives FrontendAction::BeginSourceFile's
    // clearIDTables(). Registering off-thread after preprocess produced a map
    // that was stale from the first ExecuteAction onward.

    var fe = self._ci->invocation().frontend;
    if fe.dump_preprocessed { self._dump_preprocessed_source(); }
    if fe.print_tokens  { self._dump_tokens();  }
    if fe.print_macros  { self._dump_macros();  }
    if fe.print_imports { self._dump_imports(); }
    return true;
}

/// Marks one parse task's fid as done when the task ends, however it ends,
/// so the flusher never waits on a task that threw.
class PublishOnExit {
    priv var _d: *std::Atomic::<bool>;

    fn PublishOnExit(self, d: *std::Atomic::<bool>) { self._d = d; }

    delete fn PublishOnExit(self, other: ref!(PublishOnExit));
    delete fn op = (self, other: ref!(PublishOnExit)) -> ref!(PublishOnExit);

    fn op delete (self) { self._d->store(true, libcxx::memory_order_release); }
}

fn FrontendAction::_parse() -> bool {
    var _t = TimeRegion("Parse");

    self._stage = TUStage::Parsing;

    // tree order, fids[0] == main. A C++ header is never in _fids (the PP
    // never walks one), but a fid is only a number: filter anyway, because a
    // header TU reaching ASTParse would lex C++ as Kairo and overwrite the TU
    // Sema/Foreign filled.
    var fids = vec::<u32>();
    for f: u32 in self._fids {
        if self._ci->is_foreign_fid(f) { continue; }
        fids.push_back(f);
    }
    // --syntax-only: the closure is indexed (the parser's disambiguation
    // reads imported names), but only the input is parsed in full, so only
    // its errors are reported (P355).
    var parse_fids = vec::<u32>();
    var syntax_only = self._syntax_only();
    for f: u32 in fids {
        if syntax_only && (f != self._file_id) { continue; }
        parse_fids.push_back(f);
    }

    // index phase: Index-mode ASTParse over each fid (same grammar as the
    // full parse, shallow materialization). Replaces the old ASTIndex
    // token-level pre-pass.

    {
        var _ti = TimeRegion("Index");

        for fid: u32 in fids {
            var captured_rec = kairo::TimeReport::current();
            self._ci->pool()->enqueue(fn () |fid, self, captured_rec| {
                var _kt = kairo::TimeReport::Worker(captured_rec);
                var gs  = self._global_scope;
                var ctx = gs->begin_index(fid);
                if ctx != &null {
                    var indexer = ASTParse(ctx, &null, gs, ASTParse::ParseMode::Index);
                    indexer.index();
                    gs->finish_index(fid);
                }
            }, u8(5));
        }
        self._ci->pool()->wait_group(u8(5));
    }

    // parallel parse + low-water-mark flush
    {
        var _tp = TimeRegion("Full");
        var N          = parse_fids.size();
        var time_rec   = kairo::TimeReport::current();
        var time_sm    = self._ci->sm();
        var time_flush = kairo::TimeReport::region_under(time_rec, r"DiagFlush");
        kairo::TimeReport::mark_idle(time_flush);

        // done[i] published (release) by the parse task for fids[i];
        // read (acquire) by the flusher. Outlives both: the flusher is
        // joined and the parse group drained before this scope ends.
        var done      = libcxx::vector::<std::Atomic::<bool>>(N);
        var done_data = done.data();

        var engine = self._ci->diag();
        var fids_data = parse_fids.data();
        var gs     = self._global_scope;

        // flusher: drains contiguous done-prefix in fid order, single-threaded.
        var flusher = libcxx::thread(fn () |time_rec, time_flush, N, done_data, fids_data, gs, engine| {
            var _kr = kairo::TimeReport::ThreadRoot(time_rec);
            var _kf = kairo::TimeReport::Scope(time_flush);
            var cursor: usize = 0;
            while cursor < N {
                if done_data[cursor].load(libcxx::memory_order_acquire) {
                    var fid: u32 = fids_data[cursor];
                    var ctx = gs->get_context(fid);
                    if ctx != &null { ctx->diag_sink.drain_into(engine, ctx->sm); }
                    ++cursor;
                } else {
                    libcxx::this_thread::yield();
                }
            }
        });

        for var i: usize = 0; i < N; ++i {
            var fid: u32 = parse_fids[i];
            self._ci->pool()->enqueue(fn () |gs, fid, done_data, i, time_rec, time_sm| {
                var _kt = kairo::TimeReport::Worker(time_rec);
                var publish = PublishOnExit(&(done_data[i]));

                var ctx = gs->get_context(fid);
                if ctx != &null {
                    var parser = ASTParse(ctx, &null, gs, ASTParse::ParseMode::Full);
                    var tu     = parser.parse();
                    ctx->tu = reinterpret_cast::<*void>(tu);
                    if time_sm != &null { _kt.units(time_sm->get_file_size(fid), r"B"); }
                }
            }, u8(6));
        }

        self._ci->pool()->wait_group(u8(6));  // all parses done => all done[i] set
        flusher.join();                       // flusher drains tail, exits
    }

    // --- print-ast / mem stats: unchanged -----------------------------------
    var ast_mode = self._ci->invocation().frontend.print_ast;
    if !ast_mode.empty() {
        var use_color = !self._ci->invocation().diag.no_color;
        var opts: PrintOptions;
        if ast_mode == "tree" {
            opts = PrintOptions::dump();
        } else if ast_mode == "flat" {
            opts = PrintOptions::diag();
        } else if ast_mode == "canonical" {
            opts = PrintOptions::canonical();
        } else {
            return self._fatal(DiagID::I010F,
                f"invalid --print-ast value '{ast_mode}'; expected one of: tree, flat, canonical"
            );
        }
        opts.color = use_color;
        for fid: u32 in parse_fids {
            std::print(f"============== AST ({ast_mode}) for fid {fid} ==============");
            var ctx = self._global_scope->get_context(fid);
            if ctx == &null {
                return self._fatal(DiagID::I006F, f"failed to get context for fid {fid}");
            }
            
            var tu = reinterpret_cast::<*TranslationUnit>(ctx->tu);
            if tu == &null {
                return self._fatal(DiagID::I006F, f"parse failed for fid {fid}");
            }
            
            ASTPrinter::print(tu, opts);
        }
    }

    // --- print-symbols: frozen per-DeclContext symbol tables ----------------
    // Styled by the same --print-ast value (default 'tree' -> dump()); when
    // --print-ast is unset we still honor --print-symbols with diag() (flat)
    // rows, since the symbol dump renders decls one-line regardless.
    if self._ci->invocation().frontend.print_symbols {
        var use_color = !self._ci->invocation().diag.no_color;
        var sym_opts: PrintOptions = PrintOptions::diag();
        if      ast_mode == "tree"      { sym_opts = PrintOptions::dump();      }
        else if ast_mode == "canonical" { sym_opts = PrintOptions::canonical(); }
        sym_opts.color = use_color;

        for fid: u32 in parse_fids {
            var ctx = self._global_scope->get_context(fid);
            if ctx == &null { continue; }
            var tu = reinterpret_cast::<*TranslationUnit>(ctx->tu);
            if tu == &null { continue; }
            std::print(f"============== SYMBOLS for fid {fid} ==============");
            self._dump_symbols(tu, ctx, sym_opts);
        }
    }

    // dump the hoisted scope as well
    if !ast_mode.empty() {
        std::print(f"-- hoisted scope: {self.path.full_path()} --");
        self._global_scope->dump();
    }

    self._dump_mem_stats();
    return true;
}

/// Semantic analysis stage: runs the pipeline to its current end (N) over
/// every fid of this TU's graph, then honors the sema dump flags.
/// One group of the sema loop (FrontendAction::_sema): every Kairo TU of
/// \p fids to SemaPhase::Typed, the group's panic sets solved, then each
/// on to Checked, the lowerings and mono, in \p fids's order.
///
/// The group's Semas live until the second pass is done, at addresses that
/// never move: Sema keeps `&self.sc` (and the context `&self.lifecycle`)
/// from its constructor on, so a growing vector of them by value would
/// break both. The arena runs their destructors when the group ends, which
/// for a group of one is where the loop's `sem` used to die.
fn FrontendAction::_sema_group(fids: *vec::<u32>, effects: *EffectTable, print_sema: bool, print_lowered: bool, sema_opts: PrintOptions) {
    var sema_arena: llvm::SpecificBumpPtrAllocator::<Sema>;
    var sems = vec::<*Sema>();
    for var i: usize = 0; i < fids->size(); ++i {
        var fid = (*fids)[i];
        var ctx = self._global_scope->get_context(fid);
        if ctx == &null { continue; }
        var tu = reinterpret_cast::<*TranslationUnit>(ctx->tu);
        if tu == &null { continue; }
        if tu->is_foreign { continue; }   // decls came from clang, already resolved; nothing to run.
        var sem = sema_arena.Allocate(1);
        libcxx::construct_at(sem, ctx, self._global_scope);
        sem->sc.foreign  = self._ci->foreign_instantiate();   // before any pass captures &sem->sc.
        sem->sc.builtins = self._ci->builtins();
        sem->sc.effects  = reinterpret_cast::<*void>(effects);
        // The file this action was asked to compile is a root, and may be a
        // script (SCRIPT.md 1.1); a fid reached through its imports, or a
        // `.k` a C++ input includes (discovered), is a module, whose
        // top-level statement nothing would run. The same answer for kcc and
        // every --emit mode: it depends on the command line, not the output.
        sem->sc.script_root = (fid == self._file_id) && (!self.discovered);
        sems.push_back(sem);
    }

    // One TU goes to Typed in one run, as it always did. The TUs of an
    // import cycle go there in LOCKSTEP, one phase at a time across the
    // group: each phase of one reads what the same phase of the other
    // produced (I folds the other's surface, X calls functions whose
    // parameter types the other's T resolved), and with no order in which
    // every import is finished first, run one TU to Typed ahead of the
    // other and its calls into the other see unresolved types. A TU that
    // stops in a phase (a hard stop in I/N/T) goes no further; the others
    // carry on, as an acyclic importer of it would.
    {
        var _ts = TimeRegion("Sema");
        if sems.size() == 1 {
            sems[0]->run_to(SemaPhase::Typed);
        } else {
            var phases = vec::<SemaPhase>();
            phases.push_back(SemaPhase::ImportsResolved);
            phases.push_back(SemaPhase::Expanded);
            phases.push_back(SemaPhase::Verified);
            phases.push_back(SemaPhase::NamesResolved);
            phases.push_back(SemaPhase::TypesResolved);
            phases.push_back(SemaPhase::Typed);
            var stopped = vec::<bool>();
            for var i: usize = 0; i < sems.size(); ++i { stopped.push_back(false); }
            for var p: usize = 0; p < phases.size(); ++p {
                // T before any ChainBinding of the group: binding walks the
                // other TUs' records through edges their T resolves (G31).
                if phases[p] == SemaPhase::TypesResolved {
                    for var i: usize = 0; i < sems.size(); ++i {
                        if stopped[i] { continue; }
                        if sems[i]->sc.phase == SemaPhase::NamesResolved { sems[i]->resolve_types_pre(); }
                    }
                }
                for var i: usize = 0; i < sems.size(); ++i {
                    if stopped[i] { continue; }
                    // run_to's continuation would carry a stopped TU on past
                    // its hard stop; one that fails a phase is left there.
                    if !sems[i]->run_to(phases[p]) { stopped[i] = true; }
                }
                // Re-exports across the cycle, to a fixpoint: the TU that
                // ran I first folded its sources' re-exports from overlays
                // the others had not built yet (ImportResolution::
                // refold_reexports). Bounded: each round that continues
                // added a target, and the targets are finite.
                if phases[p] == SemaPhase::ImportsResolved {
                    var grew = true;
                    while grew {
                        grew = false;
                        for var i: usize = 0; i < sems.size(); ++i {
                            if stopped[i] { continue; }
                            if ImportResolution(&(sems[i]->sc)).refold_reexports() { grew = true; }
                        }
                    }
                }
            }
        }
    }

    // The barrier. A TU that stopped short of Typed (a hard stop in I/N/T)
    // is not registered: its bodies were never typed, and a call into it
    // says nothing about panics (EffectPropagation, "a set that cannot be
    // known"). A TU that reached Typed with errors is: its poisoned nodes
    // are skipped like everywhere else.
    {
        var _te = TimeRegion("PanicSets");
        effects->reset();
        for var i: usize = 0; i < sems.size(); ++i {
            if static_cast::<u8>(sems[i]->sc.phase) >= static_cast::<u8>(SemaPhase::Typed) {
                effects->add_tu(&(sems[i]->sc));
            }
        }
        effects->solve();
    }

    // The TU that declares the Nullable lang item lowers first: every `T?`
    // in another TU is lowered through its layout, which that TU's
    // EnumLayoutLowering builds. Import order already puts the builtin root
    // ahead of what imports it, except around a cycle: a builtin file the
    // root imports that itself imports alloc.k (which names `T?`) put
    // alloc.k first, and NullTestLowering ICEd on the missing layout.
    var order = vec::<usize>();
    for var i: usize = 0; i < sems.size(); ++i {
        var en = sems[i]->sc.nullable_enum();
        var home = (NameLookup::tu_of(reinterpret_cast::<*DeclContext>(en->semantic_dc))) if (en != &null) else (&null);
        if (home != &null) && (home == sems[i]->sc.tu) { order.push_back(i); break; }
    }
    for var i: usize = 0; i < sems.size(); ++i {
        if (order.size() > 0) && (order[0] == i) { continue; }
        order.push_back(i);
    }

    for var oi: usize = 0; oi < order.size(); ++oi {
        var sem = sems[order[oi]];
        var ctx: *ASTContext = sem->sc.ctx;
        // Through L, not just the checks: OperatorLowering rewrites every user
        // operator into the call it is, and codegen ICEs on any operator node
        // that reaches it. --type-check-only stops here too, so the lowering
        // schedule runs under it and is exercised by the sema tests.
        // The dump is PINNED at Checked: X's output is what --print-sema is
        // about, and a lowering replaces the very nodes it names (a list
        // literal becomes a ctor call, a cast becomes a construction). Run
        // the rest afterwards; --print-lowered is the same dump on the far
        // side, for asserting what a lowering produced.
        // Splitting the run must not lose the hard stop: a stage that
        // returned false has already halted the pipeline, and re-entering
        // would carry on past it -- running the checks and the lowerings over
        // a tree whose names or types never resolved, which is cascade noise
        // by the schedule's own policy (Sema.k::_hard_stop). A TU that
        // stopped before Typed is not continued at all; one that reached it
        // runs the late checks whatever errors it had, as one run did.
        var reached = false;
        if static_cast::<u8>(sem->sc.phase) >= static_cast::<u8>(SemaPhase::Typed) {
            var _ts = TimeRegion("Sema");
            reached = sem->run_to(SemaPhase::Checked);
        }
        if print_sema { SemaDump(&(sem->sc), sema_opts).run(); }
        // Two continuations instead of one run(), only so the timing tree can
        // tell lowering from mono. run_to is re-entrant and _done() is pure,
        // so stopping at Lowered and resuming is the same schedule.
        if reached {
            { var _tl = TimeRegion("Lower"); sem->run_to(SemaPhase::Lowered); }
            { var _tm = TimeRegion("Mono");  sem->run(); }
        }
        // Test hook (Tests/CLI/Driver/ice_flushes_diagnostics.k): an ICE at
        // the worst point for the diagnostics -- Sema done on a TU that
        // reported errors, its sink not yet drained -- so the test proves
        // the ICE path flushes them.
        if (libcxx::getenv(r"KAIRO_DEBUG_FORCE_ICE") != &null) && (ctx->diag_sink.error_count() > 0) {
            ICE_FAIL("forced by KAIRO_DEBUG_FORCE_ICE (a test hook)");
        }
        if ctx->diag_sink.error_count() > 0 { ctx->sema_errored = true; }
        ctx->diag_sink.drain_into(self._ci->diag(), ctx->sm);
        // Kept past `sem`: the batch rejects two scripts in one link.
        if sem->sc.script_at.is_valid() { self.result.script_at = sem->sc.script_at; }
        // Likewise two global allocators. One action compiles every module
        // its input imports, so the second may be in this same loop: that
        // one is reported here, the batch compares actions.
        if (sem->sc.tu != &null) && sem->sc.tu->global_alloc_at.is_valid() {
            var here  = sem->sc.tu->global_alloc_at;
            var hfile = ctx->sm->get_filename(here.start);
            // Its forwarders would be strong kairo_global_* definitions in an
            // object that inlined System for its own allocations: refused
            // here rather than at the link. Only a split build gets here
            // (_settle_global_allocator found it otherwise).
            if (!self._ci->invocation().pp.global_allocator_set) && (!self._ci->invocation().frontend.stops_before_codegen()) {
                var hname = Path(hfile).filename();
                var mac   = LowerTargets::global_alloc_set_macro();
                var d = self._ci->diag()->report(DiagID::SC001E, here.start,
                    f"'{hname}' sets the global allocator, but this build does not define {mac}; pass --global-allocator-set when compiling the program's files separately");
                d.first(here);
                d.emit();
            }
            if !self.result.global_alloc_at.is_valid() {
                self.result.global_alloc_at   = here;
                self.result.global_alloc_file = hfile;
            } else if self.result.global_alloc_file != hfile {
                var first = self.result.global_alloc_at;
                var a = Path(self.result.global_alloc_file).filename();
                var b = Path(hfile).filename();
                var d = self._ci->diag()->report(DiagID::SC001E, here.start,
                    f"two files set the global allocator: '{b}' and '{a}'; a program has one");
                d.first(here);
                d.note(DiagID::SC001N, first.start, f"'{a}' sets it here").first(first);
                d.emit();
            }
        }

        // Dump INSIDE the loop: SemaDump reads sc.phase / sc.well_known, which
        // live on this fid's SemaContext and die with the arena.
        if print_lowered {
            std::print(f"-- lowered: {self.path.full_path()} --");
            SemaDump(&(sem->sc), sema_opts).run();
        }
    }
}

/// The import graph of one action cut into the groups the sema loop runs
/// together: its strongly connected components, each placed after every
/// component it imports, in the order the loop already used (`order`,
/// _import_order) wherever that order holds. With no import cycle every
/// component is one fid and the groups are `order` itself.
class ImportGroups {
    pub var fids:   vec::<u32>;     ///< every fid, group by group.
    pub var starts: vec::<usize>;   ///< group g is fids[starts[g] .. starts[g + 1]).
    priv var _order: vec::<u32>;
    priv var _adj:   vec::<usize>;  ///< the imports of order[i], as indices: _adj[_adj_at[i] .. _adj_at[i + 1]).
    priv var _adj_at: vec::<usize>;
    priv var _reach: vec::<bool>;   ///< n*n: order[i] reaches order[j] through imports.
    priv var _done:  vec::<bool>;

    fn ImportGroups(self) { }

    fn build(self, order: *vec::<u32>, gs: *GlobalDisambigTable) {
        var n = order->size();
        self._order = *order;
        // Index by fid, WIDENED: an edge's target can be u32(-1), DenseMap's
        // empty key (_import_order has the same note).
        var at = llvm::DenseMap::<u64, u64>();
        for var i: usize = 0; i < n; ++i { at[static_cast::<u64>((*order)[i])] = static_cast::<u64>(i); }
        for var i: usize = 0; i < n; ++i {
            self._adj_at.push_back(self._adj.size());
            var ctx = gs->get_context((*order)[i]);
            var tu: *TranslationUnit = &null;
            if ctx != &null { tu = reinterpret_cast::<*TranslationUnit>(ctx->tu); }
            if tu == &null { continue; }
            for var j: usize = 0; j < tu->import_edges.size(); ++j {
                var e = tu->import_edges.get(j);
                if e == &null { continue; }
                var it = at.find(static_cast::<u64>(e->target_fid));
                if it == at.end() { continue; }
                var k = static_cast::<usize>(it->second);
                if k != i { self._adj.push_back(k); }
            }
        }
        self._adj_at.push_back(self._adj.size());

        // Reachability by one walk from each fid: graphs are small, and a
        // component is then "reaches and is reached by".
        for var i: usize = 0; i < n * n; ++i { self._reach.push_back(false); }
        for var i: usize = 0; i < n; ++i {
            var stack = vec::<usize>();
            stack.push_back(i);
            while stack.size() > 0 {
                var v = stack[stack.size() - 1];
                stack.pop_back();
                for var a: usize = self._adj_at[v]; a < self._adj_at[v + 1]; ++a {
                    var w = self._adj[a];
                    if self._reach[i * n + w] { continue; }
                    self._reach[i * n + w] = true;
                    stack.push_back(w);
                }
            }
        }
        for var i: usize = 0; i < n; ++i { self._done.push_back(false); }
        for var i: usize = 0; i < n; ++i { self._place(i); }
        self.starts.push_back(self.fids.size());
    }

    priv fn _same(self, i: usize, j: usize) -> bool {
        if i == j { return true; }
        var n = self._order.size();
        return self._reach[i * n + j] && self._reach[j * n + i];
    }

    /// Place \p i's component after every component it imports. Its members
    /// are marked first: no import of another component can lead back into
    /// this one (it would be in it), so the recursion ends.
    priv fn _place(self, i: usize) {
        if self._done[i] { return; }
        var n = self._order.size();
        var members = vec::<usize>();
        for var j: usize = 0; j < n; ++j {
            if self._same(i, j) { members.push_back(j); self._done[j] = true; }
        }
        for var m: usize = 0; m < members.size(); ++m {
            var v = members[m];
            for var a: usize = self._adj_at[v]; a < self._adj_at[v + 1]; ++a {
                var w = self._adj[a];
                if !self._same(i, w) { self._place(w); }
            }
        }
        self.starts.push_back(self.fids.size());
        for var m: usize = 0; m < members.size(); ++m { self.fids.push_back(self._order[members[m]]); }
    }
}

fn FrontendAction::_sema() -> bool {
    // Timed per piece, not as one region: this function also runs the FFI
    // header join, the lowerings and mono, none of which is semantic
    // analysis, and a "Sema" row that contained them misreported all three.
    self._stage = TUStage::Sema;
    var fe = self._ci->invocation().frontend;
    // --dump-type-info has no consumer: SemaDump's expression-types section is
    // private to its whole-TU walk, so there is no cheap per-expression hook
    // here. It is marked unimplemented centrally rather than faking a header.

    // --print-sema styling follows --print-ast, exactly like --print-symbols:
    // 'tree' -> dump(), 'canonical' -> canonical(), otherwise flat diag rows.
    var sema_opts: PrintOptions = PrintOptions::diag();
    if fe.print_sema || fe.print_lowered {
        var ast_mode = fe.print_ast;
        if      ast_mode == "tree"      { sema_opts = PrintOptions::dump();      }
        else if ast_mode == "canonical" { sema_opts = PrintOptions::canonical(); }
        sema_opts.color = !self._ci->invocation().diag.no_color;
    }
    if fe.print_sema { std::print(f"-- sema: {self.path.full_path()} --"); }

    // Phase A of header import joins here. Every set requested during
    // preprocess must be PARSED before it can be indexed, and INDEXED before
    // phase I of any importer folds its headers. Indexing mints the header
    // fids, so it runs on this (driver) thread; _attach_ffi_edges then stamps
    // each ffi ImportDecl with the closure it imports.
    // The runtime's C objects need nothing from Kairo: compile them on the
    // pool now, while the serial Sema below leaves it idle (P380).
    self._ci->prestart_runtime();

    var hc = self._ci->headers();
    if hc != &null {
        var _th = TimeRegion("Headers");
        {
            var _tw = TimeRegion("HeaderSetWait");
            hc->wait_all();
        }
        for fid: u32 in self._fids {
            var hctx = self._global_scope->get_context(fid);
            if hctx == &null { continue; }
            var htu = reinterpret_cast::<*TranslationUnit>(hctx->tu);
            if (htu == &null) || (htu->header_set == &null) { continue; }
            var view = reinterpret_cast::<*HeaderSet>(htu->header_set);
            // P417: a view's headers were parsed in the build's one shared
            // set; from here on the TU's set IS that set, and only the ffi
            // closures below still read which file the view's spelling meant.
            var hs = view;
            if view->shared != &null { hs = view->shared; }
            self._ci->header_index()->index(hs);
            // The set's build-time clang diagnostics, buffered on the pool
            // thread (HeaderSet::diag_buf): into the engine now the build
            // has joined. A set shared by several TUs drains once.
            hs->drain_diags(self._ci->diag(), self._ci->sm());
            self._attach_ffi_edges(htu, hctx, hs, view);
            htu->header_set = reinterpret_cast::<*void>(hs);
        }
        // Phase B's merged PCH needs nothing but the sets that just joined:
        // build it on the pool now, overlapping Sema and the lowerings,
        // rather than on the driver thread when codegen starts (about 45 ms
        // there on a hello-sized program). _codegen joins it.
        if !fe.stops_before_codegen() {
            var gsets = self._graph_header_sets();
            if gsets.size() > 0 { hc->prebuild_codegen_pch(gsets, kairo::TimeReport::current()); }
        }
    }

    // Clang builtins, the fourth source of unqualified names. Here because
    // init mints a foreign TU (HeaderIndex writes the SM and the global
    // table: driver thread only) and must finish before the first
    // SemaContext. Outside the header block on purpose: a TU that imports
    // no C++ can still call `__builtin_expect`.
    //
    // startup() is idempotent and joins the pool task through the backend's
    // mutex; it is normally long done by now. Timed apart from init so a
    // stall reads as what it is.
    {
        var be = self._ci->backend();
        var bi = self._ci->builtins();
        if (be != &null) && (bi != &null) {
            {
                var _tj = TimeRegion("BuiltinStartupJoin");
                be->startup();
            }
            bi->init(be->oracle(), self._ci->sm(), self._ci->header_index(),
                     self._global_scope, self._ci->foreign_registry());
        }
    }

    // The PRELUDE, as a real ImportDecl. The PP folded the builtin root into
    // the import GRAPH, so it is parsed, ordered and admitted -- but a graph
    // edge binds no NAMES: phase I builds a TU's overlay from tu->imports and
    // nothing else, so without this every user TU sees an empty builtin
    // surface and `string` fails to resolve.
    //
    // Injected HERE because this is the one point where both halves exist:
    // ctx->tu is set by the parse above, and phase I runs just below.
    //
    // resolved_fid is stamped rather than resolved. FileImportIndex resolves a
    // path by SPELLING path_segments, and a synthesized node has none to
    // spell; a wildcard fold reads resolved_fid and never looks at the path.
    //
    // MARKING is not gated on --no-builtins, only injection is: that flag
    // suppresses the implicit import, not the builtin root's own compilation.
    // The builtin files are still parsed and type-resolved either way, and an
    // unmarked one resolves `[T;]` against an empty lang-item table and
    // reports the item missing from inside Lib/builtin itself.
    var bfid = self._global_scope->builtin_fid();
    if bfid != 0 {
        var bsym   = self._ci->pp()->get_symbol_table()->intern(builtin_root_name());
        var inject = !self._ci->invocation().pp.no_builtins;
        self._global_scope->mark_builtin_fid(bfid);   // the loop skips the root below.

        // alloc.k (`builtin::base::alloc`), when the PP put it in the graph
        // for a file that writes `@create` / `@destroy` (P91).
        var afid = u32(-1);
        {
            var s_base  = self._ci->pp()->get_symbol_table()->intern("base");
            var s_alloc = self._ci->pp()->get_symbol_table()->intern("alloc");
            for var i: usize = 0; i < self._fids.size(); ++i {
                var actx = self._global_scope->get_context(self._fids[i]);
                if actx == &null { continue; }
                var asg = &(actx->module_base.segments);
                if asg->size() != 3 { continue; }
                if ((*asg)[0].name == bsym) && ((*asg)[1].name == s_base) && ((*asg)[2].name == s_alloc) {
                    afid = self._fids[i];
                    break;
                }
            }
        }
        {
            for var i: usize = 0; i < self._fids.size(); ++i {
                var fid = self._fids[i];
                if fid == bfid { continue; }      // the builtin root is its own prelude
                var pctx = self._global_scope->get_context(fid);
                if pctx == &null { continue; }
                var ptu = reinterpret_cast::<*TranslationUnit>(pctx->tu);
                if ptu == &null { continue; }
                if ptu->is_foreign { continue; }  // clang-owned; it has no Kairo overlay.

                // Every file UNDER the builtin root is part of the prelude
                // rather than a consumer of it. Injecting there would make
                // builtin reach itself by a second path, and the re-export
                // fold would then depend on its own overlay being complete.
                var psegs = &(pctx->module_base.segments);
                if psegs->size() > 0 {
                    var phead = (*psegs)[0];
                    if phead.name == bsym {
                        self._global_scope->mark_builtin_fid(fid);
                        continue;
                    }
                }

                if !inject { continue; }

                // The file's start, as the std alias below takes it (see there
                // for why not SourceLocation::from_base(fid, 0)).
                var prng = SourceRange::invalid();
                if pctx->sm != &null {
                    var ploc = pctx->sm->get_loc(fid, 0);
                    prng = SourceRange(ploc, ploc);
                }
                var pid  = ImportDecl::create(pctx, prng, ImportKind::Native);
                pid->is_wildcard    = true;
                pid->is_prelude     = true;
                pid->resolved_fid   = bfid;
                pid->file_seg_count = 1;
                ptu->imports.push(static_cast::<*Decl>(pid));

                var pedge = ImportEdge{};
                pedge.target_fid = bfid;
                pedge.decl       = static_cast::<*Decl>(pid);
                ptu->import_edges.push(pedge);

                // `@create` / `@destroy` lower to alloc.k's create / destroy
                // pre-bound (AllocSugarDesugar), so this TU must be typed
                // AFTER alloc.k, whose N fills the lang item: an edge orders
                // that (_import_order reads import_edges). The ImportDecl
                // binds NO name -- plain, with no path segments, so phase I's
                // _fold_plain has no handle to bind -- and a hand-written
                // `create<T>()` with no import is still undeclared.
                if (afid != u32(-1)) && (afid != fid) && ptu->has_alloc_sugar {
                    var aid = ImportDecl::create(pctx, prng, ImportKind::Native);
                    aid->is_prelude     = true;
                    aid->resolved_fid   = afid;
                    aid->file_seg_count = 1;
                    ptu->imports.push(static_cast::<*Decl>(aid));
                    var aedge = ImportEdge{};
                    aedge.target_fid = afid;
                    aedge.decl       = static_cast::<*Decl>(aid);
                    ptu->import_edges.push(aedge);
                }
            }
        }
    }

    // --prelude <file> / --force-include <file>: the PP folded each file into
    // the import GRAPH, which orders and parses it but binds no names (see the
    // builtin note above), so without a real wildcard ImportDecl the entry TU
    // reports every one of their declarations as undeclared (R020E).
    //
    // The ENTRY TU only, not every fid: a force-included file may itself import
    // helper modules, and injecting its wildcard into those would close a cycle
    // in the overlay fold. Flags apply per input file, so each input's own
    // action gets its own injection. load_file is a cache hit here (the PP
    // loaded the same paths), so this re-derives the fids without PP state.
    {
        var xfids = vec::<u32>();
        if (!self._ci->invocation().pp.no_prelude) && (self._ci->invocation().pp.prelude_path.size() > 0) {
            xfids.push_back(self._ci->sm()->load_file(Path(self._ci->invocation().pp.prelude_path)));
        }
        for xpath: string in self._ci->invocation().pp.force_includes {
            xfids.push_back(self._ci->sm()->load_file(Path(xpath)));
        }
        var xctx = self._global_scope->get_context(self._file_id);
        if (xfids.size() > 0) && (xctx != &null) {
            var xtu = reinterpret_cast::<*TranslationUnit>(xctx->tu);
            if (xtu != &null) && (!xtu->is_foreign) {
                var xrng = SourceRange::invalid();
                if xctx->sm != &null {
                    var xloc = xctx->sm->get_loc(self._file_id, 0);
                    xrng = SourceRange(xloc, xloc);
                }
                for var xi: usize = 0; xi < xfids.size(); ++xi {
                    var xf = xfids[xi];
                    // u32(-1): load_file already reported the missing path.
                    // A self-include is a no-op, not a self-edge.
                    if (xf == u32(-1)) || (xf == 0) || (xf == self._file_id) { continue; }
                    var xid = ImportDecl::create(xctx, xrng, ImportKind::Native);
                    xid->is_wildcard    = true;
                    xid->is_prelude     = true;
                    xid->resolved_fid   = xf;
                    xid->file_seg_count = 1;
                    xtu->imports.push(static_cast::<*Decl>(xid));

                    var xedge = ImportEdge{};
                    xedge.target_fid = xf;
                    xedge.decl       = static_cast::<*Decl>(xid);
                    xtu->import_edges.push(xedge);
                }
            }
        }
    }

    // Phases I -> E -> V -> N -> T -> checks (ImportResolution, Expand,
    // Verify, NameResolution, TypeResolution/ChainBinding, then the
    // signature/layout checks) across every fid of this TU's graph. Run in
    // REVERSE tree order so leaf modules build their overlays before
    // importers fold re-exports (DAG order guarantees source-overlay
    // completeness, RESOLUTION.md #2). Each TU runs to Typed, then (past
    // the panic-set barrier) through the late checks, the lowerings and
    // M1 / M2 (_sema_group).
    var n     = self._fids.size();
    var order = self._import_order();

    // The panic-set barrier (PANIC.md §2.2, RESOLUTION.md "The Typed
    // barrier"). A set is the union of its callees' sets, and a callee is
    // only ever in the caller's import closure, so a TU's sets are final
    // once every TU it reaches through imports is typed. In import order
    // that holds for free -- except inside an import CYCLE (a.k and b.k
    // importing each other type-check today), which has no order in which
    // every callee is finished first. So the graph runs in groups, one per
    // strongly connected component of the import graph: every TU of a group
    // goes to SemaPhase::Typed, the group's sets are solved at once, and
    // then each goes on. A group is one TU everywhere there is no cycle, and
    // that is exactly the loop as it was.
    var groups = ImportGroups();
    groups.build(&order, self._global_scope);
    // A header set nothing imported points into (HeaderSet::contributed is
    // false: 85 of the self-host graph's 115) is still each owning TU's
    // fallback for a fill or a deduction its first set cannot spell (G58,
    // G101), and only during that TU's Sema. So it is freed once the last
    // TU owning it has run its group, instead of at exit (~200 MB each,
    // P380). One action only: a later input's graph may own it too.
    var early_release = (self._ci->kairo_only_input_count() == 1) && (!self._ci->kairo_feeds_includes())
                        && (self._ci->headers() != &null);
    var set_owners = llvm::DenseMap::<u64, u64>();
    if early_release {
        for fid: u32 in self._fids {
            var octx = self._global_scope->get_context(fid);
            if octx == &null { continue; }
            var otu = reinterpret_cast::<*TranslationUnit>(octx->tu);
            if (otu == &null) || (otu->header_set == &null) { continue; }
            set_owners[reinterpret_cast::<u64>(otu->header_set)] += 1;
        }
    }
    var effects: EffectTable;
    for var g: usize = 0; g + 1 < groups.starts.size(); ++g {
        var members = vec::<u32>();
        for var k: usize = groups.starts[g]; k < groups.starts[g + 1]; ++k { members.push_back(groups.fids[k]); }
        self._sema_group(&members, &effects, fe.print_sema, fe.print_lowered, sema_opts);
        if !early_release { continue; }
        for fid: u32 in members {
            var mctx = self._global_scope->get_context(fid);
            if mctx == &null { continue; }
            var mtu = reinterpret_cast::<*TranslationUnit>(mctx->tu);
            if (mtu == &null) || (mtu->header_set == &null) { continue; }
            var key = reinterpret_cast::<u64>(mtu->header_set);
            var it = set_owners.find(key);
            if (it == set_owners.end()) || (it->second == 0) { continue; }
            it->second -= 1;
            if it->second == 0 { reinterpret_cast::<*HeaderSet>(mtu->header_set)->release_unused(); }
        }
    }

    if fe.print_imports { self._dump_overlays(); }
    if fe.print_panic_sets { self._dump_panic_sets(); }

    // The EmitPlan is codegen's, but it reads only sema's resolved links, so
    // it can be built and dumped here without a backend. That is what makes
    // it testable at all today: EmitIR cannot yet emit a record, so a full
    // codegen run over a file with a class never reaches the plan.
    if fe.print_emit_plan {
        for var i: usize = 0; i < n; ++i {
            var fid = self._fids[n - 1 - i];
            var ctx = self._global_scope->get_context(fid);
            if ctx == &null { continue; }
            var tu = reinterpret_cast::<*TranslationUnit>(ctx->tu);
            if tu == &null { continue; }
            var psym = self._ci->pp()->get_symbol_table();
            var cg = CodegenContext(ctx, &null, psym, self._global_scope->instances());
            var plan = EmitPlan(&cg, PlanMode::Preamble);
            plan.run();
            plan.dump(self._ci->sm()->get_filename(fid));

            // The header root set too (own pub decls, no uses), so both
            // are golden-testable from one flag. A pathless TU has no
            // header (EmitCXXHeader skips it), so its dump would be noise.
            if CXXSpell::is_entry_tu(tu) { continue; }
            var hcg = CodegenContext(ctx, &null, psym, self._global_scope->instances());
            var hplan = EmitPlan(&hcg, PlanMode::Header);
            hplan.run();
            hplan.dump(self._ci->sm()->get_filename(fid));
        }
    }

    // The interface text needs no clang either, so it is produced here and
    // works under --type-check-only. A header now carries the module's
    // inline and template bodies (EmitCXXHeader), so --emit-headers runs
    // EmitIR over them and ICEs on any such body EmitIR cannot emit yet, as a
    // full codegen run would.
    // A sibling loop, not the plan loop: that one skips a pathless TU before
    // its header dump, and a pathless TU still has a preamble.
    if fe.print_cxx || (!fe.emit_headers.empty()) {
        for var i: usize = 0; i < n; ++i {
            var fid = self._fids[n - 1 - i];
            var ctx = self._global_scope->get_context(fid);
            if ctx == &null { continue; }
            var tu = reinterpret_cast::<*TranslationUnit>(ctx->tu);
            if tu == &null { continue; }
            // An empty TU prints nothing, not even its banner: a module that
            // only re-exports must not change a golden.
            if fe.print_cxx && (!self._tu_is_empty(fid)) {
                var ts  = TextSink(self._ci->sm(), self._ci->tcm());
                var tcg = CodegenContext(ctx, &ts, self._ci->pp()->get_symbol_table(), self._global_scope->instances());
                var tplan = EmitPlan(&tcg, PlanMode::Preamble);
                tplan.run();
                tcg.advance_phase(CodegenPhase::Planned);
                InterfaceEmitter(&tcg, &tplan).run();
                std::print(f"============== CXX PREAMBLE fid {fid}: {self._ci->sm()->get_filename(fid)} ==============");
                std::print(ts.out);
            }
            // EmitCXXHeader skips the entry TU and writes nothing for it.
            // Nor after an error: the bodies it emits need a lowered tree,
            // and sema stops short of lowering once anything fails.
            if (!fe.emit_headers.empty()) && (!self._ci->diag()->has_errors()) {
                var h = EmitCXXHeader(ctx, self._ci->pp()->get_symbol_table(), self._global_scope->instances());
                if h.write(fe.emit_headers) {
                    Logger::info(Logger::Stage::Driver, f"emitted header {h.path_under(fe.emit_headers)}");
                } else if h.render().size() > 0 {
                    // write() is false both for a TU with no header (the entry
                    // TU) and for a failed write; only the second has text. An
                    // unwritable --emit-headers dir used to exit 0 silently.
                    self._ci->diag()->report(DiagID::U001E,
                        f"cannot write C++ header '{h.path_under(fe.emit_headers)}\x27").emit();
                }
            }
        }
    }

    // TODO(sema): full pipeline once N/T/checks land: Sema(ctx, gs).run().
    return true;
}

/// \p fid has nothing to define (EmitPlan::is_empty, on the preamble plan).
/// A fid with no context or TU is not empty -- it is not a Kairo TU at all,
/// and the callers already skip those -- so this answers only for real ones.
/// The header sets of every TU in the graph, in graph order, each once:
/// what phase B's merged PCH holds. One helper for the early build in
/// _sema and the lookup in _codegen, so both name the same list.
fn FrontendAction::_graph_header_sets() -> vec::<*HeaderSet> {
    var out = vec::<*HeaderSet>();
    for other: u32 in self._graph {
        var sctx = self._global_scope->get_context(other);
        if sctx == &null { continue; }
        var stu = reinterpret_cast::<*TranslationUnit>(sctx->tu);
        if (stu == &null) || (stu->header_set == &null) { continue; }
        var hs  = reinterpret_cast::<*HeaderSet>(stu->header_set);
        var dup = false;
        for var j: usize = 0; j < out.size(); ++j { if out[j] == hs { dup = true; break; } }
        if !dup { out.push_back(hs); }
    }
    return out;
}

fn FrontendAction::_tu_is_empty(fid: u32) -> bool {
    var ctx = self._global_scope->get_context(fid);
    if (ctx == &null) || (ctx->tu == &null) { return false; }
    var cg   = CodegenContext(ctx, &null, self._ci->pp()->get_symbol_table(), self._global_scope->instances());
    var plan = EmitPlan(&cg, PlanMode::Preamble);
    plan.run();
    return plan.is_empty();
}

/// Every fid of the graph, each after everything it imports.
///
/// Reversing `_fids` is not that order: it is a tree walk, so reversed it
/// puts a later SIBLING first. `module.k` imports `string` before `fmt`
/// (now fmt/fmt_buf.k), and reversed, `fmt` was typed before `string` had
/// resolved -- every `s.len` on a `string` came out unknown, without an
/// error, and reached codegen untyped. A fid is placed once each fid it imports (in this graph)
/// is placed; imports are acyclic, but should a pass place nothing the rest
/// go in the old reverse order rather than be dropped.
fn FrontendAction::_import_order() -> vec::<u32> {
    var n      = self._fids.size();
    var order  = vec::<u32>();
    // Membership only (order comes from the _fids walk). Keyed by the fid
    // WIDENED: an import edge's target_fid can be u32(-1), DenseSet<u32>'s
    // empty key, and even a find with it asserts.
    var placed = llvm::DenseSet::<u64>();
    var in_set = llvm::DenseSet::<u64>();
    for var i: usize = 0; i < n; ++i { in_set.insert(static_cast::<u64>(self._fids[i])); }

    while order.size() < n {
        var progressed = false;
        for var i: usize = 0; i < n; ++i {
            var fid = self._fids[n - 1 - i];
            if placed.contains(static_cast::<u64>(fid)) { continue; }
            var ready = true;
            var ctx = self._global_scope->get_context(fid);
            var tu: *TranslationUnit = &null;
            if ctx != &null { tu = reinterpret_cast::<*TranslationUnit>(ctx->tu); }
            if tu != &null {
                for var j: usize = 0; j < tu->import_edges.size(); ++j {
                    var e = tu->import_edges.get(j);
                    if e == &null { continue; }
                    var t = e->target_fid;
                    if (t == fid) || (!in_set.contains(static_cast::<u64>(t))) { continue; }
                    if !placed.contains(static_cast::<u64>(t)) { ready = false; break; }
                }
            }
            if !ready { continue; }
            order.push_back(fid);
            placed.insert(static_cast::<u64>(fid));
            progressed = true;
        }
        // Stuck on an import cycle: break it at ONE file and keep sorting.
        // Placing every remaining file at once in list order would drop the
        // dependency order for the whole rest of the program -- and the
        // builtin prelude has a cycle (module.k -> containers -> alloc.k ->
        // module.k for Nullable), so every program would hit it.
        // ImportGroups keeps each cycle's members together either way.
        if !progressed {
            for var i: usize = 0; i < n; ++i {
                var fid = self._fids[n - 1 - i];
                if placed.find(fid) == placed.end() { order.push_back(fid); placed.insert(fid); break; }
            }
        }
    }
    return order;
}

/// Stamp every ffi ImportDecl of \p tu with what its header resolved to in
/// \p hs: resolved_fid (the header's own fid), the closure fids phase I folds,
/// and one ImportEdge per closure header, so the import graph (importers_of,
/// release's inbound-edge guard) sees a header the way it sees a Kairo file.
/// A spelling clang never resolved leaves resolved_fid 0 and no edges.
/// \p hs is the set the TU's headers were parsed in; \p view the TU's own
/// list, which is \p hs unless the build parsed every list as one (P417):
/// then a spelling is first resolved as the view's own parse resolved it.
fn FrontendAction::_attach_ffi_edges(tu: *TranslationUnit, ctx: *ASTContext, hs: *HeaderSet, view: *HeaderSet) {
    for var i: usize = 0; i < tu->imports.size(); ++i {
        var slot = tu->imports[i];
        if slot == &null { continue; }
        var id = dyn_cast::<ImportDecl>(*slot);
        if (id == &null) || (!id->has_ffi_linkage()) { continue; }
        // Before the stamp-once skip: each action reports it for its link.
        var hdr = HeaderSet::unquote(ctx->get_spelling(id->header));
        if hdr == "pthread.h" { self.result.ffi_pthread = true; }
        // A fid shared by two inputs' graphs reaches here twice; stamp once.
        if id->ffi_closure_fids.size() > 0 { continue; }

        var key = hdr;
        if view != hs { key = HeaderSetCache::resolve_spelling(view, hdr); }
        var ks = hs->closure_kfids(key);
        for var p: usize = 0; p < ks->size(); ++p {
            var k = (*ks)[p];
            if id->ffi_closure_fids.size() == 0 { id->resolved_fid = k; }
            id->ffi_closure_fids.push_back(k);
            var e = ImportEdge{};
            e.target_fid = k;
            e.decl       = static_cast::<*Decl>(id);
            tu->import_edges.push(e);
        }
        id->file_seg_count = 0;
    }
}

fn FrontendAction::_codegen() -> bool {
    var _t = TimeRegion("Codegen");

    self._stage = TUStage::Codegen;

    {
        var _tw = TimeRegion("ClangStartupWait");
        self._ci->pool()->wait_group(CLANG_STARTUP_GROUP());
    }

    // A TU Sema reported errors against is emitted by nobody, and neither is
    // anything that imports it: its decls are poisoned or were never lowered
    // (a field initializer FieldInitLowering skipped), and the emitters'
    // guards would ICE and abort the batch, hiding every other diagnostic.
    // Its errors are already in the engine, so the batch fails on those.
    // Walked through the import edges, not _fids: that holds only the fids
    // THIS action claimed, and a TU an earlier input already analysed (and
    // reported) is one this graph imports but does not own.
    {
        var seen  = llvm::DenseSet::<u64>();
        var stack = vec::<u32>();
        for fid: u32 in self._fids { stack.push_back(fid); seen.insert(static_cast::<u64>(fid)); }
        while stack.size() > 0 {
            var fid = stack.back();
            stack.pop_back();
            var ectx = self._global_scope->get_context(fid);
            if ectx == &null { continue; }
            if ectx->sema_errored {
                Logger::info(Logger::Stage::Driver, f"codegen: skipped, {self._ci->sm()->get_filename(fid)} had errors");
                self._stage = TUStage::Failed;
                return false;
            }
            var etu = reinterpret_cast::<*TranslationUnit>(ectx->tu);
            if etu == &null { continue; }
            for var j: usize = 0; j < etu->import_edges.size(); ++j {
                var e = etu->import_edges.get(j);
                if e == &null { continue; }
                var t = e->target_fid;
                if t == u32(-1) { continue; }
                if seen.contains(static_cast::<u64>(t)) { continue; }
                seen.insert(static_cast::<u64>(t));
                stack.push_back(t);
            }
        }
    }

    var be = self._ci->backend();
    if (be == &null) || (!be->ready()) {
        return self._fatal(DiagID::I006F, "clang backend not ready");
    }

    var fe    = self._ci->invocation().frontend;
    var psym  = self._ci->pp()->get_symbol_table();
    var insts = self._global_scope->instances();

    // One object per Kairo TU with something to define. Foreign fids are C++
    // headers: clang parsed them, nothing is emitted for them.
    var own = vec::<u32>();
    var n   = self._fids.size();
    var any_kairo = false;
    // --emit-scope=inputs: this action's own file only, and nothing for a
    // discovered one (a header to this run). The rest is analysed for it.
    var inputs_only = self._ci->invocation().linker.inputs_only();
    var cand = vec::<u32>();
    for var i: usize = 0; i < n; ++i {
        var f = self._fids[n - 1 - i];   // reverse tree order: imports before importers.
        if self._ci->is_foreign_fid(f) { continue; }
        any_kairo = true;
        if inputs_only && ((f != self._file_id) || self.discovered) { continue; }
        cand.push_back(f);
    }
    // An empty TU -- zero bytes, comments, only `pub import`s -- has done
    // all it can (it resolved as an import, it passed sema). Decided on
    // the PLAN, before any backend or anchor exists for it, so it gets no
    // CodegenBackend, no clang run and no object.
    //
    // A plan's one in-place write that other plans read is the entry TU's
    // cxx_escaping (prepare_shared); made first, serially and in this order,
    // the plans are then read-only and run side by side, as the codegen
    // workers run them. They were one serial plan per TU on this thread,
    // seconds on a large graph (P380). Verdicts are read back in order.
    {
        var psym0 = self._ci->pp()->get_symbol_table();
        var inst0 = self._global_scope->instances();
        for f: u32 in cand {
            var sctx = self._global_scope->get_context(f);
            if (sctx == &null) || (sctx->tu == &null) { continue; }
            var scg  = CodegenContext(sctx, &null, psym0, inst0);
            var sprep = EmitPlan(&scg, PlanMode::Header);
            sprep.prepare_shared();
        }
    }
    var empty = vec::<u8>();
    for var i: usize = 0; i < cand.size(); ++i { empty.push_back(u8(0)); }
    {
        var e_p  = empty.data();
        var c_p  = cand.data();
        var me   = &self;
        for var i: usize = 0; i < cand.size(); ++i {
            self._ci->pool()->enqueue(fn () |e_p, c_p, me, i| {
                if me->_tu_is_empty(c_p[i]) { e_p[i] = u8(1); }
            }, u8(14));   // the emptiness plans.
        }
        self._ci->pool()->wait_group(u8(14));
    }
    for var i: usize = 0; i < cand.size(); ++i {
        var f = cand[i];
        if empty[i] != u8(0) {
            Logger::info(Logger::Stage::Driver, f"nothing to define in {self._ci->sm()->get_filename(f)}; no object");
            continue;
        }
        own.push_back(f);
    }
    if !any_kairo {
        return self._fatal(DiagID::I006F, "codegen: no Kairo translation unit to emit");
    }

    // -o under -c names the one object; a graph emits several, and they go
    // to --cache-dir. A linking run never has a single object here: -o is
    // the executable then.
    // What each TU writes (--emit), all under the object dir, one
    // ExecuteAction each. The extension is the kind's.
    var kinds = vec::<EmitKind>();
    var exts  = vec::<string>();
    if fe.emit_obj     { kinds.push_back(EmitKind::Obj);    exts.push_back(".o");  }
    if fe.emit_asm     { kinds.push_back(EmitKind::Asm);    exts.push_back(".s");  }
    if fe.emit_llvm_ir { kinds.push_back(EmitKind::LLVMIR); exts.push_back(".ll"); }
    if fe.emit_llvm_bc { kinds.push_back(EmitKind::LLVMBC); exts.push_back(".bc"); }
    if kinds.size() == 0 {
        return self._fatal(DiagID::I004F, "--emit names no output to write");
    }

    // -o names the one USER translation unit's output. The prelude (builtin,
    // std) and any imported module are separate TUs in `own` too, but they are
    // not what -o is about: they go under the object dir. So the I004F count
    // is user inputs and kinds, never `own`, which always holds the prelude.
    var single_obj = self._ci->single_object();
    if (!single_obj.empty()) {
        var n_out = self._ci->kairo_input_count() * kinds.size();
        if n_out > 1 {
            return self._fatal(DiagID::I004F,
                f"-o {single_obj} names one output, but this build emits {n_out}; use --cache-dir <dir> for them");
        }
    }
    var obj_dir = self._ci->object_dir();

    // Every TU loads the same headers: the whole graph's sets, in graph
    // order, as one PCH (CodegenPCH). Normally already built on the pool
    // during Sema (prebuild_codegen_pch); else built here, before the first
    // TU.
    var graph_sets = self._graph_header_sets();
    var merged: *CodegenPCH = &null;
    // Also for ONE set (P380): the sets write no PCH of their own now.
    if (graph_sets.size() > 0) && (self._ci->headers() != &null) {
        self._ci->headers()->wait_all();
        {
            var _tw = TimeRegion("CodegenPCHWait");
            self._ci->headers()->wait_codegen_pch();
        }
        merged = self._ci->headers()->codegen_pch(graph_sets);
    }

    // Pre-pass, driver thread: every decision about a TU (its output paths,
    // its header sets), so the per-TU compile below reads nothing it shares
    // with another TU except what is read-only from here on.
    var crun = CodegenRun();
    crun.be        = be;
    crun.psym      = psym;
    crun.instances = insts;
    crun.merged    = merged;
    var jobs = vec::<*CodegenJob>();
    var all_sets = vec::<*HeaderSet>();
    var used_stems = vec::<string>();
    for fid: u32 in own {
        var ctx = self._global_scope->get_context(fid);
        if ctx == &null {
            for j: *CodegenJob in jobs { std::destroy(j); }
            return self._fatal(DiagID::I006F, "codegen: no ASTContext for a Kairo fid");
        }
        var ksize = static_cast::<u32>(self._ci->sm()->get_file_size(fid));

        // The output path mirrors the module path, so two modules of the
        // same leaf name do not collide. A pathless TU (outside every search
        // dir) is named by its file stem instead.
        var stem = "";
        var obj_stem = "";       // the object dir's name for it, whatever `stem` became
        var to_single = (!single_obj.empty()) && (fid == self._file_id) && (!self.discovered);
        if !to_single {
            var ocg  = CodegenContext(ctx, &null, psym, insts);
            var sp   = CXXSpell(&ocg);
            var segs = sp.module_segments(reinterpret_cast::<*TranslationUnit>(ctx->tu));
            var rel  = "";
            for var i: usize = 0; i < segs.size(); ++i {
                if i > 0 { rel += "/"; }
                rel += segs[i];
            }
            // A one-segment path sits beside a C/C++ input's <stem>.o, and
            // `foo.cc` including `foo.k` is the common case: kairo_object_stem
            // moves the Kairo object aside, as it did when foo.k was an entry.
            if rel.size() == 0 { rel = self._ci->kairo_object_stem(self.path.stem()); }
            else if segs.size() == 1 { rel = self._ci->kairo_object_stem(rel); }
            stem = obj_dir + "/" + rel;
            obj_stem = stem;
            // Two TUs can map to one object name: a pathless `builtin.k`
            // outside every search dir is named by its stem, as the builtin
            // root is. Serially the later TU overwrote the earlier and the
            // link happened to keep the right one; side by side, which write
            // lands last is a race. The later TU in graph order (the
            // importer, the one that used to win) takes a fid-suffixed name.
            var taken = false;
            for p: string in used_stems { if p == obj_stem { taken = true; break; } }
            if taken {
                obj_stem = obj_stem + f"-{fid}";
                stem     = obj_stem;
            }
            used_stems.push_back(obj_stem);
            var beside = ("") if (self.discovered || (fid != self._file_id)) else (self._ci->emit_beside(self.path.stem()));
            if !beside.empty() { stem = beside; }
        }

        var job = std::create::<CodegenJob>();
        job->fid   = fid;
        job->ctx   = ctx;
        job->ksize = ksize;
        job->path  = self._ci->sm()->get_filename(fid);
        if fe.print_cg { job->print |= 2; }
        if fe.print_ir { job->print |= 1; }
        for var k: usize = 0; k < kinds.size(); ++k {
            var out = (single_obj) if (to_single) else (stem + exts[k]);
            // An object nobody listed is a link input only.
            if (!to_single) && (kinds[k] == EmitKind::Obj) && (!self._ci->obj_listed()) { out = obj_stem + exts[k]; }
            self._ensure_parent_dir(out);
            job->kinds.push_back(kinds[k]);
            job->outs.push_back(out);
        }

        // Phase B loads phase A's PCHs instead of re-parsing the headers:
        // the merged one when it built, else one per set (CodegenBackend::
        // run), where only the first loads as a PCH and the rest are text.
        var sets = vec::<*HeaderSet>();
        var own_tu = reinterpret_cast::<*TranslationUnit>(ctx->tu);
        if (own_tu != &null) && (own_tu->header_set != &null) {
            sets.push_back(reinterpret_cast::<*HeaderSet>(own_tu->header_set));
        }
        // The whole graph's: an inline body this TU emits may name a header
        // of a module an earlier input claimed (builtin's rt/fmt.h).
        for hs: *HeaderSet in graph_sets {
            var dup = false;
            for var j: usize = 0; j < sets.size(); ++j { if sets[j] == hs { dup = true; break; } }
            if !dup { sets.push_back(hs); }
        }
        // Per-set fallback: the set that is costliest to re-parse goes first,
        // as the PCH. Headers are include-guarded and each set stands alone,
        // so only which one loads as the PCH changes, not what is declared.
        // Without this a builtin TU loaded its small rt/fmt.h set and parsed
        // libc++'s <coroutine> as text, every TU (4.7x on a small program).
        var big: usize = 0;
        for var j: usize = 1; j < sets.size(); ++j {
            if (!sets[j]->ok) { continue; }
            if (!sets[big]->ok) || (sets[j]->files.size() > sets[big]->files.size()) { big = j; }
        }
        if big > 0 {
            var b = sets[big];
            sets.erase(sets.begin() + big);
            sets.insert(sets.begin(), b);
        }
        for hs: *HeaderSet in sets {
            var dup = false;
            for var j: usize = 0; j < all_sets.size(); ++j { if all_sets[j] == hs { dup = true; break; } }
            if !dup { all_sets.push_back(hs); }
        }
        job->sets = sets;
        jobs.push_back(job);

        // The one cache a plan fills in place that other TUs' plans read
        // (EmitPlan::prepare_shared): filled here, one TU at a time, so the
        // fills below only read what they share.
        var pcg  = CodegenContext(ctx, &null, psym, insts);
        var prep = EmitPlan(&pcg, PlanMode::Header);
        prep.prepare_shared();
    }
    // Everything any TU's VFS will hold, mounted (well, listed) before the
    // first TU starts: nothing is added once workers read.
    crun.mount(all_sets);

    // The fan-out (P216). Each TU compiles on a CompilerInstance of its own
    // (CodegenJob::run), so TUs run side by side up to the pool's size
    // (--threads; every logical CPU by default) and the TU count. The P216
    // spike capped it at the physical cores (SMT doubled a small program's
    // per-TU time); on the self-host graph (316 TUs) all 24 threads beat 12
    // by 12% of the whole build (P380), so the cap is gone. One worker when
    // something prints per TU (--print-cg / --print-ir): their output is
    // written as each TU fills, so it must come one TU at a time.
    var workers = self._ci->pool()->get_thread_count();
    if workers > jobs.size() { workers = jobs.size(); }
    // KAIRO_CODEGEN_WORKERS: an explicit worker count, for measuring.
    {
        var wenv = libcxx::getenv(r"KAIRO_CODEGEN_WORKERS");
        if wenv != &null {
            var wn = static_cast::<usize>(libcxx::strtoull(wenv, &null, 10));
            if wn > 0 { workers = wn; }
            if workers > jobs.size() { workers = jobs.size(); }
        }
    }
    if fe.print_cg || fe.print_ir { workers = 1; }

    {
        var _tr = TimeRegion("Backend");
        if workers <= 1 {
            for j: *CodegenJob in jobs { j->run(&crun); }
        } else {
            var q = CodegenQueue();
            q.run = &crun;
            for j: *CodegenJob in jobs { q.add(j); }
            q.schedule();
            Logger::info(Logger::Stage::Driver, f"codegen: {jobs.size()} TU(s) on {workers} worker(s)");
            var qp  = &q;
            var rec = _tr.record();
            for var w: usize = 0; w < workers; ++w {
                self._ci->pool()->enqueue(fn () |qp, rec| {
                    var _kt = kairo::TimeReport::Worker(rec);
                    qp->work();
                }, CODEGEN_GROUP());
            }
            var wrec = time_region("Join");
            time_mark_idle(wrec);
            var _tj = TimeRegion(wrec);
            self._ci->pool()->wait_group(CODEGEN_GROUP());
        }
    }

    // Post-pass, driver thread, in TU order: what each TU said and wrote,
    // independent of which worker finished first. Every TU ran, a failed
    // one included, so every sink is drained before the verdict.
    var all_ok = true;
    for job: *CodegenJob in jobs {
        job->sink.drain_into(self._ci->diag(), self._ci->sm());
        // Codegen's OWN reports (EmitIR's I011W, CODEGEN.md section 8) go to
        // the TU's diag_sink, whose last drain was after sema. Undrained, they
        // were never shown and the sink ICEd in its destructor at exit.
        job->ctx->diag_sink.drain_into(self._ci->diag(), job->ctx->sm);
        if !job->ok { all_ok = false; continue; }
        if !all_ok { continue; }
        // Only objects are link inputs; the rest are outputs in their own right.
        for var k: usize = 0; k < job->written.size(); ++k {
            Logger::info(Logger::Stage::Driver, f"emitted {job->written[k]}");
            if job->kinds[k] == EmitKind::Obj { self.result.objects.push_back(job->written[k]); }
        }
        // A linking run's extra outputs are named, as the executable is not:
        // the user asked for them and could not have known where they went.
        if self._ci->emits_beside_link() && (!self.discovered) && (job->fid == self._file_id) {
            for var k: usize = 0; k < job->written.size(); ++k {
                if (job->kinds[k] == EmitKind::Obj) && (!self._ci->obj_listed()) { continue; }
                std::eprintln(f"kairo: wrote {job->written[k]}");
            }
        }
    }
    for j: *CodegenJob in jobs { std::destroy(j); }
    if !all_ok {
        self._stage = TUStage::Failed;
        return false;
    }

    self._stage = TUStage::Done;
    return true;
}

//  Post-stage dump helpers

fn FrontendAction::_dump_tokens() {
    var tokens = self._ci->tcm()->get_tokens(self._file_id);
    if tokens == &null {
        std::print(f"-- token stream: {self.path.full_path()} (none) --");
        return;
    }

    var printer = TokenPrinter(
        self._ci->tcm(),
        self._ci->invocation().diag.no_color
    );

    printer.print_stream(tokens, self.path.full_path());
}

/// \brief --dump-preprocessed: reconstruct macro-expanded source text from the
///        finalized token buffer and print it to stdout. This is the ONLY
///        stdout-emitting form of the preprocessor's output --preprocess alone
///        stops the pipeline after preprocessing with no extra output, matching
///        every other stops_at_* flag.
///
///        Spelling comes from TokenText::resolve() (the sole sanctioned text
///        accessor  see Token/TokenText.k), which already unwraps macro
///        expansion chains to their substituted identity. TkNewLine is
///        special-cased to a real byte instead of resolve()'s escaped debug
///        rendering (`"\\n"`), since this is meant to read back as source,
///        not as a token dump.
///
///        The lexer doesn't emit TkWhitespace for ordinary inter-token gaps
///        on a line (only newlines are real tokens - verified against
///        --print-tokens output), so original spacing isn't recoverable from
///        the buffer. A single space is inserted before every content token
///        that isn't the first on its line instead; this over-spaces
///        one-character punctuation ("( )" instead of "()") but stays
///        readable, matching the eyeball-aid framing for this flag.
fn FrontendAction::_dump_preprocessed_source() {
    var tokens = self._ci->tcm()->get_tokens(self._file_id);
    if tokens == &null {
        std::print(f"-- preprocessed source: {self.path.full_path()} (none) --");
        return;
    }

    var tcm = self._ci->tcm();
    var out: string = "";
    var at_line_start = true;
    for var i: usize = 0; i < tokens->size(); ++i {
        var tok = tokens->get(i);
        if tok->kind == TokenKind::TkNewLine    { out += "\n"; at_line_start = true; continue; }
        if tok->kind == TokenKind::TkWhitespace { continue; }
        if tok->kind == TokenKind::TkEof        { continue; }
        if tok->kind == TokenKind::TkFileStart  { continue; }
        if tok->kind == TokenKind::TkFileEnd    { continue; }
        if !at_line_start { out += " "; }
        at_line_start = false;
        out += TokenText::resolve(*tok, tcm).get_text();
    }
    std::print(out);
}

fn FrontendAction::_dump_macros() {
    var pp = self._ci->pp();
    if pp == &null { return; }
    var mt = pp->get_macro_table();
    var st = pp->get_symbol_table();
    if (mt == &null) || (st == &null) { return; }
    std::print(f"-- macro table: {self.path.full_path()} --");
    // One row per macro this graph defines, builtin/std included: they share
    // the table, and hiding them would make the count disagree with
    // PreProcessor::macro_count(). Keyed by fid because that is the table's
    // ownership index; `_fids` is the set this action preprocessed.
    for fid: u32 in self._fids {
        var entries = mt->entries_of_fid(fid);
        for var i: usize = 0; i < entries.size(); ++i {
            var e = entries[i];
            if e->decl == &null { continue; }
            var name = st->resolve(e->name_sym);
            var nm   = string("?");
            if name != &null { nm = *name; }
            var nparams: usize = e->decl->params_spec.size();
            var shape = f"{nparams} param(s)";
            if e->decl->is_variadic { shape = f"{nparams} param(s) + variadic"; }
            var full = self._ci->sm()->get_line_col(e->decl->range.start);
            std::print(f"macro {nm}: {shape}, defined at {full.path.full_path()}:{full.line}:{full.column}");
        }
    }
}

fn FrontendAction::_dump_imports() {
    std::print(f"-- imports: {self.path.full_path()} --");
    for fid: u32 in self._fids {
        var ctx = self._global_scope->get_context(fid);
        if ctx == &null { continue; }
        var tu = reinterpret_cast::<*TranslationUnit>(ctx->tu);
        if tu == &null { continue; }

        std::print(f"fid {fid}: {tu->import_edges.size()} edge(s)");
        for var i: usize = 0; i < tu->import_edges.size(); ++i {
            var edge = tu->import_edges[i];   // *ImportEdge (ArenaList::op[] yields *T)
            var id   = dyn_cast::<ImportDecl>(edge->decl);
            if id == &null { continue; }

            // path spelling: a::b::c
            var path: string = "";
            for var s: usize = 0; s < id->path_segments.size(); ++s {
                if s > 0 { path += "::"; }
                path += ctx->get_spelling(id->path_segments[s]);
            }

            // edge shape label
            var kind: string = "plain";
            if id->is_wildcard        { kind = "wildcard"; }
            else if id->has_items     { kind = "selective"; }
            else if id->last_seg_is_macro { kind = "macro"; }

            var alias: string = "";
            if id->has_alias { alias = f" as {ctx->get_spelling(id->alias)}"; }

            std::print(f"  [{kind}] {path}{alias} -> fid {edge->target_fid}");
        }
    }
}

fn _overlay_kind_str(k: OverlayTargetKind) -> string {
    if k == OverlayTargetKind::FunctionSet  { return "fn-set"; }
    if k == OverlayTargetKind::Type         { return "type";   }
    if k == OverlayTargetKind::ModuleHandle { return "module"; }
    return "?";
}

fn _overlay_vis_str(v: OverlayVisibility) -> string {
    if v == OverlayVisibility::Public    { return "pub";  }
    if v == OverlayVisibility::Protected { return "prot"; }
    if v == OverlayVisibility::Private   { return "priv"; }
    return "?";
}

/// --print-panic-sets: every Panic<T, E...> instance the build formed
/// (PANIC.md §1.3, §1.1a), by its C++ spelling: the canonical set in
/// order with each type id, then the layout Sema predicted (size 0:
/// not known before C++ lays it out). Sorted, for golden tests: the
/// registry's own order is mint order, which moves when an unrelated TU
/// mints first.
fn FrontendAction::_dump_panic_sets() {
    var ids = self._ci->panic_type_ids();
    if ids == &null { return; }
    var all = vec::<*InstanceEntry>();
    self._global_scope->instances()->collect(all);
    var rows = vec::<string>();
    for var i: usize = 0; i < all.size(); ++i {
        var e = all[i];
        if (!ids->is_panic(e->primary)) || (e->type_ids.size() == 0) { continue; }
        var p = e->args.size() - e->type_ids.size();
        var t = ids->spelling(e->args[0]);
        var r = f"Panic<{t}";
        for var k: usize = p; k < e->args.size(); ++k { r += ", " + ids->spelling(e->args[k]); }
        r += f">: size {e->adt_size}, payload offset {e->payload_offset}";
        for var k: usize = 0; k < e->type_ids.size(); ++k {
            r += "\n  " + ids->spelling(e->args[p + k]) + " = 0x" + hex32(e->type_ids[k]);
        }
        var at = rows.size();
        rows.push_back(r);
        while (at > 0) && (r < rows[at - 1]) { rows[at] = rows[at - 1]; at -= 1; }
        rows[at] = r;
    }
    std::print("-- panic sets --");
    for var i: usize = 0; i < rows.size(); ++i { std::print(rows[i]); }
}

/// Dump the built import overlays (phase I output): per fid, each folded name
/// key and its targets (kind, source fid, visibility, origin import shape).
/// Runs AFTER ImportResolution in _sema, so the overlay is populated. Pairs
/// with _dump_imports (edges) the way --print-symbols pairs with the parse.
fn FrontendAction::_dump_overlays() {
    std::print(f"-- overlays: {self.path.full_path()} --");
    for fid: u32 in self._fids {
        var ctx = self._global_scope->get_context(fid);
        if ctx == &null { continue; }
        var tu = reinterpret_cast::<*TranslationUnit>(ctx->tu);
        if tu == &null { continue; }
        var ov = tu->import_overlay;
        if ov == &null {
            std::print(f"fid {fid}: (no overlay)");
            continue;
        }

        std::print(f"fid {fid}: {ov->size()} overlay key(s)");

        // The injected prelude is not in the source, so naming it here is the
        // only place a reader can see WHY builtin's names are in this overlay.
        for var pi: usize = 0; pi < tu->imports.size(); ++pi {
            var pslot = tu->imports[pi];
            if pslot == &null { continue; }
            var pimp = dyn_cast::<ImportDecl>(*pslot);
            if pimp == &null { continue; }
            if !pimp->is_prelude { continue; }
            // One prelude: builtin's wildcard. std has none; it is imported
            // by name (`import std::io`) like any other module. A plain one
            // is the nameless edge to alloc.k for `@create` (P91).
            if !pimp->is_wildcard {
                std::print(f"  <prelude> alloc edge for @create / @destroy (src=fid {pimp->resolved_fid})");
                continue;
            }
            std::print(f"  <prelude> import builtin::* (src=fid {pimp->resolved_fid})");
        }

        var imms = ctx->get_imm_table();
        var rows = vec::<ImportOverlay::Row>();
        ov->collect_rows(rows);
        for var i: usize = 0; i < rows.size(); ++i {
            var row  = rows[i];
            var name = ("<?>") if (imms == &null) else (imms->get_ident(row.key));
            var amb  = (" [AMBIGUOUS]") if (row.entry->is_ambiguous()) else ("");
            if row.entry->is_ambiguous() && row.entry->lazy { amb += " (reported at use)"; }
            std::print(f"  {name}: {row.entry->targets.size()} target(s){amb}");
            for var t: usize = 0; t < row.entry->targets.size(); ++t {
                var tg = row.entry->targets[t];
                var hid = (" hidden") if (tg.hidden) else ("");
                std::print(f"    - {_overlay_kind_str(tg.kind)} src=fid {tg.src_fid} vis={_overlay_vis_str(tg.vis)}{hid}");
            }
        }
    }
}

/// Disambiguating suffix for a type-decl scope header. Overloaded/specialized
/// types (e.g. `class <T> Box`, `class <> Box<i32>`, `class <> Box<[T]>`) all
/// share the bare name `Box`, so three `scope <tu>::Box` headers are
/// indistinguishable in the dump. Append the specialization args (`<i32>`) or,
/// for a generic primary, the parameter list (`<T>`), rendered through the
/// same type/token printers the AST dump uses. Non-generic decls get "".
fn _sym_spec_suffix(ctx:            *ASTContext,
                    opts:           PrintOptions,
                    spec_kind:      SpecKind,
                    spec_args:      ref!(FrozenList::<*Type>),
                    generic_params: ref!(FrozenList::<*GenericParamDecl>)) -> string {
    // Specialization: render the post-name `<...>` argument pattern.
    if (spec_kind == SpecKind::Explicit) || (spec_kind == SpecKind::Partial) {
        var s: string = "<";
        for var i: usize = 0; i < spec_args.size(); ++i {
            if i > 0 { s += ", "; }
            if spec_args[i] != &null { s += TypePrinter::print(spec_args[i], ctx, opts); }
        }
        s += ">";
        return s;
    }
    // Generic primary: render the parameter names.
    if !generic_params.is_empty() {
        var s: string = "<";
        for var i: usize = 0; i < generic_params.size(); ++i {
            if i > 0 { s += ", "; }
            if generic_params[i] != &null { s += ctx->get_spelling(generic_params[i]->name); }
        }
        s += ">";
        return s;
    }
    return "";
}

fn FrontendAction::_dump_symbols(tu: *TranslationUnit, ctx: *ASTContext, opts: PrintOptions) {
    var tu_dc = static_cast::<*DeclContext>(tu);
    self._dump_symbols_dc(tu_dc, ctx, opts, "<tu>");
}

priv fn FrontendAction::_dump_symbols_dc(dc: *DeclContext, ctx: *ASTContext, opts: PrintOptions, qual: string) {
    if dc == &null { return; }

    var p = Painter(opts);
    p.paint(Color::NodeKind, f"scope {qual}");
    if dc->dc_symbols == &null {
        p.paint(Color::Dim, "  (no table)");
        p.newline();
    } else {
        var tbl = dc->dc_symbols;
        if tbl->is_frozen() {
            p.paint(Color::Dim, f"  ({tbl->size()} names, frozen)");
        } else {
            p.paint(Color::Error, f"  ({tbl->size()} names, NOT FROZEN)");
        }
        p.newline();

        var entries: vec::<SymbolTable::Entry>;
        tbl->collect_entries(entries);
        for var ei: usize = 0; ei < entries.size(); ++ei {
            var cell = entries[ei].cell;
            if cell == &null { continue; }

            // Name header: idents/ctor/dtor decode from the key; operators
            // cannot (the key packs TokenKind hashes lossily), so render them
            // from the first decl's op_token via get_spelling   the exact
            // source bytes the user wrote.
            var name = entries[ei].name.describe(ctx);
            if entries[ei].name.is_op() {
                var od = cell->get(0);
                if (od != &null) && isa::<FunctionDecl>(od) {
                    var f = cast::<FunctionDecl>(od);
                    var opr: string = "op ";
                    for var ti: usize = 0; ti < f->op_token.size(); ++ti {
                        opr += ctx->get_spelling(f->op_token[ti]);
                    }
                    name = opr;
                }
            }

            var n = cell->size();
            p.paint(Color::Ident, name);
            if n > 1 { p.paint(Color::Dim, f"  [overloaded x{n}]"); }
            p.newline();
            for var di: usize = 0; di < n; ++di {
                var d = cell->get(di);
                if d == &null { continue; }
                p.paint(Color::Tree, "    ");
                p.put(DeclPrinter::print(d, ctx, opts));
                p.newline();
            }
        }
    }
    std::print(p.out);

    for var i: usize = 0; i < dc->dc_decls.size(); ++i {
        var d = *(dc->dc_decls.get(i));
        if d == &null { continue; }

        var child: *DeclContext = &null;
        var name:  string       = "";

        if isa::<ClassDecl>(d) {
            var n = cast::<ClassDecl>(d);
            child = static_cast::<*DeclContext>(n);
            name  = ctx->get_spelling(n->name)
                  + _sym_spec_suffix(ctx, opts, n->spec_kind, n->spec_args, n->generic_params);
        } else if isa::<StructDecl>(d) {
            var n = cast::<StructDecl>(d);
            child = static_cast::<*DeclContext>(n);
            name  = ctx->get_spelling(n->name)
                  + _sym_spec_suffix(ctx, opts, n->spec_kind, n->spec_args, n->generic_params);
        } else if isa::<UnionDecl>(d) {
            var n = cast::<UnionDecl>(d);
            child = static_cast::<*DeclContext>(n);
            name  = ctx->get_spelling(n->name)
                  + _sym_spec_suffix(ctx, opts, n->spec_kind, n->spec_args, n->generic_params);
        } else if isa::<InterfaceDecl>(d) {
            var n = cast::<InterfaceDecl>(d);
            child = static_cast::<*DeclContext>(n);
            name  = ctx->get_spelling(n->name)
                  + _sym_spec_suffix(ctx, opts, n->spec_kind, n->spec_args, n->generic_params);
        } else if isa::<EnumDecl>(d) {
            var n = cast::<EnumDecl>(d);
            child = static_cast::<*DeclContext>(n);
            name  = ctx->get_spelling(n->name)
                  + _sym_spec_suffix(ctx, opts, n->spec_kind, n->spec_args, n->generic_params);
        } else if isa::<ModuleDecl>(d) {
            var n = cast::<ModuleDecl>(d);
            child = static_cast::<*DeclContext>(n);
            name  = ctx->get_spelling(n->name);
        } else if isa::<ExtensionDecl>(d) {
            var n = cast::<ExtensionDecl>(d);
            child = static_cast::<*DeclContext>(n);
            name  = "<extension>";
        }

        if child == &null { continue; }
        self._dump_symbols_dc(child, ctx, opts, f"{qual}::{name}");
    }
}

priv fn FrontendAction::_dump_mem_stats() {
    if libcxx::getenv(r"MEM_STATS") == &null { return; }

    var total_bytes:  usize = 0;
    var total_slabs:  usize = 0;
    var total_allocs: usize = 0;
    var tu_count:     usize = 0;

    for fid: u32 in self._fids {
        var ctx = self._global_scope->get_context(fid);
        if ctx == &null { continue; }
        var p = ctx->mem_profile();
        total_bytes  += libcxx::get::<0>(p);
        total_slabs  += libcxx::get::<1>(p);
        total_allocs += libcxx::get::<2>(p);
        tu_count     += 1;
    }

    var retained_blocks: usize = 0;
    var retained_bytes:  usize = 0;
    kairo::GlobalRecycler::instance().stats(retained_blocks, retained_bytes);

    std::eprintln(f"[mem] TU contexts:        {tu_count}");
    std::eprintln(f"[mem] arena live bytes:   {total_bytes / (1024*1024)} MB ({total_bytes} B)");
    std::eprintln(f"[mem] arena slabs:        {total_slabs}");
    std::eprintln(f"[mem] alloc calls:        {total_allocs}");
    std::eprintln(f"[mem] bytes / alloc:      {(total_bytes / total_allocs) if (total_allocs > 0) else 0}");
    std::eprintln(f"[mem] recycler retained:  {retained_bytes / (1024*1024)} MB ({retained_blocks} blocks)");
    {
        var b_pp: usize = 0; var b_ix: usize = 0; var b_ast: usize = 0;
        var b_sem: usize = 0; var b_scr: usize = 0; var b_str: usize = 0;
        var top_fid: u32 = 0; var top_b: usize = 0;
        for fid: u32 in self._fids {
            var c = self._global_scope->get_context(fid);
            if c == &null { continue; }
            b_pp  += c->pp_alloc.profile().bytes_allocated;
            b_ix  += c->index_alloc.profile().bytes_allocated;
            b_ast += c->ast_alloc.profile().bytes_allocated;
            b_sem += c->sema_alloc.profile().bytes_allocated;
            b_scr += c->scratch_alloc.profile().bytes_allocated;
            b_str += c->string_alloc.profile().bytes_allocated;
            var one = libcxx::get::<0>(c->mem_profile());
            if one > top_b { top_b = one; top_fid = fid; }
        }
        var mb: usize = 1024 * 1024;
        std::eprintln(f"[mem] by arena MB: pp {b_pp / mb} index {b_ix / mb} ast {b_ast / mb} sema {b_sem / mb} scratch {b_scr / mb} string {b_str / mb}");
        std::eprintln(f"[mem] largest TU: {self._ci->sm()->get_filename(top_fid)} {top_b / mb} MB");
    }
    if self._ci->headers() != &null {
        var hsets: vec::<*HeaderSet>;
        self._ci->headers()->all(hsets);
        var live: usize = 0;
        var hbytes: usize = 0;
        for hs: *HeaderSet in hsets {
            var b = hs->ast_bytes();
            if b > 0 { live += 1; hbytes += b; }
        }
        std::eprintln(f"[mem] header sets:        {live} of {hsets.size()} live, clang AST {hbytes / (1024*1024)} MB");
        var m_buf: usize = 0; var m_map: usize = 0; var m_sm: usize = 0; var m_pp: usize = 0;
        for hs: *HeaderSet in hsets { hs->other_bytes(&m_buf, &m_map, &m_sm, &m_pp); }
        var mb: usize = 1024 * 1024;
        std::eprintln(f"[mem] header sets other:  file buffers heap {m_buf / mb} MB mmap {m_map / mb} MB, SM tables {m_sm / mb} MB, PP {m_pp / mb} MB");
    }
}