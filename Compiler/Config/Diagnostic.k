/// --- The Kairo Project -------------------------- Config/Diagnostic.k --- ///
///
///   DiagnosticOptions: diagnostic formatting, severity and budget limits.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/KShims.hh"
ffi "c++" import "vector"

import Command::ParsedArgs::ParsedArgs

///
/// \class DiagnosticOptions
///
/// \brief Controls diagnostic formatting, filtering, and budget limits.
///
pub class DiagnosticOptions {
    /// # severity overrides

    pub var warn_list:   cxx::std::vector<string> ///< -W<name>
    pub var allow_list:  cxx::std::vector<string> ///< -A<name>
    pub var deny_list:   cxx::std::vector<string> ///< -E<name>
    pub var forbid_list: cxx::std::vector<string> ///< -F<name>
    /// # formatting

    pub var format: string = "pretty" ///< pretty|basic|json|msvc
    /// # budget limits (from --c* config flags)

    pub var max_errors:        i32 = 20 ///< 0 = unlimited
    pub var max_warnings:      i32 = 0  ///< 0 = unlimited
    pub var max_notes:         i32 = 0  ///< 0 = unlimited
    pub var max_context_lines: i32 = 3
    pub var max_suggestions:   i32 = 5
    pub var tab_width:         i32 = 4
    /// # formatting

    pub var no_color:       bool = false
    pub var show_ids:       bool = false ///< print DiagCode alongside every message
    pub var cascade:        bool = true  ///< cascade suppression via poisoned scopes
    pub var absolute_paths: bool = false
    pub var show_context:   bool = true  ///< print surrounding source lines
    /// # severity overrides

    pub var warnings_as_errors: bool = false ///< --Werror
    pub var suppress_warnings:  bool = false ///< -w
    pub var Wall:               bool = false
    pub var Wextra:             bool = false
    pub var Wpedantic:          bool = false
    /// -Wshift-count-unproven: a shift on ARM32 whose count mask costs an
    /// instruction (EmitIR::_warn_unproven_shift). Off by default.
    pub var Wshift_count_unproven: bool = false
    /// -Wconst-self: a method that never mutates `self` (SC273W) and an
    /// `@inout` parameter never mutated (SC274W), with fix-its
    /// (ParamPassInference). Off by default: the user turns it on for a
    /// pass over a tree, then decides whether it becomes the default.
    pub var Wconst_self: bool = false


    static fn from_args(@inout args: ParsedArgs) -> DiagnosticOptions {
        var o = DiagnosticOptions()
        o.format = args.get_string("error-format")
        var is_tty:   bool = isatty(1) != 0
        var no_color: bool = args.get_bool("no-color")
        o.no_color              = !is_tty || no_color
        o.show_ids              = args.get_bool("diag-show-ids")
        o.cascade               = args.get_bool("diag-cascade")
        o.absolute_paths        = args.get_bool("diag-absolute-paths")
        o.show_context          = args.get_bool("diag-show-context")
        o.max_errors            = args.get_cfg_i32("max-errors")
        o.max_warnings          = args.get_cfg_i32("max-warnings")
        o.max_notes             = args.get_cfg_i32("max-notes")
        o.max_context_lines     = args.get_cfg_i32("max-diag-context-lines")
        o.max_suggestions       = args.get_cfg_i32("max-suggestion-count")
        o.tab_width             = args.get_cfg_i32("tab-width")
        o.warnings_as_errors    = args.get_bool("Werror")
        o.suppress_warnings     = args.get_bool("nowarn")
        o.Wall                  = args.get_bool("Wall")
        o.Wshift_count_unproven = args.get_bool("Wshift-count-unproven")
        o.Wconst_self           = args.get_bool("Wconst-self")
        o.Wextra                = args.get_bool("Wextra")
        o.Wpedantic             = args.get_bool("Wpedantic")
        for s in *args.get_list("warn") {
            o.warn_list.push_back(s)
        }

        for s in *args.get_list("allow") {
            o.allow_list.push_back(s)
        }

        for s in *args.get_list("deny") {
            o.deny_list.push_back(s)
        }

        for s in *args.get_list("forbid") {
            o.forbid_list.push_back(s)
        }

        return o
    }
}
