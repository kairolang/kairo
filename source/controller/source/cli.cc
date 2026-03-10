///--- The Kairo Project ------------------------------------------------------------------------///
///                                                                                              ///
///   Part of the Kairo Project, under the Attribution 4.0 International license (CC BY 4.0).    ///
///   You are allowed to use, modify, redistribute, and create derivative works, even for        ///
///   commercial purposes, provided that you give appropriate credit, and indicate if changes    ///
///   were made.                                                                                 ///
///                                                                                              ///
///   For more information on the license terms and requirements, please visit:                  ///
///     https://creativecommons.org/licenses/by/4.0/                                             ///
///                                                                                              ///
///   SPDX-License-Identifier: Apache-2.0                                                        ///
///   Copyright (c) 2024 The Kairo Project (CC BY 4.0)                                           ///
///                                                                                              ///
///-------------------------------------------------------------------------------------- C++ ---///

#include "controller/include/cli/cli.hh"

#include <iostream>
#include <optional>
#include <string>

#include "neo-pprint/include/ansi_colors.hh"
#include "neo-pprint/include/hxpprint.hh"
#include "taywee-args/include/args.hh"

__CONTROLLER_CLI_BEGIN {
    CLIArgs::CLIArgs(int argc, char **argv, const std::string &_version) {
        args::ArgumentParser parser("Kairo Compiler Command Line Interface", R"(
Kairo CLI - The Next-Generation Compiler for Modern Development

Usage Examples:
  1. Compile a Kairo source file:
     kairo input_file.kro

  2. Compile with optimization level 2:
     kairo -O2 -o output_file input_file.kro

  3. Generate LLVM Intermediate Representation (IR):
     kairo --emit-llvm -o output.ll input_file.kro

  4. Cross-compile for a specific target:
     kairo --target x86_64-linux-gnu -o output_file input_file.kro

  5. Compile as a library with Rust ABI:
     kairo --lib --rust -o liboutput.a input_file.kro

For more detailed documentation, visit:
  https://kairo-lang.com/docs

For support or to report issues, contact:
  support@kairo-lang.com

Thank you for using Kairo!
DISCLAIMER: All of these options are subject to change in future versions of kairo. (until this message is removed)
)");
        args::HelpFlag       help(parser, "help", "Display this help menu", {'h', "help"});
        args::Flag version(parser, "version", "Display the version information", {'v', "version"});
        args::Flag license(parser, "license", "Display license information", {"license"});

        args::Flag verbose(parser, "verbose", "Enable verbose output", {"verbose"});
        args::Flag quiet(parser, "quiet", "Suppress all output", {"quiet"});
        args::Flag error(parser, "error", "Suppress all output except errors", {"error"});

        args::Flag emit_tokens(
            parser, "emit-tokens", "Output tokenized source code", {"emit-tokens"});
        args::Flag emit_llvm(
            parser, "emit-llvm", "Output LLVM Intermediate Representation (IR)", {"emit-llvm"});
        args::Flag lsp_mode(
            parser, "lsp-mode", "Enable Language Server Protocol (LSP) mode", {"lsp-mode"});
        args::Flag emit_asm(parser, "emit-asm", "Output assembly code", {"emit-asm"});
        args::Flag emit_ast(
            parser, "emit-ast", "Output Abstract Syntax Tree (AST) in JSON format", {"emit-ast"});
        args::Flag emit_cst(
            parser, "emit-cst", "Output Concrete Syntax Tree (CST) in JSON format", {"emit-cst"});
        args::Flag emit_ir(
            parser, "emit-ir", "Output intermediate representation (C++)", {"emit-ir"});
        args::Flag emit_doc(parser,
                            "emit-doc",
                            "Extract and output doc-comments along with signatures in JSON format",
                            {"emit-doc"});
        args::Flag emit_deps(parser, "deps", "Output list of imported dependencies", {"deps"});

        args::Group toolchain_group(
            parser, "Cross Compilation Toolchain Options", args::Group::Validators::AtMostOne);
        args::ValueFlag<std::string> toolchain_target(
            parser, "target", "Specify target triple for cross-compilation", {"target"});
        args::ValueFlag<std::string> toolchain_arch(
            parser, "arch", "Specify target architecture", {"arch"});
        args::ValueFlag<std::string> toolchain_cpu(parser, "cpu", "Specify target MCPU", {"cpu"});
        args::ValueFlag<std::string> toolchain_sdk(
            parser, "sdk", "Specify optional path to SDK", {"sdk"});

        args::ValueFlag<std::string> config_file(
            parser, "config", "Specify path to configuration file", {"config"});
        args::ValueFlag<std::string> output_file(
            parser, "output", "Specify output file path", {'o'});

        args::Flag release(
            parser, "release", "Build in release mode with optimizations", {'r', "release"});
        args::Flag debug(
            parser, "debug", "Build in debug mode with debugging symbols", {'d', "debug"});

        args::Group optimization_group(
            parser, "Optimization Levels", args::Group::Validators::AtMostOne);
        args::Flag optimize1(
            optimization_group, "optimize1", "Enable optimization level 1", {"O1", "optimize1"});
        args::Flag optimize2(
            optimization_group, "optimize2", "Enable optimization level 2", {"O2", "optimize2"});
        args::Flag optimize3(
            optimization_group, "optimize3", "Enable optimization level 3", {"O3", "optimize3"});
        args::Flag optimize4(
            optimization_group, "optimize4", "Enable optimization level 4", {"O4", "optimize4"});
        args::Flag optimize5(
            optimization_group, "optimize5", "Enable optimization level 5", {"O5", "optimize5"});

        args::Flag lib(parser, "lib", "Compile as a library", {"lib"});

        args::Group abi_group(parser, "ABI Options", args::Group::Validators::AtMostOne);
        args::Flag  python_abi(abi_group,
                              "python",
                              "Generate Python stub files and compile to a Python library",
                               {"py", "python"});
        args::Flag  rust_abi(abi_group,
                            "rust",
                            "Generate Rust source files and compile to a Rust library",
                             {"rs", "rust"});
        args::Flag  cxx_abi(abi_group,
                           "cxx",
                           "Generate C++ header files and compile to a linkable object file",
                            {"cxx", "cxx"});
        args::Flag  kairo_abi(
            abi_group, "kairo", "Generate Kairo ABI-compatible library", {"kro", "kairo"});

        args::ValueFlagList<std::string> include_dirs(
            parser, "include", "Specify include directories", {'I'});
        args::ValueFlagList<std::string> library_dirs(
            parser, "libdir", "Specify library directories", {'L'});
        args::ValueFlagList<std::string> link_libraries(
            parser, "lib", "Specify libraries to link against", {'l'});
        args::ValueFlagList<std::string> module_dirs(
            parser, "moddir", "Specify Kairo modules directories", {'m'});
        args::Positional<std::string> input_file(parser, "file", "Specify input file path");

        /// any other flags after -- are treated as compiler flags
        args::PositionalList<std::string> cxx_args(
            parser, "c++_flags", "Flags to pass into the C++ compiler");

        parser.LongSeparator(" ");

        try {
            parser.ParseCLI(argc, argv);

            if (help) {
                print(parser);
                this->exit_   = true;
                this->exit_co = 0;
                return;
            }
            if (version) {
                print("Kairo Compiler Version: ", _version);
                this->exit_   = true;
                this->exit_co = 0;
                return;
            }
            if (license) {
                print(R"(
Kairo Language Project - License Information

This software is part of the Kairo Language Project and is licensed under the Attribution 4.0 International license (CC BY 4.0).

You are permitted to:
  - Use, modify, and redistribute the software
  - Create derivative works, even for commercial purposes

Provided that you:
  - Give appropriate credit
  - Provide a link to the license
  - Indicate if changes were made

For more detailed information, please visit: https://creativecommons.org/licenses/by/4.0/

SPDX-License-Identifier: CC-BY-4.0

This software is provided by the creators of Kairo. Visit our website at:
https://kairo-lang.com/ for more information.
    )");
                this->exit_   = true;
                this->exit_co = 0;
                return;
            }

            this->file = args::get(input_file);
            this->output_file =
                output_file ? std::make_optional(args::get(output_file)) : std::nullopt;

            if (optimize1) {
                optimize = OPTIMIZATION::O1;
            }
            if (optimize2) {
                optimize = OPTIMIZATION::O2;
            }
            if (optimize3) {
                optimize = OPTIMIZATION::O3;
            }
            if (optimize4) {
                optimize = OPTIMIZATION::O4;
            }
            if (optimize5) {
                optimize = OPTIMIZATION::O5;
            }

            this->help        = help;
            this->verbose     = verbose;
            this->quiet       = quiet;
            this->error       = error;
            this->emit_tokens = emit_tokens;
            this->emit_llvm   = emit_llvm;
            this->lsp_mode    = lsp_mode;
            this->emit_asm    = emit_asm;
            this->emit_ast    = emit_ast;
            this->emit_cst    = emit_cst;
            this->emit_ir     = emit_ir;
            this->emit_doc    = emit_doc;
            this->emit_deps   = emit_deps;

            if (verbose && quiet) {
                print_err(colors::fg16::red,
                          "Error:",
                          colors::reset,
                          " Cannot specify both verbose and quiet options.");
                this->exit_   = true;
                this->exit_co = 1;
                return;
            }

            if (release) {
                build_mode = MODE::RELEASE;
            }
            if (debug) {
                build_mode = MODE::DEBUG_;
            }

            if (lib) {
                if (python_abi) {
                    build_lib = ABI::PYTHON;
                } else if (rust_abi) {
                    build_lib = ABI::RUST;
                } else if (cxx_abi) {
                    build_lib = ABI::CXX;
                } else {
                    build_lib = ABI::KAIRO;
                }
            }

            if (toolchain_target) {
                toolchain.target = args::get(toolchain_target);
            }
            if (toolchain_arch) {
                toolchain.arch = args::get(toolchain_arch);
            }
            if (toolchain_cpu) {
                toolchain.cpu = args::get(toolchain_cpu);
            }
            if (toolchain_sdk) {
                toolchain.sdk = args::get(toolchain_sdk);
            }

            if (config_file) {
                this->config_file = args::get(config_file);
            }

            this->include_dirs   = args::get(include_dirs);
            this->library_dirs   = args::get(library_dirs);
            this->link_libraries = args::get(link_libraries);
            this->module_dirs    = args::get(module_dirs);
            this->cxx_args       = args::get(cxx_args);

            this->get_all_flags += "flags: \n";
            this->get_all_flags +=
                "    verbose: " + std::to_string(static_cast<int>(verbose)) + ", \n";
            this->get_all_flags += "    quiet: " + std::to_string(static_cast<int>(quiet)) + ", \n";
            this->get_all_flags +=
                "    emit tokens: " + std::to_string(static_cast<int>(emit_tokens)) + ", \n";
            this->get_all_flags +=
                "    emit llvm: " + std::to_string(static_cast<int>(emit_llvm)) + ", \n";
            this->get_all_flags +=
                "    emit asm: " + std::to_string(static_cast<int>(emit_asm)) + ", \n";
            this->get_all_flags +=
                "    emit ast: " + std::to_string(static_cast<int>(emit_ast)) + ", \n";
            this->get_all_flags +=
                "    emit cst: " + std::to_string(static_cast<int>(emit_cst)) + ", \n";
            this->get_all_flags +=
                "    emit ir: " + std::to_string(static_cast<int>(emit_ir)) + ", \n";
            this->get_all_flags +=
                "    emit doc: " + std::to_string(static_cast<int>(emit_doc)) + ", \n";
            this->get_all_flags +=
                "    release: " + std::to_string(static_cast<int>(release)) + ", \n";
            this->get_all_flags += "    debug: " + std::to_string(static_cast<int>(debug)) + ", \n";
            this->get_all_flags += "    lib: " + std::to_string(static_cast<int>(lib)) + ", \n";
            this->get_all_flags +=
                "    python abi: " + std::to_string(static_cast<int>(python_abi)) + ", \n";
            this->get_all_flags +=
                "    rust abi: " + std::to_string(static_cast<int>(rust_abi)) + ", \n";
            this->get_all_flags +=
                "    cxx abi: " + std::to_string(static_cast<int>(cxx_abi)) + ", \n";
            this->get_all_flags +=
                "    kairo abi: " + std::to_string(static_cast<int>(kairo_abi)) + ", \n";

            this->get_all_flags += "    config file: " + config_file.Get() + ", \n";
            this->get_all_flags += "    output file: " + output_file.Get() + ", \n";
            this->get_all_flags += "    toolchain target: " + toolchain_target.Get() + ", \n";
            this->get_all_flags += "    toolchain arch: " + toolchain_arch.Get() + ", \n";
            this->get_all_flags += "    toolchain cpu: " + toolchain_cpu.Get() + ", \n";
            this->get_all_flags += "    toolchain sdk: " + toolchain_sdk.Get() + ", \n";

            this->get_all_flags +=
                "    include dir: [" + std::string(!include_dirs.Get().empty() ? "\n" : " ");
            ;
            for (auto &dir : include_dirs.Get()) {
                this->get_all_flags += dir + ", \n    ";
            }

            this->get_all_flags += "    ], \n";
            this->get_all_flags +=
                "    library dir: [" + std::string(!library_dirs.Get().empty() ? "\n" : " ");
            for (auto &dir : library_dirs.Get()) {
                this->get_all_flags += dir + ", \n    ";
            }

            this->get_all_flags += "    ], \n";
            this->get_all_flags +=
                "    link libraries: [" + std::string(!link_libraries.Get().empty() ? "\n" : " ");
            for (auto &lib : link_libraries.Get()) {
                this->get_all_flags += lib + ", \n    ";
            }

            this->get_all_flags += "    ], \n";
            this->get_all_flags +=
                "    module dir: [" + std::string(!module_dirs.Get().empty() ? "\n" : " ");
            for (auto &mod : module_dirs.Get()) {
                this->get_all_flags += mod + ", \n    ";
            }

            this->get_all_flags += "    ]";

        } catch (args::Help) { print(parser); } catch (args::ParseError &e) {
            print_err(e.what(), "\n", parser);
            this->exit_   = true;
            this->exit_co = 1;
            return;
        } catch (args::ValidationError &e) {
            print_err(e.what(), "\n", parser);
            this->exit_   = true;
            this->exit_co = 1;
            return;
        }
    }
}  // end __CONTROLLER_CLI_BEGIN