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

#ifndef __AST_EXPRESSIONS_H__
#define __AST_EXPRESSIONS_H__

#include <utility>

#include "parser/ast/include/config/AST_config.def"
#include "parser/ast/include/private/AST_nodes.hh"
#include "parser/ast/include/types/AST_modifiers.hh"
#include "parser/ast/include/types/AST_types.hh"
#include "token/include/config/Token_config.def"
#include "token/include/private/Token_base.hh"

__AST_NODE_BEGIN {
    class LiteralExpr final : public Node {  // := LITERAL
        BASE_CORE_METHODS(LiteralExpr);

        enum class LiteralType {
            Integer,
            Float,
            String,
            Char,
            Boolean,
            Null,
        };

        LiteralExpr(__TOKEN_N::Token value, LiteralType type)
            : value(std::move(value))
            , type(type) {}

        __TOKEN_N::Token value;
        LiteralType      type;
        bool             contains_format_args = false;
        NodeV<>          format_args;
    };

    class BinaryExpr final : public Node {  // := E op E
        BASE_CORE_METHODS(BinaryExpr);

        BinaryExpr(NodeT<> lhs, NodeT<> rhs, __TOKEN_N::Token op)
            : lhs(std::move(lhs))
            , op(std::move(op))
            , rhs(std::move(rhs)) {}

        NodeT<>          lhs;
        __TOKEN_N::Token op;
        NodeT<>          rhs;
    };

    class UnaryExpr final : public Node {  // := op E
        BASE_CORE_METHODS(UnaryExpr);

        enum class PosType { PreFix, PostFix };

        UnaryExpr(NodeT<> opd, __TOKEN_N::Token op, PosType type, bool in_type = false)
            : opd(std::move(opd))
            , op(std::move(op))
            , type(type)
            , in_type(in_type) {}

        NodeT<>          opd;
        __TOKEN_N::Token op;
        PosType          type    = PosType::PreFix;
        bool             in_type = false;

        void mark_in_type(bool as) {
            in_type = as;

            if (opd->getNodeType() == nodes::UnaryExpr) {
                __AST_N::as<UnaryExpr>(opd)->mark_in_type(as);
            }
        }
    };

    class IdentExpr final : public Node {  // := T
        BASE_CORE_METHODS(IdentExpr);

        explicit IdentExpr(__TOKEN_N::Token name, bool is_reserved_primitive = false)
            : name(std::move(name))
            , is_reserved_primitive(is_reserved_primitive) {}

        __TOKEN_N::Token name;
        bool             is_reserved_primitive = false;
    };

    class NamedArgumentExpr final : public Node {  // := IdentExpr '=' E
        BASE_CORE_METHODS(NamedArgumentExpr);

        NamedArgumentExpr(NodeT<IdentExpr> name, NodeT<> value)
            : name(std::move(name))
            , value(std::move(value)) {}

        NodeT<IdentExpr> name;
        NodeT<>          value;
    };

    class ArgumentExpr final : public Node {  // := PositionalArgumentExpr | NamedArgumentExpr
        BASE_CORE_METHODS(ArgumentExpr);

        explicit ArgumentExpr(NodeT<> value)
            : value(std::move(value))
            , type(ArgumentType::Positional) {};

        enum class ArgumentType {
            Positional,
            Keyword,
        };

        NodeT<>      value;
        ArgumentType type;
    };

    class ArgumentListExpr final : public Node {  // := '(' ArgumentExpr (',' ArgumentExpr)* ')'
        BASE_CORE_METHODS(ArgumentListExpr);

        explicit ArgumentListExpr(NodeT<> args) {
            if (args != nullptr) {
                (this->args).emplace_back(std::move(args));
            }
        }

        explicit ArgumentListExpr(NodeV<> args)
            : args(std::move(args)) {}

        explicit ArgumentListExpr(bool /* unused */) {}

        NodeV<> args;
    };

    class GenericInvokeExpr final : public Node {  // := '<' Type ((',' Type)*)? '>'
        BASE_CORE_METHODS(GenericInvokeExpr);

        explicit GenericInvokeExpr(NodeT<> args) {
            if (args != nullptr) {
                (this->args).emplace_back(std::move(args));
            }
        }

        explicit GenericInvokeExpr(NodeV<> args)
            : args(std::move(args)) {}

        NodeV<> args;
    };

    class ScopePathExpr final : public Node {  // := E '::' E
        /// TODO: add support for generics
        BASE_CORE_METHODS(ScopePathExpr);

        explicit ScopePathExpr(NodeT<IdentExpr> full) { path.emplace_back(std::move(full)); }
        explicit ScopePathExpr(bool /* unused */) {}
        explicit ScopePathExpr(NodeV<IdentExpr> path, NodeT<> access, bool global_scope)
            : path(std::move(path))
            , access(std::move(access))
            , global_scope(global_scope) {}

        // -- Helper Functions -- //

        [[nodiscard]] token::Token get_back_name() const {
            if (path.empty()) {
                return token::Token(
                    token::tokens::IDENTIFIER, "__/kairo$$internal/__", "__global__");
            }

            return path.back()->name;
        }



        NodeV<IdentExpr> path;
        NodeT<>          access;
        bool             global_scope = false;
    };

    class DotPathExpr final : public Node {  // := E '.' E
        BASE_CORE_METHODS(DotPathExpr);

        DotPathExpr(NodeT<> lhs, NodeT<> rhs)
            : lhs(std::move(lhs))
            , rhs(std::move(rhs)) {}

        [[nodiscard]] NodeT<> get_back() const {
            NodeT<> current = rhs;

            while (auto next = std::dynamic_pointer_cast<DotPathExpr>(current)) {
                current = next->rhs;
            }

            return current;
        }

        NodeT<> lhs;
        NodeT<> rhs;
    };

    class ArrayAccessExpr final : public Node {  // := E '[' E ']'
        BASE_CORE_METHODS(ArrayAccessExpr);

        ArrayAccessExpr(NodeT<> lhs, NodeT<> rhs)
            : lhs(std::move(lhs))
            , rhs(std::move(rhs)) {}

        NodeT<> lhs;
        NodeT<> rhs;
    };

    class PathExpr final : public Node {  // := ScopePathExpr | DotPathExpr
        BASE_CORE_METHODS(PathExpr);

        enum class PathType : char {
            Scope,
            Dot,
            Identifier,
        };

        explicit PathExpr(NodeT<> path)
            : path(std::move(path))
            , type(PathType::Identifier) {}

        explicit PathExpr(NodeT<> path, PathType type)
            : path(std::move(path))
            , type(type) {}

        NodeT<>  path;
        PathType type = PathType::Identifier;

        // -- Helper Functions -- //

        [[nodiscard]] token::Token get_back_name() const {
            if (path == nullptr) {
                throw std::runtime_error("invalid path, possible memory corruption");
            }

            switch (path->getNodeType()) {
                case nodes::ScopePathExpr: {
                    NodeT<ScopePathExpr> scope = __AST_N::as<ScopePathExpr>(path);
                    if (scope->path.empty()) {  // this is a global scope
                        return token::Token(
                            token::tokens::IDENTIFIER, "__/kairo$$internal/__", "__global__");
                    }

                    return scope->path.back()->name;
                    break;
                }
                case nodes::IdentExpr:
                    return __AST_N::as<__AST_NODE::IdentExpr>(path)->name;
                    break;
                default:
                    print("failed default path", (int)type);
            }

            throw std::runtime_error("invalid path type, possible memory corruption");
        }

        [[nodiscard]] size_t path_length() const {
            if (path == nullptr) {
                return 0;
            }

            switch (type) {
                case PathType::Scope:
                    return __AST_N::as<ScopePathExpr>(path)->path.size();
                    break;
                case PathType::Dot: {
                    size_t length = 0;
                    NodeT<> current = path;

                    while (auto next = std::dynamic_pointer_cast<DotPathExpr>(current)) {
                        ++length;
                        current = next->rhs;
                    }

                    return length + 1;
                    break;
                }
                case PathType::Identifier:
                    return 1;
                    break;
                default:
                    print("failed default path", (int)type);
            }

            return 0;
        }
    };

    class FunctionCallExpr final : public Node {  // := PathExpr GenericInvokeExpr? ArgumentListExpr
        BASE_CORE_METHODS(FunctionCallExpr);

        FunctionCallExpr(NodeT<PathExpr>          path,
                         NodeT<>                  args,
                         NodeT<GenericInvokeExpr> generic = nullptr)
            : path(std::move(path))
            , args(std::move(args))
            , generic(std::move(generic)) {}

        NodeT<PathExpr>          path;
        NodeT<>                  args;
        NodeT<GenericInvokeExpr> generic;
    };

    class ArrayLiteralExpr final : public Node {  // := '[' E (',' E)* ']'
        BASE_CORE_METHODS(ArrayLiteralExpr);

        explicit ArrayLiteralExpr(NodeT<> value) { values.emplace_back(std::move(value)); }

        NodeV<> values;
    };

    class TupleLiteralExpr final : public Node {  // := '(' E (',' E)* ')'
        BASE_CORE_METHODS(TupleLiteralExpr);

        explicit TupleLiteralExpr(NodeT<> value) { values.emplace_back(std::move(value)); }

        NodeV<> values;
        bool in_type = false;
    };

    class SetLiteralExpr final : public Node {  // := '{' E (',' E)* '}'
        BASE_CORE_METHODS(SetLiteralExpr);

        explicit SetLiteralExpr(NodeT<> value) { values.emplace_back(std::move(value)); }

        NodeV<> values;
    };

    class MapPairExpr final : public Node {  // := E ':' E
        BASE_CORE_METHODS(MapPairExpr);

        MapPairExpr(NodeT<> key, NodeT<> value)
            : key(std::move(key))
            , value(std::move(value)) {}

        NodeT<> key;
        NodeT<> value;
    };

    class MapLiteralExpr final : public Node {
        BASE_CORE_METHODS(MapLiteralExpr);

        explicit MapLiteralExpr(NodeT<MapPairExpr> value) { values.emplace_back(std::move(value)); }

        NodeV<MapPairExpr> values;
    };

    class ObjInitExpr final
        : public Node {  // := '{' (NamedArgumentExpr (',' NamedArgumentExpr)*)? '}'
        BASE_CORE_METHODS(ObjInitExpr);

        explicit ObjInitExpr(NodeT<NamedArgumentExpr> args) {
            this->kwargs.emplace_back(std::move(args));
        }

        static bool is_allowed(__AST_NODE::nodes node_t) {
            switch (node_t) {
                case __AST_NODE::nodes::IdentExpr:
                    [[fallthrough]];
                case __AST_NODE::nodes::GenericInvokeExpr:
                    [[fallthrough]];
                case __AST_NODE::nodes::ScopePathExpr:
                    [[fallthrough]];
                case __AST_NODE::nodes::DotPathExpr:
                    [[fallthrough]];
                case __AST_NODE::nodes::PathExpr:
                    [[fallthrough]];
                case __AST_NODE::nodes::Type:
                    return true;
                default:
                    return false;
            }
        };

        explicit ObjInitExpr(bool /* unused */) {}

        NodeV<NamedArgumentExpr> kwargs;
        NodeT<>                  path;
    };

    class LambdaExpr final : public Node {
        BASE_CORE_METHODS(LambdaExpr);

        explicit LambdaExpr(__TOKEN_N::Token marker)
            : marker(std::move(marker)) {}

        __TOKEN_N::Token    marker;
        NodeV<VarDecl>      params;
        NodeT<RequiresDecl> generics;
        NodeT<Type>         returns;
        NodeT<SuiteState>   body;
    };

    class TernaryExpr final : public Node {  // := (E '?' E ':' E) | (E 'if' E 'else' E)
        BASE_CORE_METHODS(TernaryExpr);

        TernaryExpr(NodeT<> condition, NodeT<> if_true, NodeT<> if_false)
            : condition(std::move(condition))
            , if_true(std::move(if_true))
            , if_false(std::move(if_false)) {}

        NodeT<> condition;
        NodeT<> if_true;
        NodeT<> if_false;
    };

    class ParenthesizedExpr final : public Node {  // := '(' E ')'
        BASE_CORE_METHODS(ParenthesizedExpr);

        explicit ParenthesizedExpr(NodeT<> value)
            : value(std::move(value)) {}

        NodeT<> value;
    };

    class CastExpr final : public Node {  // := E 'as' E
        BASE_CORE_METHODS(CastExpr);

        CastExpr(NodeT<> value, NodeT<Type> type)
            : value(std::move(value))
            , type(std::move(type)) {}

        NodeT<>     value;
        NodeT<Type> type;
    };

    class InstOfExpr final : public Node {  // := E ('in' | 'derives') E
        BASE_CORE_METHODS(InstOfExpr);

        enum class InstanceType {
            Implement,
            Derives,
        };

        InstOfExpr(NodeT<> value, NodeT<> type, InstanceType op, token::Token marker)
            : value(std::move(value))
            , type(std::move(type))
            , marker(std::move(marker))
            , op(op) {}

        NodeT<>      value;
        NodeT<>      type;
        token::Token marker;
        bool in_requires = false;
        InstanceType op;
    };

    class Type final : public Node {  // := IdentExpr
        BASE_CORE_METHODS(Type);

        struct FnPtr {
            __TOKEN_N::Token marker;

            // fn (...) -> ...

            NodeV<Type> params;
            NodeT<Type> returns;
        };

        explicit Type(NodeT<> value)
            : value(std::move(value)) {}
        explicit Type(FnPtr value)
            : fn_ptr(std::move(value)) {}
        explicit Type(bool /* unused */) {}

        token::Token             marker;
        NodeT<>                  value;
        NodeT<GenericInvokeExpr> generics;
        bool                     nullable  = false;
        token::Token             nullable_marker;
        bool                     is_fn_ptr = false;
        FnPtr                    fn_ptr{};  // never set unless is_fn_ptr is true
        Modifiers                specifiers = Modifiers(Modifiers::ExpectedModifier::TypeSpec);
    };

    class AsyncThreading final : public Node {  // := IdentExpr
        BASE_CORE_METHODS(AsyncThreading);

        enum class AsyncThreadingType { Await, Spawn, Thread, Other };

        explicit AsyncThreading(NodeT<> value, const __TOKEN_N::Token &type)
            : value(std::move(value)) {
            switch (type.token_kind()) {
                case __TOKEN_N::KEYWORD_AWAIT:
                    this->type = AsyncThreadingType::Await;
                    break;
                case __TOKEN_N::KEYWORD_SPAWN:
                    this->type = AsyncThreadingType::Spawn;
                    break;
                case __TOKEN_N::KEYWORD_THREAD:
                    this->type = AsyncThreadingType::Thread;
                    break;
                default:
                    this->type = AsyncThreadingType::Other;
                    break;
            }
        }

        NodeT<>            value;
        AsyncThreadingType type;
    };
}

#endif  // __AST_EXPRESSIONS_H__