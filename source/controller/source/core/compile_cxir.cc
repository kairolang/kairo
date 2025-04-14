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

#include "controller/include/config/cxx_flags.hh"
#include "controller/include/shared/eflags.hh"
#include "controller/include/shared/logger.hh"
#include "controller/include/tooling/tooling.hh"
#include "neo-panic/include/error.hh"
#include "parser/preprocessor/include/preprocessor.hh"

#ifndef DEBUG_LOG
#define DEBUG_LOG(...)                            \
    if (is_verbose) {                             \
        helix::log<LogLevel::Debug>(__VA_ARGS__); \
    }
#endif

void CXIRCompiler::compile_CXIR(CXXCompileAction &&action, bool dry_run) const {
    this->dry_run = dry_run;
    CompileResult ret;
#if defined(_WIN32) || defined(WIN32) || defined(_WIN64) || defined(WIN64)
    // try compiling with msvc first
    if (action.cxx_compiler.empty()) {
        try {
            ret = CXIR_MSVC(action);

            if (ret.second.contains(flag::types::ErrorType::NotFound)) {
                // try compiling with clang
                action.cxx_compiler = "c++";
                ret                 = CXIR_CXX(action);
            }
        } catch (...) {
            if (error::HAS_ERRORED) {
                return;
            }

            error::HAS_ERRORED = true;
            helix::log<LogLevel::Error>("failed to compile using msvc or clang");
        }
    } else {
        ret = CXIR_CXX(action);
    }

    action.cleanup();
    return;
#else
    ret = CXIR_CXX(action);
#endif
}

CXIRCompiler::CompileResult CXIRCompiler::CXIR_CXX(const CXXCompileAction &action) const {
    /// identify the compiler
    ExecResult            compile_result = exec(action.cxx_compiler + " --version");
    flag::types::Compiler compiler       = flag::types::Compiler::Custom;
    bool is_verbose = action.flags.contains(EFlags(flag::types::CompileFlags::Verbose));

    if (compile_result.return_code != 0) {
        helix::log<LogLevel::Error>("failed to identify the compiler");
        return {compile_result, flag::ErrorType(flag::types::ErrorType::NotFound)};
    }

    if (compile_result.output.find("clang") != std::string::npos) {
        compiler = flag::types::Compiler::Clang;
    } else if (compile_result.output.find("gcc") != std::string::npos) {
        compiler = flag::types::Compiler::GCC;
    } else if (compile_result.output.find("msvc") != std::string::npos) {
        compiler = flag::types::Compiler::MSVC;
    } else if (compile_result.output.find("mingw") != std::string::npos) {
        compiler = flag::types::Compiler::MingW;
    }

    std::string compile_cmd = action.cxx_compiler + " ";

    // get the path to the core lib
    auto core = __CONTROLLER_FS_N::get_exe().parent_path().parent_path() / "core" / "include" / "core.hh";
    auto core_lib_dir = __CONTROLLER_FS_N::get_exe().parent_path().parent_path() / "lib";

    if (!std::filesystem::exists(core)) {
        helix::log<LogLevel::Error>("core lib not found, verify the installation");
        return {compile_result, flag::ErrorType(flag::types::ErrorType::NotFound)};
    }

    /// start with flags we know are going to be present
    compile_cmd += make_command(  // ...
        compiler,

        // cxx::flags::noDefaultLibrariesFlag,
        // cxx::flags::noCXXSTDLibrariesFlag,
        // cxx::flags::noCXXSTDIncludesFlag,
        // cxx::flags::noBuiltinIncludesFlag,
        // FIXME: add these later

        "-include \"" + core.generic_string() + "\" ",
        
        // cxx::flags::linkPathFlag,
        // core_lib_dir.generic_string(),

        // cxx::flags::linkFlag,
        // "helix",

        cxx::flags::includeFlag,
        core.parent_path().parent_path().generic_string(),

        ((action.flags.contains(flag::types::CompileFlags::Debug))
             ? cxx::flags::debugModeFlag
             : cxx::flags::optimizationLevel3),

        "-rdynamic",

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
        cxx::flags::linkTimeOptimizationFlag,

        ((action.flags.contains(flag::types::CompileFlags::Debug))
             ? cxx::flags::SanitizeFlag
             : cxx::flags::None),

// #if defined(__unix__) || defined(__APPLE__) || defined(__linux__) || defined(__FreeBSD__) ||      \
//     defined(__NetBSD__) || defined(__OpenBSD__) || defined(__bsdi__) || defined(__DragonFly__) || \
//     defined(__MACH__)
//         "-Wl,-w,-rpath,/usr/local/lib",
// #endif
        cxx::flags::warnAllFlag,
        cxx::flags::outputFlag,
        "\"" + action.cc_output.generic_string() + "\""  // output
    );

    if (this->dry_run) {
        compile_cmd += std::string(cxx::flags::dryRunFlag.clang) + " ";
    }

    // add all the import paths:
    if (!COMPILE_ACTIONS.empty()) {
        for (auto &action : COMPILE_ACTIONS) {
            compile_cmd += "\"" + action.cc_source.generic_string() + "\" ";
        }
    }

    /// add any additional flags passed into the action
    for (const auto &flag : action.cxx_args) {
        compile_cmd += flag + " ";
    }

    /// add the source file in a normalized path format
    compile_cmd += "\"" + action.cc_source.generic_string() + "\"";

    /// redirect stderr to stdout
    compile_cmd += " 2>&1";

    /// execute the command
    compile_result = exec(compile_cmd);

    if (is_verbose) {
        helix::log<LogLevel::Debug>("compile command: " + compile_cmd);
        helix::log<LogLevel::Debug>("compiler output:\n" + compile_result.output);
    }

    /// parse the output and show errors after translating them to helix errors
    std::vector<std::string> lines;
    std::istringstream       stream(compile_result.output);

    DEBUG_LOG("parsing compiler output intrinsics");

    for (std::string line; std::getline(stream, line);) {
        if (line.starts_with('/')) {
            lines.push_back(line);
        }
    }

    DEBUG_LOG("parsing compiler output, size: " + std::to_string(lines.size()));

    for (auto &line : lines) {
        ErrorPOFNormalized err;

        if (compiler == flag::types::Compiler::Clang) {
            err = CXIRCompiler::parse_clang_err(line);
        } else if (compiler == flag::types::Compiler::GCC) {
            err = CXIRCompiler::parse_gcc_err(line);
        } else if (compiler == flag::types::Compiler::MSVC) {
            err = CXIRCompiler::parse_msvc_err(line);
        } else {
            helix::log<LogLevel::Error>("unknown c++ compiler, raw output shown");
            helix::log<LogLevel::Info>("output ------------>");
            helix::log<LogLevel::Info>(compile_result.output);
            helix::log<LogLevel::Info>("<------------ output");

            if (compile_result.return_code == 0) {
                helix::log_opt<LogLevel::Progress>(action.flags.contains(flag::types::CompileFlags::Verbose), "lowered " + action.helix_src.generic_string() +
                                               " and compiled cxir");
                helix::log_opt<LogLevel::Progress>(action.flags.contains(flag::types::CompileFlags::Verbose), "compiled successfully to " +
                                               action.cc_output.generic_string());
                return {compile_result, flag::ErrorType(flag::types::ErrorType::Success)};
            }

            return {compile_result, flag::ErrorType(flag::types::ErrorType::Error)};
        }

        if (!std::filesystem::exists(std::get<2>(err))) {
            error::Panic _(error::CompilerError{
                .err_code     = 0.8245,
                .err_fmt_args = {"error at: " + std::get<2>(err) + std::get<1>(err)},
            });

            continue;
        }

        std::pair<size_t, size_t> err_t = {std::get<1>(err).find_first_not_of(' '),
                                           std::get<1>(err).find(':') -
                                               std::get<1>(err).find_first_not_of(' ')};

        error::Level level = std::map<string, error::Level>{
            {"error", error::Level::ERR},                       //
            {"warning", error::Level::WARN},                    //
            {"note", error::Level::NOTE}                        //
        }[std::get<1>(err).substr(err_t.first, err_t.second)];  //

        std::string msg = std::get<1>(err).substr(err_t.first + err_t.second + 1);

        msg = msg.substr(msg.find_first_not_of(' '));

        DEBUG_LOG("showing error: " + msg);
        error::Panic(error::CodeError{
            .pof          = &std::get<0>(err),
            .err_code     = 0.8245,
            .mark_pof     = true,
            .err_fmt_args = {msg},
            .level        = level,
            .indent       = static_cast<size_t>((level == error::NOTE) ? 1 : 0),
        });
        DEBUG_LOG("error shown");
    }

    if (compile_result.return_code == 0) {
        helix::log_opt<LogLevel::Progress>(action.flags.contains(flag::types::CompileFlags::Verbose), "lowered " + action.helix_src.generic_string() +
                                       " and compiled cxir");
        helix::log_opt<LogLevel::Progress>(action.flags.contains(flag::types::CompileFlags::Verbose), "compiled successfully to " +
                                       action.cc_output.generic_string());
        return {compile_result, flag::ErrorType(flag::types::ErrorType::Success)};
    }

    DEBUG_LOG("returning error");
    return {compile_result,
            flag::ErrorType(error::HAS_ERRORED ? flag::types::ErrorType::Error
                                               : flag::types::ErrorType::Success)};
}
