//===------------------------------------------ C++ ------------------------------------------====//
//                                                                                                //
//  Part of the Helix Project, under the Attribution 4.0 International license (CC BY 4.0). You   //
//  are allowed to use, modify, redistribute, and create derivative works, even for commercial    //
//  purposes, provided that you give appropriate credit, and indicate if changes                  //
//  were made. For more information, please visit: https://creativecommons.org/licenses/by/4.0/   //
//                                                                                                //
//  SPDX-License-Identifier: CC-BY-4.0 // Copyright (c) 2024 (CC BY 4.0)                          //
//                                                                                                //
//====----------------------------------------------------------------------------------------====//
///                                                                                              ///
///  @file Decls.cc                                                                              ///
///  @brief This file contains the entire logic to parse declarations using a recursive descent  ///
///         parser. the parser adheres to an ll(1) grammar, which means it processes the input   ///
///         left-to-right and constructs the leftmost derivation using one token of lookahead.   ///
///                                                                                              ///
///  The parser is implemented using the `parse` method, which is a recursive descent parser     ///
///     that uses the token list to parse the Declaration grammar.                               ///
///                                                                                              ///
///  @code                                                                                       ///
///  Declaration decl(tokens);                                                                   ///
///  ParseResult<> node = decl.parse();                                                          ///
///                                                                                              ///
///  if (node.has_value()) {                                                                     ///
///      NodeT<> ast = node.value();                                                             ///
///  } else {                                                                                    ///
///      std::cerr << node.error().what() << std::endl;                                          ///
///  }                                                                                           ///
///  @endcode                                                                                    ///
///                                                                                              ///
///  By default, the parser will parse the entire declaration, but you can also parse a specific ///
///     declaration by calling the specific parse method. or get a specific node by calling      ///
///     parse and then passing a template argument to the method.                                ///
///                                                                                              ///
///  @code                                                                                       ///
///  Declaration state(tokens);                                                                  ///
///  ParseResult<ReturnState> node = state.parse<ReturnState>();                                 ///
///  @endcode                                                                                    ///
///                                                                                              ///
/// The parser is implemented using the following grammar:                                       ///
///                                                                                              ///
/// STS *           /* node types */                                                             ///
/// [x] * Literal     * L                                                                        ///
/// [x] * Operator    * O                                                                        ///
/// [x] * Token       * T                                                                        ///
/// [x] * Expression  * E                                                                        ///
/// [x] * Statement   * S                                                                        ///
/// [x] * Declaration * D                                                                        ///
///                                                                                              ///
/// STS *                  /* generics and type bounds */                                        ///
/// [x] * RequiresParamDecl * 'const'? (S.NamedVarSpecifier) ('=' E)?                            ///
/// [x] * RequiresParamList * (RequiresParamDecl (',' RequiresParamDecl)*)?                      ///
/// [x] * TypeBoundDecl     * 'if' InstOfExpr                                                    ///
/// [x] * TypeBoundList     * (TypeBoundDecl (',' TypeBoundDecl)*)?                              ///
/// [x] * RequiresDecl      * 'requires' '<' RequiresParamList '>' TypeBoundList?                ///
/// [x] * ExtendsDecl       * 'extends' (E.Type (',' E.Type)*)?                                  ///
/// [x] * EnumMemberDecl    * E.IdentExpr ('=' E)?                                               ///
/// [x] * UDTDeriveDecl     * 'derives' (E.Type (',' E.Type)*)?                                  ///
///                                                                                              ///
///                        /* declaration helpers */                                             ///
/// [x] * StorageSpecifier  * 'ffi' | 'static' | 'async' | 'eval'                                ///
/// [x] * FFISpecifier      * 'class' | 'interface' | 'struct' | 'enum' | 'union' | 'type'       ///
/// [x] * TypeQualifier     * 'const' | 'module' | 'yield' | 'async' | 'ffi' | 'static'          ///
/// [x] * AccessSpecifier   * 'pub' | 'priv' | 'prot' | 'intl'                                   ///
/// [x] * FunctionSpecifier * 'inline'  | 'async' | 'static' | 'const' | 'eval' | 'other'        ///
/// [x] * FunctionQualifier * 'default' | 'panic' | 'delete' | 'const'                           ///
///                                                                                              ///
/// [x] * VisDecl         * AccessSpecifier                                                       //
/// [x] * VarDecl         * S.NamedVarSpecifier ('=' E)? ~ also pass in a bool to force type need //
/// [x] * SharedModifiers * (FunctionSpecifier)*)?                                               ///
///                                                                                              ///
///                /* declaration nodes */                                                       ///
/// [ ] * FFIDecl   *  VisDecl? 'ffi' L.StringLiteral D                                          ///
/// [x] * LetDecl   *  VisDecl? 'let'   SharedModifiers VarDecl* ';'                             ///
/// [x] * ConstDecl *  VisDecl? 'const' SharedModifiers VarDecl* ';'                             ///
/// [x] * TypeDecl  *  VisDecl? 'type'  E.IdentExpr RequiresDecl? '=' E ';'                      ///
/// [x] * EnumDecl  *  VisDecl? 'enum' ('derives' E.Type)? E.ObjInitExpr                         ///
/// [x] * OpDecl    *  SharedModifiers? 'op' T FuncDecl[no_SharedModifiers=true]                 ///
/// [x] * FuncDecl  *  SharedModifiers? 'fn' E.PathExpr '(' VarDecl[true]* ')' RequiresDecl? S.Suite
/// [x] * StructDecl* 'const'? VisDecl? 'struct'    E.IdentExpr UDTDeriveDecl? RequiresDecl? S.Suite
/// [x] * ClassDecl * 'const'? VisDecl? 'class' E.IdentExpr UDTDeriveDecl? ExtendsDecl?
/// RequiresDecl? S.Suite [x] * InterDecl * 'const'? VisDecl? 'interface' E.IdentExpr UDTDeriveDecl?
/// RequiresDecl? S.Suite [x] * ModuleDecl* 'inline'? 'module' E.PathExpr S.Suite ///
///                                                                                              ///
/// [ ] * ExtDecl   * 'extend' E.PathExpr UDTDeriveDecl? S.Suite       /* TODO: dont forget */   ///
///                                                                                              ///
/// [ ] * UnionDecl     * VisDecl? 'union'  E.IdentExpr UDTDeriveDecl? RequiresDecl? S.Suite     ///
/// TODO: should unions be Statements in the form of anonymous unions or concrete type decls???  ///
//===-----------------------------------------------------------------------------------------====//

#include <cstddef>
#include <cstdio>
#include <expected>
#include <iterator>
#include <memory>
#include <unordered_set>
#include <utility>
#include <vector>

#include "neo-panic/include/error.hh"
#include "neo-pprint/include/hxpprint.hh"
#include "parser/ast/include/config/AST_config.def"
#include "parser/ast/include/nodes/AST_declarations.hh"
#include "parser/ast/include/nodes/AST_expressions.hh"
#include "parser/ast/include/nodes/AST_statements.hh"
#include "parser/ast/include/private/AST_generate.hh"
#include "parser/ast/include/private/base/AST_base_expression.hh"
#include "parser/ast/include/private/base/AST_base_statement.hh"
#include "parser/ast/include/types/AST_jsonify_visitor.hh"
#include "parser/ast/include/types/AST_modifiers.hh"
#include "parser/ast/include/types/AST_types.hh"
#include "token/include/Token.hh"
#include "token/include/private/Token_generate.hh"

AST_NODE_IMPL(Declaration, RequiresParamDecl) {
    IS_NOT_EMPTY;
    // RequiresParamDecl := const'? (S.NamedVarSpecifier) ('=' E)?

    NodeT<RequiresParamDecl>       node = make_node<RequiresParamDecl>(true);
    ParseResult<NamedVarSpecifier> var;

    if CURRENT_TOKEN_IS (__TOKEN_N::KEYWORD_CONST) {
        iter.advance();  // skip 'const'
        node->is_const = true;
    }

    var = state_parser.parse<NamedVarSpecifier>(node->is_const);  // force type if is_const is true
    RETURN_IF_ERROR(var);

    node->var = var.value();

    if CURRENT_TOKEN_IS (__TOKEN_N::OPERATOR_ASSIGN) {
        iter.advance();  // skip '='

        ParseResult<> value = expr_parser.parse();
        RETURN_IF_ERROR(value);

        node->value = value.value();
    }

    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, RequiresParamDecl) {
    json.section("RequiresParamDecl")
        .add("is_const", node.is_const ? "true" : "false")
        .add("var", get_node_json(node.var))
        .add("value", get_node_json(node.value));
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Declaration, RequiresParamList) {
    IS_NOT_EMPTY;
    // RequiresParamList := RequiresParamDecl (',' RequiresParamDecl)*)?

#define TOKENS_REQUIRED {__TOKEN_N::KEYWORD_CONST, __TOKEN_N::IDENTIFIER}
    IS_IN_EXCEPTED_TOKENS(TOKENS_REQUIRED);
#undef TOKENS_REQUIRED

    ParseResult<RequiresParamDecl> first = parse<RequiresParamDecl>();
    RETURN_IF_ERROR(first);

    NodeT<RequiresParamList> node = make_node<RequiresParamList>(first.value());

    while (CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_COMMA)) {
        iter.advance();  // skip ','

        ParseResult<RequiresParamDecl> next = parse<RequiresParamDecl>();
        RETURN_IF_ERROR(next);

        node->params.emplace_back(next.value());
    }

    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, RequiresParamList) {
    std::vector<neo::json> params;

    for (const auto &param : node.params) {
        params.push_back(get_node_json(param));
    }

    json.section("RequiresParamList", params);
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Declaration, EnumMemberDecl) {
    IS_NOT_EMPTY;
    // EnumMemberDecl := E.IdentExpr ('=' E)?
    IS_EXCEPTED_TOKEN(__TOKEN_N::IDENTIFIER);

    ParseResult<IdentExpr> name = expr_parser.parse<IdentExpr>();
    RETURN_IF_ERROR(name);

    NodeT<EnumMemberDecl> node = make_node<EnumMemberDecl>(name.value());

    if (CURRENT_TOKEN_IS(__TOKEN_N::OPERATOR_ASSIGN)) {
        iter.advance();  // skip '='

        ParseResult<> value = expr_parser.parse();
        RETURN_IF_ERROR(value);

        node->value = value.value();
    }

    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, EnumMemberDecl) {
    json.section("EnumMemberDecl")
        .add("name", get_node_json(node.name))
        .add("value", get_node_json(node.value));
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Declaration, UDTDeriveDecl) {
    IS_NOT_EMPTY;
    // UDTDeriveDecl := 'derives' (VisDecl? E.Type (',' VisDecl? E.Type)*)?

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_DERIVES);

    iter.advance();  // skip 'derives'

    AccessSpecifier access = AccessSpecifier(
        __TOKEN_N::Token(__TOKEN_N::KEYWORD_PUBLIC, "HZL_CMPILER_INL.ACCESS_SPECIFIER__.tmp"));
    if (AccessSpecifier::is_access_specifier(CURRENT_TOK)) {
        access = AccessSpecifier(CURRENT_TOK);
    }

    ParseResult<Type> type = expr_parser.parse<Type>();
    RETURN_IF_ERROR(type);

    NodeT<UDTDeriveDecl> node = make_node<UDTDeriveDecl>(std::make_pair(type.value(), access));

    while (CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_COMMA)) {
        iter.advance();  // skip ','

        AccessSpecifier access = AccessSpecifier(
            __TOKEN_N::Token(__TOKEN_N::KEYWORD_PUBLIC, "HZL_CMPILER_INL.ACCESS_SPECIFIER__.tmp"));
        if (AccessSpecifier::is_access_specifier(CURRENT_TOK)) {
            access = AccessSpecifier(CURRENT_TOK);
        }

        ParseResult<Type> next = expr_parser.parse<Type>();
        RETURN_IF_ERROR(next);

        node->derives.emplace_back(next.value(), access);
    }

    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, UDTDeriveDecl) {
    std::vector<neo::json> derives;

    for (const auto &derive : node.derives) {
        derives.push_back(get_node_json(derive.first));
        derives.push_back(derive.second.to_json());
    }

    json.section("UDTDeriveDecl", derives);
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Declaration, TypeBoundList) {
    IS_NOT_EMPTY;
    // FIXME: TypeBoundList := InstOfExpr (('||' | '&&') InstOfExpr)*
    // TypeBoundList := InstOfExpr (',' InstOfExpr)*)?

    ParseResult<InstOfExpr> bound = expr_parser.parse<InstOfExpr>(expr_parser.parse<Type>(), true);
    RETURN_IF_ERROR(bound);

    NodeT<TypeBoundList> node = make_node<TypeBoundList>(bound.value());

    while (CURRENT_TOKEN_IS(__TOKEN_N::tokens::OPERATOR_LOGICAL_AND)) {
        iter.advance();  // skip '&&'

        ParseResult<InstOfExpr> next = expr_parser.parse<InstOfExpr>(expr_parser.parse<Type>(), true);
        RETURN_IF_ERROR(next);

        node->bounds.emplace_back(next.value());
    }

    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, TypeBoundList) {
    std::vector<neo::json> bounds;

    for (const auto &bound : node.bounds) {
        bounds.push_back(get_node_json(bound));
    }

    json.section("TypeBoundList", bounds);
}

// ---------------------------------------------------------------------------------------------- //

/* TODO: DEPRECATE MERGED WITH LIST*/
AST_NODE_IMPL(Declaration, TypeBoundDecl) {
    IS_NOT_EMPTY;
    NOT_IMPLEMENTED;
}

AST_NODE_IMPL_VISITOR(Jsonify, TypeBoundDecl) { json.section("TypeBoundDecl"); }

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Declaration, RequiresDecl) {
    IS_NOT_EMPTY;
    // RequiresDecl := requires' '<' RequiresParamList '>' ('if' TypeBoundList)?

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_REQUIRES);
    iter.advance();  // skip 'requires

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_OPEN_ANGLE);
    iter.advance();  // skip '<'

    ParseResult<RequiresParamList> params = parse<RequiresParamList>();
    RETURN_IF_ERROR(params);

    NodeT<RequiresDecl> node = make_node<RequiresDecl>(params.value());

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_CLOSE_ANGLE);
    iter.advance();  // skip '>'

    if (CURRENT_TOKEN_IS(__TOKEN_N::KEYWORD_IF)) {
        iter.advance();  // skip 'if'

        ParseResult<TypeBoundList> bounds = parse<TypeBoundList>();
        RETURN_IF_ERROR(bounds);

        node->bounds = bounds.value();
    }

    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, RequiresDecl) {
    json.section("RequiresDecl")
        .add("params", get_node_json(node.params))
        .add("bounds", get_node_json(node.bounds));
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Declaration, StructDecl, const std::shared_ptr<__TOKEN_N::TokenList> &modifiers) {
    IS_NOT_EMPTY;
    // StructDecl := Modifiers 'struct' E.IdentExpr UDTDeriveDecl? RequiresDecl? S.Suite

    NodeT<StructDecl> node = make_node<StructDecl>(true);

    if (modifiers != nullptr) {
        for (auto &tok : *modifiers) {
            if (!node->modifiers.find_add(tok.current().get())) {
                return std::unexpected(
                    PARSE_ERROR(tok.current().get(), "invalid modifier for struct"));
            }
        }
    } else {
        while (node->modifiers.find_add(CURRENT_TOK)) {
            iter.advance();  // skip modifier
        }
    }

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_STRUCT);
    iter.advance();  // skip 'struct'

    ParseResult<IdentExpr> name = expr_parser.parse<IdentExpr>();
    RETURN_IF_ERROR(name);

    node->name = name.value();

    if (CURRENT_TOKEN_IS(__TOKEN_N::KEYWORD_DERIVES)) {
        ParseResult<UDTDeriveDecl> derives = parse<UDTDeriveDecl>();
        RETURN_IF_ERROR(derives);

        node->derives = derives.value();
    }

    if (CURRENT_TOKEN_IS(__TOKEN_N::KEYWORD_REQUIRES)) {
        ParseResult<RequiresDecl> generics = parse<RequiresDecl>();
        RETURN_IF_ERROR(generics);

        node->generics = generics.value();
    }

    if (CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_SEMICOLON)) {  // forward declaration
        iter.advance();                                        // skip ';'
        return node;
    }

    ParseResult<SuiteState> body = state_parser.parse<SuiteState>();
    RETURN_IF_ERROR(body);

    node->body = body.value();

    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, StructDecl) {
    json.section("StructDecl")
        .add("name", get_node_json(node.name))
        .add("derives", get_node_json(node.derives))
        .add("generics", get_node_json(node.generics))
        .add("body", get_node_json(node.body))
        .add("modifiers", node.modifiers.to_json());
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Declaration,
              ConstDecl,
              const std::shared_ptr<__TOKEN_N::TokenList> &modifiers) { /* TODO - MAYBE REMOVE */
    IS_NOT_EMPTY;
    // ConstDecl := Modifiers 'const' Modifiers VarDecl* ';'

    NodeT<ConstDecl> node = make_node<ConstDecl>(true);

    // ignore const modifer
    if (modifiers != nullptr) {
        for (auto &tok : *modifiers) {
            if (!node->vis.find_add(tok.current().get())) {
                return std::unexpected(
                    PARSE_ERROR(tok.current().get(), "invalid modifier for const"));
            }
        }
    } else {
        while (node->vis.find_add(CURRENT_TOK)) {
            iter.advance();  // skip modifier
        }

        IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_CONST);
        iter.advance();  // skip 'const'
    }

    while (node->modifiers.find_add(CURRENT_TOK)) {
        iter.advance();  // skip modifier
    }

    while
        CURRENT_TOKEN_IS(__TOKEN_N::IDENTIFIER) {
            ParseResult<VarDecl> var = parse<VarDecl>(true, true);  // force type and value
            RETURN_IF_ERROR(var);

            // if no value is provided type is required
            if ((var.value()->value == nullptr) && (var.value()->var->type == nullptr)) {
                return std::unexpected(PARSE_ERROR(var.value()->var->path->name,
                                                   "expected a type or value for const"));
            }

            node->vars.emplace_back(var.value());

            if (CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_COMMA)) {
                iter.advance();  // skip ','
            }
        }

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_SEMICOLON);
    iter.advance();  // skip ';'

    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, ConstDecl) {
    std::vector<neo::json> vars;

    for (const auto &var : node.vars) {
        vars.push_back(get_node_json(var));
    }

    json.section("ConstDecl")
        .add("vars", vars)
        .add("vis", node.vis.to_json())
        .add("modifiers", node.modifiers.to_json());
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Declaration, ExtendDecl, const std::shared_ptr<__TOKEN_N::TokenList> & /* unused */) {
    NOT_IMPLEMENTED;
}

AST_NODE_IMPL_VISITOR(Jsonify, ExtendDecl) { json.section("ExtendDecl"); }

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Declaration, ClassDecl, const std::shared_ptr<__TOKEN_N::TokenList> &modifiers) {
    IS_NOT_EMPTY;
    // ClassDecl := Modifiers 'class'  E.IdentExpr UDTDeriveDecl? RequiresDecl? S.Suite
    auto parse_extends = [this](NodeT<ClassDecl> &node) -> std::expected<void, ParseError> {
        // ExtendsDecl := 'extends' (VisDecl? E.Type (',' VisDecl? E.Type)*)?
        IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_IMPL);
        iter.advance();  // skip 'extends'

        AccessSpecifier access = AccessSpecifier(
            __TOKEN_N::Token(__TOKEN_N::KEYWORD_PUBLIC, "HZL_CMPILER_INL.ACCESS_SPECIFIER__.tmp"));
        if (AccessSpecifier::is_access_specifier(CURRENT_TOK)) {
            access = AccessSpecifier(CURRENT_TOK);
        }

        ParseResult<Type> type = expr_parser.parse<Type>();
        RETURN_IF_ERROR(type);

        node->extends.emplace_back(type.value(), access);

        while (CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_COMMA)) {
            iter.advance();  // skip ','

            AccessSpecifier access = AccessSpecifier(__TOKEN_N::Token(
                __TOKEN_N::KEYWORD_PUBLIC, "HZL_CMPILER_INL.ACCESS_SPECIFIER__.tmp"));
            if (AccessSpecifier::is_access_specifier(CURRENT_TOK)) {
                access = AccessSpecifier(CURRENT_TOK);
            }

            ParseResult<Type> next = expr_parser.parse<Type>();
            RETURN_IF_ERROR(next);

            node->extends.emplace_back(next.value(), access);
        }

        return {};
    };

    NodeT<ClassDecl> node = make_node<ClassDecl>(true);

    if (modifiers != nullptr) {
        for (auto &tok : *modifiers) {
            if (!node->modifiers.find_add(tok.current().get())) {
                return std::unexpected(
                    PARSE_ERROR(tok.current().get(), "invalid modifier for class"));
            }
        }
    } else {
        while (node->modifiers.find_add(CURRENT_TOK)) {
            iter.advance();  // skip modifier
        }
    }

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_CLASS);
    iter.advance();  // skip 'class'

    ParseResult<IdentExpr> name = expr_parser.parse<IdentExpr>();
    RETURN_IF_ERROR(name);

    node->name = name.value();

    if (CURRENT_TOKEN_IS(__TOKEN_N::KEYWORD_DERIVES)) {
        ParseResult<UDTDeriveDecl> derives = parse<UDTDeriveDecl>();
        RETURN_IF_ERROR(derives);

        node->derives = derives.value();
    }

    if (CURRENT_TOKEN_IS(__TOKEN_N::KEYWORD_IMPL)) {
        RETURN_IF_ERROR(parse_extends(node));
    }

    if (CURRENT_TOKEN_IS(__TOKEN_N::KEYWORD_REQUIRES)) {
        ParseResult<RequiresDecl> generics = parse<RequiresDecl>();
        RETURN_IF_ERROR(generics);

        node->generics = generics.value();
    }

    if (CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_SEMICOLON)) {  // forward declaration
        iter.advance();                                        // skip ';'
        return node;
    }

    ParseResult<SuiteState> body = state_parser.parse<SuiteState>();
    RETURN_IF_ERROR(body);

    node->body = body.value();

    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, ClassDecl) {
    json.section("ClassDecl")
        .add("name", get_node_json(node.name))
        .add("derives", get_node_json(node.derives))
        .add("generics", get_node_json(node.generics))
        .add("body", get_node_json(node.body))
        .add("modifiers", node.modifiers.to_json());
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Declaration, InterDecl, const std::shared_ptr<__TOKEN_N::TokenList> &modifiers) {
    IS_NOT_EMPTY;
    // InterDecl := Modifiers 'interface' E.IdentExpr UDTDeriveDecl? RequiresDecl? S.Suite

    NodeT<InterDecl> node = make_node<InterDecl>(true);

    if (modifiers != nullptr) {
        for (auto &tok : *modifiers) {
            if (!node->modifiers.find_add(tok.current().get())) {
                return std::unexpected(
                    PARSE_ERROR(tok.current().get(), "invalid modifier for interface"));
            }
        }
    } else {
        while (node->modifiers.find_add(CURRENT_TOK)) {
            iter.advance();  // skip modifier
        }
    }

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_INTERFACE);
    iter.advance();  // skip 'interface'

    ParseResult<IdentExpr> name = expr_parser.parse<IdentExpr>();
    RETURN_IF_ERROR(name);

    node->name = name.value();

    if (CURRENT_TOKEN_IS(__TOKEN_N::KEYWORD_DERIVES)) {
        ParseResult<UDTDeriveDecl> derives = parse<UDTDeriveDecl>();
        RETURN_IF_ERROR(derives);

        node->derives = derives.value();
    }

    if (CURRENT_TOKEN_IS(__TOKEN_N::KEYWORD_REQUIRES)) {
        ParseResult<RequiresDecl> generics = parse<RequiresDecl>();
        RETURN_IF_ERROR(generics);

        node->generics = generics.value();
    }

    if (CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_SEMICOLON)) {  // forward declaration
        return std::unexpected(
            PARSE_ERROR(CURRENT_TOK, "forward declaration's are not allowed for interface's"));
    }

    ParseResult<SuiteState> body = state_parser.parse<SuiteState>();
    RETURN_IF_ERROR(body);

    node->body = body.value();

    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, InterDecl) {
    json.section("InterDecl")
        .add("name", get_node_json(node.name))
        .add("derives", get_node_json(node.derives))
        .add("generics", get_node_json(node.generics))
        .add("body", get_node_json(node.body))
        .add("modifiers", node.modifiers.to_json());
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Declaration, EnumDecl, const std::shared_ptr<__TOKEN_N::TokenList> &modifiers) {
    IS_NOT_EMPTY;
    // EnumDecl := Modifiers 'enum' (('derives' E.Type)? Ident)? (('{' (EnumMemberDecl (',' EnumMemberDecl)*)? '}') | (':' (EnumMemberDecl) ';'))

    NodeT<EnumDecl> node = make_node<EnumDecl>(true);

    if (modifiers != nullptr) {
        for (auto &tok : *modifiers) {
            if (!node->vis.find_add(tok.current().get())) {
                return std::unexpected(
                    PARSE_ERROR(tok.current().get(), "invalid modifier for enum"));
            }
        }
    } else {
        while (node->vis.find_add(CURRENT_TOK)) {
            iter.advance();  // skip modifier
        }
    }

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_ENUM);
    iter.advance();  // skip 'enum'

    if (CURRENT_TOKEN_IS(__TOKEN_N::KEYWORD_DERIVES)) {
        ParseResult<Type> derives = expr_parser.parse<Type>();
        RETURN_IF_ERROR(derives);

        node->derives = derives.value();
    }

    if (CURRENT_TOKEN_IS(__TOKEN_N::IDENTIFIER)) {
        ParseResult<IdentExpr> name = expr_parser.parse<IdentExpr>();
        RETURN_IF_ERROR(name);

        node->name = name.value();
    } else {
        if (node->derives) {
            return std::unexpected(PARSE_ERROR(CURRENT_TOK, "anonymous enum cannot have specified type"));
        }
    }
    
    if (CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_OPEN_BRACE)) {
        iter.advance();  // skip '{'

        while (CURRENT_TOKEN_IS(__TOKEN_N::IDENTIFIER)) {
            ParseResult<EnumMemberDecl> member = parse<EnumMemberDecl>();
            RETURN_IF_ERROR(member);

            node->members.emplace_back(member.value());

            if (!CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_COMMA)) {
                break;
            }
            
            iter.advance();  // skip ','
        }

        IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_CLOSE_BRACE);
        iter.advance();  // skip '}'
    } else if (CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_COLON)) {
        iter.advance();  // skip ':'

        ParseResult<EnumMemberDecl> member = parse<EnumMemberDecl>();
        RETURN_IF_ERROR(member);

        node->members.emplace_back(member.value());

        IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_SEMICOLON);
        iter.advance();  // skip ';'
    } else {
        return std::unexpected(PARSE_ERROR(CURRENT_TOK, "expected '{' or ':' for enum"));
    }

    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, EnumDecl) {
    std::vector<neo::json> members;

    for (const auto &member : node.members) {
        members.push_back(get_node_json(member));
    }

    json.section("EnumDecl")
        .add("derives", get_node_json(node.derives))
        .add("members", members)
        .add("vis", node.vis.to_json())
        .add("name", get_node_json(node.name));
}

// ---------------------------------------------------------------------------------------------- //

// type Foo requires <T> = Bar::<T>;

AST_NODE_IMPL(Declaration, TypeDecl, const std::shared_ptr<__TOKEN_N::TokenList> &modifiers) {
    IS_NOT_EMPTY;
    // TypeDecl := Modifiers 'type' E.IdentExpr RequiresDecl? '=' E ';'

    NodeT<TypeDecl> node = make_node<TypeDecl>(true);

    if (modifiers != nullptr) {
        for (auto &tok : *modifiers) {
            if (!node->vis.find_add(tok.current().get())) {
                return std::unexpected(
                    PARSE_ERROR(tok.current().get(), "invalid modifier for type"));
            }
        }
    } else {
        while (node->vis.find_add(CURRENT_TOK)) {
            iter.advance();  // skip modifier
        }
    }

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_TYPE);
    iter.advance();  // skip 'type'

    ParseResult<IdentExpr> name = expr_parser.parse<IdentExpr>();
    RETURN_IF_ERROR(name);

    node->name = name.value();

    if (CURRENT_TOKEN_IS(__TOKEN_N::KEYWORD_REQUIRES)) {
        ParseResult<RequiresDecl> generics = parse<RequiresDecl>();
        RETURN_IF_ERROR(generics);

        node->generics = generics.value();
    }

    IS_EXCEPTED_TOKEN(__TOKEN_N::OPERATOR_ASSIGN);
    iter.advance();  // skip '='

    ParseResult<Type> type = expr_parser.parse<Type>();
    RETURN_IF_ERROR(type);

    node->type = type.value();

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_SEMICOLON);
    iter.advance();  // skip ';'

    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, TypeDecl) {
    json.section("TypeDecl")
        .add("name", get_node_json(node.name))
        .add("generics", get_node_json(node.generics))
        .add("type", get_node_json(node.type))
        .add("vis", node.vis.to_json());
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Declaration,
              FuncDecl,
              const std::shared_ptr<__TOKEN_N::TokenList> &modifiers,
              bool                                         force_name) {
    IS_NOT_EMPTY;
    // FuncDecl :=  Modifiers 'fn' E.PathExpr '(' VarDecl[true]* ')' RequiresDecl? ('->'
    // E.TypeExpr)? (S.Suite | ';' | '=' ('default' | 'delete'))

    // one rule to follow is we cant have keyword arguments after positional arguments
    bool has_keyword    = false;
    bool found_requires = false;

    NodeT<FuncDecl> node = make_node<FuncDecl>(true);

    if (modifiers != nullptr) {
        for (auto &tok : *modifiers) {
            if (!node->modifiers.find_add(tok.current().get())) {
                return std::unexpected(
                    PARSE_ERROR(tok.current().get(), "invalid modifier for function"));
            }
        }
    } else {
        while (node->modifiers.find_add(CURRENT_TOK)) {
            iter.advance();  // skip modifier
        }
    }

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_FUNCTION);
    node->marker = CURRENT_TOK; // save 'fn' token
    iter.advance();  // skip 'fn'

    bool has_name = true;

    if (!force_name && !(CURRENT_TOKEN_IS(__TOKEN_N::IDENTIFIER) || CURRENT_TOKEN_IS(__TOKEN_N::OPERATOR_SCOPE))) {
        has_name = false;
    }

    if (has_name) {
        ParseResult<PathExpr> name = expr_parser.parse<PathExpr>();
        RETURN_IF_ERROR(name);

        if (name.value()->type == PathExpr::PathType::Dot) {
            return std::unexpected(PARSE_ERROR(CURRENT_TOK, "invalid function name"));
        }

        node->name = name.value();
    } else {
        node->name = nullptr;
    }

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_OPEN_PAREN);
    iter.advance();  // skip '('

    if (!CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_CLOSE_PAREN)) {
        __TOKEN_N::Token starting = CURRENT_TOK;
        ParseResult<VarDecl> first_param = parse<VarDecl>(true);
        RETURN_IF_ERROR(first_param);

        node->params.emplace_back(first_param.value());

        while (CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_COMMA)) {
            iter.advance();  // skip ','

            ParseResult<VarDecl> param = parse<VarDecl>(true);
            RETURN_IF_ERROR(param);

            if (param.value()->value != nullptr) {
                has_keyword = true;
            } else { // if theres no value but theres a keyword arg
                if (has_keyword) {
                    return std::unexpected(
                        PARSE_ERROR(starting, "positional argument after default argument"));
                }
            }

            node->params.emplace_back(param.value());
        }
    }
    
    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_CLOSE_PAREN);
    iter.advance();  // skip ')'

    if (CURRENT_TOKEN_IS(__TOKEN_N::KEYWORD_REQUIRES)) {
        ParseResult<RequiresDecl> generics = parse<RequiresDecl>();
        RETURN_IF_ERROR(generics);

        node->generics = generics.value();
        found_requires = true;
    }

    if (CURRENT_TOKEN_IS(__TOKEN_N::OPERATOR_ARROW)) {
        iter.advance();  // skip '->'

        ParseResult<Type> returns = expr_parser.parse<Type>();
        RETURN_IF_ERROR(returns);

        node->returns = returns.value();

        if (CURRENT_TOKEN_IS(__TOKEN_N::KEYWORD_REQUIRES)) {
            if (found_requires) {
                return std::unexpected(PARSE_ERROR(CURRENT_TOK, "duplicate requires clause"));
            }

            ParseResult<RequiresDecl> generics = parse<RequiresDecl>();
            RETURN_IF_ERROR(generics);

            node->generics = generics.value();
        }
    }

    if (CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_SEMICOLON)) {
        iter.advance();  // skip ';'
    } else if (CURRENT_TOKEN_IS(__TOKEN_N::OPERATOR_ASSIGN)) {
        iter.advance();  // skip '='

        while (node->qualifiers.find_add(CURRENT_TOK)) {
            iter.advance();  // skip qualifier
        }

        IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_SEMICOLON);
        iter.advance();  // skip ';'
    } else if (CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_OPEN_BRACE)) {
        ParseResult<SuiteState> body = state_parser.parse<SuiteState>();
        RETURN_IF_ERROR(body);

        node->body = body.value();
    } else {
        return std::unexpected(PARSE_ERROR(CURRENT_TOK, "expected function body"));
    }

    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, FuncDecl) {
    std::vector<neo::json> params;

    for (const auto &param : node.params) {
        params.push_back(get_node_json(param));
    }

    json.section("FuncDecl")
        .add("name", get_node_json(node.name))
        .add("params", params)
        .add("generics", get_node_json(node.generics))
        .add("returns", get_node_json(node.returns))
        .add("body", get_node_json(node.body))
        .add("modifiers", node.modifiers.to_json())
        .add("qualifiers", node.qualifiers.to_json());
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Declaration, VarDecl, bool force_type, bool force_value) {
    IS_NOT_EMPTY;
    // VarDecl := S.NamedVarSpecifier ('=' E)? ~ also pass in a bool to force type need

    ParseResult<NamedVarSpecifier> var = state_parser.parse<NamedVarSpecifier>(force_type);
    RETURN_IF_ERROR(var);

    if (CURRENT_TOKEN_IS(__TOKEN_N::OPERATOR_ASSIGN)) {
        iter.advance();  // skip '='

        ParseResult<> value = expr_parser.parse();
        RETURN_IF_ERROR(value);

        NodeT<VarDecl> node = make_node<VarDecl>(var.value(), value.value());
        return node;
    }

    if (force_value) {
        return std::unexpected(PARSE_ERROR(CURRENT_TOK, "expected value for variable"));
    }

    NodeT<VarDecl> node = make_node<VarDecl>(var.value());
    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, VarDecl) {
    json.section("VarDecl")
        .add("var", get_node_json(node.var))
        .add("value", get_node_json(node.value));
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Declaration, FFIDecl, const std::shared_ptr<__TOKEN_N::TokenList> &modifiers) {
    IS_NOT_EMPTY;
    // FFIDecl := Modifiers 'ffi' L.StringLiteral D

    NodeT<FFIDecl> node = make_node<FFIDecl>(true);

    if (modifiers != nullptr) {
        for (auto &tok : *modifiers) {
            if (!node->vis.find_add(tok.current().get())) {
                return std::unexpected(
                    PARSE_ERROR(tok.current().get(), "invalid modifier for ffi"));
            }
        }
    } else {
        while (node->vis.find_add(CURRENT_TOK)) {
            iter.advance();  // skip modifier
        }
    }

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_FFI);
    iter.advance();  // skip 'ffi'

    IS_EXCEPTED_TOKEN(__TOKEN_N::LITERAL_STRING);
    node->name = expr_parser.parse<LiteralExpr>().value();

    ParseResult<ImportState> ext_import = state_parser.parse<ImportState>(true);
    RETURN_IF_ERROR(ext_import);

    node->value = ext_import.value();
    if (ext_import.value()->type == ImportState::Type::Single &&
        node->name->value.value() == "\"c++\"") {
        NodeT<SingleImport> single = __AST_N::as<SingleImport>(ext_import.value()->import);

        if (single->type == SingleImport::Type::Module) {
            NodeT<ScopePathExpr> path = __AST_N::as<ScopePathExpr>(single->path);
            token::Token         tok  = path->get_back_name();

            if (tok.value() == "__/helix$$internal/__") {
                /// this is completely disallowed theres no marker for this
                return std::unexpected(
                    PARSE_ERROR(node->name->value,
                                "global module imports are not allowed, remove the first `::`"));
            }

            error::Panic(error::CodeError{
                .pof      = const_cast<__TOKEN_N::Token *>(&tok),
                .err_code = 4.1002,
                .mark_pof = true,
                .fix_fmt_args{},
                .err_fmt_args{"the specified module must be an exported c++ module otherwise use a "
                              "\"...\" (path-based) import"},
                .opt_fixes{},
            });
        }
    }

    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, FFIDecl) {
    json.section("FFIDecl")
        .add("name", get_node_json(node.name))
        .add("value", get_node_json(node.value))
        .add("vis", node.vis.to_json());
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Declaration, LetDecl, const std::shared_ptr<__TOKEN_N::TokenList> &modifiers) {
    IS_NOT_EMPTY;
    // LetDecl := Modifiers 'let' Modifiers VarDecl* ';'

    NodeT<LetDecl> node = make_node<LetDecl>(true);

    if (modifiers != nullptr) {
        for (auto &tok : *modifiers) {
            if (!(node->vis.find_add(tok.current().get()) ||
                  node->modifiers.find_add(tok.current().get()))) {
                return std::unexpected(
                    PARSE_ERROR(tok.current().get(), "invalid modifier for var"));
            }
        }
    } else {
        while (node->vis.find_add(CURRENT_TOK)) {
            iter.advance();  // skip modifier
        }
    }

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_LET);
    iter.advance();  // skip 'let'

    while (node->modifiers.find_add(CURRENT_TOK)) {
        iter.advance();  // skip modifier
    }

    while
        CURRENT_TOKEN_IS(__TOKEN_N::IDENTIFIER) {
            ParseResult<VarDecl> var = parse<VarDecl>();
            RETURN_IF_ERROR(var);

            // if no value is provided type is required
            if ((var.value()->value == nullptr) && (var.value()->var->type == nullptr)) {
                return std::unexpected(
                    PARSE_ERROR(var.value()->var->path->name, "expected a type or value for var"));
            }

            node->vars.emplace_back(var.value());

            if (CURRENT_TOKEN_IS(__TOKEN_N::PUNCTUATION_COMMA)) {
                iter.advance();  // skip ','
            }
        }

    IS_EXCEPTED_TOKEN(__TOKEN_N::PUNCTUATION_SEMICOLON);
    iter.advance();  // skip ';'

    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, LetDecl) {
    std::vector<neo::json> vars;

    for (const auto &var : node.vars) {
        vars.push_back(get_node_json(var));
    }

    json.section("LetDecl")
        .add("vars", vars)
        .add("vis", node.vis.to_json())
        .add("modifiers", node.modifiers.to_json());
}

// ---------------------------------------------------------------------------------------------- //

/* TODO: MERGE WITH FUNCTION DECL */
AST_NODE_IMPL(Declaration, OpDecl, const std::shared_ptr<__TOKEN_N::TokenList> &modifiers) {
    IS_NOT_EMPTY;
    // OpDecl := Modifiers 'op' T FuncDecl[no_SharedModifiers=true]

    NodeT<OpDecl> node = make_node<OpDecl>(true);

    if (modifiers != nullptr) {
        for (auto &tok : *modifiers) {
            if (!node->modifiers.find_add(tok.current().get())) {
                return std::unexpected(
                    PARSE_ERROR(tok.current().get(), "invalid modifier for an operator"));
            }
        }
    } else {
        while (node->modifiers.find_add(CURRENT_TOK)) {
            iter.advance();  // skip modifier
        }
    }

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_OPERATOR);

    // TODO: Find a better way to do this...
    while (iter.advance().get().token_kind() != token::KEYWORD_FUNCTION) {
        node->op.push_back(CURRENT_TOK);  // skip token and push it
    }

    /// 'fn' here, so we now need to parse the function in name optional mode
    ParseResult<FuncDecl> fn = parse<FuncDecl>(nullptr, false);
    RETURN_IF_ERROR(fn);

    // NodeT<FuncDecl> fn_node = make_node<FuncDecl>();

    node->func.swap(fn.value());

    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, OpDecl) {
    json.section("OpDecl")
        .add("op", node.op)
        .add("func", get_node_json(node.func))
        .add("modifiers", node.modifiers.to_json());
}

// ---------------------------------------------------------------------------------------------- //

AST_NODE_IMPL(Declaration, ModuleDecl, const std::shared_ptr<__TOKEN_N::TokenList> &modifiers) {
    IS_NOT_EMPTY;
    // ModuleDecl := 'inline'? 'module' E.PathExpr[scopeOnly=true] S.Suite

    if (modifiers != nullptr) {
        for (auto &tok : *modifiers) {
            return std::unexpected(
                PARSE_ERROR(tok.current().get(), "invalid specifier for module"));
        }
    }

    bool inline_module = false;

    if (CURRENT_TOKEN_IS(__TOKEN_N::KEYWORD_INLINE)) {
        inline_module = true;
        iter.advance();  // skip 'inline'
    }

    IS_EXCEPTED_TOKEN(__TOKEN_N::KEYWORD_MODULE);
    iter.advance();  // skip 'module'

    ParseResult<PathExpr> name = expr_parser.parse<PathExpr>();
    RETURN_IF_ERROR(name);

    ParseResult<SuiteState> body = state_parser.parse<SuiteState>();
    RETURN_IF_ERROR(body);

    NodeT<ModuleDecl> node = make_node<ModuleDecl>(name.value(), body.value(), inline_module);
    return node;
}

AST_NODE_IMPL_VISITOR(Jsonify, ModuleDecl) {
    json.section("ModuleDecl")
        .add("name", get_node_json(node.name))
        .add("body", get_node_json(node.body))
        .add("inline_module", node.inline_module ? "true" : "false");
}

// ---------------------------------------------------------------------------------------------- //

AST_BASE_IMPL(Declaration, parse) {
    IS_NOT_EMPTY;

    __TOKEN_N::Token tok = CURRENT_TOK;  /// get the current token from the iterator
    std::shared_ptr<__TOKEN_N::TokenList> modifiers = nullptr;  /// create a pointer to the modifiers

    /* TODO: make this not happen if bool is passed */
    while (Modifiers::is_modifier(tok)) {
        if (modifiers == nullptr || modifiers->empty()) {
            modifiers = std::make_shared<__TOKEN_N::TokenList>();
        }

        if (tok == __TOKEN_N::KEYWORD_FFI &&
            (HAS_NEXT_TOK &&
             (NEXT_TOK == __TOKEN_N::LITERAL_STRING || NEXT_TOK == __TOKEN_N::LITERAL_CHAR))) {
            break;
        }

        modifiers->push_back(tok);  /// add the modifier to the list
        iter.advance();             /// advance the iterator

        tok = CURRENT_TOK;  /// get the next token
    }

    if (tok.token_kind() == __TOKEN_N::IDENTIFIER) {
        if (modifiers != nullptr) {
            for (std::iter_difference_t<__TOKEN_N::TokenList> i = 0;
                 i < static_cast<std::iter_difference_t<__TOKEN_N::TokenList>>(modifiers->size());
                 i++) {
                if (modifiers->at(i).token_kind() == __TOKEN_N::KEYWORD_CONST) {
                    // remove the const modifier from the list
                    modifiers->erase(modifiers->cbegin() + i);
                    return parse<ConstDecl>(modifiers);
                }
            }
        }
    }

    switch (tok.token_kind()) {
        case __TOKEN_N::KEYWORD_CLASS:
            return parse<ClassDecl>(modifiers);
        case __TOKEN_N::KEYWORD_ENUM:
            if (modifiers != nullptr) {
                return std::unexpected(PARSE_ERROR(tok, "invalid modifier for enum"));
            }

            return parse<EnumDecl>(modifiers);
        case __TOKEN_N::KEYWORD_INTERFACE:
            return parse<InterDecl>(modifiers);
        case __TOKEN_N::KEYWORD_LET:
            return parse<LetDecl>(modifiers);
        case __TOKEN_N::KEYWORD_FFI:
            return parse<FFIDecl>(modifiers);
        case __TOKEN_N::KEYWORD_FUNCTION:
            return parse<FuncDecl>(modifiers);
        case __TOKEN_N::KEYWORD_OPERATOR:
            return parse<OpDecl>(modifiers);
        case __TOKEN_N::KEYWORD_TYPE:
            return parse<TypeDecl>(modifiers);
        // case __TOKEN_N::KEYWORD_UNION:
        //     return parse<UnionDecl>(modifiers);
        // TODO: evaluate if unions should be statements or declarations
        case __TOKEN_N::KEYWORD_STRUCT:
            return parse<StructDecl>(modifiers);
        case __TOKEN_N::KEYWORD_MODULE:
            return parse<ModuleDecl>(modifiers);
        default:
            return state_parser.parse(modifiers);
    }
}