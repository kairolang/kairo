/// --- The Kairo Project
///
///   Frontend action selection, pipeline control, and testing options.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
///

import Command::ParsedArgs::*;

///
/// \brief Selects the highest-priority pipeline action.
///
/// Precedence (highest -> lowest):
///   Preprocess > SyntaxOnly > TypeCheckOnly > EmitObjOnly
///   > EmitAsm > EmitLLVMIR > EmitLLVMBC > EmitObj (default)
///
/// Post-stage dump flags (print_tokens, print_macros, print_ast, ...) are
/// orthogonal to the primary action and can be combined with any of them.
///
enum FrontendActionKind derives u8 {
    EmitObj,       ///< compile + link (default)
    EmitObjOnly,   ///< compile to .o, no link              (-c)
    EmitAsm,       ///< emit assembly                       (-S / --emit asm)
    EmitLLVMIR,    ///< emit LLVM IR text                   (--emit llvm-ir)
    EmitLLVMBC,    ///< emit LLVM bitcode                   (--emit llvm-bc)
    Preprocess,    ///< preprocessor output only            (-E)
    SyntaxOnly,    ///< stop after parsing                  (--syntax-only)
    TypeCheckOnly, ///< stop after semantic analysis        (--type-check-only)
}

class FrontendOptions {
    // output
    pub var output:              string = "";
    pub var out_dir:             string = "";
    pub var entry:               string = "main";
    pub var emit:                string = "obj";
    // verbosity / timing
    pub var time_trace:          string = "";
    pub var stats_file:          string = "";
    // concurrency
    pub var thread_count:        i32    = 0; ///< 0 = hardware concurrency
    pub var max_threads:         i32    = 0; ///< 0 = no cap
    pub var max_expr_depth:      i32    = 512;
    pub var max_scope_depth:     i32    = 256;
    // primary action
    pub var action:              FrontendActionKind = FrontendActionKind::EmitObj;
    // verbosity / timing
    pub var verbose:             bool   = false;
    pub var quiet:               bool   = false;
    pub var suppress:            bool   = false;
    pub var time_passes:         bool   = false;
    pub var print_stats:         bool   = false;
    // post-stage dump flags (independent of primary action)
    pub var dump_preprocessed:   bool   = false; ///< --dump-preprocessed: print reconstructed source to stdout
    pub var print_tokens:        bool   = false;
    pub var print_macros:        bool   = false;
    pub var print_imports:       bool   = false;
    pub var print_symbols:       bool   = false;
    pub var print_ast:           string = "";
    pub var print_sema:          bool   = false;
    pub var print_cg:            bool   = false;
    pub var print_bcir:          bool   = false;
    pub var print_generics:      bool   = false;
    pub var dump_type_info:      bool   = false;
    pub var print_regalloc:      bool   = false;
    pub var print_pass_pipeline: bool   = false;
    // verification passes
    pub var verify_ir:           bool   = false;
    pub var verify_bcir:         bool   = false;
    pub var bcir_verbose:        bool   = false;
    pub var bcir_stats:          bool   = false;
    // output
    pub var shared:              bool   = false;
    pub var static_:             bool   = false;
    pub var no_entry:            bool   = false;
    pub var dll:                 bool   = false;
    pub var save_temps:          bool   = false;
    // parser / sema
    pub var max_generic_instantiations: i32 = 0x7FFFFFFE;
    pub var max_tuple_arity:            i32 = 128;

    // incremental compilation
    pub var incremental:         bool   = false;
    pub var incremental_dir:     string = ".kairo-cache";
    pub var force_recompile:     bool   = false;

    // module system
    pub var module_name:         string = "";
    pub var module_cache_dir:    string = ".kairo-modules";
    pub var no_module_cache:     bool   = false;

    // testing
    pub var testing:             bool   = false;
    pub var test_list:           bool   = false;
    pub var test_filter:         string = "";
    pub var test_format:         string = "pretty";
    pub var test_threads:        i32    = 0;       ///< 0 = logical CPU count
    pub var test_no_capture:     bool   = false;
    pub var test_timeout:        i32    = 0;       ///< 0 = no timeout (ms)
    pub var test_exit_code:      i32    = 1;

    // BCIR / AMT limits
    pub var max_borrow_depth:          i32 = 512;
    pub var max_amt_smartptr_rewrites: i32 = 8192;  ///< 0 = unlimited

    // helpers

    fn stops_at_preprocess(self) -> bool {
        return self.action == FrontendActionKind::Preprocess;
    }

    fn stops_at_parse(self) -> bool {
        return (self.action == FrontendActionKind::SyntaxOnly)
            || (self.action == FrontendActionKind::Preprocess);
    }

    fn stops_at_sema(self) -> bool {
        return (self.action == FrontendActionKind::TypeCheckOnly)
            || self.stops_at_parse();
    }

    fn stops_before_codegen(self) -> bool {
        return self.stops_at_sema();
    }
    
    /// Three-state string flag: absent -> "", bare -> `dfl`, =value -> value.
    priv static fn _mode_or(args: ref!(ParsedArgs), key: string, dfl: string) -> string {
        if !args.is_set(key) {
            return "";
        }
        
        var v = args.get_string(key);
        return (dfl) if (v.empty()) else (v);
    }

    static fn from_args(args: ref!(ParsedArgs)) -> FrontendOptions {
        var o = FrontendOptions();
        (o.output)          = args.get_string("output");
        (o.out_dir)         = args.get_string("out-dir");
        (o.entry)           = args.get_string("entry");
        (o.emit)            = args.get_string("emit");
        (o.shared)          = args.get_bool("shared");
        (o.static_)         = args.get_bool("static");
        (o.no_entry)        = args.get_bool("no-entry");
        (o.dll)             = args.get_bool("dll");
        (o.save_temps)      = args.get_bool("save-temps");
        (o.verbose)         = args.get_bool("verbose");
        (o.quiet)           = args.get_bool("quiet");
        (o.suppress)        = args.get_bool("suppress");
        (o.time_passes)     = args.get_bool("time-passes");
        (o.time_trace)      = args.get_string("time-trace");
        (o.print_stats)     = args.get_bool("print-stats");
        (o.stats_file)      = args.get_string("stats-file");
        (o.thread_count)    = args.get_i32("threads");
        (o.max_expr_depth)  = args.get_cfg_i32("max-expr-depth");
        (o.max_scope_depth) = args.get_cfg_i32("max-scope-depth");
        (o.max_threads)     = args.get_cfg_i32("max-threads");

        // post-stage dump flags
        (o.dump_preprocessed)   = args.get_bool("dump-preprocessed");
        (o.print_tokens)        = args.get_bool("print-tokens");
        (o.print_macros)        = args.get_bool("print-macros");
        (o.print_imports)       = args.get_bool("print-imports");
        (o.print_symbols)       = args.get_bool("print-symbols");
        (o.print_ast)           = FrontendOptions::_mode_or(args, "print-ast", "tree");
        (o.print_sema)          = args.get_bool("print-sema");
        (o.print_cg)            = args.get_bool("print-cg");
        (o.print_bcir)          = args.get_bool("print-bcir");
        (o.print_generics)      = args.get_bool("print-generics");
        (o.dump_type_info)      = args.get_bool("dump-type-info");
        (o.print_regalloc)      = args.get_bool("print-regalloc");
        (o.print_pass_pipeline) = args.get_bool("print-pass-pipeline");
        (o.verify_ir)           = args.get_bool("verify-ir");
        (o.verify_bcir)         = args.get_bool("verify-bcir");
        (o.bcir_verbose)        = args.get_bool("bcir-verbose");
        (o.bcir_stats)          = args.get_bool("bcir-stats");

        // parser / sema
        (o.max_generic_instantiations) = args.get_cfg_i32("max-generic-instantiations");
        (o.max_tuple_arity)            = args.get_cfg_i32("max-tuple-arity");

        // incremental compilation
        (o.incremental)      = args.get_bool("incremental");
        (o.incremental_dir)  = args.get_string("incremental-dir");
        (o.force_recompile)  = args.get_bool("force-recompile");

        // module system
        (o.module_name)      = args.get_string("module-name");
        (o.module_cache_dir) = args.get_string("module-cache-dir");
        (o.no_module_cache)  = args.get_bool("no-module-cache");

        // testing
        (o.testing)          = args.get_bool("test");
        (o.test_list)        = args.get_bool("test-list");
        (o.test_filter)      = args.get_string("test-filter");
        (o.test_format)      = args.get_string("test-format");
        (o.test_threads)     = args.get_i32("test-threads");
        (o.test_no_capture)  = args.get_bool("test-no-capture");
        (o.test_timeout)     = args.get_i32("test-timeout");
        (o.test_exit_code)   = args.get_i32("test-exit-code");

        // BCIR / AMT limits
        (o.max_borrow_depth)          = args.get_cfg_i32("max-borrow-depth");
        (o.max_amt_smartptr_rewrites) = args.get_cfg_i32("max-amt-smartptr-rewrites");

        // primary action: highest-priority flag wins
        if (args.get_bool("preprocess")) || (args.get_bool("dump-preprocessed")) {
            o.action = FrontendActionKind::Preprocess;
        } else if args.get_bool("syntax-only") {
            o.action = FrontendActionKind::SyntaxOnly;
        } else if args.get_bool("type-check-only") {
            o.action = FrontendActionKind::TypeCheckOnly;
        } else if args.get_bool("compile-only") {
            o.action = FrontendActionKind::EmitObjOnly;
        } else if args.get_bool("emit-asm") {
            o.action = FrontendActionKind::EmitAsm;
        } else {
            var emit_str = args.get_string("emit");

            if      (emit_str == "llvm-ir") { o.action = FrontendActionKind::EmitLLVMIR; }
            else if (emit_str == "llvm-bc") { o.action = FrontendActionKind::EmitLLVMBC; }
            else if (emit_str == "asm"    ) { o.action = FrontendActionKind::EmitAsm;    }
            else                            { o.action = FrontendActionKind::EmitObj;    }
        }

        return o;
    }
}