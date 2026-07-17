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
///   print_ir, print_bcir) are checked at each stage boundary and are orthogonal
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
import Token::TokenCacheManager::*;
import Command::Command::*;
import Command::FlagRegistry::*;
import Config::Invocation::*;
import Driver::BatchResult::*;
import Driver::TUResult::*;
import Driver::TUStage::*;
import Preprocessor::Preprocessor::*;
import Parser::ASTParse::*;
import AST::Context::GlobalDisambigTable::*;
import AST::Printer::ASTPrinter::*;
import Token::TokenPrinter::*;
import Sema::NullableTypeLowering::*;
import Interop::Clang::ClangBackend::*;

ffi "c++" import "llvm/TargetParser/Host.h";
ffi "c++" import "llvm/Support/raw_ostream.h";
ffi "c++" import "llvm/Support/Threading.h";
ffi "c++" import "llvm/TargetParser/Triple.h";
ffi "c++" import "llvm/MC/TargetRegistry.h";
ffi "c++" import "llvm/MC/MCSubtargetInfo.h";
ffi "c++" import "llvm/Support/TargetSelect.h";
ffi "c++" import "llvm/Support/raw_ostream.h";
ffi "c++" import "llvm/TargetParser/Triple.h";
ffi "c++" import "llvm/TargetParser/Host.h";
ffi "c++" import "llvm/Target/TargetMachine.h";
ffi "c++" import "llvm/Target/TargetOptions.h";
ffi "c++" import "llvm/Support/CodeGen.h";

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
    fn ok(self)      -> bool    { return self._stage == TUStage::Done; }
    fn failed(self)  -> bool    { return self._stage == TUStage::Failed; }

    priv fn _fatal(self, msg: string) -> bool;
    priv fn _load(self)        -> bool;
    priv fn _preprocess(self)  -> bool;
    priv fn _parse(self)       -> bool;
    priv fn _sema(self)        -> bool;
    priv fn _codegen(self)     -> bool;
    priv fn _dump_tokens(self);
    priv fn _dump_macros(self);
    priv fn _dump_imports(self);
    priv fn _dump_mem_stats(self);
}

/// Shared resource hub for a single compilation.
///
/// Constructed once per \c main() invocation. Owns all subsystems, parses the
/// CLI, builds a \c CompilerInvocation, and drives \c FrontendAction execution
/// via \c execute(). Destruction releases all resources in reverse-dependency
/// order.
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
    priv var _parsed: ParsedArgs;
    priv var _inv:    CompilerInvocation;

    // --- Constructors ----------------------------------------------------

    /// Constructs all subsystems, parses \p argv, and applies the resulting
    /// invocation to live subsystems via \c _apply_invocation().
    ///
    /// Construction order rationale:
    ///   - Pool first: SM and TCM hold a pointer to it.
    ///   - DiagEngine before consumers: consumers register into it.
    ///   - SM before consumers: consumers need it for source context.
    ///   - Command last: CLI parsing may emit diagnostics into the engine.
    fn CompilerInstance(self, argc: i32, argv: *(*kairo::std::Legacy::char)) {
        self._diag   = std::create::<DiagEngine>        ();
        self._vfm    = std::create::<VirtualFileManager>(self._diag);
        self._pretty = std::create::<PrettyDiagConsumer>();
        self._basic  = std::create::<BasicDiagConsumer> ();
        self._diag->add_consumer(self._pretty); // pretty is the default consumer

        // no sm for now since we only want cli diags
        self._cmd = std::create::<Command>(argc, argv, self._diag);

        register_kairo_flags(self._cmd);
        self._parsed = self._cmd->parse();

        if self._parsed.ok {
            self._inv = CompilerInvocation::from_args(self._parsed);
            self._apply_invocation();
        }

        self._pool = std::create::<ThreadPool>(usize(
                    (llvm::hardware_concurrency().compute_thread_count())
            if   (self._inv.frontend.thread_count == 0)
            else (self._inv.frontend.thread_count)
        ));

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
        // MemoryBufferRef views into _vfm's mmaps. Pool tasks touching it
        // (startup/preload groups) must be drained before teardown.
        if self._backend != &null {
            self._pool->wait_group(CLANG_STARTUP_GROUP());
            self._pool->wait_group(CLANG_PRELOAD_GROUP());
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
    fn backend(self)      -> *ClangBackend            { return self._backend; }
    // --- CLI query helpers -----------------------------------------------

    fn wants_help(self)    -> bool { return self._parsed.get_bool("help");               }
    fn wants_version(self) -> bool { return self._parsed.get_bool("version");            }
    fn wants_explain(self) -> bool { return !self._parsed.get_string("explain").empty(); }
    fn args_ok(self)       -> bool { return self._parsed.ok;                             }

    /// True when any info flag is present whose subsystem is not yet live.
    fn wants_info_query(self) -> bool {
        return self._parsed.get_bool("print-targets")
            || self._parsed.get_bool("print-cpus")
            || self._parsed.get_bool("print-dirs")
            || self._parsed.get_bool("print-clang-args")
            || self._parsed.get_bool("print-ld-args")
            || self._parsed.get_bool("print-target-info")
            || self._parsed.get_bool("print-pass-pipeline")
            || self._parsed.get_bool("print-cfg");
    }

    // --- Identity actions ------------------------------------------------

    fn get_target_triple(self) -> string {
        var triple = llvm::Triple(llvm::Triple::normalize(llvm::sys::getProcessTriple()));
        if (triple.getVendor()) == (llvm::Triple::UnknownVendor) && (triple.isOSLinux()) {
            triple.setVendor(llvm::Triple::PC);
        }

        return std::nstring_to_string(triple.getTriple());
    }

    fn print_help(self) {
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
        var code = self._parsed.get_string("explain");

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
    priv fn _effective_triple(self) -> string {
        var t = self._parsed.get_string("target");

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

    // =========================================================================
    //  --print-targets
    // =========================================================================

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

    // =========================================================================
    //  --print-cpus
    // =========================================================================

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

        if TM == &null {
            self._diag->report(DiagID::U001F, f"failed to create TargetMachine for '{string(triple.raw())}\x27").emit();
            return 1;
        }

        finally {
            delete TM;
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

    // =========================================================================
    //  --print-target-info
    // =========================================================================

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
        if self._parsed.get_bool("print-targets") {
            return self.print_targets();
        }

        if self._parsed.get_bool("print-cpus") {
            return self.print_cpus();
        }

        if self._parsed.get_bool("print-target-info") {
            return self.print_target_info();
        }

        if self._parsed.get_bool("print-cfg") {
            for s: string in self._parsed.get_list("cfg") { std::print(s); }
            return 0;
        }
        return 0;
    }

    fn flush_errors(self) {
        if self._inv.diag.format == "basic" {
            self._basic->finalize_to_stderr();
        } else {
            self._pretty->finalize_to_stderr();
        }
    }

    // --- Compilation pipeline --------------------------------------------
    // the step to index, and create the shared instance
    fn index(self, cwd: Path) {
        var rb = ImportResolver::Builder().cwd(cwd);
        for dir: string in self._inv.include_dirs { rb.add_include(Path(dir)); }
        for dir: string in self._inv.macro_paths  { rb.add_include(Path(dir)); }
        self._imp = rb.create_ptr(self._pool);

        self._pp = std::create::<PreProcessor>(
            self._sm, self._tcm, self._imp, self._pool,
            self._diag, self._g_scope, &self._inv, self._inv.pp);

        // Shared clang backend: kick the expensive startup (invocation parse,
        // TargetInfo, FileManager/SourceManager) onto the pool NOW so it runs
        // concurrently with lex/preprocess. startup() and preload() serialize
        // on the backend's internal mutex, so this cannot race the per-TU
        // preload tasks. Joined via CLANG_STARTUP_GROUP before codegen.
        var bcfg = ClangBackendConfig{};
        (bcfg.triple) = self._effective_triple();
        self._backend = std::create::<ClangBackend>(self._sm, bcfg);

        inline "c++" {
            auto* be = _backend;
            _pool->enqueue([be]() { be->startup(); }, CLANG_STARTUP_GROUP());
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

        if self._inv.input_files.empty() {
            self._diag->report(DiagID::U001F, "no input files").emit();
            result.aborted = true;
            return result;
        }

        Logger::info(Logger::Stage::Driver,
            f"CompilerInstance::execute: {self._inv.input_files.size()} file(s)");

        result.tu_results.reserve(self._inv.input_files.size());

        for path_str: string in self._inv.input_files {
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

    // --- Private ---------------------------------------------------------

    /// Maps invocation fields to live subsystem setters. Called once after
    /// the invocation is built. Fields whose subsystem does not yet exist are
    /// silently accepted stored in the invocation for future use.
    priv fn _apply_invocation(self) {
        var d  = self._inv.diag;
        var fe = self._inv.frontend;

        if d.format == "basic" {
            self._diag->remove_consumer(self._pretty);
            self._diag->add_consumer(self._basic);
        }

        if d.no_color { self._pretty->set_color(false); }

        self._diag->set_error_limit(u32(d.max_errors));
        self._diag->set_warnings_as_errors(d.warnings_as_errors);

        // Logger was initialised at Trace in main(); quiet it down unless
        // the user asked for verbose output.
        if !fe.verbose {
            Logger::set_level(Logger::Level::Warn);
        }
    }
}

// =========================================================================
//  FrontendAction out-of-line definitions
// =========================================================================

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
    if fe.stops_at_parse() { self._stage = TUStage::Done; return; }

    if !self._sema() { return; }
    if fe.stops_at_sema() { self._stage = TUStage::Done; return; }

    if !self._codegen() { return; }

    self._stage = TUStage::Done;
    Logger::info(Logger::Stage::Driver,
        f"FrontendAction: done '{self.path.full_path()}' ({self.result.elapsed_ms:.2}ms)");
}

// =========================================================================
//  Pipeline stages each returns true to continue, false to halt.
// =========================================================================

/// Emits a fatal diagnostic, marks the TU as failed, and returns false.
fn FrontendAction::_fatal(msg: string) -> bool {
    self._ci->diag()->report(DiagID::U001F, msg).emit();
    self.result.had_fatal = true;
    self._stage = TUStage::Failed;
    return false;
}

/// Registers the source file with \c SourceManager and obtains a file ID.
fn FrontendAction::_load() -> bool {
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
    self._stage = TUStage::Preprocessing;

    var pp_opts = self._ci->invocation().pp;
    if pp_opts.defines.size() > 0 {
        Logger::warn(Logger::Stage::Preprocessor,
            f"-D defines ({pp_opts.defines.size()}) not yet implemented; ignored");
    }

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

    // All fids for this TU's dependency graph are now final: mirror them into
    // the shared clang SM off-thread while parse runs. preload() is idempotent
    // (maps only the unmapped tail) and self-runs startup if that task lost
    // the race. Joined via CLANG_PRELOAD_GROUP before codegen touches clang.
    if self._ci->backend() != &null {
        inline "c++" {
            auto* be = _ci->backend();
            _ci->pool()->enqueue([be]() { be->preload(); }, CLANG_PRELOAD_GROUP());
        }
    }

    var fe = self._ci->invocation().frontend;
    if fe.print_tokens  { self._dump_tokens();  }
    if fe.print_macros  { self._dump_macros();  }
    if fe.print_imports { self._dump_imports(); }
    return true;
}

fn FrontendAction::_parse() -> bool {
    self._stage = TUStage::Parsing;

    var fids = self._fids;  // tree order, fids[0] == main

    // index phase: Index-mode ASTParse over each fid (same grammar as the
    // full parse, shallow materialization). Replaces the old ASTIndex
    // token-level pre-pass.
    for fid: u32 in fids {
        inline "c++" {
            auto captured_fid  = fid;
            auto captured_self = this;
            _ci->pool()->enqueue([captured_fid, captured_self]() {
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

    // parallel parse + low-water-mark flush
    inline "c++" {
        const size_t N = fids.size();

        // done[i] published (release) by the parse task for fids[i];
        // read (acquire) by the flusher. heap so the flusher thread can hold it.
        auto* done = new libcxx::atomic<bool>[N];
        for (size_t i = 0; i < N; ++i) done[i].store(false, libcxx::memory_order_relaxed);

        auto* engine = _ci->diag();
        auto* fids_p = &fids;
        auto* gs     = _global_scope;

        // flusher: drains contiguous done-prefix in fid order, single-threaded.
        libcxx::thread flusher([=]() {
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

        // enqueue parse tasks. each publishes done[i] LAST.
        for (size_t i = 0; i < N; ++i) {
            u32 fid = (*fids_p)[i];
            _ci->pool()->enqueue([gs, fid, done, i]() {
                auto* ctx = gs->get_context(fid);
                if (ctx) {
                    ASTParse parser(ctx, nullptr, gs, ASTParse::ParseMode::Full);
                    auto* tu = parser.parse();
                    ctx->tu = reinterpret_cast<void*>(tu);
                }
                // publish AFTER sink fully written + tu set. release pairs with acquire
                done[i].store(true, libcxx::memory_order_release);
            }, u8(6));
        }

        _ci->pool()->wait_group(u8(6));  // all parses done => all done[i] set
        flusher.join();                  // flusher drains tail, exits
        delete[] done;
    }

    // NullableTypeLowering: lower T? -> std::Nullable<T> per fid
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

    // dump the hoisted scope as well
    if !ast_mode.empty() {
        std::print(f"-- hoisted scope: {self.path.full_path()} --");
        self._global_scope->dump();
    }

    self._dump_mem_stats();
    return true;
}

/// Semantic analysis stage not yet implemented.
fn FrontendAction::_sema() -> bool {
    self._stage = TUStage::Sema;
    var fe = self._ci->invocation().frontend;
    if fe.print_sema     { std::print(f"-- sema: {self.path.full_path()} (not yet implemented) --"); }
    if fe.dump_type_info { std::print(f"-- type info: {self.path.full_path()} (not yet implemented) --"); }
    // TODO(sema): var typed = Sema(ci, ast).analyze();
    return true;
}

/// Code generation stage not yet implemented.
fn FrontendAction::_codegen() -> bool {
    self._stage = TUStage::Codegen;

    // Join the shared clang backend: startup + fid preload must be complete
    // before anything touches the clang SM. This is the happens-before edge
    // the ClangLocMap threading contract requires.
    self._ci->pool()->wait_group(CLANG_STARTUP_GROUP());
    self._ci->pool()->wait_group(CLANG_PRELOAD_GROUP());

    var be = self._ci->backend();
    if (be != &null) && (be->ready()) {
        // TODO(codegen): per-TU token injection over the shared clang TU:
        //   var adapter = be->begin_tu(&tu_sink, self._file_id);
        //   ... build the clang token stream (borrowed .kro locs via
        //       be->locmap(), divergent literals via the arena buffer),
        //       replace FrontendOpts.Inputs, ExecuteAction on be->ci() ...
        //   be->end_tu(adapter);   // flushes trailing notes, detaches client
        //   tu_sink.drain_into(self._ci->diag());
        0;
    }

    var fe = self._ci->invocation().frontend;
    if fe.print_ir   { std::print(f"-- IR: {self.path.full_path()} (not yet implemented) --"); }
    if fe.print_bcir { std::print(f"-- BCIR: {self.path.full_path()} (not yet implemented) --"); }
    if fe.verify_ir  { std::print(f"-- IR verify: {self.path.full_path()} (not yet implemented) --"); }
    // TODO(codegen): CodeGen(ci, typed).emit();
    return true;
}

// =========================================================================
//  Post-stage dump helpers
// =========================================================================

fn FrontendAction::_dump_tokens() {
    var tokens = self._ci->tcm()->get_tokens(self._file_id);
    if tokens == &null {
        std::print(f"-- token stream: {self.path.full_path()} (none) --");
        return;
    }

    var imm_tbl = self._ci->tcm()->get_imm_table_for_fid(self._file_id);

    var printer = TokenPrinter(
        self._ci->tcm(),
        self._ci->invocation().diag.no_color
    );

    printer.print_stream(tokens, self.path.full_path());
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
        for var i: usize = 0; i < tu->imports.size(); ++i {
            // TODO: ASTPrinter::decl_summary not yet implemented
            0;
        }
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