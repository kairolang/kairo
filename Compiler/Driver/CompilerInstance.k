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

import Diagnostic::Engine::*;
import Diagnostic::Registry::*;
import Diagnostic::PrettyConsumer::*;
import Diagnostic::BasicConsumer::*;
import Location::SourceManager::*;
import Support::TermRenderer::*;
import Support::TimeReport::*;
import Token::TokenCacheManager::*;
import Token::TokenText::*;
import Token::TokenKind::*;
import Command::Command::*;
import Command::FlagRegistry::*;
import Codegen::Backend::*;
import Config::Invocation::*;
import Driver::BatchResult::*;
import Driver::TUResult::*;
import Driver::TUStage::*;
import Preprocessor::Preprocessor::*;
import Parser::ASTParse::*;
import AST::Context::GlobalDisambigTable::*;
import AST::Printer::ASTPrinter::*;
import AST::Printer::PrintCore::*;
import AST::Context::DeclContext::*;
import AST::Context::SymbolTable::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import Token::TokenPrinter::*;
import Sema::Lower::NullableTypeLowering::*;
import Sema::Sema::*;
import Sema::SemaDump::*;
import Sema::SemaContext::*;
import AST::Context::ImportOverlay::*;
import Interop::Clang::ClangBackend::*;
import Diagnostic::ClangDiagLookup::*;

ffi "c++" import "llvm/TargetParser/Host.h";
ffi "c++" import "llvm/Support/raw_ostream.h";
ffi "c++" import "llvm/Support/Threading.h";
ffi "c++" import "llvm/TargetParser/Triple.h";
ffi "c++" import "llvm/MC/TargetRegistry.h";
ffi "c++" import "llvm/MC/MCSubtargetInfo.h";
ffi "c++" import "llvm/Support/TargetSelect.h";
ffi "c++" import "llvm/Target/TargetMachine.h";
ffi "c++" import "llvm/Target/TargetOptions.h";
ffi "c++" import "llvm/Support/CodeGen.h";
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
    priv var _fids:         vec::<u32>;
    pub var result:         TUResult;
    priv var _stage:        TUStage;

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

    priv fn _fatal(self, msg: string) -> bool;
    priv fn _load(self)        -> bool;
    priv fn _preprocess(self)  -> bool;
    priv fn _parse(self)       -> bool;
    priv fn _sema(self)        -> bool;
    priv fn _codegen(self)     -> bool;
    priv fn _dump_tokens(self);
    priv fn _dump_preprocessed_source(self);
    priv fn _dump_macros(self);
    priv fn _dump_imports(self);
    priv fn _dump_overlays(self);
    priv fn _dump_symbols(self, tu: *TranslationUnit, ctx: *ASTContext, opts: PrintOptions);
    priv fn _dump_symbols_dc(self, dc: *DeclContext, ctx: *ASTContext, opts: PrintOptions, qual: string);
    priv fn _dump_mem_stats(self);
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
    //   Listed in construction order; destroyed in reverse.
    priv var _pool:    *ThreadPool;
    priv var _vfm:     *VirtualFileManager;
    priv var _diag:    *DiagEngine;
    priv var _sm:      *SourceManager;
    priv var _tcm:     *TokenCacheManager;
    priv var _pretty:  *PrettyDiagConsumer;
    priv var _basic:   *BasicDiagConsumer;
    priv var _cmd:     *Command;
    priv var _pp:      *PreProcessor;
    priv var _imp:     *ImportResolver;
    priv var _g_scope: *GlobalDisambigTable;
    priv var _backend: *ClangBackend = &null; ///< shared clang backend; owned

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

        self._pool = std::create::<ThreadPool>(usize(
                    (llvm::hardware_concurrency().compute_thread_count())
            if   (self.invocation().frontend.thread_count == 0)
            else (self.invocation().frontend.thread_count)
        ));

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
            || self.invocation().args.get_bool("print-ld-args")
            || self.invocation().args.get_bool("print-target-info")
            || self.invocation().args.get_bool("print-pass-pipeline")
            || self.invocation().args.get_bool("print-cfg");
    }

    // --- Identity actions ------------------------------------------------

    fn get_target_triple(self) -> string {
        var triple = llvm::Triple(llvm::Triple::normalize(llvm::sys::getProcessTriple()));
        if (triple.getVendor()) == (llvm::Triple::UnknownVendor) && (triple.isOSLinux()) {
            triple.setVendor(llvm::Triple::PC);
        }

        return std::nstring_to_string(triple.getTriple());
    }

    /// No-op when the instance was built from an invocation: there is no flag
    /// table to describe and no argv[0] to name in the USAGE line.
    fn print_help(self) {
        if self._cmd == &null { return; }
        self._cmd->print_help();
    }

    fn print_version(self) {
        std::print(f"installed version: {VERSION}");
        std::print(f"target triple:     {self.get_target_triple()}");
        std::print(f"thread model:      {std::get_thread_model()}");
        std::print(f"installed at:      {((std::get_exe_path()).parent_path()).generic_wstring()}");
    }

    /// Resolves and renders the long-form explanation for a diagnostic code.
    /// Returns 1 if the code is unknown.
    fn run_explain(self) -> i32 {
        var code = self.invocation().args.get_string("explain");

        var first: usize = code.raw_string().find_first_not_of(" \t\n\r\f\v".raw());
        if !(string::npos == first) {
            var last: usize = code.raw_string().find_last_not_of(" \t\n\r\f\v".raw());
            code = code.raw_string().substr(first, (last - first + 1));
        }

        var diag_id = diag_from_string(code);
        var explain = diag_explain(diag_id);
        if explain.empty() {
            std::eprintln(f"error: unknown diagnostic code '{code}\x27");
            return 1;
        }

        var r = TermRenderer(true, 80);
        std::print(r.render(explain));
        return 0;
    }

    /// Returns the effective target triple: --target if given, else host triple.
    ///
    /// Reads the typed option rather than the raw flag so it works on the
    /// invocation path too. TargetOptions::triple is set verbatim from
    /// `--target`, so the argv path is unaffected.
    priv fn _effective_triple(self) -> string {
        var t = self.invocation().target.triple;

        if !t.empty() {
            return t;
        }

        return self.get_target_triple();
    }

    /// Looks up a registered target by triple. Returns nullptr if not found
    /// and writes the LLVM error message to `err_out`.
    priv fn _lookup_target(self, triple: string, err_out: *string) -> *void {
        var result: *void = &null;
        var err:     libcxx::string;
        var triple_str = std::string_to_nstring(triple);

        inline "c++" {
            auto llvm_triple = llvm::Triple(llvm::Triple::normalize(triple_str.raw_string()));
            const llvm::Target *T = llvm::TargetRegistry::lookupTarget(llvm_triple, err);
        }

        if T == &null {
            (*err_out) = string(err.c_str());
        }

        inline "c++" { result = const_cast<void*>(static_cast<const void*>(T)); }
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
        
        inline "c++" {
            libcxx::sort(rows.begin(), rows.end(),
            // only reason this is in an inline c++ block is auto is not supported in Kairo stage0
                [](const auto &a, const auto &b) { return a.first < b.first; });
        }

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
        var triple = std::string_to_nstring(self._effective_triple());
        var llvm_triple = llvm::Triple(llvm::Triple::normalize(triple.raw()));
        var err:     libcxx::string;
    
        var T: *llvm::Target = const_cast::<*llvm::Target>(
            llvm::TargetRegistry::lookupTarget(llvm_triple, err)
        );

        if T == &null {
            self._diag->report(DiagID::U001F, f"unknown target triple '{triple}': {string(err.c_str(), err.size())}").emit();
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
            self._diag->report(DiagID::U001F, f"failed to create TargetMachine for '{string(triple.raw())}\x27").emit();
            return 1;
        }

        var STI: *llvm::MCSubtargetInfo = const_cast::<*llvm::MCSubtargetInfo>(TM->getMCSubtargetInfo());
        if STI == &null {
            self._diag->report(DiagID::U001F, f"no subtarget info for '{string(triple.raw())}\x27").emit();
            return 1;
        }

        std::print(f"Available CPUs for target '{string(triple.raw())}':");

        var cpu_rows: libcxx::vector::<libcxx::string>;
        var max_cpu:  size_t = 0;

        for cpu in STI->getAllProcessorDescriptions() {
            cpu_rows.emplace_back(cpu.Key);
            max_cpu = libcxx::max(max_cpu, libcxx::strlen(cpu.Key));
        }

        inline "c++" {
            libcxx::sort(cpu_rows.begin(), cpu_rows.end(),
                [](const auto &a, const auto &b) { return a < b; });
        }

        for row in cpu_rows {
            std::print(f"  {string(row.c_str(), row.size())}");
        }

        std::print("");
        std::print("Available features:");

        var feat_rows: libcxx::vector::<libcxx::pair::<libcxx::string, libcxx::string>>;
        var max_feat:  size_t = 0;

        inline "c++" {
            for (const llvm::SubtargetFeatureKV &feat : STI->getAllProcessorFeatures()) {
                const char *desc = (feat.Desc && *feat.Desc) ? feat.Desc : "";
                feat_rows.emplace_back(feat.Key, desc);
                max_feat = libcxx::max(max_feat, libcxx::strlen(feat.Key));
            }

            libcxx::sort(feat_rows.begin(), feat_rows.end(),
                [](const auto &a, const auto &b) { return a.first < b.first; });
        }

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
        var triple = std::string_to_nstring(self._effective_triple());
        var llvm_triple = llvm::Triple(llvm::Triple::normalize(triple.raw()));
        var err: libcxx::string;

        var T: *llvm::Target = const_cast::<*llvm::Target>(
            llvm::TargetRegistry::lookupTarget(llvm_triple, err)
        );

        if T == &null {
            self._diag->report(DiagID::U001F,
                f"unknown target triple '{string(triple.raw())}': {string(err.c_str(), err.size())}"
            ).emit();
            return 1;
        }

        var full_triple: libcxx::string  = llvm_triple.getTriple();
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
        inline "c++" {
            switch (llvm_triple.getObjectFormat()) {
                case llvm::Triple::COFF:        obj_format = string("COFF");        break;
                case llvm::Triple::ELF:         obj_format = string("ELF");         break;
                case llvm::Triple::MachO:       obj_format = string("Mach-O");      break;
                case llvm::Triple::Wasm:        obj_format = string("Wasm");        break;
                case llvm::Triple::XCOFF:       obj_format = string("XCOFF");       break;
                case llvm::Triple::GOFF:        obj_format = string("GOFF");        break;
                case llvm::Triple::DXContainer: obj_format = string("DXContainer"); break;
                case llvm::Triple::SPIRV:       obj_format = string("SPIR-V");      break;
                default:                        obj_format = string("unknown");     break;
            }
        }

        std::print(f"Triple:          {string(full_triple.c_str(), full_triple.size())}");
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
            self._diag->report(DiagID::U001F,
                f"failed to create TargetMachine for '{string(triple.raw())}\x27"
            ).emit();
            return 1;
        }

        finally {
            delete TM;
        }

        var data_layout: libcxx::string  = TM->createDataLayout().getStringRepresentation();
        var default_cpu: llvm::StringRef = TM->getTargetCPU();

        std::print(f"Data layout:     {string(data_layout.c_str(), data_layout.size())}");
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

        if self.invocation().args.get_bool("print-cfg") {
            for s: string in self.invocation().args.get_list("cfg") { std::print(s); }
            return 0;
        }
        return 0;
    }

    fn flush_errors(self) {
        if self.invocation().diag.format == "basic" {
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
    fn initialize(self, cwd: Path) {
        {
            var _t = TimeRegion("ImportIndex");
            var rb = ImportResolver::Builder().cwd(cwd);
            for dir: string in self.invocation().include_dirs { rb.add_include(Path(dir)); }
            for dir: string in self.invocation().macro_paths  { rb.add_include(Path(dir)); }
            self._imp = rb.create_ptr(self._pool);
        }

        self._pp = std::create::<PreProcessor>(
            self._sm, self._tcm, self._imp, self._pool,
            self._diag, self._g_scope, &self.invocation(), self.invocation().pp);

        // Shared clang backend: kick the expensive startup (invocation parse,
        // TargetInfo, FileManager/SourceManager) onto the pool NOW so it runs
        // concurrently with lex/preprocess. Joined via CLANG_STARTUP_GROUP
        // before codegen. Kairo fids are NOT registered here   that happens in
        // ClangLocMap::rebind(), inside the codegen action window.
        var bcfg = ClangBackendConfig{};
        (bcfg.triple) = self._effective_triple();
        (bcfg.wargs)  = _clang_wargs_from_policy(self.invocation().diag);
        self._backend = std::create::<ClangBackend>(self._sm, bcfg);

        inline "c++" {
            auto* be  = _backend;
            auto* rec = ::kairo::TimeReport::region("ClangStartup");
            _pool->enqueue([be, rec]() {
                KTIME_WORKER(rec);
                be->startup();
            }, CLANG_STARTUP_GROUP());
        }
    }

    /// Compiles all input files described by the invocation.
    ///
    /// Builds an \c ImportResolver from the search paths in the invocation,
    /// then runs a \c FrontendAction for each input file. A fatal diagnostic
    /// in any file sets \c BatchResult::aborted and skips remaining files.
    /// Results are collected into the returned \c BatchResult.
    fn execute(self) -> BatchResult {
        assert((self._imp != &null) && r"initialize() must be called before execute()");

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
            self._diag->report(DiagID::U001F, "no input files").emit();
            result.aborted = true;
            return result;
        }

        Logger::info(Logger::Stage::Driver,
            f"CompilerInstance::execute: {self.invocation().input_files.size()} file(s)");

        result.tu_results.reserve(self.invocation().input_files.size());

        var _t_frontend = TimeRegion("Frontend");

        for path_str: string in self.invocation().input_files {
            if result.aborted { break; }

            var action = std::create::<FrontendAction>(
                Path(path_str),
                ModulePath(),
                self._g_scope,
                self._imp,
                &self
            );

            finally { std::destroy(action); }

            action->run();

            if action->result.had_fatal { result.aborted = true; }
            result.total_errors   += action->result.error_count;
            result.total_warnings += action->result.warn_count;
            result.tu_results.push_back(action->result);
        }

        Logger::info(Logger::Stage::Driver,
            f"CompilerInstance::execute: {result.summary()}");

        return result;
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

        var lowered_tu = reinterpret_cast::<*TranslationUnit>(ctx->tu);
        if lowered_tu != &null {
            var pass = NullableTypeLowering{};
            pass.ctx = ctx;
            pass.run(lowered_tu);
        }

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

    /// Maps invocation fields to live subsystem setters. Called once after
    /// the invocation is built. Fields whose subsystem does not yet exist are
    /// silently accepted stored in the invocation for future use.
    priv fn _apply_invocation(self) {
        var d  = self.invocation().diag;
        var fe = self.invocation().frontend;

        if d.format == "basic" {
            self._diag->remove_consumer(self._pretty);
            self._diag->add_consumer(self._basic);
        }

        if d.no_color { self._pretty->set_color(false); }

        self._diag->set_error_limit(u32(d.max_errors));
        self._diag->set_warnings_as_errors(d.warnings_as_errors);
        self._diag->set_suppress_all_warnings(d.suppress_warnings);

        // Per-code diagnostic policy. Codes are addressed by their numeric part
        // only (severity-letter-agnostic): S025, S025W, s025 all key on 25.
        // allow -> Silence, deny(--error/-E) -> Promote, forbid -> Forbid.
        for c in d.allow_list  { self._diag->set_policy(_diag_code_to_number(c), DiagAction::Silence); }
        for c in d.deny_list   { self._diag->set_policy(_diag_code_to_number(c), DiagAction::Promote); }
        for c in d.forbid_list { self._diag->set_policy(_diag_code_to_number(c), DiagAction::Forbid);  }

        // Logger was initialised at Trace in main(); quiet it down unless
        // the user asked for verbose output. The stream level controls what is
        // echoed to stderr live (default Error); --verbose turns the terminal
        // into a running trace instead of something you read out of kairo.log
        // after the fact.
        if !fe.verbose {
            Logger::set_level(Logger::Level::Warn);
        } else {
            Logger::set_stream_level(Logger::Level::Info);
        }
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
    }

    Logger::info(Logger::Stage::Driver,
        f"FrontendAction: begin '{self.path.full_path()}\x27");

    // Phase 1: shared-state stages driver thread only.
    if !self._load() { return; }

    // Phase 2: per-file stages async-dispatchable in a future phase.
    if !self._preprocess() { return; }
    var fe = ((self._ci->invocation()).frontend);
    if fe.stops_at_preprocess() { self._stage = TUStage::Done; return; }

    if !self._parse() { return; }
    if self._ci->diag()->error_count() > 0 { self._stage = TUStage::Failed; return; }
    if fe.stops_at_parse() { self._stage = TUStage::Done; return; }

    if !self._sema() { return; }
    if self._ci->diag()->error_count() > 0 { self._stage = TUStage::Failed; return; }
    if fe.stops_at_sema() { self._stage = TUStage::Done; return; }

    if !self._codegen() { return; }

    self._stage = TUStage::Done;
    Logger::info(Logger::Stage::Driver,
        f"FrontendAction: done '{self.path.full_path()}' ({self.result.elapsed_ms:.2}ms)");
}

//  Pipeline stages each returns true to continue, false to halt.

/// Emits a fatal diagnostic, marks the TU as failed, and returns false.
fn FrontendAction::_fatal(msg: string) -> bool {
    self._ci->diag()->report(DiagID::U001F, msg).emit();
    self.result.had_fatal = true;
    self._stage = TUStage::Failed;
    return false;
}

/// Registers the source file with \c SourceManager and obtains a file ID.
fn FrontendAction::_load() -> bool {
    var _t = TimeRegion("Load");

    self._stage   = TUStage::Loading;
    self._file_id = self._ci->sm()->load_file(self.path);
    if self._file_id == u32(-1) {
        return self._fatal(f"cannot open '{self.path.full_path()}\x27");
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

    var pp_res = self._ci->pp()->preprocess(self._file_id, self.module_base);
    self._fids = pp_res.fids;

    self.result.error_count = self._ci->diag()->error_count();
    self.result.warn_count  = self._ci->diag()->warn_count();

    if self._ci->diag()->has_fatal() {
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

fn FrontendAction::_parse() -> bool {
    var _t = TimeRegion("Parse");

    self._stage = TUStage::Parsing;

    var fids = self._fids;  // tree order, fids[0] == main

    // index phase: Index-mode ASTParse over each fid (same grammar as the
    // full parse, shallow materialization). Replaces the old ASTIndex
    // token-level pre-pass.

    {
        var _ti = TimeRegion("Index");

        for fid: u32 in fids {
            inline "c++" {
                auto  captured_fid  = fid;
                auto  captured_self = this;
                auto* captured_rec  = ::kairo::TimeReport::current();
                _ci->pool()->enqueue([captured_fid, captured_self, captured_rec]() {
                    KTIME_WORKER(captured_rec);
                    auto* gs  = captured_self->_global_scope;
                    auto* ctx = gs->begin_index(captured_fid);
                    if (ctx) {
                        ASTParse indexer(ctx, nullptr, gs, ASTParse::ParseMode::Index);
                        indexer.index();
                        gs->finish_index(captured_fid);
                    }
                }, u8(5));
            }
        }
        self._ci->pool()->wait_group(u8(5));
    }

    // parallel parse + low-water-mark flush
    {
        var _tp = TimeRegion("Full");
        inline "c++" {
            const size_t N = fids.size();
            auto* time_rec  = ::kairo::TimeReport::current();
            auto* time_sm   = _ci->sm();
            auto* time_flush = ::kairo::TimeReport::region_under(time_rec, "DiagFlush");
            ::kairo::TimeReport::mark_idle(time_flush);

            // done[i] published (release) by the parse task for fids[i];
            // read (acquire) by the flusher. heap so the flusher thread can hold it.
            auto* done = new libcxx::atomic<bool>[N];
            for (size_t i = 0; i < N; ++i) done[i].store(false, libcxx::memory_order_relaxed);

            auto* engine = _ci->diag();
            auto* fids_p = &fids;
            auto* gs     = _global_scope;

            // flusher: drains contiguous done-prefix in fid order, single-threaded.
            libcxx::thread flusher([=]() {
                KTIME_ROOT(time_rec);
                KTIME_REC(time_flush);
                size_t cursor = 0;
                while (cursor < N) {
                    if (done[cursor].load(libcxx::memory_order_acquire)) {
                        u32 fid = (*fids_p)[cursor];
                        auto* ctx = gs->get_context(fid);
                        if (ctx) ctx->diag_sink.drain_into(engine);
                        ++cursor;
                    } else {
                        libcxx::this_thread::yield();
                    }
                }
            });


            for (size_t i = 0; i < N; ++i) {
                u32 fid = (*fids_p)[i];
                _ci->pool()->enqueue([gs, fid, done, i, time_rec, time_sm]() {
                    ::kairo::TimeReport::Worker _kt(time_rec);

                    struct Publish {
                        libcxx::atomic<bool>* d;
                        ~Publish() { d->store(true, libcxx::memory_order_release); }
                    } pub{&done[i]};

                    auto* ctx = gs->get_context(fid);
                    if (ctx) {
                        ASTParse parser(ctx, nullptr, gs, ASTParse::ParseMode::Full);
                        auto* tu = parser.parse();
                        ctx->tu = reinterpret_cast<void*>(tu);
                        if (time_sm) { _kt.units(time_sm->get_file_size(fid), "B"); }
                    }
                }, u8(6));
            }

            _ci->pool()->wait_group(u8(6));  // all parses done => all done[i] set
            flusher.join();                  // flusher drains tail, exits
            delete[] done;
        }
    }

    for fid in fids {
        var lower_ctx = self._global_scope->get_context(fid);
        if lower_ctx == &null { continue; }
        var lower_tu = reinterpret_cast::<*TranslationUnit>(lower_ctx->tu);
        if lower_tu == &null { continue; }
        var pass = NullableTypeLowering{};
        pass.ctx = lower_ctx;
        pass.run(lower_tu);
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
            return self._fatal(
                f"invalid --print-ast value '{ast_mode}'; expected one of: tree, flat, canonical"
            );
        }
        opts.color = use_color;
        for fid: u32 in fids {
            std::print(f"============== AST ({ast_mode}) for fid {fid} ==============");
            var ctx = self._global_scope->get_context(fid);
            if ctx == &null {
                return self._fatal(f"failed to get context for fid {fid}");
            }
            
            var tu = reinterpret_cast::<*TranslationUnit>(ctx->tu);
            if tu == &null {
                return self._fatal(f"parse failed for fid {fid}");
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

        for fid: u32 in fids {
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
fn FrontendAction::_sema() -> bool {
    var _t = TimeRegion("Sema");

    self._stage = TUStage::Sema;
    var fe = self._ci->invocation().frontend;
    if fe.dump_type_info { std::print(f"-- type info: {self.path.full_path()} (not yet implemented) --"); }

    // --print-sema styling follows --print-ast, exactly like --print-symbols:
    // 'tree' -> dump(), 'canonical' -> canonical(), otherwise flat diag rows.
    var sema_opts: PrintOptions = PrintOptions::diag();
    if fe.print_sema {
        var ast_mode = fe.print_ast;
        if      ast_mode == "tree"      { sema_opts = PrintOptions::dump();      }
        else if ast_mode == "canonical" { sema_opts = PrintOptions::canonical(); }
        sema_opts.color = !self._ci->invocation().diag.no_color;
        std::print(f"-- sema: {self.path.full_path()} --");
    }

    // Phases I -> E -> V -> N (ImportResolution, Expand, Verify,
    // NameResolution) across every fid of this TU's graph. Run in REVERSE
    // tree order so leaf modules build their overlays before importers fold
    // re-exports (DAG order guarantees source-overlay completeness,
    // RESOLUTION.md #2). run_to stops at NamesResolved; the T/... stubs are
    // not reached.
    var n = self._fids.size();
    for var i: usize = 0; i < n; ++i {
        var fid = self._fids[n - 1 - i];
        var ctx = self._global_scope->get_context(fid);
        if ctx == &null { continue; }
        var tu = reinterpret_cast::<*TranslationUnit>(ctx->tu);
        if tu == &null { continue; }
        var sem = Sema(ctx, self._global_scope);
        sem.run_to(SemaPhase::NamesResolved);
        ctx->diag_sink.drain_into(self._ci->diag());

        // Dump INSIDE the loop: SemaDump reads sc.phase / sc.well_known, which
        // live on this fid's SemaContext and die with `sem` at loop exit.
        if fe.print_sema { SemaDump(&(sem.sc), sema_opts).run(); }
    }

    if fe.print_imports { self._dump_overlays(); }

    // TODO(sema): full pipeline once N/T/checks land: Sema(ctx, gs).run().
    return true;
}

fn FrontendAction::_codegen() -> bool {
    var _t = TimeRegion("Codegen");

    self._stage = TUStage::Codegen;


    {
        var _tw = TimeRegion("ClangStartupWait");
        self._ci->pool()->wait_group(CLANG_STARTUP_GROUP());
    }

    var be = self._ci->backend();
    if (be == &null) || (!be->ready()) {
        return self._fatal("clang backend not ready");
    }

    var kfid    = self._file_id;
    var sink    = BufferedDiagSink{};
    var adapter = be->begin_tu(&sink, kfid);

    var ctx = self._global_scope->get_context(self._file_id);
    if ctx == &null {
        be->end_tu(adapter);
        return self._fatal("codegen: no ASTContext for main fid");
    }

    var ksize = static_cast::<u32>(self._ci->sm()->get_file_size(self._file_id));
    if ksize == 0 {
        be->end_tu(adapter);
        return self._fatal("codegen: zero-size main file");
    }

    var fe  = self._ci->invocation().frontend;
    var out = fe.output;
    if out.empty() { out = "a.o"; }

    var cg = CodegenBackend(be, ctx, kfid, &(ctx->codegen_alloc), ksize);
    cg.set_print_cg(fe.print_cg, self.path.full_path());

    var ok = false;
    {
        var _tr = TimeRegion("Emit");
        ok = cg.run(out);
    }

    // end_tu FIRST: it flushes any builder still open in the adapter, so
    // draining before it would silently drop the last diagnostic.
    be->end_tu(adapter);
    sink.drain_into(self._ci->diag());

    if !ok {
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
    // TODO: MacroTable::as_string not yet implemented
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
    if k == OverlayTargetKind::FfiAnchor    { return "ffi";    }
    return "?";
}

fn _overlay_vis_str(v: OverlayVisibility) -> string {
    if v == OverlayVisibility::Public    { return "pub";  }
    if v == OverlayVisibility::Protected { return "prot"; }
    if v == OverlayVisibility::Private   { return "priv"; }
    return "?";
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
        var imms = ctx->get_imm_table();
        var rows = vec::<ImportOverlay::Row>();
        ov->collect_rows(rows);
        for var i: usize = 0; i < rows.size(); ++i {
            var row  = rows[i];
            var name = ("<?>") if (imms == &null) else (imms->get_ident(row.key));
            var amb  = (" [AMBIGUOUS]") if (row.entry->is_ambiguous()) else ("");
            std::print(f"  {name}: {row.entry->targets.size()} target(s){amb}");
            for var t: usize = 0; t < row.entry->targets.size(); ++t {
                var tg = row.entry->targets[t];
                std::print(f"    - {_overlay_kind_str(tg.kind)} src=fid {tg.src_fid} vis={_overlay_vis_str(tg.vis)}");
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
    inline "c++" { if (::getenv("MEM_STATS") == nullptr) return; }

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
    inline "c++" {
        kairo::GlobalRecycler::instance().stats(retained_blocks, retained_bytes);
    }

    std::eprintln(f"[mem] TU contexts:        {tu_count}");
    std::eprintln(f"[mem] arena live bytes:   {total_bytes / (1024*1024)} MB ({total_bytes} B)");
    std::eprintln(f"[mem] arena slabs:        {total_slabs}");
    std::eprintln(f"[mem] alloc calls:        {total_allocs}");
    std::eprintln(f"[mem] bytes / alloc:      {(total_bytes / total_allocs) if (total_allocs > 0) else 0}");
    std::eprintln(f"[mem] recycler retained:  {retained_bytes / (1024*1024)} MB ({retained_blocks} blocks)");
}