//===------------------------------------------ C++ ------------------------------------------====//
//                                                                                                //
//  Part of the Kairo Project, under the Attribution 4.0 International license (CC BY 4.0). You   //
//  are allowed to use, modify, redistribute, and create derivative works, even for commercial    //
//  purposes, provided that you give appropriate credit, and indicate if changes were made.       //
//  For more information, please visit: https://creativecommons.org/licenses/by/4.0/              //
//                                                                                                //
//  SPDX-License-Identifier: Apache-2.0                                                           //
//  Copyright (c) 2024 (CC BY 4.0)                                                                //
//                                                                                                //
///====--------------------------------------------------------------------------------------====///
///                                                                                              ///
///  @file AST_types.hh                                                                          ///
///  @brief Defines common types for Abstract Syntax Tree (AST) nodes used throughout the Kairo  ///
///         project. This includes types for nodes, parse results, and helpers for creating AST  ///
///         nodes.                                                                               ///
///                                                                                              ///
///  This file provides types and helper functions used in the construction and management of    ///
///     AST nodes within the Kairo parser. It defines `NodeT`, a template for handling AST       ///
///     nodes, `ParseResult`, for handling parsing results (either a node or an error), and      ///
///     `NodeV`, a vector of AST nodes. Additionally, a `make_node` function is provided for     ///
///     creating new AST nodes with perfect forwarding of arguments.                             ///
///                                                                                              ///
///  @code                                                                                       ///
///  NodeT<ast::node::Type> node = make_node<ast::node::Type>(token, type);                      ///
///  NodeV<> nodes = {node};                                                                     ///
///  @endcode                                                                                    ///
///                                                                                              ///
///===---------------------------------------------------------------------------------------====///

#ifndef __AST_TYPES_H__
#define __AST_TYPES_H__

#include <expected>
#include <memory>
#include <vector>

#include "parser/ast/include/config/AST_config.def"
#include "parser/ast/include/types/AST_parse_error.hh"
#include "token/include/Token.hh"

__AST_NODE_BEGIN {
    class Node;
    class Declaration;
    class Expression;
    class Statement;
    class Annotation;
    class Program;
}  // namespace __AST_NODE

__AST_BEGIN {
    template <typename T>
    concept DerivedFromNode = std::is_base_of_v<__AST_NODE::Node, T>;

    /// NodeT is a unique pointer to a T (where T is a AST node)
    template <typename T = __AST_NODE::Node>
    using NodeT = std::shared_ptr<T>;

    template <typename T = __AST_NODE::Node>  // either a node or a parse error
    using ParseResult = std::expected<NodeT<T>, ParseError>;

    /// NodeV is a vector of NodeT
    template <typename T = __AST_NODE::Node>
    using NodeV = std::vector<NodeT<T>>;

    template <class T, class U>
    inline NodeT<T> as(const NodeT<U> &ptr) noexcept {
        return NodeT<T>(ptr, static_cast<typename NodeT<T>::element_type *>(ptr.get()));
    }

    template <class T = __AST_NODE::Node, class U>
    inline NodeT<T> as(NodeT<U> && ptr) noexcept {
        return NodeT<T>(std::move(ptr), static_cast<typename NodeT<T>::element_type *>(ptr.get()));
    }

    template <class T = __AST_NODE::Node, class U>
    inline NodeV<T> as(NodeV<U> &&vec) noexcept {
        NodeV<T> result;
        result.reserve(vec.size());

        for (auto &&ptr : vec) {
            result.push_back(as<T>(std::move(ptr)));
        }

        return result;
    }

    template <class T = __AST_NODE::Node, class U>
    inline NodeV<T> as(const NodeV<U> &vec) noexcept {
        NodeV<T> result;
        result.reserve(vec.size());
        for (const auto &ptr : vec) {
            result.push_back(as<T>(std::shared_ptr<U>(ptr)));
        }
        return result;
    }

    /// make_node is a helper function to create a new node with perfect forwarding
    /// @tparam T is the type of the node
    /// @param args are the arguments to pass to the constructor of T
    /// @return a unique pointer to the new node
    template <typename T, typename... Args>
    inline constexpr NodeT<T> make_node(Args && ...args) {
        // return a heap-alloc unique pointer to the new node with
        // perfect forwarding of the arguments allowing the caller
        // to identify any errors in the arguments at compile time
        return std::make_shared<T>(std::forward<Args>(args)...);
    }
}  // namespace __AST_BEGIN

#endif  // __AST_TYPES_H__