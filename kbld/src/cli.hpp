#pragma once

#include <stdexcept>

#include "types.hpp"

namespace kbld {

inline auto parse_cli(int argc, char *argv[]) -> CLIOptions {
    CLIOptions opts;

    if (argc < 2) {
        return opts;
    }

    int i = 1;

    std::string_view first = argv[1];
    if (first == "build") {
        opts.command = Command::Build;
        ++i;
    } else if (first == "clean") {
        opts.command = Command::Clean;
        ++i;
    } else if (first == "test") {
        opts.command = Command::Test;
        ++i;
    } else if (first == "deps") {
        opts.command = Command::Deps;
        ++i;
    } else if (first == "index") {
        opts.command = Command::Index;
        ++i;
    } else if (first == "install") {
        opts.command = Command::Install;
        ++i;
    } else if (first == "line") {
        opts.command = Command::Line;
        ++i;
    } else if (first.starts_with("-")) {
        // no command, just options
    } else {
        // nothing matches, treat as positional for default command
    }

    for (; i < argc; ++i) {
        std::string_view arg = argv[i];

        if (arg == "--debug") {
            opts.mode_override = BuildMode::Debug;
        } else if (arg == "--release") {
            opts.mode_override = BuildMode::Release;
        } else if (arg == "--verbose") {
            opts.verbose = true;
        } else if (arg == "--dry-run") {
            opts.dry_run = true;
        } else if (arg == "--emit-ir") {
            opts.emit_ir = true;
        } else if (arg == "--emit-ast") {
            opts.emit_ast = true;
        } else if (arg == "--keep-going") {
            opts.keep_going = true;
        } else if (arg == "--perf") {
            opts.perf = true;
        } else if (arg == "--compile-only") {
            opts.compile_only = true;
        } else if (arg == "--jobs") {
            if (++i >= argc)
                throw std::runtime_error("--jobs requires a value");
            opts.jobs = std::atoi(argv[i]);
            if (opts.jobs <= 0)
                throw std::runtime_error("--jobs must be positive");
        } else if (arg.starts_with("--jobs=")) {
            opts.jobs = std::atoi(std::string(arg.substr(7)).c_str());
        } else if (arg.starts_with("-j")) {
            opts.jobs = std::atoi(std::string(arg.substr(2)).c_str());
        } else if (arg == "--help" || arg == "-h") {
            std::fputs("kbld — Build tool for Kairo projects\n"
                       "\n"
                       "Usage: kbld [command] [options]\n"
                       "\n"
                       "Commands:\n"
                       "  build  [targets...]    Build all or specified targets "
                       "(default)\n"
                       "  clean  [targets...]    Remove build artifacts\n"
                       "  test   <file.kro>      Compile and run a test file\n"
                       "  deps   <file.kro>      Print dependency tree for a file\n"
                       "  index                  Regenerate compile_commands.json "
                       "only\n"
                       "  install [prefix]       Copy binaries to prefix/bin\n"
                       "  line   <file.kro> [s:e] Extract IR lines for a file\n"
                       "\n"
                       "Options:\n"
                       "  --debug                Force debug mode\n"
                       "  --release              Force release mode\n"
                       "  --verbose              Verbose output\n"
                       "  --jobs <n>             Max parallel jobs\n"
                       "  --dry-run              Print commands, don't execute\n"
                       "  --emit-ir              Pass --emit-ir to kairo\n"
                       "  --emit-ast             Pass --emit-ast to kairo\n"
                       "  --keep-going           Don't stop on first failure\n"
                       "  --perf                 (test) compile in release mode\n"
                       "  --compile-only         (test) compile but don't run\n",
                       stdout);
            std::exit(0);
        } else if (!arg.starts_with("-")) {
            opts.positional.emplace_back(arg);
        } else {
            log::warn(fmt("Unknown option: {}", std::string(arg)));
        }
    }

    if (opts.command == Command::Line && opts.positional.size() >= 2) {
        auto &last = opts.positional.back();
        if (last.find(':') != std::string::npos ||
            (last.find('-') != std::string::npos && !last.starts_with("-") &&
             !last.starts_with("/"))) {
            opts.line_range = last;
            opts.positional.pop_back();
        }
    }

    if (opts.command == Command::Install && !opts.positional.empty()) {
        opts.install_prefix = opts.positional[0];
        opts.positional.clear();
    }

    return opts;
}

}  // namespace kbld
