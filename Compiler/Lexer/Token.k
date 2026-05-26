/// --- The Kairo Project ----------------------------------- <filename> --- ///
///
///   <short description>
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://kairo-lang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Kairo Software Foundation
///
/// ------------------------------------------------------------------------ ///

import Source::SourceRange::*;
import TokenKind::*;

/// size = 16 bytes on 64-bit
///      sizeof(kind)   = 32 bits
///      sizeof(range)  = 64 bits </ (start: 32 bits, end: 32 bits)
///      sizeof(imm)    = 32 bits
///      alignof(Token) = 4 bytes
///      total          = 16 bytes + 0 bytes padding
///
/// on 32-bit alignment is 4 bytes, total size is still 16 bytes
class Token { // size=16B, align=4
    pub var range: SourceRange = SourceRange();          ///< source location range
    pub var kind:  TokenKind   = TokenKind::TkUnknown;   ///< token kind
    pub var imm:   u32         = -1;                     ///< immediate value index in ImmediateTable, or -1 if none

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

    fn Token(self) {
        self.kind  = TokenKind::TkUnknown;
        self.range = SourceRange();
        self.imm   = u32(-1);
    }

    fn Token(self, range: SourceRange, kind: TokenKind = TokenKind::TkUnknown, imm: u32 = -1) {
        self.kind  = kind;
        self.range = range;
        self.imm   = imm;
    }

    const fn op == (self, other: Token) -> bool {
        return (self.kind == other.kind) && (self.range == other.range) && (self.imm == other.imm);
    }

    const fn op != (self, other: Token) -> bool {
        return !(self == other);
    }

    const fn op == (self, other: TokenKind) -> bool {
        return self.kind == other;
    }

    const fn op != (self, other: TokenKind) -> bool {
        return self.kind != other;
    }

    fn op = (self, new: TokenKind) -> ref!(Token) {
        self.kind = new;
        return self;
    }

    fn op = (self, new: SourceRange) -> ref!(Token) {
        self.range = new;
        return self;
    }

    fn op = (self, new: u32) -> ref!(Token) {
        self.imm = new;
        return self;
    }

    fn op == (self, kinds: set::<TokenKind>) -> bool {
        return kinds.contains(self.kind);
    }

    fn op != (self, kinds: set::<TokenKind>) -> bool {
        return !(kinds.contains(self.kind));
    }

    fn op == (self, kinds: vec::<TokenKind>) -> bool {
        for kind in kinds {
            if self.kind == kind {
                return true;
            }
        }
        return false;
    }

    fn op != (self, kinds: vec::<TokenKind>) -> bool {
        return !(self == kinds);
    }

    fn op == (self, const typ: Type) -> bool {
        switch (typ) {
            case Type::Annotation {
                return is_annotation(self.kind);
            } case Type::Keyword {
                return is_keyword(self.kind);
            } case Type::UnaryOperator {
                return is_unary_operator(self.kind);
            } case Type::BinaryOperator {
                return is_binary_operator(self.kind);
            } case Type::AssignmentOperator {
                return is_assignment_operator(self.kind);
            } case Type::Punctuator {
                return is_punctuator(self.kind);
            } case Type::Operator {
                return is_operator(self.kind);
            } case Type::Builtin {
                return is_builtin(self.kind);
            } case Type::Special {
                return is_special(self.kind);
            } case Type::Internal {
                return is_internal(self.kind);
            } case Type::Literal {
                return is_literal(self.kind);
            } case Type::Substitutable {
                return is_substitutable(self.kind);
            } case Type::Eof {
                return self.kind == TokenKind::TkEof;
            } case Type::Unknown {
                return self.kind == TokenKind::TkUnknown;
            }
        }
    }

    fn op != (self, const typ: Type) -> bool {
        return !(self == typ);
    }

    const fn op as (self) -> string {
        return f"Token(kind: '{token_kind_to_string(self.kind)}', kind[hash]: 0x{to_hex_string(static_cast::<u32>(self.kind))}, range: {self.range}, imm: 0x{to_hex_string((self.imm) as u64)})";
    }

    fn has_imm(self) -> bool {
        return self.imm != u32(-1);
    }

    fn is_valid(self) -> bool {
        return self.kind != TokenKind::TkUnknown;
    }

    fn is_eof(self) -> bool {
        return self.kind == TokenKind::TkEof;
    }

    fn is_error(self) -> bool {
        return self.kind == TokenKind::TkError;
    }

    fn error_expected_kind(self) -> TokenKind {
        return static_cast::<TokenKind>(self.imm);
    }

    fn start_loc(self) -> SourceLocation {
        return self.range.start;
    }

    fn end_loc(self) -> SourceLocation {
        return self.range.end;
    }

    fn readable_kind(self) -> string {
        return token_kind_to_readable_string(self.kind);
    }
} //Token end