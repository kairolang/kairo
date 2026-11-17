/// --- The Kairo Project -------------------- Memory/MappedFileBuffer.k --- ///
///
///   MappedFileBuffer: a memory-mapped file viewed through a MemoryBuffer.
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
ffi "c++" import "Native/Log.hh"

import Memory::MMapRegion::MMapRegion
import Memory::MemoryBuffer::MemoryBuffer
import Support::FileIO::AtomicFile::now_ns
import Support::FileIO::Path::Path
import Support::Timer::Timer
import std::io

/// memory-mapped file abstraction with utf-8 viewing support.
///
/// `MappedFileBuffer` provides a unified cross-platform interface for working
/// with memory-mapped files. it handles region creation, attachment to parent
/// buffers, and read-only byte-level access through a `MemoryBuffer` view.
///
/// under the hood, it uses `MMapRegion` for low-level os mapping, providing
/// page-aligned memory access. on posix systems this wraps `mmap`, while on
/// windows it wraps `CreateFileMapping`.
///
/// a `MappedFileBuffer` can either own its region (when loaded directly from a
/// file) or reference a subrange of another buffer (`attach()`).
///
/// the class supports utf-8 viewing via `UTF8View` and is used heavily by the
/// `VirtualFileManager` and `SourceManager`.
///
/// **Warning:** not thread-safe. synchronization is the caller's responsibility.
///
/// **Warning:** error handling is minimal; production builds should add safety
/// layers around i/o and mapping failures.

/// lightweight wrapper around a mapped file region.
///
/// provides deterministic file mapping and byte access without heap copies.
/// suitable for compiler file i/o, lexer input, or caching.
///
/// ownership semantics:
///   - if created via `load()`, the buffer owns its region.
///   - if created via `attach()`, it references another buffer's region.
pub class MappedFileBuffer {
    var _region:      MMapRegion   = MMapRegion()   ///< underlying mmap region.
    var _view:        MemoryBuffer = MemoryBuffer() ///< byte-level buffer view.
    var _owns_region: bool         = true           ///< true if buffer owns the mapped region.

    /// default constructor, creates an empty invalid buffer.
    pub fn MappedFileBuffer(self) = default

    /// disable copy construction and assignment.
    @copy fn MappedFileBuffer(self, const other: Self) = delete

    /// destructor, closes mapped region if owned.
    fn op finally (self) {
        self.close()
    }

    /// checks if the buffer is valid and mapped.
    pub fn is_valid(const self) -> bool {
        return self._region.is_valid()
    }

    /// returns the raw byte view of the mapped region.
    ///
    /// ### Returns
    /// `MemoryBuffer` providing pointer and size access.
    pub fn bytes(self) -> MemoryBuffer {
        return self._view
    }

    /// closes and unmaps the region if owned.
    ///
    /// resets the memory buffer and releases resources.
    pub fn close(self) {
        if self._owns_region {
            self._region.close()
        }

        self._view = MemoryBuffer()
    }

    /// loads a file into memory via mapping.
    ///
    /// ### Parameters
    /// - `path`: pointer to string path of the file.
    ///
    /// performs an os-level file mapping, exposing it as a contiguous region
    /// through `MemoryBuffer`. replaces any existing region.
    pub fn load(self, path: unsafe *string) {
        self._owns_region = true
        self._region.open(path)
        self._view = MemoryBuffer(self._region.data(), self._region.size())
        kairo::Logger::debug(
            kairo::Logger::Stage::Driver,
            f"MappedFileBuffer::load: mapped {*path} size={self._view.size()}B",
        )
    }

    /// attaches a subregion of another mapped file buffer.
    ///
    /// ### Parameters
    /// - `parent`: pointer to parent buffer.
    /// - `offset`: starting byte offset within parent buffer.
    /// - `length`: number of bytes to include in subregion.
    ///
    /// does not take ownership of memory. used internally for segment-level
    /// slicing inside large mapped files.
    pub fn attach(self, parent: unsafe *MappedFileBuffer, offset: usize, length: usize) {
        if parent == &null || !parent->_region.is_valid() {
            self._region = MMapRegion()
            kairo::Logger::warn(
                kairo::Logger::Stage::Driver,
                "MappedFileBuffer::attach: null or invalid parent",
            )

            return
        }

        self._region.attach(unsafe &parent->_region, offset, length)
        self._view = MemoryBuffer(self._region.data(), self._region.size())
        self._owns_region = false
    }

    /// attaches raw memory as the buffer (non-owning).
    ///
    /// ### Parameters
    /// - `data`: pointer to raw byte data.
    /// - `size`: size of the data in bytes.
    ///
    /// used for wrapping non-mapped memory regions.
    pub fn attach_raw(self, data: unsafe *u8, size: usize) {
        self._region._data  = data
        self._region._size  = size
        self._region._valid = data != &null
        self._region._owns  = false
        self._view = MemoryBuffer(
            unsafe (data as kairo::std::ConstPtr<u8>),
            size,
        )

        self._owns_region = false
    }
}

// TODO(replace with kairo test blocks)
pub fn Test() -> i32 {
    var timer: Timer = Timer("MMap Test")

    // The file is the test's own, under a name no other run uses at once.
    var expected = "first line\nsecond line, with UTF-8: λ\n"
    var path     = Path::temp_dir().join(f"kunit_mmap_{now_ns()}.txt")
    if !Path::write_file(path, expected) {
        io::println(f"cannot write {path}")
        return 1
    }

    finally {
        Path::remove_file(path)
    }

    var buf: MappedFileBuffer = MappedFileBuffer()
    buf.load(unsafe &path)

    if !buf.is_valid() {
        io::println(f"cannot map {path}")
        return 1
    }

    var mem:  MemoryBuffer     = buf.bytes()
    var ptr:  unsafe *const u8 = mem.data()
    var size: usize            = mem.size()

    timer.stop()

    var content = string(unsafe (ptr as *const u8), size)
    io::println(f"file: {path}\ncontent size: {size} bytes")

    if content != expected {
        io::println(
            f"expected {expected.size()} bytes:\n{expected}\nmapped:\n{content}",
        )

        return 1
    }

    return 0
}
