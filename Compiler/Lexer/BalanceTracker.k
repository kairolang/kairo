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

import Include::Base::*;
import Lexer::Token::*;
import Lexer::TokenBuffer::*;

class BalanceTracker {
    

    struct Entry {
        var kind:     TokenKind; // 32
        var loc:      SourceLocation; // 32
        var is_macro: bool; // 1
    }
    
    enum BalanceErrorKind derives u8 {
        Unclosed,
        Unexpected,
        Mismatched
    }
    
    struct BalanceError {
        var loc      : SourceLocation;
        var open_loc : SourceLocation;
        var expected : TokenKind;
        var found    : TokenKind;
        var kind     : BalanceErrorKind;
        var is_macro : bool;
    }
    
    var stack           : std::Memory::buffer::<Entry, 512>; // static const and initialized in class is not supported in stage(0)
    pub var errors      : libcxx::deque::<BalanceError>;
    var stack_size      : usize = 0;
    const MAX_STACK_SIZE: usize = 512;
    
    inline fn push(self, kind: TokenKind, loc: SourceLocation, is_macro: bool = false) {
        if self.stack_size < MAX_STACK_SIZE {
            self.stack[self.stack_size] = Entry{
                kind: kind,
                loc: loc,
                is_macro: is_macro
            };
            ++self.stack_size;
        } else {
            // overflow = unrecoverable nesting
            self.errors.push_back(BalanceError{
                loc: loc,
                open_loc: loc,
                expected: TokenKind::TkUnknown,
                found: TokenKind::TkUnknown,
                kind: BalanceErrorKind::Unclosed,
                is_macro: is_macro
            });
        }
    }

    /// Returns recovery tokens that should be appended BEFORE the closer
    /// we never balance check fstring exprs since thats the parser job entirely
    inline fn pop(self, closer: TokenKind, loc: SourceLocation, buff: *TokenBuffer::<512>) {
        if self.stack_size == 0 {
            self.errors.push_back(BalanceError{
                loc: loc,
                open_loc: SourceLocation(),
                expected: TokenKind::TkUnknown,
                found: closer,
                kind: BalanceErrorKind::Unexpected,
                is_macro: false
            });
            return;
        }

        var top = self.stack[self.stack_size - 1];
        var expected = BalanceTracker::get_closer(top.kind);

        if expected == closer {
            --self.stack_size;
            return;
        }

        // Find matching opener in stack (limit search depth to 8)
        var matching_opener = BalanceTracker::get_opener(closer);
        var found_index: isize = -1;

        for var i: isize = static_cast::<isize>(self.stack_size) - 1;
            i >= 0 && (static_cast::<usize>(self.stack_size - 1 - i) <= 8);
            --i {

            if self.stack[static_cast::<usize>(i)].kind == matching_opener {
                found_index = i;
                break;
            }
        }

        if found_index >= 0 {
            // Emit synthetic closers for everything between found_index and top
            // Go top-down (innermost first)
            for var i: isize = static_cast::<isize>(self.stack_size) - 1;
                i > found_index;
                --i {

                var unclosed = self.stack[static_cast::<usize>(i)];
                var unclosed_closer = BalanceTracker::get_closer(unclosed.kind);

                self.errors.push_back(BalanceError{
                    loc: loc,
                    open_loc: unclosed.loc,
                    expected: unclosed_closer,
                    found: TokenKind::TkUnknown,
                    kind: BalanceErrorKind::Unclosed,
                    is_macro: unclosed.is_macro
                });

                buff->append(Token(
                    SourceRange::single(loc),
                    TokenKind::TkError,
                    static_cast::<u32>(unclosed_closer)
                ));
            }

            // Consume everything including the matching opener
            self.stack_size = static_cast::<usize>(found_index);
        } else {
            // No matching opener found true mismatch
            self.errors.push_back(BalanceError{
                loc: loc,
                open_loc: top.loc,
                expected: expected,
                found: closer,
                kind: BalanceErrorKind::Mismatched,
                is_macro: top.is_macro
            });

            // Emit synthetic closer for top, then pop it
            buff->append(Token(
                SourceRange::single(loc),
                TokenKind::TkError,
                static_cast::<u32>(expected)
            ));

            --self.stack_size;
        }

        return;
    }

    /// Appends recovery tokens for all unclosed openers at EOF
    inline fn finalize(self, tokens: *TokenBuffer::<512>, eof_loc: SourceLocation) {
        while self.stack_size > 0 {
            var top = self.stack[self.stack_size - 1];
            var expected = BalanceTracker::get_closer(top.kind);

            self.errors.push_back(BalanceError{
                loc: eof_loc,
                open_loc: top.loc,
                expected: expected,
                found: TokenKind::TkUnknown,
                kind: BalanceErrorKind::Unclosed,
                is_macro: top.is_macro
            });

            tokens->append(Token(
                SourceRange::single(eof_loc),
                TokenKind::TkError,
                static_cast::<u32>(expected)
            ));

            --self.stack_size;
        }
    }

    static fn get_opener(closer: TokenKind) -> TokenKind {
        switch closer {
            case TokenKind::OpRBrace  { return TokenKind::OpLBrace;  }
            case TokenKind::OpRParen  { return TokenKind::OpLParen;  }
            case TokenKind::OpRSquare { return TokenKind::OpLSquare; }
            default { return TokenKind::TkUnknown; }
        }
    }
    
    inline static fn get_closer(opener: TokenKind) -> TokenKind {
        switch opener {
            case TokenKind::OpLBrace  { return TokenKind::OpRBrace;  }
            case TokenKind::OpLParen  { return TokenKind::OpRParen;  }
            case TokenKind::OpLSquare { return TokenKind::OpRSquare; }
            default { return TokenKind::TkUnknown; }
        }
    }
    
    inline static fn is_opener(kind: TokenKind) -> bool {
        return (kind == TokenKind::OpLBrace)
            || (kind == TokenKind::OpLParen)
            || (kind == TokenKind::OpLSquare);
    }
    
    inline static fn is_closer(kind: TokenKind) -> bool {
        return (kind == TokenKind::OpRBrace)
            || (kind == TokenKind::OpRParen)
            || (kind == TokenKind::OpRSquare);
    }
    
    fn has_errors(self) -> bool {
        return !self.errors.empty();
    }
    
    inline fn clear(self) {
        self.stack_size = 0;
        self.errors.clear();
    }
}
