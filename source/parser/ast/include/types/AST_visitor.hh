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

#ifndef __AST_VISITOR_H__
#define __AST_VISITOR_H__

#include "parser/ast/include/private/AST_generate.hh"

__AST_NODE_BEGIN { class Program; }

__AST_VISITOR_BEGIN {
    class Visitor {
      public:
        Visitor()                           = default;
        Visitor(const Visitor &)            = default;
        Visitor &operator=(const Visitor &) = default;
        Visitor(Visitor &&)                 = default;
        Visitor &operator=(Visitor &&)      = default;
        virtual ~Visitor()                  = default;

        GENERATE_VISIT_FUNCS;
    };
}

#endif  // __AST_VISITOR_H__