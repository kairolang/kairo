/// --- The Kairo Project ----------------------- AST/Mixin/FFILinkage.k --- ///
///
///   CRTP mixin for declarations that may carry foreign-language linkage.
///   Mirrors VisibilityAnnotation in shape: a small enum + source range,
///   defaulting to None (no FFI). Only set by the parser's _parse_ffi path.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// -------------------------------------------------------------------- ///

import Location::SourceRange::*;
import Token::Token::*;

enum LinkageKind derives u8 {
    None = 0,  ///< No FFI linkage. Default Kairo linkage.
    C,         ///< ffi "c"  , no mangling.
    Cpp,       ///< ffi "c++", Itanium/MSVC mangling.
}

/// CRTP mixin: Decl nodes derive FFILinkage::<SelfType> to get inline
/// foreign-linkage storage and the query/mutation API.
///
/// `None` means no `ffi` keyword was written, the vast majority of decls.
/// The mixin adds only 2 bytes (enum) + a SourceRange + a Token to each
/// Decl that derives it. If you want zero cost on non-FFI decls, derive
/// this only on the node types that can legally appear in FFI context
/// (FunctionDecl, ClassDecl, StructDecl, TypeAliasDecl, etc.) rather
/// than on Decl base.
class <T> FFILinkage {
    pub var ffi_linkage:        LinkageKind = LinkageKind::None;
    pub var _ffi_linkage_range: SourceRange = SourceRange::invalid();
    pub var _ffi_lang_token:    Token;  ///< the string literal token ("c"/"c++")

    // --- Queries --------------------------------------------------------

    const fn has_ffi_linkage(self) -> bool {
        return self.ffi_linkage != LinkageKind::None;
    }

    const fn is_ffi_c(self) -> bool {
        return self.ffi_linkage == LinkageKind::C;
    }

    const fn is_ffi_cpp(self) -> bool {
        return self.ffi_linkage == LinkageKind::Cpp;
    }

    const fn ffi_linkage_range(self) -> SourceRange {
        return self._ffi_linkage_range;
    }

    const fn ffi_lang_token(self) -> Token {
        return self._ffi_lang_token;
    }

    // --- Mutation -------------------------------------------------------

    fn set_ffi_linkage(self, kind: LinkageKind, lang_tok: Token, range: SourceRange) {
        self.ffi_linkage        = kind;
        self._ffi_lang_token    = lang_tok;
        self._ffi_linkage_range = range;
    }

    fn clear_ffi_linkage(self) {
        self.ffi_linkage        = LinkageKind::None;
        self._ffi_linkage_range = SourceRange::invalid();
    }
}