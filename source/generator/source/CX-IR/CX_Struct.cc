///--- The Kairo Project ------------------------------------------------------------------------///
///                                                                                              ///
///   part of the kairo project, under the attribution 4.0 international license (cc by 4.0).    ///
///   you are allowed to use, modify, redistribute, and create derivative works, even for        ///
///   commercial purposes, provided that you give appropriate credit, and indicate if changes    ///
///   were made.                                                                                 ///
///                                                                                              ///
///   for more information on the license terms and requirements, please visit:                  ///
///     https://creativecommons.org/licenses/by/4.0/                                             ///
///                                                                                              ///
///   spdx-license-identifier: cc-by-4.0                                                         ///
///   copyright (c) 2024 the kairo project (cc by 4.0)                                           ///
///                                                                                              ///
///-------------------------------------------------------------------------------------- C++ ---///

#include "parser/ast/include/config/AST_config.def"
#include "utils.hh"

CX_VISIT_IMPL(StructDecl) {
    auto add_udt_body = [node](CXIR                                         *self,
                              [[maybe_unused]]  const __AST_N::NodeT<__AST_NODE::IdentExpr> name,
                               const __AST_N::NodeT<__AST_NODE::SuiteState> &body) {
        if (body != nullptr) {
            self->append(cxir_tokens::CXX_LBRACE);
            bool has_destructor = false;

            for (auto &child : body->body->body) {
                switch (child->getNodeType()) {
                    case __AST_NODE::nodes::EnumDecl:
                    case __AST_NODE::nodes::StructDecl:
                    case __AST_NODE::nodes::TypeDecl:
                    case __AST_NODE::nodes::LetDecl:
                    case __AST_NODE::nodes::ConstDecl:
                    break;
                    case __AST_NODE::nodes::IfState: {
                        auto if_node = __AST_N::as<__AST_NODE::IfState>(child);
                        
                        if (if_node->has_const && if_node->has_eval) {
                            break;
                        }
                    }
                    case __AST_NODE::nodes::FuncDecl: {
                        auto func_decl = __AST_N::as<__AST_NODE::FuncDecl>(child);
                    
                        if (func_decl->is_op && (func_decl->name == nullptr)) {
                            break;
                        }
                    } default:
                        CODEGEN_ERROR(
                            node.name->name,
                            "struct declaration cannot have a node of type: '" +
                                child->getNodeName() +
                                "', struct can only contain: enums, types, structs, unnamed ops, "
                                "and var/const declarations.");
                        continue;
                }

                if (child->getNodeType() == __AST_NODE::nodes::FuncDecl && __AST_N::as<__AST_NODE::FuncDecl>(child)->is_op) {
                    auto op_decl = __AST_N::as<__AST_NODE::FuncDecl>(child);
                    if (op_decl->name) {
                        auto marker = op_decl->name->get_back_name();
                        CODEGEN_ERROR(
                            marker,
                            "struct declaration cannot have named operators; remove the named alias.");
                        continue;
                    }

                    auto op_t = OpType(*op_decl, true);
                    if (op_t.type == OpType::Error) {
                        continue;
                    }

                    if (op_t.type == OpType::GeneratorOp) {
                        for (auto &child : body->body->body) {
                            if (child->getNodeType() == __AST_NODE::nodes::FuncDecl) {
                                auto func_decl = __AST_N::as<__AST_NODE::FuncDecl>(child);
                                token::Token func_name = func_decl->name->get_back_name();

                                if (func_name.value() == "begin" && func_decl->params.size() == 0) {
                                    error::Panic(error::CodeError{
                                        .pof          = &func_name,
                                        .err_code     = 0.3002,
                                        .err_fmt_args = {
                                            "cannot define both begin/end functions and overload "
                                            "the `in` generator operator"}});
                                }

                                if (func_name.value() == "end" && func_decl->params.size() == 0) {
                                    error::Panic(error::CodeError{
                                        .pof          = &func_name,
                                        .err_code     = 0.3002,
                                        .err_fmt_args = {
                                            "cannot define both begin/end functions and overload "
                                            "the `in` generator operator"}});
                                }
                            }
                        }
                    } else if (op_t.type == OpType::DeleteOp) {
                        // generate: ~name->name() body
                        has_destructor = true;
                        
                        if (op_decl->modifiers.contains(token::tokens::KEYWORD_PROTECTED) || op_decl->modifiers.contains(token::tokens::KEYWORD_PRIVATE)) {
                            error::Panic(error::CodeError{
                                            .pof          = &*op_t.tok,
                                            .err_code     = 0.3002,
                                            .err_fmt_args = {
                                                "can not define a destructor as private or protected"}});
                        }

                        add_public(self);
                        token::Token marker = ((op_t.tok == nullptr) ? node.name->name : *op_t.tok);
                    
                        self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_TILDE, marker));
                        self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_CORE_IDENTIFIER,
                                                                node.name->name.value(), marker));
                        self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_LPAREN));
                        self->append(std::make_unique<CX_Token>(cxir_tokens::CXX_RPAREN));

                        self->visit(*op_decl->body);

                        continue;
                    }

                    add_visibility(self, op_decl);
                    self->visit(*op_decl, true, true);
                } else if (child->getNodeType() == __AST_NODE::nodes::LetDecl) {
                    auto let_decl = __AST_N::as<__AST_NODE::LetDecl>(child);

                    if (let_decl->vis.contains(token::tokens::KEYWORD_PROTECTED)) {
                        add_protected(self);
                    } else if (let_decl->vis.contains(token::tokens::KEYWORD_PRIVATE)) {
                        add_private(self);
                    } else {
                        add_public(self);
                    }

                    child->accept(*self);
                    self->append(cxir_tokens::CXX_SEMICOLON);
                } else if (child->getNodeType() == __AST_NODE::nodes::ConstDecl) {
                    auto const_decl = __AST_N::as<__AST_NODE::ConstDecl>(child);

                    if (const_decl->vis.contains(token::tokens::KEYWORD_PROTECTED)) {
                        add_protected(self);
                    } else if (const_decl->vis.contains(token::tokens::KEYWORD_PRIVATE)) {
                        add_private(self);
                    } else {
                        add_public(self);
                    }

                    child->accept(*self);
                    self->append(cxir_tokens::CXX_SEMICOLON);
                } else {
                    add_visibility(self, child);
                    child->accept(*self);
                    self->append(cxir_tokens::CXX_SEMICOLON);
                }
            }

            // generate: ...(const ...&) = delete;
            // generate: ...& operator=(const ...&) = delete;
            // generate: ...(...&&) noexcept = default;
            // generate: ...& operator=(...&&) noexcept = default;
            // also generate a default destructor if not present

            if (!has_destructor) {
                default_destructor(self, node.name);
            }

            // default_constructor(self, node.name);
            // delete_copy_constructor(self, node.name);
            // default_move_constructor(self, node.name);

            delete_copy_assignment(self, node.name);
            default_move_assignment(self, node.name);

            self->append(cxir_tokens::CXX_RBRACE);
        }
    };

    if (node.generics != nullptr) {
        ADD_NODE_PARAM(generics);
    }

    ADD_TOKEN(CXX_STRUCT);
    ADD_NODE_PARAM(name);

    if (node.derives) {
        ADD_TOKEN(CXX_COLON);
        ADD_NODE_PARAM(derives);
    }

    if (node.body != nullptr) {
        add_udt_body(this, node.name, node.body);
    }

    ADD_TOKEN(CXX_SEMICOLON);
}
