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