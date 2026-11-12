/// --- The Kairo Project --------------------- Location/SourceManager.k --- ///
///
///   SourceManager: loads source files and maps locations to their text.
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
ffi "c++" import "Native/UTF8Decode.hh"
ffi "c++" import "llvm/Support/FormatVariadic.h"
ffi "c++" import "Native/KLog.hh"
ffi "c++" import "vector"
ffi "c++" import "string"

import Diagnostic::Engine::DiagEngine
import Diagnostic::Registry::DiagID
import Location::FullSourceLocation::FullSourceLocation
import Location::SourceFile::SourceFile
import Location::SourceLineTable::SourceLineTable
import Location::SourceLocation::SourceLocation
import Location::SourceRange::SourceRange
import Memory::MemoryBuffer::MemoryBuffer
import Support::Assert::Assert
import Support::FileIO::Path::Path
import Support::FileIO::VirtualFileManager::VirtualFileManager
import Support::UTF8View::UTF8View
import Threading::ThreadPool::ThreadPool
import std::io

pub type FileID = u32

/// FIXME: change the use of string paths in get_line_col to Path objects.

///
/// \file SourceManager.k
/// \brief central coordinator for file loading, buffer access, and location
///        mapping.
///
/// \details
/// `SourceManager` acts as the backbone of the compiler's source system. it
/// maintains the relationship between on-disk files, in-memory buffers, and
/// compact `SourceLocation` identifiers used throughout parsing and diagnostics.
///
/// it integrates several key subsystems:
///   - `VirtualFileManager`: handles file registration and mapped memory.
///   - `SourceLineTable`: provides fast line/column resolution.
///   - `ThreadPool`: performs async line index building.
///   - `SourceFile`: represents loaded files and their memory-backed content.
///
/// conceptually, it provides a unified logical address space where each file
/// occupies a contiguous region. a `SourceLocation` id is an offset
/// into this space:
/// **`id = file_base + local_offset`**
///
/// this provides deterministic mapping and constant-time location resolution.
///
/// \note
/// this class is *not thread-safe*. concurrent operations must be synchronized
/// externally.
///
/// \see VirtualFileManager, SourceLineTable, SourceFile, SourceLocation
///

///
/// \class SourceManager
/// \brief manages mapping between files, buffers, and source locations.
///
/// provides APIs for:
///   - loading files (`load_file`)
///   - resolving ids to file/offset (`resolve`)
///   - computing line/column (`get_line_col`)
///   - fetching views, buffers, and metadata
///
pub class SourceManager {
    pub  var _line_table: SourceLineTable ///< global line mapping table
    priv var _files:      cxx::std::vector<unsafe *SourceFile> ///< all loaded files
    priv var _total_b:    u64                                  = 0 ///< total bytes mapped
    priv var _pool:       unsafe *ThreadPool ///< background worker pool
    priv var _vfile_mgr:  unsafe *VirtualFileManager ///< underlying virtual filesystem
    priv var _load_mu:    kairo::std::Mutex ///< mutex for synchronizing file loads
    priv var _diag:       unsafe *DiagEngine ///< diagnostic engine for reporting errors

    ///
    /// \brief constructs a new SourceManager with pool and vfile manager.
    ///
    /// \param pool thread pool used for background indexing.
    /// \param vfile_mgr virtual file manager used for mapping files.
    ///
    /// \throws RuntimeError if either argument is null.
    ///
    fn SourceManager(self,
                     pool:      unsafe *ThreadPool,
                     vfile_mgr: unsafe *VirtualFileManager,
                     diag:      unsafe *DiagEngine) {
        if pool == &null {
            kairo::std::ice_fail(
                "SourceManager: A valid ThreadPool is required",
            )
        }

        if vfile_mgr == &null {
            kairo::std::ice_fail(
                "SourceManager: A valid VirtualFileManager is required",
            )
        }

        if diag == &null {
            kairo::std::ice_fail(
                "SourceManager: A valid DiagEngine is required",
            )
        }

        self._diag      = diag
        self._pool      = pool
        self._files     = cxx::std::vector<unsafe *SourceFile>()
        self._total_b   = 0
        self._vfile_mgr = vfile_mgr
        kairo::Logger::info(
            kairo::Logger::Stage::Driver,
            f"SourceManager: initialized",
        )
    }

    ///
    /// \brief destructor: cleans up all loaded files.
    ///
    fn op finally (self) {
        self._line_table.shutdown()
        // self._pool->wait_all();

        for var f: *SourceFile? in self._files {
            if f != &null {
                @destroy unsafe (f as *SourceFile)
            }
        }

        self._files.clear()
    }

    ///
    /// \brief loads a file and registers it in the global source space.
    ///
    /// \param path file path to load.
    /// \return file id assigned by VirtualFileManager.
    ///
    /// \details
    /// - avoids duplicates by checking already-loaded paths.
    /// - registers file in the VirtualFileManager and SourceLineTable.
    /// - schedules async line-index build on the thread pool.
    ///
    pub fn load_file(self, const path: Path, skip_indexing: bool = false) -> FileID /* file_id */ {
        var lock  = kairo::std::LockGuard(self._load_mu) // synchronize file loading
        var known = self._vfile_mgr->fid_for_path(path)
        if known != (u32::MAX as FileID) {
            kairo::Logger::debug(
                kairo::Logger::Stage::Driver,
                f"SourceManager::load_file: cache hit for {path.full_path()} fid={known}",
            )

            self._materialize(known, path)
            return known
        }

        if !path.exists() {
            self._diag->report(
                DiagID::I005F,
                f"no such file: '{path.full_path()}'",
            ).emit()
            return u32::MAX
        }

        if path.is_directory() {
            self._diag->report(
                DiagID::I005F,
                f"'{path.full_path()}' is a directory, not a source file",
            ).emit()
            return u32::MAX
        }

        if path.is_symlink() && !path.is_regular_file() {
            self._diag->report(
                DiagID::I005F,
                f"'{path.full_path()}' is a symlink to a non-file target",
            ).emit()
            return u32::MAX
        }

        if !path.is_regular_file() {
            self._diag->report(
                DiagID::I005F,
                f"'{path.full_path()}' is not a regular file",
            ).emit()
            return u32::MAX
        }

        // Metadata says regular file, but we may still lack read permission
        // (chmod 000). Path does no I/O, so the open can still fail with EACCES.
        // register_file below opens/maps the file;
        var base_fid = self._vfile_mgr->register_file(path)
        if base_fid == (u32::MAX as FileID) {
            self._diag->report(
                DiagID::I005F,
                f"cannot read '{path.full_path()}': permission denied or I/O error",
            ).emit()
            return u32::MAX
        }

        var info = self._vfile_mgr->get_info(base_fid)
        var size = info.size

        self._line_table.register_file(base_fid, (size as u32))

        self._materialize(base_fid, path)
        kairo::Logger::info(
            kairo::Logger::Stage::Driver,
            f"SourceManager::load_file: loaded fid={base_fid} path={path.full_path()} size={size}B total={self._total_b}B",
        )

        if skip_indexing {
            kairo::Logger::info(
                kairo::Logger::Stage::Driver,
                f"SourceManager::load_file: skipping line index for fid={base_fid} path={path.full_path()}",
            )

            return base_fid
        }

        // Bytes and entry are both resolved HERE, under _load_mu, and handed
        // to the task by value. The task must not go back to the
        // VirtualFileManager for them: the next load_file pushes onto
        // _segments, and a pool thread indexing it mid-reallocation read a
        // null Segment. reserve_build also counts the task before it is
        // queued, so evict()/invalidate() wait for it before unmapping.
        var        bytes  = self._bytes_of(base_fid)
        var unsafe *entry = self._line_table.reserve_build(base_fid)
        if entry == &null {
            return base_fid
        }

        // A stopped pool drops what it is handed, which would strand the
        // reservation and hang every later drain. The driver destroys the
        // pool after this manager, so this only catches misuse.
        if !self._pool->is_active() {
            self._line_table.run_reserved_build(entry, bytes)
            return base_fid
        }

        self._pool->enqueue(
            kairo::SmallFunction<64>(
                fn () |entry, bytes, self| {
                    self._line_table.run_reserved_build(entry, bytes)
                },
            ),
        )

        // std::print(f"load_file: path={path.full_path()}, base_fid={base_fid}, _files.size()={self._files.size()}");
        return base_fid
    }

    ///
    /// \brief ensures \c _files[fid] holds a live SourceFile for \p path.
    ///
    /// \details \c _files is INDEXED BY FID, so this writes at \p fid rather
    ///          than appending: fids are not handed out in load order and can be
    ///          reused, because identity outlives artifacts.
    ///
    ///          Idempotent: a fid that still has its entry is left alone, so
    ///          this doubles as the cache-hit path. A fid whose entry was
    ///          released gets a fresh SourceFile over the SAME mapping   the
    ///          buffer belongs to the VirtualFileManager and did not go away.
    ///
    /// \note Caller must hold \c _load_mu.
    priv fn _materialize(self, fid: FileID, path: Path) {
        while self._files.size() <= (fid as usize) {
            self._files.push_back(&null)
        }

        if self._files[fid] != &null {
            return
        }

        var unsafe *buf = self._vfile_mgr->get_buffer(fid)
        if buf == &null || !buf->is_valid() {
            kairo::Logger::error(
                kairo::Logger::Stage::Driver,
                f"SourceManager::_materialize: no buffer for fid={fid}",
            )

            return
        }

        var unsafe *file = unsafe (@create SourceFile(path, buf, self._total_b as usize) as unsafe *SourceFile)

        /// Precondition: the running total cannot overflow.
        self._total_b += ((file->size_bytes) as u64)
        self._files[fid] = file
    }

    ///
    /// \brief \p fid's bytes as a by-value view, or an empty one.
    ///
    /// \details What every line-index build is handed, so that no build ever
    ///          reads the VirtualFileManager itself. The view stays valid until
    ///          the segment is evicted or re-mapped, and both of those drain
    ///          the line table's builds first.
    ///
    /// \note Caller must hold \c _load_mu.
    priv fn _bytes_of(self, fid: FileID) -> MemoryBuffer {
        var unsafe *buf = self._vfile_mgr->get_buffer(fid)
        if buf == &null || !buf->is_valid() {
            return MemoryBuffer()
        }

        return buf->bytes()
    }

    ///
    /// \brief loads a virtual (in-memory) file into the source space.
    ///
    /// \param fake_path logical path to assign to the virtual file.
    /// \param data pointer to raw byte data.
    /// \param size size of the data in bytes.
    ///
    /// \return file id assigned by VirtualFileManager.
    ///
    /// \note The caller is responsible for ensuring the data pointer
    ///       remains valid for the lifetime of the virtual file.
    ///
    pub fn load_virtual(self,
                        const fake_path: Path,
                        data:            kairo::std::ConstPtr<u8>,
                        size:            usize) -> FileID {
        var lock = kairo::std::LockGuard(self._load_mu)
        var fid  = self._vfile_mgr->register_virtual(fake_path, data, size)

        self._line_table.register_file(fid, (size as u32))

        self._materialize(fid, fake_path)
        kairo::Logger::info(
            kairo::Logger::Stage::Driver,
            f"SourceManager::load_virtual: registered fid={fid} path={fake_path.full_path()} size={size}B",
        )

        self._line_table.build_index(fid, self._bytes_of(fid))

        return fid
    }

    /// \brief load_virtual under a REAL path: later loads of \p real_path
    ///        return this buffer instead of the file on disk.
    ///
    /// \details What a language server needs for an unsaved buffer. See
    ///          VirtualFileManager::bind_path for what is and is not replaced.
    ///
    /// \note \p data is NOT copied (load_virtual's contract): it must outlive
    ///       every use of the returned fid.
    pub fn load_overlay(self,
                        const real_path: Path,
                        data:            kairo::std::ConstPtr<u8>,
                        size:            usize) -> FileID {
        var fid = self.load_virtual(real_path, data, size)
        self._vfile_mgr->bind_path(real_path, fid)
        return fid
    }

    /// \brief load_overlay without the load: \p real_path gets these bytes
    ///        when the graph first loads it, with the file id its place in
    ///        the load order gives it (VirtualFileManager::stage_overlay).
    pub fn stage_overlay(self, const real_path: Path, data: kairo::std::ConstPtr<u8>, size: usize) {
        var lock = kairo::std::LockGuard(self._load_mu)
        self._vfile_mgr->stage_overlay(real_path, data, size)
    }

    ///
    /// \brief drops one fid's loaded file: the SourceFile and its buffer view.
    ///
    /// \details Reset IN PLACE, never erased   `_files` is indexed by fid, so
    ///          erasing would renumber every later file.
    ///
    ///          The line-table entry is deliberately NOT dropped.
    ///          SourceLineTable publishes entries through an atomic table read
    ///          concurrently by diagnostics, and per-entry teardown there needs
    ///          its own quiescence protocol. Line indices are small next to the
    ///          file buffer, which is what this reclaims. Revisit if line-table
    ///          residency ever shows up in a profile.
    ///
    /// \return false if the fid was never loaded.
    pub fn release(self, file_id: FileID) -> bool {
        if (file_id as usize) >= self._files.size() {
            return false
        }

        if self._files[file_id] == &null {
            return false
        }

        @destroy unsafe (self._files[file_id] as *SourceFile)
        self._files[file_id] = &null
        return true
    }

    ///
    /// \brief re-reads \p file_id from disk and rebuilds its line index.
    ///
    /// \details What a reparse of a CHANGED file does. Identity is kept: the
    ///          fid, and every index keyed on it, survives, so only this file's
    ///          bytes and line map are rebuilt   not the whole import graph.
    ///
    ///          Distinct from release(), which drops derived artifacts but
    ///          leaves the bytes alone, and from evict(), which drops the file
    ///          entirely. If the file did NOT change, none of the three is
    ///          needed   that is the point of stable identity.
    ///
    /// \warning Invalidates every SourceLocation into this file, and any token
    ///          or AST built from it. Callers must release those artifacts.
    ///
    /// \return false if unknown, virtual, or the re-read failed (previous
    ///         contents are kept in that case).
    ///
    pub fn invalidate(self, file_id: FileID) -> bool {
        var lock = kairo::std::LockGuard(self._load_mu)

        // A pool build may still be reading the current mapping, which the
        // re-map below destroys. The line table's own invalidate drains too,
        // but only after the bytes are already gone.
        self._line_table.drain_builds()

        if !self._vfile_mgr->invalidate(file_id) {
            return false
        }

        var path = Path()
        if (file_id as usize) < self._files.size() && self._files[file_id] != &null {
            path = self._files[file_id]->path
            @destroy unsafe (self._files[file_id] as *SourceFile)
            self._files[file_id] = &null
        } else {
            path = Path(self._vfile_mgr->get_info(file_id).path.full_path())
        }

        self._materialize(file_id, path)
        self._line_table.invalidate(file_id, self._bytes_of(file_id))
        return true
    }

    /// \brief invalidate() with the new bytes handed over instead of read
    ///        from the disk: an editor's buffer replacing what \p file_id
    ///        held, whichever of the disk or an earlier buffer that was.
    ///
    /// \note \p data is NOT copied (load_virtual's contract).
    ///
    /// \warning As invalidate(): every SourceLocation into the file, and any
    ///          token or AST built from it, is stale.
    pub fn replace_bytes(self,
                         file_id: FileID,
                         data:    kairo::std::ConstPtr<u8>,
                         size:    usize) -> bool {
        var lock = kairo::std::LockGuard(self._load_mu)
        self._line_table.drain_builds()

        var path = Path()
        if (file_id as usize) < self._files.size() && self._files[file_id] != &null {
            path = self._files[file_id]->path
        } else {
            path = Path(self._vfile_mgr->get_info(file_id).path.full_path())
        }

        if !self._vfile_mgr->replace_bytes(file_id, data, size) {
            return false
        }

        if (file_id as usize) < self._files.size() && self._files[file_id] != &null {
            @destroy unsafe (self._files[file_id] as *SourceFile)
            self._files[file_id] = &null
        }

        self._materialize(file_id, path)
        self._line_table.invalidate(file_id, self._bytes_of(file_id))
        return true
    }

    /// Is \p file_id's text a caller-owned buffer and not a mapping of its
    /// path? invalidate() refuses such a file.
    pub fn is_virtual(self, file_id: FileID) -> bool {
        return self._vfile_mgr->is_virtual(file_id)
    }

    ///
    /// \brief drops \p file_id completely: buffer, mapping, address range,
    ///        line index, and path identity.
    ///
    /// \details The rare path   the file was deleted, or memory is being
    ///          reclaimed. A reparse should call invalidate() instead; this
    ///          retires the fid permanently and a later load of the same path
    ///          gets a NEW one.
    ///
    /// \return false if \p file_id was not loaded.
    ///
    pub fn evict(self, file_id: FileID) -> bool {
        var lock = kairo::std::LockGuard(self._load_mu)

        if (file_id as usize) < self._files.size() {
            if self._files[file_id] != &null {
                @destroy unsafe (self._files[file_id] as *SourceFile)
                self._files[file_id] = &null
            }
        }

        self._line_table.drop_file(file_id)
        return self._vfile_mgr->evict(file_id)
    }

    /// \brief brackets a preprocessor walk, whose lex workers read the
    ///        VirtualFileManager unlocked. In a debug build an
    ///        invalidate/replace/evict between the two is an ICE and a load
    ///        that misses the cache is logged (VirtualFileManager::
    ///        _check_not_walking says why not an ICE yet). No-ops in release.
    pub fn begin_walk(self) {
        self._vfile_mgr->begin_walk()
    }

    pub fn end_walk(self) {
        self._vfile_mgr->end_walk()
    }

    /// Live line-table entries. Flat once the graph is loaded.
    fn line_table_files(self) -> usize {
        return self._line_table.file_count()
    }

    /// Distinct files mapped by the VirtualFileManager. Flat once loaded   a
    /// climbing count means identity is being re-minted per pass.
    fn mapped_files(self) -> usize {
        return self._vfile_mgr->file_count()
    }

    /// Times this file has been re-read. See VirtualFileManager::generation_of.
    fn generation_of(self, file_id: FileID) -> u32 {
        return self._vfile_mgr->generation_of(file_id)
    }

    ///
    /// \brief resolves line and column for a given SourceLocation.
    ///
    pub fn get_line_col(self, loc: SourceLocation) -> FullSourceLocation {
        var res     = self.resolve(loc)
        var file_id = res.fid
        var offset  = res.offset

        if file_id >= self._files.size() || self._files[file_id] == &null {
            kairo::Logger::warn(
                kairo::Logger::Stage::Driver,
                f"SourceManager::get_line_col: invalid fid={file_id}",
            )

            return FullSourceLocation()
        }

        return self._line_table.get_line_col(
            (file_id as u32),
            (offset as u32),
            Path(self.get_filename((file_id as u32)))
        )
    }

    ///
    /// \brief resolves line/column directly by file id and offset.
    ///
    fn get_line_col(self, file_id: FileID, offset: usize) -> FullSourceLocation {
        return self._line_table.get_line_col(
            file_id,
            (offset as u32),
            Path(self.get_filename(file_id))
        )
    }

    pub fn get_full_line(self, loc: SourceLocation) -> string {
        var range = self.get_line_range(loc)
        return self.get_text(range)
    }

    pub fn get_line_text(self, fid: FileID, line: u32) -> string {
        var line_start = self._line_table.get_line_offset(fid, line)
        var line_end   = self._line_table.get_line_end_offset(fid, line)
        if line_start == line_end {
            return ""
        }

        var line_range = self.get_range(
            fid,
            line_start as usize,
            ((line_end - line_start) as usize)
        )

        return self.get_text(line_range)
    }

    ///
    /// \brief resolves a SourceLocation -> file/offset pair.
    ///
    /// \return segment info `{fid, offset}` or invalid if not found.
    ///
    pub fn resolve(self, loc: SourceLocation) -> VirtualFileManager::SegmentResolve {
        return self._vfile_mgr->resolve_loc(loc)
    }

    ///
    /// \brief placeholder for async line index status.
    ///
    fn is_line_index_ready(self, file_id: FileID) -> bool {
        return false
    }

    ///
    /// \brief blocks until line index for file is ready.
    ///
    pub fn wait_for_line_index(self, file_id: FileID) {
        self._line_table.wait_until_ready(file_id)
    }

    ///
    /// \brief checks that \p fid's buffer is well-formed UTF-8, reporting
    ///        S072E once per maximal run of invalid bytes.
    ///
    /// \details Runs once per file, before lexing, and is linear: ASCII is
    ///          skipped 16 bytes at a time and only non-ASCII reaches the
    ///          decoder. A run is merged into one diagnostic because a single
    ///          corrupt character is often several bad bytes (`ED A0 80`),
    ///          and one error per byte would bury the real ones.
    ///
    ///          The verdict is cached on the SourceFile, so the lexer opening
    ///          the same fid again (dependency scan, then the real parse)
    ///          neither rescans nor re-reports. An invalid file is still
    ///          lexed; the lexer then reports what it can, and max-errors
    ///          caps the total.
    ///
    ///          Everything downstream that counts code points (LowerSynth::
    ///          cp_count) relies on this having run.
    ///
    /// \return true if the buffer is valid UTF-8 (or the fid is unknown).
    pub fn validate_utf8(self, fid: FileID) -> bool {
        var lock = kairo::std::LockGuard(self._load_mu)
        if (fid as usize) >= self._files.size() || self._files[fid] == &null {
            return true
        }

        if self._files[fid]->utf8_checked {
            return self._files[fid]->utf8_valid
        }

        self._files[fid]->utf8_checked = true

        var buf = self._files[fid]->buffer->bytes()
        const      base: kairo::std::ConstPtr<u8> = buf.data()
        const      end:  kairo::std::ConstPtr<u8> = base + buf.size()
        var unsafe *p                             = base
        var        valid                          = true

        while p < end {
            p = kairo::skip_ascii_simd(p, end)
            if p >= end {
                break
            }

            var d = kairo::decode_utf8_lut(p, (end - p) as usize)
            if d.ok {
                p += d.len
                continue
            }

            var unsafe *run = p
            while p < end {
                var r = kairo::decode_utf8_lut(p, (end - p) as usize)
                if r.ok {
                    break
                }

                p += r.len // always 1 on failure with bytes remaining
            }

            valid = false
            var off   = ((run - base) as usize)
            var len   = ((p - run) as usize)
            var range = self.get_range(fid, off, len)
            var hex: string = string(
                unsafe ((llvm::formatv(r"{0:X-2}", run[0] as u32).str().c_str() as unsafe *const u8) as *const u8),
            )

            var b = self._diag->report(
                DiagID::S072E,
                range.start,
                f"invalid UTF-8 byte 0x{hex} in source",
            )

            b.first(range)
            b.emit()
        }

        self._files[fid]->utf8_valid = valid
        return valid
    }

    ///
    /// \brief retrieves file buffer as MemoryBuffer view.
    ///
    pub fn get_buffer(self, file_id: FileID) -> MemoryBuffer? {
        if (file_id as usize) >= self._files.size() || self._files[file_id] == &null {
            return null
        }

        return self._files[file_id]->buffer->bytes()
    }

    ///
    /// \brief returns full path for file id.
    ///
    pub fn get_filename(self, file_id: FileID) -> string {
        if (file_id as usize) >= self._files.size() || self._files[file_id] == &null {
            return "<invalid>"
        }

        return self._files[file_id]->path.full_path()
    }

    ///
    /// \brief returns the DIRECTORY holding a file, for anchored import
    ///        resolution (`self::`, `module::`; ImportResolver::resolve_module_in).
    /// \return the parent directory, or an empty Path when \p file_id is
    ///         unknown (callers treat that as "no importing file").
    ///
    pub fn get_file_dir(self, file_id: FileID) -> Path {
        var out = Path()
        if (file_id as usize) >= self._files.size() || self._files[file_id] == &null {
            return out
        }

        var full   = self._files[file_id]->path
        var parent = full.parent_path()
        if !parent.empty() {
            out = Path(parent, false)
        }

        return out
    }

    ///
    /// \brief fid of an ALREADY-LOADED \p path, or u32(-1). Never loads.
    ///
    /// \details For a caller that meets a file by path from outside Kairo (a
    ///          clang FileID behind a PCH) and must not mint a fid for a file
    ///          Kairo never loaded. load_file answers a known path the same
    ///          way, but loads an unknown one.
    ///
    pub fn find_fid(self, const path: Path) -> FileID {
        var lock = kairo::std::LockGuard(self._load_mu)
        return self._vfile_mgr->fid_for_path(path)
    }

    ///
    /// \brief returns logical path for SourceLocation
    ///
    pub fn get_filename(self, loc: SourceLocation) -> string {
        var res = self.resolve(loc)
        return self.get_filename((res.fid as u32))
    }

    ///
    /// \brief returns logical path for SourceRange
    ///
    pub fn get_filename(self, range: SourceRange) -> string {
        var res = self.resolve(range.start)
        return self.get_filename((res.fid as u32))
    }

    ///
    /// \brief returns file extension (if any).
    ///
    fn get_file_extension(self, file_id: FileID) -> string? {
        if (file_id as usize) >= self._files.size() || self._files[file_id] == &null {
            return null
        }

        return self._files[file_id]->path.extension()
    }

    ///
    /// \brief fetches file view handle from VirtualFileManager.
    ///
    pub fn get_file_view(self, fid: FileID) -> VirtualFileManager::FileHandle {
        return self._vfile_mgr->get_file_view(fid)
    }

    ///
    /// \brief resolves a raw pointer back to file id + offset.
    ///
    fn resolve_ptr(self, ptr: kairo::std::ConstPtr<u8>)
        -> VirtualFileManager::SegmentResolve {
        return self._vfile_mgr->resolve_ptr(unsafe (ptr as unsafe *u8))
    }

    ///
    /// \brief expands a SourceLocation into a FullSourceLocation.
    ///
    pub fn get_full_loc(self, loc: SourceLocation) -> FullSourceLocation {
        if !loc.is_valid() {
            return FullSourceLocation()
        }

        var res = self.resolve(loc)
        var lc  = self.get_line_col((res.fid as FileID), res.offset)

        return FullSourceLocation(res.fid, lc.line, lc.column, lc.path)
    }

    ///
    /// \brief convenience wrapper to get SourceLocation from fid+offset.
    ///
    pub fn get_loc(self, fid: FileID, off: usize) -> SourceLocation {
        return self._vfile_mgr->get_loc(fid, off)
    }

    fn get_loc(self, ptr: kairo::std::restrict_ptr<u8>) -> SourceLocation {
        return self._vfile_mgr->get_loc(ptr)
    }

    ///
    /// \brief returns SourceRange for file id, offset, and length.
    ///
    pub fn get_range(self, fid: FileID, off: usize, len: usize) -> SourceRange {
        return self._vfile_mgr->get_range(fid, off, len)
    }

    ///
    /// \brief returns number of loaded files.
    ///
    pub fn file_count(self) -> usize {
        return self._files.size()
    }

    ///
    /// \brief returns total bytes of all loaded files.
    ///
    fn total_bytes(self) -> u64 {
        /// Precondition: the running total cannot overflow.
        return self._total_b
    }

    ///
    /// \brief retrieves a MemoryBuffer view for a SourceRange.
    ///
    pub fn get_view(self, range: SourceRange) -> MemoryBuffer {
        // degenerate/invalid ranges (EOF tokens, synthesized nodes, failed
        // resolution) must degrade to an empty view, never UB. every guard
        // below has been hit in practice   do not remove them.
        if !range.is_valid() {
            return MemoryBuffer()
        }

        var res     = self.resolve(range.start)
        var file_id = res.fid
        var offset  = res.offset
        var length  = ((range.end.raw() - range.start.raw()) as usize)

        if file_id >= self._files.size() {
            kairo::Logger::warn(
                kairo::Logger::Stage::Driver,
                f"SourceManager::get_view: unresolvable fid {file_id} (files={self._files.size()})",
            )

            return MemoryBuffer()
        }

        var unsafe *file = self._files[file_id]
        if file == &null || file->buffer == &null {
            kairo::Logger::warn(
                kairo::Logger::Stage::Driver,
                f"SourceManager::get_view: null file/buffer for fid {file_id}",
            )

            return MemoryBuffer()
        }

        var buf = file->buffer->bytes()
        if offset >= buf.size() {
            return MemoryBuffer()
        }

        if offset + length >= buf.size() {
            length = buf.size() - offset
        }

        return MemoryBuffer(buf.data() + offset, length)
    }

    ///
    /// \brief retrieves a UTF-8 string for a SourceRange.
    ///
    /// \param range source range to fetch.
    /// \return UTF-8 string covering the range.
    ///
    /// \warning This is a very expensive operation. Use only for debugging.
    ///
    pub fn get_text(self, range: SourceRange) -> string {
        // a Kairo string is UTF-8 bytes, so the range is copied verbatim.
        // decoding to code points and pushing them back as u8 turned every non-ASCII character into one invalid byte
        // and shifted every offset after it.
        var mbuf = self.get_view(range)
        if mbuf.size() == 0 {
            return string()
        }

        return string(
            unsafe ((mbuf.data() as unsafe *const u8) as *const u8),
            mbuf.size() as usize,
        )
    }

    ///
    /// \brief prints loaded file metadata for debugging.
    ///
    fn dump_files(self) {
        io::println("=== SourceManager File Dump ===")

        for i in (0 as usize)..self._files.size() {
            var unsafe *file = self._files[i]
            io::println(f"[{i}] {file->path.full_path()}")
            io::println(f"     size: {file->size_bytes} bytes")
            io::println(f"     base offset: {file->base_offset}")
        }
    }

    ///
    /// \brief computes byte distance between two source locations.
    ///
    /// \param a first location.
    /// \param b second location.
    /// \return absolute byte distance.
    ///
    /// \warning returns 0 if locations are from different files.
    ///
    fn diff(self, a: SourceLocation, b: SourceLocation) -> usize {
        var res_a = self.resolve(a)
        var res_b = self.resolve(b)

        // different files -> distance is meaningless
        if res_a.fid != res_b.fid {
            return 0
        }

        return a.distance_to(b)
    }

    ///
    /// \brief checks if two locations are in the same file.
    ///
    pub fn same_file(self, a: SourceLocation, b: SourceLocation) -> bool {
        var res_a = self.resolve(a)
        var res_b = self.resolve(b)
        return res_a.fid == res_b.fid
    }

    ///
    /// \brief extracts a single character at a location.
    ///
    /// \param loc location to read from.
    /// \return UTF-32 codepoint, or 0 if invalid.
    ///
    pub fn get_char_at(self, loc: SourceLocation) -> u8 {
        var range = SourceRange::single(loc)
        var buf   = self.get_view(range)

        if buf.size() == 0 {
            return 0
        }

        var res = UTF8View::decode_utf8(buf.data(), buf.size())
        return (res.chr as u8)
    }

    ///
    /// \brief checks if a location points to whitespace.
    ///
    fn is_whitespace_at(self, loc: SourceLocation) -> bool {
        var chr = self.get_char_at(loc)
        return chr == (' ' as u8)
            || chr == ('\t' as u8)
            || chr == ('\n' as u8)
            || chr == ('\r' as u8)
    }

    ///
    /// \brief finds start of line containing location.
    ///
    /// \param loc location to search from.
    /// \return location at start of line.
    ///
    fn get_line_start(self, loc: SourceLocation) -> SourceLocation {
        if !loc.is_valid() {
            return loc
        }

        var res = self.resolve(loc)
        if res.fid == usize::MAX || res.fid >= self._files.size() {
            return loc
        }

        self._line_table.wait_until_ready((res.fid as u32))

        if !self._line_table.is_ready((res.fid as u32)) {
            return loc
        }

        var full_loc = self.get_line_col(loc)
        var line_start_offset = self._line_table.get_line_offset(
            (res.fid as u32),
            (full_loc.line as u32)
        )

        if line_start_offset == 0 && full_loc.line == 0 {
            return loc
        }

        return self.get_loc((res.fid as u32), line_start_offset as usize)
    }

    ///
    /// \brief finds end of line containing location.
    ///
    /// \param loc location to search from.
    /// \return location at end of line (before newline).
    ///
    fn get_line_end(self, loc: SourceLocation) -> SourceLocation {
        if !loc.is_valid() {
            return loc
        }

        var res = self.resolve(loc)
        if res.fid == usize::MAX || res.fid >= self._files.size() {
            return loc
        }

        self._line_table.wait_until_ready((res.fid as u32))

        if !self._line_table.is_ready((res.fid as u32)) {
            return loc
        }

        var full_loc = self.get_line_col(loc)
        var line_end_offset = self._line_table.get_line_end_offset(
            (res.fid as u32),
            (full_loc.line as u32)
        )

        if line_end_offset == 0 && full_loc.line == 0 {
            return loc
        }

        return self.get_loc((res.fid as u32), line_end_offset as usize)
    }

    ///
    /// \brief extracts entire line containing a location.
    ///
    /// \param loc any location on the line.
    /// \return range covering the full line.
    ///
    fn get_line_range(self, loc: SourceLocation) -> SourceRange {
        var start = self.get_line_start(loc)
        var end   = self.get_line_end(loc)
        return SourceRange::from_bounds(start, end)
    }

    ///
    /// \brief checks if range spans multiple lines.
    ///
    fn is_multiline(self, range: SourceRange) -> bool {
        var start_line = self.get_line_col(range.start).line
        var end_line   = self.get_line_col(range.end).line
        return start_line != end_line
    }

    pub fn get_fid(self, loc: SourceLocation) -> FileID {
        var res = self.resolve(loc)
        return (res.fid as u32)
    }

    pub fn get_fid(self, range: SourceRange) -> FileID {
        var res = self.resolve(range.start)
        return (res.fid as u32)
    }

    pub fn get_offset(self, loc: SourceLocation) -> usize {
        var res = self.resolve(loc)
        return res.offset
    }

    fn get_offset(self, range: SourceRange) -> usize {
        var res = self.resolve(range.start)
        return res.offset
    }

    pub fn get_file_size(self, fid: FileID) -> usize {
        if (fid as usize) >= self._files.size() || self._files[fid] == &null {
            return 0
        }

        return self._files[fid]->size_bytes
    }

    fn get_file_size(self, loc: SourceLocation) -> usize {
        var res = self.resolve(loc)
        return self.get_file_size((res.fid as u32))
    }

    ///
    /// \brief resets the manager to initial state.
    ///
    /// \details
    /// destroys all loaded files, resets byte counter and line table.
    /// also resets the underlying VirtualFileManager.
    /// used for test isolation.
    ///
    pub fn reset(self) {
        self._line_table.shutdown()
        kairo::Logger::debug(
            kairo::Logger::Stage::Driver,
            f"SourceManager::reset: releasing {self._files.size()} files, {self._total_b}B total",
        )

        for var f: *SourceFile? in self._files {
            if f != &null {
                @destroy unsafe (f as *SourceFile)
            }
        }

        self._files.clear()

        self._total_b = 0
        self._vfile_mgr->reset()

        // reinitialize line table if needed
        self._line_table.reset()
    }
}

pub fn Test() -> i32 {
    var unsafe *pool = kairo::std::create<ThreadPool>(4)
    var        diag  = DiagEngine()
    var unsafe *vfm  = kairo::std::create<VirtualFileManager>(&diag)
    var unsafe *sm   = kairo::std::create<SourceManager>(pool, vfm, &diag)

    finally {
        kairo::std::destroy(sm)
        kairo::std::destroy(vfm)
        kairo::std::destroy(pool)
    }

    var suite = Assert("SourceManager Multi-File Tests")

    // HELPERS

    static data0: cxx::std::string
    static data1: cxx::std::string

    var file0_str = "hello world\nline two\n"
    var file1_str = "module Foo {\n    macro mac! { 10 }\n}\n"

    var nd0 = file0_str
    data0 = kairo::std::to_std_string(nd0)
    var nd1 = file1_str
    data1 = kairo::std::to_std_string(nd1)

    var fid0 = sm->load_virtual(
        Path("test_file0.k", false),
        unsafe (data0.data() as kairo::std::ConstPtr<u8>),
        file0_str.size(),
    )

    var fid1 = sm->load_virtual(
        Path("test_file1.k", false),
        unsafe (data1.data() as kairo::std::ConstPtr<u8>),
        file1_str.size(),
    )

    // FILE REGISTRATION

    suite.equal<string>(
        "fid0 is 0",
        "pass",
        fn () -> string {
            if fid0 != 0 {
                return f"expected fid0=0, got {fid0}"
            }

            return "pass"
        },
    )

    suite.equal<string>(
        "fid1 is 1",
        "pass",
        fn () -> string {
            if fid1 != 1 {
                return f"expected fid1=1, got {fid1}"
            }

            return "pass"
        },
    )

    suite.equal<string>(
        "total bytes = sum of file sizes",
        "pass",
        fn () -> string {
            var expected = file0_str.size() + file1_str.size()
            var actual   = sm->total_bytes()
            if actual != (expected as u64) {
                return f"expected total_bytes={expected}, got {actual}"
            }

            return "pass"
        },
    )

    // GET_LOC / RESOLVE ROUND-TRIP: FILE 0

    suite.equal<string>(
        "file0: get_loc(0) resolves to fid=0 offset=0",
        "pass",
        fn () -> string {
            var loc = sm->get_loc(fid0, 0)
            var res = sm->resolve(loc)
            if res.fid != 0 {
                return f"fid: expected 0, got {res.fid}"
            }

            if res.offset != 0 {
                return f"offset: expected 0, got {res.offset}"
            }

            return "pass"
        },
    )

    suite.equal<string>(
        "file0: get_loc(5) resolves to fid=0 offset=5",
        "pass",
        fn () -> string {
            var loc = sm->get_loc(fid0, 5)
            var res = sm->resolve(loc)
            if res.fid != 0 {
                return f"fid: expected 0, got {res.fid}"
            }

            if res.offset != 5 {
                return f"offset: expected 5, got {res.offset}"
            }

            return "pass"
        },
    )

    suite.equal<string>(
        "file0: last byte resolves correctly",
        "pass",
        fn () -> string {
            var last = file0_str.size() - 1
            var loc  = sm->get_loc(fid0, last)
            var res  = sm->resolve(loc)
            if res.fid != 0 {
                return f"fid: expected 0, got {res.fid}"
            }

            if res.offset != last {
                return f"offset: expected {last}, got {res.offset}"
            }

            return "pass"
        },
    )

    // GET_LOC / RESOLVE ROUND-TRIP: FILE 1

    suite.equal<string>(
        "file1: get_loc(0) resolves to fid=1 offset=0",
        "pass",
        fn () -> string {
            var loc = sm->get_loc(fid1, 0)
            var res = sm->resolve(loc)
            if res.fid != 1 {
                return f"fid: expected 1, got {res.fid}"
            }

            if res.offset != 0 {
                return f"offset: expected 0, got {res.offset}"
            }

            return "pass"
        },
    )

    suite.equal<string>(
        "file1: get_loc(7) resolves to fid=1 offset=7",
        "pass",
        fn () -> string {
            var loc = sm->get_loc(fid1, 7)
            var res = sm->resolve(loc)
            if res.fid != 1 {
                return f"fid: expected 1, got {res.fid}"
            }

            if res.offset != 7 {
                return f"offset: expected 7, got {res.offset}"
            }

            return "pass"
        },
    )

    suite.equal<string>(
        "file1: last byte resolves correctly",
        "pass",
        fn () -> string {
            var last = file1_str.size() - 1
            var loc  = sm->get_loc(fid1, last)
            var res  = sm->resolve(loc)
            if res.fid != 1 {
                return f"fid: expected 1, got {res.fid}"
            }

            if res.offset != last {
                return f"offset: expected {last}, got {res.offset}"
            }

            return "pass"
        },
    )

    // GET_TEXT: FILE 0

    suite.equal<string>(
        "file0: get_text [0,5] = 'hello'",
        "pass",
        fn () -> string {
            var text = sm->get_text(sm->get_range(fid0, 0, 5))
            if text != "hello" {
                return f"expected 'hello', got '{text}'"
            }

            return "pass"
        },
    )

    suite.equal<string>(
        "file0: get_text [6,11] = 'world'",
        "pass",
        fn () -> string {
            var text = sm->get_text(sm->get_range(fid0, 6, 5))
            if text != "world" {
                return f"expected 'world', got '{text}'"
            }

            return "pass"
        },
    )

    suite.equal<string>(
        "file0: get_text [0,11] = 'hello world'",
        "pass",
        fn () -> string {
            var text = sm->get_text(sm->get_range(fid0, 0, 11))
            if text != "hello world" {
                return f"expected 'hello world', got '{text}'"
            }

            return "pass"
        },
    )

    // GET_TEXT: FILE 1

    suite.equal<string>(
        "file1: get_text [0,6] = 'module'",
        "pass",
        fn () -> string {
            var text = sm->get_text(sm->get_range(fid1, 0, 6))
            if text != "module" {
                return f"expected 'module', got '{text}'"
            }

            return "pass"
        },
    )

    suite.equal<string>(
        "file1: get_text [7,10] = 'Foo'",
        "pass",
        fn () -> string {
            var text = sm->get_text(sm->get_range(fid1, 7, 3))
            if text != "Foo" {
                return f"expected 'Foo', got '{text}'"
            }

            return "pass"
        },
    )

    suite.equal<string>(
        "file1: get_text [17,22] = 'macro'",
        "pass",
        fn () -> string {
            var text = sm->get_text(sm->get_range(fid1, 17, 5))
            if text != "macro" {
                return f"expected 'macro', got '{text}'"
            }

            return "pass"
        },
    )

    // GET_VIEW: BUFFER CORRECTNESS

    suite.equal<string>(
        "file0: get_view bytes match 'hello'",
        "pass",
        fn () -> string {
            var view = sm->get_view(sm->get_range(fid0, 0, 5))
            if view.data() == &null {
                return "view data is null"
            }

            if view.size() != 5 {
                return f"expected size 5, got {view.size()}"
            }

            // h=104 e=101 l=108 l=108 o=111
            if view.data()[0] != 104 {
                return f"byte 0: expected 104, got {view.data()[0]}"
            }

            if view.data()[1] != 101 {
                return f"byte 1: expected 101, got {view.data()[1]}"
            }

            if view.data()[4] != 111 {
                return f"byte 4: expected 111, got {view.data()[4]}"
            }

            return "pass"
        },
    )

    suite.equal<string>(
        "file1: get_view bytes match 'Foo'",
        "pass",
        fn () -> string {
            var view = sm->get_view(sm->get_range(fid1, 7, 3))
            if view.data() == &null {
                return "view data is null"
            }

            if view.size() != 3 {
                return f"expected size 3, got {view.size()}"
            }

            // F=70 o=111 o=111
            if view.data()[0] != 70 {
                return f"byte 0: expected 70, got {view.data()[0]}"
            }

            if view.data()[1] != 111 {
                return f"byte 1: expected 111, got {view.data()[1]}"
            }

            return "pass"
        },
    )

    // CROSS-FILE ISOLATION

    suite.equal<string>(
        "file0 locations never resolve to file1",
        "pass",
        fn () -> string {
            for i in (0 as usize)..file0_str.size() {
                var loc = sm->get_loc(fid0, i)
                var res = sm->resolve(loc)
                if res.fid != 0 {
                    return f"offset {i}: resolved to fid={res.fid}, expected 0"
                }
            }

            return "pass"
        },
    )

    suite.equal<string>(
        "file1 locations never resolve to file0",
        "pass",
        fn () -> string {
            for i in (0 as usize)..file1_str.size() {
                var loc = sm->get_loc(fid1, i)
                var res = sm->resolve(loc)
                if res.fid != 1 {
                    return f"offset {i}: resolved to fid={res.fid}, expected 1"
                }
            }

            return "pass"
        },
    )

    // GET_BUFFER

    suite.equal<string>(
        "get_buffer(fid0) returns correct size",
        "pass",
        fn () -> string {
            var buf? = sm->get_buffer(fid0)
            if buf == null {
                return "buffer is null"
            }

            var b? = buf
            if b.size() != file0_str.size() {
                return f"expected size {file0_str.size()}, got {b.size()}"
            }

            return "pass"
        },
    )

    suite.equal<string>(
        "get_buffer(fid1) returns correct size",
        "pass",
        fn () -> string {
            var buf? = sm->get_buffer(fid1)
            if buf == null {
                return "buffer is null"
            }

            var b? = buf
            if b.size() != file1_str.size() {
                return f"expected size {file1_str.size()}, got {b.size()}"
            }

            return "pass"
        },
    )

    pool->wait_all()
    return 0
}
