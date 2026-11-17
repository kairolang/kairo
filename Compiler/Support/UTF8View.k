/// --- The Kairo Project --------------------------- Support/UTF8View.k --- ///
///
///   UTF8View: a forward iterator decoding UTF-8 into code points.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/UTF8Decode.hh"

import Memory::MMapRegion::MMapRegion

/// forward iterator for utf-8 decoding with ascii fast-path.
///
/// `UTF8View` provides an iterator interface for decoding utf-8 byte sequences
/// into unicode code points (`char32_t`). it's a lightweight, read-only view
/// that operates directly on existing memory buffers; typically those mapped
/// from files via `MMapRegion`.
///
/// the iterator decodes one code point per iteration using `decode_utf8_lut()`
/// (from `UTF8Decode.hh`), which applies strict utf-8 validation. invalid
/// or overlong sequences are replaced with `'?'` (0x3F). for efficiency, ascii
/// bytes are processed in a single fast-path pass.
///
/// this type is used internally by the lexer, source manager, and diagnostic
/// subsystems when decoding large text buffers.
///
/// **Note:**
/// this class performs no normalization or surrogate correction.
///
/// **Warning:**
/// not thread-safe. concurrent iteration over shared memory requires external
/// synchronization.
///
/// See MMapRegion, decode_utf8_lut.

/// forward-only view for utf-8 decoding over raw data.
///
/// provides sequential utf-8 decoding over a byte buffer. each `in` iteration
/// yields a single unicode code point. the class can be constructed from either
/// a raw pointer or an `MMapRegion`.
pub class UTF8View {
    var data: unsafe *const u8 ///< pointer to utf-8 data.
    var size: usize            ///< data length in bytes.

    /// constructs from a raw pointer and byte size.
    ///
    /// ### Parameters
    /// - `data`: pointer to utf-8 encoded bytes.
    /// - `size`: total number of bytes available.
    pub fn UTF8View(self, data: unsafe *const u8, size: usize) {
        self.data = data
        self.size = size
    }

    /// constructs from an `MMapRegion`.
    ///
    /// ### Parameters
    /// - `region`: memory-mapped region containing utf-8 text.
    fn UTF8View(self, const region: MMapRegion) {
        self.data = region.data()
        self.size = region.size()
    }

    /// decodes a single utf-8 sequence from memory.
    ///
    /// ### Parameters
    /// - `ptr`: pointer to current byte position.
    /// - `remaining`: number of bytes left in the buffer.
    ///
    /// ### Returns
    /// `DecodeResult` containing codepoint and bytes consumed.
    ///
    /// **Note:**
    /// invalid sequences return `{0xFFFD, 0}` to indicate replacement.
    pub static fn decode_utf8(ptr: unsafe *const u8, remaining: usize) -> kairo::DecodeResult {
        return kairo::decode_utf8_lut(ptr, remaining)
    }

    /// iterator interface for utf-8 decoding.
    ///
    /// yields one code point per iteration until end-of-buffer is reached.
    /// ensures forward progress by checking `len != 0`. malformed or
    /// truncated sequences yield `0xFFFD` before stopping.
    ///
    /// \example
    /// ```kairo
    /// for ch in UTF8View(region) {
    ///     std::print(f"codepoint = {ch}\n");
    /// }
    /// ```
    fn op in (self) -> yield char {
        var pos: usize = 0

        while pos < self.size {
            var decoded = UTF8View::decode_utf8(
                self.data + pos,
                self.size - pos,
            )

            if decoded.len == 0 { // no progress safeguard
                break
            }

            yield decoded.chr
            pos += decoded.len as usize
        }
    }
}
