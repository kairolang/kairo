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

#include <cstdint>
#include <iostream>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "neo-pprint/include/ansi_colors.hh"
#include "neo-pprint/include/hxpprint.hh"
#include "neo-types/include/hxint.hh"
#include "token/include/Token.hh"
#include "token/include/config/Token_config.def"
#include "token/include/private/Token_base.hh"
#include "token/include/private/Token_generate.hh"

__TOKEN_BEGIN {
    TokenList::TokenList(std::string filename)
        : filename(std::move(filename))
        , it(this->cbegin()) {}

    TokenList::TokenList(
        const std::string &filename, TokenVec::const_iterator start, TokenVec::const_iterator end)
        : TokenVec(start, end)
        , filename(filename) {}

    void TokenList::remove_left() {
        this->erase(this->cbegin(), it);
        it = this->cbegin();
    }

    void TokenList::reset() { it = this->cbegin(); }

    const std::string &TokenList::file_name() const { return filename; }

    TokenList TokenList::slice(const u64 start, i64 end) {
        if (start > static_cast<u64>(std::numeric_limits<i64>::max())) [[unlikely]] {
            throw std::out_of_range("start is greater than the maximum value of i64.");
        }

        if (end < 0) [[likely]] {
            end = static_cast<i64>(this->size());
        }

        if (end > static_cast<i64>(this->size())) [[unlikely]] {
            end = static_cast<i64>(this->size());
        }

        if (start > static_cast<u64>(std::numeric_limits<TokenVec::difference_type>::max()))
            [[unlikely]] {
            throw std::out_of_range("start of slice is greater than allowable range.");
        }

        if (static_cast<i64>(start) > end) [[unlikely]] {
            throw std::out_of_range("start of slice is greater than end.");
        }

        auto            start_index = static_cast<difference_type>(start);
        difference_type end_index   = end;

        return {this->filename, this->cbegin() + start_index, this->cbegin() + end_index};
    }

    void TokenList::remove(const token::Token &start, const token::Token &end) {
        auto start_it = std::find(this->cbegin(), this->cend(), start);
        auto end_it   = std::find(this->cbegin(), this->cend(), end);

        if (start_it == this->cend() || end_it == this->cend()) {
            throw std::out_of_range("Token not found in list");
        }

        this->erase(start_it, end_it);
    }

    TokenList TokenList::raw_slice(const u64 start, const i64 end) const {
        auto start_index = static_cast<TokenVec::difference_type>(start);
        auto end_index   = static_cast<TokenVec::difference_type>(end);

        return {this->filename, this->cbegin() + start_index, this->cbegin() + end_index};
    }

    /// @brief
    /// @param i Inclusive split
    /// @return first is the left side of the split and the second is the right
    std::pair<TokenList, TokenList> TokenList::split_at(const u64 i) const {
        auto      start_idx = static_cast<TokenVec::difference_type>(i);
        TokenList first{this->filename, this->cbegin(), cbegin() + start_idx};
        TokenList second{this->filename, this->cbegin() + start_idx, this->cend()};
        return {first, second};
    }

    TokenList TokenList::pop(const u64 offset) {

        auto diff = static_cast<TokenVec::difference_type>(offset);
        *this     = {this->filename, this->cbegin() + diff + 1, this->cend()};

        // TODO: Bounds Checks
        return {this->filename, this->cbegin(), this->cbegin() + diff};
    }

    const Token TokenList::pop_front() {
        if (this->empty()) {
            throw std::out_of_range("TokenList is empty");
        }

        const Token tok = this->front();
        this->erase(this->cbegin());
        return tok;
    }

    /**
     * @brief Replaces tokens in the list from start to end with the provided tokens.
     *
     * This function removes tokens from the specified start index up to, but not including,
     * the end index, and then inserts the tokens from the provided TokenList at the start index.
     *
     * @param tokens TokenList to insert.
     * @param start Start index of the range to remove.
     * @param end End index of the range to remove.
     */
    void TokenList::insert_remove(TokenList & tokens, u64 start, u64 end) {
        if (start > end || end > this->size()) {
            throw std::out_of_range("Invalid start or end index");
        }

        auto start_it = this->cbegin() + static_cast<TokenVec::difference_type>(start);
        auto end_it   = this->cbegin() + static_cast<TokenVec::difference_type>(end);

        this->erase(start_it, end_it);
        this->insert(start_it, tokens.cbegin(), tokens.cend());
    }

    void print_tokens(__TOKEN_N::TokenList & tokens) {
        std::uint16_t indent = 0;

        for (auto &tok : tokens) {
            if (tok->value() == "{") {
                indent++;
            } else if (tok->value() == "}") {
                indent--;
            }
            if (tok->token_kind() == __TOKEN_TYPES_N::PUNCTUATION_SEMICOLON ||
                tok->token_kind() == __TOKEN_TYPES_N::PUNCTUATION_OPEN_BRACE ||
                tok->token_kind() == __TOKEN_TYPES_N::PUNCTUATION_CLOSE_BRACE ||
                tok->token_kind() == __TOKEN_TYPES_N::PUNCTUATION_SINGLE_LINE_COMMENT) {
                if (tok->token_kind() != __TOKEN_TYPES_N::PUNCTUATION_CLOSE_BRACE) {
                    print("(",
                          colors::fg16::red,
                          __TOKEN_N::tokens_map.at(tok->token_kind()).value(),
                          colors::reset,
                          ", ",
                          colors::fg16::green,
                          tok->value(),
                          colors::reset,
                          ") ");
                }

                print("\n");
                print(std::string(static_cast<u16>(indent * 4), ' '));

                if (tok->token_kind() == __TOKEN_TYPES_N::PUNCTUATION_CLOSE_BRACE) {
                    print("(",
                          colors::fg16::red,
                          __TOKEN_N::tokens_map.at(tok->token_kind()).value(),
                          colors::reset,
                          ", ",
                          colors::fg16::green,
                          tok->value(),
                          colors::reset,
                          ") ");
                }

                continue;
            }
            print("(",
                  colors::fg16::red,
                  __TOKEN_N::tokens_map.at(tok->token_kind()).value(),
                  colors::reset,
                  ", ",
                  colors::fg16::green,
                  tok->value(),
                  colors::reset,
                  ") ");
        }

        print("\n");
    }

    bool TokenList::operator==(const TokenList &rhs) const {
        // First, compare sizes
        if (size() != rhs.size()) {
            return false;
        }

        // Then, compare each element
        for (size_t i = 0; i < size(); ++i) {
            if (at(i) != rhs.at(i)) {  // Assuming Token has operator==
                return false;
            }
        }

        return true;
    }

    bool TokenList::TokenListIter::operator!=(const TokenListIter &other) const {
        return cursor_position != other.cursor_position;
    }

    bool TokenList::TokenListIter::operator==(const TokenListIter &other) const {
        return cursor_position == other.cursor_position;
    }

    // FIXME : This is a temporary fix, need to change this to a  reference
    Token *TokenList::TokenListIter::operator->() {
        return &tokens.get()[cursor_position];
    }  // TODO: change if a shared ptr is needed

    TokenList::TokenListIter &TokenList::TokenListIter::operator*() { return *this; }

    const Token &TokenList::TokenListIter::operator*() const {
        return tokens.get()[cursor_position];
    }

    std::reference_wrapper<TokenList::TokenListIter> TokenList::TokenListIter::operator--() {
        if ((cursor_position - 1) >= 0) {
            --cursor_position;
            return *this;
        }

        throw std::out_of_range("access to token in token list is out of bounds");
    }

    std::reference_wrapper<TokenList::TokenListIter> TokenList::TokenListIter::operator++() {
        if ((cursor_position) <= end + 1) {
            ++cursor_position;
            return *this;
        }

        throw std::out_of_range("access to token in token list is out of bounds");
    }

    std::reference_wrapper<Token> TokenList::TokenListIter::advance(const i32 n) {
        if ((cursor_position + n) <= end + 1) {
            ++cursor_position;
        }

        if (n > 1) {
            return advance(n - 1);
        }

        return tokens.get()[cursor_position];
    }

    std::reference_wrapper<Token> TokenList::TokenListIter::reverse(const i32 n) {
        if ((cursor_position - n) >= 0) {
            --cursor_position;
        }

        if (n > 1) {
            return advance(n - 1);
        }

        return tokens.get()[cursor_position];
    }

    std::optional<std::reference_wrapper<Token>> TokenList::TokenListIter::peek(const i32 n) const {
        if ((cursor_position + n) <= end) {
            return tokens.get()[cursor_position + n];
        }

        return std::nullopt;
    }

    std::optional<std::reference_wrapper<Token>> TokenList::TokenListIter::peek_back(const i32 n)
        const {
        if ((cursor_position - n) >= 0) {
            return tokens.get()[cursor_position - n];
        }

        return std::nullopt;
    }

    std::reference_wrapper<Token> TokenList::TokenListIter::current() const {
        return tokens.get()[cursor_position];
    }

    TokenList TokenList::TokenListIter::remaining() {
        // Get the reference to the original TokenList
        auto &original_tokens = tokens.get();

        // Create a new TokenList starting from the current position to the end
        auto filename = original_tokens.file_name();
        auto start    = original_tokens.cbegin() + cursor_position;
        auto end      = original_tokens.cend();

        return {filename, start, end};
    }
}  // __TOKEN_BEGIN