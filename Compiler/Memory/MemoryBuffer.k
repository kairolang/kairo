/// --- The Kairo Project ------------------------ Memory/MemoryBuffer.k --- ///
///
///   MemoryBuffer: a read-only byte range with a UTF-8 view.
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

import Support::UTF8View::UTF8View

/// simple read-only byte buffer with utf-8 decoding support.
///
/// `MemoryBuffer` is a lightweight wrapper around a pointer to immutable
/// byte data and its total size. it provides direct byte access and an
/// iterator-based utf-8 view for character-level decoding.
///
/// typically wraps a memory-mapped region (`MMapRegion`) or subrange of one,
/// exposing convenient access for lexers, parsers, and file i/o layers.
///
/// this class performs no ownership or lifetime management- the backing
/// memory must remain valid for the duration of its use.
///
/// **Note:**
/// read-only by design; use external writers for mutable operations.
///
/// **Warning:**
/// not thread-safe without external synchronization.

/// read-only view over raw byte memory.
///
/// provides direct pointer access (`data()`, `size()`) and utf-8 decoding
/// through the `chars()` method. used heavily by the compiler's source and
/// file management subsystems.
pub class MemoryBuffer {
    priv var _data: kairo::std::ConstPtr<u8> = &null ///< pointer to raw data bytes.
    priv var _size: usize                    = 0     ///< total byte size of buffer.

    /// default constructor (invalid buffer).
    pub fn MemoryBuffer(self) = default

    /// constructs from a raw pointer and size.
    ///
    /// ### Parameters
    /// - `data`: pointer to constant byte memory.
    /// - `size`: total number of bytes available.
    pub fn MemoryBuffer(self, data: kairo::std::ConstPtr<u8>, size: usize) {
        self._data = data
        self._size = size
    }

    /// assignment operator.

    /// returns pointer to underlying byte data.
    pub inline fn data(self) -> kairo::std::ConstPtr<u8> {
        return self._data
    }

    /// returns total size of the buffer in bytes.
    pub inline fn size(self) -> usize {
        return self._size
    }

    /// checks if buffer is valid.
    ///
    /// ### Returns
    /// true if `_data` is not null and `_size` > 0.
    pub inline fn is_valid(self) -> bool {
        return self._data != &null
    }

    /// returns utf-8 decoding view of the buffer.
    ///
    /// ### Returns
    /// `UTF8View` initialized with buffer data.
    inline fn chars(self) -> UTF8View {
        return UTF8View(self._data, self._size)
    }
}
