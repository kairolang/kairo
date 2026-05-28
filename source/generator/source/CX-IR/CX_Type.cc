/// --- The Kairo Project -------------------------------------------------- ///
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

#include "generator/include/config/Gen_config.def"
#include "utils.hh"

CX_VISIT_IMPL(Type) {  // TODO Modifiers
    if (node.specifiers.contains(token::tokens::KEYWORD_YIELD)) {
        auto marker = node.specifiers.get(token::tokens::KEYWORD_YIELD);

        ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "kairo", marker);
        ADD_TOKEN(CXX_SCOPE_RESOLUTION);

        ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "$generator", marker);
        ANGLE_DELIMIT(ADD_NODE_PARAM(value); ADD_NODE_PARAM(generics););

        return;
    }

    if (node.nullable) {
        __TOKEN_N::Token marker;

        if (node.value->getNodeType() == __AST_NODE::nodes::UnaryExpr) {
            marker = node.nullable_marker;
        }

        ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "kairo", marker);
        ADD_TOKEN(CXX_SCOPE_RESOLUTION);

        ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "$question", marker);
        ANGLE_DELIMIT(ADD_PARAM(__AST_N::as<__AST_NODE::UnaryExpr>(node.value)->opd); ADD_NODE_PARAM(generics););

        return;
    }

    if (node.is_fn_ptr) {  // $function<rt(prm)>
        ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "kairo", node.fn_ptr.marker);
        ADD_TOKEN(CXX_SCOPE_RESOLUTION);

        ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "$function", node.fn_ptr.marker);
        ADD_TOKEN(CXX_LESS_THAN);

        if (node.fn_ptr.returns) {
            ADD_PARAM(node.fn_ptr.returns);
        } else {
            ADD_TOKEN(CXX_VOID);
        }
        PAREN_DELIMIT(  //
            if (!node.fn_ptr.params.empty()) {
                for (const auto &prm : node.fn_ptr.params) {
                    ADD_PARAM(prm);
                    ADD_TOKEN(CXX_COMMA);
                }

                tokens.pop_back();  // remove the last comma added
            }  //
        );

        ADD_TOKEN(CXX_GREATER_THAN);
        return;
    }

    ADD_NODE_PARAM(value);
    ADD_NODE_PARAM(generics);
}
