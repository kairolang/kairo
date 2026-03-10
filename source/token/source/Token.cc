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
///   SPDX-License-Identifier: Apache-2.0                                                        ///
///   Copyright (c) 2024 The Kairo Project (CC BY 4.0)                                           ///
///                                                                                              ///
///-------------------------------------------------------------------------------------- C++ ---///

#include <mutex>
#include <shared_mutex>
#include <vector>

#include "token/include/config/Token_config.def"
#include "token/include/private/Token_base.hh"
#include "token/include/private/Token_generate.hh"

__TOKEN_BEGIN {

    Token::Token(u64                line,
                 u64                column,
                 u64                length,
                 u64                offset,
                 std::string_view   value,
                 const std::string &filename,
                 std::string_view   token_kind)
        : line(line)
        , column(column)
        , len(length)
        , _offset(offset)
        , val(value)
        , filename(filename) {
        std::optional<tokens> token_enum;

        if (token_kind.empty()) {
            token_enum = tokens_map.at(value);
        } else {
            token_enum = tokens_map.at(token_kind);
        }

        if (token_enum.has_value()) {
            this->kind = token_enum.value();
        } else {
            this->kind = __TOKEN_TYPES_N::OTHERS;
        }
    }

    // Default Constructor
    Token::Token()
        : kind(__TOKEN_TYPES_N::WHITESPACE)
        , val(" ") {}

    // custom intrinsics constructor
    Token::Token(tokens token_type, const std::string &filename, std::string value)
        : kind(token_type)
        , filename(filename) {

        if (value.empty()) {
            value = std::string(tokens_map.at(token_type).value());
        }

        len = value.length();
        val = std::move(value);
    }

    // Copy Constructor
    Token::Token(const Token &other)
        : line(other.line)
        , column(other.column)
        , len(other.len)
        , _offset(other._offset)
        , kind(other.kind)
        , val(other.val)
        , filename(other.filename) {}

    // Copy Assignment Operator
    Token &Token::operator=(const Token &other) {
        if (this == &other) {
            return *this;
        }
        line     = other.line;
        column   = other.column;
        len      = other.len;
        _offset  = other._offset;
        kind     = other.kind;
        val      = other.val;
        filename = other.filename;

        return *this;
    }

    // Move Constructor
    Token::Token(Token && other) noexcept
        : line(other.line)
        , column(other.column)
        , len(other.len)
        , _offset(other._offset)
        , kind(other.kind)
        , val(std::move(other.val))
        , filename(std::move(other.filename)) {}

    // Move Assignment Operator
    Token &Token::operator=(Token &&other) noexcept {
        if (this == &other) {
            return *this;
        }
        line     = other.line;
        column   = other.column;
        len      = other.len;
        _offset  = other._offset;
        kind     = other.kind;
        val      = std::move(other.val);
        filename = other.filename;
        return *this;
    }

    Token &Token::operator=(const std::string &other) {
        this->val = std::string(other);
        this->len = this->val.length();
        return *this;
    }

    // Destructor
    Token::~Token() = default;

    u32 Token::line_number() const { return line; }

    u32 Token::column_number() const { return column; }

    u32 &Token::get_column_number() const { return column; }

    u32 Token::length() const { return len; }

    u32 Token::offset() const { return _offset; }

    tokens Token::token_kind() const { return kind; }

    std::string Token::value() const { return val; }

    std::string &Token::get_value() const { return val; }

    std::string Token::token_kind_repr() const { return std::string(tokens_map.at(kind).value()); }

    std::string Token::file_name() const { return filename; }

    void Token::set_file_name(const std::string &file_name) {
        this->filename = std::string(file_name);
    }

    void Token::set_value(const std::string &other) {
        this->val = std::string(other);
        this->len = this->val.length();
    }

    void Token::set_kind(tokens token_type) { this->kind = token_type; }

    void Token::offset(OffsetType ty, u64 by) {
        switch (ty) {
            case OffsetType::Line:
                line += by;
                return;
            case OffsetType::Offset:
                _offset += by;
                return;
            case OffsetType::Colum:
                column += by;
                return;
            default:
                return;
        }
    }

    std::string Token::to_string() const {
        return std::string("Token(") + std::string("line: ") + std::to_string(line) +
               std::string(", column: ") + std::to_string(column) + std::string(", len: ") +
               std::to_string(len) + std::string(", offset: ") + std::to_string(_offset) +
               std::string(", kind: ") + std::string(token_kind_repr()) + std::string(", val: \"") +
               std::string(val) + "\")";
    }

    bool Token::operator==(const Token &rhs) const {
        return (line == rhs.line && column == rhs.column && len == rhs.len &&
                _offset == rhs._offset && kind == rhs.kind && val == rhs.val &&
                filename == rhs.filename);
    }

    bool Token::operator==(const tokens &rhs) const { return (kind == rhs); }

    std::ostream &Token::operator<<(std::ostream &os) const { return os << to_string(); }

    Token &Token::operator+(const string &str) {
        this->val += str;
        return *this;
    }

    Token bare_token(tokens token_type, std::string value) {
        return Token(token_type,
                     "",
                     value.empty() ? std::string(tokens_map.at(token_type).value())
                                   : std::move(value));
    }
}  // __TOKEN_BEGIN

__TOKEN_N::Token operator+(const std::string &lhs, __TOKEN_N::Token rhs) {
    rhs.set_value(lhs + rhs.value());
    return rhs;
}

__TOKEN_N::Token operator+(__TOKEN_N::Token &lhs, const std::string &rhs) {
    lhs.set_value(lhs.value() + rhs);
    return lhs;
}
