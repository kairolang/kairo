///--- The Helix Project ------------------------------------------------------------------------///
///                                                                                              ///
///   Part of the Helix Project, under the Attribution 4.0 International license (CC BY 4.0).    ///
///   You are allowed to use, modify, redistribute, and create derivative works, even for        ///
///   commercial purposes, provided that you give appropriate credit, and indicate if changes    ///
///   were made.                                                                                 ///
///                                                                                              ///
///   For more information on the license terms and requirements, please visit:                  ///
///     https://creativecommons.org/licenses/by/4.0/                                             ///
///                                                                                              ///
///   SPDX-License-Identifier: CC-BY-4.0                                                         ///
///   Copyright (c) 2024 The Helix Project (CC BY 4.0)                                           ///
///                                                                                              ///
///-------------------------------------------------------------------------------------- C++ ---///

#ifndef __PRE_PROCESSOR_H__
#define __PRE_PROCESSOR_H__

#include "controller/include/Controller.hh"
#include "controller/include/tooling/tooling.hh"
#include "generator/include/CX-IR/CXIR.hh"
#include "parser/preprocessor/include/config/Preprocessor_config.def"
#include "parser/preprocessor/include/private/dependency_tree.hh"
#include "parser/preprocessor/include/private/processor.hh"

#include <filesystem>
#include <string>
#include <thread>
#include <utility>
#include <variant>
#include <vector>

#include "parser/ast/include/nodes/AST_expressions.hh"
#include "parser/ast/include/nodes/AST_statements.hh"
#include "token/include/private/Token_base.hh"

// parser::preprocessor::import_tree

#define ADVANCE_AND_CHECK          \
    iter.advance();                \
    if (iter.remaining_n() == 0) { \
        continue;                  \
    }

#ifndef THROW_PANIC
#define THROW_PANIC(msg, marker)         \
    throw error::Panic(error::CodeError{ \
        .pof      = marker,              \
        .err_code = 0.0123,              \
        .mark_pof = true,                \
        .fix_fmt_args{},                 \
        .err_fmt_args{msg},              \
        .opt_fixes{},                    \
        .level = error::ERR,             \
    })
#ifndef WARN_PANIC_FIX
#define WARN_PANIC_FIX(msg, fix, marker) \
    error::Panic(error::CodeError{       \
        .pof      = marker,              \
        .err_code = 0.0126,              \
        .mark_pof = true,                \
        .fix_fmt_args{fix},              \
        .err_fmt_args{msg},              \
        .opt_fixes{},                    \
        .level = error::WARN,            \
    })
#endif
#endif

inline std::vector<CXXCompileAction> COMPILE_ACTIONS;
inline std::unordered_set<std::filesystem::path>  DEPENDENCIES;     // all imported files

__PREPROCESSOR_BEGIN {
    class ImportProcessor {
      private:
        __TOKEN_N::TokenList &tokens;  // NOLINT - this is a reference intentionally
                                       // (i cba to make it a pointer lol)
        std::vector<std::filesystem::path> import_dirs;
        __CONTROLLER_CLI_N::CLIArgs        parsed_args;
        void* override_processable_imports = nullptr; // NOLINT - if 0xFFF is present then we stop processing imports

      public:
        enum class Type {
            Module,
            Header,
        };

        using NormalizedImport =
        std::tuple<std::filesystem::path, size_t, parser::preprocessor::ImportProcessor::Type>;

        using ImportType                = std::variant<std::filesystem::path, __TOKEN_N::TokenList>;
        using ImportAlias               = __TOKEN_N::TokenList;
        using SingleImportNormalized    = std::tuple<ImportType, ImportAlias, bool>;
        using MultipleImportsNormalized = std::vector<SingleImportNormalized>;
        using ASTScopePath              = __AST_N::NodeT<__AST_NODE::ScopePathExpr>;
        using ASTSpecImport             = __AST_N::NodeT<__AST_NODE::SpecImport>;
        using Token                     = __TOKEN_N::Token;
        using InstLoc                   = std::pair<u64, Token>;

        using InstCXX      = std::variant<std::pair<std::string, std::string>, std::string>;
        using ResolvedPath = std::tuple<std::filesystem::path, size_t, Type>;

        std::vector<generator::CXIR::CXIR> imports;

        ImportProcessor(__TOKEN_N::TokenList               &tokens,
                        std::vector<std::filesystem::path> &import_dirs,
                        __CONTROLLER_CLI_N::CLIArgs         parsed_args)
            : tokens(tokens)
            , import_dirs(import_dirs)
            , parsed_args(std::move(parsed_args)) {}

        ImportProcessor(const ImportProcessor &)            = default;
        ImportProcessor(ImportProcessor &&)                 = default;
        ImportProcessor &operator=(const ImportProcessor &) = delete;
        ImportProcessor &operator=(ImportProcessor &&)      = delete;
        ~ImportProcessor()                                  = default;

        static __TOKEN_N::TokenList normalize_scope_path(const ASTScopePath &scope,
                                                         Token               start_tok);

        /// \return a tuple containing the resolved path, the alias, and a bool indicating if the
        /// import is a wildcard
        static SingleImportNormalized
        resolve_single_import(const __AST_N::NodeT<__AST_NODE::SingleImport> &single_import,
                              Token                                           start_tok);

        static MultipleImportsNormalized resolve_spec_import(const ASTSpecImport &spec_import,
                                                             Token                start_tok);

        static void
        insert_inline_cpp(__TOKEN_N::TokenList &tokens, const InstLoc &loc, const InstCXX &cxx);

        void process();
        bool has_processable_import();
        void force_import(const std::filesystem::path &path, __CONTROLLER_CLI_N::CLIArgs args);

        void append(const std::filesystem::path                        &path,
                    size_t                                    rel_to_index,
                    Type                                      type,
                    size_t                                    start_pos,
                    const std::vector<std::filesystem::path> &import_dirs,
                    __CONTROLLER_CLI_N::CLIArgs              &parsed_args,
                    __TOKEN_N::Token                         &start);

        void extend(const std::vector<NormalizedImport> &normalized,
                    const std::vector<std::filesystem::path>                 &import_dirs,
                    __CONTROLLER_CLI_N::CLIArgs                              &parsed_args,
                    size_t                                                    start_pos,
                    __TOKEN_N::Token                                         &start);

        std::vector<std::filesystem::path> get_dirs() const { return import_dirs; }

        /// \returns a resolved path (maybe), which index it was found at, and
        ///          the type of the path that was found, and a vec of also matched paths
        std::vector<ResolvedPath> final_import_normalizer(std::filesystem::path &path,
                                                          Token                  marker,
                                                          bool                   keep_ext  = false,
                                                          bool                   is_module = false);
    };
}

#endif  // __PRE_PROCESSOR_H__