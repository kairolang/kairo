/// --- The Kairo Project ---------------------------- Config/Language.k --- ///
///
///   Language semantics and standard configuration.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Command::ParsedArgs::*;

///
/// \class LangOptions
///
/// \brief Language semantics and standard configuration.
///
/// Deserialised from ParsedArgs once by CompilerInvocation::from_args().
/// Nothing downstream reads raw flag keys after this point.
///
class LangOptions {
    pub var edition:         string = "2026";

    // -- build mode / AMT --------------------------------------------------
    pub var borrow_check:    string = "";  ///< warn|error|off
    pub var amt_mode:        string = "";  ///< warn|error|silent
    pub var amt_report_file: string = "";  ///< path for AMT audit log
    pub var panic_handler:   string = "";  ///< custom panic handler symbol

    // -- config flags (--cfg) ----------------------------------------------
    pub var cfg_flags:       vec::<string>;  ///< --cfg name or --cfg name=value

    // -- -f / -fno- feature toggles ----------------------------------------
    // -1 = unset (profile default applies), 0 = disabled, 1 = enabled
    pub var verify_interfaces:   i32 = -1;
    pub var const_checks:        i32 = -1;
    pub var overflow_checks:     i32 = -1;
    pub var strict_null:         i32 = -1;
    pub var implicit_conv:       i32 = -1;
    pub var rtti:                i32 = -1;
    pub var union_inference:     i32 = -1;
    pub var exceptions:          i32 = -1;
    pub var unsafe_feature:      i32 = -1;
    /// -funwind: Kairo functions are not `noexcept`, so a C++ exception may
    /// pass through every Kairo frame. Unset or -fno-unwind: each is
    /// `noexcept` unless marked `@unwind`.
    pub var unwind:              i32 = -1;
    /// -fduck-generics: `<T: type>` is accepted, its body typed as written
    /// and emitted as an unconstrained template that clang checks per
    /// instance (MONO.md D1). Unset or -fno-duck-generics: `: type` is an
    /// error. Transitional: it goes when the self-host corpus no longer
    /// needs it.
    pub var duck_generics:       i32 = -1;

    // -- hard kill-switches ------------------------------------------------
    pub var no_assert:       bool = false;
    pub var no_finally:      bool = false;
    pub var no_exceptions:   bool = false;
    pub var no_ffi:          bool = false;
    pub var no_cxx:          bool = false;
    pub var no_unsafe:       bool = false;
    pub var no_overflow:     bool = false;
    pub var strict_const:    bool = false;
    pub var no_eval:         bool = false;
    pub var no_yield:        bool = false;
    pub var no_modules:      bool = false;
    pub var no_generics:     bool = false;
    pub var no_fp:           bool = false;
    pub var freestanding:    bool = false;

    // -- compiler test hooks (PANIC.md §7, P1) -------------------------------
    pub var test_panic_type:    bool = false;  ///< --test-panic-type: source may name Panic<...>.
    pub var test_panic_id_bits: i32  = 32;     ///< --test-panic-id-bits: type ids masked to this many bits.

    // -- sema / type system limits (from --c* config flags) ----------------
    pub var max_generic_depth:     i32 = 128;
    pub var max_generic_backtrace: i32 = 5;
    pub var max_const_eval_steps:  i32 = 1000000;
    pub var max_const_eval_depth:  i32 = 512;
    pub var max_const_backtrace:   i32 = 8;
    pub var max_struct_fields:     i32 = 0;    ///< 0 = unlimited
    pub var max_function_params:   i32 = 255;
    pub var max_enum_variants:     i32 = 0;    ///< 0 = unlimited
    pub var max_match_arms:        i32 = 0;    ///< 0 = unlimited
    pub var max_union_width:       i32 = 64;
    pub var max_type_alias_depth:  i32 = 64;
    pub var max_interface_impls:   i32 = 0;    ///< 0 = unlimited
    pub var max_extend_chain:      i32 = 64;

    /// Whether the C++ a build writes and compiles has exceptions: -fexceptions,
    /// or by default a hosted target (\p hosted: the triple names an OS, not
    /// --freestanding, not kernel mode), which has an unwinder; -fno-exceptions
    /// turns them off anywhere. The one rule: FlagTranslator passes it to
    /// clang, Sema rejects a C++ exception arm without it (PANIC.md §3.5).
    fn cxx_exceptions(self, hosted: bool) -> bool {
        return (self.exceptions == 1) || ((self.exceptions == -1) && hosted);
    }

    static fn from_args(args: ref!(ParsedArgs)) -> LangOptions {
        var o = LangOptions();
        (o.edition)         = args.get_string("edition");

        // -- build mode / AMT ----------------------------------------------
        (o.borrow_check)    = args.get_string("borrow-check");
        (o.amt_mode)        = args.get_string("amt-mode");
        (o.amt_report_file) = args.get_string("amt-report-file");
        (o.panic_handler)   = args.get_string("panic-handler");

        // -- config flags --------------------------------------------------
        for s in args.get_list("cfg") { o.cfg_flags.push_back(s); }

        // -- hard kill-switches --------------------------------------------
        (o.no_assert)       = args.get_bool("no-assert");
        (o.no_finally)      = args.get_bool("no-finally");
        (o.no_exceptions)   = args.get_bool("no-exceptions");
        (o.no_ffi)          = args.get_bool("no-ffi");
        (o.no_cxx)          = args.get_bool("no-cxx");
        (o.no_unsafe)       = args.get_bool("no-unsafe");
        (o.no_overflow)     = args.get_bool("no-overflow");
        (o.strict_const)    = args.get_bool("strict-const");
        (o.no_eval)         = args.get_bool("no-eval");
        (o.no_yield)        = args.get_bool("no-yield");
        (o.no_modules)      = args.get_bool("no-modules");
        (o.no_generics)     = args.get_bool("no-generics");
        (o.no_fp)           = args.get_bool("no-fp");

        // no-prelude / no-stdlib live in PreprocessorOptions and no-crt /
        // no-default-libs in LinkerOptions, where their consumers read them;
        // a second copy here had no reader and could only drift.
        (o.freestanding)    = args.get_bool("freestanding");
        (o.test_panic_type)    = args.get_bool("test-panic-type");
        (o.test_panic_id_bits) = args.get_i32("test-panic-id-bits");

        // -- feature toggles -----------------------------------------------
        (o.verify_interfaces)   = (args.get_feature("verify-interfaces"));
        (o.const_checks)        = (args.get_feature("const-checks"));
        (o.overflow_checks)     = (args.get_feature("overflow-checks"));
        (o.strict_null)         = (args.get_feature("strict-null"));
        (o.implicit_conv)       = (args.get_feature("implicit-conv"));
        (o.rtti)                = (args.get_feature("rtti"));
        (o.union_inference)     = (args.get_feature("union-inference"));
        (o.exceptions)          = (args.get_feature("exceptions"));
        (o.unwind)              = (args.get_feature("unwind"));
        (o.duck_generics)       = (args.get_feature("duck-generics"));
        (o.unsafe_feature)      = (args.get_feature("unsafe"));

        // -- sema / type system limits -------------------------------------
        (o.max_generic_depth)     = args.get_cfg_i32("max-generic-depth");
        (o.max_generic_backtrace) = args.get_cfg_i32("max-generic-backtrace");
        (o.max_const_eval_steps)  = args.get_cfg_i32("max-const-eval-steps");
        (o.max_const_eval_depth)  = args.get_cfg_i32("max-const-eval-depth");
        (o.max_const_backtrace)   = args.get_cfg_i32("max-const-backtrace");
        (o.max_struct_fields)     = args.get_cfg_i32("max-struct-fields");
        (o.max_function_params)   = args.get_cfg_i32("max-function-params");
        (o.max_enum_variants)     = args.get_cfg_i32("max-enum-variants");
        (o.max_match_arms)        = args.get_cfg_i32("max-match-arms");
        (o.max_union_width)       = args.get_cfg_i32("max-union-width");
        (o.max_type_alias_depth)  = args.get_cfg_i32("max-type-alias-depth");
        (o.max_interface_impls)   = args.get_cfg_i32("max-interface-impls");
        (o.max_extend_chain)      = args.get_cfg_i32("max-extend-chain");

        return o;
    }
}