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

#ifndef __AST_JSONIFY_VISIT_H__
#define __AST_JSONIFY_VISIT_H__

#include "neo-json/include/json.hh"
#include "parser/ast/include/config/AST_config.def"
#include "parser/ast/include/nodes/AST_nodes.hh"
#include "parser/ast/include/types/AST_types.hh"
#include "parser/ast/include/types/AST_visitor.hh"

__AST_VISITOR_BEGIN {
    class Jsonify : public Visitor {
      public:
        Jsonify()                           = default;
        Jsonify(const Jsonify &)            = default;
        Jsonify(Jsonify &&)                 = delete;
        Jsonify &operator=(const Jsonify &) = default;
        Jsonify &operator=(Jsonify &&)      = delete;
        ~Jsonify() override                 = default;

        neo::json json{"ast"};

        GENERATE_VISIT_EXTENDS;
    };

    inline neo::json get_node_json(const NodeT<> &node) {
        auto visitor = Jsonify();

        if (node == nullptr) {
            return neo::json("nullptr");
        }

        node->accept(visitor);
        return visitor.json;
    }
}  // namespace __AST_BEGIN

#endif  // __AST_JSONIFY_VISIT_H__