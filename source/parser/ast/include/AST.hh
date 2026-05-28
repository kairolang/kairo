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

#ifndef __AST_H__
#define __AST_H__

#include "parser/ast/include/config/AST_config.def"
#include "parser/ast/include/nodes/AST_declarations.hh"
#include "parser/ast/include/nodes/AST_expressions.hh"
#include "parser/ast/include/nodes/AST_statements.hh"
#include "parser/ast/include/private/AST_classifier.hh"
#include "parser/ast/include/private/AST_context.hh"
#include "parser/ast/include/private/AST_generate.hh"
#include "parser/ast/include/private/AST_matcher.hh"
#include "parser/ast/include/private/AST_nodes.hh"
#include "parser/ast/include/private/base/AST_base.hh"
#include "parser/ast/include/types/AST_jsonify_visitor.hh"
#include "parser/ast/include/types/AST_modifiers.hh"
#include "parser/ast/include/types/AST_types.hh"
#include "parser/ast/include/types/AST_visitor.hh"

#endif  // __AST_H__