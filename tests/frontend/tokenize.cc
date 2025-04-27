//===------------------------------------------ C++ ------------------------------------------====//
//                                                                                                //
//  Part of the Helix Project, under the Attribution 4.0 International license (CC BY 4.0).       //
//  You are allowed to use, modify, redistribute, and create derivative works, even for           //
//  commercial purposes, provided that you give appropriate credit, and indicate if changes       //
//   were made. For more information, please visit: https://creativecommons.org/licenses/by/4.0/  //
//                                                                                                //
//  SPDX-License-Identifier: CC-BY-4.0                                                            //
//  Copyright (c) 2024 (CC BY 4.0)                                                                //
//                                                                                                //
//====----------------------------------------------------------------------------------------====//

#include <catch2>
#include <string>
#include <string_view>

#include "lexer/include/lexer.hh"
#include "neo-panic/include/error.hh"
#include "token/include/private/Token_base.hh"
#include "token/include/private/Token_list.hh"

using namespace parser::lexer;

TEST_CASE("Test __TOKEN_N::Token constructor") {
    SECTION("Testing keyword 'if'") {
        __TOKEN_N::Token token(1, 1, 2, 0, "if", "<main>");

        REQUIRE(token.line_number() == 1);
        REQUIRE(token.column_number() == 1);
        REQUIRE(token.length() == 2);
        REQUIRE(token.offset() == 0);
        REQUIRE(token.token_kind() == __TOKEN_TYPES_N::KEYWORD_IF);
        REQUIRE(token.value() == "if");
    }

    SECTION("Testing identifier") {
        __TOKEN_N::Token token(1, 5, 8, 4, "variable", "<main>", "<id>");

        REQUIRE(token.line_number() == 1);
        REQUIRE(token.column_number() == 5);
        REQUIRE(token.length() == 8);
        REQUIRE(token.offset() == 4);
        REQUIRE(token.token_kind() == __TOKEN_TYPES_N::IDENTIFIER);
        REQUIRE(token.value() == "variable");
    }

    SECTION("Testing numeric literal") {
        __TOKEN_N::Token token(2, 3, 3, 15, "42", "<main>", "<int>");

        REQUIRE(token.line_number() == 2);
        REQUIRE(token.column_number() == 3);
        REQUIRE(token.length() == 3);
        REQUIRE(token.offset() == 15);
        REQUIRE(token.token_kind() == __TOKEN_TYPES_N::LITERAL_INTEGER);
        REQUIRE(token.value() == "42");
    }
}

TEST_CASE("Test Lexer tokenization", "[lexer::Lexer]") {
    SECTION("Basic tokenization") {
        std::string          source = "if (x > 0) { return true; }";
        Lexer                lexer(source, "<test>");
        __TOKEN_N::TokenList tokens = lexer.tokenize();

        REQUIRE(tokens.size() == 12);
        REQUIRE(tokens[0].token_kind() == __TOKEN_TYPES_N::KEYWORD_IF);
        REQUIRE(tokens[1].token_kind() == __TOKEN_TYPES_N::PUNCTUATION_OPEN_PAREN);
        REQUIRE(tokens[2].token_kind() == __TOKEN_TYPES_N::IDENTIFIER);
        REQUIRE(tokens[3].token_kind() == __TOKEN_TYPES_N::PUNCTUATION_CLOSE_ANGLE);
        REQUIRE(tokens[4].token_kind() == __TOKEN_TYPES_N::LITERAL_INTEGER);
        REQUIRE(tokens[5].token_kind() == __TOKEN_TYPES_N::PUNCTUATION_CLOSE_PAREN);
        REQUIRE(tokens[6].token_kind() == __TOKEN_TYPES_N::PUNCTUATION_OPEN_BRACE);
        REQUIRE(tokens[7].token_kind() == __TOKEN_TYPES_N::KEYWORD_RETURN);
        REQUIRE(tokens[8].token_kind() == __TOKEN_TYPES_N::LITERAL_TRUE);
        REQUIRE(tokens[9].token_kind() == __TOKEN_TYPES_N::PUNCTUATION_SEMICOLON);
        REQUIRE(tokens[10].token_kind() == __TOKEN_TYPES_N::PUNCTUATION_CLOSE_BRACE);
    }

    SECTION("Complex expression") {
        std::string          source = "var result = (a + b) * (c - d) / 2;";
        Lexer                lexer(source, "<test>");
        __TOKEN_N::TokenList tokens = lexer.tokenize();

        REQUIRE(tokens.size() == 18);
        REQUIRE(tokens[0].token_kind() == __TOKEN_TYPES_N::KEYWORD_LET);
        REQUIRE(tokens[1].token_kind() == __TOKEN_TYPES_N::IDENTIFIER);
        REQUIRE(tokens[2].token_kind() == __TOKEN_TYPES_N::OPERATOR_ASSIGN);
        REQUIRE(tokens[3].token_kind() == __TOKEN_TYPES_N::PUNCTUATION_OPEN_PAREN);
        REQUIRE(tokens[4].token_kind() == __TOKEN_TYPES_N::IDENTIFIER);
        REQUIRE(tokens[5].token_kind() == __TOKEN_TYPES_N::OPERATOR_ADD);
        REQUIRE(tokens[6].token_kind() == __TOKEN_TYPES_N::IDENTIFIER);
        REQUIRE(tokens[7].token_kind() == __TOKEN_TYPES_N::PUNCTUATION_CLOSE_PAREN);
        REQUIRE(tokens[8].token_kind() == __TOKEN_TYPES_N::OPERATOR_MUL);
        REQUIRE(tokens[9].token_kind() == __TOKEN_TYPES_N::PUNCTUATION_OPEN_PAREN);
        REQUIRE(tokens[10].token_kind() == __TOKEN_TYPES_N::IDENTIFIER);
        REQUIRE(tokens[11].token_kind() == __TOKEN_TYPES_N::OPERATOR_SUB);
        REQUIRE(tokens[12].token_kind() == __TOKEN_TYPES_N::IDENTIFIER);
        REQUIRE(tokens[13].token_kind() == __TOKEN_TYPES_N::PUNCTUATION_CLOSE_PAREN);
        REQUIRE(tokens[14].token_kind() == __TOKEN_TYPES_N::OPERATOR_DIV);
    }
}

TEST_CASE("Test Lexer error handling", "[lexer::Lexer]") {
    SECTION("Invalid character") {
        std::string source = "var x = $;";
        Lexer       lexer(source, "<test>");
        REQUIRE_THROWS_AS(lexer.tokenize(), error::Panic);
    }

    SECTION("Unclosed string literal") {
        std::string source = "var message = \"Hello, world;";
        Lexer       lexer(source, "<test>");
        REQUIRE_THROWS_AS(lexer.tokenize(), error::Panic);
    }

    SECTION("Invalid numeric literal") {
        std::string source = "var value = 3.14.15;";
        Lexer       lexer(source, "<test>");
        REQUIRE_THROWS_AS(lexer.tokenize(), error::Panic);
    }
}

TEST_CASE("Test Lexer whitespace handling", "[lexer::Lexer]") {
    SECTION("Mixed whitespace") {
        std::string          source = "  var   x\t=\n10;\n";
        Lexer                lexer(source, "<test>");
        __TOKEN_N::TokenList tokens = lexer.tokenize();

        REQUIRE(tokens.size() == 6);
        REQUIRE(tokens[0].token_kind() == __TOKEN_TYPES_N::KEYWORD_LET);
        REQUIRE(tokens[1].token_kind() == __TOKEN_TYPES_N::IDENTIFIER);
        REQUIRE(tokens[2].token_kind() == __TOKEN_TYPES_N::OPERATOR_ASSIGN);
        REQUIRE(tokens[3].token_kind() == __TOKEN_TYPES_N::LITERAL_INTEGER);
        REQUIRE(tokens[4].token_kind() == __TOKEN_TYPES_N::PUNCTUATION_SEMICOLON);
    }
}

TEST_CASE("Test Lexer comment handling", "[lexer::Lexer]") {
    SECTION("Single-line comment") {
        std::string          source = "var x = 5; // This is a comment\nvar y = 10;";
        Lexer                lexer(source, "<test>");
        __TOKEN_N::TokenList tokens = lexer.tokenize();

        REQUIRE(tokens.size() == 12);
        REQUIRE(tokens[3].token_kind() == __TOKEN_TYPES_N::LITERAL_INTEGER);
        REQUIRE(tokens[4].token_kind() == __TOKEN_TYPES_N::PUNCTUATION_SEMICOLON);
        REQUIRE(tokens[5].token_kind() == __TOKEN_TYPES_N::PUNCTUATION_SINGLE_LINE_COMMENT);
        REQUIRE(tokens[6].token_kind() == __TOKEN_TYPES_N::KEYWORD_LET);
    }

    SECTION("Multi-line comment") {
        std::string source = "var x = 5;\n/* This is a\nmulti-line comment */\nvar y = 10;";
        Lexer       lexer(source, "<test>");
        __TOKEN_N::TokenList tokens = lexer.tokenize();

        REQUIRE(tokens.size() == 12);
        REQUIRE(tokens[3].token_kind() == __TOKEN_TYPES_N::LITERAL_INTEGER);
        REQUIRE(tokens[4].token_kind() == __TOKEN_TYPES_N::PUNCTUATION_SEMICOLON);
        REQUIRE(tokens[5].token_kind() == __TOKEN_TYPES_N::PUNCTUATION_MULTI_LINE_COMMENT);
        REQUIRE(tokens[6].token_kind() == __TOKEN_TYPES_N::KEYWORD_LET);
    }
}

TEST_CASE("Test Lexer string literal handling", "[lexer::Lexer]") {
    SECTION("Simple string") {
        std::string          source = "var message = \"Hello, world!\";";
        Lexer                lexer(source, "<test>");
        __TOKEN_N::TokenList tokens = lexer.tokenize();

        REQUIRE(tokens.size() == 6);
        REQUIRE(tokens[3].token_kind() == __TOKEN_TYPES_N::LITERAL_STRING);
        REQUIRE(tokens[3].value() == "\"Hello, world!\"");
    }

    SECTION("String with escapes") {
        std::string          source = R"(var message = "Hello, \"world\"!";)";
        Lexer                lexer(source, "<test>");
        __TOKEN_N::TokenList tokens = lexer.tokenize();

        REQUIRE(tokens.size() == 6);
        REQUIRE(tokens[3].token_kind() == __TOKEN_TYPES_N::LITERAL_STRING);
        REQUIRE(tokens[3].value() == "\"Hello, \\\"world\\\"!\"");
    }
}

TEST_CASE("Test Lexer operator handling", "[lexer::Lexer]") {
    SECTION("Compound operators") {
        std::string          source = "a += b -= c *= d /= e %= f;";
        Lexer                lexer(source, "<test>");
        __TOKEN_N::TokenList tokens = lexer.tokenize();

        REQUIRE(tokens.size() == 13);
        REQUIRE(tokens[1].token_kind() == __TOKEN_TYPES_N::OPERATOR_ADD_ASSIGN);
        REQUIRE(tokens[3].token_kind() == __TOKEN_TYPES_N::OPERATOR_SUB_ASSIGN);
        REQUIRE(tokens[5].token_kind() == __TOKEN_TYPES_N::OPERATOR_MUL_ASSIGN);
        REQUIRE(tokens[7].token_kind() == __TOKEN_TYPES_N::OPERATOR_DIV_ASSIGN);
        REQUIRE(tokens[9].token_kind() == __TOKEN_TYPES_N::OPERATOR_MOD_ASSIGN);
    }

    SECTION("Comparison operators") {
        std::string          source = "a == b != c < d > e <= f >= g;";
        Lexer                lexer(source, "<test>");
        __TOKEN_N::TokenList tokens = lexer.tokenize();

        REQUIRE(tokens.size() == 15);
        REQUIRE(tokens[1].token_kind() == __TOKEN_TYPES_N::OPERATOR_EQUAL);
        REQUIRE(tokens[3].token_kind() == __TOKEN_TYPES_N::OPERATOR_NOT_EQUAL);
        REQUIRE(tokens[5].token_kind() == __TOKEN_TYPES_N::PUNCTUATION_OPEN_ANGLE);
        REQUIRE(tokens[7].token_kind() == __TOKEN_TYPES_N::PUNCTUATION_CLOSE_ANGLE);
        REQUIRE(tokens[9].token_kind() == __TOKEN_TYPES_N::OPERATOR_LESS_THAN_EQUALS);
        REQUIRE(tokens[11].token_kind() == __TOKEN_TYPES_N::OPERATOR_GREATER_THAN_EQUALS);
    }
}

TEST_CASE("Test Lexer numeric literal handling", "[lexer::Lexer]") {
    SECTION("Integer literals") {
        std::string          source = "var a = 42; var b = 0xFF; var c = 0b1010;";
        Lexer                lexer(source, "<test>");
        __TOKEN_N::TokenList tokens = lexer.tokenize();

        REQUIRE(tokens.size() == 16);
        REQUIRE(tokens[3].token_kind() == __TOKEN_TYPES_N::LITERAL_INTEGER);
        REQUIRE(tokens[3].value() == "42");
        REQUIRE(tokens[8].token_kind() == __TOKEN_TYPES_N::LITERAL_INTEGER);
        REQUIRE(tokens[8].value() == "0xFF");
        REQUIRE(tokens[13].token_kind() == __TOKEN_TYPES_N::LITERAL_INTEGER);
        REQUIRE(tokens[13].value() == "0b1010");
    }

    SECTION("Float literals") {
        std::string          source = "var a = 3.14; var b = 2.5e-3; var c = 0.5;";
        Lexer                lexer(source, "<test>");
        __TOKEN_N::TokenList tokens = lexer.tokenize();

        REQUIRE(tokens.size() == 16);
        REQUIRE(tokens[3].token_kind() == __TOKEN_TYPES_N::LITERAL_FLOATING_POINT);
        REQUIRE(tokens[3].value() == "3.14");
        REQUIRE(tokens[8].token_kind() == __TOKEN_TYPES_N::LITERAL_FLOATING_POINT);
        REQUIRE(tokens[8].value() == "2.5e-3");
        REQUIRE(tokens[13].token_kind() == __TOKEN_TYPES_N::LITERAL_FLOATING_POINT);
        REQUIRE(tokens[13].value() == "0.5");
    }
}

TEST_CASE("Test Lexer identifier handling", "[lexer::Lexer]") {
    SECTION("Valid identifiers") {
        std::string source = "var _var1 = 10; specialVar = 20; camelCase = 30; PascalCase = 40;";
        Lexer       lexer(source, "<test>");
        __TOKEN_N::TokenList tokens = lexer.tokenize();

        REQUIRE(tokens.size() == 18);
        REQUIRE(tokens[1].token_kind() == __TOKEN_TYPES_N::IDENTIFIER);
        REQUIRE(tokens[1].value() == "_var1");
        REQUIRE(tokens[5].token_kind() == __TOKEN_TYPES_N::IDENTIFIER);
        REQUIRE(tokens[5].value() == "specialVar");
        REQUIRE(tokens[9].token_kind() == __TOKEN_TYPES_N::IDENTIFIER);
        REQUIRE(tokens[9].value() == "camelCase");
        REQUIRE(tokens[13].token_kind() == __TOKEN_TYPES_N::IDENTIFIER);
        REQUIRE(tokens[13].value() == "PascalCase");
    }
}

TEST_CASE("Test Lexer keyword handling", "[lexer::Lexer]") {
    SECTION("Keywords") {
        std::string          source = "if else while for fn return var const class";
        Lexer                lexer(source, "<test>");
        __TOKEN_N::TokenList tokens = lexer.tokenize();

        REQUIRE(tokens.size() == 10);
        REQUIRE(tokens[0].token_kind() == __TOKEN_TYPES_N::KEYWORD_IF);
        REQUIRE(tokens[1].token_kind() == __TOKEN_TYPES_N::KEYWORD_ELSE);
        REQUIRE(tokens[2].token_kind() == __TOKEN_TYPES_N::KEYWORD_WHILE);
        REQUIRE(tokens[3].token_kind() == __TOKEN_TYPES_N::KEYWORD_FOR);
        REQUIRE(tokens[4].token_kind() == __TOKEN_TYPES_N::KEYWORD_FUNCTION);
        REQUIRE(tokens[5].token_kind() == __TOKEN_TYPES_N::KEYWORD_RETURN);
        REQUIRE(tokens[6].token_kind() == __TOKEN_TYPES_N::KEYWORD_LET);
        REQUIRE(tokens[7].token_kind() == __TOKEN_TYPES_N::KEYWORD_CONST);
        REQUIRE(tokens[8].token_kind() == __TOKEN_TYPES_N::KEYWORD_CLASS);
    }
}