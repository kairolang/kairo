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
ffi "c++" import "Native/KShims.hh" // posix_stat
ffi "c++" import "llvm/Support/ConvertUTF.h"
ffi "c++" import "string"

import std::c_char

///
/// \file MMapRegion.k
/// \brief cross-platform RAII wrapper around memory-mapped file regions.
///
/// \details
/// `MMapRegion` abstracts OS-specific file mapping APIs (`mmap` on POSIX,
/// `CreateFileMappingW` on Windows) into a consistent interface for read-only
/// file access without copying data into user space.
///
/// the class ensures cleanup through RAII; automatically unmapping memory
/// when destroyed. it supports direct pointer access to mapped data and
/// optional subregion attachment.
///
/// design goals:
///   - zero-copy read access to large files.
///   - deterministic cleanup on scope exit.
///   - minimal abstraction overhead.
///   - uniform semantics across platforms.
///
/// \note
/// - always maps in **read-only** mode.
/// - not thread-safe; external synchronization required.
/// - includes an implicit null terminator for safety with string-like data.
///
/// \see MappedFileBuffer, VirtualFileManager, MemoryBuffer
///

///
/// \class MMapRegion
/// \brief lightweight managed interface for memory-mapped regions.
///
/// manages the lifecycle of an OS-level memory mapping, exposing basic
/// operations like open, close, and attach. primarily used internally by
/// `MappedFileBuffer` and the virtual filesystem.
///
pub class MMapRegion {
    pub var _data:  unsafe *u8 = &null ///< pointer to mapped region.
    pub var _size:  usize      = 0     ///< mapped region size (in bytes).
    pub var _valid: bool       = false ///< indicates mapping success.
    pub var _owns:  bool       = true  ///< true if region owns the mapping.

    ///
    /// \brief default constructor.
    ///
    fn MMapRegion(self) = default

    fn MMapRegion(self, data: unsafe *u8, size: usize, valid: bool = true) {
        self._data  = data
        self._size  = size
        self._valid = valid
    }

    // Move-only: the destructor unmaps the region, so a copy would unmap it
    // twice. The source is left empty, so its close() is a no-op.
    @move fn MMapRegion(self, other: Self) {
        self._data   = other._data
        self._size   = other._size
        self._valid  = other._valid
        self._owns   = other._owns
        other._data  = &null
        other._size  = 0
        other._valid = false
    }

    ///
    /// \brief destructor; automatically unmaps region if valid.
    ///
    fn op finally (self) {
        self.close()
    }

    ///
    /// \brief opens and memory-maps a file by path.
    ///
    /// \param path pointer to string containing the path.
    /// \return true if successfully mapped, false otherwise.
    ///
    /// \details
    /// - on windows, uses `CreateFileW` and `MapViewOfFile`.
    /// - on posix, uses `open` + `mmap`.
    /// - stores mapping pointer and size for later access.
    /// - closes handles/descriptors after mapping.
    ///
    /// \warning
    /// - only supports read-only access.
    /// - must not be called on an already-open region (use `close()` first).
    ///
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
                unsafe ((path->raw() as unsafe *const u8) as unsafe *const c_char),
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
            var path_str     = *path
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

            var mapping: unsafe *u8 = unsafe (mmap(
                &null,
                st.st_size as usize,
                kairo::prot_read,
                kairo::map_private,
                fd,
                0
            ) as unsafe *u8)

            close(fd)

            if mapping == unsafe (kairo::map_failed() as unsafe *u8) {
                return false
            }

            self._data  = mapping
            self._size  = st.st_size as usize
            self._owns  = true
            self._valid = true
        }

        return true
    }

    ///
    /// \brief unmaps region and resets internal state.
    ///
    /// \details
    /// - no-op if invalid or already unmapped.
    /// - safe to call multiple times.
    ///
    fn close(self) {
        if !self._valid || self._data == &null || !self._owns {
            return
        }

        eval if defined!(_WIN32) {
            kairo::win32::unmap(self._data)
        } else {
            munmap(self._data, self._size)
        }

        self._data  = &null
        self._size  = 0
        self._valid = false
    }

    ///
    /// \brief returns pointer to mapped data.
    ///
    pub fn data(const self) -> unsafe *u8 {
        return self._data
    }

    ///
    /// \brief returns size of mapped region (in bytes).
    ///
    pub fn size(const self) -> usize {
        return self._size
    }

    ///
    /// \brief checks whether the mapping is valid.
    ///
    fn is_valid(const self) -> bool {
        return self._valid
    }

    ///
    /// \brief attaches this region to a subregion of another mapping.
    ///
    /// \param parent pointer to valid parent mapping.
    /// \param offset byte offset into parent region.
    /// \param length desired subrange length.
    ///
    /// \details
    /// - creates a lightweight view without allocating or remapping.
    /// - clamps length if it exceeds parent size.
    /// - if parent invalid or null, marks self invalid.
    ///
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
