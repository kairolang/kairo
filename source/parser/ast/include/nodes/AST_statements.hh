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

#ifndef __AST_STATEMENTS_H__
#define __AST_STATEMENTS_H__

#include <memory>
#include <utility>

#include "parser/ast/include/config/AST_config.def"
#include "parser/ast/include/nodes/AST_expressions.hh"
#include "parser/ast/include/private/AST_nodes.hh"
#include "parser/ast/include/types/AST_types.hh"
#include "token/include/config/Token_config.def"

// va
// var_decl := 'let' Ident (':' E)? ('=' expr)? ';'

__AST_NODE_BEGIN {
    class NamedVarSpecifier final : public Node {
        BASE_CORE_METHODS(NamedVarSpecifier);

        // := Ident (':' E)?

        explicit NamedVarSpecifier(bool /* unused */) {}
        explicit NamedVarSpecifier(NodeT<IdentExpr> path, NodeT<Type> type = nullptr)
            : path(std::move(path))
            , type(std::move(type)) {}

        NodeT<IdentExpr> path;
        NodeT<Type>      type = nullptr;
        bool is_const = false;
    };

    class NamedVarSpecifierList final : public Node {
        BASE_CORE_METHODS(NamedVarSpecifierList);

        // := NamedVarSpecifier (',' NamedVarSpecifier)*

        explicit NamedVarSpecifierList(bool /* unused */) {}

        NodeV<NamedVarSpecifier> vars;
    };

    class ForPyStatementCore final : public Node {
        BASE_CORE_METHODS(ForPyStatementCore);

        // := NamedVarSpecifier 'in 'expr' Suite

        explicit ForPyStatementCore(bool /* unused */) {}

        __TOKEN_N::Token             in_marker;
        NodeT<NamedVarSpecifierList> vars;
        NodeT<>                      range;
        NodeT<>                      body;
    };

    class ForCStatementCore final : public Node {
        BASE_CORE_METHODS(ForCStatementCore);

        // := (expr)? ';' (expr)? ';' (expr)? Suite

        explicit ForCStatementCore(bool /* unused */) {}

        NodeT<>           init;
        NodeT<>           condition;
        NodeT<>           update;
        NodeT<SuiteState> body;
    };

    class ForState final : public Node {
        BASE_CORE_METHODS(ForState);

        // := 'for' (ForPyStatementCore | ForCStatementCore)

        enum class ForType {
            Python,
            C,
        };

        ForState(NodeT<> core, ForType type)
            : core(std::move(core))
            , type(type) {}

        NodeT<> core;
        ForType type;
    };

    class WhileState final : public Node {
        BASE_CORE_METHODS(WhileState);

        // := 'while' expr Suite

        explicit WhileState(NodeT<> condition, NodeT<SuiteState> body)
            : condition(std::move(condition))
            , body(std::move(body)) {}

        NodeT<>           condition;
        NodeT<SuiteState> body;
    };

    class IfState final : public Node {
        BASE_CORE_METHODS(IfState);

        // := 'if' expr Suite (ElseState)?

        enum class IfType {
            If,
            Unless,
        };

        explicit IfState(NodeT<> condition)
            : condition(std::move(condition)) {}

        NodeT<>           condition;
        NodeT<SuiteState> body;
        NodeV<ElseState>  else_body;
        IfType            type = IfType::If;
        bool has_const = false;
        bool has_eval  = false;
    };

    class ElseState final : public Node {
        BASE_CORE_METHODS(ElseState);

        // := 'else' Suite | 'else' ('if' | 'unless') E Suite

        enum class ElseType {
            Else,
            ElseIf,
            ElseUnless,
        };

        explicit ElseState(bool /* unused */) {}

        NodeT<>           condition;
        NodeT<SuiteState> body;
        ElseType          type = ElseType::Else;
    };

    class SwitchState final : public Node {
        BASE_CORE_METHODS(SwitchState);

        // := 'switch' expr '{' SwitchCaseState* '}'

        SwitchState(NodeT<> condition)
            : condition(std::move(condition)) {}

        NodeT<>                condition;
        NodeV<SwitchCaseState> cases;
    };

    class SwitchCaseState final : public Node {
        BASE_CORE_METHODS(SwitchCaseState);

        // := 'case' expr Suite | 'default' Suite

        enum class CaseType {
            Case,        // no fallthrough
            Default,     // no fallthrough
            Fallthrough, // fallthrough
        };

        SwitchCaseState(NodeT<>           condition,
                        NodeT<SuiteState> body,
                        CaseType          type,
                        __TOKEN_N::Token  marker)
            : condition(std::move(condition))
            , body(std::move(body))
            , type(type)
            , marker(std::move(marker)) {}

        NodeT<>           condition;
        NodeT<SuiteState> body;
        CaseType          type;
        __TOKEN_N::Token  marker;
    };

    /// ImportState        := 'import' (SpecImport | SingleImport) ';'
    /// SingleImport       := (ScopePath | StringLiteral) ('as' Ident)?
    /// ImportItems        := SingleImport (',' SingleImport)*
    /// SpecImport         := ScopePath '::' ('{' ImportItems '}') | ('*')

    /// MultiImportState   := 'import' '{' ImportState* '}'

    class ImportState final : public Node {
        BASE_CORE_METHODS(ImportState);

        enum class Type {
            Spec,
            Single,
        };

        explicit ImportState(NodeT<SingleImport> imp, bool is_module)
            : import(__AST_N::as<Node>(std::move(imp)))
            , explicit_module(is_module) {}
        
        explicit ImportState(NodeT<SpecImport> import, bool is_module)
            : import(__AST_N::as<Node>(std::move(import)))
            , type(Type::Spec)
            , explicit_module(is_module) {}

        NodeT<> import;
        Type    type            = Type::Single;
        bool    explicit_module = false;
    };

    /* DEPRECATE */
    class ImportItems final : public Node {
        BASE_CORE_METHODS(ImportItems);

        explicit ImportItems(NodeT<SingleImport> first) { imports.emplace_back(std::move(first)); }

        NodeV<SingleImport> imports;
    };

    class SingleImport final : public Node {
        BASE_CORE_METHODS(SingleImport);

        enum class Type {
            Module,  //< import the entire module relative to cwd / -i path
            File,    //< import a specific file either relative or absolute
        };

        explicit SingleImport(Type type)
            : type(type) {}

        NodeT<IdentExpr> alias; //< TODO: change to ScopePathExpr to allow for any path alias
        NodeT<>          path;  //< either a string literal or a scope path
        Type             type = Type::Module;
        bool             is_wildcard = false;
    };

    class SpecImport final : public Node {
        BASE_CORE_METHODS(SpecImport);

        enum class Type {
            Wildcard,  //< import into the current module namespace
            Symbol,    //< import a specific symbol from a module
        };

        explicit SpecImport(NodeT<ScopePathExpr> path)
            : path(std::move(path)) {}

        explicit SpecImport(/* takes ownership */ NodeT<SingleImport> import) {
            /// this means this is a single import thats a wildcard import
            if (import->is_wildcard) {
                if (import->type == SingleImport::Type::File) {
                    throw std::runtime_error("wildcard imports are not allowed in file imports");
                }

                this->path = __AST_N::as<ScopePathExpr>(std::move(import->path));
                this->type = Type::Wildcard;

                import.reset();  // clear the import

                return;
            }

            throw std::runtime_error("invalid import");
        }

        NodeT<ScopePathExpr> path;     ///< always used
        NodeT<ImportItems>   imports;  ///< only used if the type is Symbol
        Type                 type = Type::Symbol;
    };

    class MultiImportState final : public Node {
        BASE_CORE_METHODS(MultiImportState);
    };

    class YieldState final : public Node {
        BASE_CORE_METHODS(YieldState);

        // := 'yield' expr ';'

        explicit YieldState(NodeT<> value, __TOKEN_N::Token marker)
            : value(std::move(value))
            , marker(std::move(marker)) {}

        NodeT<> value;
        __TOKEN_N::Token marker;
    };

    class DeleteState final : public Node {
        BASE_CORE_METHODS(DeleteState);

        // := 'yield' expr ';'

        explicit DeleteState(NodeT<> value)
            : value(std::move(value)) {}

        NodeT<> value;
    };

    class ReturnState final : public Node {
        BASE_CORE_METHODS(ReturnState);

        // := 'return' expr ';'

        explicit ReturnState(NodeT<> value)
            : value(std::move(value)) {}

        NodeT<> value;
    };

    class BreakState final : public Node {
        BASE_CORE_METHODS(BreakState);

        // := 'break' ';'

        explicit BreakState(__TOKEN_N::Token marker)
            : marker(std::move(marker)) {}

        __TOKEN_N::Token marker;
    };

    class ContinueState final : public Node {
        BASE_CORE_METHODS(ContinueState);

        // := 'continue' ';'

        explicit ContinueState(__TOKEN_N::Token marker)
            : marker(std::move(marker)) {}

        __TOKEN_N::Token marker;
    };

    class ExprState final : public Node {
        BASE_CORE_METHODS(ExprState);

        // := expr ';'

        explicit ExprState(NodeT<> value)
            : value(std::move(value)) {}

        NodeT<> value;
    };

    class BlockState final : public Node {
        BASE_CORE_METHODS(BlockState);

        // := '{' Statement* '}'

        explicit BlockState(NodeV<> body)
            : body(std::move(body)) {}

        NodeV<> body;
    };

    class SuiteState final : public Node {
        BASE_CORE_METHODS(SuiteState);

        // := BlockState | (':' Statement)
        // the suite parser will either make a block node if theres a { or a single statement with
        // the :

        explicit SuiteState(NodeT<BlockState> body)
            : body(std::move(body)) {}

        NodeT<BlockState> body;
    };

    class CatchState final : public Node {
        BASE_CORE_METHODS(CatchState);

        // := 'catch' (NamedVarSpecifier | Type)? SuiteState (CatchState |
        // FinallyState)?

        CatchState(NodeT<> catch_state, NodeT<SuiteState> body)
            : catch_state(catch_state == nullptr ? nullptr : std::move(catch_state))
            , body(std::move(body)) {}

        NodeT<>           catch_state;
        NodeT<SuiteState> body;
    };

    class FinallyState final : public Node {
        BASE_CORE_METHODS(FinallyState);

        // := 'finally' SuiteState

        explicit FinallyState(NodeT<SuiteState> body)
            : body(std::move(body)) {}

        NodeT<SuiteState> body;
    };

    class TryState final : public Node {
        BASE_CORE_METHODS(TryState);

        // := 'try' SuiteState (CatchState*) (FinallyState)?

        explicit TryState(NodeT<SuiteState> body)
            : body(std::move(body)) {}

        TryState(NodeT<SuiteState>   body,
                 NodeV<CatchState>   catch_states,
                 NodeT<FinallyState> finally_state = nullptr)
            : body(std::move(body))
            , catch_states(std::move(catch_states))
            , finally_state(std::move(finally_state)) {}

        NodeT<SuiteState>   body;
        NodeV<CatchState>   catch_states;
        NodeT<FinallyState> finally_state;

        bool no_catch;
    };

    class PanicState final : public Node {
        BASE_CORE_METHODS(PanicState);

        // := 'panic' E ';'

        explicit PanicState(NodeT<> expr, __TOKEN_N::Token marker)
            : expr(std::move(expr))
            , marker(std::move(marker)) {}

        NodeT<> expr;
        __TOKEN_N::Token marker;
        bool crash = false;
    };

}  // namespace __AST_NODE_BEGIN

#endif  // __AST_STATEMENTS_H__