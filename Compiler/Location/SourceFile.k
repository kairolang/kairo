/// --- The Kairo Project ------------------------ Location/SourceFile.k --- ///
///
///   SourceFile: a handle on one memory-mapped source file.
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

import Memory::MappedFileBuffer::MappedFileBuffer
import Support::FileIO::Path::Path

///
/// \file SourceFile.k
/// \brief representation of a single memory-mapped source file.
///
/// \details
/// `SourceFile` acts as a lightweight handle over a memory-mapped file region
/// managed by `VirtualFileManager`. it holds a reference to a `MappedFileBuffer`
/// and tracks its base offset and size within the larger virtual memory map.
///
/// this abstraction allows higher-level systems- such as the `SourceManager`,
/// lexer, and parser- to uniformly access source contents without worrying
/// about file segmentation or buffer ownership.
///
/// each `SourceFile` is valid only as long as its parent `MappedFileBuffer`
/// remains mapped. it provides convenience methods for validity checking and
/// end offset computation.
///
/// \see VirtualFileManager, MappedFileBuffer
///

///
/// \class SourceFile
/// \brief wrapper for a mapped source file region.
///
/// \details
/// represents a contiguous section of a source file stored in memory.
/// provides metadata such as file path, total size, and base offset.
/// this type is purely referential and does not manage lifetime of the
/// underlying buffer.
///
pub class SourceFile {
    pub var path:        Path                         ///< filesystem path of the file.
    pub var buffer:      unsafe *MappedFileBuffer     ///< pointer to mapped memory region.
    pub var base_offset: usize                    = 0 ///< base offset within global space.
    pub var size_bytes:  usize                    = 0 ///< size of the file in bytes.

    /// Set once by SourceManager::validate_utf8. Checked-and-valid is two
    /// flags rather than one because "not yet scanned" must not read as
    /// either verdict: the scan reports diagnostics, and a second scan of the
    /// same buffer would report them twice.
    pub var utf8_checked: bool = false
    pub var utf8_valid:   bool = true

    ///
    /// \brief constructs a `SourceFile` from an existing mapped buffer.
    ///
    /// \param path   absolute or canonical file path.
    /// \param buffer pointer to a valid `MappedFileBuffer`.
    /// \param base   base offset within the virtual memory space.
    ///
    /// \throws RuntimeError if buffer is null or invalid.
    ///
    fn SourceFile(self, const path: Path, buffer: unsafe *MappedFileBuffer, base: usize) {
        if buffer == &null || !buffer->is_valid() {
            kairo::std::ice_fail("SourceFile: Invalid buffer for SourceFile")
        }

        self.path        = path
        self.buffer      = buffer
        self.base_offset = base
        self.size_bytes  = buffer->bytes().size()
    }

    ///
    /// \brief computes the byte offset immediately after the file.
    ///
    /// \return `base_offset + size_bytes`.
    ///
    fn end_offset(const self) -> usize {
        return self.base_offset + self.size_bytes
    }

    ///
    /// \brief checks whether the file is in a valid mapped state.
    ///
    /// \return true if the buffer exists and is valid.
    ///
    fn is_valid(const self) -> bool {
        return self.buffer != &null && self.buffer->is_valid()
    }
}
