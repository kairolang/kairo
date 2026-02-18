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

#ifndef __CST_NODES_HH__
#define __CST_NODES_HH__

#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

#include "lexer/include/lexer.hh"
#include "neo-panic/include/error.hh"
#include "neo-pprint/include/hxpprint.hh"
#include "neo-types/include/hxint.hh"
#include "parser/cst/include/cst.hh"
#include "token/include/Token.hh"

#define CST_NODE_METHODS(name)               \
    ~name() = default;                       \
    explicit name(TokenListRef parse_tokens) \
        : tokens(std::move(parse_tokens)){}; \
    name()                        = default; \
    name(name &&)                 = default; \
    name(const name &)            = default; \
    name &operator=(name &&)      = default; \
    name &operator=(const name &) = delete;

namespace parser::cst {
using namespace token;

template <const char quote, const tokens TOKE_KIND>
struct Quoted final : CSTBase<Quoted<quote, TOKE_KIND>> {
  public:
    enum class Format : char {
        Invalid,
        None      = quote,
        Raw       = 'r',
        Bytes     = 'b',
        Unicode   = 'u',
        Formatted = 'f',  // does not work for char....., but it could if someone really wanted too
    };

    CST_NODE_METHODS(Quoted);

  public:
    ParseResult parse() final override {
        // Do we have suffixes?
        Token &toke  = tokens->front();
        this->tokens = tokens;

        // print(delim_tokes->to_json());
        if (toke.token_kind() != TOKE_KIND) {
            error::Error(error::create_old_CodeError(
                &toke, 2.1004, {}, std::vector<string>{"quote literal"}));
        };

        // There in no need to check for the token kind as the value of this
        this->format = static_cast<Format>(toke.value().at(0));

        if (format == Format::Invalid) {
            error::Error(error::create_old_CodeError(&toke, 5.1003));
        }

        this->value = toke;
        auto siz    = this->format == Format::None ? 1 : 2;
        // Remove the format specifier (if it is there) and quotes
        this->value.set_value(toke.value().substr(siz, toke.value().size() - (siz + 1)));
        // - 1 is the actual length
        // - 2 is removing the \0
        // - 3 removes the quote

        // Check for format
        // TODO: make f"hi {name if !name.empty() else "john doe"}" -> string: "hi {}", fmt_args
        // (astExpr): name if !name.empty() else "john doe"

        /*Sure, here are the formatting types with examples for both Rust and C++:

### Rust Formatting Types with Examples

#### Alignment
- `:<`  - Left aligns the result
  ```rust
  format!("{:<10}", "left") // "left      "
  ```
- `:>`  - Right aligns the result
  ```rust
  format!("{:>10}", "right") // "     right"
  ```
- `:^`  - Center aligns the result
  ```rust
  format!("{:^10}", "center") // "  center  "
  ```

#### Sign and Space
- `:=`  - Places the sign to the left most position
  ```rust
  format!("{:=+10}", 42) // "+      42"
  ```
- `:+`  - Use a plus sign to indicate if the result is positive or negative
  ```rust
  format!("{:+}", 42) // "+42"
  ```
- `:-`  - Use a minus sign for negative values only
  ```rust
  format!("{:-}", -42) // "-42"
  ```
- `: `  - Use a space to insert an extra space before positive numbers (and a minus sign before
negative numbers)
  ```rust
  format!("{: }", 42) // " 42"
  ```

#### SEPARATOR
- `:,`  - Use a comma as a thousand separator
  ```rust
  format!("{:,}", 1000000) // "1,000,000"
  ```
- `:_`  - Use an underscore as a thousand separator
  ```rust
  format!("{:_}", 1000000) // "1_000_000"
  ```

#### Base
- `:b`  - Binary format
  ```rust
  format!("{:b}", 42) // "101010"
  ```
- `:o`  - Octal format
  ```rust
  format!("{:o}", 42) // "52"
  ```
- `:x`  - Hex format, lower case
  ```rust
  format!("{:x}", 42) // "2a"
  ```
- `:X`  - Hex format, upper case
  ```rust
  format!("{:X}", 42) // "2A"
  ```

#### Number
- `:d`  - Decimal format
  ```rust
  format!("{:d}", 42) // "42"
  ```
- `:e`  - Scientific format, with a lower case e
  ```rust
  format!("{:e}", 12345.6789) // "1.234568e4"
  ```
- `:E`  - Scientific format, with an upper case E
  ```rust
  format!("{:E}", 12345.6789) // "1.234568E4"
  ```
- `:f`  - Fix point number format
  ```rust
  format!("{:f}", 3.14159) // "3.141590"
  ```
- `:F`  - Fix point number format, in uppercase format (show inf and nan as INF and NAN)
  ```rust
  format!("{:F}", 3.14159) // "3.141590"
  ```
- `:g`  - General format
  ```rust
  format!("{:g}", 12345.6789) // "12345.7"
  ```
- `:G`  - General format (using an upper case E for scientific notations)
  ```rust
  format!("{:G}", 12345.6789) // "12345.7"
  ```
- `:n`  - Number format
  ```rust
  format!("{:n}", 1234567890) // "1234567890"
  ```
- `:%`  - Percentage format
  ```rust
  format!("{:.2%}", 0.1234) // "12.34%"
  ```

#### Other
- `:c`  - Converts the value into the corresponding Unicode character
  ```rust
  format!("{:c}", 65) // "A"
  ```

### C++ Formatting Types with Examples (using `std::format` from C++20)

#### Alignment
- `<`  - Left aligns the result
  ```cpp
  std::format("{:<10}", "left") // "left      "
  ```
- `>`  - Right aligns the result
  ```cpp
  std::format("{:>10}", "right") // "     right"
  ```
- `^`  - Center aligns the result
  ```cpp
  std::format("{:^10}", "center") // "  center  "
  ```

#### Sign and Space
- `=`  - Places the sign to the left most position
  ```cpp
  std::format("{:=+10}", 42) // "+      42"
  ```
- `+`  - Use a plus sign to indicate if the result is positive or negative
  ```cpp
  std::format("{:+}", 42) // "+42"
  ```
- `-`  - Use a minus sign for negative values only
  ```cpp
  std::format("{:-}", -42) // "-42"
  ```
- ` `  - Use a space to insert an extra space before positive numbers (and a minus sign before
negative numbers)
  ```cpp
  std::format("{: }", 42) // " 42"
  ```

#### SEPARATOR
- `,`  - Use a comma as a thousand separator
  ```cpp
  std::format("{:,}", 1000000) // "1,000,000"
  ```
- `_`  - Use an underscore as a thousand separator
  ```cpp
  std::format("{:_}", 1000000) // "1_000_000"
  ```

#### Base
- `b`  - Binary format
  ```cpp
  std::format("{:b}", 42) // "101010"
  ```
- `o`  - Octal format
  ```cpp
  std::format("{:o}", 42) // "52"
  ```
- `x`  - Hex format, lower case
  ```cpp
  std::format("{:x}", 42) // "2a"
  ```
- `X`  - Hex format, upper case
  ```cpp
  std::format("{:X}", 42) // "2A"
  ```

#### Number
- `d`  - Decimal format
  ```cpp
  std::format("{:d}", 42) // "42"
  ```
- `e`  - Scientific format, with a lower case e
  ```cpp
  std::format("{:e}", 12345.6789) // "1.234568e4"
  ```
- `E`  - Scientific format, with an upper case E
  ```cpp
  std::format("{:E}", 12345.6789) // "1.234568E4"
  ```
- `f`  - Fix point number format
  ```cpp
  std::format("{:f}", 3.14159) // "3.141590"
  ```
- `F`  - Fix point number format, in uppercase format (show inf and nan as INF and NAN)
  ```cpp
  std::format("{:F}", 3.14159) // "3.141590"
  ```
- `g`  - General format
  ```cpp
  std::format("{:g}", 12345.6789) // "12345.7"
  ```
- `G`  - General format (using an upper case E for scientific notations)
  ```cpp
  std::format("{:G}", 12345.6789) // "12345.7"
  ```
- `n`  - Number format
  ```cpp
  std::format("{:n}", 1234567890) // "1234567890"
  ```
- `%`  - Percentage format
  ```cpp
  std::format("{:.2%}", 0.1234) // "12.34%"
  ```

#### Other
- `c`  - Converts the value into the corresponding Unicode character
  ```cpp
  std::format("{:c}", 65) // "A"
  ```

These examples illustrate how to use various formatting options in Rust and C++.
        */
        // print(delim_tokes->to_json());
        if (this->format == Format::Formatted) {

            // {var=} // var = value
            // {function_name(var)} // "___value"
            auto tokenized_string = lexer::Lexer(toke).tokenize();
        }
        return std::make_shared<TokenList>(this->tokens->slice(1));
    };

    virtual bool peek() const override final {
        return this->tokens->front().token_kind() == TOKE_KIND;
    };

    virtual std::string to_json(u32 depth = 0) const override final {

        std::string format;

        switch (this->format) {
            case Format::Raw:
                format = "r";
                break;
            case Format::Bytes:
                format = "b";
                break;
            case Format::Unicode:
                format = "u";
                break;
            case Format::Formatted:
                format = "f";
                break;
            case Format::None:
                break;
        }

        /*
        "Quoted" : {
            "value" : ...

        },
        */

        return jsonify::indent(depth) + "\"Quoted\" : {\n" +
               jsonify::to_json(jsonify::escape(std::string(1, quote)), depth + 1, "openSymbol") +
               ",\n" + jsonify::indent(depth + 1) +
               "\"value\" : " + this->value.to_json(depth + 1, false) + ",\n" +
               jsonify::to_json(jsonify::escape(std::string(1, quote)), depth + 1, "closeSymbol") +
               "\n" + jsonify::indent(depth) + "}\n";
    };

  private:
    TokenListRef tokens;
    Token        value;
    Format       format = Format::None;
};

struct BoolLiteral final : CSTBase<BoolLiteral> {
  public:
    enum class BoolValue : u8 {
        True  = 't',
        False = 'f',
    };

    CST_NODE_METHODS(BoolLiteral);
    ParseResult parse() final override;
    std::string to_json(u32 depth = 0) const final;

  private:
    TokenListRef tokens;
    Token        value;
    // BoolValue value; // should this be a bool?
};

using StringLiteral = Quoted<'"', __TOKEN_TYPES_N::LITERAL_STRING>;
using CharLiteral   = Quoted<'\'', __TOKEN_TYPES_N::LITERAL_CHAR>;

template <const tokens StartTokenKind,
          const char   StartChar,
          typename MiddleNode,
          const char   EndChar,
          const tokens EndTokensKind>
struct Delimited final
    : CSTBase<Delimited<StartTokenKind, StartChar, MiddleNode, EndChar, EndTokensKind>> {
  public:
    CST_NODE_METHODS(Delimited);

  public:
    // const char start = StartChar;
    // const char end = EndChar;

    virtual ParseResult parse() final {

        TokenListRef delim_tokes = tokens;

        // Check if the first token is the start token
        if (tokens->front().token_kind() != StartTokenKind) {
            error::Error(error::create_old_CodeError(
                &tokens->front(), 2.1004, {}, std::vector<string>{"start token"}));
        };

        delim_tokes = std::make_shared<TokenList>(delim_tokes->slice(1));

        this->value.emplace(std::make_unique<MiddleNode>(delim_tokes));

        ParseResult res = this->value.value()->parse();

        if (!res.has_value()) {
            // TODO: ERROR
            throw;
        }

        delim_tokes = res.value();

        // Check if the last token is the end token
        if (delim_tokes->back().token_kind() != EndTokensKind) {
            error::Error(error::create_old_CodeError(
                &delim_tokes->front(), 2.1004, {}, std::vector<string>{"end token"}));
        }

        delim_tokes     = std::make_shared<TokenList>(delim_tokes->slice(1));
        auto new_tokens = std::make_shared<TokenList>(this->tokens->slice(0));
        this->tokens.swap(new_tokens);
        return delim_tokes;
    }

    bool peek() const final override { throw std::logic_error("Method not implemented"); }

    std::string to_json(u32 depth = 0) const final {

        return jsonify::indent(depth) + "\"Delimited\" : {\n" +
               jsonify::to_json(
                   jsonify::escape(std::string(1, StartChar)), depth + 1, "openSymbol") +
               ",\n" + jsonify::indent(depth + 1) + "\"value\" : {\n" +
               this->value.value()->to_json(depth + 2) + jsonify::indent(depth + 1) + "},\n" +
               jsonify::to_json(
                   jsonify::escape(std::string(1, EndChar)), depth + 1, "closeSymbol") +
               "\n" + jsonify::indent(depth) + "}\n";
    }

  private:
    TokenListRef                               tokens;
    std::optional<std::unique_ptr<MiddleNode>> value;
};

template <CSTNode T>
using Parentheses = Delimited<__TOKEN_TYPES_N::PUNCTUATION_OPEN_PAREN,
                              '(',
                              T,
                              ')',
                              __TOKEN_TYPES_N::PUNCTUATION_CLOSE_PAREN>;

template <CSTNode T>
using CurlyBraces = Delimited<__TOKEN_TYPES_N::PUNCTUATION_OPEN_BRACE,
                              '{',
                              T,
                              '}',
                              __TOKEN_TYPES_N::PUNCTUATION_CLOSE_BRACE>;

template <CSTNode T>
using SquareBrack = Delimited<__TOKEN_TYPES_N::PUNCTUATION_OPEN_BRACKET,
                              '[',
                              T,
                              ']',
                              __TOKEN_TYPES_N::PUNCTUATION_CLOSE_BRACKET>;

template <CSTNode T>
using AngleBrace = Delimited<__TOKEN_TYPES_N::PUNCTUATION_OPEN_ANGLE,
                             '<',
                             T,
                             '>',
                             __TOKEN_TYPES_N::PUNCTUATION_CLOSE_ANGLE>;

template <CSTNode T>
using PipeDelimited = Delimited<__TOKEN_TYPES_N::OPERATOR_BITWISE_OR,
                                '|',
                                T,
                                '|',
                                __TOKEN_TYPES_N::OPERATOR_BITWISE_OR>;

enum SeparatedType { Trailing, OptionalTrailing, NoTrailing };

template <CSTNode             ElementNode,
          const char          SEPARATOR,
          const tokens        SeparatorTokenKind,
          const SeparatedType SepType = SeparatedType::NoTrailing>
struct SeparatedList final
    : CSTBase<SeparatedList<ElementNode, SEPARATOR, SeparatorTokenKind, SepType>> {
  public:
    CST_NODE_METHODS(SeparatedList)
  public:
    ParseResult parse() final override {
        print("SepListPars ", SEPARATOR);
        TokenListRef sep_tokes = this->tokens;

        // temp as a size check would be safer
        while (tokens->as_vec().back().token_kind() != EOF_TOKEN) {  // Make this a peek
            ElementNode element{sep_tokes};
            ParseResult res = element.parse();
            if (!res.has_value()) {
                // TODO Erro
                // +r

                throw std::runtime_error("No value");
            }

            sep_tokes = res.value();

            // Push the element to the vector
            this->elements.emplace_back(std::move(element));

            // Parse the separator
            if (sep_tokes->front().token_kind() != SeparatorTokenKind) {

                // If the separator is not found break
                break;
            }
            // Remove the separator
            sep_tokes = std::make_shared<TokenList>(sep_tokes->slice(1));
        }

        // if constexpr (SepType == SeparatedType::Trailing) {
        //     if (tokes->front().token_kind() !=
        //         SeparatorTokenKind) {  // TODO: make this error better...
        //         error::Error(error::Line(tokes->front(), "Expected a separator: " + SEPARATOR));
        //     }
        //     tokes = std::make_shared<TokenList>(tokes->slice(1));
        // } else

        //    if constexpr (SepType == SeparatedType::OptionalTrailing) {
        //    // Parse the trailing element
        //    if (tokes->front().token_kind() == SeparatorTokenKind) {
        //        tokes = std::make_shared<TokenList>(tokes->slice(1));
        //    }
        //}

        // Return the remaining tokens and store the new tokens

        return sep_tokes;
    }

    std::string to_json(u32 depth = 0) const final {

        const std::string sep = std::string(1, SEPARATOR);

        std::string json = jsonify::indent(depth) + "\"SeparatedList\" : {\n" +
                           jsonify::to_json(jsonify::escape(sep), depth + 1, "separator") + ",\n" +
                           jsonify::indent(depth + 1) + "\"elements\" : [\n";

        for (const auto &element : this->elements) {
            json += element.to_json(depth + 2);
        }

        json += jsonify::indent(depth + 1) + "]\n" + jsonify::indent(depth) + "}\n";

        return json;
    }

  private:
    TokenListRef tokens;
    using temp = struct {
        ElementNode one;
        Token       sep;
    };
    std::vector<temp> elements{};
};

}  // namespace parser::cst

#undef CST_NODE_METHODS
#endif  // __CST_NODES_HH__