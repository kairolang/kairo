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

#ifndef __PARSER_HH__
#define __PARSER_HH__

#include <iostream>
#include <memory>

#include "parser/cst/include/cst.hh"
#include "parser/cst/include/nodes.hh"
#include "token/include/Token.hh"

namespace parser {
class CSTParser {
    explicit CSTParser(__TOKEN_N::TokenList tokens);
};
}  // namespace parser

#endif  // __PARSER_HH__