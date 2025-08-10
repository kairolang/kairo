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
#include "parser/ast/include/config/AST_config.def"
#include "parser/ast/include/nodes/AST_expressions.hh"
#include "parser/ast/include/types/AST_types.hh"
#include "token/include/private/Token_generate.hh"
#include "utils.hh"
#include "generator/include/CX-IR/reserved.hh"

class Foo {
    public:
    operator int() {
        return 192;
    }
};

CX_VISIT_IMPL(BinaryExpr) {
    // -> '(' lhs op  rhs ')'
    // FIXME: are the parens necessary?

    /// the one change to this behavior is with the range/range-inclusive operators
    /// we then change the codegen to emit either range(lhs, rhs) or range(lhs, rhs++)

    switch (node.op) {
        case token::OPERATOR_RANGE:
        case token::OPERATOR_RANGE_INCLUSIVE: {
            ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "range", node.op);
            ADD_TOKEN(CXX_LPAREN);

            ADD_NODE_PARAM(lhs);
            ADD_TOKEN(CXX_COMMA);
            ADD_NODE_PARAM(rhs);

            if (node.op.token_kind() == token::OPERATOR_RANGE_INCLUSIVE) {
                ADD_TOKEN_AT_LOC(CXX_PLUS, node.op);
                ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_LITERAL, "1", node.op);
            }

            ADD_TOKEN(CXX_RPAREN);
            return;
        }

        case token::KEYWORD_IN: {
            // lhs in rhs
            // becomes: rhs.operator$contains(lhs)

            ADD_NODE_PARAM(rhs);
            ADD_TOKEN_AT_LOC(CXX_DOT, node.op);
            ADD_TOKEN(CXX_LPAREN);
            ADD_NODE_PARAM(rhs);
            ADD_TOKEN(CXX_RPAREN);

            return;
        }

        default:
            break;
    }

    ADD_NODE_PARAM(lhs);
    ADD_TOKEN_AS_TOKEN(CXX_CORE_OPERATOR, node.op);
    ADD_NODE_PARAM(rhs);
}

CX_VISIT_IMPL(UnaryExpr) {
    // -> '(' op '(' opd ')' ')' | '(' opd ')'

    /// if op = '&' and value is a IdentExpr with value "null" then it is a nullptr
    /// if op = '*' and value is a IdentExpr with value "null" error

    if (node.in_type) {
        if (node.type == __AST_NODE::UnaryExpr::PosType::PostFix) {
            if (node.op.token_kind() != token::PUNCTUATION_QUESTION_MARK) {  // if foo*
                CODEGEN_ERROR(node.op, "type cannot have postfix specifier");
            }

            return;
        }

        // prefix
        if (node.opd->getNodeType() == __AST_NODE::nodes::Type) [[likely]] {
            auto type = __AST_NODE::Node::as<__AST_NODE::Type>(node.opd);

            if (type->value->getNodeType() == __AST_NODE::nodes::LiteralExpr) [[unlikely]] {
                auto ident = __AST_NODE::Node::as<__AST_NODE::LiteralExpr>(type->value)->value;

                if (ident.value() == "null") [[unlikely]] {
                    CODEGEN_ERROR(ident, "null is not a valid type, use 'void' instead");
                    return;
                }
            }
        }

        switch (node.op.token_kind()) {
            case token::OPERATOR_BITWISE_AND:
            case token::OPERATOR_LOGICAL_AND:
            case token::OPERATOR_MUL:
                break;

            default:
                CODEGEN_ERROR(node.op, "invalid specifier for type");
                return;
        }

        ADD_NODE_PARAM(opd);
        ADD_TOKEN_AS_TOKEN(CXX_CORE_OPERATOR, node.op);

        return;
    }

    if ((node.type == __AST_NODE::UnaryExpr::PosType::PostFix) && (node.op.token_kind() == token::PUNCTUATION_QUESTION_MARK)) {
        // codegen: opd.operator$question()
        ADD_NODE_PARAM(opd);
        ADD_TOKEN_AT_LOC(CXX_DOT, node.op);
        ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "operator$question", node.op);
        ADD_TOKEN(CXX_LPAREN);
        ADD_TOKEN(CXX_RPAREN);

        return;
    }

    if (node.opd->getNodeType() == __AST_NODE::nodes::LiteralExpr) {
        auto ident = __AST_NODE::Node::as<__AST_NODE::LiteralExpr>(node.opd)->value;

        if (ident.value() == "null") [[unlikely]] {
            switch (node.op.token_kind()) {
                case token::OPERATOR_BITWISE_AND:
                    break;

                case token::OPERATOR_MUL:
                    CODEGEN_ERROR(node.op, "cannot dereference null");
                    return;

                default:
                    CODEGEN_ERROR(node.op, "invalid specifier for null");
                    return;
            }

            ident.get_value() = "nullptr";
            ADD_TOKEN_AS_TOKEN(CXX_CORE_OPERATOR, ident);

            return;
        }
    }

    PAREN_DELIMIT(if (node.op.token_kind() != token::PUNCTUATION_QUESTION_MARK)
                      ADD_TOKEN_AS_TOKEN(CXX_CORE_OPERATOR, node.op);

                  PAREN_DELIMIT(ADD_NODE_PARAM(opd);););
}

CX_VISIT_IMPL(IdentExpr) {
    // if self then set to (*this)
    if (reserved_transformations.contains(node.name.value())) {
        reserved_transformations[node.name.value()](this, node.name);
        return;
    }

    // if its a "_" then add a /* unused */ comment
    if (node.name.value() == "_") {
        ADD_TOKEN_AS_TOKEN(CXX_CORE_IDENTIFIER, node.name);
        ADD_TOKEN_AS_VALUE_AT_LOC(CXX_ANNOTATION, "/* unused */", node.name);
        return;
    }
    
    ADD_TOKEN_AS_TOKEN(CXX_CORE_IDENTIFIER, node.name);
}

CX_VISIT_IMPL(NamedArgumentExpr) {
    // -> name '=' value
    ADD_NODE_PARAM(name);
    if (node.value) {
        ADD_TOKEN_AS_VALUE(CXX_CORE_OPERATOR, "=");
        ADD_NODE_PARAM(value);
    }
}

CX_VISIT_IMPL(ArgumentExpr) { ADD_NODE_PARAM(value); }

CX_VISIT_IMPL(ArgumentListExpr) {
    // -> '(' arg (',' arg)* ')'
    PAREN_DELIMIT(COMMA_SEP(args););
}

CX_VISIT_IMPL(GenericInvokeExpr) { ANGLE_DELIMIT(COMMA_SEP(args);); }

CX_VISIT_IMPL_VA(ScopePathExpr, bool access) {
    // -> path ('::' path)*

    if (node.global_scope) {
        ADD_TOKEN(CXX_SCOPE_RESOLUTION);
        ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, "helix");
        ADD_TOKEN(CXX_SCOPE_RESOLUTION);
    }

    for (const __AST_N::NodeT<__AST_NODE::IdentExpr> &ident : node.path) {
        ident->accept(*this);
        ADD_TOKEN(CXX_SCOPE_RESOLUTION);
    }

    if (access) {
        ADD_NODE_PARAM(access);
    }
}

CX_VISIT_IMPL(DotPathExpr) {
    // -> path '.' path
    ADD_NODE_PARAM(lhs);
    ADD_TOKEN_AS_VALUE(CXX_CORE_OPERATOR, ".");
    ADD_NODE_PARAM(rhs);
}

CX_VISIT_IMPL(ArrayAccessExpr) {
    // -> array '[' index ']'
    ADD_NODE_PARAM(lhs);
    BRACKET_DELIMIT(          //
        ADD_NODE_PARAM(rhs);  //
    );
}

CX_VISIT_IMPL(PathExpr) { ADD_NODE_PARAM(path); }

CX_VISIT_IMPL(FunctionCallExpr) {
    // path
    // generic
    // args

    size_t depth = 0;

    if (node.path->get_back_name().value() == "__inline_cpp") {
        if (node.args->getNodeType() != __AST_NODE::nodes::ArgumentListExpr ||
            __AST_N::as<__AST_NODE::ArgumentListExpr>(node.args)->args.size() != 1) {
            auto bad_tok = node.path->get_back_name();
            CODEGEN_ERROR(bad_tok, "__inline_cpp requires exactly one argument");
            return;
        }

        auto arg = __AST_N::as<__AST_NODE::ArgumentListExpr>(node.args)->args[0];
        if (arg->getNodeType() != __AST_NODE::nodes::ArgumentExpr ||
            __AST_N::as<__AST_NODE::ArgumentExpr>(arg)->value->getNodeType() !=
                __AST_NODE::nodes::LiteralExpr) {
            auto bad_tok = node.path->get_back_name();
            CODEGEN_ERROR(bad_tok, "__inline_cpp requires a string literal argument");
            return;
        }

        auto arg_ptr =
            __AST_N::as<__AST_NODE::LiteralExpr>(__AST_N::as<__AST_NODE::ArgumentExpr>(arg)->value);
        if (arg_ptr->contains_format_args) {
            auto bad_tok = node.path->get_back_name();
            CODEGEN_ERROR(bad_tok, "__inline_cpp does not support format arguments");
            return;
        }

        auto arg_str = arg_ptr->value;
        arg_str.get_value() =
            arg_str.value().substr(1, arg_str.value().size() - 2);  // remove quotes

        // remove any escaped chars (e.g. \" -> " or \\ -> \ and so on, but not \n or \t and so on)
        auto unescape_string = [](std::string &str) {
            for (size_t i = 0; i < str.size(); ++i) {
                if (str[i] == '\\') {
                    if (i + 1 < str.size()) {
                        switch (str[i + 1]) {
                            case '\\':
                            case '\'':
                            case '\"':
                            case '?':
                                str.erase(i, 1);
                                break;
                            case 'a':
                                str[i] = '\a';
                                str.erase(i + 1, 1);
                                break;
                            case 'b':
                                str[i] = '\b';
                                str.erase(i + 1, 1);
                                break;
                            case 'f':
                                str[i] = '\f';
                                str.erase(i + 1, 1);
                                break;
                            case 'n':
                                str[i] = '\n';
                                str.erase(i + 1, 1);
                                break;
                            case 'r':
                                str[i] = '\r';
                                str.erase(i + 1, 1);
                                break;
                            case 't':
                                str[i] = '\t';
                                str.erase(i + 1, 1);
                                break;
                            case 'v':
                                str[i] = '\v';
                                str.erase(i + 1, 1);
                                break;
                            default:
                                break;
                        }
                    }
                }
            }
        };

        unescape_string(arg_str.get_value());
        ADD_TOKEN_AS_TOKEN(CXX_INLINE_CODE, arg_str);

        return;
    }

    switch (node.path->type) {
        case __AST_NODE::PathExpr::PathType::Scope: {
            __AST_N::NodeT<__AST_NODE::ScopePathExpr> scope =
                __AST_N::as<__AST_NODE::ScopePathExpr>(node.path->path);
            this->visit(*scope, false);

            if (node.generic && scope->path.size() >= 1) {
                ADD_TOKEN(CXX_TEMPLATE);
            }

            ADD_PARAM(scope->access);
            break;
        }
        case __AST_NODE::PathExpr::PathType::Dot: {
            __AST_N::NodeT<__AST_NODE::DotPathExpr> dot =
                __AST_N::as<__AST_NODE::DotPathExpr>(node.path->path);

            ++depth;
            ADD_PARAM(dot->lhs);
            ADD_TOKEN_AS_VALUE(CXX_CORE_OPERATOR, ".");

            __AST_N::NodeT<> current = dot->rhs;

            while (auto next = std::dynamic_pointer_cast<__AST_NODE::DotPathExpr>(current)) {
                ++depth;

                ADD_PARAM(next->lhs);
                ADD_TOKEN_AS_VALUE(CXX_CORE_OPERATOR, ".");

                current = next->rhs;
            }

            if (node.generic && depth >= 1) {
                ADD_TOKEN(CXX_TEMPLATE);
            }

            ADD_PARAM(current);

            break;
        }
        case __AST_NODE::PathExpr::PathType::Identifier: {
            ADD_NODE_PARAM(path);
            break;
        }
    }

    ADD_NODE_PARAM(generic);

    if (node.args->getNodeType() == __AST_NODE::nodes::ObjInitExpr) {
        auto obj = __AST_N::as<__AST_NODE::ObjInitExpr>(node.args);
        obj->path = nullptr;
    }

    ADD_NODE_PARAM(args);
}

CX_VISIT_IMPL(ArrayLiteralExpr) {
    ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, "vec");
    BRACE_DELIMIT(COMMA_SEP(values););
}

CX_VISIT_IMPL(TupleLiteralExpr) {
    if ((!node.values.empty() && (node.values.size() > 0) &&
        (node.values[0]->getNodeType() == __AST_NODE::nodes::Type)) || node.in_type) {

        ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, "tuple");
        ANGLE_DELIMIT(COMMA_SEP(values););

        return;
    }

    BRACE_DELIMIT(COMMA_SEP(values););
}

CX_VISIT_IMPL(SetLiteralExpr) {
    ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, "set");
    BRACE_DELIMIT(COMMA_SEP(values););
}

CX_VISIT_IMPL(MapPairExpr) {
    ADD_TOKEN(CXX_LBRACE);
    ADD_NODE_PARAM(key);
    ADD_TOKEN(CXX_COLON);
    ADD_NODE_PARAM(value);
    ADD_TOKEN(CXX_RBRACE);
}

CX_VISIT_IMPL(MapLiteralExpr) {
    BRACE_DELIMIT(
        if (!node.values.empty()) {
            for (auto &i : node.values) {
                BRACE_DELIMIT(
                    ADD_PARAM(i->key);
                    ADD_TOKEN(CXX_COMMA);
                    ADD_PARAM(i->value);
                );

                ADD_TOKEN(CXX_COMMA);
            }

            tokens.pop_back();  // remove last comma
        }
    );
}

CX_VISIT_IMPL(ObjInitExpr) {
    ADD_NODE_PARAM(path);

    BRACE_DELIMIT(  //
        if (!node.kwargs.empty()) {
            for (auto &i : node.kwargs) {
                ADD_TOKEN(CXX_DOT);
                ADD_PARAM(i->name);
                ADD_TOKEN_AT_LOC(CXX_ASSIGN, i->name->name);
                ADD_PARAM(i->value);
                ADD_TOKEN(CXX_COMMA);
            }

            tokens.pop_back(); // remove last comma
        }  //
    );
}

CX_VISIT_IMPL(LambdaExpr) {
    NO_EMIT_FORWARD_DECL;

    BRACKET_DELIMIT(ADD_TOKEN_AT_LOC(CXX_AMPERSAND, node.marker););

    if (node.generics) {
        ANGLE_DELIMIT(                         //
            ADD_PARAM(node.generics->params);  //
        );
    }

    PAREN_DELIMIT(          //
        COMMA_SEP(params);  // (params)
    );

    ADD_TOKEN(CXX_PTR_ACC);
    if (node.returns) {
        ADD_NODE_PARAM(returns);
    } else {
        ADD_TOKEN_AT_LOC(CXX_VOID, node.marker);
    }

    if (node.generics) {
        if (node.generics->bounds) {
            ADD_TOKEN(CXX_REQUIRES);
            ADD_PARAM(node.generics->bounds);
        }
    }

    ADD_NODE_PARAM(body);
}

CX_VISIT_IMPL(TernaryExpr) {

    PAREN_DELIMIT(                  //
        ADD_NODE_PARAM(condition);  //
    );
    ADD_TOKEN(CXX_QUESTION);
    ADD_NODE_PARAM(if_true);
    ADD_TOKEN(CXX_COLON);
    ADD_NODE_PARAM(if_false);
}

CX_VISIT_IMPL(ParenthesizedExpr) { PAREN_DELIMIT(ADD_NODE_PARAM(value);); }

CX_VISIT_IMPL(CastExpr) {
    /*
    a as float;       // regular cast
    a as *int;        // pointer cast (safe, returns a pointer if the memory is allocated else
    *null) a as &int;        // reference cast (safe, returns a reference if the memory is allocated
    else &null) a as unsafe *int; // unsafe pointer cast (raw memory access) a as const int;   //
    const cast (makes the value immutable) a as int;         // removes the const qualifier if
    present else does nothing

    /// we now also have to do a check to see if the type has a `.as` method that takes a nullptr of
    the casted type and returns the casted type
    /// if it does we should use that instead of the regular cast

    template <typename T, typename U>
    concept has_castable = requires(T t, U* u) {
        { t.as(u) } -> std::same_as<U>;
    };

    // as_cast utility: resolves at compile-time whether to use 'op as' or static_cast
    template <typename T, typename U>
    constexpr auto as_cast(const T& obj) {
        if consteval {
            if constexpr (has_castable<T, U>) {
                return obj.as(static_cast<U*>(nullptr)); // Call 'op as'
            } else {
                return static_cast<U>(obj); // Fallback to static_cast
            }
        } else {
            return static_cast<U>(obj); // Non-consteval fallback (shouldn't happen here)
        }
    }

    */

    // a as float;        // const_cast | static_cast - removes the const qualifier if present else
    // static cast a as *int;         // dynamic_cast             - pointer cast (safe, returns a
    // pointer if the memory is allocated else *null) a as &int;         // static_cast - reference
    // cast (safe, returns a reference if the memory is allocated else &null) a as unsafe *int;  //
    // reintreprit_cast         - unsafe pointer cast (c style) a as const int;    // const_cast -
    // const cast (makes the value immutable) avaliable fucntions: std::as_remove_const
    //                      a as const int  -> std::as_const
    //                      a as float      -> std::as_cast
    //                      a as *int       -> std::as_pointer
    //                      a as unsafe int -> std::as_unsafe

    ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, "helix");
    ADD_TOKEN(CXX_SCOPE_RESOLUTION);
    ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, "std");
    ADD_TOKEN(CXX_SCOPE_RESOLUTION);

    if (node.type->specifiers.contains(token::tokens::KEYWORD_UNSAFE)) {
        ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, "as_unsafe");
    } else if (node.type->specifiers.contains(token::tokens::KEYWORD_CONST)) {
        ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, "as_const");
    } else {
        ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, "as_cast");
    }

    ANGLE_DELIMIT(             //
        ADD_NODE_PARAM(type);  //
        ADD_TOKEN(CXX_COMMA);
        ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, "decltype");
        PAREN_DELIMIT(              //
            ADD_NODE_PARAM(value);  //
        ););

    PAREN_DELIMIT(              //
        ADD_NODE_PARAM(value);  //
    );
}

// := E ('in' | 'derives') E
CX_VISIT_IMPL(InstOfExpr) {
    switch (node.op) {
        case __AST_NODE::InstOfExpr::InstanceType::Derives:
            // TODO: make it so it does not require that it is a class
            /// std::is_base_of<A, B>::value
            ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, "std");
            ADD_TOKEN(CXX_SCOPE_RESOLUTION);
            ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, "Meta");
            ADD_TOKEN(CXX_SCOPE_RESOLUTION);
            ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, "is_derived_of");
            ANGLE_DELIMIT(              //
                ADD_NODE_PARAM(type);   //
                ADD_TOKEN(CXX_COMMA);   //
                ADD_NODE_PARAM(value);  //
            );
            ADD_TOKEN(CXX_SCOPE_RESOLUTION);
            ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, "value");

            break;
        case __AST_NODE::InstOfExpr::InstanceType::Has:
            // since type is just an expr we would do
            // lhs.operator$contains(type);

            if (node.in_requires) {
                // we gotta add the value to the generics of type
                if (node.type->getNodeType() == __AST_NODE::nodes::Type) {
                    __AST_N::NodeT<__AST_NODE::Type> type = __AST_N::as<__AST_NODE::Type>(node.type);
                    
                    if (type->generics == nullptr || type->generics->args.empty()) {
                        type->generics = std::make_shared<__AST_NODE::GenericInvokeExpr>(node.value);
                    } else {
                        type->generics->args.insert(type->generics->args.begin(), node.value);
                    }

                    // value 'has' type
                    // T has Foo::<int>
                    // becomes: Foo<T, int>

                    ADD_PARAM(type);
                    return;
                }

                CODEGEN_ERROR(node.marker, "lhs of 'has' requires a type, but got a expression instead.");
                return;
            }

            ADD_NODE_PARAM(value);
            ADD_TOKEN_AT_LOC(CXX_DOT, node.marker);
            ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "operator$contains", node.marker);
            ADD_TOKEN(CXX_LPAREN);
            ADD_NODE_PARAM(type);
            ADD_TOKEN(CXX_RPAREN);

            break;
    }
}

CX_VISIT_IMPL(AsyncThreading) {
    switch (node.type) {
        case __AST_NODE::AsyncThreading::AsyncThreadingType::Await:
            ADD_TOKEN(CXX_CO_AWAIT);
            ADD_NODE_PARAM(value);
            break;
        case __AST_NODE::AsyncThreading::AsyncThreadingType::Spawn:
        case __AST_NODE::AsyncThreading::AsyncThreadingType::Thread:
        case __AST_NODE::AsyncThreading::AsyncThreadingType::Other:
            CXIR_NOT_IMPLEMENTED;
    }
}
