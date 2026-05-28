/// --- The Kairo Project -------------------------------------------------- ///
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

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
