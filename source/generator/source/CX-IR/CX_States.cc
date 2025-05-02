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

#include "generator/include/config/Gen_config.def"
#include "utils.hh"

CX_VISIT_IMPL_VA(NamedVarSpecifier, bool omit_t) {
    // (type | auto) name

    if (!omit_t) {
        if (node.is_const) {
            ADD_TOKEN(CXX_CONST);
        }
        
        if (node.type) {
            ADD_NODE_PARAM(type);
        } else {
            ADD_TOKEN(CXX_AUTO);
        }
    }

    ADD_NODE_PARAM(path);
}

CX_VISIT_IMPL_VA(NamedVarSpecifierList, bool omit_t) {
    if (!node.vars.empty()) {
        if (node.vars[0] != nullptr) {
            visit(*node.vars[0], omit_t);
        }
        for (size_t i = 1; i < node.vars.size(); ++i) {
            ADD_TOKEN(CXX_COMMA);
            if (node.vars[i] != nullptr) {
                visit(*node.vars[i], omit_t);
            }
        }
    };
}

CX_VISIT_IMPL(ForPyStatementCore) {
    // := NamedVarSpecifier 'in 'expr' Suite

    ADD_TOKEN(CXX_LPAREN);
    // auto &[a, b]

    if (node.vars->vars.size() > 1) {
        ADD_TOKEN(CXX_AUTO);
        ADD_TOKEN(CXX_AMPERSAND);
        ADD_TOKEN(CXX_LBRACKET);

        if (node.vars != nullptr) {
            visit(*node.vars, true);
        }

        ADD_TOKEN(CXX_RBRACKET);
    } else {
        ADD_NODE_PARAM(vars);
    }

    ADD_TOKEN(CXX_COLON);
    ADD_NODE_PARAM(range);
    ADD_TOKEN(CXX_RPAREN);
    ADD_NODE_PARAM_BODY();
}

CX_VISIT_IMPL(ForCStatementCore) {
    PAREN_DELIMIT(                  //
        ADD_NODE_PARAM(init);       //
        ADD_TOKEN(CXX_SEMICOLON);   //
        ADD_NODE_PARAM(condition);  //
        ADD_TOKEN(CXX_SEMICOLON);   //
        ADD_NODE_PARAM(update);     //
    );

    ADD_NODE_PARAM_BODY();
}

CX_VISIT_IMPL(ForState) {
    NO_EMIT_FORWARD_DECL;
    // := 'for' (ForPyStatementCore | ForCStatementCore)

    ADD_TOKEN(CXX_FOR);

    ADD_NODE_PARAM(core);
}

CX_VISIT_IMPL(WhileState) {
    NO_EMIT_FORWARD_DECL;
    // := 'while' expr Suite

    ADD_TOKEN(CXX_WHILE);

    PAREN_DELIMIT(                  //
        ADD_NODE_PARAM(condition);  //
    );
    ADD_NODE_PARAM_BODY();
}

CX_VISIT_IMPL(ElseState) {
    NO_EMIT_FORWARD_DECL;

    ADD_TOKEN(CXX_ELSE);

    if (node.type != __AST_NODE::ElseState::ElseType::Else) {
        ADD_TOKEN(CXX_IF);
        PAREN_DELIMIT(  //
            if (node.type == __AST_NODE::ElseState::ElseType::ElseUnless) {
                ADD_TOKEN(CXX_EXCLAMATION);
            }

            PAREN_DELIMIT(                  //
                ADD_NODE_PARAM(condition);  //
            );                              //
        );
    }
    ADD_NODE_PARAM_BODY();
}

CX_VISIT_IMPL(IfState) {
    // const eval if == #if in C/C++
    // eval if == if constexpr in C++
    if (node.has_const && node.has_eval) {
        ADD_TOKEN(CXX_PP_IF);

        if (node.type == __AST_NODE::IfState::IfType::Unless) {  //
            PAREN_DELIMIT(                                       //
                ADD_TOKEN(CXX_EXCLAMATION);                      //
                PAREN_DELIMIT(                                   //
                    ADD_NODE_PARAM(condition);                   //
                );                                               //
            );                                                   //
        } else {
            PAREN_DELIMIT(                  //
                ADD_NODE_PARAM(condition);  //
            );                              //
        }

        if (node.body != nullptr) {
            node.body->body->accept(*this);
        }

        if (!node.else_body.empty()) {
            for (auto &else_body : node.else_body) {
                if (else_body->type == __AST_NODE::ElseState::ElseType::Else) {
                    ADD_TOKEN(CXX_PP_ELSE);
                } else {
                    ADD_TOKEN(CXX_PP_ELIF);

                    if (else_body->type == __AST_NODE::ElseState::ElseType::ElseUnless) {
                        PAREN_DELIMIT(                                       //
                            ADD_TOKEN(CXX_EXCLAMATION);                      //
                            PAREN_DELIMIT(                                   //
                                ADD_PARAM(else_body->condition);         //
                            );                                               //
                        );                                                   //
                    } else {
                        PAREN_DELIMIT(                  //
                            ADD_PARAM(else_body->condition);  //
                        );                              //
                    }
                }

                if (else_body->body != nullptr) {
                    else_body->body->body->accept(*this);
                }
            }
        }

        ADD_TOKEN(CXX_PP_ENDIF);
        return;
    }

    NO_EMIT_FORWARD_DECL;
    ADD_TOKEN(CXX_IF);

    if (node.has_eval && !node.has_const) {
        ADD_TOKEN(CXX_CONSTEXPR);
    }

    if (node.type == __AST_NODE::IfState::IfType::Unless) {  //
        PAREN_DELIMIT(                                       //
            ADD_TOKEN(CXX_EXCLAMATION);                      //
            PAREN_DELIMIT(                                   //
                ADD_NODE_PARAM(condition);                   //
            );                                               //
        );                                                   //
    } else {
        PAREN_DELIMIT(                  //
            ADD_NODE_PARAM(condition);  //
        );                              //
    }

    if (node.body != nullptr) {
        node.body->accept(*this);
    } else {
        tokens.push_back(std ::make_unique<CX_Token>(cxir_tokens ::CXX_SEMICOLON));
    };

    if (node.has_eval && !node.has_const) {
        if (!node.else_body.empty()) {
            for (auto &else_body : node.else_body) {
                if (else_body->type == __AST_NODE::ElseState::ElseType::Else) {
                    ADD_TOKEN(CXX_ELSE);
                } else {
                    ADD_TOKEN(CXX_ELSE);
                    ADD_TOKEN(CXX_IF);
                    ADD_TOKEN(CXX_CONSTEXPR);

                    if (else_body->type == __AST_NODE::ElseState::ElseType::ElseUnless) {
                        PAREN_DELIMIT(                                       //
                            ADD_TOKEN(CXX_EXCLAMATION);                      //
                            PAREN_DELIMIT(                                   //
                                ADD_PARAM(else_body->condition);         //
                            );                                               //
                        );                                                   //
                    } else {
                        PAREN_DELIMIT(                  //
                            ADD_PARAM(else_body->condition);  //
                        );                              //
                    }
                }

                if (else_body->body != nullptr) {
                    else_body->body->accept(*this);
                }
            }
        }
    } else {
        ADD_ALL_NODE_PARAMS(else_body);
    }
}

CX_VISIT_IMPL(SwitchCaseState) {
    NO_EMIT_FORWARD_DECL;

    switch (node.type) {
        case __AST_NODE::SwitchCaseState::CaseType::Case:
            ADD_TOKEN(CXX_CASE);
            ADD_NODE_PARAM(condition);
            ADD_TOKEN(CXX_COLON);

            BRACE_DELIMIT(  //
                if (node.body && node.body->body) { node.body->body->accept(*this); }

                ADD_TOKEN_AT_LOC(CXX_BREAK, node.marker);  // break;
                ADD_TOKEN(CXX_SEMICOLON);                  //
            );

            break;

        case __AST_NODE::SwitchCaseState::CaseType::Fallthrough:
            ADD_TOKEN(CXX_CASE);
            ADD_NODE_PARAM(condition);
            ADD_TOKEN(CXX_COLON);

            BRACE_DELIMIT(  //
                if (node.body && node.body->body) { node.body->body->accept(*this); }

                BRACKET_DELIMIT(                                                 //
                    BRACKET_DELIMIT(                                             //
                        ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, "fallthrough");  //
                    );                                                           //
                );                                                               // [[fallthrough]];

                ADD_TOKEN(CXX_SEMICOLON);  //
            );

            break;

        case __AST_NODE::SwitchCaseState::CaseType::Default:
            ADD_TOKEN(CXX_DEFAULT);
            ADD_TOKEN(CXX_COLON);

            BRACE_DELIMIT(  //
                if (node.body && node.body->body) { node.body->body->accept(*this); }

                ADD_TOKEN_AT_LOC(CXX_BREAK, node.marker);  // break;
                ADD_TOKEN(CXX_SEMICOLON);                  //
            );

            break;
    }
}

CX_VISIT_IMPL(SwitchState) {
    NO_EMIT_FORWARD_DECL;
    ADD_TOKEN(CXX_SWITCH);

    PAREN_DELIMIT(                  //
        ADD_NODE_PARAM(condition);  //
    );

    BRACE_DELIMIT(                   //
        ADD_ALL_NODE_PARAMS(cases);  //
    );
}

CX_VISIT_IMPL(YieldState) {
    NO_EMIT_FORWARD_DECL;
    ADD_TOKEN(CXX_CO_YIELD);
    ADD_NODE_PARAM(value);
    ADD_TOKEN(CXX_SEMICOLON);
}

CX_VISIT_IMPL(DeleteState) {
    NO_EMIT_FORWARD_DECL;
    ADD_TOKEN(CXX_DELETE);
    ADD_NODE_PARAM(value);
    ADD_TOKEN(CXX_SEMICOLON);
}

CX_VISIT_IMPL(ImportState) {
    NO_EMIT_FORWARD_DECL;
    throw std::runtime_error(std::string(colors::fg16::green) + std::string(__FILE__) + ":" +
                             std::to_string(__LINE__) + colors::reset + std::string(" - ") +
                             "This shouldn't be called, should be handled by the Preprocessor not "
                             "CodeGen, something went wrong.");
}

CX_VISIT_IMPL(ImportItems) {
    NO_EMIT_FORWARD_DECL;
    throw std::runtime_error(std::string(colors::fg16::green) + std::string(__FILE__) + ":" +
                             std::to_string(__LINE__) + colors::reset + std::string(" - ") +
                             "This shouldn't be called, should be handled by the Preprocessor not "
                             "CodeGen, something went wrong.");
}
CX_VISIT_IMPL(SingleImport) {
    NO_EMIT_FORWARD_DECL;
    throw std::runtime_error(std::string(colors::fg16::green) + std::string(__FILE__) + ":" +
                             std::to_string(__LINE__) + colors::reset + std::string(" - ") +
                             "This shouldn't be called, should be handled by the Preprocessor not "
                             "CodeGen, something went wrong.");
}
CX_VISIT_IMPL(SpecImport) {
    NO_EMIT_FORWARD_DECL;
    throw std::runtime_error(std::string(colors::fg16::green) + std::string(__FILE__) + ":" +
                             std::to_string(__LINE__) + colors::reset + std::string(" - ") +
                             "This shouldn't be called, should be handled by the Preprocessor not "
                             "CodeGen, something went wrong.");
}
CX_VISIT_IMPL(MultiImportState) {
    NO_EMIT_FORWARD_DECL;
    throw std::runtime_error(std::string(colors::fg16::green) + std::string(__FILE__) + ":" +
                             std::to_string(__LINE__) + colors::reset + std::string(" - ") +
                             "This shouldn't be called, should be handled by the Preprocessor not "
                             "CodeGen, something went wrong.");
}

CX_VISIT_IMPL(ReturnState) {
    NO_EMIT_FORWARD_DECL;
    ADD_TOKEN(CXX_RETURN);  // TODO co_return for generator contexts?
    ADD_NODE_PARAM(value);
    ADD_TOKEN(CXX_SEMICOLON);
}

CX_VISIT_IMPL(BreakState) {
    NO_EMIT_FORWARD_DECL;
    ADD_TOKEN(CXX_BREAK);
    ADD_TOKEN(CXX_SEMICOLON);
}

CX_VISIT_IMPL(BlockState) {
    // -> (statement ';')*
    if (!node.body.empty()) {
        for (const auto &i : node.body) {
            if (i != nullptr) {
                if (i->getNodeType() == __AST_NODE::nodes::LetDecl) {
                    __AST_N::NodeT<__AST_NODE::LetDecl> node = __AST_N::as<__AST_NODE::LetDecl>(i);
                    visit(*node, true);
                } else {
                    i->accept(*this);
                }
            }

            tokens.push_back(std::make_unique<CX_Token>(cxir_tokens::CXX_SEMICOLON));
        }
    }
}

CX_VISIT_IMPL(SuiteState) {
    // -> '{' body '}'
    BRACE_DELIMIT(                                 //
        if (node.body) { ADD_NODE_PARAM_BODY(); }  //
    );
}
CX_VISIT_IMPL(ContinueState) {
    NO_EMIT_FORWARD_DECL;
    ADD_TOKEN(CXX_CONTINUE);
}

CX_VISIT_IMPL(CatchState) {
    NO_EMIT_FORWARD_DECL;
    ADD_TOKEN(CXX_CATCH);

    if (!node.catch_state) {
        PAREN_DELIMIT(                    //
            ADD_TOKEN(CXX_ELLIPSIS);      //
        );
    } else {
        PAREN_DELIMIT(                    //
            ADD_NODE_PARAM(catch_state);  //
        );                                //
    }
    
    ADD_NODE_PARAM_BODY();
}

CX_VISIT_IMPL(FinallyState) {
    NO_EMIT_FORWARD_DECL;
    // TODO: this needs to be placed before return, so, the code gen needs to be statefull here...
    // for now it will just put the
    // https://stackoverflow.com/questions/33050620/golang-style-defer-in-c

    /// $finally _([&] { free(a); });

    ADD_TOKEN(CXX_SCOPE_RESOLUTION);
    ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, "helix");
    ADD_TOKEN(CXX_SCOPE_RESOLUTION);
    ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, "$finally");
    ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, "_" + generate_unique_name());
    ADD_TOKEN(CXX_LPAREN);
    ADD_TOKEN(CXX_LBRACKET);
    ADD_TOKEN(CXX_AMPERSAND);
    ADD_TOKEN(CXX_RBRACKET);
    ADD_NODE_PARAM_BODY();
    ADD_TOKEN(CXX_RPAREN);
    ADD_TOKEN(CXX_SEMICOLON);
}

CX_VISIT_IMPL(TryState) {
    NO_EMIT_FORWARD_DECL;

    ADD_NODE_PARAM(finally_state);

    ADD_TOKEN(CXX_TRY);
    ADD_NODE_PARAM_BODY();

    ADD_ALL_NODE_PARAMS(catch_states);
}

CX_VISIT_IMPL(PanicState) {
    NO_EMIT_FORWARD_DECL;
    if (!node.crash) {
        ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "_HX_MC_Q7_PANIC_M", node.marker);
    } else {
        ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "_HX_MC_Q7_INTERNAL_CRASH_PANIC_M", node.marker);
    }
    
    PAREN_DELIMIT(                    //
        ADD_NODE_PARAM(expr);        //
    );                                //
    ADD_TOKEN(CXX_SEMICOLON);
}

CX_VISIT_IMPL(ExprState) {
    NO_EMIT_FORWARD_DECL;
    // -> expr ';'
    ADD_NODE_PARAM(value);
    ADD_TOKEN(CXX_SEMICOLON);
}
