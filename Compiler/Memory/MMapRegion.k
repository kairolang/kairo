/// --- The Kairo Project -------------------------- Memory/MMapRegion.k --- ///
///
///   MMapRegion: a read-only memory-mapped file region (POSIX and Windows).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Win32.hh" // map_readonly / unmap
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/Shims.hh" // posix_stat
ffi "c++" import "llvm/Support/ConvertUTF.h"
ffi "c++" import "string"

import std::c_char

/// cross-platform RAII wrapper around memory-mapped file regions.
///
/// `MMapRegion` gives a file's bytes a stable address for the whole compile.
/// On POSIX they are read into anonymous memory (`mmap` with
/// `MAP_ANONYMOUS`), so a later write to the file does not reach them; on
/// Windows the file is mapped (`CreateFileMappingW`), which the system keeps
/// from being truncated while the view is open.
///
/// the class ensures cleanup through RAII; automatically unmapping memory
/// when destroyed. it supports direct pointer access to mapped data and
/// optional subregion attachment.
///
/// design goals:
///   - deterministic cleanup on scope exit.
///   - minimal abstraction overhead.
///   - uniform semantics across platforms.
///
/// **Note:**
/// - not thread-safe; external synchronization required.
/// - includes an implicit null terminator for safety with string-like data.
///
/// See MappedFileBuffer, VirtualFileManager, MemoryBuffer.

/// lightweight managed interface for memory-mapped regions.
///
/// manages the lifecycle of an OS-level memory mapping, exposing basic
/// operations like open, close, and attach. primarily used internally by
/// `MappedFileBuffer` and the virtual filesystem.
pub class MMapRegion {
    pub var _data:  unsafe *u8 = &null ///< pointer to mapped region.
    pub var _size:  usize      = 0     ///< mapped region size (in bytes).
    pub var _valid: bool       = false ///< indicates mapping success.
    pub var _owns:  bool       = true  ///< true if region owns the mapping.
    /// Bytes to unmap on POSIX: the size read plus the terminator's room,
    /// which _size does not count.
    pub var _map_len: usize = 0

    /// default constructor.
    fn MMapRegion(self) = default

    fn MMapRegion(self, data: unsafe *u8, size: usize, valid: bool = true) {
        self._data  = data
        self._size  = size
        self._valid = valid
    }

    // Move-only: the destructor unmaps the region, so a copy would unmap it
    // twice. The source is left empty, so its close() is a no-op.
    @move fn MMapRegion(self, other: Self) {
        self._data    = other._data
        self._size    = other._size
        self._valid   = other._valid
        self._owns    = other._owns
        self._map_len = other._map_len
        other._data   = &null
        other._size   = 0
        other._valid  = false
    }

    /// destructor; automatically unmaps region if valid.
    fn op finally (self) {
        self.close()
    }

    /// opens and memory-maps a file by path.
    ///
    /// ### Parameters
    /// - `path`: pointer to string containing the path.
    ///
    /// ### Returns
    /// true if successfully mapped, false otherwise.
    ///
    /// - on windows, uses `CreateFileW` and `MapViewOfFile`.
    /// - on posix, uses `open` + `mmap`.
    /// - stores mapping pointer and size for later access.
    /// - closes handles/descriptors after mapping.
    ///
    /// **Warning:**
    /// - only supports read-only access.
    /// - must not be called on an already-open region (use `close()` first).
    fn open(self, path: unsafe *string) -> bool {
        if path == &null {
            return false
        }

        self.close()

        eval if defined!(_WIN32) {
            // Win32 lives in Native/Win32.cpp: <windows.h> in a header a
            // module imports put every Win32 name in this module's lookup.
            var data: unsafe *u8 = &null
            var size: usize      = 0
            if !kairo::win32::map_readonly(
                unsafe ((path->data() as unsafe *const u8) as unsafe *const c_char),
                path->size(),
                unsafe &data,
                unsafe &size,
            ) {
                return false
            }

            // An empty file is a non-null, zero-length region that is not a
            // mapping (map_readonly's static buffer): _owns false, never unmapped.
            self._data  = data
            self._size  = size
            self._owns  = size != 0
            self._valid = true
        } else {
            var path_str     = path->copy()
            var fd:      i32 = open(path_str.c_str(), kairo::o_rdonly)
            if fd < 0 {
                return false
            }

            var st: kairo::posix_stat = kairo::posix_stat()

            if fstat(fd, unsafe &st) != 0 {
                close(fd)
                return false
            }

            if st.st_size == 0 {
                close(fd)
                // As above: a literal, not a mapping, so never munmap it.
                self._data  = unsafe ((unsafe ("".c_str() as unsafe *const u8)) as unsafe *u8)
                self._size  = 0
                self._owns  = false
                self._valid = true
                return true
            }

            // The bytes are copied into anonymous memory, not mapped from the
            // file: a file rewritten in place while the compiler runs (an
            // editor, a script, another build) would change the bytes under
            // tokens already lexed, and one truncated kills the process
            // (SIGBUS) at the next read past its new end. The copy is what
            // the whole compile, clang's side included, sees. The extra
            // zeroed byte is the terminator clang's buffers require.
            var cap = (st.st_size as usize) + 1
            var mem: unsafe *u8 = unsafe (mmap(
                &null,
                cap,
                kairo::prot_read | kairo::prot_write,
                kairo::map_private | kairo::map_anonymous,
                -1,
                0
            ) as unsafe *u8)

            if mem == unsafe (kairo::map_failed() as unsafe *u8) {
                close(fd)
                return false
            }

            // A file that shrank since the fstat ends the copy early; one
            // that grew is cut at the size the fstat saw.
            var got: usize = 0
            var bad        = false
            while got < cap - 1 {
                var n = read(fd, mem + got, cap - 1 - got)
                if n < 0 {
                    bad = true
                    break
                }

                if n == 0 {
                    break
                }

                got += n as usize
            }

            close(fd)

            if bad {
                munmap(mem, cap)
                return false
            }

            self._data    = mem
            self._size    = got
            self._map_len = cap
            self._owns    = true
            self._valid   = true
        }

        return true
    }

    /// unmaps region and resets internal state.
    ///
    /// - no-op if invalid or already unmapped.
    /// - safe to call multiple times.
    fn close(self) {
        if !self._valid || self._data == &null || !self._owns {
            return
        }

        eval if defined!(_WIN32) {
            kairo::win32::unmap(self._data)
        } else {
            munmap(self._data, self._map_len)
        }

        self._data    = &null
        self._size    = 0
        self._map_len = 0
        self._valid   = false
    }

    /// returns pointer to mapped data.
    pub fn data(const self) -> unsafe *u8 {
        return self._data
    }

    /// returns size of mapped region (in bytes).
    pub fn size(const self) -> usize {
        return self._size
    }

    /// checks whether the mapping is valid.
    fn is_valid(const self) -> bool {
        return self._valid
    }

    /// attaches this region to a subregion of another mapping.
    ///
    /// ### Parameters
    /// - `parent`: pointer to valid parent mapping.
    /// - `offset`: byte offset into parent region.
    /// - `length`: desired subrange length.
    ///
    /// - creates a lightweight view without allocating or remapping.
    /// - clamps length if it exceeds parent size.
    /// - if parent invalid or null, marks self invalid.
    fn attach(self, parent: unsafe *MMapRegion, offset: usize, length: usize) {
        if parent == &null || !parent->_valid {
            self._valid = false
            return
        }

        if offset + length > parent->_size {
            length = parent->_size - offset
        }

        self._size = length

        self._data  = parent->_data + offset
        self._valid = true
        // A view never owns: left at the default, this region's destructor
        // unmapped the PARENT's mapping (the parent then unmapped it again),
        // and for an empty file the "mapping" is a literal inside the
        // executable's own image, which UnmapViewOfFile then tore out.
        self._owns = false
    }
}
