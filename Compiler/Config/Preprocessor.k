/// --- The Kairo Project ------------------------ Config/Preprocessor.k --- ///
///
///   PreprocessorOptions: defines, forced includes and expansion limits.
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
    DEFAULT_MACRO_TRACE_DEPTH,
    DEFAULT_MAX_FILE_SIZE_MB,
    DEFAULT_MAX_IMPORT_DEPTH,
    DEFAULT_MAX_MACRO_BACKTRACE,
    DEFAULT_MAX_MACRO_DEPTH,
    DEFAULT_MAX_MACRO_EXPANSIONS,
    DEFAULT_MAX_TOKEN_COUNT,
}
import Command::ParsedArgs::ParsedArgs

///
/// \class PreprocessorOptions
///
/// \brief Configuration passed directly into PreProcessor and MacroExpander.
///
/// Contains all tunable limits (macro depth, expansion budget, etc.) and
/// debug flags so the preprocessor never reads raw flag keys.
///
pub class PreprocessorOptions {
    /// # CLI defines: each entry is "NAME" or "NAME=VALUE"

    pub var defines: cxx::std::vector<string> ///< -D flags
    /// # forced includes prepended before every source file

    pub var force_includes: cxx::std::vector<string> ///< --force-include
    /// Some file of the program sets the global allocator, so every Kairo
    /// file is compiled with __KAIRO_GLOBAL_ALLOCATOR_SET defined (the
    /// builtin's Global goes through the kairo_global_* symbols). From
    /// --global-allocator-set or a -D naming the macro; the driver also sets
    /// it when a file it reaches writes `@set_global_allocator`
    /// (CompilerInstance::_settle_global_allocator). EmitIR records its
    /// absence in each object's ABI note.
    pub var global_allocator_set: bool = false
    /// # import / module limits

    pub var max_import_depth: i32 = DEFAULT_MAX_IMPORT_DEPTH ///< --cmax-import-depth
    /// -fimport-cycles / -fno-import-cycles: -1 unset (= on), 0 off, 1 on.
    /// On, an import cycle compiles with a warning; off, it is an error.
    pub var import_cycles: i32 = -1
    /// # source limits

    pub var max_file_size_mb: i32 = DEFAULT_MAX_FILE_SIZE_MB ///< --cmax-file-size-mb
    pub var max_token_count:  i32 = DEFAULT_MAX_TOKEN_COUNT ///< --cmax-token-count; 0 = unlimited
    // max-string-length is a lexer concern (string literal length), not a PP one;
    // no LexerOptions plumbing exists yet, so there's no flag for it here.
    /// # macro system limits

    pub var max_depth:      i32 = DEFAULT_MAX_MACRO_DEPTH ///< --cmax-macro-depth
    pub var max_expansions: i32 = DEFAULT_MAX_MACRO_EXPANSIONS ///< --cmax-macro-expansions; 0 = unlimited
    pub var max_backtrace:  i32 = DEFAULT_MAX_MACRO_BACKTRACE ///< --cmax-macro-backtrace
    pub var trace_depth:    i32 = DEFAULT_MACRO_TRACE_DEPTH ///< --cmacro-trace-depth; 0 = unlimited
    /// # prelude

    pub var prelude_path: string = ""    ///< --prelude
    pub var no_prelude:   bool   = false ///< --no-prelude / --freestanding
    /// --builtins-dir: where the builtin module tree lives. Empty means
    /// `<resource-dir>/builtin`; with neither, there is no builtin root and the
    /// lang items stay unbound. Read by the DRIVER (it registers the search
    /// root); the PP never needs it, because the prelude resolves by module
    /// NAME through that root rather than by path.
    pub var builtins_dir: string = "" ///< --builtins-dir
    /// --no-builtins: suppress the implicit `import builtin::*` injection.
    /// Distinct from --no-prelude, which also stops the builtin root being
    /// FOLDED into the import graph: the builtin TU's own tests need the root
    /// loaded (it is what they compile) while having no prelude of their own,
    /// and a Tests/ case asserting the unbound-lang-item diagnostic needs the
    /// same shape.
    pub var no_builtins: bool = false ///< --no-builtins
    /// --std-dir: where the Kairo standard library tree lives. Empty means
    /// `<resource-dir>/std`; with neither there is no std root and
    /// `import std::...` is an ordinary unresolved import. Read by the DRIVER,
    /// which registers the root NAMED `kairo::std` (identity, namespace) and
    /// SPELLED `std` (what source imports). Nothing pulls std in implicitly.
    pub var std_dir: string = "" ///< --std-dir
    /// --no-stdlib: no std root. Distinct from --no-builtins: builtin
    /// DECLARES the lang items sema needs, std only extends them, so a
    /// freestanding TU can drop std and keep builtin.
    pub var no_stdlib: bool = false ///< --no-stdlib / --freestanding
    /// # debug / trace

    pub var macro_debug_filter: string = ""    ///< --macro-debug-filter
    pub var macro_debug:        bool   = false ///< --macro-debug
    /// # trivia

    /// Keep AtComment in the token stream (--preserve-comments). Off by
    /// default: comments reach the AST as annotations and the AST printer
    /// renders them, so a file's own comment header shows up as nodes on the
    /// next declaration. Tooling that wants the trivia asks for it.
    pub var preserve_comments: bool = false ///< --preserve-comments
    // macro origin tracking (TkMacroExpand + MacroExpansionInfo chain, so
    // diagnostics can point at the invocation site as well as the definition)
    // is unconditional, not a toggle: PPWalker::_wrap_origin always runs.

    static fn from_args(@inout args: ParsedArgs) -> PreprocessorOptions {
        var o = PreprocessorOptions()
        o.max_depth          = args.get_cfg_i32("max-macro-depth")
        o.max_expansions     = args.get_cfg_i32("max-macro-expansions")
        o.max_backtrace      = args.get_cfg_i32("max-macro-backtrace")
        o.trace_depth        = args.get_cfg_i32("macro-trace-depth")
        o.max_import_depth   = args.get_cfg_i32("max-import-depth")
        o.import_cycles      = args.get_feature("import-cycles")
        o.max_file_size_mb   = args.get_cfg_i32("max-file-size-mb")
        o.max_token_count    = args.get_cfg_i32("max-token-count")
        o.macro_debug        = args.get_bool("macro-debug")
        o.preserve_comments  = args.get_bool("preserve-comments")
        o.macro_debug_filter = args.get_string("macro-debug-filter")
        o.prelude_path       = args.get_string("prelude")
        o.no_prelude         = args.get_bool("no-prelude") || args.get_bool("freestanding")
        o.builtins_dir       = args.get_string("builtins-dir")
        o.no_builtins        = args.get_bool("no-builtins")
        o.std_dir            = args.get_string("std-dir")
        o.no_stdlib          = args.get_bool("no-stdlib") || args.get_bool("freestanding")

        for *s in *args.get_list("define") {
            o.defines.push_back(*s)
        }

        for *s in *args.get_list("force-include") {
            o.force_includes.push_back(*s)
        }

        o.global_allocator_set = args.get_bool("global-allocator-set")
        return o
    }
}
