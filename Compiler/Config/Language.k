/// --- The Kairo Project ---------------------------- Config/Language.k --- ///
///
///   LangOptions: language semantics and standard selection.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "vector"

import Command::FlagRegistry::{
    DEFAULT_MAX_CONST_BACKTRACE,
    DEFAULT_MAX_CONST_EVAL_DEPTH,
    DEFAULT_MAX_CONST_EVAL_STEPS,
    DEFAULT_MAX_ENUM_VARIANTS,
    DEFAULT_MAX_EXTEND_CHAIN,
    DEFAULT_MAX_FUNCTION_PARAMS,
    DEFAULT_MAX_GENERIC_BACKTRACE,
    DEFAULT_MAX_GENERIC_DEPTH,
    DEFAULT_MAX_INTERFACE_IMPLS,
    DEFAULT_MAX_MATCH_ARMS,
    DEFAULT_MAX_STRUCT_FIELDS,
    DEFAULT_MAX_TYPE_ALIAS_DEPTH,
    DEFAULT_MAX_UNION_WIDTH,
}
import Command::ParsedArgs::ParsedArgs

///
/// \class LangOptions
///
/// \brief Language semantics and standard configuration.
///
/// Deserialised from ParsedArgs once by CompilerInvocation::from_args().
/// Nothing downstream reads raw flag keys after this point.
///
pub class LangOptions {
    pub var edition: string = "2026"

    /// # build mode / AMT

    pub var borrow_check:    string = "" ///< warn|error|off
    pub var amt_mode:        string = "" ///< warn|error|silent
    pub var amt_report_file: string = "" ///< path for AMT audit log
    pub var panic_handler:   string = "" ///< custom panic handler symbol

    /// # config flags (--cfg)

    pub var cfg_flags: cxx::std::vector<string> ///< --cfg name or --cfg name=value

    /// # -f / -fno- feature toggles
    /// -1 = unset (profile default applies), 0 = disabled, 1 = enabled

    /// -fverify-interfaces, -fconst-checks, -foverflow-checks and
    /// -fstrict-null parse but have no consumer (FlagRegistry's
    /// mark_unimplemented: U005W), so nothing stores them.
    pub var implicit_conv: i32 = -1
    /// -fcxx-implicit-conv: at a call (or initialisation) that crosses into
    /// C++, C++'s own implicit conversions apply (one user-defined
    /// conversion, a literal crossing as `const char[N]`). Off unless 1;
    /// -fimplicit-conv is the Kairo-side rules only and never turns it on.
    pub var cxx_implicit_conv: i32 = -1
    pub var rtti:              i32 = -1
    pub var union_inference:   i32 = -1
    pub var exceptions:        i32 = -1
    pub var unsafe_feature:    i32 = -1
    /// -funwind: Kairo functions are not `noexcept`, so a C++ exception may
    /// pass through every Kairo frame. Unset or -fno-unwind: each is
    /// `noexcept` unless marked `@unwind`.
    pub var unwind: i32 = -1
    /// -finfer-purity: FnPurityCheck::infer stamps const / pure on the
    /// functions that keep the promise unwritten (Compiler/Spec/
    /// SemanticChecks.md, FnPurityCheck). On unless 0 (-fno-infer-purity),
    /// as `const` parameters are inferred unasked: the
    /// rules are the written promise's, so what they admit is sound.
    pub var infer_purity: i32 = -1
    /// -fduck-generics: `<T: type>` is accepted, its body typed as written
    /// and emitted as an unconstrained template that clang checks per
    /// instance (Compiler/Spec/Generics.md#duck-regime). OFF unless 1: an internal flag that build.py passes for the compiler's
    /// own targets only; everyone else gets real bounds. Transitional: removal
    /// is Compiler/Spec/Generics.md#duck-regime (delete the regime and the flag).
    pub var duck_generics: i32 = -1
    /// -fdefault-visibility=spec|pub (hidden): `pub` keeps the older rule
    /// for unmarked declarations (public, a class's variables private); `spec`, the default, makes them `priv`, or `prot`
    /// under a module.k (AST/VisibilityFacts.k). build.py passes `spec` for
    /// the compiler's own targets (tree_visibility_args); `pub` stays for
    /// users and tests.
    pub var default_vis_pub: bool = false

    /// # hard kill-switches

    pub var no_assert:     bool = false
    pub var no_finally:    bool = false
    pub var no_exceptions: bool = false
    pub var no_ffi:        bool = false
    pub var no_cxx:        bool = false
    pub var no_unsafe:     bool = false
    pub var no_overflow:   bool = false
    pub var strict_const:  bool = false
    pub var no_eval:       bool = false
    pub var no_yield:      bool = false
    pub var no_modules:    bool = false
    pub var no_generics:   bool = false
    pub var no_fp:         bool = false
    pub var freestanding:  bool = false

    /// # compiler test hooks (Compiler/Spec/Panic.md#type-ids)

    pub var test_panic_type:    bool = false ///< --test-panic-type: source may name Panic<...>.
    pub var test_panic_id_bits: i32  = 32 ///< --test-panic-id-bits: type ids masked to this many bits.
    pub var test_fold_lie:      bool = false ///< --test-fold-lie: the late eval-if fold reads every triviality fact inverted (Compiler/Spec/Eval.md#deferred-conditions).

    /// # sema / type system limits (from --c* config flags)

    pub var max_generic_depth:     i32 = DEFAULT_MAX_GENERIC_DEPTH
    pub var max_generic_backtrace: i32 = DEFAULT_MAX_GENERIC_BACKTRACE
    pub var max_const_eval_steps:  i32 = DEFAULT_MAX_CONST_EVAL_STEPS
    pub var max_const_eval_depth:  i32 = DEFAULT_MAX_CONST_EVAL_DEPTH
    pub var max_const_backtrace:   i32 = DEFAULT_MAX_CONST_BACKTRACE
    pub var max_struct_fields:     i32 = DEFAULT_MAX_STRUCT_FIELDS     ///< 0 = unlimited
    pub var max_function_params:   i32 = DEFAULT_MAX_FUNCTION_PARAMS
    pub var max_enum_variants:     i32 = DEFAULT_MAX_ENUM_VARIANTS     ///< 0 = unlimited
    pub var max_match_arms:        i32 = DEFAULT_MAX_MATCH_ARMS        ///< 0 = unlimited
    pub var max_union_width:       i32 = DEFAULT_MAX_UNION_WIDTH
    pub var max_type_alias_depth:  i32 = DEFAULT_MAX_TYPE_ALIAS_DEPTH
    pub var max_interface_impls:   i32 = DEFAULT_MAX_INTERFACE_IMPLS   ///< 0 = unlimited
    pub var max_extend_chain:      i32 = DEFAULT_MAX_EXTEND_CHAIN

    /// Whether the C++ a build writes and compiles has exceptions: -fexceptions,
    /// or by default a hosted target (\p hosted: the triple names an OS, not
    /// --freestanding, not kernel mode), which has an unwinder; -fno-exceptions
    /// turns them off anywhere. The one rule: FlagTranslator passes it to
    /// clang, Sema rejects a C++ exception arm without it (Compiler/Spec/Panic.md#c-exception-arms).
    pub fn cxx_exceptions(self, hosted: bool) -> bool {
        return self.exceptions == 1 || self.exceptions == -1 && hosted
    }

    static fn from_args(@inout args: ParsedArgs) -> LangOptions {
        var o = LangOptions()
        o.edition = args.get_string("edition")

        /// ## build mode / AMT
        o.borrow_check    = args.get_string("borrow-check")
        o.amt_mode        = args.get_string("amt-mode")
        o.amt_report_file = args.get_string("amt-report-file")
        o.panic_handler   = args.get_string("panic-handler")

        /// ## config flags
        for s in *args.get_list("cfg") {
            o.cfg_flags.push_back(s)
        }

        /// ## hard kill-switches
        o.no_assert     = args.get_bool("no-assert")
        o.no_finally    = args.get_bool("no-finally")
        o.no_exceptions = args.get_bool("no-exceptions")
        o.no_ffi        = args.get_bool("no-ffi")
        o.no_cxx        = args.get_bool("no-cxx")
        o.no_unsafe     = args.get_bool("no-unsafe")
        o.no_overflow   = args.get_bool("no-overflow")
        o.strict_const  = args.get_bool("strict-const")
        o.no_eval       = args.get_bool("no-eval")
        o.no_yield      = args.get_bool("no-yield")
        o.no_modules    = args.get_bool("no-modules")
        o.no_generics   = args.get_bool("no-generics")
        o.no_fp         = args.get_bool("no-fp")

        // no-prelude / no-stdlib live in PreprocessorOptions and no-crt /
        // no-default-libs in LinkerOptions, where their consumers read them;
        // a second copy here had no reader and could only drift.
        o.freestanding       = args.get_bool("freestanding")
        o.test_panic_type    = args.get_bool("test-panic-type")
        o.test_panic_id_bits = args.get_i32("test-panic-id-bits")
        o.test_fold_lie      = args.get_bool("test-fold-lie")

        /// ## feature toggles
        o.implicit_conv     = args.get_feature("implicit-conv")
        o.cxx_implicit_conv = args.get_feature("cxx-implicit-conv")
        o.rtti              = args.get_feature("rtti")
        o.union_inference   = args.get_feature("union-inference")
        o.exceptions        = args.get_feature("exceptions")
        o.unwind            = args.get_feature("unwind")
        o.infer_purity      = args.get_feature("infer-purity")
        o.duck_generics     = args.get_feature("duck-generics")
        o.default_vis_pub   = args.get_string("default-visibility") == "pub"
        o.unsafe_feature    = args.get_feature("unsafe")

        /// ## sema / type system limits
        o.max_generic_depth     = args.get_cfg_i32("max-generic-depth")
        o.max_generic_backtrace = args.get_cfg_i32("max-generic-backtrace")
        o.max_const_eval_steps  = args.get_cfg_i32("max-const-eval-steps")
        o.max_const_eval_depth  = args.get_cfg_i32("max-const-eval-depth")
        o.max_const_backtrace   = args.get_cfg_i32("max-const-backtrace")
        o.max_struct_fields     = args.get_cfg_i32("max-struct-fields")
        o.max_function_params   = args.get_cfg_i32("max-function-params")
        o.max_enum_variants     = args.get_cfg_i32("max-enum-variants")
        o.max_match_arms        = args.get_cfg_i32("max-match-arms")
        o.max_union_width       = args.get_cfg_i32("max-union-width")
        o.max_type_alias_depth  = args.get_cfg_i32("max-type-alias-depth")
        o.max_interface_impls   = args.get_cfg_i32("max-interface-impls")
        o.max_extend_chain      = args.get_cfg_i32("max-extend-chain")

        return o
    }
}
