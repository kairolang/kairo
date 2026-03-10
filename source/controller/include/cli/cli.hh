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

#ifndef __CLI_2_H__
#define __CLI_2_H__

#include <array>
#include <cstddef>
#include <iostream>
#include <optional>
#include <string>

#include "controller/include/config/Controller_config.def"
#include "neo-pprint/include/hxpprint.hh"
#include "neo-types/include/hxint.hh"
#include "taywee-args/include/args.hh"

/*
Helios - package manager / build system

Usage:
    helios create <project>               Create a new Kairo project.
    helios build                          Build the current project.
    helios run [-r] -- <args>             Run the current project with optional arguments.
    helios test                           Run tests for the current project.
    helios clean                          Clean build artifacts.
    helios install <package>              Install a package.
    helios uninstall <package>            Uninstall a package.
    helios update                         Update all installed packages.
    helios search <package>               Search for a package.
    helios list                           List all installed packages.
    helios info <package>                 Show information about a specific package.
    helios help                           Show help information.
    helios version                        Show the version of Helios.
    helios license                        Show the license of Helios.
    helios doc-gen                        Generate documentation.
*/

/*
kairo - command line interface

Usage:
    kairo [options] <file> [options-2]
    kairo (-h | --help)
    kairo --version
    kairo --license

options:
    -O1 --optimize1          Optimization level 1.
    -O2 --optimize2          Optimization level 2.
    -O3 --optimize3          Optimization level 3.
    -O4 --optimize4          Optimization level 4.
    -O5 --optimize5          Optimization level 5.

    -h --help                Show this screen.
    -v --version             Show version.
    -l --license             Show license information.

    --verbose                Show verbose output.
    --quiet                  Show no output.
    --error                  Show only errors.

    --emit-tokens            Show tokens.
    --emit-llvm              Show LLVM IR.
    --emit-asm               Show assembly.
    --emit-ast               Show AST in json format
    --emit-ir                Show intermediate representation. (C++)
    --emit-doc               Only extract doc-comments along with signatures in json format.

    --toolchain <options-3>  Set the toolchain to use

    --config <file>          Specify configuration file.
    -r --release             Build in release mode.
    -d --debug               Build in debug mode with symbols.

options-2:
    --lib [abi-options]      Compile as library.
    -o <file>                Output file.
    -I <dir>                 Include directory.
    -L <dir>                 Library directory.
    -l <lib>                 Link library.
    -m <mod>                 Kairo Modules directory.

options-3:
    --target <triple>        Target triple.
    --arch   <arch>          Target architecture.
    --os     <os>            Target operating system.
    --sdk    <sdk-path>      Optional Path to a sdk.

abi-options:
    -py  --python        Python stub files gen and pylib compile
    -rs  --rust          Rust source files gen and a rust compiler lib
    -cxx --cxx           C++ header files gen and linkable object file
    -kro --kairo         Kairo ABI compatable libary
*/

__CONTROLLER_CLI_BEGIN {
    class CLIArgs {
      public:
        enum class OPTIMIZATION : u8 { O1 = 1, O2 = 2, O3 = 3, O4 = 4, O5 = 5 };
        enum class MODE : char { RELEASE = 'r', DEBUG_ = 'd' };
        enum class ABI : char { PYTHON = 'p', RUST = 'r', CXX = 'c', KAIRO = 'h' };

        std::string                file;
        std::optional<std::string> output_file;
        // Options
        OPTIMIZATION optimize;

        bool help    = false;
        bool verbose = false;
        bool quiet   = false;
        bool error   = false;
        bool exit_   = false;
        int  exit_co = 0;

        bool emit_tokens = false;
        bool emit_llvm   = false;
        bool lsp_mode    = false;
        bool emit_asm    = false;
        bool emit_ast    = false;
        bool emit_cst    = false;
        bool emit_ir     = false;
        bool emit_doc    = false;
        bool emit_deps   = false;

        struct tool_chain {
            std::string target;
            std::string arch;
            std::string cpu;
            std::string sdk;
        };

        tool_chain toolchain;

        std::string config_file;

        MODE build_mode;
        ABI  build_lib;  // if --lib is passed without [-py, -rs, -cx, -kro] then assume -kro

        std::vector<std::string> include_dirs;
        std::vector<std::string> library_dirs;
        std::vector<std::string> link_libraries;
        std::vector<std::string> module_dirs;

        std::vector<std::string> cxx_args;

        explicit CLIArgs(int argc, char **argv, const std::string &version);
        std::string get_all_flags;
    };

    inline void check_exit(CLIArgs & obj) {
        if (obj.exit_) {
            std::exit(obj.exit_co);
        }

        if (obj.file.empty()) {
            print("no files provided run \"kairo -h\" for help.");
            std::exit(0);
        }
    }
}  // end __CONTROLLER_CLI_BEGIN

#endif // __CLI_2_H__