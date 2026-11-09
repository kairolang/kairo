/// --- The Kairo Project -------------------------------- Token/Token.k --- ///
///
///   Token: a 16-byte token: its kind, source range and payload index.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "set"
ffi "c++" import "vector"

import Location::SourceLocation::SourceLocation
import Location::SourceRange::SourceRange
import Support::EvalHash::to_hex_string
import Token::TokenKind::{
    TokenKind,
    is_annotation,
    is_assignment_operator,
    is_binary_operator,
    is_builtin,
    is_internal,
    is_keyword,
    is_literal,
    is_operator,
    is_punctuator,
    is_special,
    is_substitutable,
    is_unary_operator,
    token_kind_to_readable_string,
    token_kind_to_string,
}

/// size = 16 bytes on 64-bit
///      sizeof(kind)   = 32 bits
///      sizeof(range)  = 64 bits </ (start: 32 bits, end: 32 bits)
///      sizeof(imm)    = 32 bits
///      alignof(Token) = 4 bytes
///      total          = 16 bytes + 0 bytes padding
///
/// on 32-bit alignment is 4 bytes, total size is still 16 bytes
pub class Token { // size=16B, align=4
    pub var range: SourceRange = SourceRange() ///< source location range
    pub var kind:  TokenKind   = TokenKind::TkUnknown ///< token kind
    pub var imm:   u32         = u32::MAX ///< immediate value index in ImmediateTable, or -1 if none

    enum Type {
        Annotation,
        Keyword,
        UnaryOperator,
        BinaryOperator,
        AssignmentOperator,
        Punctuator,
        Operator,
        Builtin,
        Special,
        Internal,
        Literal,
        Substitutable,
        Eof,
        Unknown,
    }

    pub fn Token(self) {
        self.kind  = TokenKind::TkUnknown
        self.range = SourceRange()
        self.imm   = u32::MAX
    }

    pub fn Token(self,
                 range: SourceRange,
                 kind:  TokenKind = TokenKind::TkUnknown,
                 imm:   u32 = u32::MAX) {
        self.kind  = kind
        self.range = range
        self.imm   = imm
    }

    fn op == (const self, other: Token) -> bool {
        return self.kind == other.kind && self.range == other.range && self.imm == other.imm
    }

    fn op != (const self, other: Token) -> bool {
        return !(self == other)
    }

    pub fn op == (const self, other: TokenKind) -> bool {
        return self.kind == other
    }

    pub fn op != (const self, other: TokenKind) -> bool {
        return self.kind != other
    }

    pub fn set_kind(self, value: TokenKind) {
        self.kind = value
    }

    pub fn set_range(self, value: SourceRange) {
        self.range = value
    }

    pub fn set_imm(self, value: u32) {
        self.imm = value
    }

    fn op == (self, kinds: cxx::std::set<TokenKind>) -> bool {
        return kinds.contains(self.kind)
    }

    fn op != (self, kinds: cxx::std::set<TokenKind>) -> bool {
        return !kinds.contains(self.kind)
    }

    fn op == (self, kinds: cxx::std::vector<TokenKind>) -> bool {
        for kind in kinds {
            if self.kind == kind {
                return true
            }
        }

        return false
    }

    fn op != (self, kinds: cxx::std::vector<TokenKind>) -> bool {
        return !(self == kinds)
    }

    fn op == (self, const typ: Self::Type) -> bool {
        match typ {
            case Self::Type::Annotation {
                return is_annotation(self.kind)
            } case Self::Type::Keyword {
                return is_keyword(self.kind)
            } case Self::Type::UnaryOperator {
                return is_unary_operator(self.kind)
            } case Self::Type::BinaryOperator {
                return is_binary_operator(self.kind)
            } case Self::Type::AssignmentOperator {
                return is_assignment_operator(self.kind)
            } case Self::Type::Punctuator {
                return is_punctuator(self.kind)
            } case Self::Type::Operator {
                return is_operator(self.kind)
            } case Self::Type::Builtin {
                return is_builtin(self.kind)
            } case Self::Type::Special {
                return is_special(self.kind)
            } case Self::Type::Internal {
                return is_internal(self.kind)
            } case Self::Type::Literal {
                return is_literal(self.kind)
            } case Self::Type::Substitutable {
                return is_substitutable(self.kind)
            } case Self::Type::Eof {
                return self.kind == TokenKind::TkEof
            } case Self::Type::Unknown {
                return self.kind == TokenKind::TkUnknown
            }
        }
    }

    fn op != (self, const typ: Self::Type) -> bool {
        return !(self == typ)
    }

    pub fn op as (const self) -> string {
        return f"Token(kind: '{token_kind_to_string(self.kind)}', kind[hash]: 0x{to_hex_string((((self.kind as u32)) as usize))}, range: {self.range}, imm: 0x{to_hex_string((((self.imm) as u64) as usize))})"
    }

    pub fn has_imm(self) -> bool {
        return self.imm != u32::MAX
    }

    fn is_valid(self) -> bool {
        return self.kind != TokenKind::TkUnknown
    }

    fn is_eof(self) -> bool {
        return self.kind == TokenKind::TkEof
    }

    fn is_error(self) -> bool {
        return self.kind == TokenKind::TkError
    }

    fn error_expected_kind(self) -> TokenKind {
        return self.imm as TokenKind
    }

    fn start_loc(self) -> SourceLocation {
        return self.range.start
    }

    fn end_loc(self) -> SourceLocation {
        return self.range.end
    }

    fn readable_kind(self) -> string {
        return token_kind_to_readable_string(self.kind)
    }
}
