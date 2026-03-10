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

#include "utils.hh"

CX_VISIT_IMPL(LiteralExpr) {
    enum class FloatRange {
        NONE,

        F32,
        F64,
        F80
    };

    auto determineFloatRange = [](const std::string &numStr) -> FloatRange {
        try {
            // Handle hexadecimal floating-point numbers (C++17)
            bool isHex = numStr.find("0x") == 0 || numStr.find("0X") == 0;

            // Parse as long double (highest precision available natively)
            char       *end;
            long double value = isHex ? std::strtold(numStr.c_str(), &end)   // Hexadecimal parsing
                                      : std::strtold(numStr.c_str(), &end);  // Standard parsing

            // Check if the entire string was parsed
            if (*end != '\0') {
                return FloatRange::NONE;  // Parsing failed
            }

            // Check range for float
            if (value >= -std::numeric_limits<float>::max() &&
                value <= std::numeric_limits<float>::max()) {
                return FloatRange::F32;
            }

            // Check range for double
            if (value >= -std::numeric_limits<double>::max() &&
                value <= std::numeric_limits<double>::max()) {
                return FloatRange::F64;
            }

            // Check range for long double
            if (value >= -std::numeric_limits<long double>::max() &&
                value <= std::numeric_limits<long double>::max()) {
                return FloatRange::F80;
            }

        } catch (...) {}

        return FloatRange::NONE;
    };

    auto add_literal = [&](const token::Token &tok) {
        /// we now need to cast the token to a specific type to avoid c++ inference issues
        /// all strings must be wrapped in `string()`
        /// all chars must be wrapped in `char()`
        /// numerics should be size checked and casted to the correct type
        /// bools, nulls, and compiler directives have no special handling
        bool inference = false;
        bool string_or_char = false;
        bool heap_int  = false;
        switch (tok.token_kind()) {
            case token::LITERAL_STRING:
                if (tok.value().starts_with("r")) {
                    break;
                }

                inference = true;
                string_or_char = true;
                ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "string", tok);
                ADD_TOKEN(CXX_LPAREN);
                break;
            case token::LITERAL_CHAR:
                inference = true;
                string_or_char = true;
                ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "wchar_t", tok);
                ADD_TOKEN(CXX_LPAREN);
                break;
            case token::LITERAL_FLOATING_POINT:
                inference = true;

                switch (determineFloatRange(tok.value())) {
                    case FloatRange::NONE:
                        ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "float", tok);
                        ADD_TOKEN(CXX_LPAREN);
                        break;
                    case FloatRange::F32:
                        ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "f32", tok);
                        ADD_TOKEN(CXX_LPAREN);
                        break;
                    case FloatRange::F64:
                        ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "f64", tok);
                        ADD_TOKEN(CXX_LPAREN);
                        break;
                    case FloatRange::F80:
                        ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "f80", tok);
                        ADD_TOKEN(CXX_LPAREN);
                        break;
                }

                break;

            case token::LITERAL_INTEGER:
                inference = true;

                switch (Int(tok.value()).determineRange()) {
                    case Int::IntRange::NONE:
                        inference = false;
                        heap_int  = true;
                        break;

                    // never infer unsigned types for literals
                    // always assume the smallest int is a i32 or larger
                    case Int::IntRange::U8:
                    case Int::IntRange::I8:
                    case Int::IntRange::U16:
                    case Int::IntRange::I16:
                    case Int::IntRange::U32:
                    case Int::IntRange::I32:
                        ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "i32", tok);
                        ADD_TOKEN(CXX_LPAREN);
                        break;
                    case Int::IntRange::U64:
                        ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "u64", tok);
                        ADD_TOKEN(CXX_LPAREN);
                        break;
                    case Int::IntRange::I64:
                        ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "i64", tok);
                        ADD_TOKEN(CXX_LPAREN);
                        break;
                    case Int::IntRange::U128:
                        ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "u128", tok);
                        ADD_TOKEN(CXX_LPAREN);
                        break;
                    case Int::IntRange::I128:
                        ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "i128", tok);
                        ADD_TOKEN(CXX_LPAREN);
                        break;
                    case Int::IntRange::U256:
                        ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "u256", tok);
                        ADD_TOKEN(CXX_LPAREN);
                        break;
                    case Int::IntRange::I256:
                        ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "i256", tok);
                        ADD_TOKEN(CXX_LPAREN);
                        break;
                }

                break;

            case token::LITERAL_TRUE:
            case token::LITERAL_FALSE:
            case token::LITERAL_NULL:
            case token::LITERAL_COMPILER_DIRECTIVE:
            default:
                break;
        }

        if (tok.value().starts_with("r")) {
            ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, tok.value().substr(1), tok);
        } else if (string_or_char) {
            ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_LITERAL, "L" + tok.value(), tok);
        } else {
            ADD_TOKEN_AS_TOKEN(CXX_CORE_LITERAL, tok);
        }

        if (inference) {
            ADD_TOKEN(CXX_RPAREN);
        } else if (heap_int) {
            ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "i", tok);
        }
    };

    if (node.contains_format_args) {
        // kairo::std::stringf(node.value, (format_arg)...)
        ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, "kairo");
        ADD_TOKEN(CXX_SCOPE_RESOLUTION);
        ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, "std");
        ADD_TOKEN(CXX_SCOPE_RESOLUTION);
        ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, "stringf");
        ADD_TOKEN(CXX_LPAREN);
        add_literal(node.value);
        ADD_TOKEN(CXX_COMMA);

        if (!node.format_args.empty()) {
            for (const auto &format_spec : node.format_args) {
                PAREN_DELIMIT(format_spec->accept(*this););
                ADD_TOKEN(CXX_COMMA);
            }

            tokens.pop_back();  // remove trailing comma
        } else { // since we added a comma a couple of lines above
            tokens.pop_back();  // remove trailing comma
        }

        ADD_TOKEN(CXX_RPAREN);

        return;
    }

    add_literal(node.value);
}
