/// --- The Kairo Project -------------------------------------------------- ///
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

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
    error::Panic(error::CodeError{ \
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
inline std::unordered_map<std::filesystem::path, std::shared_ptr<generator::CXIR::CXIR>> IMPORT_CACHE_MODULE;
inline std::unordered_set<std::filesystem::path> IMPORT_CACHE_HEADER;

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

        std::vector<std::shared_ptr<generator::CXIR::CXIR>> imports;
        std::unordered_set<std::filesystem::path>           emitted_imports;

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

        /// Permanently stop this processor from expanding imports.  Used by
        /// --index-file, which wants one file's own declarations and nothing
        /// from its closure.  Same mechanism the internal bail-out paths use.
        void disable_import_processing() {
            override_processable_imports = reinterpret_cast<void *>(0xFFF);
        }

        /// Delete every import statement from the token stream without resolving
        /// any of them.
        ///
        /// Declining to *follow* imports is not enough on its own: the parser
        /// never sees an `import` statement under normal compilation because
        /// process() always deletes the tokens after expanding them.  Leaving
        /// them in place makes Program::parse abort, so --index-file has to
        /// remove the syntax even though it wants nothing from the target.
        void strip_imports();

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