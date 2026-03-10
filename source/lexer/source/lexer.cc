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

#include "lexer/include/lexer.hh"

#include <cstddef>
#include <string>
#include <unordered_map>
#include <vector>

#include "lexer/include/cases.def"
#include "neo-panic/include/error.hh"
#include "neo-pprint/include/hxpprint.hh"
#include "token/include/Token.hh"
#include "token/include/config/Token_cases.def"
#include "token/include/private/Token_generate.hh"

namespace parser::lexer {
Lexer::Lexer(std::string source, const std::string &filename)
    : tokens(filename)
    , source(std::move(source))
    , file_name(filename)
    , currentChar(this->source.length() > 0 ? this->source[0] : '\0')
    , cachePos(0)
    , currentPos(0)
    , line(1)
    , column(0)
    , offset(0)
    , end(this->source.size()) {}

Lexer::Lexer(std::string source, const std::string &filename, u64 line, u64 column, u64 offset)
    : tokens(filename)
    , source(std::move(source))
    , file_name(filename)
    , currentChar(this->source.length() > 0 ? this->source[0] : '\0')
    , cachePos(0)
    , currentPos(0)
    , line(line)
    , column(column)
    , offset(offset)
    , end(this->source.size())
    , starting_pos_override({line, column}) {}

Lexer::Lexer(const __TOKEN_N::Token &token)
    : tokens(token.file_name())
    , source(token.value())
    , file_name(token.file_name())
    , currentChar('\0')
    , cachePos(0)
    , currentPos(0)
    , line(token.line_number())
    , column(token.column_number())
    , offset(token.offset())
    , end(this->source.size()) {}

__TOKEN_N::TokenList Lexer::tokenize() {
    __TOKEN_N::Token token;

    while ((currentPos + 1) <= end) {
        token = next_token();

        if (token.token_kind() == __TOKEN_TYPES_N::WHITESPACE) {
            continue;
        }

        token.set_file_name(file_name);
        tokens.push_back(token);
    }

    token = get_eof();
    token.set_file_name(file_name);
    tokens.push_back(token);

    tokens.reset();
    return tokens;
}

inline __TOKEN_N::Token Lexer::get_eof() {
    return {line, column, 1, offset, "\0", file_name, "<eof>"};
}

inline __TOKEN_N::Token Lexer::process_single_line_comment() {
    auto start = currentPos;

    while (current() != '\n' && !is_eof()) {
        bare_advance();
    }

    return {line,
            column - (currentPos - start),
            currentPos - start,
            offset,
            source.substr(start, currentPos - start),
            file_name,
            "//"};
}

inline __TOKEN_N::Token Lexer::process_multi_line_comment() {
    auto start         = currentPos;
    u64  comment_depth = 0;

    u64 start_line = line;
    u64 start_col  = column;

    while (!is_eof()) {
        switch (current()) {
            case '/':
                if (peek_forward() == '*') {
                    ++comment_depth;
                    bare_advance(2);
                }
                break;
            case '*':
                if (peek_forward() == '/') {
                    --comment_depth;
                    if (comment_depth != 0) {
                        bare_advance(2);
                    }
                }
                break;
            case '\n':
                column = 0;
                break;
        }

        if (comment_depth == 0) {
            bare_advance(2);
            break;
        }

        bare_advance();
    }

    if (comment_depth != 0) {
        auto bad_token = __TOKEN_N::Token{start_line, start_col, 2, offset, "", file_name};
        error::Panic(error::create_old_CodeError(
            &bad_token, 2.1002, {}, std::vector<string>{"block comment"}));
        
        return {start_line, start_col, 2, offset, "", file_name, "/* unclosed comment"};
    }

    return {line,
            start_col,
            currentPos - start,
            offset,
            source.substr(start, currentPos - start),
            file_name,
            "/*"};
}

inline __TOKEN_N::Token Lexer::next_token() {
    switch (source[currentPos]) {
        case WHITE_SPACE:
            bare_advance();
            return __TOKEN_N::Token{};
        case '/':
            switch (peek_forward()) {
                case '/':
                    return process_single_line_comment();
                case '*':
                    return process_multi_line_comment();
            }
            return parse_operator();
        case STRING:
            return parse_string();
        case _0_9:
            return parse_numeric();
        case STRING_BYPASS:
            switch (peek_forward()) {
                case STRING:
                    return parse_string();
            }
        case '_':
        case A_Z:
        case a_z_EXCLUDE_rbuf:  // removed the following cases since they are already
                                // covered by the STRING_BYPASS: (r, b, f, u)
            return parse_alpha_numeric();
        case '#':  // so things like #[...] are compiler directives and are 1 token but # [...] is
                   // a NOT compiler directive and is # token + everything else
            return parse_compiler_directive();
        case PUNCTUATION:
            return parse_punctuation();
        case OPERATORS:
            return parse_operator();
    }

    auto bad_token =
        __TOKEN_N::Token{line, column, 1, offset, std::string(1, current()), file_name};

    error::Panic(error::create_old_CodeError(
        &bad_token, 1.0011, {}, std::vector<string>{std::string(1, current())}));
    return bad_token;
}

inline __TOKEN_N::Token Lexer::parse_compiler_directive() {
    auto start       = currentPos;
    auto end_loop    = false;
    u32  brace_level = 0;

    if (peek_forward() != '[') {
        __TOKEN_N::Token bad_token = {line, column, 1, offset, source.substr(start, 1), file_name};

        error::Panic(error::CodeError{.pof = &bad_token, .err_code = 0.7006 /* NOLINT */});
        return bad_token;
    }

    while (!end_loop && !is_eof()) {
        switch (current()) {
            case '[':
                ++brace_level;
                break;
            case ']':
                --brace_level;
                end_loop = brace_level == 0;
                break;
            case '\n':
                end_loop = brace_level == 0;
                break;
        }

        bare_advance();
    }

    __TOKEN_N::Token tok{line,
                         column - (currentPos - start),
                         currentPos - start,
                         offset,
                         source.substr(start + 2, (currentPos - start) - 3),
                         file_name,
                         "/* compiler_directive */"};

    return tok;
}

inline __TOKEN_N::Token Lexer::process_whitespace() {
    auto result = __TOKEN_N::Token{
        line, column, 1, offset, source.substr(currentPos, 1), file_name, "/*   */"};
    bare_advance();
    return result;
}

inline __TOKEN_N::Token Lexer::parse_alpha_numeric() {
    auto start = currentPos;

    bool end_loop = false;

    while (!end_loop && !is_eof()) {
        switch (peek_forward()) {
            case '_':
            case A_Z:
            case a_z:
            case _0_9:
                break;
            default:
                end_loop = true;
                break;
        }
        bare_advance();
    }

    auto result = __TOKEN_N::Token{line,
                                   column - (currentPos - start),
                                   currentPos - start,
                                   offset,
                                   source.substr(start, currentPos - start),
                                   file_name};

    if (result.token_kind() != __TOKEN_TYPES_N::OTHERS) {
        return result;
    }

    return {line,
            column - (currentPos - start),
            currentPos - start,
            offset,
            source.substr(start, currentPos - start),
            file_name,
            "_"};
}

inline __TOKEN_N::Token Lexer::parse_numeric() {
    // all the data within 0-9 is a number
    // a number can have the following chars after the first digit:
    // 0-9, ., F, f, U, u, o, x, b, e, E, A-F, a-f, _
    // TODO: add sci notation
    auto start = currentPos;

    u32  dot_count    = 0;
    bool is_float     = false;
    bool end_loop     = false;
    bool sci_notation = false;

    while (!end_loop && !is_eof()) {
        switch (peek_forward()) {
            case '.':
                ++dot_count;
                
                if (dot_count == 2) {
                    /// we might have a range, a range inclusive operator or a ellipsis
                    /// either we have 2 dots or and the current token is a '=` then we have a range

                    if (current() == '.' /* we know peed_forward is also a '.' */) {
                        end_loop = true;
                        is_float = false;
                        --currentPos; // reverse the last advance
                        break;
                    }
                }

                is_float = true;
            case _non_float_numeric:
                if (peek_forward() == 'e') {
                    sci_notation = true;
                }
                break;
            default:
                if (sci_notation && (peek_forward() == '-' || peek_forward() == '+')) {
                    break;
                }
                end_loop = true;
                break;
        }
        bare_advance();
    }

    // if theres a . then it is a float
    if (is_float) {
        if (dot_count > 1) {
            /// we might have a range or a range inclusive operator
            /// either we have 2 dots or and the current token is a '=` then we have a range

            auto bad_token = __TOKEN_N::Token{line,
                                              column - (currentPos - start),
                                              currentPos - start,
                                              offset,
                                              source.substr(start, currentPos - start),
                                              file_name,
                                              "/* float */"};

            error::Panic(error::create_old_CodeError(&bad_token, 0.0003));
            return bad_token;
        }
        return {line,
                column - (currentPos - start),
                currentPos - start,
                offset,
                source.substr(start, currentPos - start),
                file_name,
                "/* float */"};
    }
    return {line,
            column - (currentPos - start),
            currentPos - start,
            offset,
            source.substr(start, currentPos - start),
            file_name,
            "/* int */"};
}

inline __TOKEN_N::Token Lexer::parse_string() {
    // all the data within " (<string>) or ' (<char>) is a string
    auto start        = currentPos;
    auto start_line   = line;
    auto start_column = column+1;

    std::string token_type;

    bool end_loop      = false;
    char quote         = current();
    bool is_format_str = false;

    switch (current()) {
        case 'r':
        case 'b':
        case 'f':
            is_format_str = true;
        case 'u':
            if (peek_forward() == '"' || peek_forward() == '\'') {
                quote = advance();
            } else {
                error::Panic panic = error::Panic(error::create_old_CodeError(
                    nullptr,
                    0.0001,
                    {},
                    std::vector<string>{"more then 1 string specifier provided."}));
            }
            break;
    }

    size_t brace_nesting = 0;

    // if the quote is followed by a \ then ignore the quote
    while (!end_loop && !is_eof()) {
        if (is_format_str) {
            switch (current()) {
                case '{':
                    ++brace_nesting;
                    break;
                case '}':
                    --brace_nesting;
                    break;
                default:
                    break;
            }
        }

        if (brace_nesting > 0) {
            bare_advance();
            continue;
        }

        switch (peek_forward()) {
            case '\\':
                bare_advance();
                break;
            case STRING:
                end_loop = advance() == quote;
                break;
            default:
                break;
        }

        bare_advance();
    }

    if (brace_nesting > 0) {
        auto bad_token = __TOKEN_N::Token{start_line, start_column, 1, offset, "\"", file_name};
        error::Panic(error::create_old_CodeError(
            &bad_token, 2.1002, {}, std::vector<string>{"'{' in f-string"}));
        return bad_token;
    }

    if (is_eof()) {
        auto bad_token = __TOKEN_N::Token{start_line, start_column, 1, offset, "\"", file_name};
        error::Panic(
            error::create_old_CodeError(&bad_token, 2.1002, {}, std::vector<string>{"string"}));
        return bad_token;
    }

    switch (quote) {
        case '"':
            token_type = "/* string */";
            break;
        case '\'':
            token_type = "/* char */";
            break;
    }

    return {start_line,
            start_column,
            currentPos - start,
            offset,
            source.substr(start, currentPos - start),
            file_name,
            token_type};
}

inline __TOKEN_N::Token Lexer::parse_operator() {
    auto start    = currentPos;
    bool end_loop = false;

    while (!end_loop && !is_eof()) {
        switch (peek_forward()) {
            case OPERATORS:
                break;
            default:
                end_loop = true;
                break;
        }

        bare_advance();
    }

    // we might have a few operaotrs in here, something like >>> would be a >> and a > but this parser will
    // treat it asx >>> bing a single token
    string current_token;

    // break the token into a smaller token if current token is not a valid token
    token::Token tok {line,
            column - (currentPos - start),
            currentPos - start,
            offset,
            source.substr(start, currentPos - start),
            file_name};

check_if_invalid_tok:
    if (tok == token::OTHERS) { // invalid token
        // we need to break the token into smaller tokens
        current_token = tok.value();

        current_token.pop_back(); // >>> would become >>
        --currentPos;

        tok = {line,
            tok.column_number(),
            current_token.length(),
            tok.offset() - 1,
            current_token,
            file_name};

        if (current_token.length() == 0) {
            error::Panic(error::create_old_CodeError(
                &tok, 1.0011, {}, std::vector<string>{std::string(1, current())}));
            return tok;
        }

        goto check_if_invalid_tok; // if the token is still invalid
    }

    return tok;
}

inline __TOKEN_N::Token Lexer::parse_punctuation() {  // gets here bacause of something like . | :
    __TOKEN_N::Token result;

    switch (source[currentPos]) {
        case '.':  // .
            // can be: .., ..., ..=
            if (peek_forward() == '.') {  // ..
                bare_advance();

                if (peek_forward() == '.') {  // ...
                    bare_advance(2);
                    result = __TOKEN_N::Token{line, column - 2, 3, offset, "...", file_name};

                    return result;
                }

                if (peek_forward() == '=') {  // ..=
                    bare_advance(2);
                    result = __TOKEN_N::Token{line, column - 2, 3, offset, "..=", file_name};

                    return result;
                }

                bare_advance();
                result = __TOKEN_N::Token{line, column - 1, 2, offset, "..", file_name};
                return result;
            }
            break;

        case ':':  // : or ::
            if (peek_forward() == ':') {
                bare_advance(2);
                result = __TOKEN_N::Token{line, column, 2, offset, "::", file_name};

                return result;
            }
            break;

        default: {
            break;
        }
    }

    result = __TOKEN_N::Token{line, column, 1, offset, source.substr(currentPos, 1), file_name};
    bare_advance();
    return result;
}

inline char Lexer::advance(u16 n) {
    if (currentPos + 1 > end) {
        return '\0';
    }

    switch (source[currentPos]) {
        case '\n':
            ++line;
            column = 0;
            break;
        default:
            ++column;
            ++offset;
            break;
    }

    ++currentPos;

    if (n > 1) {
        return advance(n - 1);
    }

    return current();
}

inline void Lexer::bare_advance(u16 n) {
    switch (source[currentPos]) {
        case '\n':
            ++line;
            column = 0;
            break;
        default:
            ++column;
            ++offset;
            break;
    }

    ++currentPos;

    if (n > 1) {
        return bare_advance(n - 1);
    }
}

inline char Lexer::reverse(u16 n) {
    if (currentPos == 0) {
        return '\0'; // Prevent going out of bounds
    }

    --currentPos;

    switch (source[currentPos]) {
        case '\n': {
            --line;
            column = 0;
            
            while ((currentPos - column >= 0) && (source[currentPos - column] != '\n')) {
                ++column;
            }

            break;
        } default:
            --column;
            --offset;
            break;
    }

    if (n > 1) {
        return reverse(n - 1);
    }

    return current();
}

inline char Lexer::current() {
    if (is_eof()) {
        return '\0';
    }

    if (currentPos == cachePos) {
        return currentChar;
    }

    cachePos    = currentPos;
    currentChar = source[currentPos];

    return currentChar;
}

inline char Lexer::peek_back() const {
    if (currentPos - 1 < 0) {
        return '\0';
    }

    return source[currentPos - 1];
}

inline char Lexer::peek_forward() const {
    if (currentPos + 1 >= end) {
        return '\0';
    }

    return source[currentPos + 1];
}

inline bool Lexer::is_eof() const { return currentPos > end; }
}  // namespace parser::lexer