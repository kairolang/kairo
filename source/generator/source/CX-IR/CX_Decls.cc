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

#include "parser/ast/include/config/AST_config.def"
#include "parser/ast/include/nodes/AST_expressions.hh"
#include "utils.hh"

CX_VISIT_IMPL(RequiresParamDecl) {
    if (node.is_const) {
        if (node.var && !node.var->type) {
            CODEGEN_ERROR(node.var->path->name, "const requires a type");
            return;
        };
    }

    if (node.var->type) {           //
        ADD_NODE_PARAM(var->type);  // TODO: verify
    } else {
        ADD_TOKEN(CXX_TYPENAME);  // template <typename
    }

    ADD_NODE_PARAM(var->path);

    if (node.value) {                                //
        ADD_TOKEN_AS_VALUE(CXX_CORE_OPERATOR, "=");  //
        ADD_NODE_PARAM(value);                       //
    };
}

CX_VISIT_IMPL(RequiresParamList) {  // -> (param (',' param)*)?
    COMMA_SEP(params);
}

CX_VISIT_IMPL(EnumMemberDecl) {
    ADD_NODE_PARAM(name);
    if (node.value) {
        ADD_TOKEN_AS_VALUE(CXX_CORE_OPERATOR, "=");
        ADD_NODE_PARAM(value);
    };
}

CX_VISIT_IMPL(UDTDeriveDecl) {

    switch (node.derives[0].second.type) {
        case __AST_N::AccessSpecifier::Specifier::Internal:
            CXIR_NOT_IMPLEMENTED;  // TODO: ERROR?
            break;
        case __AST_N::AccessSpecifier::Specifier::Public:
            ADD_TOKEN(CXX_PUBLIC);
            break;
        case __AST_N::AccessSpecifier::Specifier::Protected:
            ADD_TOKEN(CXX_PROTECTED);
            break;
        case __AST_N::AccessSpecifier::Specifier::Private:
            ADD_TOKEN(CXX_PRIVATE);
            break;
    }

    ADD_NODE_PARAM(derives[0].first);
    for (size_t i = 1; i < node.derives.size(); ++i) {
        ADD_TOKEN(CXX_COMMA);
        switch (node.derives[i].second.type) {
            case __AST_N::AccessSpecifier::Specifier::Internal:
                CXIR_NOT_IMPLEMENTED;  // TODO: ERROR?
                break;
            case __AST_N::AccessSpecifier::Specifier::Public:
                ADD_TOKEN(CXX_PUBLIC);
                break;
            case __AST_N::AccessSpecifier::Specifier::Protected:
                ADD_TOKEN(CXX_PROTECTED);
                break;
            case __AST_N::AccessSpecifier::Specifier::Private:
                ADD_TOKEN(CXX_PRIVATE);
                break;
        }

        ADD_NODE_PARAM(derives[i].first);
    }
}

CX_VISIT_IMPL(TypeBoundList){

    SEP(bounds, ADD_TOKEN(CXX_LOGICAL_AND))

}

CX_VISIT_IMPL(TypeBoundDecl) {
    ADD_NODE_PARAM(bound);
}

CX_VISIT_IMPL(RequiresDecl) {
    // -> 'template' '<' params '>'
    ADD_TOKEN(CXX_TEMPLATE);

    ANGLE_DELIMIT(               //
        ADD_NODE_PARAM(params);  //
    );

    if (node.bounds) {
        ADD_TOKEN(CXX_REQUIRES);
        ADD_NODE_PARAM(bounds);
    }
}

CX_VISIT_IMPL(ModuleDecl) {

    if (node.inline_module) {
        ADD_TOKEN(CXX_INLINE);
    }

    // if (node.name->type == __AST_NODE::PathExpr::PathType::Scope) {
    //     // cast as ScopePathExpr
    //     auto path = __AST_N::as<__AST_NODE::ScopePathExpr>(node.name->path);
    //     // keep adding more namespaces for each part
    //     auto parts = path->path;

    //     for (const auto & part : parts) {
    //         ADD_TOKEN(CXX_NAMESPACE);
    //         ADD_PARAM(part);

    //         if (part != parts.back()) {
    //             ADD_TOKEN(CXX_LBRACE);
    //         }
    //     }

    //     node.body->accept(*this);

    //     for (size_t i = 0; i < (parts.size() - 1); ++i) {
    //         ADD_TOKEN(CXX_LBRACE);
    //     }

    //     return;
    // }
    
    ADD_TOKEN(CXX_NAMESPACE);
    ADD_NODE_PARAM(name);

    ADD_NODE_PARAM_BODY();
}

CX_VISIT_IMPL(EnumDecl) {

    ADD_TOKEN(CXX_ENUM);

    if (node.name != nullptr) {
        ADD_TOKEN(CXX_CLASS);
        ADD_NODE_PARAM(name);
    }

    if (node.derives) {
        ADD_TOKEN(CXX_COLON);
        ADD_NODE_PARAM(derives);
    }

    BRACE_DELIMIT(           //
        COMMA_SEP(members);  //
    );

    ADD_TOKEN(CXX_SEMICOLON);
}

CX_VISIT_IMPL(TypeDecl) {
    ADD_NODE_PARAM(generics);
    ADD_TOKEN(CXX_USING);
    ADD_NODE_PARAM(name);
    ADD_TOKEN_AS_VALUE(CXX_CORE_OPERATOR, "=");
    ADD_NODE_PARAM(type);
}

CX_VISIT_IMPL(FFIDecl) {
    using namespace __AST_N;
    if (node.name->value.value() != "\"c++\"") {
        throw std::runtime_error("Only C++ is supported at the moment");
    }

    if (node.value->getNodeType() == node::nodes::ImportState) {
        NodeT<node::ImportState> import = __AST_N::as<node::ImportState>(node.value);

        if (import->type != node::ImportState::Type::Single) {
            throw std::runtime_error("Only single imports are supported at the moment");
        }

        NodeT<node::SingleImport> single = __AST_N::as<node::SingleImport>(import->import);

        if (single->type == node::SingleImport::Type::Module) {
            NodeT<node::ScopePathExpr> path = __AST_N::as<node::ScopePathExpr>(single->path);

            ADD_TOKEN(CXX_IMPORT);

            for (auto &part : path->path) {
                ADD_PARAM(part);
                ADD_TOKEN(CXX_DOT);
            }

            if (path->path.size() > 0) {
                ADD_PARAM(path->access);
            }

            ADD_TOKEN(CXX_SEMICOLON);
        } else {
            ADD_TOKEN(CXX_PP_INCLUDE);
            ADD_TOKEN_AS_TOKEN(CXX_CORE_LITERAL,
                               __AST_N::as<node::LiteralExpr>(single->path)->value);
        }

    } else {
        throw std::runtime_error("Only string literals are supported at the moment");
    }
}
