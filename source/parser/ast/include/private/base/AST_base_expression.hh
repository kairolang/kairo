///--- The Helix Project ------------------------------------------------------------------------///
///                                                                                              ///
///   Part of the Helix Project, under the Attribution 4.0 International license (CC BY 4.0).    ///
///   You are allowed to use, modify, redistribute, and create derivative works, even for        ///
///   commercial purposes, provided that you give appropriate credit, and indicate if changes    ///
///   were made.                                                                                 ///
///                                                                                              ///
///   For more information on the license terms and requirements, please visit:                  ///
///     https://creativecommons.org/licenses/by/4.0/                                             ///
///                                                                                              ///
///   SPDX-License-Identifier: CC-BY-4.0                                                         ///
///   Copyright (c) 2024 The Helix Project (CC BY 4.0)                                           ///
///                                                                                              ///
///-------------------------------------------------------------------------------------- C++ ---///

#ifndef __AST_BASE_EXPRESSION_H__
#define __AST_BASE_EXPRESSION_H__

#include "parser/ast/include/config/AST_config.def"
#include "parser/ast/include/private/AST_generate.hh"
#include "parser/ast/include/types/AST_types.hh"

__AST_NODE_BEGIN {
    /*
     *  Expression class
     *
     *  This class is responsible for parsing the expression grammar.
     *  It is a recursive descent parser that uses the token list
     *  to parse the expression grammar.
     *
     *  (its very bad quality but will be improved when written in helix)
     *
     *  usage:
     *     Expression expr(tokens);
     *     NodeT<> node = expr.parse();
     *
     *     // or
     *
     *     NodeT<...> node = expr.parse<...>();
     */
    class Expression {  // THIS IS NOT A NODE
        template <typename T = Node>
        using p_r = parser ::ast ::ParseResult<T>;
        token ::TokenList ::TokenListIter &iter;

      public:
        Expression()                              = delete;
        Expression(const Expression &)            = default;
        Expression &operator=(const Expression &) = delete;
        Expression(Expression &&)                 = default;
        Expression &operator=(Expression &&)      = delete;
        ~Expression()                             = default;
        p_r<> parse(bool in_requires = false, int precedence = 0);
        explicit Expression(token ::TokenList ::TokenListIter &iter)
            : iter(iter) {};

        ParseResult<> parse_primary();
        template <typename T, typename... Args>
        ParseResult<T> parse(Args &&...args) { /* NOLINT */
            if constexpr (std ::same_as<T, LiteralExpr>) {
                return parse_LiteralExpr(std ::forward<Args>(args)...);
            } else if constexpr (std ::same_as<T, BinaryExpr>) {
                return parse_BinaryExpr(std ::forward<Args>(args)...);
            } else if constexpr (std ::same_as<T, UnaryExpr>) {
                return parse_UnaryExpr(std ::forward<Args>(args)...);
            } else if constexpr (std ::same_as<T, IdentExpr>) {
                return parse_IdentExpr(std ::forward<Args>(args)...);
            } else if constexpr (std ::same_as<T, NamedArgumentExpr>) {
                return parse_NamedArgumentExpr(std ::forward<Args>(args)...);
            } else if constexpr (std ::same_as<T, ArgumentExpr>) {
                return parse_ArgumentExpr(std ::forward<Args>(args)...);
            } else if constexpr (std ::same_as<T, ArgumentListExpr>) {
                return parse_ArgumentListExpr(std ::forward<Args>(args)...);
            } else if constexpr (std ::same_as<T, GenericInvokeExpr>) {
                return parse_GenericInvokeExpr(std ::forward<Args>(args)...);
            } else if constexpr (std ::same_as<T, ScopePathExpr>) {
                return parse_ScopePathExpr(std ::forward<Args>(args)...);
            } else if constexpr (std ::same_as<T, DotPathExpr>) {
                return parse_DotPathExpr(std ::forward<Args>(args)...);
            } else if constexpr (std ::same_as<T, ArrayAccessExpr>) {
                return parse_ArrayAccessExpr(std ::forward<Args>(args)...);
            } else if constexpr (std ::same_as<T, PathExpr>) {
                return parse_PathExpr(std ::forward<Args>(args)...);
            } else if constexpr (std ::same_as<T, FunctionCallExpr>) {
                return parse_FunctionCallExpr(std ::forward<Args>(args)...);
            } else if constexpr (std ::same_as<T, ArrayLiteralExpr>) {
                return parse_ArrayLiteralExpr(std ::forward<Args>(args)...);
            } else if constexpr (std ::same_as<T, TupleLiteralExpr>) {
                return parse_TupleLiteralExpr(std ::forward<Args>(args)...);
            } else if constexpr (std ::same_as<T, SetLiteralExpr>) {
                return parse_SetLiteralExpr(std ::forward<Args>(args)...);
            } else if constexpr (std ::same_as<T, MapPairExpr>) {
                return parse_MapPairExpr(std ::forward<Args>(args)...);
            } else if constexpr (std ::same_as<T, MapLiteralExpr>) {
                return parse_MapLiteralExpr(std ::forward<Args>(args)...);
            } else if constexpr (std ::same_as<T, ObjInitExpr>) {
                return parse_ObjInitExpr(std ::forward<Args>(args)...);
            } else if constexpr (std ::same_as<T, LambdaExpr>) {
                return parse_LambdaExpr(std ::forward<Args>(args)...);
            } else if constexpr (std ::same_as<T, TernaryExpr>) {
                return parse_TernaryExpr(std ::forward<Args>(args)...);
            } else if constexpr (std ::same_as<T, ParenthesizedExpr>) {
                return parse_ParenthesizedExpr(std ::forward<Args>(args)...);
            } else if constexpr (std ::same_as<T, CastExpr>) {
                return parse_CastExpr(std ::forward<Args>(args)...);
            } else if constexpr (std ::same_as<T, InstOfExpr>) {
                return parse_InstOfExpr(std ::forward<Args>(args)...);
            } else if constexpr (std ::same_as<T, Type>) {
                return parse_Type(std ::forward<Args>(args)...);
            } else if constexpr (std ::same_as<T, AsyncThreading>) {
                return parse_AsyncThreading(std ::forward<Args>(args)...);
            } else if constexpr (std ::same_as<T, InlineBlockExpr>) {
                return parse_InlineBlockExpr(std ::forward<Args>(args)...);
            }
        };

      private:
        ParseResult<NamedArgumentExpr>     parse_NamedArgumentExpr(bool is_anonymous = false, bool in_obj_init = false);
        ParseResult<PathExpr>              parse_PathExpr(ParseResult<> simple_path = nullptr);
        ParseResult<UnaryExpr>             parse_UnaryExpr(ParseResult<> lhs = nullptr, bool in_type = false);
        ParseResult<BinaryExpr>            parse_BinaryExpr(ParseResult<> lhs, int min_precedence);
        ParseResult<LiteralExpr>           parse_LiteralExpr(ParseResult<> str_concat = nullptr);
        ParseResult<ArgumentExpr>          parse_ArgumentExpr();
        ParseResult<DotPathExpr>           parse_DotPathExpr(ParseResult<> lhs = nullptr);
        ParseResult<IdentExpr>             parse_IdentExpr();
        ParseResult<ScopePathExpr>         parse_ScopePathExpr(ParseResult<> lhs = nullptr, bool global_scope = false, bool is_import = false);
        ParseResult<ArrayAccessExpr>       parse_ArrayAccessExpr(ParseResult<> lhs = nullptr);
        ParseResult<ArgumentListExpr>      parse_ArgumentListExpr();
        ParseResult<GenericInvokeExpr>     parse_GenericInvokeExpr();
        ParseResult<ArrayLiteralExpr>      parse_ArrayLiteralExpr();
        ParseResult<InlineBlockExpr>       parse_InlineBlockExpr();
        ParseResult<TupleLiteralExpr>
        parse_TupleLiteralExpr(ParseResult<> starting_element = nullptr);
        ParseResult<SetLiteralExpr>    parse_SetLiteralExpr(ParseResult<> starting_value);
        ParseResult<MapPairExpr>       parse_MapPairExpr();
        ParseResult<MapLiteralExpr>    parse_MapLiteralExpr(ParseResult<> starting_value);
        ParseResult<ObjInitExpr>       parse_ObjInitExpr(bool          skip_start_brace = false,
                                                         ParseResult<> obj_path         = nullptr);
        ParseResult<LambdaExpr>        parse_LambdaExpr();
        ParseResult<TernaryExpr>       parse_TernaryExpr(ParseResult<> lhs = nullptr);
        ParseResult<ParenthesizedExpr> parse_ParenthesizedExpr(ParseResult<> expr = nullptr);
        ParseResult<CastExpr>          parse_CastExpr(ParseResult<> lhs);
        ParseResult<InstOfExpr>        parse_InstOfExpr(ParseResult<> lhs = nullptr, bool in_requires = false);
        ParseResult<Type>              parse_Type();
        ParseResult<AsyncThreading>    parse_AsyncThreading();
        ParseResult<FunctionCallExpr>  parse_FunctionCallExpr(ParseResult<> lhs = nullptr, NodeT<GenericInvokeExpr> generic_invoke = nullptr);
    };
}  //  namespace __AST_NODE_BEGIN

#endif  // __AST_BASE_EXPRESSION_H__