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

#ifndef __AST_PARSE_ERROR_H__
#define __AST_PARSE_ERROR_H__

#include <string>
#include <utility>

#include "neo-panic/include/error.hh"
#include "parser/ast/include/config/AST_config.def"
#include "token/include/Token.hh"

__AST_BEGIN {
    class ParseError {
        __TOKEN_N::Token err;
        __TOKEN_N::Token expected;
        std::string      msg;

      public:
        ParseError()                              = default;
        ~ParseError()                             = default;
        ParseError(const ParseError &)            = default;
        ParseError &operator=(const ParseError &) = default;
        ParseError(ParseError &&)                 = default;
        ParseError &operator=(ParseError &&)      = default;

        ParseError(const __TOKEN_N::Token &err, const __TOKEN_N::Token &expected)
            : err(err)
            , expected(expected) {

            this->msg = "expected '" + expected.value() + "' but found '" + err.value() + "'";
        }

        ParseError(__TOKEN_N::Token err, std::string msg)
            : err(std::move(err))
            , msg(std::move(msg)) {}

        explicit ParseError(std::string msg)
            : msg(std::move(msg)) {}

        [[nodiscard]] std::string what() const { return msg; }
        void                      panic() const {
            error::Panic(error::CodeError{
                .pof      = const_cast<__TOKEN_N::Token *>(&err),
                .err_code = 0.0001,
                .mark_pof = true,
                .fix_fmt_args{},
                .err_fmt_args{msg},
                .opt_fixes{},
            });
        }
    };
}  // namespace __AST_BEGIN

#endif  // __AST_PARSE_ERROR_H__