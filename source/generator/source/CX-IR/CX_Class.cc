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

#include "utils.hh"

CX_VISIT_IMPL(ClassDecl) {
    auto add_udt_body = [node, this](CXIR                                         *self,
                                     const __AST_N::NodeT<__AST_NODE::IdentExpr>   name,
                                     const __AST_N::NodeT<__AST_NODE::SuiteState> &body) {
        if (body != nullptr) {
            self->append(cxir_tokens::CXX_LBRACE);
            bool has_destructor  = false;
            bool has_constructor = false;

            for (auto &child : body->body->body) {
                if (child->getNodeType() == __AST_NODE::nodes::FuncDecl && !__AST_N::as<__AST_NODE::FuncDecl>(child)->is_op) {
                    auto         func_decl = __AST_N::as<__AST_NODE::FuncDecl>(child);
                    token::Token func_name = func_decl->name->get_back_name();

                    auto [has_self, has_static] = contains_self_static(func_decl);

                    if (func_name.value() == name->name.value()) {
                        // self must be present and the fucntion can not be marked as static
                        if (!has_self || has_static) {
                            error::Panic(error::CodeError{.pof = &func_name, .err_code = 0.3007});

                            continue;
                        }

                        has_constructor = true;
                    }

                    handle_static_self_fn_decl(func_decl, func_name);
                    add_visibility(self, func_decl);

                    if (name != nullptr) {
                        self->visit(*func_decl, func_name.value() == name->name.value());
                    } else {
                        self->visit(*func_decl);
                    }

                } else if (child->getNodeType() == __AST_NODE::nodes::FuncDecl && __AST_N::as<__AST_NODE::FuncDecl>(child)->is_op) {
                    // we need to handle the `in` operator since its codegen also has to check for
                    // the presence of the begin and end functions 2 variations of the in operator
                    // are possible
                    // 1. `in` operator that takes no args and yields (used in for loops)
                    // 2. `in` operator that takes 1 arg and returns a bool (used in expressions)
                    // we need to handle both of these cases
                    token::Token op_name;
                    auto         op_decl = __AST_N::as<__AST_NODE::FuncDecl>(child);
                    auto         op_t    = OpType(*op_decl, true);

                    if (op_decl->name != nullptr) {
                        op_name = op_decl->name->get_back_name();
                    } else {
                        op_name = op_decl->op.back();
                    }

                    if (op_t.type == OpType::Error) {
                        continue;
                    }

                    /// FIXME: this is ugly as shit. this has to be fixed, we need pattern matching
                    /// and a symbol table
                    if (op_t.type == OpType::GeneratorOp) {
                        /// there can not be a fucntion named begin and define that takes no
                        /// arguments
                        for (auto &child : body->body->body) {
                            if (child->getNodeType() == __AST_NODE::nodes::FuncDecl) {
                                auto         func_decl = __AST_N::as<__AST_NODE::FuncDecl>(child);
                                
                                if (func_decl->name != nullptr) {
                                    token::Token func_name = func_decl->name->get_back_name();

                                    if (func_name.value() == "begin") {
                                        if (func_decl->params.size() == 0) {
                                            error::Panic(error::CodeError{
                                                .pof          = &func_name,
                                                .err_code     = 0.3002,
                                                .err_fmt_args = {
                                                    "can not define both begin/end fuctions and "
                                                    "overload the `in` genrator operator"}});
                                        }
                                    }

                                    if (func_name.value() == "end") {
                                        if (func_decl->params.size() == 0) {
                                            error::Panic(error::CodeError{
                                                .pof          = &func_name,
                                                .err_code     = 0.3002,
                                                .err_fmt_args = {
                                                    "can not define both begin/end fuctions and "
                                                    "overload the `in` genrator operator"}});
                                        }
                                    }
                                }
                            }
                        }
                    } else if (op_t.type == OpType::DeleteOp) {
                        // generate: ~name->name() body
                        has_destructor = true;

                        if (op_decl->modifiers.contains(token::tokens::KEYWORD_PROTECTED) ||
                            op_decl->modifiers.contains(token::tokens::KEYWORD_PRIVATE)) {
                            error::Panic(error::CodeError{
                                .pof          = &op_name,
                                .err_code     = 0.3002,
                                .err_fmt_args = {
                                    "can not define a destructor as private or protected"}});
                        }

                        add_public(self);
                        token::Token marker = ((op_t.tok == nullptr) ? node.name->name : *op_t.tok);

                        add_func_modifiers(this, op_decl->modifiers);

                        self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_TILDE, marker));
                        self->append(std::make_unique<CX_Token>(
                            cxir_tokens::CXX_CORE_IDENTIFIER, node.name->name.value(), marker));
                        self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_LPAREN));
                        self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_RPAREN));

                        add_func_specifiers(this, op_decl->modifiers);

                        if (op_decl->modifiers.contains(__TOKEN_N::KEYWORD_OVERRIDE)) {
                            this->append(std::make_unique<__CXIR_CODEGEN_N::CX_Token>(
                                __CXIR_CODEGEN_N::cxir_tokens::CXX_OVERRIDE,
                                op_decl->modifiers.get(__TOKEN_N::KEYWORD_OVERRIDE)));
                        }

                        if (op_decl->modifiers.contains(__TOKEN_N::KEYWORD_DELETE)) {
                            // add and = and delete to the function decl
                            this->append(std::make_unique<__CXIR_CODEGEN_N::CX_Token>(
                                __CXIR_CODEGEN_N::cxir_tokens::CXX_EQUAL));
                            this->append(std::make_unique<__CXIR_CODEGEN_N::CX_Token>(
                                __CXIR_CODEGEN_N::cxir_tokens::CXX_DELETE,
                                op_decl->modifiers.get(__TOKEN_N::KEYWORD_DELETE)));
                        } else if (op_decl->modifiers.contains(__TOKEN_N::KEYWORD_DEFAULT)) {
                            // add and = and default to the function decl
                            this->append(std::make_unique<__CXIR_CODEGEN_N::CX_Token>(
                                __CXIR_CODEGEN_N::cxir_tokens::CXX_EQUAL));
                            this->append(std::make_unique<__CXIR_CODEGEN_N::CX_Token>(
                                __CXIR_CODEGEN_N::cxir_tokens::CXX_DEFAULT,
                                op_decl->modifiers.get(__TOKEN_N::KEYWORD_DEFAULT)));
                        }

                        if (op_decl->body == nullptr) {
                            self->append(cxir_tokens::CXX_SEMICOLON);
                        } else {
                            if (op_decl->modifiers.contains(__TOKEN_N::KEYWORD_DELETE) ||
                                op_decl->modifiers.contains(__TOKEN_N::KEYWORD_DEFAULT)) {
                                error::Panic(error::CodeError{
                                    .pof          = &op_name,
                                    .err_code     = 0.3002,
                                    .err_fmt_args = {"can not have a body for a deleted or "
                                                     "defaulted function"}});
                            }

                            self->visit(*op_decl->body);
                        }

                        continue;
                    }

                    add_visibility(self, op_decl);
                    self->visit(*op_decl, true, true);
                } else if (child->getNodeType() == __AST_NODE::nodes::LetDecl) {
                    auto let_decl = __AST_N::as<__AST_NODE::LetDecl>(child);

                    if (let_decl->vis.contains(token::tokens::KEYWORD_PROTECTED)) {
                        add_protected(self);
                    } else if (let_decl->vis.contains(token::tokens::KEYWORD_PUBLIC)) {
                        add_public(self);
                    } else {
                        add_private(self);
                    }

                    child->accept(*self);
                    self->append(cxir_tokens::CXX_SEMICOLON);
                } else if (child->getNodeType() == __AST_NODE::nodes::ConstDecl) {
                    auto const_decl = __AST_N::as<__AST_NODE::ConstDecl>(child);

                    if (const_decl->vis.contains(token::tokens::KEYWORD_PROTECTED)) {
                        add_protected(self);
                    } else if (const_decl->vis.contains(token::tokens::KEYWORD_PUBLIC)) {
                        add_public(self);
                    } else {
                        add_private(self);
                    }

                    child->accept(*self);
                    self->append(cxir_tokens::CXX_SEMICOLON);
                } else {
                    add_visibility(self, child);
                    child->accept(*self);
                    self->append(cxir_tokens::CXX_SEMICOLON);
                }
            }

            if (!has_constructor) {
                default_constructor(self, node.name);
            }

            if (!has_destructor) {
                default_destructor(self, node.name);
            }

            if (node.modifiers.contains(token::tokens::KEYWORD_DEFAULT)) {
                delete_copy_constructor(self, node.name);
                delete_copy_assignment(self, node.name);
                default_move_constructor(self, node.name);
                default_move_assignment(self, node.name);
            }

            self->append(cxir_tokens::CXX_RBRACE);
        }
    };

    if (node.generics != nullptr) {
        ADD_NODE_PARAM(generics);
    }

    ADD_TOKEN(CXX_CLASS);
    ADD_NODE_PARAM(name);

    if (node.derives) {
        ADD_TOKEN(CXX_COLON);
        ADD_NODE_PARAM(derives);
    }

    if (node.body != nullptr) {
        add_udt_body(this, node.name, node.body);
    }

    ADD_TOKEN(CXX_SEMICOLON);

    /// interface support
    /// FIXME: this does not work in the cases where the class takes a generic type
    if (!node.extends.empty()) {
        /// static_assert(extend<class<gens>>, "... must satisfy ... interface");
        token::Token loc;

        if (node.generics != nullptr) {
            /// warn that this class will not be checked since it accepts a generic
            error::Panic(error::CodeError{.pof = &node.name->name, .err_code = 0.3001});

            return;
        }

        auto add_token = [this, &loc](const cxir_tokens &tok) {
            this->append(std::make_unique<CX_Token>(tok, loc));
        };

        /// class Foo::<T> extends Bar::<T> requires <T> {}
        /// static_assert(Bar<Foo<T>, T>, "Foo<T> must satisfy Bar<T> interface");
        for (auto &_extend : node.extends) {
            auto &extend = std::get<0>(_extend);
            loc          = extend->marker;

            add_token(cxir_tokens::CXX_STATIC_ASSERT);
            add_token(cxir_tokens::CXX_LPAREN);

            if (extend->is_fn_ptr) {
                PARSE_ERROR(loc, "Function pointers are not allowed in extends");
            } else if (extend->nullable) {
                PARSE_ERROR(loc, "Nullable types are not allowed in extends");
            }

            __AST_N::NodeT<__AST_NODE::Type> type_node =
                parser::ast::make_node<__AST_NODE::Type>(true);
            type_node->value = node.name;

            __AST_N::NodeV<__AST_NODE::IdentExpr> args;

            if (node.generics) {
                for (auto &arg : node.generics->params->params) {
                    args.emplace_back(arg->var->path);
                }

                type_node->generics =
                    parser::ast::make_node<__AST_NODE::GenericInvokeExpr>(__AST_N::as<>(args));
            }

            /// append the class name and generics to extend
            if (extend->generics) {
                extend->generics->args.insert(extend->generics->args.begin(),
                                              __AST_N::as<__AST_NODE::Node>(type_node));
            } else {
                extend->generics = parser::ast::make_node<__AST_NODE::GenericInvokeExpr>(
                    __AST_N::as<__AST_NODE::Node>(type_node));
            }

            extend->accept(*this);
            add_token(cxir_tokens::CXX_COMMA);

            this->append(std::make_unique<CX_Token>(cxir_tokens::CXX_CORE_LITERAL,
                                                    "\"" + node.name->name.value() +
                                                        " must satisfy " + extend->marker.value() +
                                                        " interface\"",
                                                    loc));
            add_token(cxir_tokens::CXX_RPAREN);
            add_token(cxir_tokens::CXX_SEMICOLON);
        }
    }
}
