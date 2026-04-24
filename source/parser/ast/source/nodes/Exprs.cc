//===------------------------------------------ C++ ------------------------------------------====//
//                                                                                                //
//  Part of the Kairo Project, under the Attribution 4.0 International license (CC BY 4.0). You   //
//  are allowed to use, modify, redistribute, and create derivative works, even for commercial    //
//  purposes, provided that you give appropriate credit, and indicate if changes                  //
//  were made. For more information, please visit: https://creativecommons.org/licenses/by/4.0/   //
//                                                                                                //
//  SPDX-License-Identifier: Apache-2.0// Copyright (c) 2024 (CC BY 4.0)                          //
//                                                                                                //
//====----------------------------------------------------------------------------------------====//
///                                                                                              ///
///  @file Expr.cc                                                                               ///
///  @brief This file contains the entire logic to parse expressions using a recursive descent   ///
///         parser. the parser adheres to an ll(1) grammar, which means it processes the input   ///
///         left-to-right and constructs the leftmost derivation using one token of lookahead.   ///
///                                                                                              ///
///  The parser is implemented using the `parse` method, which is a recursive descent parser     ///
///     that uses the token list to parse the expression grammar.                                ///
///                                                                                              ///
///  @code                                                                                       ///
///  Expression expr(tokens);                                                                    ///
///  ParseResult<> node = expr.parse();                                                          ///
///                                                                                              ///
///  if (node.has_value()) {                                                                     ///
///      NodeT<> ast = node.value();                                                             ///
///  } else {                                                                                    ///
///      std::cerr << node.error().what() << std::endl;                                          ///
///  }                                                                                           ///
///  @endcode                                                                                    ///
///                                                                                              ///
///  By default, the parser will parse the entire expression, but you can also parse a specific  ///
///     expression by calling the specific parse method. or get a specific node by calling parse ///
///     and then passing a template argument to the method.                                      ///
///                                                                                              ///
///  @code                                                                                       ///
///  Expression expr(tokens);                                                                    ///
///  ParseResult<BinaryExpr> node = expr.parse<BinaryExpr>();                                    ///
///  @endcode                                                                                    ///
///                                                                                              ///
/// The parser is implemented using the following grammar:                                       ///
///                                                                                              ///
/// STS *         /* node types */                                                               ///
/// [x] * Literal  * L                                                                           ///
/// [x] * Operator * O                                                                           ///
/// [x] * Token    * T                                                                           ///
///                                                                                              ///
///                          * helper nodes (not supposed to be explicitly used) */              ///
/// [x] * ArgumentListExpr   * AL -> ( AE? ( ',' AE )* )                                         ///
/// [x] * NamedArgumentExpr  * KA -> '.' ID '=' E                                                ///
/// [x] * ArgumentExpr       * AE -> E | ID '=' E                                                ///
/// [x] * MapPairExpr        * MP -> E ':' E                                                     ///
///                                                                                              ///
///                   /* primary nodes */                                                        ///
/// [x] * UnaryExpr    * UE  -> O    PE                                                          ///
/// [x] * BinaryExpr   * BE  -> UE   BE'                                                         ///
///                      BE' -> O UE BE' | ϵ                                                     ///
///                                                                                              ///
///                     /* core single associative */                                            ///
/// [x] * IdentExpr      * ID -> T                                                               ///
/// [x] * LiteralExpr    * LE -> L                                                               ///
///                                                                                              ///
///                       /* multi-associative */                                                ///
/// [x] * ScopePathExpr    * SA -> ID '::' ID                                                    ///
/// [x] * DotPathExpr      * DE -> PE '.'  ID                                                    ///
/// [x] * PathExpr         * PA -> SA | DE                                                       ///
///                                                                                              ///
/// [x] * TernaryExpr      * TE -> PE '?' E ':' E | PE 'if' E 'else' E                           ///
/// [x] * InstOfExpr       * IE -> PE ( 'has' | 'derives' ) ID                                   ///
/// [x] * CastExpr         * CE -> PE 'as' E                                                     ///
///                                                                                              ///
/// [x] * ArrayAccessExpr  * AA -> PE '[' E ']'                                                  ///
/// [x] * FunctionCallExpr * FC -> PA GI? AL                                                     ///
///                                                                                              ///
///                            /* right associative recursive */                                 ///
/// [x] * ObjInitExpr           * OI -> '{' ( KA ( ',' KA )* )? '}'                              ///
/// [x] * SetLiteralExpr        * SE -> '{' E ( ',' E )* '}'                                     ///
/// [x] * TupleLiteralExpr      * TL -> '(' E ( ',' E )* ')'                                     ///
/// [x] * ArrayLiteralExpr      * AE -> '[' E ( ',' E )* ']'                                     ///
/// [x] * ParenthesizedExpr     * PAE -> '(' E? ')'                                              ///
///                                                                                              ///
/// [x] * AsyncExpr                 * AS -> ('spawn' | 'thread') E                               ///
/// [x] * AwaitExpr                 * AS -> 'await' E                                            ///
/// [ ] * ContextManagerExpr        * CM -> E 'as' ID Suite                                      ///
/// [x] * LambdaExpr                * LE -> 'fn' TODO                                            ///
///                                                                                              ///
///                                /* generics */                                                ///
/// [ ] * GenericInvokeExpr         * GI -> '<' TY? ( ',' TY )* '>'                              ///
///                                                                                              ///
///                                                                                              ///
/// [x] * Type    * TY -> ID | PA | SE | TL | OI | AE | PAE                                      ///
///                                                                                              ///
///    /* complete parser */                                                                     ///
/// [x] * PE -> LE | ID | AE | SE | TL | OI | PA | PAE                                           ///
/// [x] * E  -> PE | UE | BE | TE | CE | IE | AA | FC                                            ///
///                                                                                              ///
/// TODO: big problem: the parser needs to be able to parse generics in the context of exprs,    ///
///          since doing something like `foo<int>` is a valid expression. This is not currently  ///
///          supported. a better example would be:                                               ///
///                                                                                              ///
///       @code                                                                                  ///
///       fn PI() static const eval -> T requires <T> = T(3.1415926535);                       ///
///       let x: int = PI<int>;                                                                  ///
///       @endcode                                                                               ///
///                                                                                              ///
///       this is a valid expression, but how do we parse it?                                    ///
///          how can we parse the `PI<int>` and not confuse it with a BinaryExpr like            ///
///          `PI < int`? and the > becoming a syntax error?                                      ///
///                                                                                              ///
/// TODO: add support for async keywords, 'await', 'spawn', 'thread'                             ///
/// TODO: add support for 'match' expressions                                                    ///
///                                                                                              ///
//===-----------------------------------------------------------------------------------------====//

#include <expected>
#include <memory>
#include <unordered_set>
#include <vector>

#include "lexer/include/lexer.hh"
#include "neo-panic/include/error.hh"
#include "neo-pprint/include/hxpprint.hh"
#include "parser/ast/include/config/AST_config.def"
#include "parser/ast/include/nodes/AST_declarations.hh"
#include "parser/ast/include/nodes/AST_expressions.hh"
#include "parser/ast/include/private/AST_generate.hh"
#include "parser/ast/include/private/base/AST_base_declaration.hh"
#include "parser/ast/include/private/base/AST_base_expression.hh"
#include "parser/ast/include/types/AST_jsonify_visitor.hh"
#include "parser/ast/include/types/AST_modifiers.hh"
#include "parser/ast/include/types/AST_types.hh"
#include "token/include/config/Token_cases.def"
#include "token/include/config/Token_config.def"
#include "token/include/private/Token_generate.hh"
#include "token/include/private/Token_list.hh"

// ---------------------------------------------------------------------------------------------- //

bool is_excepted(const __TOKEN_N::Token &tok, const std::unordered_set<__TOKEN_TYPES_N> &tokens);
int  get_precedence(const __TOKEN_N::Token &tok);

bool is_function_specifier(const __TOKEN_N::Token &tok);
bool is_function_qualifier(const __TOKEN_N::Token &tok);
bool is_storage_specifier(const __TOKEN_N::Token &tok);
bool is_access_specifier(const __TOKEN_N::Token &tok);
bool is_type_qualifier(const __TOKEN_N::Token &tok);
bool is_ffi_specifier(const __TOKEN_N::Token &tok);

// ---------------------------------------------------------------------------------------------- //

AST_BASE_IMPL(Expression, parse_primary) {  // NOLINT(readability-function-cognitive-complexity)
    IS_NOT_EMPTY;

    __TOKEN_N::Token tok = CURRENT_TOK;
    ParseResult<>    node;

    if (is_excepted(tok, IS_LITERAL)) {
        node = parse<LiteralExpr>();
    } else if (is_excepted(tok, IS_IDENTIFIER)) {
        node = parse<IdentExpr>();

        if (CURRENT_TOK == __TOKEN_N::OPERATOR_SCOPE) {
            node = parse<ScopePathExpr>(node);
        } else if (CURRENT_TOK == __TOKEN_N::PUNCTUATION_DOT) {
            node = parse<DotPathExpr>(node);
        }
    } else if (is_excepted(tok, IS_UNARY_OPERATOR)) {
        node = parse<UnaryExpr>();
    } else if (is_excepted(tok, IS_PUNCTUATION)) {
        if (tok.token_kind() ==
            __TOKEN_N::PUNCTUATION_OPEN_PAREN) {  /// at this point we either have a tuple or a
                                                  /// parenthesized expression, so we need to do
                                                  /// further analysis to determine which one it
                                                  /// is
            iter.advance();                       /// skip '('

            if (CURRENT_TOK.token_kind() == __TOKEN_N::PUNCTUATION_CLOSE_PAREN) {
                return std::unexpected(
                    PARSE_ERROR_MSG("tuple literals must have at least one element, for a blank "
                                    "tuples are not allowed."));
            }

            ParseResult<> expr = parse();
            RETURN_IF_ERROR(expr);

            if (CURRENT_TOK == __TOKEN_N::PUNCTUATION_COMMA) {  /// if the next token is a
                                                                /// comma, then its a tuple
                node = parse<TupleLiteralExpr>(expr);
            } else {
                node = parse<ParenthesizedExpr>(expr);
            }
        } else if (tok.token_kind() == __TOKEN_N::PUNCTUATION_OPEN_BRACKET) {
            node = parse<ArrayLiteralExpr>();
        } else if (tok.token_kind() == __TOKEN_N::PUNCTUATION_OPEN_BRACE) {
            /// heres its either a set, a map or an object
            /// initializer, to determine which one it is, its
            /// quite simple we need to check if the next
            /// token is a '.' which if it is, then its an
            /// object initializer otherwise we parse E(1) and
            /// check if the next token is a ':', if it is,
            /// then its a map otherwise its a set
            /// we also have to make sure the prev node type is an expr

            iter.advance();  // skip '{' only thing allowed is either, a map, a set or an obj init

            if (CURRENT_TOK.token_kind() == __TOKEN_N::PUNCTUATION_CLOSE_BRACE) {
                if (iter.peek_back(2).has_value() &&
                    iter.peek_back(2).value().get() != __TOKEN_N::IDENTIFIER) {
                    return std::unexpected(PARSE_ERROR_MSG(
                        "blank brace expressions are disallowed due to ambiguity in "
                        "parsing. This behavior will be allowed in the future."));
                }
            } else if (CURRENT_TOK == __TOKEN_N::PUNCTUATION_DOT) {
                node = parse<ObjInitExpr>(true);
            } else {
                ParseResult<> first = parse();
                RETURN_IF_ERROR(first);

                if (CURRENT_TOK == __TOKEN_N::PUNCTUATION_COLON) {
                    node = parse<MapLiteralExpr>(first);
                } else {  // we dont check for a comma since {1} is a valid set
                    node = parse<SetLiteralExpr>(first);
                }
            }
        } else {
            if (tok.token_kind() != __TOKEN_N::PUNCTUATION_SEMICOLON) {
                return std::unexpected(
                    PARSE_ERROR_MSG("Expected an expression, but found nothing"));
            }
        }
    } else if (tok.token_kind() == __TOKEN_N::KEYWORD_FUNCTION) {
        node = parse<LambdaExpr>();
    } else if (is_excepted(tok,
                           {__TOKEN_N::KEYWORD_THREAD,
                            __TOKEN_N::KEYWORD_SPAWN,
                            __TOKEN_N::KEYWORD_AWAIT})) {
        node = parse<AsyncThreading>();
    } else if (tok.token_kind() == __TOKEN_N::OPERATOR_SCOPE) {
        node = parse<ScopePathExpr>(nullptr, true);
    } else if (tok.token_kind() == __TOKEN_N::KEYWORD_INLINE) {
        node = parse<InlineBlockExpr>();
    } else {
        return std::unexpected(
            PARSE_ERROR_MSG("Expected an expression, but found an unexpected token '" +
                            CURRENT_TOK.token_kind_repr() + "'"));
    }

    return node;
}

// ---------------------------------------------------------------------------------------------- //

parser ::ast ::ParseResult<> parser::ast::node::Expression::parse(
    bool in_requires, int min_precedence) {  // NOLINT(readability-function-cognitive-complexity)
    IS_NOT_EMPTY;        /// simple macro to check if the iterator is empty, expands to:
                         /// if(iter.remaining_n() == 0) { return std::unexpected(...); }

    __TOKEN_N::Token tok;
    size_t           iter_n = 0;
    size_t n_max = iter.remaining_n() << 1;  /// this is a way to approx the tokens to parse, and is
                                             /// used to prevent the parser from going into an
                                             /// infinite loop  if the expression is malformed, this
                                             /// is a simple way to prevent stack overflows and
                                             /// memory exhaustion
    bool          continue_loop = true;
    ParseResult<> expr = parse_primary();  /// E(1) - this is always the first expression in the
                                           /// expression, we then build compound expressions from
                                           /// this

    RETURN_IF_ERROR(expr);  /// simple macro to return if the expression is an error expands to:
                            /// if (!expr.has_value()) { return std::unexpected(expr.error()); }

    /// parsed above, but now we need way to limit the number of times we can loop since if we have
    /// a really really long expression, we could end up in an memory exhaustion situation or a
    /// stack overflow situation. /* TODO */
    for (; iter_n < n_max && continue_loop; iter_n++) {  /// this is a simple loop that will
                                                         /// continue to loop until we have parsed
                                                         /// all the tokens in the expression, the
                                                         /// expression

        tok = CURRENT_TOK;  /// simple macro to get the current token expands to:
                            /// CURRENT_TOK

        switch (tok.token_kind()) {
                // case __TOKEN_N::PUNCTUATION_OPEN_ANGLE:  /// what to do if its ident '<' parms
                //                                      /// '>' '(' args ')' its now either a
                //                                      /// function call w a generic or its a
                //                                      /// binary expression may god help me
                //     NOT_IMPLEMENTED;
                // SOLUTION: turbofish syntax

            case __TOKEN_N::PUNCTUATION_OPEN_PAREN:
                expr = parse<FunctionCallExpr>(expr);
                RETURN_IF_ERROR(expr);
                break;

            case __TOKEN_N::PUNCTUATION_OPEN_BRACKET:
                expr = parse<ArrayAccessExpr>(expr);
                RETURN_IF_ERROR(expr);
                break;

            case __TOKEN_N::PUNCTUATION_DOT:
                expr = parse<DotPathExpr>(expr);
                RETURN_IF_ERROR(expr);
                break;

            case __TOKEN_N::OPERATOR_SCOPE:
                if (HAS_NEXT_TOK && NEXT_TOK == __TOKEN_N::PUNCTUATION_OPEN_ANGLE) {
                    iter.advance();  // skip '::'

                    ParseResult<GenericInvokeExpr> gen_expr = parse<GenericInvokeExpr>();
                    RETURN_IF_ERROR(gen_expr);

                    expr = parse<FunctionCallExpr>(expr, gen_expr.value());
                    RETURN_IF_ERROR(expr);
                } else {
                    expr = parse<ScopePathExpr>(expr);
                    RETURN_IF_ERROR(expr);
                }
                break;

            case __TOKEN_N::PUNCTUATION_OPEN_BRACE:
                if (iter.peek().has_value() && (iter.peek().value().get().token_kind() ==
                                                __TOKEN_TYPES_N::PUNCTUATION_CLOSE_BRACE)) {
                    if (ObjInitExpr::is_allowed(expr->get()->getNodeType())) {
                        expr = parse<ObjInitExpr>(false, expr);
                        RETURN_IF_ERROR(expr);
                    }  // blank obj init

                    break;
                }

                if (iter.peek().has_value() &&
                    (iter.peek().value().get().token_kind() != __TOKEN_TYPES_N::IDENTIFIER)) {
                        continue_loop = false;
                    break;
                }

                if (iter.peek(2).has_value() &&
                    iter.peek(2).value().get().token_kind() != __TOKEN_TYPES_N::PUNCTUATION_COLON) {
                    continue_loop = false;
                    break;
                }

                if (ObjInitExpr::is_allowed(expr->get()->getNodeType())) {
                    expr = parse<ObjInitExpr>(false, expr);
                    RETURN_IF_ERROR(expr);
                } else {
                    continue_loop = false;
                }

                break;

            case __TOKEN_N::KEYWORD_IMPL:
            case __TOKEN_N::KEYWORD_DERIVES:
                expr = parse<InstOfExpr>(expr, in_requires);
                RETURN_IF_ERROR(expr);
                break;

            // c-style ternary operator are not allowed, only python style ternary operators
            case __TOKEN_N::KEYWORD_IF:
                expr = parse<TernaryExpr>(expr);
                RETURN_IF_ERROR(expr);
                break;

            case __TOKEN_N::KEYWORD_AS:
                expr = parse<CastExpr>(expr);
                RETURN_IF_ERROR(expr);
                break;

            case __TOKEN_N::LITERAL_CHAR:
            case __TOKEN_N::LITERAL_STRING:
                expr = parse<LiteralExpr>(expr);
                RETURN_IF_ERROR(expr);
                break;

            default:
                if (is_excepted(tok, IS_BINARY_OPERATOR)) {
                    if (get_precedence(tok) <= min_precedence) {
                        continue_loop = false;
                        break;
                    }
                    expr = parse<BinaryExpr>(expr, get_precedence(tok));
                    RETURN_IF_ERROR(expr);
                } else if (is_excepted(tok, IS_UNARY_OPERATOR)) {
                    expr = parse<UnaryExpr>(expr);
                    RETURN_IF_ERROR(expr);
                } else if (tok == __TOKEN_N::PUNCTUATION_OPEN_PAREN) {
                    iter.advance();                         // skip '('
                    expr = parse<ParenthesizedExpr>(expr);  /// im not sure why this works, but
                                                            /// based on small tests, it seems
                                                            /// to work fine i'll find out soon
                                                            /// enough if it doesn't
                    RETURN_IF_ERROR(expr);
                } else {
                    continue_loop = false;
                }
        }
    }

    if (iter_n >= n_max) {
        return std::unexpected(PARSE_ERROR_MSG("expression is too long"));
    }

    return expr;
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Expression, InlineBlockExpr) {
    IS_NOT_EMPTY;

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_INLINE);
    auto marker = CURRENT_TOK;
    iter.advance();

    IS_EXCEPTED_TOKEN(__TOKEN_N::LITERAL_STRING);
    __TOKEN_N::Token lang = CURRENT_TOK;
    iter.advance();

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_OPEN_BRACE);
    u32 last_end = CURRENT_TOK.offset() + CURRENT_TOK.length();
    iter.advance();

    int depth = 1;
    std::string raw_content;
    u32 prev_line = CURRENT_TOK.line_number();
    u32 prev_col  = 0;
    u32 prev_len  = 0;

    __TOKEN_N::Token first_content_tok = marker;
    bool captured_first = false;

    while (depth > 0 && iter.remaining_n() > 0) {
        __TOKEN_N::Token cur = CURRENT_TOK;

        if (cur.token_kind() == __TOKEN_N::PUNCTUATION_OPEN_BRACE) {
            depth++;
        } else if (cur.token_kind() == __TOKEN_N::PUNCTUATION_CLOSE_BRACE) {
            depth--;
            if (depth == 0) break;
        }

        if (!captured_first) {
            first_content_tok = cur;
            captured_first = true;
        }

        u32 cur_line = cur.line_number();
        u32 cur_col = cur.column_number();

        if (prev_line == 0) {
            // first token, no prefix
        } else if (cur_line > prev_line) {
            // new line(s)
            for (u32 i = 0; i < cur_line - prev_line; i++) {
                raw_content += '\n';
            }
            // indent to column
            for (u32 i = 1; i < cur_col; i++) {
                raw_content += ' ';
            }
        } else {
            // same line, fill gap
            u32 expected_col = prev_col + prev_len;
            if (cur_col > expected_col) {
                for (u32 i = 0; i < cur_col - expected_col; i++) {
                    raw_content += ' ';
                }
            }
        }

        raw_content += cur.value();
        prev_line = cur_line;
        prev_col = cur_col;
        prev_len = cur.length();
        iter.advance();
    }

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_CLOSE_BRACE);
    iter.advance();

    __TOKEN_N::Token content(token::tokens::LITERAL_STRING, raw_content, first_content_tok);
    return make_node<InlineBlockExpr>(lang, content);
}

AST_NODE_IMPL_VISITOR(Jsonify, InlineBlockExpr) {
    json.section("InlineBlockExpr")
        .add("lang", node.lang)
        .add("content", node.content);
}

// make a parse f-string method to parse f"string {expr} string"

AST_NODE_IMPL(Expression, LiteralExpr, ParseResult<> str_concat) {
    IS_NOT_EMPTY;

    __TOKEN_N::Token tok = CURRENT_TOK;  // get tokens[0]
    iter.advance();                      // pop tokens[0]

    LiteralExpr::LiteralType type{};

    IS_NOT_NULL_RESULT(str_concat) {
        if (str_concat.value()->getNodeType() != nodes::LiteralExpr ||
            as<LiteralExpr>(str_concat.value())->type != LiteralExpr::LiteralType::String) {
            return std::unexpected(PARSE_ERROR(tok, "expected a string literal"));
        }

        NodeT<LiteralExpr> str = as<LiteralExpr>(str_concat.value());

        if (tok.token_kind() != __TOKEN_N::LITERAL_STRING) {
            return std::unexpected(PARSE_ERROR(tok, "expected a string literal"));
        }

        str->value.set_value(str->value.value() + tok.value());
        return str;
    }

    switch (tok.token_kind()) {
        case __TOKEN_N::LITERAL_INTEGER:
            type = LiteralExpr::LiteralType::Integer;
            break;
        case __TOKEN_N::LITERAL_FLOATING_POINT:
            type = LiteralExpr::LiteralType::Float;
            break;
        case __TOKEN_N::LITERAL_STRING:
            type = LiteralExpr::LiteralType::String;
            if (tok.value().length() > 0 && (tok.value()[0] == 'f' && tok.value()[1] == '"')) {
                tok.get_column_number() -= 1;  // minus 1 to account for the "f" in the string
            }
            break;
        case __TOKEN_N::LITERAL_CHAR:
            type = LiteralExpr::LiteralType::Char;
            break;
        case __TOKEN_N::LITERAL_TRUE:
        case __TOKEN_N::LITERAL_FALSE:
            type = LiteralExpr::LiteralType::Boolean;
            break;
        case __TOKEN_N::LITERAL_NULL:
            type = LiteralExpr::LiteralType::Null;
            break;
        default:
            return std::unexpected(
                PARSE_ERROR(tok, "expected a literal. but found: " + tok.token_kind_repr()));
    }

    NodeT<LiteralExpr> node = make_node<LiteralExpr>(tok, type);

    std::string base_string = tok.value();

    if (base_string.length() > 0 &&
        (base_string[0] == 'f' && base_string[1] == '"')) {  // check if its a f-string
        // remove the "f" from the string.
        std::string formatted_string = base_string.substr(1);

        // vector of (offset to the "{", offset to the "}"), ignoring any "\{" or "\}"
        std::vector<std::pair<size_t, size_t>> f_string_elements;

        bool   prev_is_backslash = false;
        size_t start             = std::string::npos;
        int    open_braces       = 0;

        for (size_t pos = 0; pos < formatted_string.size(); ++pos) {
            switch (formatted_string[pos]) {
                case '\\':
                    prev_is_backslash = !prev_is_backslash;
                    continue;

                case '{':
                    if (!prev_is_backslash) {
                        if (open_braces == 0) {
                            start = pos + 1;
                        }

                        open_braces++;
                    }

                    prev_is_backslash = false;
                    continue;

                case '}':
                    if (!prev_is_backslash) {
                        open_braces--;

                        if (open_braces == 0 && start != std::string::npos) {
                            if (pos == start) {
                                return std::unexpected(PARSE_ERROR(
                                    tok,
                                    "blank f-strings are not allowed, use \"\\{\\}\" if meant to "
                                    "have unformatted braces."));
                            }

                            f_string_elements.emplace_back(start, pos - start);
                            start = std::string::npos;

                        } else if (open_braces < 0) {
                            return std::unexpected(
                                PARSE_ERROR(tok, "malformed f-string, unterminated \"}\"."));
                        }
                    }

                    prev_is_backslash = false;
                    continue;

                default:
                    prev_is_backslash = false;
                    break;
            }
        }

        // check if there's any unmatched opening brace.
        if (open_braces != 0) {
            return std::unexpected(PARSE_ERROR(tok, "malformed f-string, unterminated \"}\"."));
        }

        std::vector<std::pair<size_t, size_t>> original_copy = f_string_elements;

        if (!f_string_elements
                 .empty()) {  // if there is no f-string elements, then we dont need to do anything
            for (size_t i = 0; i < f_string_elements.size(); ++i) {
                // start a tokenizer instance to process f-string elemets
                parser::lexer::Lexer lexer(formatted_string.substr(f_string_elements[i].first,
                                                                   f_string_elements[i].second),
                                           tok.file_name(),
                                           tok.line_number(),
                                           tok.column_number() + original_copy[i].first,
                                           tok.offset() + original_copy[i].first);

                // remove the section of formatted_string
                formatted_string.erase(f_string_elements[i].first, f_string_elements[i].second);

                // update the position of all the elements after the current one
                for (auto &f_string_element_ : f_string_elements) {
                    if (f_string_element_.first > f_string_elements[i].first) {
                        f_string_element_.first -= f_string_elements[i].second;
                    }
                }

                // lex the substring
                __TOKEN_N::TokenList tokens = lexer.tokenize();

                // pre-process
                // ...

                // make a ast generator
                auto       iter = tokens.begin();
                Expression _expr_parser(iter);

                // parse ast to identify syntax errors
                ParseResult<> parse = _expr_parser.parse();

                // check if any errors were emitted and if so return
                if (!parse || !parse.has_value()) {
                    return std::unexpected(parse.error());
                }

                node->format_args.emplace_back(parse.value());
            }
        } else {
            // if there are no f-string elements, then we can just remove the "f" from the string
            // since its just a normal string
            formatted_string = base_string.substr(1);
        }

        // Convert only "\{" to "\\{" and "\}" to "\\}"
        for (size_t i = 0; i < formatted_string.size(); ++i) {
            if (formatted_string.substr(i, 2) == "\\{") {
                formatted_string.insert(i, "\\");
                i += 2;
                continue;
            }

            if (formatted_string.substr(i, 2) == "\\}") {
                formatted_string.insert(i, "\\");
                i += 2;
                continue;
            }
        }

        node->value.get_value()    = formatted_string;
        node->contains_format_args = true;
    }

    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, LiteralExpr) {
    std::vector<neo::json> args;

    if (node.contains_format_args && !node.format_args.empty()) {
        for (const auto &arg : node.format_args) {
            args.push_back(get_node_json(arg));
        }
    }

    json.section("LiteralExpr")
        .add("value", node.value)
        .add("format_args", args)
        .add("contains_format_args", ((node.contains_format_args) ? "true" : "false"))
        .add("type", (int)node.getNodeType());
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Expression, BinaryExpr, ParseResult<> lhs, int min_precedence) {
    IS_NOT_EMPTY;

    // := E op E
    // TODO if E(2) does not exist, check if its a & | * token, since if it is,
    // then return a unary expression since its a pointer or reference type

    __TOKEN_N::Token tok = CURRENT_TOK;

    while (is_excepted(tok, IS_BINARY_OPERATOR) && get_precedence(tok) >= min_precedence) {
        int              precedence = get_precedence(tok);
        __TOKEN_N::Token op         = tok;

        iter.advance();

        ParseResult<> rhs = parse(false, precedence);
        RETURN_IF_ERROR(rhs);

        tok = CURRENT_TOK;
        while (is_excepted(tok, IS_BINARY_OPERATOR) && get_precedence(tok) > precedence) {
            rhs = parse<BinaryExpr>(rhs, get_precedence(tok));
            RETURN_IF_ERROR(rhs);
            tok = CURRENT_TOK;
        }

        lhs = make_node<BinaryExpr>(lhs.value(), rhs.value(), op);
    }

    return as<BinaryExpr>(lhs.value());
}

AST_NODE_IMPL_VISITOR(Jsonify, BinaryExpr) {
    json.section("BinaryExpr")
        .add("lhs", get_node_json(node.lhs))
        .add("op", node.op)
        .add("rhs", get_node_json(node.rhs));
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Expression, UnaryExpr, ParseResult<> lhs, bool in_type) {
    IS_NOT_EMPTY;

    // := op E | E op

    IS_IN_EXCEPTED_TOKENS(IS_UNARY_OPERATOR);
    __TOKEN_N::Token op = CURRENT_TOK;
    iter.advance();  // skip the op

    IS_NULL_RESULT(lhs) {
        ParseResult<> rhs = in_type ? parse<Type>() : parse();
        RETURN_IF_ERROR(rhs);

        if (rhs.value()->getNodeType() == nodes::UnaryExpr) {
            NodeT<UnaryExpr> rhs_unary = as<UnaryExpr>(rhs.value());
            rhs_unary->in_type         = in_type;

            return make_node<UnaryExpr>(rhs_unary, op, UnaryExpr::PosType::PreFix, in_type);
        }

        return make_node<UnaryExpr>(rhs.value(), op, UnaryExpr::PosType::PreFix, in_type);
    }

    return make_node<UnaryExpr>(lhs.value(), op, UnaryExpr::PosType::PostFix, in_type);
}

AST_NODE_IMPL_VISITOR(Jsonify, UnaryExpr) {
    json.section("UnaryExpr")
        .add("operand", get_node_json(node.opd))
        .add("op", node.op)
        .add("type", (int)node.type);
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Expression, IdentExpr) {
    IS_NOT_EMPTY;

    // verify the current token is an identifier
    __TOKEN_N::Token tok                   = CURRENT_TOK;
    bool             is_reserved_primitive = false;

    IS_IN_EXCEPTED_TOKENS(IS_IDENTIFIER);

    if (tok.token_kind() != __TOKEN_N::IDENTIFIER) {
        is_reserved_primitive = true;
    }

    iter.advance();  // pop the token
    return make_node<IdentExpr>(tok, is_reserved_primitive);
}

AST_NODE_IMPL_VISITOR(Jsonify, IdentExpr) { json.section("IdentExpr", node.name); }

// ---------------------------------------------------------------------------------------------- //

// should not be called by `parse` directly as it is a helper function
AST_NODE_IMPL(Expression, NamedArgumentExpr, bool is_anonymous, bool in_obj_init) {
    IS_NOT_EMPTY;

    // := '.'? IdentExpr '=' E
    if (is_anonymous) {
        IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_DOT);
        iter.advance();  // skip '.'
    } else {
        IS_NOT_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_DOT);
    }

    ParseResult<IdentExpr> name = parse<IdentExpr>();
    RETURN_IF_ERROR(name);

    if (in_obj_init) {
        IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_COLON);
        iter.advance();  // skip ':'
    } else {
        IS_EXCEPTED_TOKEN(__TOKEN_N::OPERATOR_ASSIGN);
        iter.advance();  // skip '='
    }

    ParseResult<> value = parse();
    RETURN_IF_ERROR(value);

    return make_node<NamedArgumentExpr>(name.value(), value.value());
}

AST_NODE_IMPL_VISITOR(Jsonify, NamedArgumentExpr) {
    json.section("NamedArgumentExpr")
        .add("name", get_node_json(node.name))
        .add("value", get_node_json(node.value));
}

// ---------------------------------------------------------------------------------------------- //

// should not be called by `parse` directly as it is a helper function
AST_NODE_IMPL(Expression, ArgumentExpr) {
    IS_NOT_EMPTY;

    NodeT<ArgumentExpr> result;

    ParseResult<> lhs = parse();  // E(1)
    RETURN_IF_ERROR(lhs);

    NodeT<> lhs_node = lhs.value();

    if (lhs_node->getNodeType() == nodes::BinaryExpr) {
        NodeT<BinaryExpr> bin_expr = as<BinaryExpr>(lhs_node);

        if (bin_expr->lhs->getNodeType() == nodes::IdentExpr &&
            bin_expr->op.token_kind() == __TOKEN_N::OPERATOR_ASSIGN) {

            NodeT<NamedArgumentExpr> kwarg =
                make_node<NamedArgumentExpr>(as<IdentExpr>(bin_expr->lhs), bin_expr->rhs);

            result       = make_node<ArgumentExpr>(kwarg);
            result->type = ArgumentExpr::ArgumentType::Keyword;

            return result;
        }
    }

    result       = make_node<ArgumentExpr>(lhs_node);
    result->type = ArgumentExpr::ArgumentType::Positional;

    return result;
}

AST_NODE_IMPL_VISITOR(Jsonify, ArgumentExpr) {
    json.section("ArgumentExpr")
        .add("type", (int)node.type)
        .add("value", get_node_json(node.value));
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Expression, ArgumentListExpr) {
    IS_NOT_EMPTY;

    // := '(' ArgumentExpr (',' ArgumentExpr)* ')'
    // in typical recursive descent fashion, we parse the first argument expression

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_OPEN_PAREN);
    iter.advance();  // skip '('

    if CURRENT_TOKEN_IS (__TOKEN_N::PUNCTUATION_CLOSE_PAREN) {
        iter.advance();  // skip ')'
        return make_node<ArgumentListExpr>(nullptr);
    }

    ParseResult<ArgumentExpr> first = parse<ArgumentExpr>();
    RETURN_IF_ERROR(first);

    NodeT<ArgumentListExpr> args = make_node<ArgumentListExpr>(first.value());

    while
        CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_COMMA) {
            iter.advance();  // skip ','

            ParseResult<ArgumentExpr> arg = parse<ArgumentExpr>();
            RETURN_IF_ERROR(arg);

            args->args.push_back(arg.value());
        }

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_CLOSE_PAREN);
    iter.advance();  // skip ')'

    return args;
}

AST_NODE_IMPL_VISITOR(Jsonify, ArgumentListExpr) {
    std::vector<neo::json> args;

    for (const auto &arg : node.args) {
        args.push_back(get_node_json(arg));
    }

    json.section("ArgumentListExpr", args);
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Expression, GenericInvokeExpr) {
    IS_NOT_EMPTY;
    // := '<' GenericArgumentExpr (',' GenericArgumentExpr)* '>'

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_OPEN_ANGLE);
    iter.advance();  // skip '<'

    if CURRENT_TOKEN_IS (__TOKEN_N::PUNCTUATION_CLOSE_ANGLE) {
        iter.advance();  // skip '>'
        return make_node<GenericInvokeExpr>(nullptr);
    }

    ParseResult<> first = parse<Type>();
    RETURN_IF_ERROR(first);

    NodeT<GenericInvokeExpr> generics = make_node<GenericInvokeExpr>(first.value());

    while
        CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_COMMA) {
            iter.advance();  // skip ','

            ParseResult<> arg = parse<Type>();
            RETURN_IF_ERROR(arg);

            generics->args.push_back(arg.value());
        }

    // either a > or >> is expected
    if (CURRENT_TOKEN_IS_NOT(__TOKEN_N::PUNCTUATION_CLOSE_ANGLE) &&
        CURRENT_TOKEN_IS_NOT(__TOKEN_N::OPERATOR_BITWISE_R_SHIFT)) {
        return std::unexpected(
            PARSE_ERROR_MSG("expected '>' to close generic arguments, but found '" +
                            CURRENT_TOK.token_kind_repr() + "'"));
    }

    if (CURRENT_TOKEN_IS(__TOKEN_N::OPERATOR_BITWISE_R_SHIFT)) {
        // break this node into two nodes of PUNCTUATION_CLOSE_ANGLE
        // we are at the '>>' token
        // we need to make it '>' and '>'
        __TOKEN_N::Token &cur_tok = iter.current().get();
        __TOKEN_N::Token  new_tok(cur_tok.line_number(),
                                 cur_tok.column_number() + 1,
                                 cur_tok.length() - 1,
                                 cur_tok.offset() + 1,
                                 ">",
                                 cur_tok.file_name());

        cur_tok.set_value(">");
        cur_tok.set_kind(__TOKEN_N::PUNCTUATION_CLOSE_ANGLE);

        iter.insert(new_tok);
    }

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_CLOSE_ANGLE);
    iter.advance();  // skip '>'

    return generics;
}

AST_NODE_IMPL_VISITOR(Jsonify, GenericInvokeExpr) {
    std::vector<neo::json> args;

    for (const auto &arg : node.args) {
        args.push_back(get_node_json(arg));
    }

    json.section("GenericInvokeExpr", args);
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Expression, ScopePathExpr, ParseResult<> lhs, bool global_scope, bool is_import) {
    IS_NOT_EMPTY;

    // := ('::'? E) ('::' E)*

    ParseResult<IdentExpr> first;
    NodeT<ScopePathExpr>   path;

    if (global_scope) {
        IS_EXCEPTED_TOKEN(__TOKEN_N::OPERATOR_SCOPE);

        path               = make_node<ScopePathExpr>(false);
        path->global_scope = true;

        goto LINE910_PARSE_SCOPE_PATH_EXPR;
    } else {
        IS_NULL_RESULT(lhs) {
            if (CURRENT_TOKEN_IS(__TOKEN_N::OPERATOR_SCOPE)) {  // global scope access
                path               = make_node<ScopePathExpr>(false);
                path->global_scope = true;

                goto LINE910_PARSE_SCOPE_PATH_EXPR;
            }

            first = parse<IdentExpr>();
            RETURN_IF_ERROR(first);
        }
        else {
            RETURN_IF_ERROR(lhs);

            if (lhs.value()->getNodeType() == nodes::PathExpr) {
                NodeT<PathExpr> path = as<PathExpr>(lhs.value());

                if (path->type != PathExpr::PathType::Identifier) {
                    return std::unexpected(
                        PARSE_ERROR_MSG("expected an identifier, but found nothing"));
                }
            } else if (lhs.value()->getNodeType() != nodes::IdentExpr) {
                return std::unexpected(
                    PARSE_ERROR_MSG("expected an identifier, but found nothing"));
            }

            first = as<IdentExpr>(lhs.value());
        }
    }

    path = make_node<ScopePathExpr>(first.value());

LINE910_PARSE_SCOPE_PATH_EXPR:
    while
        CURRENT_TOKEN_IS(__TOKEN_N::OPERATOR_SCOPE) {
            iter.advance();  // skip '::'

            // turbofish | import
            if (is_import) {
                if (CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_OPEN_BRACE) ||
                    CURRENT_TOKEN_IS(__TOKEN_N::OPERATOR_MUL)) {
                    break;
                }
            }

            if (CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_OPEN_ANGLE)) {
                path->access = path->path.back();
                path->path.pop_back();

                iter.reverse();

                break;
            }

            if (CURRENT_TOKEN_IS_NOT(__TOKEN_N::IDENTIFIER) ||
                (HAS_NEXT_TOK && NEXT_TOK != __TOKEN_N::OPERATOR_SCOPE)) {
                ParseResult<> rhs = parse_primary();
                RETURN_IF_ERROR(rhs);

                path->access = rhs.value();
                break;
            }

            ParseResult<IdentExpr> rhs = parse<IdentExpr>();
            RETURN_IF_ERROR(rhs);

            path->path.push_back(rhs.value());
        }

    return path;
}

AST_NODE_IMPL_VISITOR(Jsonify, ScopePathExpr) {
    std::vector<neo::json> path;

    for (const auto &p : node.path) {
        path.push_back(get_node_json(p));
    }

    json.section("ScopePathExpr")
        .add("path", path)
        .add("access", get_node_json(node.access))
        .add("global_scope", node.global_scope ? "true" : "false");
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Expression, DotPathExpr, ParseResult<> lhs) {
    IS_NOT_EMPTY;

    // := E '.' E

    IS_NULL_RESULT(lhs) {
        lhs = parse();
        RETURN_IF_ERROR(lhs);
    }

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_DOT);
    iter.advance();  // skip '.'

    ParseResult<> rhs = parse();
    RETURN_IF_ERROR(rhs);

    return make_node<DotPathExpr>(lhs.value(), rhs.value());
}

AST_NODE_IMPL_VISITOR(Jsonify, DotPathExpr) {
    json.section("DotPathExpr")
        .add("lhs", get_node_json(node.lhs))
        .add("rhs", get_node_json(node.rhs));
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Expression, ArrayAccessExpr, ParseResult<> lhs) {
    IS_NOT_EMPTY;

    // := E '[' E ']'

    IS_NULL_RESULT(lhs) {
        lhs = parse();
        RETURN_IF_ERROR(lhs);
    }

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_OPEN_BRACKET);
    iter.advance();  // skip '['

    ParseResult<> index = parse();
    RETURN_IF_ERROR(index);

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_CLOSE_BRACKET);
    iter.advance();  // skip ']'

    return make_node<ArrayAccessExpr>(lhs.value(), index.value());
}

AST_NODE_IMPL_VISITOR(Jsonify, ArrayAccessExpr) {
    json.section("ArrayAccessExpr")
        .add("array", get_node_json(node.lhs))
        .add("index", get_node_json(node.rhs));
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Expression, PathExpr, ParseResult<> simple_path) {
    IS_NOT_EMPTY;

    // := IdentExpr | ScopePathExpr | DotPathExpr

    IS_NULL_RESULT(simple_path) {
        simple_path = parse_primary();
        RETURN_IF_ERROR(simple_path);
    }

    NodeT<PathExpr> path = make_node<PathExpr>(simple_path.value());
    switch (simple_path.value()->getNodeType()) {
        case __AST_NODE::nodes::IdentExpr:
            path->type = PathExpr::PathType::Identifier;
            break;

        case __AST_NODE::nodes::ScopePathExpr:
            path->type = PathExpr::PathType::Scope;
            break;

        case __AST_NODE::nodes::DotPathExpr:
            path->type = PathExpr::PathType::Dot;
            break;

        default:
            return std::unexpected(
                PARSE_ERROR_MSG("expected a simple path expression, but found nothing"));
    }

    return path;
}

AST_NODE_IMPL_VISITOR(Jsonify, PathExpr) {
    json.section("PathExpr").add("path", get_node_json(node.path)).add("type", (int)node.type);
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Expression,
              FunctionCallExpr,
              ParseResult<>            lhs,
              NodeT<GenericInvokeExpr> generic_invoke) {
    IS_NOT_EMPTY;

    /*
        FunctionCallExpr = {
            NodeT<PathExpr>
            NodeT<ArgumentListExpr>
            NodeT<GenericInvokeExpr>
        }
    */

    ParseResult<PathExpr> path;

    IS_NULL_RESULT(lhs) {
        lhs = parse();
        RETURN_IF_ERROR(lhs);
    }

    path = parse<PathExpr>(lhs.value());
    RETURN_IF_ERROR(path);

    ParseResult<> initializer;

    // either a Argument List or a Object Initializer
    switch (CURRENT_TOK.token_kind()) {
        case __TOKEN_N::PUNCTUATION_OPEN_PAREN:
            initializer = parse<ArgumentListExpr>();
            break;

        case __TOKEN_N::PUNCTUATION_OPEN_BRACE:
            initializer = parse<ObjInitExpr>(false, path);
            break;

        default:
            return std::unexpected(PARSE_ERROR_MSG("expected '(' or '{' after the previous token"));
    }
    RETURN_IF_ERROR(initializer);

    return make_node<FunctionCallExpr>(path.value(), initializer.value(), generic_invoke);
}

AST_NODE_IMPL_VISITOR(Jsonify, FunctionCallExpr) {
    json.section("FunctionCallExpr")
        .add("path", get_node_json(node.path))
        .add("args", get_node_json(node.args))
        .add("generics", get_node_json(node.generic));
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Expression, ArrayLiteralExpr) {
    IS_NOT_EMPTY;
    // := '[' E (',' E)* ']'

    // [1, 2, 3, ]

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_OPEN_BRACKET);
    iter.advance();  // skip '['

    if CURRENT_TOKEN_IS (__TOKEN_N::PUNCTUATION_CLOSE_BRACKET) {
        iter.advance();  // skip ']'
        return std::unexpected(PARSE_ERROR_MSG(
            "list literals must have at least one element, for a blank list use 'list::<...>()' - "
            "replace ... with a type - or default initializer instead."));
    }

    ParseResult<> first = parse();

    RETURN_IF_ERROR(first);

    NodeT<ArrayLiteralExpr> array = make_node<ArrayLiteralExpr>(first.value());

    while
        CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_COMMA) {
            iter.advance();  // skip ','

            if CURRENT_TOKEN_IS (__TOKEN_N::PUNCTUATION_CLOSE_BRACKET) {
                break;
            }

            ParseResult<> next = parse();
            RETURN_IF_ERROR(next);

            array->values.push_back(next.value());
        }

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_CLOSE_BRACKET);
    iter.advance();  // skip ']'

    return array;
}

AST_NODE_IMPL_VISITOR(Jsonify, ArrayLiteralExpr) {
    std::vector<neo::json> values;

    for (const auto &value : node.values) {
        values.push_back(get_node_json(value));
    }

    json.section("ArrayLiteralExpr", values);
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Expression, TupleLiteralExpr, ParseResult<> starting_element) {
    IS_NOT_EMPTY;
    // := '(' E (',' E)* ')'

    ParseResult<> first;

    IS_NULL_RESULT(starting_element) {  // we dont have a starting element in this case
        IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_OPEN_PAREN);
        iter.advance();  // skip '('

        if CURRENT_TOKEN_IS (__TOKEN_N::PUNCTUATION_CLOSE_PAREN) {
            iter.advance();  // skip ')'
            return std::unexpected(
                PARSE_ERROR_MSG("tuple literals must have at least one element"));
        }

        first = parse();
        RETURN_IF_ERROR(first);
    }
    else {
        first = starting_element;
    }

    if CURRENT_TOKEN_IS (__TOKEN_N::PUNCTUATION_CLOSE_PAREN) {
        iter.advance();  // skip ')'
        return std::unexpected(PARSE_ERROR_MSG("tuple literals must have at least one element"));
    }

    NodeT<TupleLiteralExpr> tuple = make_node<TupleLiteralExpr>(first.value());
    while
        CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_COMMA) {
            iter.advance();  // skip ','

            if CURRENT_TOKEN_IS (__TOKEN_N::PUNCTUATION_CLOSE_PAREN) {
                break;
            }

            ParseResult<> next = parse();
            RETURN_IF_ERROR(next);

            tuple->values.push_back(next.value());
        }

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_CLOSE_PAREN);
    iter.advance();  // skip ')'

    return tuple;
}

AST_NODE_IMPL_VISITOR(Jsonify, TupleLiteralExpr) {
    std::vector<neo::json> values;

    for (const auto &value : node.values) {
        values.push_back(get_node_json(value));
    }

    json.section("TupleLiteralExpr", values);
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Expression, SetLiteralExpr, ParseResult<> first) {
    IS_NOT_EMPTY;
    // := '{' E (',' E)* '}'
    // {1}
    // {1, 2, 3, }

    NodeT<SetLiteralExpr> set;

    IS_NULL_RESULT(first) {
        IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_OPEN_BRACE);
        iter.advance();  // skip '{'

        first = parse();
        RETURN_IF_ERROR(first);
    }

    set = make_node<SetLiteralExpr>(first.value());

    // we have parsed the '{' and the first E, so we need to check if the current token is ','
    if CURRENT_TOKEN_IS (__TOKEN_N::PUNCTUATION_CLOSE_BRACE) {
        iter.advance();  // skip '}'
        return set;
    }

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_COMMA);  // we expect a comma here

    while
        CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_COMMA) {
            iter.advance();  // skip ','

            if CURRENT_TOKEN_IS (__TOKEN_N::PUNCTUATION_CLOSE_BRACE) {
                break;
            }

            ParseResult<> next = parse();
            RETURN_IF_ERROR(next);

            set->values.push_back(next.value());
        }

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_CLOSE_BRACE);
    iter.advance();  // skip '}'

    return set;
}

AST_NODE_IMPL_VISITOR(Jsonify, SetLiteralExpr) {
    std::vector<neo::json> values;

    for (const auto &value : node.values) {
        values.push_back(get_node_json(value));
    }

    json.section("SetLiteralExpr", values);
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Expression, MapPairExpr) {
    IS_NOT_EMPTY;
    // := E ':' E

    ParseResult<> key = parse();
    RETURN_IF_ERROR(key);

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_COLON);
    iter.advance();  // skip ':'

    ParseResult<> value = parse();
    RETURN_IF_ERROR(value);

    return make_node<MapPairExpr>(key.value(), value.value());
}

AST_NODE_IMPL_VISITOR(Jsonify, MapPairExpr) {
    json.section("MapPairExpr")
        .add("key", get_node_json(node.key))
        .add("value", get_node_json(node.value));
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Expression, MapLiteralExpr, ParseResult<> key) {
    IS_NOT_EMPTY;

    // := '{' E (':' E)* '}'

    NodeT<MapPairExpr> pair;

    IS_NULL_RESULT(key) {
        IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_OPEN_BRACE);
        iter.advance();  // skip '{'

        ParseResult<MapPairExpr> pair = parse<MapPairExpr>();
        RETURN_IF_ERROR(pair);

        pair = pair.value();
    }
    else {
        // we have parsed the '{' and the first E, so we need to check if the current token is ':'
        IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_COLON);
        iter.advance();  // skip ':'

        ParseResult<> value = parse();
        RETURN_IF_ERROR(value);

        pair = make_node<MapPairExpr>(key.value(), value.value());
    }

    // := (',' E)* '}' is the remaining part of the map literal expression (there could be a
    // trailing comma)

    NodeT<MapLiteralExpr> map = make_node<MapLiteralExpr>(pair);

    while
        CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_COMMA) {
            iter.advance();  // skip ','

            if CURRENT_TOKEN_IS (__TOKEN_N::PUNCTUATION_CLOSE_BRACE) {
                break;
            }

            ParseResult<MapPairExpr> next_pair = parse<MapPairExpr>();
            RETURN_IF_ERROR(next_pair);

            map->values.push_back(next_pair.value());
        }

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_CLOSE_BRACE);
    iter.advance();  // skip '}'

    return map;
}

AST_NODE_IMPL_VISITOR(Jsonify, MapLiteralExpr) {
    std::vector<neo::json> values;

    for (const auto &value : node.values) {
        values.push_back(get_node_json(value));
    }

    json.section("MapLiteralExpr", values);
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Expression, ObjInitExpr, bool skip_start_brace, ParseResult<> obj_path) {
    IS_NOT_EMPTY;
    // := PATH? '{' (NamedArgumentExpr (',' NamedArgumentExpr)*)? '}'

    bool is_anonymous = true;

    IS_NOT_NULL_RESULT(obj_path) { is_anonymous = false; }

    if (!skip_start_brace) {
        IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_OPEN_BRACE);
        iter.advance();  // skip '{'
    }

    if CURRENT_TOKEN_IS (__TOKEN_N::PUNCTUATION_CLOSE_BRACE) {
        if (!is_anonymous) {
            NodeT<ObjInitExpr> obj = make_node<ObjInitExpr>(false);
            obj->path              = obj_path.value();

            iter.advance();  // skip '}'
            return obj;
        }

        return std::unexpected(
            PARSE_ERROR_MSG("blank object initializers are disallowed due to ambiguity in "
                            "parsing, use a more explict initializer"));
    }

    ParseResult<NamedArgumentExpr> first = parse<NamedArgumentExpr>(is_anonymous, true);
    RETURN_IF_ERROR(first);

    NodeT<ObjInitExpr> obj = make_node<ObjInitExpr>(first.value());

    while
        CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_COMMA) {
            iter.advance();  // skip ','

            if CURRENT_TOKEN_IS (__TOKEN_N::PUNCTUATION_CLOSE_BRACE) {
                break;
            }

            ParseResult<NamedArgumentExpr> next = parse<NamedArgumentExpr>(is_anonymous, true);
            RETURN_IF_ERROR(next);

            obj->kwargs.push_back(next.value());
        }

    if (!is_anonymous) {
        obj->path = obj_path.value();
    }

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_CLOSE_BRACE);
    iter.advance();  // skip '}'

    return obj;
}

AST_NODE_IMPL_VISITOR(Jsonify, ObjInitExpr) {
    std::vector<neo::json> kwargs;

    for (const auto &kwarg : node.kwargs) {
        kwargs.push_back(get_node_json(kwarg));
    }

    json.section("ObjInitExpr").add("keyword_args", kwargs).add("path", get_node_json(node.path));
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Expression, LambdaExpr) {
    IS_NOT_EMPTY;

    Declaration decl_parser(iter);

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_FUNCTION);
    NodeT<LambdaExpr> lambda = make_node<LambdaExpr>(CURRENT_TOK);

    ParseResult<FuncDecl> decl = decl_parser.parse<FuncDecl>(nullptr, false);
    RETURN_IF_ERROR(decl);

    NodeT<FuncDecl> func_decl = decl.value();
    if (func_decl->body == nullptr) {
        return std::unexpected(
            PARSE_ERROR_MSG("lambda expresion excepted to have a body, but this is missing one"));
    }

    // deconstruct the function declaration
    lambda->body     = func_decl->body;
    lambda->params   = func_decl->params;
    lambda->generics = func_decl->generics;
    lambda->returns  = func_decl->returns;

    return lambda;
}

AST_NODE_IMPL_VISITOR(Jsonify, LambdaExpr) {
    std::vector<neo::json> args;

    for (const auto &arg : node.params) {
        args.push_back(get_node_json(arg));
    }

    json.section("LambdaExpr")
        .add("maker", node.marker)
        .add("body", get_node_json(node.body))
        .add("params", args)
        .add("generics", get_node_json(node.generics))
        .add("returns", get_node_json(node.returns));
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Expression, TernaryExpr, ParseResult<> E1) {
    IS_NOT_EMPTY;

    // := (E '?' E ':' E) | (E 'if' E 'else' E)
    // true ? 1 : 0 | 1 if true else 0

    IS_NULL_RESULT(E1) {
        E1 = parse();
        RETURN_IF_ERROR(E1);
    }

    if CURRENT_TOKEN_IS (__TOKEN_N::PUNCTUATION_QUESTION_MARK) {
        iter.advance();  // skip '?'

        ParseResult<> E2 = parse();
        RETURN_IF_ERROR(E2);

        IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_COLON);
        iter.advance();  // skip ':'

        ParseResult<> E3 = parse();
        RETURN_IF_ERROR(E3);

        return make_node<TernaryExpr>(E1.value(), E2.value(), E3.value());
    }

    if CURRENT_TOKEN_IS (__TOKEN_N::KEYWORD_IF) {
        iter.advance();  // skip 'if'

        ParseResult<> E2 = parse();
        RETURN_IF_ERROR(E2);

        IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_ELSE);
        iter.advance();  // skip 'else'

        ParseResult<> E3 = parse();
        RETURN_IF_ERROR(E3);

        return make_node<TernaryExpr>(E2.value(), E1.value(), E3.value());
    }

    return std::unexpected(PARSE_ERROR(
        CURRENT_TOK, "expected '?' or 'if', but found: " + CURRENT_TOK.token_kind_repr()));
}

AST_NODE_IMPL_VISITOR(Jsonify, TernaryExpr) {
    json.section("TernaryExpr")
        .add("condition", get_node_json(node.condition))
        .add("if_true", get_node_json(node.if_true))
        .add("if_false", get_node_json(node.if_false));
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Expression, ParenthesizedExpr, ParseResult<> expr) {
    IS_NOT_EMPTY;

    // := '(' E ')'

    IS_NOT_NULL_RESULT(expr) {
        // check if the current token is a ')'
        IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_CLOSE_PAREN);
        iter.advance();  // skip ')'

        return make_node<ParenthesizedExpr>(expr.value());
    }

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_OPEN_PAREN);
    iter.advance();  // skip '('

    ParseResult<> inner = parse();
    RETURN_IF_ERROR(inner);

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_CLOSE_PAREN);
    iter.advance();  // skip ')'

    return make_node<ParenthesizedExpr>(inner.value());
}

AST_NODE_IMPL_VISITOR(Jsonify, ParenthesizedExpr) {
    json.section("ParenthesizedExpr", get_node_json(node.value));
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Expression, CastExpr, ParseResult<> lhs) {
    IS_NOT_EMPTY;

    // := E 'as' E

    IS_NULL_RESULT(lhs) {
        lhs = parse();
        RETURN_IF_ERROR(lhs);
    }

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_AS);
    iter.advance();  // skip 'as'

    ParseResult<Type> rhs = parse<Type>();
    RETURN_IF_ERROR(rhs);

    return make_node<CastExpr>(lhs.value(), rhs.value());
}

AST_NODE_IMPL_VISITOR(Jsonify, CastExpr) {
    json.section("CastExpr")
        .add("value", get_node_json(node.value))
        .add("type", get_node_json(node.type));
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Expression, InstOfExpr, ParseResult<> lhs, bool in_requires) {
    IS_NOT_EMPTY;
    // := E 'has' E | E 'derives' E

    InstOfExpr::InstanceType op = InstOfExpr::InstanceType::Derives;
    token::Token             tok;

    IS_NULL_RESULT(lhs) {
        lhs = parse();
        RETURN_IF_ERROR(lhs);
    }

#define INST_OF_OPS {__TOKEN_N::KEYWORD_IMPL, __TOKEN_N::KEYWORD_DERIVES}
    IS_IN_EXCEPTED_TOKENS(INST_OF_OPS);
#undef INST_OF_OPS

    if CURRENT_TOKEN_IS (__TOKEN_N::KEYWORD_IMPL) {
        op = InstOfExpr::InstanceType::Implement;
    }

    tok = iter.current();

    iter.advance();  // skip 'has' or 'derives'

    ParseResult<> rhs;

    if (op == InstOfExpr::InstanceType::Implement) {
        if (in_requires) {
            rhs = parse<Type>();
        } else {
            rhs = parse();
        }
    } else {
        rhs = parse<Type>();
    }

    RETURN_IF_ERROR(rhs);

    auto node         = make_node<InstOfExpr>(lhs.value(), rhs.value(), op, tok);
    node->in_requires = in_requires;

    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, InstOfExpr) {
    json.section("InstOfExpr")
        .add("value", get_node_json(node.value))
        .add("type", get_node_json(node.type))
        .add("op", (int)node.op);
}

// ---------------------------------------------------------------------------------------------- //

/* Change in self-hosted parser
type should look like so:
class TypeNode {
    enum State { Function, Tuple, Specified, ... };

    State state;
    union {
        SpecifiedTypeNode *specified;
        FunctionTypeNode  *fn;
        TupleTypeNode     *tuple;
        ...
    } data;
};

this is to make the type system more flexible and easier to work with
*/
AST_NODE_IMPL(Expression, Type) {  // TODO - REMAKE using the new Modifiers and stricter rules, such
                                   // as no types can contain a binary expression
    // if E(2) does not exist, check if its a & | * token, since if it is,
    // then return a unary expression since its a pointer or reference type

    // types are quite complex in kairo since this is the gammer:
    // Type := ('fn' '(' (Type ((',' Type)*)?)? ')' ('->' Type)?)
    //      | (TypePrefixes ((',' TypePrefixes)*)?)? PathExpr GenericInvocationExpr?

    // enums: StorageSpecifier, FFISpecifier, TypeQualifier, AccessSpecifier, FunctionSpecifier,
    // FunctionQualifier
    IS_NOT_EMPTY;
    Modifiers type_specifiers(Modifiers::ExpectedModifier::TypeSpec);

    NodeT<Type> node = make_node<Type>(true);

    if (CURRENT_TOKEN_IS(__TOKEN_N::KEYWORD_FUNCTION)) {
        /// fn ptr types
        // fn (int, float, ...) (-> ...)?

        Type::FnPtr fn_ptr;

        fn_ptr.marker = CURRENT_TOK;
        iter.advance();

        IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_OPEN_PAREN);
        iter.advance();  // skip '('

        if (CURRENT_TOKEN_IS_NOT(__TOKEN_N::PUNCTUATION_CLOSE_PAREN)) {  // blank params
            ParseResult<Type> arg = parse<Type>();
            RETURN_IF_ERROR(arg);

            fn_ptr.params.emplace_back(arg.value());

            while (CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_COMMA)) {
                if (CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_CLOSE_PAREN)) {
                    break;  // exit the loop
                }

                ParseResult<Type> arg = parse<Type>();
                RETURN_IF_ERROR(arg);

                fn_ptr.params.emplace_back(arg.value());
            }
        }

        IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_CLOSE_PAREN);
        iter.advance();  // skip ')'

        if (CURRENT_TOKEN_IS(__TOKEN_N::OPERATOR_ARROW)) {
            iter.advance();  // skip '->'

            ParseResult<Type> return_t = parse<Type>();
            RETURN_IF_ERROR(return_t);

            fn_ptr.returns = return_t.value();
        }

        NodeT<Type> node = make_node<Type>(fn_ptr);
        node->is_fn_ptr  = true;

        return node;
    }

    while (node->specifiers.find_add(CURRENT_TOK)) {
        iter.advance();  // TODO: Handle 'ffi' ('class' | 'interface' | 'struct' | 'enum' | 'union'
                         // | 'type' | 'unsafe')
    }

    auto __parse_tuple = [&](NodeT<Type> elm1) -> ParseResult<> {
        NodeT<TupleLiteralExpr> tuple = make_node<TupleLiteralExpr>(elm1);
        while
            CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_COMMA) {
                iter.advance();  // skip ','

                if CURRENT_TOKEN_IS (__TOKEN_N::PUNCTUATION_CLOSE_PAREN) {
                    break;
                }

                ParseResult<> next = parse<Type>();
                RETURN_IF_ERROR(next);

                tuple->values.push_back(next.value());
            }

        IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_CLOSE_PAREN);
        iter.advance();  // skip ')'

        return tuple;
    };

    node->marker = CURRENT_TOK;

    ParseResult<> EXPR;
    switch (CURRENT_TOK.token_kind()) {
        case __TOKEN_N::OPERATOR_MUL:
        case __TOKEN_N::OPERATOR_BITWISE_AND:
            EXPR = parse<UnaryExpr>(EXPR, true);
            break;

        case __TOKEN_N::PUNCTUATION_OPEN_PAREN: {
            // identify if its a tuple or a parenthesized type
            iter.advance();  // skip '('

            if CURRENT_TOKEN_IS (__TOKEN_N::PUNCTUATION_CLOSE_PAREN) {  // ()
                iter.advance();                                         // skip ')'
                return std::unexpected(PARSE_ERROR(
                    CURRENT_TOK, "expected a type, or a parenthesized type, but found nothing"));
            }

            auto elm1 = parse<Type>();
            RETURN_IF_ERROR(elm1);

            switch (CURRENT_TOK.token_kind()) {
                case __TOKEN_N::PUNCTUATION_CLOSE_PAREN:
                    iter.advance();  // skip ')'
                    EXPR = elm1;
                    break;

                case __TOKEN_N::PUNCTUATION_COMMA:
                    EXPR = __parse_tuple(elm1.value());
                    break;

                default:
                    return std::unexpected(PARSE_ERROR(CURRENT_TOK,
                                                       "expected a ')' or ',', but found: " +
                                                           CURRENT_TOK.token_kind_repr()));
            }

            break;
        }

        default:
            EXPR = parse_primary();
            break;
    }

    RETURN_IF_ERROR(EXPR);

    bool continue_loop = true;
    while (continue_loop) {
        const __TOKEN_N::Token &tok = CURRENT_TOK;

        switch (tok.token_kind()) {
            case __TOKEN_N::OPERATOR_LOGICAL_NOT: {
                // this is a function call, not allowed UNLESS its a fucntion call to a thing
                // called: 'ref' or 'mref' then we replace it with a unary expression still validate
                // there is only 1 argument and its a type like ref!(int) or mref!(int)

                if (iter.peek_back().value().get() != __TOKEN_N::IDENTIFIER) {
                    return std::unexpected(
                        PARSE_ERROR(tok,
                                    "expected a type, but found a macro call to: " +
                                        iter.peek_back().value().get().get_value()));
                }

                auto cur_tok = iter.peek_back().value().get();  // get the current token again

                if (cur_tok.get_value() == "ref" || cur_tok.get_value() == "mref") {
                    iter.advance();  // skip '!'

                    if (CURRENT_TOKEN_IS_NOT(__TOKEN_N::PUNCTUATION_OPEN_PAREN)) {
                        return std::unexpected(PARSE_ERROR(
                            tok, "expected a '(', but found: " + CURRENT_TOK.token_kind_repr()));
                    }

                    iter.advance();  // skip '('

                    ParseResult<Type> arg = parse<Type>();
                    RETURN_IF_ERROR(arg);

                    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_CLOSE_PAREN);
                    iter.advance();  // skip ')'

                    cur_tok = token::Token(cur_tok.line_number(),
                                           cur_tok.column_number(),
                                           cur_tok.length(),
                                           cur_tok.offset(),
                                           (cur_tok.get_value() == "ref")    ? "&"
                                           : (cur_tok.get_value() == "mref") ? "&&"
                                                                             : cur_tok.get_value(),
                                           cur_tok.file_name());

                    EXPR = make_node<UnaryExpr>(
                        arg.value(), cur_tok, UnaryExpr::PosType::PreFix, true);

                    break;
                }

                return std::unexpected(PARSE_ERROR(
                    tok, "expected a type, but found a macro call to: " + cur_tok.get_value()));
            }
            case __TOKEN_N::PUNCTUATION_OPEN_PAREN:
                return std::unexpected(
                    PARSE_ERROR(tok, "expected a type, but found a function call"));

            case __TOKEN_N::PUNCTUATION_OPEN_BRACKET:
                return std::unexpected(PARSE_ERROR(tok,
                                                   "expected a type, but found an array specifier, "
                                                   "use a pointer or std::array instead"));

            case __TOKEN_N::OPERATOR_SCOPE:
                // there may be turbofish here
                if (HAS_NEXT_TOK && NEXT_TOK == __TOKEN_N::PUNCTUATION_OPEN_ANGLE) {
                    iter.advance();  // skip '::'
                    goto parse_generic_in_type;
                }

                EXPR = parse<ScopePathExpr>(EXPR);
                RETURN_IF_ERROR(EXPR);
                break;

            case __TOKEN_N::PUNCTUATION_OPEN_ANGLE:  // generic lol
                return std::unexpected(
                    PARSE_ERROR(tok,
                                "use turbofish syntax instead for generic invocations, this will "
                                "change in a future release."));
            parse_generic_in_type: {
                ParseResult<GenericInvokeExpr> generic = parse<GenericInvokeExpr>();
                RETURN_IF_ERROR(generic);

                node->generics = generic.value();
                continue_loop  = false;
                break;
            }

                // TODO: add support for scope path expressions

            default:
                if (is_excepted(tok, IS_UNARY_OPERATOR)) {
                    EXPR = parse<UnaryExpr>(EXPR, true);
                    RETURN_IF_ERROR(EXPR);
                } else if (tok == __TOKEN_N::PUNCTUATION_OPEN_PAREN) {
                    iter.advance();                         // skip '('
                    EXPR = parse<ParenthesizedExpr>(EXPR);  /// im not sure why this works, but
                                                            /// based on small tests, it seems
                                                            /// to work fine i'll find out soon
                                                            /// enough if it doesn't
                    RETURN_IF_ERROR(EXPR);
                } else {
                    continue_loop = false;
                }
        }
    }

    RETURN_IF_ERROR(EXPR);
    node->value = EXPR.value();

    if (node->value->getNodeType() == nodes::UnaryExpr) {
        NodeT<UnaryExpr> type = as<UnaryExpr>(node->value);

        if (type->op.token_kind() == __TOKEN_N::PUNCTUATION_QUESTION_MARK) {
            if (type->type != UnaryExpr::PosType::PostFix) {
                return std::unexpected(PARSE_ERROR(
                    type->op,
                    "invalid placement of `?` operator: must be used as a postfix operator."));
            }

            node->nullable = true;
        } else if ((type->op.token_kind() == __TOKEN_N::OPERATOR_BITWISE_AND) ||
                   (type->op.token_kind() == __TOKEN_N::OPERATOR_LOGICAL_AND) ||
                   (type->op.token_kind() == __TOKEN_N::OPERATOR_MUL)) {  // *&type?
            if (type->type != UnaryExpr::PosType::PreFix) {
                return std::unexpected(
                    PARSE_ERROR(type->op,
                                "invalid placement of '" + type->op.value() +
                                    "' operator: must be used as a prefix operator."));
            }
        } else {
            return std::unexpected(PARSE_ERROR(type->op, "invalid type operator."));
        }
    }

    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, Type) {
    json.section("Type")
        .add("value", get_node_json(node.value))
        .add("generics", get_node_json(node.generics))
        .add("specifiers", node.specifiers.to_json())
        .add("is_fn_ptr", node.is_fn_ptr ? "true" : "false")
        .add("nullable", node.nullable ? "true" : "false");
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Expression, AsyncThreading) {
    IS_NOT_EMPTY;
    // := ('await' | 'spawn' | 'thread') E

    __TOKEN_N::Token tok = CURRENT_TOK;

#define ASYNC_THREADING_OPS \
    {__TOKEN_N::KEYWORD_AWAIT, __TOKEN_N::KEYWORD_SPAWN, __TOKEN_N::KEYWORD_THREAD}

    IS_IN_EXCEPTED_TOKENS(ASYNC_THREADING_OPS);
    iter.advance();  // skip 'await', 'spawn' or 'thread'

#undef ASYNC_THREADING_OPS

    ParseResult<> expr = parse();
    RETURN_IF_ERROR(expr);

    return make_node<AsyncThreading>(expr.value(), tok);
}

AST_NODE_IMPL_VISITOR(Jsonify, AsyncThreading) {
    json.section("AsyncThreading")
        .add("value", get_node_json(node.value))
        .add("type", (int)node.type);
}

// ---------------------------------------------------------------------------------------------- //

bool is_excepted(const __TOKEN_N::Token &tok, const std::unordered_set<__TOKEN_TYPES_N> &tokens) {
    return tokens.find(tok.token_kind()) != tokens.end();
}

int get_precedence(const __TOKEN_N::Token &tok) {
    switch (tok.token_kind()) {
        case __TOKEN_N::OPERATOR_ARROW:
            return 14;
        case __TOKEN_N::OPERATOR_MUL:
        case __TOKEN_N::OPERATOR_DIV:
        case __TOKEN_N::OPERATOR_MOD:
        case __TOKEN_N::OPERATOR_POW:
            return 12;

        case __TOKEN_N::OPERATOR_ADD:
        case __TOKEN_N::OPERATOR_SUB:
            return 11;

        case __TOKEN_N::OPERATOR_BITWISE_L_SHIFT:
        case __TOKEN_N::OPERATOR_BITWISE_R_SHIFT:
            return 10;

        case __TOKEN_N::OPERATOR_GREATER_THAN_EQUALS:
        case __TOKEN_N::OPERATOR_LESS_THAN_EQUALS:
        case __TOKEN_N::PUNCTUATION_OPEN_ANGLE:
        case __TOKEN_N::PUNCTUATION_CLOSE_ANGLE:
            return 9;

        case __TOKEN_N::OPERATOR_EQUAL:
        case __TOKEN_N::OPERATOR_NOT_EQUAL:
            return 8;

        case __TOKEN_N::OPERATOR_BITWISE_AND:
            return 7;
        case __TOKEN_N::OPERATOR_BITWISE_XOR:
            return 6;
        case __TOKEN_N::OPERATOR_BITWISE_OR:
            return 5;
        case __TOKEN_N::OPERATOR_LOGICAL_AND:
            return 4;
        case __TOKEN_N::OPERATOR_LOGICAL_OR:
            // MISSING ?:
            return 3;
        case __TOKEN_N::OPERATOR_RANGE_INCLUSIVE:
        case __TOKEN_N::OPERATOR_RANGE:
            return 2;

        case __TOKEN_N::OPERATOR_ADD_ASSIGN:
        case __TOKEN_N::OPERATOR_SUB_ASSIGN:
        case __TOKEN_N::OPERATOR_MUL_ASSIGN:
        case __TOKEN_N::OPERATOR_DIV_ASSIGN:
        case __TOKEN_N::OPERATOR_MOD_ASSIGN:
        case __TOKEN_N::OPERATOR_ASSIGN:
            return 1;

        default:
            return 0;  // Return 0 for non-binary operators
    }
}

bool is_ffi_specifier(const __TOKEN_N::Token &tok) {
    return is_excepted(tok,
                       {__TOKEN_N::KEYWORD_CLASS,
                        __TOKEN_N::KEYWORD_INTERFACE,
                        __TOKEN_N::KEYWORD_STRUCT,
                        __TOKEN_N::KEYWORD_ENUM,
                        __TOKEN_N::KEYWORD_UNION,
                        __TOKEN_N::KEYWORD_TYPE});
};

bool is_type_qualifier(const __TOKEN_N::Token &tok) {
    return is_excepted(tok,
                       {__TOKEN_N::KEYWORD_CONST,
                        __TOKEN_N::KEYWORD_MODULE,
                        __TOKEN_N::KEYWORD_YIELD,
                        __TOKEN_N::KEYWORD_ASYNC,
                        __TOKEN_N::KEYWORD_FFI,
                        __TOKEN_N::KEYWORD_STATIC,
                        __TOKEN_N::KEYWORD_MACRO});
};

bool is_access_specifier(const __TOKEN_N::Token &tok) {
    return is_excepted(tok,
                       {__TOKEN_N::KEYWORD_PUBLIC,
                        __TOKEN_N::KEYWORD_PRIVATE,
                        __TOKEN_N::KEYWORD_PROTECTED,
                        __TOKEN_N::KEYWORD_INTERNAL});
};

bool is_function_specifier(const __TOKEN_N::Token &tok) {
    return is_excepted(tok,
                       {__TOKEN_N::KEYWORD_INLINE,
                        __TOKEN_N::KEYWORD_ASYNC,
                        __TOKEN_N::KEYWORD_STATIC,
                        __TOKEN_N::KEYWORD_CONST,
                        __TOKEN_N::KEYWORD_EVAL});
};

bool is_function_qualifier(const __TOKEN_N::Token &tok) {
    return is_excepted(tok,
                       {__TOKEN_N::KEYWORD_DEFAULT,
                        __TOKEN_N::KEYWORD_PANIC,
                        __TOKEN_N::KEYWORD_DELETE,
                        __TOKEN_N::KEYWORD_CONST});
};

bool is_storage_specifier(const __TOKEN_N::Token &tok) {
    return is_excepted(tok,
                       {__TOKEN_N::KEYWORD_FFI,
                        __TOKEN_N::KEYWORD_STATIC,
                        __TOKEN_N::KEYWORD_ASYNC,
                        __TOKEN_N::KEYWORD_EVAL});
};
