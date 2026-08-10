/// --- The Kairo Project ------------------------------- Driver/Kairo.k --- ///
///
///   Compiler driver entry point.
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
///   Three-layer Clang-style driver pipeline
///   -----------------------------------------
///   Layer 1  CompilerInvocation  Strongly-typed option structs  (Options::*)
///   Layer 2  CompilerInstance    Shared resource owner          (Driver::CompilerInstance)
///   Layer 3  FrontendAction      Per-file pipeline executor     (driven by FrontendOptions)
///
///   main() is intentionally thin:
///     1. Global runtime setup (locale, Logger).
///     2. Construct CompilerInstance parses argv, wires all shared resources.
///     3. Handle identity/info early exits via CI query methods.
///     4. Call ci->execute(cwd) to run the compilation pipeline.
///     5. Flush diagnostics and global teardown.
///
///   All new driver behaviour belongs in CompilerInstance or the Invocation
///   sub-option structs, not here.
///

import Driver::CompilerInstance::*;
import Support::TimeReport::*;
import Tooling::ParseAPI::*;
import AST::Visitor::ASTWriter::*;

ffi "c++" import "Native/KTimeReport.hh";  // strcmp/strncmp for _scan_timing_flags
ffi "c++" import "llvm/Support/InitLLVM.h";
ffi "c++" import "llvm/Support/Locale.h";
ffi "c++" import "llvm/MC/TargetRegistry.h";
ffi "c++" import "llvm/MC/MCSubtargetInfo.h";
ffi "c++" import "llvm/Support/TargetSelect.h";
ffi "c++" import "llvm/Support/raw_ostream.h";
ffi "c++" import "llvm/TargetParser/Triple.h";
ffi "c++" import "llvm/TargetParser/Host.h";
ffi "c++" import "llvm/Target/TargetMachine.h";
ffi "c++" import "llvm/Target/TargetOptions.h";
ffi "c++" import "llvm/Support/CodeGen.h";

fn init_runtime(argc: i32, argv: *(*kairo::std::Legacy::char)) {
    static var init_llvm = llvm::InitLLVM(argc, argv);
    llvm::InitializeAllTargetInfos();
    llvm::InitializeAllTargets();
    llvm::InitializeAllTargetMCs();
    llvm::InitializeAllAsmParsers();
    llvm::InitializeAllAsmPrinters();

    llvm::setBugReportMsg(
        r"PLEASE submit a bug report to https://github.com/kairolang/kairo/issues and include the crash backtrace.\n"
    );

    // Force eager locale initialisation on the main thread before any workers
    // start. Wide-string machinery on Linux resolves lazily and will segfault
    // if first called from a worker thread with a shallow stack.
    inline "c++" {
        // only reason this is in inline c++
        // stage0 doesnt like accessing global namespaces
        // ::foo simply doesnt parse in stage0
        ::setlocale(LC_ALL, "");
        (void)::wcslen(WIDE_STR(""));
    }

    libcxx::use_facet::<libcxx::ctype::<char>>(libcxx::locale());
    libcxx::use_facet::<libcxx::num_put::<std::Legacy::char>>(libcxx::locale());
    libcxx::use_facet::<libcxx::num_get::<std::Legacy::char>>(libcxx::locale());

    { // Force narrow char locale facets used by stringstream/to_string
        var oss: libcxx::ostringstream;
        oss << static_cast::<usize>(1) << 1.0;
        oss.str();
    }

    const eval if defined(__linux__) {
        var attr: pthread_attr_t;
        pthread_attr_init(&attr);
        pthread_attr_setstacksize(&attr, static_cast::<usize>(64 * 1024 * 1024));
        // pthread_setattr_default_np(&attr);
        pthread_attr_destroy(&attr);
    }
}

/// \brief raw argv scan for the timing switches, before any option machinery
///        exists.
///
/// \details The timer has to be armed before \c CompilerInstance is
///          constructed   that constructor spawns the whole ThreadPool and
///          wires every subsystem, and it is not cheap. But the flags are not
///          parsed until that same constructor runs, so the ordinary path
///          cannot answer "is timing on" early enough. Hence a hand scan.
///
///          This decides ONLY whether to arm, and whether tracing is wanted.
///          The trace PATH still comes from the real parse afterwards; this is
///          deliberately not a second command-line parser.
///
/// \param trace_out set when any form of --time-trace is present.
/// \return true if timing should be armed.
fn _scan_timing_flags(
    argc:      i32,
    argv:      *(*kairo::std::Legacy::char),
    trace_out: *bool
) -> bool {
    var on = false;
    (*trace_out) = false;

    inline "c++" {
        for (int i = 1; i < argc; ++i) {
            const char *a = argv[i];
            if (a == nullptr) { continue; }
            if (::strcmp(a, "--time-passes") == 0) { on = true; continue; }
            if (::strncmp(a, "--time-trace", 12) == 0) {
                // --time-trace, --time-trace=PATH, --time-trace PATH
                on = true;
                *trace_out = true;
                continue;
            }
        }
    }

    return on;
}

fn main(argc: i32, argv: *(*kairo::std::Legacy::char)) -> i32 {
    var want_tt = false;
    var want_tp = _scan_timing_flags(argc, argv, &want_tt);
    if want_tp { time_enable(true, want_tt); }

    var ci: *CompilerInstance = &null;

    {
        var _t_startup = TimeRegion("Startup");

        {
            var _t_rt = TimeRegion("Runtime");
            Logger::init(Logger::Level::Trace);
            init_runtime(argc, argv);
        }

        {
            var _t_inst = TimeRegion("Instance");
            ci = std::create::<CompilerInstance>(argc, argv);
        }
    }


    finally {
        Logger::set_dump_path(
            (((std::get_exe_path()).parent_path()) / r"kairo.log").generic_wstring()
        );
        Logger::dump_to_file();
        Logger::shutdown();
        GlobalRecycler::shutdown_allocator_runtime();
    }

    finally { std::destroy(ci); }

    // --- Identity: help / version / explain ------------------------------
    //   These exit before any compilation state is needed.
    if ci->wants_help()    { ci->print_help();    return 0; }
    if ci->wants_version() { ci->print_version(); return 0; }
    if ci->wants_explain() { return ci->run_explain();      }

    // --- Info queries: --print-targets, --print-cfg, etc. ----------------
    //   Most are stubs until their subsystems exist. run_info_query() handles
    //   the implemented subset (currently --print-cfg).
    if ci->wants_info_query() { return ci->run_info_query(); }

    // --- Validate CLI args -----------------------------------------------
    if !ci->args_ok() {
        ci->flush_errors();
        return 1;
    }

    var fe_time = ci->invocation().frontend;
    if fe_time.time_passes || !fe_time.time_trace.empty() {
        want_tp = true;
        want_tt = want_tt || !fe_time.time_trace.empty();
        time_enable(true, want_tt);
    }

    {
        var _t_init = TimeRegion("Initialize");
        ci->initialize(Path::cwd());
    }

    // --- Layer 3: execute the FrontendAction pipeline --------------------
    //
    // The action strategy is encoded in CompilerInvocation::frontend.action.
    // FrontendOptions::stops_at_* helpers gate each pipeline stage.
    var result = ci->execute();
    ci->flush_errors();

    if want_tp {
        time_finish();
        time_print();

        if want_tt {
            if time_write_trace(fe_time.time_trace) {
                std::eprintln(f"time trace written to '{fe_time.time_trace}\x27");
            } else {
                std::eprintln(f"error: cannot write time trace to '{fe_time.time_trace}\x27");
            }
        }
    }

    if ci->invocation().frontend.verbose {
        std::eprintln(f"compilation: {result.summary()}");
    }

    return 0 if result.ok() else 1;
}