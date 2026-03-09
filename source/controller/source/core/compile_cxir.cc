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
///   SPDX-License-Identifier: CC-BY-4.0                                                         ///
///   Copyright (c) 2024 The Kairo Project (CC BY 4.0)                                           ///
///                                                                                              ///
///-------------------------------------------------------------------------------------- C++ ---///

#include "controller/include/config/cxx_flags.hh"
#include "controller/include/shared/eflags.hh"
#include "controller/include/shared/logger.hh"
#include "controller/include/tooling/tooling.hh"
#include "neo-panic/include/error.hh"
#include "parser/preprocessor/include/preprocessor.hh"
#include "parser/preprocessor/include/private/utils.hh"


#ifndef DEBUG_LOG
#define DEBUG_LOG(...)                            \
    if (is_verbose) {                             \
        kairo::log<LogLevel::Debug>(__VA_ARGS__); \
    }
#endif

// ---------------------------------------------------------------------------
// Linker error parsing
// ---------------------------------------------------------------------------

namespace {

enum class LinkerFormat {
    LLD,
    MSVCLink,   // clang-cl / MSVC link.exe: emits LNK#### codes
    GNULd,
    Unknown
};

struct LinkerDiag {
    std::string message;
    std::string file;       // may be empty for pure linker errors
    size_t      line = 0;
    error::Level level = error::Level::ERR;
};

inline LinkerFormat detect_linker_format(const std::string &output) {
    if (output.find("lld-link:")         != std::string::npos) return LinkerFormat::LLD;
    if (output.find("ld.lld:")           != std::string::npos) return LinkerFormat::LLD;
    if (output.find("LNK")              != std::string::npos) return LinkerFormat::MSVCLink; // add this
    if (output.find("ld:")               != std::string::npos) return LinkerFormat::GNULd;
    if (output.find("collect2:")         != std::string::npos) return LinkerFormat::GNULd;
    if (output.find("undefined reference")!= std::string::npos) return LinkerFormat::GNULd;
    return LinkerFormat::Unknown;
}

/// Strips MSVC mangled name noise if present — just demangles the first
/// symbol found in the message for readability.
inline std::string clean_linker_message(const std::string &msg) {
#if defined(_WIN32) || defined(_WIN64)
    // attempt partial demangle if it looks mangled (?foo@bar...)
    if (!msg.empty() && msg.find('$') != std::string::npos) {
        return helix::abi::demangle_partial(msg);
    }
#endif
    return msg;
}

std::vector<LinkerDiag> parse_msvc_link_errors(const std::string &output) {
    std::vector<LinkerDiag> diags;
    std::istringstream      stream(output);
    std::string             line;

    while (std::getline(stream, line)) {
        // skip the clang-cl summary line — the real errors are the LNK#### lines
        if (line.find("linker command failed") != std::string::npos) continue;

        // format: <file> : error LNK####: <message>
        // format: <file> : fatal error LNK####: <message>
        auto lnk_pos = line.find("LNK");
        if (lnk_pos == std::string::npos) continue;

        // find the colon after LNK####
        auto colon_after_code = line.find(':', lnk_pos);
        if (colon_after_code == std::string::npos) continue;

        std::string msg = line.substr(colon_after_code + 1);
        if (!msg.empty() && msg[0] == ' ') msg = msg.substr(1);

        // determine severity from what precedes LNK
        // "fatal error LNK" → ERR, "error LNK" → ERR, "warning LNK" → WARN
        error::Level level = error::Level::ERR;
        if (line.find("warning LNK") != std::string::npos)
            level = error::Level::WARN;

        // extract LNK code for context e.g. LNK2019
        std::string lnk_code;
        size_t code_end = lnk_pos + 3; // skip "LNK"
        while (code_end < line.size() && std::isdigit((unsigned char)line[code_end]))
            ++code_end;
        lnk_code = line.substr(lnk_pos, code_end - lnk_pos);

        // demangle if it contains a mangled symbol (starts with '?')
        auto q_pos = msg.find('?');
        if (q_pos != std::string::npos) {
            // extract just the mangled portion (up to next space or closing paren)
            auto sym_end = msg.find_first_of(" )", q_pos);
            std::string mangled = msg.substr(q_pos, sym_end - q_pos);
            std::string demangled = helix::abi::demangle_partial(mangled);
            msg = msg.substr(0, q_pos) + demangled +
                  (sym_end != std::string::npos ? msg.substr(sym_end) : "");
        }

        diags.push_back({"[" + lnk_code + "] " + clean_linker_message(msg), "", 0, level});
    }

    return diags;
}

std::vector<LinkerDiag> parse_lld_errors(const std::string &output) {
    std::vector<LinkerDiag> diags;
    std::istringstream      stream(output);
    std::string             line;

    while (std::getline(stream, line)) {
        // lld-link: error: ...
        // ld.lld: error: ...
        // lld-link: warning: ...
        auto lld_link = line.find("lld-link:");
        auto ld_lld   = line.find("ld.lld:");
        size_t prefix_end = std::string::npos;

        if (lld_link != std::string::npos)
            prefix_end = lld_link + 9; // len("lld-link:")
        else if (ld_lld != std::string::npos)
            prefix_end = ld_lld + 7;   // len("ld.lld:")

        if (prefix_end == std::string::npos) continue;

        // skip whitespace
        size_t sev_start = line.find_first_not_of(' ', prefix_end);
        if (sev_start == std::string::npos) continue;

        size_t colon = line.find(':', sev_start);
        if (colon == std::string::npos) continue;

        std::string severity = line.substr(sev_start, colon - sev_start);
        std::string msg      = line.substr(colon + 1);
        if (!msg.empty() && msg[0] == ' ') msg = msg.substr(1);

        error::Level level;
        if      (severity == "error")   level = error::Level::ERR;
        else if (severity == "warning") level = error::Level::WARN;
        else continue; // skip notes/trace lines

        diags.push_back({clean_linker_message(msg), "", 0, level});
    }

    return diags;
}

std::vector<LinkerDiag> parse_gnu_ld_errors(const std::string &output) {
    std::vector<LinkerDiag> diags;
    std::istringstream      stream(output);
    std::string             line;

    // GNU ld format examples:
    //   /path/foo.o: in function `bar':
    //   src/foo.cc:42: undefined reference to `baz'
    //   collect2: error: ld returned 1 exit status

    while (std::getline(stream, line)) {
        // skip collect2 summary line — we already have the real errors
        if (line.find("collect2:") != std::string::npos) continue;

        // look for "undefined reference to" pattern
        auto undef = line.find("undefined reference to");
        if (undef != std::string::npos) {
            // try to extract file:line prefix
            std::string file;
            size_t      lineno = 0;

            // format: /path/file.cc:42: undefined reference to `sym'
            // or:     foo.o:(.text+0x0): undefined reference to `sym'
            auto first_colon = line.find(':');
            if (first_colon != std::string::npos) {
                std::string prefix = line.substr(0, first_colon);
                // check if next chars are digits (line number)
                size_t second_colon = line.find(':', first_colon + 1);
                if (second_colon != std::string::npos) {
                    std::string between = line.substr(first_colon + 1, second_colon - first_colon - 1);
                    bool all_digits = !between.empty() &&
                        std::all_of(between.begin(), between.end(), ::isdigit);
                    if (all_digits) {
                        file   = prefix;
                        lineno = std::stoul(between);
                    }
                }
            }

            std::string msg = line.substr(undef);
            diags.push_back({clean_linker_message(msg), file, lineno, error::Level::ERR});
            continue;
        }

        // "error:" prefix lines from ld directly
        auto err_pos = line.find("error:");
        if (err_pos != std::string::npos) {
            std::string msg = line.substr(err_pos + 6);
            if (!msg.empty() && msg[0] == ' ') msg = msg.substr(1);
            if (msg.find("ld returned") != std::string::npos) continue; // skip summary
            diags.push_back({clean_linker_message(msg), "", 0, error::Level::ERR});
        }
    }

    return diags;
}

std::vector<LinkerDiag> parse_linker_errors(const std::string &output) {
    LinkerFormat fmt = detect_linker_format(output);
    switch (fmt) {
        case LinkerFormat::LLD:      return parse_lld_errors(output);
        case LinkerFormat::MSVCLink: return parse_msvc_link_errors(output);
        case LinkerFormat::GNULd:    return parse_gnu_ld_errors(output);
        default:                     return {};
    }
}
}

namespace {
inline std::string find_clang_cl_windows(bool is_verbose) {
    // 1. check PATH first — if the user has LLVM installed standalone it'll be there
    CXIRCompiler::ExecResult probe = CXIRCompiler::exec("clang-cl --version");
    if (probe.return_code == 0) return "clang-cl";

    // 2. check standalone LLVM install location
    constexpr std::string_view standalone = "C:/Program Files/LLVM/bin/clang-cl.exe";
    if (std::filesystem::exists(standalone)) return std::string(standalone);

    // 3. locate via vswhere — clang-cl bundled with VS
    constexpr std::string_view vswhere_path =
        "C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe";

    if (!std::filesystem::exists(vswhere_path)) {
        kairo::log<LogLevel::Warning>(
            "vswhere not found — cannot locate clang-cl bundled with Visual Studio");
        return "";
    }

    std::string vswhere_cmd =
        "\"" + std::string(vswhere_path) + "\""
        " -latest -products *"
        " -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64"
        " -property installationPath";

    CXIRCompiler::ExecResult vs = CXIRCompiler::exec(vswhere_cmd);

    // vswhere returns empty output (not non-zero) when nothing is found on VS 2026
    if (vs.output.empty()) {
        // fallback: hardcoded known VS 2026 BuildTools path
        constexpr std::string_view fallback_vs =
            "C:/Program Files (x86)/Microsoft Visual Studio/18/BuildTools";
        if (std::filesystem::exists(fallback_vs)) {
            vs.output    = std::string(fallback_vs);
            vs.return_code = 0;
        } else {
            kairo::log<LogLevel::Warning>(
                "vswhere returned no results and fallback VS path not found");
            return "";
        }
    }

    // trim whitespace
    std::string vs_path = vs.output;
    vs_path.erase(vs_path.find_last_not_of(" \n\r\t") + 1);

    // clang-cl bundled with VS lives here
    auto clang_cl = std::filesystem::path(vs_path) / "VC" / "Tools" / "Llvm" / "x64" / "bin" / "clang-cl.exe";
    if (std::filesystem::exists(clang_cl)) {
        return clang_cl.generic_string();
    }

    // some VS installs put it at the non-x64 path
    auto clang_cl_noarch = std::filesystem::path(vs_path) / "VC" / "Tools" / "Llvm" / "bin" / "clang-cl.exe";
    if (std::filesystem::exists(clang_cl_noarch)) {
        return clang_cl_noarch.generic_string();
    }

    kairo::log<LogLevel::Warning>(
        "clang-cl not found in VS install at: " + vs_path
        + "\nInstall the 'C++ Clang tools for Windows' component in the VS installer");
    return "";
}

/// Returns true if the line looks like a compiler diagnostic with an absolute
/// path prefix, handling both POSIX (/foo/bar) and Windows (C:\foo, Z:/foo).
inline bool is_diagnostic_line(const std::string &line) {
    if (line.empty()) return false;
    if (line[0] == '/') return true;                          // POSIX absolute path
    if (line.size() >= 2 && std::isalpha(line[0]) && line[1] == ':') return true; // Windows drive
    return false;
}

/// Resolve the compiler to use.
/// On Windows we prefer clang-cl; on all other platforms we use whatever
/// cxx_compiler is set to (defaulting to "c++" which resolves to clang/gcc).
inline std::string resolve_compiler(const std::string &requested, bool is_verbose) {
    if (!requested.empty()) return requested;
#if defined(_WIN32) || defined(_WIN64)
    std::string found = find_clang_cl_windows(is_verbose);
    if (found.empty()) {
        kairo::log<LogLevel::Error>(
            "could not locate clang-cl. Either:\n"
            "  1. Install LLVM standalone: https://releases.llvm.org\n"
            "  2. In the VS installer, add 'C++ Clang tools for Windows'\n"
            "  3. Run kairo from a Developer Command Prompt");
        return "";
    }
    return found;
#else
    return "c++";
#endif
}

/// Identify the compiler family from its --version output.
inline flag::types::Compiler identify_compiler(const std::string &version_output) {
    if (version_output.find("clang") != std::string::npos) return flag::types::Compiler::Clang;
    if (version_output.find("GCC")   != std::string::npos) return flag::types::Compiler::GCC;
    if (version_output.find("msvc")  != std::string::npos) return flag::types::Compiler::MSVC;
    if (version_output.find("mingw") != std::string::npos) return flag::types::Compiler::MingW;
    return flag::types::Compiler::Custom;
}

} // namespace

CXIRCompiler::CompileResult
CXIRCompiler::compile_CXIR(CXXCompileAction &&action, bool dry_run) const {
    bool is_verbose = action.flags.contains(EFlags(flag::types::CompileFlags::Verbose));

    this->dry_run = dry_run;
    CompileResult ret;

    action.cxx_compiler = resolve_compiler(action.cxx_compiler, is_verbose);
    if (action.cxx_compiler.empty()) {
        error::HAS_ERRORED = true;
        return {};
    }

    try {
        ret = CXIR_CXX(action);
    } catch (...) {
        if (!error::HAS_ERRORED) {
            error::HAS_ERRORED = true;
            kairo::log<LogLevel::Error>("failed to compile: unhandled exception in compilation pipeline");
        }
        return {};
    }

    action.cleanup();
    return ret;
}

CXIRCompiler::CompileResult
CXIRCompiler::CXIR_CXX(const CXXCompileAction &action) const {
    bool is_verbose = action.flags.contains(EFlags(flag::types::CompileFlags::Verbose));

    ExecResult probe = exec(action.cxx_compiler + " --version");
    if (probe.return_code != 0) {
        kairo::log<LogLevel::Error>(
            "compiler not found or failed to execute: '" + action.cxx_compiler + "'"
#if defined(_WIN32) || defined(_WIN64)
            " — install LLVM from https://releases.llvm.org and ensure clang-cl is on PATH"
#endif
        );
        return {probe, flag::ErrorType(flag::types::ErrorType::NotFound)};
    }

    flag::types::Compiler compiler = identify_compiler(probe.output);
    DEBUG_LOG("identified compiler: " + probe.output.substr(0, probe.output.find('\n')));

    auto core = __CONTROLLER_FS_N::get_exe()
                    .parent_path()
                    .parent_path() / "core" / "include" / "core.hh";

    if (!std::filesystem::exists(core)) {
        kairo::log<LogLevel::Error>("core lib not found, verify the installation");
        return {probe, flag::ErrorType(flag::types::ErrorType::NotFound)};
    }

    std::string compile_cmd = action.cxx_compiler + " ";

    // Platform-specific flag adjustments:
    //   - clang-cl (Windows): no -rdynamic, no -flto, no stdLibAndLinks,
    //     links CRT automatically, accepts clang-style -include / -I.
    //   - clang / GCC (POSIX): full flag set.
    const bool is_windows_clang_cl =
#if defined(_WIN32) || defined(_WIN64)
        (action.cxx_compiler.find("clang-cl") != std::string::npos);
#else
        false;
#endif

    if (is_windows_clang_cl) {
        compile_cmd += make_command(
            compiler,

            // force-include core — clang-cl uses /FI with no space before the path
            "/FI\"" + core.generic_string() + "\"",

            // include search path
            "/I\"" + core.parent_path().parent_path().generic_string() + "\"",

            // optimization / debug
            ((action.flags.contains(flag::types::CompileFlags::Debug)) ? "/Od /RTC1" : "/O2"),

            // compile-only if library target
            ((action.flags.contains(flag::types::CompileFlags::Library)) ? "/c" : ""),

            // C++ standard and exceptions
            "/std:c++latest",
            "/EHsc",

            // diagnostics
            "/FC",        // full path in diagnostics
            "/nologo",
            "/W4",

            // suppress CRT noise
            "/D_CRT_SECURE_NO_WARNINGS",
            "/D_SILENCE_ALL_CXX17_DEPRECATION_WARNINGS",

            // asan if debug
            ((action.flags.contains(flag::types::CompileFlags::Debug))
                ? "/fsanitize=address" : ""),

            // output
            "/Fe\"" + action.cc_output.generic_string() + "\""
        );
    } else {
        compile_cmd += make_command(
            compiler,

            "-include \"" + core.generic_string() + "\" ",

            cxx::flags::includeFlag,
            core.parent_path().parent_path().generic_string(),

            ((action.flags.contains(flag::types::CompileFlags::Debug))
                ? cxx::flags::debugModeFlag
                : cxx::flags::optimizationLevel3),

            ((action.flags.contains(flag::types::CompileFlags::Library))
                ? cxx::flags::compileOnlyFlag
                : cxx::flags::None),

            cxx::flags::cxxStandardFlag,
            cxx::flags::stdCXX23Flag,
            cxx::flags::enableExceptionsFlag,
            cxx::flags::noOmitFramePointerFlag,
            cxx::flags::noColorDiagnosticsFlag,
            cxx::flags::noDiagnosticsFixitFlag,
            cxx::flags::fullFilePathFlag,
            cxx::flags::noDiagnosticsShowLineNumbersFlag,
            cxx::flags::noDiagnosticsShowOptionFlag,
            cxx::flags::caretDiagnosticsMaxLinesFlag,
            cxx::flags::noElideTypeFlag,

            // POSIX-only flags
            (is_windows_clang_cl ? "" : "-rdynamic"),
            (is_windows_clang_cl ? cxx::flags::None : cxx::flags::linkTimeOptimizationFlag),
            (is_windows_clang_cl ? cxx::flags::None : cxx::flags::stdLibAndLinks),

            // Windows: suppress CRT warnings, clang-cl links CRT automatically
            "-D_CRT_SECURE_NO_WARNINGS",
            "-D_SILENCE_ALL_CXX17_DEPRECATION_WARNINGS",

            ((action.flags.contains(flag::types::CompileFlags::Debug))
                ? cxx::flags::SanitizeFlag
                : cxx::flags::None),

            cxx::flags::warnAllFlag,
            cxx::flags::outputFlag,
            "\"" + action.cc_output.generic_string() + "\""
        );
    }

    if (this->dry_run) {
        compile_cmd += std::string(cxx::flags::dryRunFlag.clang) + " ";
    }

    // additional translation units (batch compiles)
    if (!COMPILE_ACTIONS.empty()) {
        for (auto &a : COMPILE_ACTIONS) {
            compile_cmd += "\"" + a.cc_source.generic_string() + "\" ";
        }
    }

    // caller-supplied extra flags
    for (const auto &flag : action.cxx_args) {
        compile_cmd += flag + " ";
    }

    // primary source file
    compile_cmd += "\"" + action.cc_source.generic_string() + "\"";

    // merge stderr into stdout so exec() captures everything
    compile_cmd += " 2>&1";

    DEBUG_LOG("compile command: " + compile_cmd);

    if (!std::filesystem::exists(action.cc_source)) {
        kairo::log<LogLevel::Error>(
            "source file does not exist, possible memory corruption: "
            + action.cc_source.generic_string());
        return {{}, flag::ErrorType(flag::types::ErrorType::Error)};
    }

    #if defined(_WIN32) || defined(_WIN64)
        // exec() on Windows doesn't go through a shell, so redirects need cmd /c
        std::string shell_cmd = "cmd.exe /c \"" + compile_cmd + " 2>&1\"";
        ExecResult compile_result = exec(shell_cmd);
    #else
        compile_cmd += " 2>&1";
        ExecResult compile_result = exec(compile_cmd);
    #endif
    DEBUG_LOG("compiler output:\n" + compile_result.output);

    std::vector<std::string> diag_lines;
    {
        std::istringstream stream(compile_result.output);
        for (std::string line; std::getline(stream, line);) {
            if (is_diagnostic_line(line)) {
                diag_lines.push_back(line);
            }
        }
    }

    DEBUG_LOG("diagnostic lines to parse: " + std::to_string(diag_lines.size()));

    for (auto &line : diag_lines) {
        ErrorPOFNormalized err;

        switch (compiler) {
            case flag::types::Compiler::Clang:  err = CXIRCompiler::parse_clang_err(line); break;
            case flag::types::Compiler::GCC:    err = CXIRCompiler::parse_gcc_err(line);   break;
            // clang-cl emits clang-format diagnostics, so parse_clang_err is correct
            default:
                kairo::log<LogLevel::Warning>(
                    "unknown compiler family, raw diagnostic: " + line);
                continue;
        }

        if (std::get<1>(err).empty() || std::get<2>(err).empty()) {
            DEBUG_LOG("skipping unparsed line: " + line);
            continue;
        }

        if (!std::filesystem::exists(std::get<2>(err))) {
            DEBUG_LOG("diagnostic references non-existent file (generated/temp): " + std::get<2>(err));
            continue;
        }

        // extract severity prefix: "error", "warning", "note"
        const std::string &raw_msg    = std::get<1>(err);
        size_t             first_char = raw_msg.find_first_not_of(' ');
        size_t             colon      = raw_msg.find(':', first_char);

        if (first_char == std::string::npos || colon == std::string::npos) {
            DEBUG_LOG("malformed diagnostic message: " + raw_msg);
            continue;
        }

        std::string  severity = raw_msg.substr(first_char, colon - first_char);
        std::string  msg      = raw_msg.substr(colon + 1);
        if (auto trim = msg.find_first_not_of(' '); trim != std::string::npos)
            msg = msg.substr(trim);

        error::Level level;
        if      (severity == "error")   level = error::Level::ERR;
        else if (severity == "warning") level = error::Level::WARN;
        else if (severity == "note")    level = LSP_MODE ? error::Level::WARN : error::Level::NOTE;
        else {
            DEBUG_LOG("unrecognised severity '" + severity + "', skipping");
            continue;
        }

        auto pof = std::get<0>(err);
        DEBUG_LOG("emitting diagnostic [" + severity + "]: " + msg);

        error::Panic(error::CodeError{
            .pof          = &pof,
            .err_code     = 0.8245,
            .mark_pof     = true,
            .fix_fmt_args = {},
            .err_fmt_args = {msg},
            .level        = level,
            .indent       = static_cast<size_t>((level == error::Level::NOTE) ? 1 : 0),
        });
    }

    {
        auto linker_diags = parse_linker_errors(compile_result.output);
        for (auto &ld : linker_diags) {
            error::Panic(error::CompilerError{
                .err_code     = 0.8245,
                .fix_fmt_args = {},
                .err_fmt_args = {"linker: " + ld.message},
            });
        }

        if (!linker_diags.empty()) {
            DEBUG_LOG("emitted " + std::to_string(linker_diags.size()) + " linker diagnostic(s)");
        }
    }

    if (compile_result.return_code == 0 && !error::HAS_ERRORED) {
        kairo::log_opt<LogLevel::Progress>(
            is_verbose,
            "lowered " + action.kairo_src.generic_string() + " and compiled cxir");
        kairo::log_opt<LogLevel::Progress>(
            is_verbose,
            "compiled successfully to " + action.cc_output.generic_string());
        return {compile_result, flag::ErrorType(flag::types::ErrorType::Success)};
    }

    return {compile_result,
            flag::ErrorType(error::HAS_ERRORED ? flag::types::ErrorType::Error
                                               : flag::types::ErrorType::Success)};
}