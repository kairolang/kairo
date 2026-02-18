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

#include "generator/include/config/Gen_config.def"
#include "utils.hh"

CX_VISIT_IMPL_VA(FuncDecl, bool in_udt, bool is_op) {
    OpType       op_t  = OpType(node, in_udt);
    token::Token tok;

    /// FIXME: really have to add markers to the rewrite of the compiler
    if (in_udt) {
        if (op_t.type == OpType::Error) {
            return;
        }

        tok = *op_t.tok;
    } else {
        if (!node.op.empty()) {
            tok = node.op.front();
        } else {
            auto name = node.get_name_t();
            if (!name.empty()) {
                tok = name.back();
            } else {
                tok = node.marker;
            }
        }
    }

    handle_static_self_fn_decl(node, tok, in_udt);
    check_for_yield_and_panic(node.body, node.returns);

    // ---------------------------- add generator state ---------------------------- //
    if (in_udt && op_t.type == OpType::GeneratorOp) {
        // `private: mutable kairo::generator<return_type>* $gen_state = nullptr; public:`
        ADD_TOKEN(CXX_PRIVATE);
        ADD_TOKEN(CXX_COLON);

        ADD_TOKEN(CXX_MUTABLE);
        ADD_NODE_PARAM(returns);
        ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "$gen_state", tok);

        ADD_TOKEN(CXX_ASSIGN);
        ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "operator$generator", tok);
        PAREN_DELIMIT();

        ADD_TOKEN(CXX_SEMICOLON);

        ADD_TOKEN(CXX_PUBLIC);
        ADD_TOKEN(CXX_COLON);
    }

    // ---------------------------- operator declaration ---------------------------- //

    if (node.generics) {  //
        ADD_NODE_PARAM(generics);
    };

    if (!node.modifiers.contains(__TOKEN_N::KEYWORD_INLINE)) {
        ADD_TOKEN(CXX_INLINE);  // inline the operator
    }

    add_func_modifiers(this, node.modifiers);

    ADD_TOKEN(CXX_AUTO);

    if (in_udt && op_t.type != OpType::None) {
        // if its a generator op
        // the codegen makes 3 functions:
        // 1. the generator function: auto $generator() -> ... {}
        // 2. the begin function: auto begin() {return $generator().begin(); }
        // 3. the end function: auto end() {return $generator().end(); }

        if (op_t.type == OpType::GeneratorOp) {
            /// add the fucntion
            ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "operator$generator", *op_t.tok);
        }

        // if its a contains op
        // the codegen makes 1 function: auto operator$contains() -> bool {}

        else if (op_t.type == OpType::ContainsOp) {
            /// add the fucntion
            ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "operator$contains", *op_t.tok);
        }

        // if its a cast op
        // the codegen makes 2 functions: auto operator$cast() -> type {} and a excplicit cast

        else if (op_t.type == OpType::CastOp) {
            /// add the fucntion
            ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "operator$cast", *op_t.tok);

            auto type =
                __AST_N::make_node<__AST_NODE::Type>(__AST_N::make_node<__AST_NODE::UnaryExpr>(
                    node.returns,
                    __TOKEN_N::Token(__TOKEN_N::OPERATOR_MUL, "*", *op_t.tok),
                    __AST_NODE::UnaryExpr::PosType::PreFix,
                    true));

            auto param = __AST_N::make_node<__AST_NODE::VarDecl>(
                __AST_N::make_node<__AST_NODE::NamedVarSpecifier>(
                    __AST_N::make_node<__AST_NODE::IdentExpr>(
                        __TOKEN_N::Token()  // whitespace token
                        ),
                    type));

            node.params.emplace_back(param);
        }

        // if its a panic op
        // the codegen makes 1 function: auto operator$panic() -> void {}

        else if (op_t.type == OpType::PanicOp) {
            /// add the fucntion
            ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "operator$panic", *op_t.tok);
        }

        // if its a question op
        // the codegen makes 1 function: auto operator$question() -> bool {}

        else if (op_t.type == OpType::QuestionOp) {
            /// add the fucntion
            ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "operator$question", *op_t.tok);
        }
    } else {
        ADD_TOKEN(CXX_OPERATOR);

        for (auto &tok : node.op) {
            ADD_TOKEN_AS_VALUE(CXX_CORE_OPERATOR, tok.value());
        }
    }

    ADD_TOKEN(CXX_LPAREN);
    if (!node.params.empty()) {
        for (auto &param : node.params) {
            ADD_PARAM(param);
            ADD_TOKEN(CXX_COMMA);
        }

        this->tokens.pop_back();
    }
    ADD_TOKEN(CXX_RPAREN);

    add_func_specifiers(this, node.modifiers);

    ADD_TOKEN(CXX_PTR_ACC);

    if (node.returns) {  //
        ADD_NODE_PARAM(returns);
    } else {
        ADD_TOKEN_AT_LOC(CXX_VOID, node.marker);
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

        if (node.name != nullptr) {
            auto fail = node.name->get_back_name();
            error::Panic(
                error::CodeError{.pof          = &fail,
                                 .err_code     = 0.3002,
                                 .err_fmt_args = {"can not have a name for a deleted function"}});
        }
    } else if (node.modifiers.contains(__TOKEN_N::KEYWORD_DEFAULT)) {
        // add and = and default to the function decl
        this->append(
            std::make_unique<__CXIR_CODEGEN_N::CX_Token>(__CXIR_CODEGEN_N::cxir_tokens::CXX_EQUAL));
        this->append(std::make_unique<__CXIR_CODEGEN_N::CX_Token>(
            __CXIR_CODEGEN_N::cxir_tokens::CXX_DEFAULT,
            node.modifiers.get(__TOKEN_N::KEYWORD_DEFAULT)));

        if (node.name != nullptr) {
            auto fail = node.name->get_back_name();
            error::Panic(
                error::CodeError{.pof          = &fail,
                                 .err_code     = 0.3002,
                                 .err_fmt_args = {"can not have a name for a defaulted function"}});
        }
    }

    if (node.body && node.body->body) {
        if (node.modifiers.contains(__TOKEN_N::KEYWORD_DELETE) ||
            node.modifiers.contains(__TOKEN_N::KEYWORD_DEFAULT)) {
            auto fail = node.op.back();
            error::Panic(error::CodeError{
                .pof          = &fail,
                .err_code     = 0.3002,
                .err_fmt_args = {"can not have a body for a deleted or defaulted function"}});
        }
        // adds and removes any nested functions
        BRACE_DELIMIT(                                                                  //
            std::erase_if(node.body->body->body, ModifyNestedFunctions(this)););  //
    } else {
        ADD_TOKEN(CXX_SEMICOLON);
    }

    // ---------------------------- function declaration ---------------------------- //

    // add the alias function first if it has a name
    if (node.name != nullptr) {
        if (node.generics) {  //
            ADD_NODE_PARAM(generics);
        };

        add_func_modifiers(this, node.modifiers);

        ADD_TOKEN(CXX_AUTO);

        ADD_NODE_PARAM(name);

        PAREN_DELIMIT(                //
            COMMA_SEP(params);  //
        );

        add_func_specifiers(this, node.modifiers);

        ADD_TOKEN(CXX_PTR_ACC);
        if (node.returns) {  //
            ADD_NODE_PARAM(returns);
        } else {
            ADD_TOKEN_AT_LOC(CXX_VOID, node.marker);
        }

        if (node.modifiers.contains(__TOKEN_N::KEYWORD_OVERRIDE)) {
            this->append(std::make_unique<__CXIR_CODEGEN_N::CX_Token>(
                __CXIR_CODEGEN_N::cxir_tokens::CXX_OVERRIDE,
                node.modifiers.get(__TOKEN_N::KEYWORD_OVERRIDE)));
        }

        BRACE_DELIMIT(
            ADD_TOKEN(CXX_RETURN);  //

            if (in_udt && op_t.type != OpType::None) {
                if (op_t.type == OpType::GeneratorOp) {
                    /// add the fucntion
                    ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "operator$generator", *op_t.tok);
                } else if (op_t.type == OpType::CastOp) {
                    /// add the fucntion
                    ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "operator$cast", *op_t.tok);
                } else if (op_t.type == OpType::ContainsOp) {
                    /// add the fucntion
                    ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "operator$contains", *op_t.tok);
                } else if (op_t.type == OpType::PanicOp) {
                    /// add the fucntion
                    ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "operator$panic", *op_t.tok);
                } else if (op_t.type == OpType::QuestionOp) {
                    /// add the fucntion
                    ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "operator$question", *op_t.tok);
                }
            } else {
                ADD_TOKEN(CXX_OPERATOR);
                for (auto &tok : node.op) {
                    ADD_TOKEN_AS_VALUE(CXX_CORE_OPERATOR, tok.value());
                }
            }

            ADD_TOKEN(CXX_LPAREN);
            if (!node.params.empty()) {
                for (auto &param : node.params) {
                    ADD_PARAM(param->var->path);
                    ADD_TOKEN(CXX_COMMA);
                }

                this->tokens.pop_back();
            }

            ADD_TOKEN(CXX_RPAREN);
            ADD_TOKEN(CXX_SEMICOLON);  //
        );
    }

    // ---------------------------- add helper functions ---------------------------- //

    if (in_udt && op_t.type == OpType::GeneratorOp) {
        /// add the fucntions
        // 2. the begin function:
        // auto begin() {
        //     if ($gen_state == nullptr) { $gen_state = $generator(); } return $gen_state->begin();
        // }
        // 3. the end function:
        // auto end() {
        //    if ($gen_state == nullptr) { $gen_state = $generator(); } return $gen_state->end();
        // }
        ADD_TOKEN(CXX_AUTO);
        add_func_modifiers(this, node.modifiers);
        ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "begin", tok);
        add_func_specifiers(this, node.modifiers);
        PAREN_DELIMIT();
        BRACE_DELIMIT(ADD_TOKEN(CXX_RETURN);  //
                      ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "$gen_state", *op_t.tok);
                      ADD_TOKEN(CXX_DOT);  //
                      ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "begin", *op_t.tok);
                      PAREN_DELIMIT();
                      ADD_TOKEN(CXX_SEMICOLON);  //
        );

        ADD_TOKEN(CXX_AUTO);
        add_func_modifiers(this, node.modifiers);
        ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "end", tok);
        PAREN_DELIMIT();
        add_func_specifiers(this, node.modifiers);
        BRACE_DELIMIT(ADD_TOKEN(CXX_RETURN);  //
                      ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "$gen_state", *op_t.tok);
                      ADD_TOKEN(CXX_DOT);  //
                      ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "end", *op_t.tok);
                      PAREN_DELIMIT();
                      ADD_TOKEN(CXX_SEMICOLON);  //
        );
    } else if (in_udt && op_t.type == OpType::CastOp) {
        /// add excplit cast function: explicit operator <type>() { return
        /// operator$cast<type>(static_cast<type*>(nullptr)); }
        ADD_TOKEN(CXX_EXPLICIT);
        add_func_modifiers(this, node.modifiers);
        ADD_TOKEN(CXX_OPERATOR);
        ADD_PARAM(node.returns);
        ADD_TOKEN(CXX_LPAREN);
        ADD_TOKEN(CXX_RPAREN);
        add_func_specifiers(this, node.modifiers);

        BRACE_DELIMIT(              //
            ADD_TOKEN(CXX_RETURN);  //
            ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "this", *op_t.tok);
            ADD_TOKEN_AT_LOC(CXX_PTR_ACC, *op_t.tok);
            ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "operator$cast", *op_t.tok);
            // ANGLE_DELIMIT(                                       //
            //     ADD_PARAM(node.returns);                   //
            // );                                                   //
            PAREN_DELIMIT(                                       //
                ADD_TOKEN(CXX_STATIC_CAST);                      //
                ANGLE_DELIMIT(                                   //
                    ADD_PARAM(node.returns);               //
                    ADD_TOKEN_AS_VALUE(CXX_CORE_OPERATOR, "*");  //
                );                                               //
                PAREN_DELIMIT(                                   //
                    ADD_TOKEN(CXX_NULLPTR);                      //
                );                                               //
            );                                                   //
            ADD_TOKEN(CXX_SEMICOLON);                            //
        );
    }
}