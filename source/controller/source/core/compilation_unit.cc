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

#include <array>
#include <chrono>
#include <filesystem>
#include <iostream>
#include <memory>
#include <neo-panic/include/error.hh>
#include <neo-pprint/include/hxpprint.hh>
#include <stdexcept>
#include <string>
#include <vector>

#include "controller/include/Controller.hh"
#include "controller/include/config/Controller_config.def"
#include "controller/include/shared/file_system.hh"
#include "controller/include/shared/logger.hh"
#include "controller/include/tooling/tooling.hh"
#include "generator/include/CX-IR/CXIR.hh"
#include "lexer/include/lexer.hh"
#include "parser/ast/include/private/base/AST_base.hh"
#include "parser/ast/include/types/AST_jsonify_visitor.hh"
#include "parser/ast/include/types/AST_types.hh"
#include "parser/preprocessor/include/preprocessor.hh"
#include "token/include/private/Token_base.hh"
#include "parser/preprocessor/include/private/utils.hh"

extern bool LSP_MODE;
inline bool CORE_IMPORTED = false;

template <typename T>
void process_paths(std::vector<T>                     &paths,
                   std::vector<std::filesystem::path> &add_to,
                   std::filesystem::path &
                       base_to,  //< must be a file not a dir, it is checked also must be normalized
                   const std::vector<std::filesystem::path>& add_after_base) {
    std::vector<std::filesystem::path> normalized_input;
    std::filesystem::path              cwd = __CONTROLLER_FS_N::get_cwd();
    std::filesystem::path              exe = __CONTROLLER_FS_N::get_exe();

    if constexpr (!std::same_as<T, std::string> && !std::same_as<T, std::filesystem::path>) {
        throw std::runtime_error("invalid usage of process_paths only string or path vec allowed");
    }

    if (!paths.empty()) {
        for (auto &dir : paths) {
            normalized_input.emplace_back(dir);
        }
    }

    /// first path added is always the base_to if its not the cwd, then the cwd then the rest
    if (std::filesystem::is_regular_file(base_to)) {
        if (!std::filesystem::exists(base_to.parent_path()) &&
            !std::filesystem::is_directory(base_to.parent_path())) {
            helix::log<LogLevel::Warning>(
                "specified include dir is not a directory or does not exist: \'" +
                base_to.parent_path().generic_string() + "\'");
        } else if (base_to.parent_path() != cwd) {
            add_to.emplace_back(base_to.parent_path());
        }

    } else {
        throw std::runtime_error("input must be a file.");
    }

    // add the cwd
    add_to.emplace_back(cwd);

    if (!add_after_base.empty()) {
        for (auto &dir : add_after_base) {
            if (std::filesystem::is_directory(dir)) {
                add_to.emplace_back(dir);
            } else {
                helix::log<LogLevel::Warning>(
                    "specified include dir is not a directory or does not exist: \'" +
                    dir.generic_string() + "\'");
            }
        }
    }

    // add the remaining paths
    if (!normalized_input.empty()) {
        for (const auto &dir : normalized_input) {
            auto path = __CONTROLLER_FS_N::resolve_path(dir.generic_string(), false);

            if (path.has_value() && !std::filesystem::is_directory(path.value())) {
                helix::log<LogLevel::Warning>(
                    "specified include dir is not a directory or does not exist: \'" +
                    dir.generic_string() + "\'");

                continue;
            }

            add_to.emplace_back(path.value());
        }
    }
}

int CompilationUnit::compile(int argc, char **argv) {
    __CONTROLLER_CLI_N::CLIArgs parsed_args(argc, argv, "Helix v0.0.1-alpha-179a");
    check_exit(parsed_args);

    return compile(parsed_args);
}

__TOKEN_N::TokenList CompilationUnit::pre_process(__CONTROLLER_CLI_N::CLIArgs &parsed_args,
                                                  bool                         enable_logging) {
    std::vector<std::filesystem::path> import_dirs;
    std::vector<std::filesystem::path> link_dirs;
    std::filesystem::path in_file_path = __CONTROLLER_FS_N::normalize_path(parsed_args.file);

    parser::lexer::Lexer lexer  = {__CONTROLLER_FS_N::read_file(in_file_path.generic_string()),
                                   in_file_path.generic_string()};
    __TOKEN_N::TokenList tokens = __TOKEN_N::TokenList(lexer.tokenize());

    helix::log_opt<LogLevel::Progress>(parsed_args.verbose, "tokenized");

    process_paths(parsed_args.library_dirs,
                  link_dirs,
                  in_file_path,
                  {__CONTROLLER_FS_N::get_exe().parent_path().parent_path() / "libs"});

    process_paths(parsed_args.include_dirs,
                  import_dirs,
                  in_file_path,
                  {__CONTROLLER_FS_N::get_exe().parent_path().parent_path() / "pkgs"});

    if (parsed_args.verbose) {
        helix::log_opt<LogLevel::Debug>(enable_logging, "import dirs: [");
        for (const auto &dir : import_dirs) {
            helix::log_opt<LogLevel::Debug>(enable_logging, dir.generic_string() + ", ");
        }
        helix::log_opt<LogLevel::Debug>(enable_logging, "]");

        helix::log_opt<LogLevel::Debug>(enable_logging, "link dirs: [");
        for (const auto &dir : link_dirs) {
            helix::log_opt<LogLevel::Debug>(enable_logging, dir.generic_string() + ", ");
        }
        helix::log_opt<LogLevel::Debug>(enable_logging, "]");
    }

    helix::log_opt<LogLevel::Progress>(parsed_args.verbose, "preprocessing");

    this->import_processor = std::make_shared<__PREPROCESSOR_N::ImportProcessor>(tokens, import_dirs, parsed_args);
            
    if (tokens.empty()) {
        return {};
    }

    if (!CORE_IMPORTED) { // 1 core import per file
        CORE_IMPORTED = true;

        auto core = __CONTROLLER_FS_N::get_exe().parent_path().parent_path() / "core" / "core.hlx";
        auto pos = tokens[0];

        import_processor->force_import(core, parsed_args);
        // import_processor->insert_inline_cpp(tokens, {0, pos}, sanitize_string(core.generic_string()));
    }
    
    while (import_processor->has_processable_import()) { // recursively process imports
        import_processor->process();
    }

    if (error::HAS_ERRORED) {
        return {};
    }

    helix::log_opt<LogLevel::Progress>(parsed_args.verbose, "preprocessed");

    if (parsed_args.emit_tokens) {
        helix::log_opt<LogLevel::Debug>(enable_logging, tokens.to_json());
        print_tokens(tokens);
    }

    return tokens;
}

__AST_N::NodeT<__AST_NODE::Program> CompilationUnit::parse_ast(__TOKEN_N::TokenList &tokens,
                                                               std::filesystem::path in_file_path) {
    remove_comments(tokens);
    ast = __AST_N::make_node<__AST_NODE::Program>(tokens, in_file_path.generic_string());
    if (import_processor != nullptr) {
        ast->parse(false, import_processor);
    } else {
        helix::log<LogLevel::Error>("import processor is null");
    }
    return ast;
}

/// compile and return the path of the compiled file without calling the linker
/// ret codes: 0 - success, 1 - error, 2 - lsp mode
std::pair<CXXCompileAction, int> CompilationUnit::build_unit(
    __CONTROLLER_CLI_N::CLIArgs &parsed_args, bool enable_logging, bool no_unit) {
    if (parsed_args.error) {
        NO_LOGS           = true;
        error::SHOW_ERROR = true;
    }

    if (parsed_args.quiet || parsed_args.lsp_mode) {
        NO_LOGS           = true;
        error::SHOW_ERROR = false;
    }

    VERBOSE_LOG(parsed_args.get_all_flags);

    std::filesystem::path in_file_path = __CONTROLLER_FS_N::normalize_path(parsed_args.file);
    __TOKEN_N::TokenList  tokens       = pre_process(parsed_args, enable_logging);

    if (tokens.empty()) {
        return {{}, 1};
    }

    helix::log_opt<LogLevel::Progress>(parsed_args.verbose, "parsing ast...");
    
    ast = parse_ast(tokens, in_file_path);
    
    helix::log_opt<LogLevel::Progress>(parsed_args.verbose, "parsed");

    if (!ast) {
        return {{}, 1};
    }

    if (parsed_args.emit_ast) {
        __AST_VISITOR::Jsonify json_visitor;
        ast->accept(json_visitor);

        if (parsed_args.lsp_mode) {
            print(json_visitor.json.to_string());
            return {{}, 2};
        }

        helix::log<LogLevel::Debug>(json_visitor.json.to_string());
    }

    if (error::HAS_ERRORED) {
        LSP_MODE = parsed_args.lsp_mode;
        return {{}, 2};
    }

    if (no_unit) {
        return {{}, 0};
    }

    generator::CXIR::CXIR emitter = generate_cxir(false);
    helix::log_opt<LogLevel::Progress>(parsed_args.verbose, "emitted cx-ir");

    if (parsed_args.emit_ir) {
        emit_cxir(emitter, parsed_args.verbose);
    }

    std::filesystem::path out_file = determine_output_file(parsed_args, in_file_path);

    if (error::HAS_ERRORED) {
        return {{}, 1};
    }

    flag::CompileFlags action_flags;

    if (parsed_args.build_mode == __CONTROLLER_CLI_N::CLIArgs::MODE::DEBUG_) {
        action_flags |= flag::CompileFlags(flag::types::CompileFlags::Debug);
    }

    if (parsed_args.verbose) {
        action_flags |= flag::CompileFlags(flag::types::CompileFlags::Verbose);
    }

    return {CXXCompileAction::init(emitter, out_file, action_flags, parsed_args.cxx_args), 0};
}

generator::CXIR::CXIR CompilationUnit::generate_cxir(bool forward_only) {

    std::vector<generator::CXIR::CXIR> imports;

    if (import_processor != nullptr) {
        imports = std::move(import_processor->imports);
    }

    generator::CXIR::CXIR emitter(forward_only, std::move(imports));

    ast->accept(emitter);
    return emitter;
}

int CompilationUnit::compile(__CONTROLLER_CLI_N::CLIArgs &parsed_args) {
    std::chrono::time_point<std::chrono::high_resolution_clock> start =
        std::chrono::high_resolution_clock::now();
    auto [action, result] = build_unit(parsed_args);
    CXXCompileAction _;
    switch (result) {
        case 0:
            break;

        case 1:
            return 1;

        case 2:
            return 0;
    }

    helix::log_opt<LogLevel::Progress>(action.flags.contains(flag::types::CompileFlags::Verbose), "compiling");

    if (error::HAS_ERRORED || parsed_args.lsp_mode) {
        LSP_MODE = parsed_args.lsp_mode;

        if (LSP_MODE && !parsed_args.emit_ir) {
            return 0;
        }
    }

    compiler.compile_CXIR(std::move(action), LSP_MODE);

    if (LSP_MODE) {
        return 0;
    }

    log_time(start, parsed_args.verbose, std::chrono::high_resolution_clock::now());
    return 0;
}

void CompilationUnit::remove_comments(__TOKEN_N::TokenList &tokens) {
    __TOKEN_N::TokenList new_tokens;

    for (auto &token : tokens) {
        if (token->token_kind() != __TOKEN_N::PUNCTUATION_SINGLE_LINE_COMMENT &&
            token->token_kind() != __TOKEN_N::PUNCTUATION_MULTI_LINE_COMMENT) {
            new_tokens.push_back(token.current().get());
        }
    }

    tokens = new_tokens;
}

/**
 * @brief emit the cx-ir to the console
 *
 * @param emitter
 * @param verbose
 */
void CompilationUnit::emit_cxir /* */ (const generator::CXIR::CXIR &emitter, bool verbose) {
    helix::log<LogLevel::Info>("emitting cx-ir...");

    if (verbose) {
        helix::log<LogLevel::Debug>("\n", colors::fg16::yellow, emitter.to_CXIR(), colors::reset);
    } else {
        helix::log<LogLevel::Info>(
            "\n", colors::fg16::yellow, emitter.to_readable_CXIR(), colors::reset);
    }
}

std::filesystem::path
CompilationUnit::determine_output_file(const __CONTROLLER_CLI_N::CLIArgs &parsed_args,
                                       const std::filesystem::path       &in_file_path) {

    std::string out_file = (parsed_args.output_file.has_value())
                               ? parsed_args.output_file.value()
                               : std::filesystem::path(in_file_path).stem().generic_string();

#if defined(_WIN32) || defined(WIN32) || defined(_WIN64) || defined(WIN64)
    out_file += ".exe";
#endif

    return __CONTROLLER_FS_N::normalize_path_no_check(out_file);
}

void CompilationUnit::log_time(const std::chrono::high_resolution_clock::time_point &start,
                               bool                                                  verbose,
                               const std::chrono::high_resolution_clock::time_point &end) {

    std::chrono::duration<double> diff = end - start;

    if (verbose) {
        helix::log<LogLevel::Debug>("time taken: " + std::to_string(diff.count() * 1e+9) + " ns");
        helix::log<LogLevel::Debug>("            " + std::to_string(diff.count() * 1000) + " ms");
    }
}