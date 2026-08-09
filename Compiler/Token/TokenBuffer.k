/// --- The Kairo Project -------------------------- Token/TokenBuffer.k --- ///
///
///   <short description>
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Memory::ArenaAllocator::*;
import Token::TokenKind::*;
import Token::Token::*;

class <const CHUNK_SIZE: usize> TokenBuffer {
    struct Chunk; ///< forward declaration

    type TokenPtr  = obs::<Token>;
    type ChunkBuff = view::<Chunk>;

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
        var base:     TokenPtr;
        var capacity: usize;
        var length:   usize;
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
    var _allocator:      ArenaAllocator = ArenaAllocator(2048 * sizeof (TokenPtr));
    var _chunks:         ChunkBuff      = &null; // array of chunk descriptors
    var _chunk_count:    usize          = 0;     // chunks in use
    var _chunk_alloced:  usize          = 0;     // chunks with a live base
    var _chunk_capacity: usize          = 0;     // entries the table can hold
    var _total_length:   usize          = 0;     // number of tokens in all chunks

    __inline_cpp("public:
    TokenBuffer(TokenBuffer&& other) noexcept {
        this->_allocator      = std::Memory::move(other._allocator);
        this->_chunks         = other._chunks;
        this->_chunk_count    = other._chunk_count;
        this->_chunk_alloced  = other._chunk_alloced;
        this->_chunk_capacity = other._chunk_capacity;
        this->_total_length   = other._total_length;

        other._chunks         = &null;
        other._chunk_count    = 0;
        other._chunk_alloced  = 0;
        other._chunk_capacity = 0;
        other._total_length   = 0;
    }

    TokenBuffer& operator=(TokenBuffer&& other) noexcept {
        if (this != &other) {
            this->destroy();

            _allocator      = std::Memory::move(other._allocator);
            _chunks         = other._chunks;
            _chunk_count    = other._chunk_count;
            _chunk_alloced  = other._chunk_alloced;
            _chunk_capacity = other._chunk_capacity;
            _total_length   = other._total_length;

            other._chunks         = &null;
            other._chunk_count    = 0;
            other._chunk_alloced  = 0;
            other._chunk_capacity = 0;
            other._total_length   = 0;
        }

        return this;
    }

    TokenBuffer(TokenBuffer&) noexcept = delete;
    TokenBuffer& operator=(TokenBuffer&) noexcept = delete;
    ");

    default fn TokenBuffer(self);

    fn emit_errors(self) {
        for var i: usize = 0; i < self._total_length; ++i {
            var token = self.get(i);

            if token == &null {
                continue;
            }

            if (*token) == TokenKind::TkError {
                // FIXME: this should be handled by the DiagEngine and not here
                std::print(f"Invalid token found at {token->range} expected a valid '{token_kind_to_readable_string(static_cast::<TokenKind>(token->imm))}' token\n");
            }
        }
    }

    /// \brief makes one more chunk available to append.
    ///
    /// \details The table grows by DOUBLING. It used to re-allocate one entry
    ///          larger per chunk and copy the old contents across, which is
    ///          O(n^2) bytes against an allocator that never reclaims: every
    ///          superseded table stayed resident until destroy(). Lexing this
    ///          repo's Lexer.k (~50k tokens, 98 chunks at CHUNK_SIZE 512) meant
    ///          98 allocations and ~115 KB copied and abandoned to track 98
    ///          descriptors. Doubling makes that 5 allocations and ~7 KB.
    priv fn grow(self) {
        // A chunk retired by pop_back still owns its base. Take it back before
        // allocating anything.
        if self._chunk_count < self._chunk_alloced {
            self._chunks[self._chunk_count].length = 0;
            ++self._chunk_count;
            return;
        }

        if self._chunk_alloced == self._chunk_capacity {
            var new_cap: usize = (8) if (self._chunk_capacity == 0)
                                  else (self._chunk_capacity * 2);

            var new_table = reinterpret_cast::<ChunkBuff>(
                self._allocator.alloc(
                    sizeof  (Chunk) * new_cap,
                    alignof (Chunk)
                )
            );

            if self._chunks != &null {
                std::Memory::copy(
                    new_table,
                    self._chunks,
                    sizeof (Chunk) * self._chunk_alloced
                );
            }

            self._chunks         = new_table;
            self._chunk_capacity = new_cap;
        }

        // Fill the descriptor in place. The old code allocated a Chunk in the
        // arena, filled it, copied it into the table and abandoned the
        // original - 24 bytes leaked per chunk for nothing.
        var new_chunk = &(self._chunks[self._chunk_alloced]);

        new_chunk->capacity = CHUNK_SIZE;
        new_chunk->length   = 0;
        new_chunk->base     = reinterpret_cast::<TokenPtr>(
            self._allocator.alloc(
                sizeof  (Token) * CHUNK_SIZE,
                alignof (Token)
            )
        );

        ++self._chunk_alloced;
        ++self._chunk_count;
    }

    fn append(self, token: Token) { // copying is fine since a token is 16-bytes
        // check if we need to grow the chunk table
        if (self._chunk_count == 0)
        || ((self._chunks[self._chunk_count - 1].length)
            == (self._chunks[self._chunk_count - 1].capacity))
        {
            self.grow();
        }

        var chunk = &self._chunks[self._chunk_count - 1];
    
        chunk->base[chunk->length] = token;
        ++chunk->length;

        ++self._total_length;
    }

    fn get(self, index: usize) -> *Token {
        if index >= self._total_length {
            return &null;
        }

        var chunk_index  = index / CHUNK_SIZE;
        var offset_index = index % CHUNK_SIZE;

        return &(self._chunks[chunk_index].base[offset_index]);
    }

    fn pop_back(self) {
        if self._total_length == 0 { return; }
        var chunk = &self._chunks[self._chunk_count - 1];
        // Last chunk can be empty if pops crossed a boundary; walk back.
        //
        // _chunk_count must move here, not just a local index: get() and
        // operator[] address tokens as index / CHUNK_SIZE, which is only
        // correct while every chunk below the last in-use one is exactly full.
        // Leaving _chunk_count pinned would let the next append write into a
        // trailing empty chunk and desync that mapping. The retired chunk is
        // no longer leaked - _chunk_alloced remembers its base and grow()
        // hands it straight back.
        while (chunk->length == 0) && (self._chunk_count > 1) {
            --self._chunk_count;
            chunk = &self._chunks[self._chunk_count - 1];
        }
        if chunk->length == 0 { return; } // defensive
        --chunk->length;
        --self._total_length;
    }

    fn destroy(self) {
        self._chunk_count    = 0;
        self._chunk_alloced  = 0;
        self._chunk_capacity = 0;
        self._total_length   = 0;
        self._chunks         = &null;
        self._allocator.destroy();
    }

    fn shutdown(self) {
        self._chunk_count    = 0;
        self._chunk_alloced  = 0;
        self._chunk_capacity = 0;
        self._total_length   = 0;
        self._chunks         = &null;
        self._allocator.shutdown();
    }

    fn size(self) -> usize {
        return self._total_length;
    }

    fn chunk_count(self) -> usize {
        return self._chunk_count;
    }

    fn chunk_size(self) -> usize {
        return CHUNK_SIZE;
    }

    fn allocator(self) -> *ArenaAllocator {
        return &self._allocator;
    }

    fn chunks(self) -> ChunkBuff {
        return self._chunks;
    }

    fn clear(self) {
        self._chunk_count    = 0;
        self._chunk_alloced  = 0;
        self._chunk_capacity = 0;
        self._total_length   = 0;
        self._chunks         = &null;
        self._allocator.reset();
    }

    fn swap(self, other: *TokenBuffer::<CHUNK_SIZE>) {
        var tmp_alloc   = std::Memory::move(self._allocator);
        var tmp_chunks  = self._chunks;
        var tmp_cc      = self._chunk_count;
        var tmp_ca      = self._chunk_alloced;
        var tmp_cap     = self._chunk_capacity;
        var tmp_len     = self._total_length;

        self._allocator      = std::Memory::move(other->_allocator);
        self._chunks         = other->_chunks;
        self._chunk_count    = other->_chunk_count;
        self._chunk_alloced  = other->_chunk_alloced;
        self._chunk_capacity = other->_chunk_capacity;
        self._total_length   = other->_total_length;

        other->_allocator      = std::Memory::move(tmp_alloc);
        other->_chunks         = tmp_chunks;
        other->_chunk_count    = tmp_cc;
        other->_chunk_alloced  = tmp_ca;
        other->_chunk_capacity = tmp_cap;
        other->_total_length   = tmp_len;
    }

    fn op delete (self) {
        self.destroy();
    }

    fn op [] (self, index: usize) -> *Token {
        if index >= self._total_length {
            std::crash(std::Error::RuntimeError(
                "TokenBuffer::operator[] - index out of bounds"
            ));
        }

        var chunk_index  = index / CHUNK_SIZE;
        var offset_index = index % CHUNK_SIZE;

        return &(self._chunks[chunk_index].base[offset_index]);
    }

    fn op in (self) -> yield Token {
        for var c: usize = 0; c < self._chunk_count; ++c {
            var chunk = &self._chunks[c];

            for var i: usize = 0; i < chunk->length; ++i {
                yield chunk->base[i];
            }
        }
    }
}