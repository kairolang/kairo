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

#include <filesystem>

#include "controller/include/config/Controller_config.def"
#include "controller/include/config/cxx_flags.hh"
#include "controller/include/shared/eflags.hh"
#include "controller/include/shared/file_system.hh"
#include "controller/include/shared/logger.hh"
#include "controller/include/tooling/tooling.hh"
#include "parser/preprocessor/include/preprocessor.hh"
#include "token/include/config/Token_config.def"
#include "token/include/private/Token_list.hh"

#ifndef DEBUG_LOG
#define DEBUG_LOG(...)                            \
    if (is_verbose) {                             \
        helix::log<LogLevel::Debug>(__VA_ARGS__); \
    }
#endif

namespace CXIR {
    std::string strip(const std::string& str, const std::string& chars = " \t\n\r") {
        size_t start = str.find_first_not_of(chars);
        if (start == std::string::npos) {
            return "";
        }

        size_t end = str.find_last_not_of(chars);
        return str.substr(start, end - start + 1);
    }
}

CXIRCompiler::CompileResult CXIRCompiler::CXIR_MSVC(const CXXCompileAction &action) const {
    bool is_verbose       = action.flags.contains(EFlags(flag::types::CompileFlags::Verbose));
    bool vswhere_found    = false;
    bool msvc_found       = false;
    bool msvc_tools_found = false;

    ExecResult            compile_result;
    ExecResult            vs_result;
    std::filesystem::path msvc_tools_path;

    std::string vs_path;
    std::string compile_cmd;

    std::string where_vswhere =
        R"("C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe" )";

    std::string vswhere_cmd =
        where_vswhere +
        "-latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property "
        "installationPath";

    DEBUG_LOG("vswhere command: " + vswhere_cmd);
    vs_result = exec(vswhere_cmd);

    if (!std::filesystem::exists(
            "C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe")) {
        DEBUG_LOG("vswhere not found");
        return {vs_result, flag::ErrorType(flag::types::ErrorType::NotFound)};
    }

    if (vs_result.return_code != 0) {
        DEBUG_LOG("vswhere failed to execute: " + std::to_string(vs_result.return_code));
        DEBUG_LOG("vswhere output: " + vs_result.output);
        return {vs_result, flag::ErrorType(flag::types::ErrorType::NotFound)};
    }

    DEBUG_LOG("vswhere output: " + vs_result.output);
    vs_path = vs_result.output;
    vs_path.erase(vs_path.find_last_not_of(" \n\r\t") + 1);  // trim trailing whitespace

    DEBUG_LOG("vswhere path: " + vs_path);
    vswhere_found = vs_result.return_code == 0 && !vs_result.output.empty();
    msvc_found    = std::filesystem::exists(vs_path);

    if (!vswhere_found || !msvc_found) {
        helix::log<LogLevel::Warning>(
            "visual Studio not found attempting to find any other c++ compiler");
        return {vs_result, flag::ErrorType(flag::types::ErrorType::NotFound)};
    }

    msvc_tools_path =
        std::filesystem::path(vs_path) / "VC" / "Auxiliary" / "Build" / "vcvars64.bat";
    msvc_tools_found = std::filesystem::exists(msvc_tools_path);

    if (!msvc_tools_found) {
        helix::log<LogLevel::Warning>(
            "msvc tools not found attempting to find any other c++ compiler");
        return {vs_result, flag::ErrorType(flag::types::ErrorType::NotFound)};
    }

    DEBUG_LOG("msvc tools path: " + msvc_tools_path.generic_string());
    compile_cmd = "cmd.exe /c \"call \"" + msvc_tools_path.string() + "\" >nul 2>&1 && cl ";

    // get the path to the core lib
    auto core = __CONTROLLER_FS_N::get_exe().parent_path().parent_path() / "core" / "include" / "core.hh";
    // auto core_lib_dir = __CONTROLLER_FS_N::get_exe().parent_path().parent_path() / "lib";

    if (!std::filesystem::exists(core)) {
        helix::log<LogLevel::Error>("core lib not found, verify the installation");
        return {compile_result, flag::ErrorType(flag::types::ErrorType::NotFound)};
    }

    /// start with flags we know are going to be present
    compile_cmd += make_command(  // ...
        flag::types::Compiler::MSVC,

        "/FI\"" + core.generic_string() + "\" ",

        // cxx::flags::linkPathFlag,
        // core_lib_dir.generic_string(),

        // cxx::flags::linkFlag,
        // "helix",

        ((action.flags.contains(flag::types::CompileFlags::Debug))
             ? cxx::flags::debugModeFlag
             : cxx::flags::optimizationLevel3),

        cxx::flags::includeFlag,
        core.parent_path().parent_path().generic_string(),

        cxx::flags::cxxStandardFlag,
        cxx::flags::enableExceptionsFlag,

        "/nologo",
        "/Zc:__cplusplus",
        "-D__cpp_concepts=202002L",
        "/std:c++latest",

        ((action.flags.contains(flag::types::CompileFlags::Debug)) ? "/RTC1" : ""),
        cxx::flags::fullFilePathFlag,
        cxx::flags::noErrorReportingFlag,
        ((action.flags.contains(flag::types::CompileFlags::Debug))
             ? cxx::flags::SanitizeFlag
             : cxx::flags::None),

        // cxx::flags::noDefaultLibrariesFlag,
        // cxx::flags::noCXXSTDLibrariesFlag,
        // cxx::flags::noCXXSTDIncludesFlag,
        // cxx::flags::noBuiltinIncludesFlag,
        // FIXME: add these later
        // cxx::flags::linkTimeOptimizationFlag,
        cxx::flags::warnAllFlag,
        cxx::flags::outputFlag,
        "\"" + action.cc_output.generic_string() + "\""  // output
    );

    if (this->dry_run) {
        compile_cmd += std::string(cxx::flags::dryRunFlag.msvc) + " ";
    }

    /// add any additional flags passed into the action
    for (auto &flag : action.cxx_args) {
        compile_cmd += flag + " ";
    }

    if (!COMPILE_ACTIONS.empty()) {
        for (auto &action : COMPILE_ACTIONS) {
            compile_cmd += "\"" + action.cc_source.generic_string() + "\" ";
        }
    }

    /// add the source file in a normalized path format
    compile_cmd += "\"" + action.cc_source.generic_string() + "\"";

    DEBUG_LOG("compile command: " + compile_cmd);

    if (!std::filesystem::exists(action.cc_source)) {
        helix::log<LogLevel::Error>(
            "source file has been removed or does not exist, possible memory corruption");
        return {compile_result, flag::ErrorType(flag::types::ErrorType::Error)};
    }

    /// execute the command
    compile_result = exec(compile_cmd);

    DEBUG_LOG("compile command: " + compile_cmd);
    DEBUG_LOG("compiler output:\n" + compile_result.output);

    // if the compile outputted an obj file in the cwd remove it.
    std::filesystem::path obj_p =
        __CONTROLLER_N::file_system::get_cwd() / action.cc_source.filename();
    obj_p.replace_extension(".obj");

    if (std::filesystem::exists(obj_p)) {
        std::error_code ec_remove;
        std::filesystem::remove(obj_p, ec_remove);

        if (ec_remove) {
            helix::log<LogLevel::Warning>("failed to delete obj " + obj_p.generic_string() + ": " +
                                          ec_remove.message());
        }
    }

    /// parse the output and show errors after translating them to helix errors
    std::vector<std::string> lines;
    std::istringstream       stream(compile_result.output);

    DEBUG_LOG("parsing compiler output");
    for (std::string line; std::getline(stream, line);) {
        lines.push_back(line);
    }

    DEBUG_LOG("parsing output");
    for (auto & line : lines) {
        ErrorPOFNormalized err = CXIRCompiler::parse_msvc_err(line);
        
        DEBUG_LOG("parsed error: ", std::get<1>(err));
        if (std::get<0>(err).token_kind() == __TOKEN_N::WHITESPACE) {
            continue;
        }

        if (std::get<1>(err).empty() || std::get<2>(err).empty()) {
            continue;
        }

        if (!std::filesystem::exists(std::get<2>(err))) {
            if (std::get<2>(err).empty()) {
                continue;
            }

            continue;
            
            DEBUG_LOG("file not found (this is a bug)");
            // FIXME: for some fucking reason this causes some sort of memory corruption
            //        and caused the compiler to exit prematurely with a exit code of 0
            //        this is a temporary fix until I can figure out what is causing it
            //        to crash, this shit took 3 fucking hours of debugging to figure out.
            error::Panic _(error::CompilerError{
                .err_code     = 0.8245,
                .err_fmt_args = {"error at: " + std::get<2>(err) + std::get<1>(err)},
            });

            continue;
        }

        std::string raw_err = CXIR::strip(std::get<1>(err));

        // we either get: ('error'/'warn'/'note')':' 'C' ...
        // or we get: ('error'/'warn'/'note')':' ...
        size_t err_t = 0;
        size_t c_pos = raw_err.find('C');
        size_t colon_pos = raw_err.find(':');
        size_t first_non_space = raw_err.find_first_not_of(' ');

        // Validate if the 'C' is part of an MSVC error code (e.g., C4005)
        if (c_pos != std::string::npos && std::isdigit(raw_err[c_pos + 1])) {
            // 'C' is part of an MSVC error code
            err_t = (c_pos-1) - first_non_space;
        } else if (colon_pos != std::string::npos) {
            // Fallback to ':' position
            err_t = colon_pos - first_non_space;
        } else {
            // No valid MSVC error code or ':' found; handle the edge case
            err_t = std::string::npos;
        }

        DEBUG_LOG("getting err code for '", raw_err.substr(0, err_t), "'");
        
        error::Level level;
        std::string e_level = raw_err.substr(0, err_t);

        if (e_level == "error") {level = error::Level::ERR; }
        else if (e_level == "warning") {level = error::Level::WARN; }
        else if (e_level == "note") {level = error::Level::NOTE; }
        else {level = error::Level::FATAL; }

        auto pof = std::get<0>(err);
        try {  // if the file is a core lib file, ignore all but errors
            std::string f_name =
                std::filesystem::path(std::get<2>(err)).filename().generic_string();

            if ((f_name.size() == 28 && f_name.substr(9, 19) == "helix-compiler.cxir")) {
                if (level != error::Level::ERR) {
                    continue;
                }

                // if it is error rename pof file to helix core
                pof.set_file_name(pof.file_name() + "$helix.core.lib");
            }
        } catch (...) {}

        std::string msg = CXIR::strip(raw_err.substr(err_t + 1));

        DEBUG_LOG("panicking with error: '", raw_err, "'");
        DEBUG_LOG("token: ", pof.to_json());
        
        error::Panic(error::CodeError{
            .pof          = &pof,
            .err_code     = 0.8245,
            .mark_pof     = true,
            .fix_fmt_args = {},
            .err_fmt_args = {msg},
            .level        = level,
            .indent       = static_cast<size_t>((level == error::NOTE) ? 1 : 0),
        });
    }

    DEBUG_LOG("finished parsing output");

    if (compile_result.return_code == 0 && !error::HAS_ERRORED) {
        helix::log_opt<LogLevel::Progress>(is_verbose, "lowered " + action.helix_src.generic_string() +
                                   " and compiled cxir");
        helix::log_opt<LogLevel::Progress>(is_verbose, "compiled successfully to " + action.cc_output.generic_string());

        return {compile_result, flag::ErrorType(flag::types::ErrorType::Success)};
    }

    return {compile_result,
            flag::ErrorType(error::HAS_ERRORED ? flag::types::ErrorType::Error
                                               : flag::types::ErrorType::Success)};
}