/// --- The Kairo Project ---------------------------- Token/TokenSpan.k --- ///
///
///   TokenSpan: a read-only window over a range of a TokenBuffer.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// read-only span over a TokenBuffer only allows lexed tokens to be span'ed not string parsed tokens since they are 64-bound buffers
import Token::Token::Token
import Token::TokenBuffer::TokenBuffer

pub class TokenSpan {
    var _buffer: unsafe *TokenBuffer<512>
    var _flat:   unsafe *Token            = &null // Supports flattened tokens for f-string exprs
    var _start:  usize
    var _length: usize

    fn TokenSpan(self) {
        self._buffer = &null
        self._flat   = &null
        self._start  = 0
        self._length = 0
    }

    /// Standard constructor for the main Lexer buffer
    pub fn TokenSpan(self, buffer: unsafe *TokenBuffer<512>, start: usize, length: usize) {
        self._buffer = buffer
        self._flat   = &null
        self._start  = start
        self._length = length
    }

    pub fn TokenSpan(self, buff: unsafe *TokenBuffer<512>) {
        self._buffer = buff
        self._flat   = &null
        self._start  = 0
        self._length = buff->size()
    }

    /// Used for f-string exprs
    fn TokenSpan(self, flat_array: unsafe *Token, length: usize) {
        self._buffer = &null
        self._flat   = flat_array
        self._start  = 0
        self._length = length
    }

    pub fn size(self) -> usize {
        return self._length
    }

    pub fn get(self, index: usize) -> unsafe *Token {
        if index >= self._length {
            return &null
        }

        // If we have a standard 512 buffer, use chunked indexing
        if self._buffer != &null {
            return self._buffer->get(self._start + index)
        }

        // Otherwise, use flat array indexing
        return unsafe &self._flat[self._start + index]
    }

    /// WARNING: This may return null if the span is in flat mode.
    fn tokens(self) -> unsafe *TokenBuffer<512> {
        return self._buffer
    }

    fn op [] (self, index: usize) -> Token {
        var unsafe *token_ptr = self.get(index)
        if token_ptr == &null {
            return Token()
        }

        return *token_ptr
    }
}
