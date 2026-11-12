/// --- The Kairo Project -------------------------- Token/TokenBuffer.k --- ///
///
///   TokenBuffer: a chunked, arena-backed append-only array of Tokens.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "utility"
ffi "c++" import "cstring"

import Memory::ArenaAllocator::ArenaAllocator
import Token::Token::Token
import Token::TokenKind::{
    TokenKind,
    token_kind_to_readable_string,
}
import std::io

pub class <eval CHUNK_SIZE: usize> TokenBuffer {
    type TokenPtr  = unsafe *Token
    type ChunkBuff = unsafe *Self::Chunk

    /// we allocate tokens in chunks of CHUNK_SIZE tokens then store the base
    /// pointer and the data. this allows us to avoid moving tokens around
    /// when we need to grow the buffer. while still allowing for contiguous
    /// storage of tokens in the base (offset by base). lets say we want
    /// token at index 600, we can find it at:
    /// chunk_index  = 600 / CHUNK_SIZE = 1
    /// offset_index = 600 % CHUNK_SIZE = 88
    /// token_ptr    = chunks[chunk_index].base + offset_index
    /// this allows a O(1) access time to any token in the buffer.
    /// while still allowing for efficient appending of tokens.
    struct Chunk {
        var base:     TokenPtr
        var capacity: usize
        var length:   usize
    }

    /// Three counters, and the distinction between them is load-bearing:
    ///
    ///   _chunk_count     chunks currently IN USE. append targets
    ///                    _chunks[_chunk_count - 1], and get()/operator[]/
    ///                    iteration all assume every chunk below the last one
    ///                    is exactly full, so this is what pop_back walks back.
    ///   _chunk_alloced   chunks whose `base` has been allocated. High-water
    ///                    mark, only ever grows. Chunks between _chunk_count
    ///                    and _chunk_alloced were retired by pop_back and are
    ///                    reused by grow() instead of being re-allocated -
    ///                    ArenaAllocator is a bump allocator with no
    ///                    per-allocation reclaim, so dropping one leaked
    ///                    CHUNK_SIZE tokens for the buffer's lifetime.
    ///   _chunk_capacity  entries the _chunks table itself can hold. Doubles.
    ///
    /// Invariant: _chunk_count <= _chunk_alloced <= _chunk_capacity.
    var _allocator: ArenaAllocator = ArenaAllocator(
        2048 * sizeof (Self::TokenPtr),
    )

    var _chunks:         Self::ChunkBuff = &null // array of chunk descriptors
    var _chunk_count:    usize           = 0     // chunks in use
    var _chunk_alloced:  usize           = 0     // chunks with a live base
    var _chunk_capacity: usize           = 0     // entries the table can hold
    var _total_length:   usize           = 0     // number of tokens in all chunks

    // Move-only. A copy would share _chunks with the source and leave both
    // pointing into one arena. Prefix `delete fn` and `op =` are the
    // spellings Kairo accepts (see OwnedUnit in Tooling/ParseAPI.k). The
    // source of a move is left empty, so its destroy() frees nothing it no
    // longer owns.

    @move fn TokenBuffer(self, other: Self) {
        self._allocator      = cxx::std::move(other._allocator)
        self._chunks         = other._chunks
        self._chunk_count    = other._chunk_count
        self._chunk_alloced  = other._chunk_alloced
        self._chunk_capacity = other._chunk_capacity
        self._total_length   = other._total_length

        other._chunks         = &null
        other._chunk_count    = 0
        other._chunk_alloced  = 0
        other._chunk_capacity = 0
        other._total_length   = 0
    }


    fn TokenBuffer(self) = default

    fn emit_errors(const self) {
        for var i: usize = 0; i < self._total_length; ++i {
            var unsafe *token = self.get(i)

            if token == &null {
                continue
            }

            if *token == TokenKind::TkError {
                // FIXME: this should be handled by the DiagEngine and not here
                io::println(
                    f"Invalid token found at {token->range} expected a valid '{token_kind_to_readable_string((token->imm as TokenKind))}' token\n",
                )
            }
        }
    }

    /// \brief makes one more chunk available to append.
    ///
    /// \details The table grows by DOUBLING. Re-allocating one entry larger
    ///          per chunk and copying the old contents across is O(n^2) bytes
    ///          against an allocator that never reclaims: every superseded
    ///          table would stay resident until destroy(). Lexing this
    ///          repo's Lexer.k (~50k tokens, 98 chunks at CHUNK_SIZE 512) meant
    ///          98 allocations and ~115 KB copied and abandoned to track 98
    ///          descriptors. Doubling makes that 5 allocations and ~7 KB.
    priv fn grow(self) {
        // A chunk retired by pop_back still owns its base. Take it back before
        // allocating anything.
        if self._chunk_count < self._chunk_alloced {
            self._chunks[self._chunk_count].length = 0
            ++self._chunk_count
            return
        }

        if self._chunk_alloced == self._chunk_capacity {
            var new_cap: usize = if (self._chunk_capacity == 0) => (8)
                                 else => self._chunk_capacity * 2

            var unsafe *new_table = (unsafe (self._allocator.alloc(
                sizeof  (Self::Chunk) * new_cap,
                alignof (Self::Chunk)
                ,
            ) as Self::ChunkBuff))

            if self._chunks != &null {
                cxx::std::memcpy(
                    new_table,
                    self._chunks,
                    sizeof (Self::Chunk) * self._chunk_alloced,
                )
            }

            self._chunks         = new_table
            self._chunk_capacity = new_cap
        }

        // Fill the descriptor in place: allocating a Chunk in the arena,
        // filling it, copying it into the table and abandoning the original
        // would leak 24 bytes per chunk for nothing.
        var *new_chunk = &self._chunks[self._chunk_alloced]

        new_chunk->capacity = CHUNK_SIZE
        new_chunk->length   = 0
        new_chunk->base = (unsafe (self._allocator.alloc(
            sizeof  (Token) * CHUNK_SIZE,
            alignof (Token)
            ,
        ) as Self::TokenPtr))

        ++self._chunk_alloced
        ++self._chunk_count
    }

    pub fn append(self, token: Token) { // copying is fine since a token is 16-bytes
        // check if we need to grow the chunk table
        if self._chunk_count == 0
            || self._chunks[self._chunk_count - 1].length == self._chunks[self._chunk_count - 1].capacity {
            self.grow()
        }

        var *chunk = &self._chunks[self._chunk_count - 1]

        chunk->base[chunk->length] = token
        ++chunk->length

        ++self._total_length
    }

    pub fn get(const self, index: usize) -> unsafe *Token {
        if index >= self._total_length {
            return &null
        }

        var chunk_index  = index / CHUNK_SIZE
        var offset_index = index % CHUNK_SIZE

        return unsafe &self._chunks[chunk_index].base[offset_index]
    }

    pub fn pop_back(self) {
        if self._total_length == 0 {
            return
        }

        var *chunk = &self._chunks[self._chunk_count - 1]
        // Last chunk can be empty if pops crossed a boundary; walk back.
        //
        // _chunk_count must move here, not just a local index: get() and
        // operator[] address tokens as index / CHUNK_SIZE, which is only
        // correct while every chunk below the last in-use one is exactly full.
        // Leaving _chunk_count pinned would let the next append write into a
        // trailing empty chunk and desync that mapping. The retired chunk is
        // not leaked: _chunk_alloced remembers its base and grow() reuses it.
        while chunk->length == 0 && self._chunk_count > 1 {
            --self._chunk_count
            chunk = &self._chunks[self._chunk_count - 1]
        }

        if chunk->length == 0 { // defensive
            return
        }

        --chunk->length
        --self._total_length
    }

    fn destroy(self) {
        self._chunk_count    = 0
        self._chunk_alloced  = 0
        self._chunk_capacity = 0
        self._total_length   = 0
        self._chunks         = &null
        self._allocator.destroy()
    }

    fn shutdown(self) {
        self._chunk_count    = 0
        self._chunk_alloced  = 0
        self._chunk_capacity = 0
        self._total_length   = 0
        self._chunks         = &null
        self._allocator.shutdown()
    }

    pub fn size(const self) -> usize {
        return self._total_length
    }

    fn chunk_count(const self) -> usize {
        return self._chunk_count
    }

    fn chunk_size(const self) -> usize {
        return CHUNK_SIZE
    }

    fn allocator(self) -> *ArenaAllocator {
        return &self._allocator
    }

    fn chunks(const self) -> Self::ChunkBuff {
        return self._chunks
    }

    fn clear(self) {
        self._chunk_count    = 0
        self._chunk_alloced  = 0
        self._chunk_capacity = 0
        self._total_length   = 0
        self._chunks         = &null
        self._allocator.reset()
    }

    fn swap(self, other: *TokenBuffer<CHUNK_SIZE>) {
        var        tmp_alloc   = cxx::std::move(self._allocator)
        var unsafe *tmp_chunks = self._chunks
        var        tmp_cc      = self._chunk_count
        var        tmp_ca      = self._chunk_alloced
        var        tmp_cap     = self._chunk_capacity
        var        tmp_len     = self._total_length

        self._allocator      = cxx::std::move(other->_allocator)
        self._chunks         = other->_chunks
        self._chunk_count    = other->_chunk_count
        self._chunk_alloced  = other->_chunk_alloced
        self._chunk_capacity = other->_chunk_capacity
        self._total_length   = other->_total_length

        other->_allocator      = cxx::std::move(tmp_alloc)
        other->_chunks         = tmp_chunks
        other->_chunk_count    = tmp_cc
        other->_chunk_alloced  = tmp_ca
        other->_chunk_capacity = tmp_cap
        other->_total_length   = tmp_len
    }

    fn op finally (self) {
        self.destroy()
    }

    fn op [] (const self, index: usize) -> *Token {
        if index >= self._total_length {
            kairo::std::ice_fail(
                "TokenBuffer::operator[] - index out of bounds",
            )
        }

        var chunk_index  = index / CHUNK_SIZE
        var offset_index = index % CHUNK_SIZE

        return &self._chunks[chunk_index].base[offset_index]
    }

    fn op in (self) -> yield Token {
        for var c: usize = 0; c < self._chunk_count; ++c {
            var *chunk = &self._chunks[c]

            for var i: usize = 0; i < chunk->length; ++i {
                yield chunk->base[i]
            }
        }
    }
}
