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

#include "utils.hh"


CX_VISIT_IMPL(InterDecl) {
    // can have let const eval, type and functions, default impl functions...
    // TODO: Modifiers
    // InterDecl := 'const'? VisDecl? 'interface' E.IdentExpr UDTDeriveDecl? RequiresDecl?
    // S.Suite
    // ADD_NODE_PARAM(generics); // WE need a custom generics impl here as Self is the first generic

    /// op + fn add(self, other: self) -> self;
    /// { $self + b } -> std::same_as<self>;
    /// { $self.add(b) } -> std::same_as<self>;

    // template <typename self>
    // concept MultiMethod = requires(self t) {
    //     // Check for instance methods
    //     { t.instanceMethod() } -> std::same_as<void>;
    //     { t.getValue() } -> std::same_as<int>;
    //     // check for var
    //     { t.var } -> std::same_as<int>;

    //     // Check for a constructor
    //     self(); // Default constructor

    //     // Check for a static method
    //     { self::staticMethod() } -> std::same_as<void>;
    // };

    /// the only things allwoed in a n itnerface delc:
    /// - LetDecl
    /// - FuncDecl
    /// - OpDecl
    /// - TypeDecl
    /// - ConstDecl

    if (node.name == nullptr) {
        throw std::runtime_error(
            std::string(colors::fg16::green) + std::string(__FILE__) + ":" +
            std::to_string(__LINE__) + colors::reset + std::string(" - ") +
            "Interface Declaration is missing the name param (ub), open an issue on github.");
    }

    auto is_self_t = [&](__AST_N::NodeT<__AST_NODE::Type> &typ) -> bool {
        if (typ->value->getNodeType() == __AST_NODE::nodes::IdentExpr) {
            __AST_N::NodeT<__AST_NODE::IdentExpr> ident =
                __AST_N::as<__AST_NODE::IdentExpr>(typ->value);

            if (ident->name.value() == "self") {
                /// add the self directly
                ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "self", ident->name);
                return true;
            }
        }

        return false;
    };

    token::Token self           = node.name->name;
    std::string  self_parm_name = generate_unique_name();
    std::unordered_map<__AST_N::NodeT<__AST_NODE::VarDecl> *, std::string> type_map;

    auto self_tok = __AST_N::make_node<__AST_NODE::RequiresParamDecl>(
        __AST_N::make_node<__AST_NODE::NamedVarSpecifier>(__AST_N::make_node<__AST_NODE::IdentExpr>(
            __TOKEN_N::Token(self.line_number(),
                             self.column_number(),
                             4,
                             (self.offset() - self.length()) + 4,
                             "self",
                             self.file_name(),
                             "_"))));

    if (node.generics) {  //
        node.generics->params->params.insert(node.generics->params->params.begin(), self_tok);
    } else {
        const_cast<__AST_N::NodeT<__AST_NODE::RequiresDecl> &>(node.generics) =
            __AST_N::make_node<__AST_NODE::RequiresDecl>(
                __AST_N::make_node<__AST_NODE::RequiresParamList>(self_tok));
    }

    for (auto &decl : node.body->body->body) {
        switch (decl->getNodeType()) {
            case __AST_NODE::nodes::FuncDecl: {
                __AST_N::NodeT<__AST_NODE::FuncDecl> func_decl =
                    __AST_N::as<__AST_NODE::FuncDecl>(decl);

                auto [$self, $static] = contains_self_static(func_decl);
                if ($self && $static) {
                    CODEGEN_ERROR(self,
                                  "function is marked static but also takes a self parameter");
                    break;
                }

                if (func_decl->body != nullptr) {
                    CODEGEN_ERROR(func_decl->get_name_t().back(),
                                  "functions have to be forward declarations in an interface.")
                    break;
                }

                if (func_decl->generics != nullptr) {
                    CODEGEN_ERROR(func_decl->get_name_t().back(),
                                  "functions can not have `requires` in an interface, apply them "
                                  "to the interface itself instead.");
                    break;
                }

                if (!func_decl->params.empty()) {
                    bool first = $self;

                    for (auto &param : func_decl->params) {
                        if (first) {
                            first = !first;
                            continue;
                        }

                        type_map[&param] = generate_unique_name();
                    }
                }

                break;
            }

            case __AST_NODE::nodes::OpDecl: {  // WARN: this does not remove the self param from the
                                               //       function decl
                __AST_N::NodeT<__AST_NODE::OpDecl> op_decl = __AST_N::as<__AST_NODE::OpDecl>(decl);

                auto [$self, $static] = contains_self_static(op_decl);
                if ($self && $static) {
                    CODEGEN_ERROR(self,
                                  "function is marked static but also takes a self parameter");
                    break;
                }

                if (op_decl->func->body != nullptr) {
                    CODEGEN_ERROR(op_decl->func->get_name_t().back(),
                                  "functions have to be forward declarations in an interface.")
                    break;
                }

                if (op_decl->func->generics != nullptr) {
                    CODEGEN_ERROR(op_decl->func->get_name_t().back(),
                                  "functions can not have `requires` in an interface, apply them "
                                  "to the interface itself instead.");
                    break;
                }

                if (!op_decl->func->params.empty()) {
                    bool first = $self;

                    for (auto &param : op_decl->func->params) {
                        if (first) {
                            first = !first;
                            continue;
                        }

                        type_map[&param] = generate_unique_name();
                    }
                }

                break;
            }

            /// ------------------------- only validation at this stage ------------------------ ///
            case __AST_NODE::nodes::TypeDecl: {
                __AST_N::NodeT<__AST_NODE::TypeDecl> type_decl =
                    __AST_N::as<__AST_NODE::TypeDecl>(decl);
                CODEGEN_ERROR(type_decl->name->name,
                              "Type definitions are not allowed in interfaces");
                return;
            }
            case __AST_NODE::nodes::LetDecl: {
                __AST_N::NodeT<__AST_NODE::LetDecl> let_decl =
                    __AST_N::as<__AST_NODE::LetDecl>(decl);

                for (auto &var : let_decl->vars) {
                    if (var->value != nullptr) {
                        CODEGEN_ERROR(
                            var->var->path->name,
                            "const decorations in interfaces can not have a default value.");
                        break;
                    }
                }

                break;
            }
            case __AST_NODE::nodes::ConstDecl: {
                __AST_N::NodeT<__AST_NODE::ConstDecl> const_decl =
                    __AST_N::as<__AST_NODE::ConstDecl>(decl);
                for (auto &var : const_decl->vars) {
                    if (var->value != nullptr) {
                        CODEGEN_ERROR(
                            var->var->path->name,
                            "const decorations in interfaces can not have a default value.");
                        break;
                    }
                }
            }
            default: {
                CODEGEN_ERROR(self,
                              "'" + decl->getNodeName() +
                                  "' is not allowed in an interface, remove it.");
                return;
            }
        }
    }

    ADD_TOKEN(CXX_TEMPLATE);
    ADD_TOKEN(CXX_LESS);

    if (!node.generics->params->params.empty()) {
        for (auto &param : node.generics->params->params) {
            if (param->var->path->name.value() == "self") {
                ADD_TOKEN(CXX_TYPENAME);
                ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "self", param->var->path->name);
            } else {
                ADD_PARAM(param);
            }

            ADD_TOKEN(CXX_COMMA);
        }

        tokens.pop_back();
    }

    ADD_TOKEN(CXX_GREATER);
    ADD_TOKEN(CXX_CONCEPT);  // concept
    ADD_NODE_PARAM(name);    // FooInterface
    ADD_TOKEN(CXX_EQUAL);    // =

    if (node.generics->bounds) {
        for (auto &bound : node.generics->bounds->bounds) {
            ADD_PARAM(bound);
            ADD_TOKEN(CXX_LOGICAL_AND);
        }
    }

    ADD_TOKEN(CXX_REQUIRES);                                               // requires
    ADD_TOKEN(CXX_LPAREN);                                                 // (
    ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "self", self);          // self
    ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, self_parm_name, self);  // _$_<timestamp>

    if (!type_map.empty()) {
        ADD_TOKEN(CXX_COMMA);

        for (auto &[var, name] : type_map) {
            if (!is_self_t(var->get()->var->type)) {
                ADD_PARAM(var->get()->var->type);
            }

            ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, name, var->get()->var->path->name);
            ADD_TOKEN(CXX_COMMA);
        }

        tokens.pop_back();
    }

    ADD_TOKEN(CXX_RPAREN);
    ADD_TOKEN(CXX_LBRACE);

    /*
    interface Foo {
        fn bar() requires <T>;
    }

    { t.template foo<int>() } -> std::same_as<int>;

    */

    //    ADD_TOKEN(CXX_LBRACE);

    /// i need to figure out all the functions that are in the interface and then all the types of
    /// all the functions
    /*
    interface Foo requires U {
        fn foo(self, a: U) -> i32;
        fn bar(self, a: i32) -> i32;
        static fn baz(a: i32) -> i32;
        fn qux(self, _: *void) -> i32;

        type FLA requires U;

        let a: float;
        const b: f64;
    }

    codegen into --->

    template <typename self, typename U>
    concept Foo = requires(self t, U $U, i32 $i32, i32 $i32, *void $void) {
        { t.foo($U) } -> std::same_as<i32>;
        { t.bar($i32) } -> std::same_as<i32>;
        { self::baz($i32) } -> std::same_as<i32>;
        { t.qux($void) } -> std::same_as<i32>;

        { t.a } -> std::same_as<f64>;
        { t.b } -> std::same_as<f64>;

        typename self::FLA;
    };
    */

    /// this map contains the refrencs of args to their normalized names in the interface
    /// so for exmaple take the following interface:
    /// interface Foo requires U {
    ///     fn foo(self, a: U) -> i32;
    ///     fn bar(self, a: i32) -> i32;
    ///     static fn baz(a: i32) -> i32;
    /// }
    /// the map would look like:
    /// {
    ///     <mem-addr>(a: U) : _$_<timestamp>_,
    ///     <mem-addr>(a: i32) : _$_<timestamp>_,
    ///     <mem-addr>(a: i32) : _$_<timestamp>_
    /// }
    /// this is used to replace the args in the function with the normalized names so that the
    /// codegen would look like this:
    /// template <typename self, typename U>
    /// concept Foo = requires(self t, U _$_<timestamp>_, i32 _$_<timestamp>_, i32 _$_<timestamp>_)
    /// {
    ///     { t.foo(_$_<timestamp>_) } -> std::same_as<i32>;
    ///     { t.bar(_$_<timestamp>_) } -> std::same_as<i32>;
    ///     { self::baz(_$_<timestamp>_) } -> std::same_as<i32>;
    /// };

    /// at this stage validation is done, now we need to only focus on the codegen
    for (auto &decl : node.body->body->body) {
        switch (decl->getNodeType()) {
            case __AST_NODE::nodes::FuncDecl: {  // fn foo(self, a: U) -> i32;
                /// if static codegen: { self::foo(a) } -> std::same_as<i32>;
                /// if instance codegen: { self_parm_name.foo(a) } -> std::same_as<i32>;
                __AST_N::NodeT<__AST_NODE::FuncDecl> func_decl =
                    __AST_N::as<__AST_NODE::FuncDecl>(decl);

                auto [$self, $static] = contains_self_static(func_decl);

                ADD_TOKEN(CXX_LBRACE);  // {

                if ($self) {  // self_parm_name.
                    ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, self_parm_name);
                    ADD_TOKEN(CXX_DOT);
                } else {  // self::
                    ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, "self");
                    ADD_TOKEN(CXX_SCOPE_RESOLUTION);
                }

                ADD_PARAM(func_decl->name);  // foo
                ADD_TOKEN(CXX_LPAREN);       // (

                if (!func_decl->params.empty()) {
                    bool first = $self;

                    for (auto &param : func_decl->params) {
                        if (first) {
                            first = !first;
                            continue;
                        }

                        ADD_TOKEN_AS_VALUE_AT_LOC(
                            CXX_CORE_IDENTIFIER, type_map[&param], param->var->path->name);
                        ADD_TOKEN(CXX_COMMA);
                    }

                    // if there is self and the size of the params is 1, then we skip removing the
                    // comma
                    if (!$self || func_decl->params.size() != 1) {
                        tokens.pop_back();
                    }
                }

                ADD_TOKEN(CXX_RPAREN);  // )

                ADD_TOKEN(CXX_RBRACE);   // }
                ADD_TOKEN(CXX_PTR_ACC);  // ->
                ADD_TOKEN_AS_VALUE_AT_LOC(
                    CXX_CORE_IDENTIFIER, "std", func_decl->get_name_t().back());
                ADD_TOKEN(CXX_SCOPE_RESOLUTION);
                ADD_TOKEN_AS_VALUE_AT_LOC(
                    CXX_CORE_IDENTIFIER, "Meta", func_decl->get_name_t().back());
                ADD_TOKEN(CXX_SCOPE_RESOLUTION);
                ADD_TOKEN_AS_VALUE_AT_LOC(
                    CXX_CORE_IDENTIFIER, "is_same_as", func_decl->get_name_t().back());

                ADD_TOKEN(CXX_LESS_THAN);

                if (func_decl->returns) {
                    if (!is_self_t(func_decl->returns)) {
                        ADD_PARAM(func_decl->returns);
                    }
                } else {
                    ADD_TOKEN(CXX_VOID);
                }

                ADD_TOKEN(CXX_GREATER_THAN);
                ADD_TOKEN(CXX_SEMICOLON);

                break;
            }

            case __AST_NODE::nodes::OpDecl: {
                /// op + fn add(self, other: self) -> self;
                /// if static codegen:
                ///    { self::add(a, b) } -> std::same_as<self>;
                ///    { a + b } -> std::same_as<self>;
                /// if instance codegen:
                ///    { self_parm_name.add(b) } -> std::same_as<self>;
                ///    { self_parm_name + b } -> std::same_as<self>;

                /// heres is all the decls:
                /// unary (prefix):  op + fn add(self) -> self;
                /// unary (postfix): op r+ fn add(self) -> self;
                /// binary:          op + fn add(self, other: self) -> self;
                /// array:           op [] fn add(self, other: self) -> self;

                __AST_N::NodeT<__AST_NODE::OpDecl> op_decl = __AST_N::as<__AST_NODE::OpDecl>(decl);

                auto [$self, $static] = contains_self_static(op_decl);

                if (op_decl->func->name != nullptr) {  // first declaration
                    ADD_TOKEN(CXX_LBRACE);

                    if ($self) {
                        ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, self_parm_name);
                        ADD_TOKEN(CXX_DOT);
                    } else {
                        ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, "self");
                        ADD_TOKEN(CXX_SCOPE_RESOLUTION);
                    }

                    ADD_PARAM(op_decl->func->name);
                    ADD_TOKEN(CXX_LPAREN);

                    if (!op_decl->func->params.empty()) {
                        bool first = $self;

                        for (auto &param : op_decl->func->params) {
                            if (first) {
                                first = !first;
                                continue;
                            }

                            ADD_TOKEN_AS_VALUE_AT_LOC(
                                CXX_CORE_IDENTIFIER, type_map[&param], param->var->path->name);
                            ADD_TOKEN(CXX_COMMA);
                        }

                        if (!$self || op_decl->func->params.size() != 1) {
                            tokens.pop_back();
                        }
                    }

                    ADD_TOKEN(CXX_RPAREN);

                    ADD_TOKEN(CXX_RBRACE);
                    ADD_TOKEN(CXX_PTR_ACC);
                    ADD_TOKEN_AS_VALUE_AT_LOC(
                        CXX_CORE_IDENTIFIER, "std", op_decl->func->get_name_t().back());
                    ADD_TOKEN(CXX_SCOPE_RESOLUTION);
                    ADD_TOKEN_AS_VALUE_AT_LOC(
                        CXX_CORE_IDENTIFIER, "Meta", op_decl->func->get_name_t().back());
                    ADD_TOKEN(CXX_SCOPE_RESOLUTION);
                    ADD_TOKEN_AS_VALUE_AT_LOC(
                        CXX_CORE_IDENTIFIER, "is_convertible_to", op_decl->func->get_name_t().back());
                    ADD_TOKEN(CXX_LESS_THAN);

                    if (op_decl->func->returns) {
                        if (!is_self_t(op_decl->func->returns)) {
                            ADD_PARAM(op_decl->func->returns);
                        }
                    } else {
                        ADD_TOKEN(CXX_VOID);
                    }

                    ADD_TOKEN(CXX_GREATER_THAN);
                    ADD_TOKEN(CXX_SEMICOLON);
                }

                {  /// second declaration
                   /// for binary: `{a + b}` | `{self_parm_name + b}`
                   /// for unary: `{+a}` | `{self_parm_name}`
                    ADD_TOKEN(CXX_LBRACE);

                    /// identify if the op is a unary, binary or a array op
                    OperatorType op_type = determine_operator_type(op_decl);

                    if (op_type == OperatorType::None) {
                        if (op_decl->op.size() >= 1) {
                            CODEGEN_ERROR(op_decl->op.front(),
                                          "Invalid operator/parameters for operator overload");
                        } else {
                            CODEGEN_ERROR(op_decl->func->get_name_t().back(),
                                          "Invalid operator/parameters for operator overload");
                        }

                        break;
                    }

                    switch (op_type) {
                        case OperatorType::UnaryPrefix: {  /// codegen { +a } | { +self_name_param }
                            for (auto &tok : op_decl->op) {
                                ADD_TOKEN_AS_VALUE_AT_LOC(CXX_OPERATOR, tok.value(), tok);
                            }

                            if ($self) {
                                ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, self_parm_name);
                            } else {
                                ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER,
                                                   type_map[&op_decl->func->params.front()]);
                            }

                            break;
                        }
                        case OperatorType::UnaryPostfix: {
                            if ($self) {
                                ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, self_parm_name);
                            } else {
                                ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER,
                                                   type_map[&op_decl->func->params.front()]);
                            }

                            for (auto &tok : op_decl->op) {
                                if (tok == __TOKEN_N::OPERATOR_R_INC ||
                                    tok == __TOKEN_N::OPERATOR_R_DEC) {
                                    ADD_TOKEN_AS_VALUE_AT_LOC(
                                        CXX_OPERATOR,
                                        tok == __TOKEN_N::OPERATOR_R_INC ? "++" : "--",
                                        tok);
                                } else {
                                    ADD_TOKEN_AS_VALUE_AT_LOC(CXX_OPERATOR, tok.value(), tok);
                                }
                            }

                            break;
                        }
                        case OperatorType::Binary: {
                            if ($self) {
                                ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, self_parm_name);
                            } else {
                                ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER,
                                                   type_map[&op_decl->func->params.front()]);
                            }

                            for (auto &tok : op_decl->op) {
                                ADD_TOKEN_AS_VALUE_AT_LOC(CXX_OPERATOR, tok.value(), tok);
                            }

                            ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER,
                                               type_map[&op_decl->func->params.back()]);

                            break;
                        }
                        case OperatorType::Array:
                            if ($self) {
                                ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, self_parm_name);
                            } else {
                                ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER,
                                                   type_map[&op_decl->func->params.front()]);
                            }

                            ADD_TOKEN(CXX_LBRACKET);
                            ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER,
                                               type_map[&op_decl->func->params.back()]);
                            ADD_TOKEN(CXX_RBRACKET);

                            break;
                        case OperatorType::Call: {
                            if ($self) {
                                ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, self_parm_name);
                            } else {
                                ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER,
                                                   type_map[&op_decl->func->params.front()]);
                            }

                            ADD_TOKEN(CXX_LPAREN);

                            bool first = $self;

                            if (!op_decl->func->params.empty()) {
                                for (auto &param : op_decl->func->params) {
                                    if (first) {
                                        first = !first;
                                        continue;
                                    }

                                    ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER,
                                                              type_map[&param],
                                                              param->var->path->name);
                                    ADD_TOKEN(CXX_COMMA);
                                }

                                if (!$self || op_decl->func->params.size() != 1) {
                                    tokens.pop_back();
                                }
                            }

                            break;
                        }
                        case OperatorType::None: {
                            CODEGEN_ERROR(op_decl->op.front(),
                                          "Invalid operator/parameters for operator overload");
                            break;
                        }
                    }

                    ADD_TOKEN(CXX_RBRACE);
                    ADD_TOKEN(CXX_PTR_ACC);
                    ADD_TOKEN_AS_VALUE_AT_LOC(
                        CXX_CORE_IDENTIFIER, "std", op_decl->func->get_name_t().back());
                    ADD_TOKEN(CXX_SCOPE_RESOLUTION);
                    ADD_TOKEN_AS_VALUE_AT_LOC(
                        CXX_CORE_IDENTIFIER, "Meta", op_decl->func->get_name_t().back());
                    ADD_TOKEN(CXX_SCOPE_RESOLUTION);
                    ADD_TOKEN_AS_VALUE_AT_LOC(
                        CXX_CORE_IDENTIFIER, "is_convertible_to", op_decl->func->get_name_t().back());
                    ADD_TOKEN(CXX_LESS_THAN);

                    if (op_decl->func->returns) {
                        if (!is_self_t(op_decl->func->returns)) {
                            ADD_PARAM(op_decl->func->returns);
                        }
                    } else {
                        ADD_TOKEN(CXX_VOID);
                    }

                    ADD_TOKEN(CXX_GREATER_THAN);
                    ADD_TOKEN(CXX_SEMICOLON);
                }

                break;
            }

            case __AST_NODE::nodes::LetDecl: {  // let foo: i32;
                /// if static codegen: { self::foo } -> std::same_as<i32>;
                /// if instance codegen: { self_parm_name.foo } -> std::same_as<i32>;

                __AST_N::NodeT<__AST_NODE::LetDecl> let_decl =
                    __AST_N::as<__AST_NODE::LetDecl>(decl);

                for (auto &var : let_decl->vars) {
                    ADD_TOKEN(CXX_LBRACE);

                    if (let_decl->modifiers.contains(token::tokens::KEYWORD_STATIC)) {
                        ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, "self");
                        ADD_TOKEN(CXX_SCOPE_RESOLUTION);
                        ADD_PARAM(var->var->path);
                    } else {
                        ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, self_parm_name);
                        ADD_TOKEN(CXX_DOT);
                        ADD_PARAM(var->var->path);
                    }

                    ADD_TOKEN(CXX_RBRACE);
                    ADD_TOKEN(CXX_PTR_ACC);
                    ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "std", var->var->path->name);
                    ADD_TOKEN(CXX_SCOPE_RESOLUTION);
                    ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "Meta", var->var->path->name);
                    ADD_TOKEN(CXX_SCOPE_RESOLUTION);
                    ADD_TOKEN_AS_VALUE_AT_LOC(
                        CXX_CORE_IDENTIFIER, "is_convertible_to", var->var->path->name);
                    ADD_TOKEN(CXX_LESS_THAN);

                    if (var->var->type) {
                        if (!is_self_t(var->var->type)) {
                            ADD_PARAM(var->var->type);
                        }

                        /// now new check, since we are in an interface, we need to make sure that
                        /// the the checked var type has to be a reference type, so we add a `&` to
                        /// the type unless it is a reference type

                        // auto type = var->var->type;
                        // if (var->var->type->value != nullptr &&
                        //     !let_decl->modifiers.contains(token::tokens::KEYWORD_STATIC)) {

                        //     if (type->value->getNodeType() == __AST_NODE::nodes::IdentExpr) {
                        //         ADD_TOKEN(CXX_AMPERSAND);
                        //     } else if (type->value->getNodeType() ==
                        //     __AST_NODE::nodes::UnaryExpr) {
                        //         __AST_N::NodeT<__AST_NODE::UnaryExpr> unary =
                        //             __AST_N::as<__AST_NODE::UnaryExpr>(type->value);

                        //         if (unary->op == __TOKEN_N::OPERATOR_MUL) {
                        //             ADD_TOKEN(CXX_AMPERSAND);
                        //         }
                        //     }
                        // } else {
                        //     CODEGEN_ERROR(var->var->path->name,
                        //                   "bad type for variable declaration in interface");
                        // }
                    } else {
                        CODEGEN_ERROR(var->var->path->name,
                                      "variable declarations in interfaces must have a type.");
                        return;
                    }

                    ADD_TOKEN(CXX_GREATER_THAN);
                    ADD_TOKEN(CXX_SEMICOLON);
                }

                break;
            }

            case __AST_NODE::nodes::ConstDecl: {
                __AST_N::NodeT<__AST_NODE::ConstDecl> const_decl =
                    __AST_N::as<__AST_NODE::ConstDecl>(decl);

                for (auto &var : const_decl->vars) {
                    ADD_TOKEN(CXX_LBRACE);

                    if (const_decl->modifiers.contains(token::tokens::KEYWORD_STATIC)) {
                        ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, "self");
                        ADD_TOKEN(CXX_SCOPE_RESOLUTION);
                        ADD_PARAM(var->var->path);
                    } else {
                        ADD_TOKEN_AS_VALUE(CXX_CORE_IDENTIFIER, self_parm_name);
                        ADD_TOKEN(CXX_DOT);
                        ADD_PARAM(var->var->path);
                    }

                    ADD_TOKEN(CXX_RBRACE);
                    ADD_TOKEN(CXX_PTR_ACC);
                    ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "std", var->var->path->name);
                    ADD_TOKEN(CXX_SCOPE_RESOLUTION);
                    ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "Meta", var->var->path->name);
                    ADD_TOKEN(CXX_SCOPE_RESOLUTION);
                    ADD_TOKEN_AS_VALUE_AT_LOC(CXX_CORE_IDENTIFIER, "is_same_as", var->var->path->name);
                    ADD_TOKEN(CXX_LESS_THAN);

                    if (var->var->type) {
                        if (!is_self_t(var->var->type)) {
                            ADD_PARAM(var->var->type);
                        }
                    }

                    ADD_TOKEN(CXX_GREATER_THAN);
                    ADD_TOKEN(CXX_SEMICOLON);
                }

                break;
            }

            default: {
                CODEGEN_ERROR(self,
                              "'" + decl->getNodeName() +
                                  "' is not allowed in an interface, remove it.");
                return;
            }
        }
    }

    ADD_TOKEN(CXX_RBRACE);
    ADD_TOKEN(CXX_SEMICOLON);
}
