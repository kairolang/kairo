//===------------------------------------------------------------------------------------------===//
//
// Part of the Kairo Project, under the Attribution 4.0 International license (CC BY 4.0).
// You are allowed to use, modify, redistribute, and create derivative works, even for commercial
// purposes, provided that you give appropriate credit, and indicate if changes were made.
// For more information, please visit: https://creativecommons.org/licenses/by/4.0/
//
// SPDX-License-Identifier: CC-BY-4.0
// Copyright (c) 2024 (CC BY 4.0)
//
//===------------------------------------------------------------------------------------------===//
#ifndef __ERROR_HH__
#define __ERROR_HH__

#include <cstdio>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "neo-json/include/json.hh"
#include "neo-types/include/hxint.hh"
#include "token/include/Token.hh"

#define LINES_TO_SHOW 5

namespace error {
struct _internal_error {
  private:
    using fix_pair_vec = std::vector<std::pair<string, u32>>;

  public:
    string       color_mode;
    string       error_type;
    string       level;
    string       file;
    string       msg;
    string       fix;
    string       display;
    string       full_line;
    u64          line{};
    u64          col{};
    u64          offset{};
    fix_pair_vec quick_fix;
    size_t       indent = 0;

    _internal_error() = default;

    TO_NEO_JSON_IMPL {
        neo::json json(error_type == "code" ? "code_error" : "compiler_error");

        json.add("color_mode", neo::json::escape(color_mode))
            .add("error_type", neo::json::escape(error_type))
            .add("level", neo::json::escape(level))
            .add("file", neo::json::escape(file))
            .add("msg", neo::json::escape(msg))
            .add("fix", neo::json::escape(fix))
            .add("display", neo::json::escape(display))
            .add("line", std::to_string(line))
            .add("col", std::to_string(col))
            .add("offset", std::to_string(offset));

        std::vector<neo::json> fix_arr;
        for (const auto &[fix, pos] : quick_fix) {
            neo::json fix_json;
            fix_json.add("fix", neo::json::escape(fix));
            fix_json.add("pos", std::to_string(pos));
            fix_arr.push_back(fix_json);
        }

        json.add("quick_fixes", fix_arr);

        return json;
    }
};

using string_vec   = std::vector<string>;
using fix_pair     = std::pair<__TOKEN_N::Token, i64>;
using fix_pair_vec = std::vector<fix_pair>;
using errors_rep   = std::vector<_internal_error>;

inline bool       HAS_ERRORED = false;
inline bool       SHOW_ERROR  = true;
inline errors_rep ERRORS;
inline std::unordered_map<std::string, std::string> NAMESPACE_MAP; // maps the internal namespace representation to a ux friendly name

enum Level {
    NOTE,   ///< Just a Info.
    WARN,   ///< Warn, the compiler can move on to code gen. and produce a binary
    ERR,    ///< Error, but compiler can continue parsing
    FATAL,  ///< Fatal error all other proceeding errors omitted
    NONE,   ///< No level
};

struct Errors {
    string err;
    string fix;
    Level  level = ERR;
};

struct CodeError {
    __TOKEN_N::Token *pof;  //< point of failure
    double            err_code;
    bool              mark_pof = true;
    string_vec        fix_fmt_args;
    string_vec        err_fmt_args;
    fix_pair_vec      opt_fixes;      //< fixes that show in the code to fix
    Level             level  = NONE;  //< optional level to overload the one specifed in the error
    size_t            indent = 0;     //< optional indent to allow to error categorizing

    ~CodeError() = default;
};

struct CompilerError {
    double     err_code;
    string_vec fix_fmt_args;
    string_vec err_fmt_args;
};

class Panic {
  public:
    _internal_error final_err;

    explicit Panic(const CodeError &);
    explicit Panic(const CompilerError &);

  private:
    void process_compiler_error(CompilerError);
    void process_code_error(CodeError);
    void process_full_line();
    void show_error(bool);

    u32 calculate_addition_pos(i64) const;

    size_t level_len;
    bool   mark_pof;
};

static inline CodeError create_old_CodeError(__TOKEN_N::Token *pof,
                                             const double      err_code,
                                             string_vec        fix_fmt_args = {},
                                             string_vec        err_fmt_args = {},
                                             fix_pair_vec      opt_fixes    = {}) {
    return CodeError{.pof          = pof,
                     .err_code     = err_code,
                     .fix_fmt_args = std::move(fix_fmt_args),
                     .err_fmt_args = std::move(err_fmt_args),
                     .opt_fixes    = std::move(opt_fixes)};
};

static inline string fmt_string(const string &format, const string_vec &fmt_args) {
    string      result;
    std::size_t N = fmt_args.size();
    result.reserve(format.size());

    std::size_t argIndex = 0;
    std::size_t len      = format.size();

    for (std::size_t i = 0; i < len; ++i) {
        if (format[i] == '{' && i + 1 < len && format[i + 1] == '}') {
            if (argIndex >= N) {
                throw std::invalid_argument("Insufficient arguments provided for format string");
            }
            result += fmt_args[argIndex++];
            ++i;  // Skip over the closing '}'
        } else {
            result += format[i];
        }
    }

    if (argIndex != N) {
        throw std::invalid_argument("Too many arguments provided for format string: \"" + format +
                                    "\"");
    }

    return result;
}
}  // namespace error

#endif  // __ERROR_HH__
