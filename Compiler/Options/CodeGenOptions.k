/// --- The Kairo Project ----------- Compiler/Options/CodeGenOptions.k ----- ///
///
///   Code generation, optimization, and instrumentation options.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://kairo-lang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Kairo Software Foundation
///
/// ------------------------------------------------------------------------ ///

import Command::ParsedArgs::*;

///
/// \class CodeGenOptions
///
/// \brief Controls optimization, debug info, instrumentation, hardening,
///        reproducible builds, and code generation behaviour.
///
class CodeGenOptions {

    // -- misc codegen ------------------------------------------------------
    pub var fp_model:              string = "precise";
    pub var fp_contract:           string = "off";
    pub var thread_model:          string = "posix";
    pub var unwind_tables:         string = "sync";
    pub var rtlib:                 string = "compiler-rt";
    pub var unwindlib:             string = "";
    // -- optimization ------------------------------------------------------
    pub var lto:                   string = "off";
    pub var profile:               string = "debug";
    // -- inliner / loop limits (from --c* config flags) --------------------
    pub var inline_cost:           f64    = 225.0;
    pub var max_inline_depth:      i32    = 256;
    pub var max_unroll_count:      i32    = 0;
    pub var max_for_unroll:        i32    = 1024;
    pub var max_lambda_capture:    i32    = 1024;
    pub var max_codegen_passes:    i32    = 0;
    pub var max_object_size_mb:    i32    = 512;
    // -- optimization ------------------------------------------------------
    pub var opt_level:             i32    = 0;
    pub var opt_size:              bool   = false;
    pub var opt_size_z:            bool   = false;
    // -- debug info --------------------------------------------------------
    pub var dwarf_version:         i32    = 5;
    pub var debug_info:            bool   = false;
    pub var no_debug_info:         bool   = false;
    pub var split_dwarf:           bool   = false;
    pub var debug_macros:          bool   = false;
    pub var embed_source:          bool   = false;
    // -- strip -------------------------------------------------------------
    pub var strip:                 bool   = false;
    pub var strip_debug:           bool   = false;
    // -- misc codegen ------------------------------------------------------
    pub var save_temps:            bool   = false;
    pub var signed_wrap:           bool   = false;
    pub var unsigned_trap:         bool   = false;
    pub var strict_aliasing:       bool   = false;
    pub var instrument_functions:  bool   = false;

    // -- codegen feature toggles (-f/-fno-) --------------------------------
    //  -1 = unset (profile default applies), 0 = disabled, 1 = enabled
    pub var f_inline:              i32 = -1;
    pub var f_force_inline:        i32 = -1;
    pub var f_tail_call:           i32 = -1;
    pub var f_dead_code_elim:      i32 = -1;
    pub var f_vectorize:           i32 = -1;
    pub var f_unroll_loops:        i32 = -1;
    pub var f_merge_functions:     i32 = -1;
    pub var f_function_sections:   i32 = -1;
    pub var f_data_sections:       i32 = -1;
    pub var f_omit_frame_pointer:  i32 = -1;
    pub var f_fast_math:           i32 = -1;
    pub var f_export_all:          i32 = -1;

    // -- hardening feature toggles -----------------------------------------
    pub var f_stack_protector:     i32 = -1;
    pub var f_pic:                 i32 = -1;
    pub var f_pie:                 i32 = -1;
    pub var f_split_stack:         i32 = -1;
    pub var f_trap_unreachable:    i32 = -1;
    pub var f_soft_float:          i32 = -1;

    // -- instrumentation feature toggles -----------------------------------
    pub var f_coverage:            i32 = -1;
    pub var f_profile_generate:    i32 = -1;
    pub var f_sanitize_address:    i32 = -1;
    pub var f_sanitize_thread:     i32 = -1;
    pub var f_sanitize_memory:     i32 = -1;
    pub var f_sanitize_ub:         i32 = -1;

    // -- LLVM pass control -------------------------------------------------
    pub var pass_plugins:          vec::<string>;  ///< --pass-plugin (repeatable)
    pub var disabled_passes:       vec::<string>;  ///< --disable-llvm-pass (repeatable)
    pub var mllvm_flags:           vec::<string>;  ///< --mllvm (repeatable)

    // -- XRay instrumentation ----------------------------------------------
    pub var xray:                  string = "none";
    pub var xray_threshold:        i32    = 200;

    // -- link-time optimizations -------------------------------------------
    pub var icf:                   bool   = false;
    pub var icf_mode:              string = "safe";
    pub var whole_program_vtables: bool   = false;
    pub var devirt:                bool   = false;

    // -- security hardening ------------------------------------------------
    pub var stack_clash:           bool   = false;
    pub var hot_cold_split:        bool   = false;
    pub var no_implicit_float:     bool   = false;
    pub var kernel_mode:           bool   = false;

    // -- reproducible builds -----------------------------------------------
    pub var source_date_epoch:     string = "";
    pub var remap_path_prefix:     vec::<string>;  ///< --remap-path-prefix (repeatable)
    pub var debug_prefix_map:      vec::<string>;  ///< --debug-prefix-map (repeatable)
    pub var no_timestamps:         bool   = false;

    // -- PGO / coverage config ---------------------------------------------
    pub var profile_use:           string = "";
    pub var coverage_format:       string = "llvm";
    pub var coverage_prefix_map:   vec::<string>;  ///< --coverage-prefix-map (repeatable)

    static fn from_args(args: ref!(ParsedArgs)) -> CodeGenOptions {
        var o = CodeGenOptions();
        (o.opt_level)            = args.get_i32("opt");
        (o.opt_size)             = args.get_bool("opt-size");
        (o.opt_size_z)           = args.get_bool("opt-size-z");
        (o.lto)                  = args.get_string("lto");
        (o.profile)              = args.get_string("profile");
        (o.debug_info)           = args.get_bool("debug-info");
        (o.no_debug_info)        = args.get_bool("no-debug-info");
        (o.dwarf_version)        = args.get_i32("dwarf-version");
        (o.split_dwarf)          = args.get_bool("split-dwarf");
        (o.debug_macros)         = args.get_bool("debug-macros");
        (o.embed_source)         = args.get_bool("embed-source");
        (o.strip)                = args.get_bool("strip");
        (o.strip_debug)          = args.get_bool("strip-debug");
        (o.max_inline_depth)     = args.get_cfg_i32("max-inline-depth");
        (o.inline_cost)          = args.get_cfg_f64("inline-cost-threshold");
        (o.max_unroll_count)     = args.get_cfg_i32("max-unroll-count");
        (o.max_for_unroll)       = args.get_cfg_i32("max-for-unroll-count");
        (o.max_lambda_capture)   = args.get_cfg_i32("max-lambda-capture-size");
        (o.max_codegen_passes)   = args.get_cfg_i32("max-codegen-passes");
        (o.max_object_size_mb)   = args.get_cfg_i32("max-object-size-mb");
        (o.save_temps)           = args.get_bool("save-temps");
        (o.signed_wrap)          = args.get_bool("signed-wrap");
        (o.unsigned_trap)        = args.get_bool("unsigned-trap");
        (o.strict_aliasing)      = args.get_bool("strict-aliasing");
        (o.instrument_functions) = args.get_bool("instrument-functions");
        (o.fp_model)             = args.get_string("fp-model");
        (o.fp_contract)          = args.get_string("fp-contract");
        (o.thread_model)         = args.get_string("thread-model");
        (o.unwind_tables)        = args.get_string("unwind-tables");
        (o.rtlib)                = args.get_string("rtlib");
        (o.unwindlib)            = args.get_string("unwindlib");

        // -- codegen feature toggles ---------------------------------------
        (o.f_inline)             = args.get_feature("inline");
        (o.f_force_inline)       = args.get_feature("force-inline");
        (o.f_tail_call)          = args.get_feature("tail-call");
        (o.f_dead_code_elim)     = args.get_feature("dead-code-elim");
        (o.f_vectorize)          = args.get_feature("vectorize");
        (o.f_unroll_loops)       = args.get_feature("unroll-loops");
        (o.f_merge_functions)    = args.get_feature("merge-functions");
        (o.f_function_sections)  = args.get_feature("function-sections");
        (o.f_data_sections)      = args.get_feature("data-sections");
        (o.f_omit_frame_pointer) = args.get_feature("omit-frame-pointer");
        (o.f_fast_math)          = args.get_feature("fast-math");
        (o.f_export_all)         = args.get_feature("export-all");

        // -- hardening feature toggles -------------------------------------
        (o.f_stack_protector)    = args.get_feature("stack-protector");
        (o.f_pic)                = args.get_feature("pic");
        (o.f_pie)                = args.get_feature("pie");
        (o.f_split_stack)        = args.get_feature("split-stack");
        (o.f_trap_unreachable)   = args.get_feature("trap-unreachable");
        (o.f_soft_float)         = args.get_feature("soft-float");

        // -- instrumentation feature toggles -------------------------------
        (o.f_coverage)           = args.get_feature("coverage");
        (o.f_profile_generate)   = args.get_feature("profile-generate");
        (o.f_sanitize_address)   = args.get_feature("sanitize-address");
        (o.f_sanitize_thread)    = args.get_feature("sanitize-thread");
        (o.f_sanitize_memory)    = args.get_feature("sanitize-memory");
        (o.f_sanitize_ub)        = args.get_feature("sanitize-ub");

        // -- LLVM pass control ---------------------------------------------
        for s in args.get_list("pass-plugin")       { o.pass_plugins.push_back(s);    }
        for s in args.get_list("disable-llvm-pass") { o.disabled_passes.push_back(s); }
        for s in args.get_list("mllvm")             { o.mllvm_flags.push_back(s);     }

        // -- XRay ----------------------------------------------------------
        (o.xray)                  = args.get_string("xray");
        (o.xray_threshold)       = args.get_i32("xray-threshold");

        // -- link-time optimizations ---------------------------------------
        (o.icf)                   = args.get_bool("icf");
        (o.icf_mode)              = args.get_string("icf-mode");
        (o.whole_program_vtables) = args.get_bool("whole-program-vtables");
        (o.devirt)                = args.get_bool("devirt");

        // -- security hardening --------------------------------------------
        (o.stack_clash)           = args.get_bool("stack-clash");
        (o.hot_cold_split)        = args.get_bool("hot-cold-split");
        (o.no_implicit_float)     = args.get_bool("no-implicit-float");
        (o.kernel_mode)           = args.get_bool("kernel-mode");

        // -- reproducible builds -------------------------------------------
        (o.source_date_epoch)     = args.get_string("source-date-epoch");
        (o.no_timestamps)         = args.get_bool("no-timestamps");
        for s in args.get_list("remap-path-prefix")   { o.remap_path_prefix.push_back(s);   }
        for s in args.get_list("debug-prefix-map")     { o.debug_prefix_map.push_back(s);     }

        // -- PGO / coverage config -----------------------------------------
        (o.profile_use)           = args.get_string("profile-use");
        (o.coverage_format)       = args.get_string("coverage-format");
        for s in args.get_list("coverage-prefix-map") { o.coverage_prefix_map.push_back(s); }

        return o;
    }
}