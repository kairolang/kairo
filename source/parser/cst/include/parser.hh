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