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

#include <utility>

#include "generator/include/config/Gen_config.def"
#include "parser/ast/include/AST.hh"
#include "parser/ast/include/nodes/AST_expressions.hh"
#include "parser/ast/include/nodes/AST_statements.hh"
#include "utils.hh"

void generator::CXIR::CXIR::visit(__AST_NODE::Program &node) {
    std::erase_if(node.children, [&](const auto &child) {
        if (child->getNodeType() == __AST_NODE::nodes::FFIDecl) {
            child->accept(*this);
            return true;
        }
        return false;
    });

    std::string _namespace = helix::abi::mangle(node.get_file_name(), helix::abi::ObjectType::Module);

    error::NAMESPACE_MAP[_namespace] =
        helix::abi::mangle(std::filesystem::path(node.get_file_name()).stem().generic_string(), helix::abi::ObjectType::Module);

    // insert header guards
    ADD_TOKEN(CXX_PP_IFNDEF);
    ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, _namespace + "_M");
    ADD_TOKEN(CXX_PP_DEFINE);
    ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, _namespace + "_M");

    ADD_TOKEN_AT_LOC(
        CXX_NAMESPACE,
        token::Token(1,
                     1,
                     1,
                     1,
                     "",
                     std::filesystem::path(node.get_file_name()).stem().generic_string(),
                     " "));

    ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, "helix");
    ADD_TOKEN(CXX_LBRACE);

    bool trivially_import = contains_trivial_import_directive(node.annotations);

    if (!trivially_import) {
        ADD_TOKEN(CXX_NAMESPACE);
        ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, _namespace);
        ADD_TOKEN(CXX_LBRACE);
    }

    __AST_N::NodeT<__AST_NODE::FuncDecl> main_func = nullptr;

    std::for_each(node.children.begin(), node.children.end(), [&](const auto &child) {
        if (child->getNodeType() == __AST_NODE::nodes::FuncDecl) {
            __AST_N::NodeT<__AST_NODE::FuncDecl> func = __AST_N::as<__AST_NODE::FuncDecl>(child);
            auto                                 name = func->get_name_t();

            if (!name.empty() && name.size() == 1) {
                /// all allowed main functions in all platforms of c++ are:
                /// main, wmain, WinMain, wWinMain, _tmain, _tWinMain

                if (name[0].value() == "main" || name[0].value() == "_main" ||
                    name[0].value() == "wmain" || name[0].value() == "WinMain" ||
                    name[0].value() == "wWinMain" || name[0].value() == "_tmain" ||
                    name[0].value() == "_tWinMain" ||
                    (!node.entry.empty() && name[0].value() == node.entry)) {
                    if (main_func != nullptr) {
                        CODEGEN_ERROR(name[0], "multiple main functions are not allowed");
                    }

                    if (node.entry.empty() || name[0].value() != node.entry) {
                        /// there must be a return type
                        if (func->returns == nullptr) {
                            CODEGEN_ERROR(name[0], "main functions must have a return type (i32)");
                        }
                    }

                    main_func = func;

                    return;
                }
            }
        } else if (child->getNodeType() == __AST_NODE::nodes::LetDecl) {
            __AST_N::NodeT<__AST_NODE::LetDecl> node = __AST_N::as<__AST_NODE::LetDecl>(child);
            visit(*node, true);
            return;
        }

        child->accept(*this);
    });

    if (main_func != nullptr) {
        main_func->accept(*this);

        if (!trivially_import) {
            ADD_TOKEN(CXX_RBRACE);  // end namespace _namespace
        }

        ADD_TOKEN(CXX_RBRACE);  // end namespace helix
        // now add the main function with the same signature and name but replace the body to return
        // helix:: [passing the name and args]

        main_func->body->body->body.clear();

        {  // this is a function call to the helix::_HX_FN_Vi_Q5_7_helixrt_init_Rv()
            auto scope = __AST_N::make_node<__AST_NODE::ScopePathExpr>(true);

            scope->path.push_back(__AST_N::make_node<__AST_NODE::IdentExpr>(
                __TOKEN_N::Token(main_func->name->get_back_name().token_kind(),
                                 "helix",
                                 main_func->name->get_back_name())));

            scope->access = __AST_N::make_node<__AST_NODE::IdentExpr>(
                __TOKEN_N::Token(main_func->name->get_back_name().token_kind(),
                                 "_HX_FN_Vi_Q5_7_helixrt_init_Rv",
                                 main_func->name->get_back_name()));

            auto path  = __AST_N::make_node<__AST_NODE::PathExpr>(scope);
            path->type = __AST_NODE::PathExpr::PathType::Scope;

            auto args      = __AST_N::make_node<__AST_NODE::ArgumentListExpr>(true);
            auto func_call = __AST_N::make_node<__AST_NODE::ExprState>(
                __AST_N::make_node<__AST_NODE::FunctionCallExpr>(path, args));

            main_func->body->body->body.push_back(func_call);
        }

        {  // this is a function call to to the main function defined by the user
            auto scope = __AST_N::make_node<__AST_NODE::ScopePathExpr>(true);

            scope->path.push_back(__AST_N::make_node<__AST_NODE::IdentExpr>(
                __TOKEN_N::Token(main_func->name->get_back_name().token_kind(),
                                 "helix",
                                 main_func->name->get_back_name())));

            if (!trivially_import) {
                scope->path.push_back(__AST_N::make_node<__AST_NODE::IdentExpr>(
                    __TOKEN_N::Token(main_func->name->get_back_name().token_kind(),
                                     _namespace,
                                     main_func->name->get_back_name())));
            }

            scope->access = __AST_N::make_node<__AST_NODE::IdentExpr>(
                __TOKEN_N::Token(main_func->name->get_back_name()));

            auto path  = __AST_N::make_node<__AST_NODE::PathExpr>(scope);
            path->type = __AST_NODE::PathExpr::PathType::Scope;

            auto args = __AST_N::make_node<__AST_NODE::ArgumentListExpr>(true);
            // __AST_N::make_node<__AST_NODE::ArgumentExpr>()
            if (!main_func->params.empty()) {
                for (auto &param : main_func->params) {
                    args->args.push_back(
                        __AST_N::make_node<__AST_NODE::ArgumentExpr>(param->var->path));
                }
            }

            auto func_call = __AST_N::make_node<__AST_NODE::FunctionCallExpr>(path, args);
            auto ret       = __AST_N::make_node<__AST_NODE::ReturnState>(func_call);
            main_func->body->body->body.push_back(ret);  // return helix::...::...(..., ...);
        }

        main_func->accept(*this);
    } else {
        if (!trivially_import) {
            ADD_TOKEN(CXX_RBRACE);  // end namespace _namespace
        }

        ADD_TOKEN(CXX_RBRACE);  // end namespace helix
    }

    ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, "#endif");
}
