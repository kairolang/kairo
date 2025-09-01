#ifndef __TOOLING_H__
#define __TOOLING_H__

#include <chrono>
#include <filesystem>
#include <neo-panic/include/error.hh>
#include <neo-pprint/include/hxpprint.hh>
#include <string>
#include <type_traits>
#include <utility>

#include "controller/include/Controller.hh"
#include "controller/include/config/Controller_config.def"
#include "controller/include/config/cxx_flags.hh"
#include "controller/include/shared/eflags.hh"
#include "generator/include/CX-IR/CXIR.hh"
#include "token/include/private/Token_base.hh"

#define IS_UNIX                                                                                    \
    (defined(__unix__) || defined(__APPLE__) || defined(__linux__) || defined(__FreeBSD__) ||      \
     defined(__NetBSD__) || defined(__OpenBSD__) || defined(__bsdi__) || defined(__DragonFly__) || \
     defined(__MACH__))

#ifndef VERBOSE_LOG
#define VERBOSE_LOG(...)                          \
    if (parsed_args.verbose) {                    \
        helix::log<LogLevel::Debug>(__VA_ARGS__); \
    }
#endif

namespace parser::preprocessor {
class ImportProcessor;
}

namespace flag {
namespace types {
    enum class CompileFlags : u8 {
        None    = 0,
        Debug   = 1 << 0,
        Verbose = 1 << 1,
        Library = 1 << 2,
    };

    enum class Compiler : u8 {
        MSVC,
        GCC,
        Clang,
        MingW,
        Custom,
    };

    enum class ErrorType : u8 { NotFound, Error, Success };
}  // namespace types

using CompileFlags = EFlags<flag::types::CompileFlags>;
using Compiler     = EFlags<flag::types::Compiler>;
using ErrorType    = EFlags<flag::types::ErrorType>;
}  // namespace flag

inline bool LSP_MODE = false;

/// CXIRCompiler compiler;
/// compiler.compile_CXIR(CXXCompileAction::init(emitter, out, flags, cxx_args));
/// NOTE: init returns a rvalue reference you can not assign it to a variable
struct CXXCompileAction {  // NOLINT
    using Path = std::filesystem::path;
    using Args = std::vector<std::string>;
    using CXIR = generator::CXIR::CXIR;

    Path               working_dir;
    Path               cc_source;
    Path               cc_output;
    Path               helix_src;
    Args               cxx_args;
    flag::CompileFlags flags;
    std::string        cxx_compiler;

    static CXXCompileAction
         init(CXIR &emitter, const Path &cc_out, flag::CompileFlags flags, Args cxx_args);
    void cleanup() const;

    CXXCompileAction() = default;
    CXXCompileAction(Path               working_dir,
                     Path               cc_source,
                     Path               cc_output,
                     Path               helix_src,
                     Args               cxx_args,
                     flag::CompileFlags flags,
                     std::string        cxx_compiler)
        : working_dir(std::move(working_dir))
        , cc_source(std::move(cc_source))
        , cc_output(std::move(cc_output))
        , helix_src(std::move(helix_src))
        , cxx_args(std::move(cxx_args))
        , flags(flags)
        , cxx_compiler(std::move(cxx_compiler)) {}

    CXXCompileAction(const CXXCompileAction &other) = default;

    CXXCompileAction &operator=(const CXXCompileAction &other) {
        if (this != &other) {
            working_dir  = other.working_dir;
            cc_source    = other.cc_source;
            cc_output    = other.cc_output;
            helix_src    = other.helix_src;
            cxx_args     = other.cxx_args;
            flags        = other.flags;
            cxx_compiler = other.cxx_compiler;
        }
        return *this;
    }

    CXXCompileAction(CXXCompileAction &&other) noexcept
        : working_dir(std::move(other.working_dir))
        , cc_source(std::move(other.cc_source))
        , cc_output(std::move(other.cc_output))
        , helix_src(std::move(other.helix_src))
        , cxx_args(std::move(other.cxx_args))
        , flags(other.flags)
        , cxx_compiler(std::move(other.cxx_compiler)) {}

    CXXCompileAction &operator=(CXXCompileAction &&other) noexcept {
        if (this != &other) {
            working_dir  = std::move(other.working_dir);
            cc_source    = std::move(other.cc_source);
            cc_output    = std::move(other.cc_output);
            helix_src    = std::move(other.helix_src);
            cxx_args     = std::move(other.cxx_args);
            flags        = other.flags;
            cxx_compiler = std::move(other.cxx_compiler);
        }
        return *this;
    }

    ~CXXCompileAction();

  private:
    static std::string generate_file_name(size_t length = 6);
};

class CXIRCompiler {
  public:
    struct ExecResult {
        std::string output;
        int         return_code{};
    };

    using CompileResult = std::pair<ExecResult, flag::ErrorType>;

    [[nodiscard]] static ExecResult exec(const std::string &cmd);

    [[nodiscard]] CXIRCompiler::CompileResult compile_CXIR(CXXCompileAction &&action, bool dry_run = false) const;

  private:
    mutable bool dry_run = false;
    /// (pof, msg, file)
    using ErrorPOFNormalized = std::tuple<token::Token, std::string, std::string>;

    [[nodiscard]] static ErrorPOFNormalized parse_clang_err(std::string clang_out);
    [[nodiscard]] static ErrorPOFNormalized parse_gcc_err(std::string gcc_out);
    [[nodiscard]] static ErrorPOFNormalized parse_msvc_err(std::string msvc_out);

    [[nodiscard]] CompileResult CXIR_MSVC(const CXXCompileAction &action) const;

    [[nodiscard]] CompileResult CXIR_CXX(const CXXCompileAction &action) const;
};

class CompilationUnit {
  public:
    int                                 compile(int argc, char **argv);
    int                                 compile(__CONTROLLER_CLI_N::CLIArgs &);
    std::pair<CXXCompileAction, int>    build_unit(__CONTROLLER_CLI_N::CLIArgs &, bool = true, bool = false);
    generator::CXIR::CXIR               generate_cxir(bool);
    __TOKEN_N::TokenList                pre_process(__CONTROLLER_CLI_N::CLIArgs &, bool);
    __AST_N::NodeT<__AST_NODE::Program> parse_ast(__TOKEN_N::TokenList &tokens,
                                                  std::filesystem::path in_file_path);

  private:
    CXIRCompiler                                           compiler;
    __AST_N::NodeT<__AST_NODE::Program>                    ast;
    std::shared_ptr<parser::preprocessor::ImportProcessor> import_processor = nullptr;

    static void remove_comments(__TOKEN_N::TokenList &tokens);

    static void emit_cxir(const generator::CXIR::CXIR &emitter, bool verbose);

    static std::filesystem::path
    determine_output_file(const __CONTROLLER_CLI_N::CLIArgs &parsed_args,
                          const std::filesystem::path       &in_file_path);

    static void log_time(const std::chrono::high_resolution_clock::time_point &start,
                         bool                                                  verbose,
                         const std::chrono::high_resolution_clock::time_point &end);
};

template <typename... Flags>
inline std::string make_command(const flag::types::Compiler _Compiler, Flags... flags) {
    std::string compile_cmd;

    // for each flag call flag->clang after checking if its of type cxx::flags::CX
    (void)std::initializer_list<int>{(
        [&compile_cmd, &_Compiler](auto flag) {
            if constexpr (std::is_same_v<decltype(flag), cxx::flags::CF>) {
                if (_Compiler == flag::types::Compiler::Clang) {
                    compile_cmd += std::string((flag).clang) + " ";
                } else if (_Compiler == flag::types::Compiler::MSVC) {
                    compile_cmd += std::string((flag).msvc) + " ";
                } else if (_Compiler == flag::types::Compiler::MingW) {
                    compile_cmd += std::string((flag).mingw) + " ";
                } else {
                    compile_cmd += std::string((flag).gcc) + " "; // default to gcc
                }
            } else if constexpr (std::is_same_v<decltype(flag), std::string> ||
                                 std::is_same_v<decltype(flag), const char *>) {
                compile_cmd += flag + std::string(" ");
            } else {
                static_assert(false, "invalid flag type");
            }
        }(flags),
        0)...};

    return compile_cmd;
}

#endif  // __TOOLING_H__