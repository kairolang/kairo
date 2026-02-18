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

#include <concepts>
#include <vector>

#include "generator/include/config/Gen_config.def"
#include "parser/ast/include/config/AST_config.def"
#include "parser/ast/include/nodes/AST_declarations.hh"
#include "parser/ast/include/types/AST_types.hh"
#include "utils.hh"

CX_VISIT_IMPL_VA(FuncDecl, bool no_return_t) {
    if (node.is_op) {
        throw std::runtime_error(
            std::string(colors::fg16::green) + std::string(__FILE__) + ":" +
            std::to_string(__LINE__) + colors::reset + std::string(" - ") +
            "Function Declaration is missing the name param (ub), open an issue on github.");
    }

    ADD_NODE_PARAM(generics);

    // add the modifiers
    // 'inline' | 'async' | 'static' | 'const' | 'eval'
    // codegen:
    //      inline -> inline
    //      async -> different codegen (not supported yet)
    //      static -> static
    //      const -> special case codegen
    //      eval -> constexpr
    //      const eval -> consteval

    add_func_modifiers(this, node.modifiers);
    check_for_yield_and_panic(node.body, node.returns);

    if (!no_return_t) {
        ADD_TOKEN(CXX_AUTO);  // auto
    }

    ADD_NODE_PARAM(name);   // name
    PAREN_DELIMIT(          //
        COMMA_SEP(params);  // (params)
    );

    add_func_specifiers(this, node.modifiers);

    if (!no_return_t) {
        ADD_TOKEN(CXX_PTR_ACC);  // ->

        if (node.returns != nullptr) {  // return type
            ADD_NODE_PARAM(returns);
        } else {
            ADD_TOKEN_AT_LOC(CXX_VOID, node.marker);
        }
    }

    if (node.modifiers.contains(__TOKEN_N::KEYWORD_OVERRIDE)) {
        this->append(std::make_unique<__CXIR_CODEGEN_N::CX_Token>(
            __CXIR_CODEGEN_N::cxir_tokens::CXX_OVERRIDE,
            node.modifiers.get(__TOKEN_N::KEYWORD_OVERRIDE)));
    }

    if (node.modifiers.contains(__TOKEN_N::KEYWORD_DELETE)) {
        // add and = and delete to the function decl
        this->append(
            std::make_unique<__CXIR_CODEGEN_N::CX_Token>(__CXIR_CODEGEN_N::cxir_tokens::CXX_EQUAL));
        this->append(std::make_unique<__CXIR_CODEGEN_N::CX_Token>(
            __CXIR_CODEGEN_N::cxir_tokens::CXX_DELETE,
            node.modifiers.get(__TOKEN_N::KEYWORD_DELETE)));
    } else if (node.modifiers.contains(__TOKEN_N::KEYWORD_DEFAULT)) {
        // add and = and default to the function decl
        this->append(
            std::make_unique<__CXIR_CODEGEN_N::CX_Token>(__CXIR_CODEGEN_N::cxir_tokens::CXX_EQUAL));
        this->append(std::make_unique<__CXIR_CODEGEN_N::CX_Token>(
            __CXIR_CODEGEN_N::cxir_tokens::CXX_DEFAULT,
            node.modifiers.get(__TOKEN_N::KEYWORD_DEFAULT)));
    }

    NO_EMIT_FORWARD_DECL_SEMICOLON;

    if (node.body && node.body->body) {
        if (node.modifiers.contains(__TOKEN_N::KEYWORD_DELETE) ||
            node.modifiers.contains(__TOKEN_N::KEYWORD_DEFAULT)) {
            auto fail = node.name->get_back_name();
            error::Panic(error::CodeError{
                .pof          = &fail,
                .err_code     = 0.3002,
                .err_fmt_args = {"can not have a body for a deleted or defaulted function"}});
        }

        // adds and removes any nested functions
        BRACE_DELIMIT(                                                            //
            std::erase_if(node.body->body->body, ModifyNestedFunctions(this)););  //
    } else {
        ADD_TOKEN(CXX_SEMICOLON);
    }
}
