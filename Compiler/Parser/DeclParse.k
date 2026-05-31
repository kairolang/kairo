/// --- The Kairo Project ------------------ Compiler/Parser/DeclParse.k ----- ///
///
///   \brief Declaration parsing mixin. Handles module-level and type scopes.
///
///   \detail
///     Entry point: parse_decl() -> main dispatch for top-level declarations.
///     Handles nominal types (class, struct, enum, interface), functions/methods,
///     type aliases, and structural module imports. Includes local synchronization 
///     recovery loops for malformed declaration blocks.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the Kairo
///   Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------- ///

import ASTNode::Base::*;
import ASTNode::Declarations::*;
import ASTNode::Types::*;
import AST::ASTContext::*;
import Diag::DiagEngine::*;
import Diag::DiagRegistry::*;
import Source::SourceRange::*;
import Lexer::Token::*;
import TokenKind::*;

class <T> DeclParse {

    // ========================================================================
    //  CRTP helper & Error Factories
    // ========================================================================

    priv inline fn dyn(self) -> *T {
        return static_cast::<*T>(&self);
    }

    fn parse_decl(self) -> *Decl {
        return &null;
    }
}