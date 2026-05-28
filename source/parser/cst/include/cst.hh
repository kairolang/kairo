/// --- The Kairo Project -------------------------------------------------- ///
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

#ifndef __CST_HH__
#define __CST_HH__

#include <concepts>
#include <cstddef>
#include <cstdlib>
#include <expected>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "token/include/Token.hh"

namespace parser::cst {
inline string get_indent(u16 depth) noexcept { return string(static_cast<u16>(depth * 4), ' '); };

struct ParseError {};

// concept AstBase = requires(T t) {
//     { t.parse(__TOKEN_N::TokenList) } -> std::expected<std::weak_ptr<ASTBase>, ParseError>;
//     { t.to_string() } -> std::string;
// };

using TokenListRef = std::shared_ptr<__TOKEN_N::TokenList>;
using ParseResult  = std::expected<TokenListRef, ParseError>;

template <typename T>
struct CSTBase;

template <>
struct CSTBase<void> {
    //     virtual std::expected<std::span<Token>,AstError> parse(std::span<Token> tokens) = 0;
    CSTBase()                           = default;
    CSTBase(CSTBase &&)                 = default;
    CSTBase(const CSTBase &)            = default;
    CSTBase &operator=(CSTBase &&)      = default;
    CSTBase &operator=(const CSTBase &) = delete;
    virtual ~CSTBase()                  = default;

    [[nodiscard]] virtual ParseResult parse()                      = 0;
    [[nodiscard]] virtual std::string to_json(u32 depth = 0) const = 0;
};

template <typename T>
struct CSTBase : public CSTBase<void> {
    explicit CSTBase(TokenListRef parse_tokens);
    CSTBase()                           = default;
    CSTBase(CSTBase &&)                 = default;
    CSTBase(const CSTBase &)            = default;
    CSTBase &operator=(CSTBase &&)      = default;
    CSTBase &operator=(const CSTBase &) = delete;
    ~CSTBase()                          = default;
};

template <typename T = void>
concept CSTNode = std::derived_from<T, CSTBase<T>>;

template <typename T = void>
using CSTNodePtr = std::shared_ptr<CSTBase<T>>;

template <typename T = void>
using CSTNodeList = std::vector<CSTNodePtr<T>>;

template <typename T = void>
using CSTSlice = const std::reference_wrapper<CSTNodeList<T>>;

}  // namespace parser::cst
#endif  // __CST_HH__