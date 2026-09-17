/// --- The Kairo Project ------------------------ Config/Preprocessor.k --- ///
///
///   <short description>
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
/// \class PreprocessorOptions
///
/// \brief Configuration passed directly into PreProcessor and MacroExpander.
///
/// Contains all tunable limits (macro depth, expansion budget, etc.) and
/// debug flags so the preprocessor never reads raw flag keys.
///
class PreprocessorOptions {
    // -- CLI defines: each entry is "NAME" or "NAME=VALUE" -----------------
    pub var defines:            vec::<string>;      ///< -D flags
    // -- forced includes prepended before every source file ----------------
    pub var force_includes:     vec::<string>;      ///< --force-include
    // -- import / module limits --------------------------------------------
    pub var max_import_depth:   i32    = 512;       ///< --cmax-import-depth
    // -- source limits -----------------------------------------------------
    pub var max_file_size_mb:   i32    = 256;       ///< --cmax-file-size-mb
    pub var max_token_count:    i32    = 0;         ///< --cmax-token-count; 0 = unlimited
    // max-string-length is a lexer concern (string literal length), not a PP one;
    // no LexerOptions plumbing exists yet, so there's no flag for it here.
    // -- macro system limits -----------------------------------------------
    pub var max_depth:          i32    = 128;       ///< --cmax-macro-depth
    pub var max_expansions:     i32    = 65536;     ///< --cmax-macro-expansions; 0 = unlimited
    pub var max_backtrace:      i32    = 8;         ///< --cmax-macro-backtrace
    pub var trace_depth:        i32    = 0;         ///< --cmacro-trace-depth; 0 = unlimited
    // -- prelude -----------------------------------------------------------
    pub var prelude_path:       string = "";        ///< --prelude
    pub var no_prelude:         bool   = false;     ///< --no-prelude / --freestanding
    /// --builtins-dir: where the builtin module tree lives. Empty means
    /// `<resource-dir>/builtin`; with neither, there is no builtin root and the
    /// lang items stay unbound. Read by the DRIVER (it registers the search
    /// root); the PP never needs it, because the prelude resolves by module
    /// NAME through that root rather than by path.
    pub var builtins_dir:       string = "";        ///< --builtins-dir
    /// --no-builtins: suppress the implicit `import builtin::*` injection.
    /// Distinct from --no-prelude, which also stops the builtin root being
    /// FOLDED into the import graph: the builtin TU's own tests need the root
    /// loaded (it is what they compile) while having no prelude of their own,
    /// and a Tests/ case asserting the unbound-lang-item diagnostic needs the
    /// same shape.
    pub var no_builtins:        bool   = false;     ///< --no-builtins
    /// --std-dir: where the Kairo standard library tree lives. Empty means
    /// `<resource-dir>/std`; with neither there is no std root, bare `std`
    /// binds nothing, and every use of it is an ordinary unresolved-name
    /// error. Read by the DRIVER (it registers the search root under the name
    /// `kairo::std`) and by the PP, which folds `kairo::std` into the import
    /// GRAPH the same way it folds `builtin`.
    pub var std_dir:            string = "";        ///< --std-dir
    /// --no-stdlib: no std root, no `import kairo::std as std` alias. Distinct
    /// from --no-builtins: builtin DECLARES the lang items sema needs, std
    /// only extends them, so a freestanding TU can drop std and keep builtin.
    pub var no_stdlib:          bool   = false;     ///< --no-stdlib / --freestanding
    // -- debug / trace -----------------------------------------------------
    pub var macro_debug_filter: string = "";     ///< --macro-debug-filter
    pub var macro_debug:        bool   = false;  ///< --macro-debug
    // -- trivia ------------------------------------------------------------
    /// Keep AtComment in the token stream (--preserve-comments). Off by
    /// default: comments reach the AST as annotations and the AST printer
    /// renders them, so a file's own comment header shows up as nodes on the
    /// next declaration. Tooling that wants the trivia asks for it.
    pub var preserve_comments:  bool   = false;  ///< --preserve-comments
    // macro origin tracking (TkMacroExpand + MacroExpansionInfo chain, so
    // diagnostics can point at the invocation site as well as the definition)
    // is unconditional now, not a toggle: PPWalker::_wrap_origin always runs.

    static fn from_args(args: ref!(ParsedArgs)) -> PreprocessorOptions {
        var o = PreprocessorOptions();
        (o.max_depth)          = args.get_cfg_i32("max-macro-depth");
        (o.max_expansions)     = args.get_cfg_i32("max-macro-expansions");
        (o.max_backtrace)      = args.get_cfg_i32("max-macro-backtrace");
        (o.trace_depth)        = args.get_cfg_i32("macro-trace-depth");
        (o.max_import_depth)   = args.get_cfg_i32("max-import-depth");
        (o.max_file_size_mb)   = args.get_cfg_i32("max-file-size-mb");
        (o.max_token_count)    = args.get_cfg_i32("max-token-count");
        (o.macro_debug)        = args.get_bool("macro-debug");
        (o.preserve_comments)  = args.get_bool("preserve-comments");
        (o.macro_debug_filter) = args.get_string("macro-debug-filter");
        (o.prelude_path)       = args.get_string("prelude");
        (o.no_prelude)         = args.get_bool("no-prelude") || args.get_bool("freestanding");
        (o.builtins_dir)       = args.get_string("builtins-dir");
        (o.no_builtins)        = args.get_bool("no-builtins");
        (o.std_dir)            = args.get_string("std-dir");
        (o.no_stdlib)          = args.get_bool("no-stdlib") || args.get_bool("freestanding");

        for s: string in args.get_list("define")        { o.defines.push_back(s); }
        for s: string in args.get_list("force-include") { o.force_includes.push_back(s); }
        return o;
    }
}
