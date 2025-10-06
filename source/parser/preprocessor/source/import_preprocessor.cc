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
///                                                                                              ///
/// this file is a fucking mess, but it works, i will clean it up in the self-hosted version     ///
/// i cba to do it now, i have other things to get done...                                       ///
///                                                                                              ///
///----------------------------------------------------------------------------------------------///

#include <filesystem>
#include <functional>
#include <limits>
#include <memory>
#include <optional>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "controller/include/Controller.hh"
#include "controller/include/config/Controller_config.def"
#include "controller/include/shared/file_system.hh"
#include "controller/include/tooling/tooling.hh"
#include "generator/include/CX-IR/CXIR.hh"
#include "lexer/include/lexer.hh"
#include "neo-panic/include/error.hh"
#include "parser/ast/include/config/AST_config.def"
#include "parser/ast/include/nodes/AST_expressions.hh"
#include "parser/ast/include/nodes/AST_statements.hh"
#include "parser/preprocessor/include/preprocessor.hh"
#include "parser/preprocessor/include/private/utils.hh"
#include "token/include/config/Token_config.def"
#include "token/include/private/Token_base.hh"
#include "token/include/private/Token_generate.hh"
#include "token/include/private/Token_list.hh"

// parser::preprocessor::import_tree

__PREPROCESSOR_BEGIN {
    struct NormalizedImportHasher {
        std::size_t
        operator()(const parser::preprocessor::ImportProcessor::NormalizedImport &key) const {
            return std::hash<std::filesystem::path>{}(std::get<0>(key)) ^
                   (std::hash<unsigned long>{}(std::get<1>(key)) << 1) ^
                   (std::hash<parser::preprocessor::ImportProcessor::Type>{}(std::get<2>(key))
                    << 2);
        }
    };

    __TOKEN_N::TokenList ImportProcessor::normalize_scope_path(const ASTScopePath &scope,
                                                               Token               start_tok) {
        __TOKEN_N::TokenList final_path;

        if (scope->global_scope) {
            // handle special import cases
            // TODO

            error::Panic(error::CodeError{
                .pof      = &start_tok,
                .err_code = 0.0001,
                .mark_pof = true,
                .fix_fmt_args{},
                .err_fmt_args{GET_DEBUG_INFO + "global import not yet supported'"},
                .opt_fixes{},
            });

            return {};
        }

        if (!scope->path.empty()) {
            for (auto &ident : scope->path) {
                final_path.emplace_back(ident->name);
            }
        }

        if (scope->access != nullptr &&
            scope->access->getNodeType() != __AST_NODE::nodes::IdentExpr) {
            if (!final_path.empty()) {
                error::Panic(error::CodeError{
                    .pof      = &final_path.back(),
                    .err_code = 0.0001,
                    .mark_pof = true,
                    .fix_fmt_args{},
                    .err_fmt_args{"expected an identifier after '::', but found something else"},
                    .opt_fixes{},
                });

                return {};
            }

            return {};
        }

        if (scope->access != nullptr) {
            final_path.emplace_back(__AST_N::as<__AST_NODE::IdentExpr>(scope->access)->name);
        }

        return final_path;
    }

    /// \return a tuple containing the resolved path, the alias, and a bool indicating if the import
    /// is a wildcard
    ImportProcessor::SingleImportNormalized ImportProcessor::resolve_single_import(
        const __AST_N::NodeT<__AST_NODE::SingleImport> &single_import, Token start_tok) {

        __TOKEN_N::TokenList final_path;

        __TOKEN_N::TokenList alias;

        // handle the alias
        if (single_import->alias != nullptr) {
            if (single_import->is_wildcard) {
                error::Panic(error::CodeError{
                    .pof      = &start_tok,
                    .err_code = 0.0001,
                    .mark_pof = true,
                    .fix_fmt_args{},
                    .err_fmt_args{"wildcard imports cannot have an alias"},
                    .opt_fixes{},
                });

                return {};
            }

            if (single_import->alias->getNodeType() == __AST_NODE::nodes::IdentExpr) {
                alias.emplace_back(__AST_N::as<__AST_NODE::IdentExpr>(single_import->alias)->name);
            } else if (single_import->alias->getNodeType() == __AST_NODE::nodes::ScopePathExpr) {
                /// TODO
                // ASTScopePath path =
                //     __AST_N::as<__AST_NODE::ScopePathExpr>(
                //         single_import->alias);
                //
                // alias = normalize_scope_path(path, start_tok);
            } else {
                error::Panic(error::CodeError{
                    .pof      = &start_tok,
                    .err_code = 0.0001,
                    .mark_pof = true,
                    .fix_fmt_args{},
                    .err_fmt_args{"expected an identifier or a scope path for the alias, but found "
                                  "something else"},
                    .opt_fixes{},
                });

                return {};
            }
        }

        // handle the path
        if (single_import->type == __AST_NODE::SingleImport::Type::Module) {
            if (single_import->path->getNodeType() != __AST_NODE::nodes::ScopePathExpr) {
                error::Panic(error::CodeError{
                    .pof      = &start_tok,
                    .err_code = 0.0001,
                    .mark_pof = true,
                    .fix_fmt_args{},
                    .err_fmt_args{"expected a scope path for the import, but found something else"},
                    .opt_fixes{},
                });

                return {};
            }

            ASTScopePath path = __AST_N::as<__AST_NODE::ScopePathExpr>(single_import->path);

            final_path = normalize_scope_path(path, start_tok);
            return {final_path, alias, single_import->is_wildcard};
        }

        if (single_import->type == __AST_NODE::SingleImport::Type::File) {
            if (single_import->path->getNodeType() != __AST_NODE::nodes::LiteralExpr) {
                error::Panic(error::CodeError{
                    .pof      = &start_tok,
                    .err_code = 0.0001,
                    .mark_pof = true,
                    .fix_fmt_args{},
                    .err_fmt_args{
                        "expected a string literal for the import, but found something else"},
                    .opt_fixes{},
                });

                return {};
            }

            std::filesystem::path f_path =
                __AST_N::as<__AST_NODE::LiteralExpr>(single_import->path)->value.value();
            return {f_path, alias, single_import->is_wildcard};
        }

        return {};
    }

    ImportProcessor::MultipleImportsNormalized ImportProcessor::resolve_spec_import(
        const ASTSpecImport &spec_import, Token start_tok) {
        __TOKEN_N::TokenList base_path =
            normalize_scope_path(spec_import->path, std::move(start_tok));
        MultipleImportsNormalized imports;

        if (spec_import == nullptr) {
            error::Panic(error::CodeError{
                .pof      = &start_tok,
                .err_code = 0.0001,
                .mark_pof = true,
                .fix_fmt_args{},
                .err_fmt_args{"expected a spec import, but found none"},
                .opt_fixes{},
            });

            return {};
        }

        if (spec_import->type == __AST_NODE::SpecImport::Type::Wildcard) {
            if (spec_import->imports != nullptr) {
                error::Panic(error::CodeError{
                    .pof      = &start_tok,
                    .err_code = 0.0001,
                    .mark_pof = true,
                    .fix_fmt_args{},
                    .err_fmt_args{"expected a wildcard import, but found a symbol import"},
                    .opt_fixes{},
                });

                return {};
            }

            imports.emplace_back(base_path, __TOKEN_N::TokenList{}, true);
        } else if (spec_import->type == __AST_NODE::SpecImport::Type::Symbol) {
            if (spec_import->imports == nullptr || spec_import->imports->imports.empty()) {
                error::Panic(error::CodeError{
                    .pof      = &start_tok,
                    .err_code = 0.0001,
                    .mark_pof = true,
                    .fix_fmt_args{},
                    .err_fmt_args{"expected at least one import item, but found none"},
                    .opt_fixes{},
                });

                return {};
            }

            if (!spec_import->imports->imports.empty()) {
                for (auto &import : spec_import->imports->imports) {
                    auto [path, alias, is_wildcard] = resolve_single_import(import, start_tok);

                    /// append the base path to the start of the single import path
                    std::get<__TOKEN_N::TokenList>(path).insert(
                        std::get<__TOKEN_N::TokenList>(path).cbegin(),
                        base_path.cbegin(),
                        base_path.cend());

                    imports.emplace_back(path, alias, is_wildcard);
                }
            } else {
                error::Panic(error::CodeError{
                    .pof      = &start_tok,
                    .err_code = 0.0001,
                    .mark_pof = true,
                    .fix_fmt_args{},
                    .err_fmt_args{"expected at least one import item, but found none"},
                    .opt_fixes{},
                });

                return {};
            }
        }

        return imports;
    }

    // path       , alias       | namespace
    void ImportProcessor::insert_inline_cpp(
        __TOKEN_N::TokenList & tokens, const InstLoc &loc, const InstCXX &cxx) {

        __TOKEN_N::TokenList inline_cpp;

        auto make_token = [&loc](const std::string &str, __TOKEN_N::tokens kind) -> Token {
            return {loc.second.line_number(),
                    loc.second.column_number(),
                    str.length(),
                    loc.second.offset() + str.length(),
                    str,
                    loc.second.file_name(),
                    __TOKEN_N::tokens_map.at(kind).value()};
        };

        inline_cpp.push_back(make_token("__inline_cpp", __TOKEN_N::tokens::IDENTIFIER));
        inline_cpp.push_back(make_token("(", __TOKEN_N::tokens::PUNCTUATION_OPEN_PAREN));

        if (cxx.index() == 0) {
            auto [path, alias] = std::get<std::pair<std::string, std::string>>(cxx);
            inline_cpp.push_back(make_token("\"namespace " + path + " = " + alias + ";\"",
                                            __TOKEN_N::tokens::LITERAL_STRING));
        } else {
            inline_cpp.push_back(
                make_token("\"using namespace " + std::get<std::string>(cxx) + ";\"",
                           __TOKEN_N::tokens::LITERAL_STRING));
        }

        inline_cpp.push_back(make_token(")", __TOKEN_N::tokens::PUNCTUATION_CLOSE_PAREN));
        inline_cpp.push_back(make_token(";", __TOKEN_N::tokens::PUNCTUATION_SEMICOLON));

        tokens.insert(tokens.cbegin() +
                          static_cast<std::ptrdiff_t>(
                              loc.first == std::numeric_limits<size_t>::max() ? 0 : loc.first),
                      inline_cpp.cbegin(),
                      inline_cpp.cend());
    }

    bool ImportProcessor::has_processable_import() {
        bool found_import = false;
        __TOKEN_N::TokenList::TokenListIter iter = tokens.begin();

        if (override_processable_imports == reinterpret_cast<void*>(0xFFF)) {
            return false;
        }

        while (iter.remaining_n() > 0) {
            if (iter->token_kind() == __TOKEN_N::tokens::KEYWORD_FFI) {
                /// TODO: add checks to see if tokens are empty after advancing
                bool  has_brace = false;
                Token ffi_tok   = iter.current();

                ADVANCE_AND_CHECK;  // skip 'ffi'

                if (iter->token_kind() != __TOKEN_N::tokens::LITERAL_STRING) {
                    Token bad_tok = iter.current();

                    error::Panic(error::CodeError{
                        .pof      = &bad_tok,
                        .err_code = 0.0001,
                        .mark_pof = true,
                        .fix_fmt_args{},
                        .err_fmt_args{"expected a string literal after 'ffi'"},
                        .opt_fixes{},
                    });

                    goto leave_loop_has_processable_import;
                }

                ADVANCE_AND_CHECK;  // skip the language

                if (iter->token_kind() == __TOKEN_N::tokens::PUNCTUATION_OPEN_BRACE) {
                    has_brace = true;
                    ADVANCE_AND_CHECK;  // skip the opening brace
                }

                if (iter->token_kind() != __TOKEN_N::tokens::KEYWORD_IMPORT) {
                    continue;  // skip parsing the ffi block if it's not an import
                }

                while (iter->token_kind() != (has_brace
                                                  ? __TOKEN_N::tokens::PUNCTUATION_CLOSE_BRACE
                                                  : __TOKEN_N::tokens::PUNCTUATION_SEMICOLON)) {
                    if (iter.remaining_n() == 0) {
                        error::Panic(error::CodeError{
                            .pof      = &ffi_tok,
                            .err_code = 0.0001,
                            .mark_pof = true,
                            .fix_fmt_args{},
                            .err_fmt_args{std::string("expected a") +
                                          (has_brace ? " '}'" : " ';'") +
                                          " to close the 'ffi' block"},
                            .opt_fixes{},
                        });

                        goto leave_loop_has_processable_import;
                    }

                    ADVANCE_AND_CHECK;  // WARNING: this may fail since we break and dont break
                                        // again.
                }
            }
            
            if (iter->token_kind() == __TOKEN_N::tokens::KEYWORD_IMPORT) {
                /// remove all import tokens
                /// calculate the 'import' token to the ';' or '}' token
                i32  offset    = 1;
                bool has_brace = false;
                __TOKEN_N::Token start = iter.current().get();

                if (!iter.peek(offset).has_value() || iter.peek(offset).value().get().token_kind() == __TOKEN_N::tokens::EOF_TOKEN) {
                    error::Panic(error::CodeError{
                        .pof      = &start,
                        .err_code = 0.0001,
                        .mark_pof = true,
                        .fix_fmt_args{},
                        .err_fmt_args{"expected a something after 'import' keyword"},
                        .opt_fixes{},
                    });

                    return false;
                }

                std::unordered_set<__TOKEN_N::tokens> valid_kinds = {
                    __TOKEN_N::tokens::PUNCTUATION_OPEN_BRACE,
                    __TOKEN_N::tokens::IDENTIFIER,
                    __TOKEN_N::tokens::LITERAL_STRING
                };

                if (!valid_kinds.contains(iter.peek(1)->get().token_kind())) {
                    error::Panic(error::CodeError{
                        .pof      = &start,
                        .err_code = 0.0001,
                        .mark_pof = true,
                        .fix_fmt_args{},
                        .err_fmt_args{"expected a valid token after 'import' but found '" + iter.peek(1)->get().token_kind_repr() + "'."},
                        .opt_fixes{},
                    });

                    return false;
                }

                if (iter.peek(offset)->get().token_kind() ==
                    __TOKEN_N::tokens::PUNCTUATION_OPEN_BRACE) {
                    has_brace = true;
                    ++offset;  // skip the opening brace
                }

                while (iter.peek(offset).has_value()) {  // at this stage this is safe
                    if (!iter.peek(offset).has_value()) {
                        error::Panic(error::CodeError{
                            .pof      = &start,
                            .err_code = 0.0001,
                            .mark_pof = true,
                            .fix_fmt_args{},
                            .err_fmt_args{"expected a " + std::string(has_brace ? "'}'" : "';'") + " to close the 'import' statement"},
                            .opt_fixes{},
                            .level=error::Level::ERR
                        });
                        
                        found_import = false;
                        goto leave_loop_has_processable_import;
                    }

                    if (iter.peek(offset)->get().token_kind() ==
                        (has_brace ? __TOKEN_N::tokens::PUNCTUATION_CLOSE_BRACE
                                   : __TOKEN_N::tokens::PUNCTUATION_SEMICOLON)) {
                        found_import  = true;
                        goto leave_loop_has_processable_import;
                    }

                    ++offset;
                }

                error::Panic(error::CodeError{
                    .pof      = &start,
                    .err_code = 0.0001,
                    .mark_pof = true,
                    .fix_fmt_args{},
                    .err_fmt_args{"expected a " + std::string(has_brace ? "'}'" : "';'") + " to close the import"},
                    .opt_fixes{},
                    .level=error::Level::ERR
                });

                found_import = false;
                break;
            }

            iter.advance();
        }

leave_loop_has_processable_import:
        return found_import;
    }

    void ImportProcessor::process() {
        /// make an ast parser
        __TOKEN_N::TokenList::TokenListIter           iter = tokens.begin();
        __AST_NODE::Statement                         ast_parser(iter);
        __AST_N::NodeT<__AST_NODE::ImportState>       import;
        __AST_N::ParseResult<__AST_NODE::ImportState> import_result;

        size_t start_pos = std::numeric_limits<size_t>::max();
        Token  start;
        Token  end;
        size_t end_pos = std::numeric_limits<size_t>::max();
        bool   found_import = false;

        while (iter.remaining_n() > 0) {
            if (iter->token_kind() == __TOKEN_N::tokens::KEYWORD_FFI) {
                /// TODO: add checks to see if tokens are empty after advancing
                bool  has_brace = false;
                Token ffi_tok   = iter.current();

                ADVANCE_AND_CHECK;  // skip 'ffi'

                if (iter->token_kind() != __TOKEN_N::tokens::LITERAL_STRING) {
                    Token bad_tok = iter.current();

                    error::Panic(error::CodeError{
                        .pof      = &bad_tok,
                        .err_code = 0.0001,
                        .mark_pof = true,
                        .fix_fmt_args{},
                        .err_fmt_args{"expected a string literal after 'ffi'"},
                        .opt_fixes{},
                    });

                    override_processable_imports = (void*)(0xFFF);
                    return;
                }

                ADVANCE_AND_CHECK;  // skip the language

                if (iter->token_kind() == __TOKEN_N::tokens::PUNCTUATION_OPEN_BRACE) {
                    has_brace = true;
                    ADVANCE_AND_CHECK;  // skip the opening brace
                }

                if (iter->token_kind() != __TOKEN_N::tokens::KEYWORD_IMPORT) {
                    continue;  // skip parsing the ffi block if it's not an import
                }

                while (iter->token_kind() != (has_brace
                                                  ? __TOKEN_N::tokens::PUNCTUATION_CLOSE_BRACE
                                                  : __TOKEN_N::tokens::PUNCTUATION_SEMICOLON)) {
                    if (iter.remaining_n() == 0) {
                        error::Panic(error::CodeError{
                            .pof      = &ffi_tok,
                            .err_code = 0.0001,
                            .mark_pof = true,
                            .fix_fmt_args{},
                            .err_fmt_args{std::string("expected a") +
                                          (has_brace ? " '}'" : " ';'") +
                                          " to close the 'ffi' block"},
                            .opt_fixes{},
                        });

                        override_processable_imports = (void*)(0xFFF);
                        return;
                    }

                    ADVANCE_AND_CHECK;  // WARNING: this may fail since we break and dont break
                                        // again.
                }
            }
            
            if (iter->token_kind() == __TOKEN_N::tokens::KEYWORD_IMPORT) {
                /// remove all import tokens
                /// calculate the 'import' token to the ';' or '}' token
                i32  offset    = 1;
                bool has_brace = false;
                start          = iter.current().get();
                start_pos      = iter.position();

                if (!iter.peek(offset).has_value() || iter.peek(offset).value().get().token_kind() == __TOKEN_N::tokens::EOF_TOKEN) {
                    error::Panic(error::CodeError{
                        .pof      = &start,
                        .err_code = 0.0001,
                        .mark_pof = true,
                        .fix_fmt_args{},
                        .err_fmt_args{"expected a something after 'import' keyword"},
                        .opt_fixes{},
                    });
                    
                    override_processable_imports = (void*)(0xFFF);
                    return;
                }

                if (iter.peek(offset)->get().token_kind() ==
                    __TOKEN_N::tokens::PUNCTUATION_OPEN_BRACE) {
                    has_brace = true;
                    ++offset;  // skip the opening brace
                }

                while (iter.peek(offset).has_value()) {  // at this stage this is safe
                    if (!iter.peek(offset).has_value()) {
                        error::Panic(error::CodeError{
                            .pof      = &start,
                            .err_code = 0.0001,
                            .mark_pof = true,
                            .fix_fmt_args{},
                            .err_fmt_args{"expected a ';' or '}' to close the 'import' statement"},
                            .opt_fixes{},
                        });

                        override_processable_imports = (void*)(0xFFF);
                        return;
                    }

                    if (iter.peek(offset)->get().token_kind() ==
                        (has_brace ? __TOKEN_N::tokens::PUNCTUATION_CLOSE_BRACE
                                   : __TOKEN_N::tokens::PUNCTUATION_SEMICOLON)) {
                        end = iter.peek(offset).value().get();
                        end_pos = iter.peek(offset).value().get().offset();
                        break;
                    }

                    ++offset;
                }

                import_result = ast_parser.parse<__AST_NODE::ImportState>();
                found_import  = import_result.has_value();
                break;
            }

            iter.advance();
        }

        if (!found_import) {
            override_processable_imports = (void*)(0xFFF);
            return;
        }

        if (!import_result.has_value() || start == Token()) {
            import_result.error().panic();
            override_processable_imports = (void*)(0xFFF);
            return;
        }

        /// parse import if it exists
        import = import_result.value();

        /// NOTE: the first element of import_dirs is the cwd

        /// both spec and single imports are allowed here, and do get processed
        /// order of checking is important

        /// we first normalize the ... by doing the following: we take the whole scope path replace
        /// the `::` with `/` we dont add anything to the end tho just yet.

        /// if we have `import module ...` then we attach a .hlx to the end of it and then resolve
        /// it starting with the cwd then each of the specified import paths, if we have collisions,
        /// we take what we see first then warn saying import also matched in other locations.

        /// if we have 'import ...` we first see if the specified dir exists, if so then does it
        /// contain a .hlx file matching the back of the path name, like lets say `import foo::bar`
        /// does foo/bar exist as a dir, if so does foo/bar/bar.hlx exist, if so process that as a
        /// whole different compile unit entirely since its a lib and follow external linkage
        /// but if foo/bar is not a dir then check for foo/bar.hlx, if it exists start a new compile
        /// action and do internal linkage.

        /// NOTE: if we have a spec import, backtrack each path from right to left looking, since
        ///       we cant resolve symbols yet and warn saying specified imported item will not get
        ///       added to the current namespace in this version of the compiler.

        /// if we have `import "..."` we directly look for the specified file, and apply external
        /// linkage

        /// if we have `import module ".."` we directly look for the specified file, and apply
        /// internal linkage

        /// after all this if we cant find any path error out.

        std::vector<std::filesystem::path> resolved_paths;
        MultipleImportsNormalized          resolved_imports;

        if (import->type == __AST_NODE::ImportState::Type::Single) {
            SingleImportNormalized imports =
                resolve_single_import(__AST_N::as<__AST_NODE::SingleImport>(import->import), start);

            resolved_imports.emplace_back(imports);

        } else if (import->type == __AST_NODE::ImportState::Type::Spec) {
            auto imports =
                resolve_spec_import(__AST_N::as<__AST_NODE::SpecImport>(import->import), start);

            resolved_imports.insert(resolved_imports.end(), imports.begin(), imports.end());
        }

        /// now we can process all the imports individually
        std::vector<NormalizedImport> normalized;
        std::unordered_map<NormalizedImport, SingleImportNormalized *, NormalizedImportHasher>
            resolved_mapping;

        for (SingleImportNormalized &_import : resolved_imports) {
            /// now the following happens
            /// if the path is a string look for the path if not found error
            ///     if found and theres a alias present insert 'namespace alis =
            ///     resolved_namespace(path)`
            /// if the path is a token list join the path and sep with '/' keep backtracking until
            /// we
            ///     find a match either (a lib if not marked as a module) or a hlx file
            ///     if found and theres a alias present insert 'namespace alis =
            ///     resolved_namespace(path)` if theres a wildcard present, insert `using namespace
            ///     resolved_namespace(path)` if we had to do any backtracking, warn saying symbol
            ///     imports are not supported yet
            ///        remove them for and and replace with a single import

            ///     before the using/namespace line, process the whole file, add the forward decls
            ///     to the current file with a #ifndef guard, if the file is already included in the
            ///     current and store the output file in a global import vec.

            // NOTE: do not forget to check for .hdlx files since those are tokenized and copied
            // (avoiding duplicates)
            //       they do not go through the rest of the process, they are just inserted into the
            //       current file

            std::filesystem::path path;

            if (std::get<0>(_import).index() == 0) {  // path is a string
                // foo/bar/baz
                // helix-lang/
                path = std::get<std::filesystem::path>(std::get<0>(_import));
            } else {  // path is a token list
                __TOKEN_N::TokenList import_path =
                    std::get<__TOKEN_N::TokenList>(std::get<0>(_import));

                path = import_path.pop_front().value();

                for ([[maybe_unused]] auto & _: import_path) {
                    path /= import_path.pop_front().value();
                }
            }

            std::vector<ResolvedPath> temp = final_import_normalizer(
                path, start, std::get<0>(_import).index() == 0, import->explicit_module);

            if (!temp.empty()) {
                for (auto &elm : temp) {
                    normalized.emplace_back(std::move(elm));
                    resolved_mapping[normalized.back()] = &_import;
                }
            }
        }

        /// insert inline c++
        if (normalized.empty()) {
            return;
        }

        /// remove the import tokens
        tokens.remove(start, end);

        /// see if any of the imports are alias or wildcard imports in resolved_imports
        for (NormalizedImport &imp : normalized) {
            auto [path, rel_to_index, _] = imp;
            std::string namespace_path =
                helix::abi::mangle((import_dirs[rel_to_index] / path).generic_string(),
                                      helix::abi::ObjectType::Module);

            if ((resolved_mapping.find(imp) != resolved_mapping.end()) && (rel_to_index != std::numeric_limits<size_t>::max())) {
                auto [what_was_imported, alias, is_wildcard] = *resolved_mapping[imp];
                /// so now we know the import is in helix::<namespace_path>
                /// so lets say:
                /// what_was_imported = foo::bar | "foo/bar"
                /// namespace_path = _VOLUME_DEV_WORK_FOO_BAR_HLX_N
                /// what we do is either insert a using namespace _VOLUME_DEV_WORK_FOO_BAR_HLX_N; if
                /// wildcard else do namespace alias = _VOLUME_DEV_WORK_FOO_BAR_HLX_N;

                if (alias.empty()) {
                    if (what_was_imported.index() == 0) {
                        /// get the stem since thats the alias
                        std::string elem = std::get<std::filesystem::path>(what_was_imported)
                                               .stem()
                                               .generic_string();

                        alias.push_back({__TOKEN_N::tokens::IDENTIFIER, elem, start});
                    } else {
                        alias.push_back(
                            std::move(std::get<__TOKEN_N::TokenList>(what_was_imported).back()));
                    }
                }

                if (is_wildcard) {
                    /// insert using namespace ...
                    bool trivially_import = false;

                    auto file          = (import_dirs[rel_to_index] / path).generic_string();
                    auto contents      = __CONTROLLER_FS_N::read_file(file);
                    auto import_tokens = lexer::Lexer(contents, file).tokenize();

                    for (auto &toke : import_tokens) {
                        if (toke->token_kind() == __TOKEN_N::tokens::LITERAL_COMPILER_DIRECTIVE) {
                            if (toke->value().contains("trivially_import(true)")) {
                                trivially_import = true;
                                break;
                            }
                        }
                    }

                    if (!trivially_import) {
                        insert_inline_cpp(tokens, {start_pos, start}, namespace_path);
                    }
                } else {
                    std::string _alias;

                    if (!alias.empty()) {
                        for (auto &tok : alias) {
                            _alias += tok->value();
                            _alias += "::";
                        }

                        if (!_alias.empty()) {
                            // pop the last `::`
                            _alias.pop_back();
                            _alias.pop_back();
                        }
                    }

                    insert_inline_cpp(
                        tokens, {start_pos, start}, std::make_pair(_alias, namespace_path));
                }
            } else {
                // error::Panic(error::CodeError{
                //     .pof      = &start,
                //     .err_code = 0.0001,
                //     .mark_pof = true,
                //     .fix_fmt_args{},
                //     .err_fmt_args{"the import handler lost the import at: " +
                //                   (import_dirs[rel_to_index] / path).generic_string()},
                //     .opt_fixes{},
                // });
            }
        }

        /// add the imports to the unit
        this->extend(normalized, import_dirs, parsed_args, start_pos, start);
    }

    /// \brief force imports a file into the current compilation unit (must be a module import)
    /// \param path the absolute path to the file
    /// \param parsed_args the parsed cli args
    void ImportProcessor::force_import(const std::filesystem::path           &path,
                                       __CONTROLLER_CLI_N::CLIArgs /* copy */ parsed_args) {
        CompilationUnit unit;  // create a new compile unit instance
        parsed_args.file = path.generic_string();

        // check if the file exists and is a regular file by this point this should always be
        // true but just in case we check
        if (!std::filesystem::is_regular_file(parsed_args.file)) [[unlikely]] {
            error::Panic(error::CompilerError{
                .err_code = 0.0001, .fix_fmt_args = {}, .err_fmt_args = {"could not locate the requsted import of: " + path.generic_string()}});
        
            return;
        }

        auto [action, ec] = unit.build_unit(parsed_args, false, true);

        if (ec == 1) {  /// if there was an error, skip this import
            return;
        }

        generator::CXIR::CXIR forward_decls = unit.generate_cxir(false);
        this->imports.push_back(std::move(forward_decls));
    }

    void ImportProcessor::append(const std::filesystem::path              &path,
                                 size_t                                    rel_to_index,
                                 Type                                      type,
                                 size_t                                    start_pos,
                                 const std::vector<std::filesystem::path> &import_dirs,
                                 __CONTROLLER_CLI_N::CLIArgs              &parsed_args,
                                 __TOKEN_N::Token                         &start) {
        CompilationUnit unit;  // create a new compile unit instance
        parsed_args.file =
            (import_dirs[rel_to_index] / path).generic_string();  // set the file path
        
        DEPENDENCIES.insert(import_dirs[rel_to_index] / path);

        // check if the file exists and is a regular file by this point this should always be
        // true but just in case we check
        if (!std::filesystem::is_regular_file(parsed_args.file)) [[unlikely]] {
            // error::Panic(error::CodeError{
            //     .pof      = &start,
            //     .err_code = 0.0001,
            //     .mark_pof = true,
            //     .fix_fmt_args{},
            //     .err_fmt_args{"import path could not be resolved"},
            //     .opt_fixes{},
            // });

            return;
        }

        if (type == Type::Module) {
            /// thing is once the basic ver is done, i need to be able to do cache compilation
            /// basicly make a lock.json file that stores the hash of the file, the path to the
            /// compiled file, and the path to the source file, on each compile check the hash
            /// and if it matches the source file, use the compiled file, if not recompile

            /// this does not work right now since stuff like templates can not be instantiated
            /// from another file and be defined in another.

            // auto [action, ec] = unit.build_unit(parsed_args, false);
            // COMPILE_ACTIONS.emplace_back(std::move(action));  /// this needs to be included in
            /// the final compile action list

            auto [action, ec] = unit.build_unit(parsed_args, false, true);

            if (ec == 1) {  /// if there was an error, skip this import
                return;
            }

            generator::CXIR::CXIR forward_decls = unit.generate_cxir(false);
            this->imports.push_back(std::move(forward_decls));  /// this gets passed as an ptr
                                                                /// during cxir generation

        } else if (type == Type::Header) {
            __TOKEN_N::TokenList import_tokens = unit.pre_process(parsed_args, false);

            this->tokens.insert(
                this->tokens.cbegin() +
                    static_cast<std::ptrdiff_t>(
                        start_pos == std::numeric_limits<size_t>::max() ? 0 : start_pos),
                import_tokens.cbegin(),
                import_tokens.cend());
        }
    }

    void ImportProcessor::extend(const std::vector<NormalizedImport>      &normalized,
                                 const std::vector<std::filesystem::path> &import_dirs,
                                 __CONTROLLER_CLI_N::CLIArgs              &parsed_args,
                                 size_t                                    start_pos,
                                 __TOKEN_N::Token                         &start) {

        for (const auto &[path, rel_to_index, type] : normalized) {
            this->append(path, rel_to_index, type, start_pos, import_dirs, parsed_args, start);
        }
    }

    /// \returns a resolved path (maybe), which index it was found at, and
    ///          the type of the path that was found, and a vec of also matched paths
    std::vector<ImportProcessor::ResolvedPath> ImportProcessor::final_import_normalizer(
        std::filesystem::path & path, Token marker, bool keep_ext, bool is_module) {
        /// [(path, base_index, type), ...]
        std::vector<std::tuple<std::filesystem::path, size_t, Type>> found_paths;

        /// make sure theres no extension in the provided path and if keep_ext is false remove it
        auto check_and_remove_duplicates = [&]() {
            std::unordered_map<std::filesystem::path, std::tuple<size_t, Type>> path_map;

            for (const auto &entry : found_paths) {
                const auto &[path, index, type] = entry;

                if (path_map.find(path) == path_map.end() || index < std::get<0>(path_map[path])) {
                    path_map[path] = std::make_tuple(index, type);

                } else {
                    /// see if it exists in the location we are looking for
                    if (std::filesystem::exists(import_dirs[index] / path) &&
                        std::filesystem::is_regular_file(import_dirs[index] / path)) {
                        // be quiet
                    }

                    /// the file dont exist
                }
            }

            found_paths.clear();

            for (const auto &[path, data] : path_map) {
                found_paths.emplace_back(path, std::get<0>(data), std::get<1>(data));
            }
        };

        if (!keep_ext) {
            if (path.has_extension()) {
                path = path.replace_extension();  // remove the extension if it exists
            }
        } else {
            /// in this case the behavior is different
            /// we look for the extance of either path or import[i] / path

            for (size_t i = 0; i < import_dirs.size(); ++i) {
                auto check_and_emplace = [&](const std::filesystem::path &_path, size_t index) {
                    if (std::filesystem::exists(_path) && std::filesystem::is_regular_file(_path)) {

                        if (path.extension() == ".hlx") {
                            found_paths.emplace_back(_path, index, Type::Module);
                        } else if (path.extension() == ".hdlx") {
                            found_paths.emplace_back(_path, index, Type::Header);
                        }

                        return true;
                    }

                    return false;
                };

                if (check_and_emplace(path, std::numeric_limits<size_t>::max()) ||
                    check_and_emplace(import_dirs[i] / path, i)) {
                    continue;
                }

                // error::Panic(error::CodeError{
                //     .pof      = &marker,
                //     .err_code = 0.0123,
                //     .mark_pof = true,
                //     .fix_fmt_args{},
                //     .err_fmt_args{"import path could not be resolved"},
                //     .opt_fixes{},
                //     .level = error::ERR,
                // });
            }

            /// now figure out duplicates and remove all but the lowest index
            check_and_remove_duplicates();
            return found_paths;
        }

        bool found_module = false;
        bool found_header = false;

        auto add_ext = [](std::filesystem::path path, std::string ext) -> std::filesystem::path {
            return path.replace_extension(ext);
        };

        std::filesystem::path helix_mod     = add_ext(path, ".hlx");
        std::filesystem::path helix_hdr     = add_ext(path, ".hdlx");
        std::filesystem::path helix_mod_lib = add_ext(path / path.stem(), ".hlx");
        std::filesystem::path helix_hdr_lib = add_ext(path / path.stem(), ".hdlx");

        bool found_helix_mod     = false;
        bool found_helix_hdr     = false;
        bool found_helix_mod_lib = false;
        bool found_helix_hdr_lib = false;
        bool found_any_import    = false;

        for (size_t i = 0; i < import_dirs.size(); ++i) {
            /// exmaple path = foo/bar
            /// we check in the following order:
            /// 1. foo/bar.hlx
            /// 2. foo/bar.hdlx
            /// 3. foo/bar/bar.hlx
            /// 4. foo/bar/bar.hdlx

            if (std::filesystem::exists(import_dirs[i] / helix_mod) &&
                std::filesystem::is_regular_file(import_dirs[i] / helix_mod)) {
                found_helix_mod = true;
            }
            if (std::filesystem::exists(import_dirs[i] / helix_mod_lib) &&
                std::filesystem::is_regular_file(import_dirs[i] / helix_mod_lib)) {
                found_helix_mod_lib = true;
            }

            if (!is_module) {  // if its explicated as a module, we dont check for headers
                if (std::filesystem::exists(import_dirs[i] / helix_hdr) &&
                    std::filesystem::is_regular_file(import_dirs[i] / helix_hdr)) {
                    found_helix_hdr = true;
                }
                if (std::filesystem::exists(import_dirs[i] / helix_hdr_lib) &&
                    std::filesystem::is_regular_file(import_dirs[i] / helix_hdr_lib)) {
                    found_helix_hdr_lib = true;
                }
            }

            // these 2 are true if we have a structure like:
            // our import rules sate:
            //  libs are first priority
            //  headers are second
            //  modules have least priority (UNLESS MARKED `module` then they are first)
            //
            // main.hlx <- `import foo`
            // foo.hlx
            // foo.hdlx
            // foo/
            //   foo.hlx
            //   foo.hdlx
            //
            // in this case following our rules we end up with getting foo/foo.hdlx
            // but how to get the rest?
            // to get:
            //    ./foo.hlx    <- `import module foo`
            //    foo/foo.hlx  <- `import module foo::foo`
            //
            //    ./foo.hdlx   <- `import foo`
            //    foo/foo.hdlx <- `import foo::foo`
            //
            // see how now we have no idea what to import? theres no way to import the `./foo.hdlx`
            // first we shall do the non module checks:

            // show warnings
            if (!is_module) {
                if (found_header && found_helix_hdr_lib) {
                    WARN_PANIC_FIX("found both libary header and header for the specified path. "
                                   "using the default location: " +
                                       (import_dirs[i] / helix_hdr).generic_string(),
                                   "if your intention was to import the library header, rename "
                                   "one, or consider updating the "
                                   "line to: 'import \"" +
                                       helix_hdr_lib.generic_string() + "\"'",
                                   &marker);
                }
            } else {
                if (found_module && found_helix_mod_lib) {
                    WARN_PANIC_FIX("found both libary and module for the specified path. using the "
                                   "default location: " +
                                       (import_dirs[i] / helix_hdr).generic_string(),
                                   "if your intention was to import the library module, rename "
                                   "one, or consider updating the "
                                   "line to: 'import \"" +
                                       helix_hdr_lib.generic_string() + "\"'",
                                   &marker);
                }
            }

            switch (find_import_priority(is_module,
                                         found_helix_mod,
                                         found_helix_hdr,
                                         found_helix_mod_lib,
                                         found_helix_hdr_lib)) {
                case 1:                            // helix_hdr
                    if (is_module) [[unlikely]] {  // should never get this
                        WARN_PANIC_FIX("found only header when import is marked explicitly as "
                                       "`module` ignoring header",
                                       "consider using a explict path",
                                       &marker);
                        break;
                    }

                    found_paths.emplace_back(helix_hdr, i, Type::Header);
                    break;

                case 2:                            // helix_hdr_lib
                    if (is_module) [[unlikely]] {  // should never get this
                        WARN_PANIC_FIX("found only header when import is marked explicitly as "
                                       "`module` ignoring header",
                                       "consider using a explict path",
                                       &marker);
                        break;
                    }

                    found_paths.emplace_back(helix_hdr_lib, i, Type::Header);
                    break;

                case 3:  // helix_mod
                    found_paths.emplace_back(helix_mod, i, Type::Module);
                    break;

                case 4:  // helix_mod_lib
                    found_paths.emplace_back(helix_mod_lib, i, Type::Module);
                    break;
            }

            if (found_header || found_helix_hdr || found_helix_mod || found_helix_mod_lib) {
                found_any_import = true;
            }
        }

        if (!found_any_import) {
            error::Panic(error ::CodeError{
                .pof      = &marker,
                .err_code = 0.0123,
                .mark_pof = true,
                .fix_fmt_args{},
                .err_fmt_args{"import path could not be resolved"},
                .opt_fixes{},
                .level = error::ERR,
            });

            found_paths.emplace_back(path, std::numeric_limits<size_t>::max(), Type::Module);
            
            return found_paths;
        }

        check_and_remove_duplicates();
        return found_paths;
    }
}