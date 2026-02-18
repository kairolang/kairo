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

#ifndef __AST_DECLARATIONS_H__
#define __AST_DECLARATIONS_H__

#include <utility>
#include <vector>

#include "parser/ast/include/config/AST_config.def"
#include "parser/ast/include/nodes/AST_expressions.hh"
// #include "parser/ast/include/private/AST_nodes.hh"
#include "parser/ast/include/types/AST_modifiers.hh"
#include "parser/ast/include/types/AST_types.hh"

__AST_NODE_BEGIN {
    class RequiresParamDecl final : public Node {
        BASE_CORE_METHODS(RequiresParamDecl);

        // RequiresParamDecl := 'const'? (S.NamedVarSpecifier) ('=' E)?
        explicit RequiresParamDecl(bool /* unused */) {}
        explicit RequiresParamDecl(NodeT<NamedVarSpecifier> var)
            : var(std::move(var)) {}

        NodeT<NamedVarSpecifier> var;
        NodeT<>                  value;
        bool                     is_const = false;
        NodeT<InstOfExpr>        bound;

    };

    class RequiresParamList final : public Node {
        BASE_CORE_METHODS(RequiresParamList);

        // RequiresParamList := (RequiresParamDecl (',' RequiresParamDecl)*)?
        explicit RequiresParamList(NodeT<RequiresParamDecl> first) {
            (this->params).emplace_back(std::move(first));
        }

        NodeV<RequiresParamDecl> params;
    };

    class EnumMemberDecl final : public Node {
        BASE_CORE_METHODS(EnumMemberDecl);

        // EnumMemberDecl := E.IdentExpr ('=' E)?
        explicit EnumMemberDecl(NodeT<IdentExpr> name)
            : name(std::move(name)) {}

        NodeT<IdentExpr> name;
        NodeT<>          value;
    };

    class UDTDeriveDecl final : public Node {
        BASE_CORE_METHODS(UDTDeriveDecl);

        // UDTDeriveDecl := 'derives' (VisDecl? E.Type (',' VisDecl? E.Type)*)?
        explicit UDTDeriveDecl(std::pair<NodeT<Type>, AccessSpecifier> first) {
            (this->derives).emplace_back(std::move(first));
        }

        std::vector<std::pair<NodeT<Type>, AccessSpecifier>> derives;
    };

    class TypeBoundList final : public Node {
        BASE_CORE_METHODS(TypeBoundList);

        // TypeBoundList := (TypeBoundDecl (',' TypeBoundDecl)*)?
        explicit TypeBoundList(NodeT<InstOfExpr> bound) {
            (this->bounds).emplace_back(std::move(bound));
        }

        explicit TypeBoundList(bool /* unused */) {}

        NodeV<InstOfExpr> bounds;
    };

    class TypeBoundDecl final : public Node {
        BASE_CORE_METHODS(TypeBoundDecl);

        // TypeBoundDecl := InstOfExpr

        NodeT<InstOfExpr> bound;
    };

    class RequiresDecl final : public Node {
        BASE_CORE_METHODS(RequiresDecl);

        // RequiresDecl := 'requires' '<' RequiresParamList '>' ('where' TypeBoundList)?
        explicit RequiresDecl(NodeT<RequiresParamList> params)
            : params(std::move(params)) {}

        NodeT<RequiresParamList> params;
        NodeT<TypeBoundList>     bounds;
    };

    class StructDecl final : public Node {
        BASE_CORE_METHODS(StructDecl);

        // StructDecl := 'const'? VisDecl? 'struct' E.IdentExpr UDTDeriveDecl? RequiresDecl? S.Suite
        explicit StructDecl(bool /* unused */) {}

        NodeT<IdentExpr>     name;
        NodeT<UDTDeriveDecl> derives;
        NodeT<RequiresDecl>  generics;
        NodeT<SuiteState>    body;

        Modifiers modifiers = Modifiers(Modifiers::ExpectedModifier::ClassSpec,
                                        Modifiers::ExpectedModifier::AccessSpec);
    };

    class ConstDecl final : public Node {
        BASE_CORE_METHODS(ConstDecl);

        // LetDecl :=  VisDecl? 'let'   SharedModifiers VarDecl* ';'
        explicit ConstDecl(bool /* unused */) {}

        Modifiers      modifiers = Modifiers(Modifiers::ExpectedModifier::FuncSpec);
        Modifiers      vis       = Modifiers(Modifiers::ExpectedModifier::AccessSpec);
        NodeV<VarDecl> vars;
    };

    class ExtendDecl final : public Node {
        BASE_CORE_METHODS(ExtendDecl);

        // ExtendDecl := 'const'? VisDecl? 'class'     E.IdentExpr UDTDeriveDecl? RequiresDecl?
        // S.Suite

        explicit ExtendDecl(bool /* unused */) {}

        std::vector<std::pair<NodeT<Type>, AccessSpecifier>> extends;
        NodeT<IdentExpr>                   name;
        NodeT<UDTDeriveDecl>               derives;
        NodeT<RequiresDecl>                generics;
        NodeT<SuiteState>                  body;
        Modifiers                          modifiers = Modifiers(
              Modifiers::ExpectedModifier::ClassSpec,
              Modifiers::ExpectedModifier::AccessSpec
        );
    };

    class ClassDecl final : public Node {
        BASE_CORE_METHODS(ClassDecl);

        // ClassDecl := 'const'? VisDecl? 'class'     E.IdentExpr UDTDeriveDecl? RequiresDecl?
        // S.Suite

        explicit ClassDecl(bool /* unused */) {}

        std::vector<std::pair<NodeT<Type>, AccessSpecifier>> extends;
        Modifiers            modifiers = Modifiers(Modifiers::ExpectedModifier::ClassSpec,
                                        Modifiers::ExpectedModifier::AccessSpec);
        NodeT<IdentExpr>     name;
        NodeT<UDTDeriveDecl> derives;
        NodeT<RequiresDecl>  generics;
        NodeT<SuiteState>    body;
    };

    class InterDecl final : public Node {
        BASE_CORE_METHODS(InterDecl);

        // InterDecl := 'const'? VisDecl? 'interface' E.IdentExpr UDTDeriveDecl? RequiresDecl?
        // S.Suite

        explicit InterDecl(bool /* unused */) {}

        Modifiers            modifiers = Modifiers(Modifiers::ExpectedModifier::ClassSpec,
                                        Modifiers::ExpectedModifier::AccessSpec);
        NodeT<IdentExpr>     name;
        NodeT<UDTDeriveDecl> derives;
        NodeT<RequiresDecl>  generics;
        NodeT<SuiteState>    body;
    };

    class EnumDecl final : public Node {
        BASE_CORE_METHODS(EnumDecl);

        // EnumDecl :=  VisDecl? 'enum' ('derives' E.Type)? E.ObjInitExpr
        explicit EnumDecl(bool /* unused */) {}

        Modifiers             vis = Modifiers(Modifiers::ExpectedModifier::AccessSpec);
        NodeT<IdentExpr>      name;
        NodeT<Type>           derives;
        NodeV<EnumMemberDecl> members;
    };

    class TypeDecl final : public Node {
        BASE_CORE_METHODS(TypeDecl);

        // TypeDecl :=  VisDecl? 'type'  E.IdentExpr RequiresDecl? '=' Type ';'
        explicit TypeDecl(bool /* unused */) {}

        Modifiers           vis = Modifiers(Modifiers::ExpectedModifier::AccessSpec);
        NodeT<IdentExpr>    name;
        NodeT<RequiresDecl> generics;
        NodeT<Type>         type;
    };

    class FuncDecl final : public Node {
        BASE_CORE_METHODS(FuncDecl);

        // FuncDecl :=  SharedModifiers? 'fn' E.PathExpr '(' VarDecl[true]* ')' RequiresDecl? ('->'
        // E.TypeExpr)? (S.Suite | ';' | '=' ('default' | 'delete'))

        explicit FuncDecl(bool /* unused */) {}

        token::TokenList get_name_t() const {
            /// normalize the func name
            token::TokenList result;

            if (!name) {
                result.emplace_back(marker);
                return result;
            }

            switch (name->type) {
                case PathExpr::PathType::Identifier: {
                    result.push_back(as<IdentExpr>(name->path)->name);
                    break;
                }

                case PathExpr::PathType::Scope: {
                    auto path = as<ScopePathExpr>(name->path);

                    for (const auto &token : path->path) {
                        result.push_back(token->name);
                    }

                    break;
                }

                default:
                    break;
            }

            return result;
        }

        // fn op + ();

        Modifiers modifiers  = Modifiers(Modifiers::ExpectedModifier::FuncSpec,
                                        Modifiers::ExpectedModifier::AccessSpec);
        Modifiers qualifiers = Modifiers(Modifiers::ExpectedModifier::FuncQual);

        token::Token        marker;
        NodeT<PathExpr>     name;    // if an op then this would be alias
        NodeV<VarDecl>      params;
        NodeT<RequiresDecl> generics;
        NodeT<Type>         returns;
        NodeT<SuiteState>   body;
        
        bool is_op = false;  // if this is an operator function
        std::vector<__TOKEN_N::Token> op;
    };

    class VarDecl final : public Node {
        BASE_CORE_METHODS(VarDecl);

        // VarDecl := S.NamedVarSpecifier ('=' E)? ~ also pass in a bool to force type need
        explicit VarDecl(NodeT<NamedVarSpecifier> var, NodeT<> value = nullptr)
            : var(std::move(var))
            , value(std::move(value)) {}

        NodeT<NamedVarSpecifier> var;
        NodeT<>                  value;
    };

    class FFIDecl final : public Node {
        BASE_CORE_METHODS(FFIDecl);

        // FFIDecl :=  VisDecl? 'ffi' L.StringLiteral D
        explicit FFIDecl(bool /* unused */) {}

        Modifiers          vis = Modifiers(Modifiers::ExpectedModifier::AccessSpec);
        NodeT<LiteralExpr> name;
        NodeT<>            value;
    };

    class LetDecl final : public Node {
        BASE_CORE_METHODS(LetDecl);

        // LetDecl :=  VisDecl? 'let'   SharedModifiers VarDecl* ';'
        explicit LetDecl(bool /* unused */) {}

        Modifiers      modifiers = Modifiers(Modifiers::ExpectedModifier::FuncSpec);
        Modifiers      vis       = Modifiers(Modifiers::ExpectedModifier::AccessSpec);
        NodeV<VarDecl> vars;
    };

    class ModuleDecl final : public Node {
        BASE_CORE_METHODS(ModuleDecl);

        // ModuleDecl :=  'inline'? 'module' E.PathExpr S.Suite
        explicit ModuleDecl(NodeT<PathExpr>   name,
                            NodeT<SuiteState> body,
                            bool              inline_module = false)

            : body(std::move(body))
            , name(std::move(name))
            , inline_module(inline_module) {}

        NodeT<SuiteState> body;
        NodeT<PathExpr>   name;
        bool              inline_module = false;
    };

}  // namespace __AST_NODE_BEGIN

#endif  // __AST_DECLARATIONS_H__