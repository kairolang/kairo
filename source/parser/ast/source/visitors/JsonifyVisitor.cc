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

#include "neo-json/include/json.hh"
#include "parser/ast/include/config/AST_config.def"
#include "parser/ast/include/private/base/AST_base.hh"
#include "parser/ast/include/types/AST_jsonify_visitor.hh"

__AST_VISITOR_BEGIN {
    void Jsonify::visit(parser ::ast ::node ::Program & node) {
        neo::json children("children");
        neo::json annotations("annotations");

        for (const auto &child : node.children) {
            children.add(get_node_json(child));
        }

        for (const auto &annotation : node.annotations) {
            annotations.add(get_node_json(annotation));
        }

        json.section("Program")
            .add("children", children);
    }

}  // namespace __AST_BEGIN
