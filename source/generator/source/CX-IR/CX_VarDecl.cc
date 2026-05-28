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

#include "utils.hh"

CX_VISIT_IMPL(ConstDecl) {
    for (const auto &param : node.vars) {
        ADD_TOKEN(CXX_CONST);
        param->accept(*this);
    };
}

CX_VISIT_IMPL(VarDecl) {
    // if (node.var->type, ADD_PARAM(node.var->type);) else { ADD_TOKEN(CXX_AUTO); }

    ADD_NODE_PARAM(var);

    if (node.value) {
        ADD_TOKEN_AS_VALUE(CXX_CORE_OPERATOR, "=");
        ADD_NODE_PARAM(value);
    }
}

CX_VISIT_IMPL_VA(LetDecl, bool is_in_statement) {

    // for (int i =0; i<node.modifiers.get<__AST_N::TypeSpecifier>().size(); ++i) {

    //     // node.modifiers.

    // }

    // insert all the modifiers at the start
    auto mods = node.modifiers.get<__AST_N::FunctionSpecifier>();

    for (const auto &mod : mods) {
        if (mod.type == __AST_N::FunctionSpecifier::Specifier::Static) {
            ADD_TOKEN_AS_TOKEN(CXX_STATIC, mod.marker);
        }
    }

    for (const auto &param : node.vars) {
        param->accept(*this);
        
        if (is_in_statement) {
            ADD_TOKEN(CXX_SEMICOLON);
        }
    };
}
