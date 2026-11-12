/// --- The Kairo Project ---------- Support/FileIO/VirtualFileManager.k --- ///
///
///   VirtualFileManager: maps files into segments and resolves addresses.
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
ffi "c++" import "Native/KLog.hh"
ffi "c++" import "vector"
ffi "c++" import "llvm/ADT/StringMap.h"

import Diagnostic::Engine::DiagEngine
import Diagnostic::Registry::DiagID
import Location::SourceLocation::SourceLocation
import Location::SourceRange::SourceRange
import Memory::MappedFileBuffer::MappedFileBuffer
import Support::FileIO::Path::Path
import Support::Limits::U32_MAX

///
/// \file VirtualFileManager.k
/// \brief abstraction layer for managing mapped files and memory segments.
///
/// \details
/// `VirtualFileManager` provides a unified interface for handling memory-mapped
/// file regions used across the kairo compiler. it manages segmentation of large
/// files into 4 gb chunks, tracks their virtual identifiers, and provides lookup
/// utilities for translating between memory addresses, offsets, and `SourceLocation`s.
///
/// each file loaded through `register_file()` is split into one or more **segments**
/// (depending on file size). each segment maintains its own offset and mapping
/// through `MappedFileBuffer`. the class guarantees deterministic cleanup and
/// o(1) lookups by file id.
///
/// typical consumers include:
///   - `SourceManager` for source indexing and diagnostics
///   - `SourceLineTable` for line/column mapping
///   - compiler passes that require byte-level file access
///
/// \note
/// the manager does not synchronize concurrent access; external locking
/// or isolation is required if used across threads.
///

///
/// \class VirtualFileManager
/// \brief manages memory-mapped source files and derived virtual segments.
///
/// \details
/// handles file registration, segment mapping, pointer resolution, and translation
/// between raw offsets and `SourceLocation`s. the file manager abstracts low-level
/// i/o from compiler subsystems while maintaining cache locality and consistent
/// id-based lookups.
///
pub class VirtualFileManager {
    /// Indexed by fid. INVARIANT: no task that can overlap a registration
    /// reads this, directly or through get_buffer()/get_loc()/resolve_loc().
    /// register_file/register_virtual push onto it under
    /// SourceManager::_load_mu, and a reader without that lock can index it
    /// mid-reallocation and see a null Segment.
    ///
    /// The line-index build is queued by load_file itself, so it always
    /// overlaps the next load: it never reads this, and is handed the bytes
    /// instead   a MemoryBuffer view resolved under the lock. That view stays
    /// valid because the Segment it points into is heap-owned and only
    /// evict()/invalidate()/reset() free or re-map it, each after the line
    /// table has drained its builds.
    ///
    /// Lex/parse workers DO read this, unlocked. They are safe only because
    /// every registration happens on the driver before the walk starts (the
    /// DepScanner preloads the import graph); the walk's own load_file calls
    /// are cache hits. A worker-side load that missed the cache would break
    /// that, and would need this read path locked.
    priv var _segments: cxx::std::vector<unsafe *Self::Segment> = cxx::std::vector<unsafe *Self::Segment>()
    priv var _page_table: cxx::std::vector<u32> = cxx::std::vector<u32>() ///< page index -> segment index, 0xFFFFFFFF = gap/invalid.

    /// Canonical path -> fid. THE authority on file identity.
    ///
    /// This belongs here, at the layer that owns the mapping, and not in
    /// SourceManager as a linear scan over its _files vector. That vector is
    /// indexed by fid and release() nulls entries in place, so the scan
    /// would skip released files and re-register them under a BRAND NEW fid,
    /// re-mmapping and re-indexing the whole import graph on every reparse
    /// while the fid space, page table and line table grew without bound.
    ///
    /// Identity outlives artifacts: releasing a file's tokens or AST must not
    /// change what fid its path resolves to. Only evict() removes an entry.
    ///
    /// TODO: key on (dev, inode) rather than the path string, so a symlink and
    ///       its target do not map to two fids over the same bytes. Needs stat
    ///       plumbing through Path; the path key is correct for every case the
    ///       compiler hits today because callers canonicalize first.
    priv var _by_path:       llvm::StringMap<u32> ///< absolute path -> fid; probed with the path's bytes, never iterated
    priv var _staged:        llvm::StringMap<u32> ///< absolute path -> slot of a staged buffer (stage_overlay)
    priv var _staged_data:   cxx::std::vector<kairo::std::ConstPtr<u8>>
    priv var _staged_size:   cxx::std::vector<u64>
    priv var _diag:          *DiagEngine
    priv var _global_offset: usize                                      = 0
    priv var _next_fid:      u32                                        = 0

    /// The phase the _segments invariant above is about, made checkable:
    /// how many preprocessor walks are running (Preprocessor brackets
    /// WaveExecutor::run with begin_walk/end_walk). Registering or re-mapping
    /// while one runs is the race the invariant forbids   a worker indexing
    /// _segments mid-reallocation   so a debug build reports it at the
    /// offending call instead of as a rare null Segment somewhere else. A
    /// count, not a flag: the phases repeat (one walk per input, and a
    /// language server walks once per pass). Touched only in debug builds.
    priv var _walks: kairo::std::Atomic<u32> = kairo::std::Atomic<u32>(0)

    ///
    /// \class Segment
    /// \brief represents a single contiguous mapped file section.
    ///
    /// \details
    /// each `Segment` corresponds to one slice of a file, typically up to 4 gb
    /// in length. segments store metadata (path, offset, size) and own a
    /// `MappedFileBuffer` view of their region.
    ///
    class Segment {
        pub var fid:         u32              ///< unique file id for this segment.
        pub var path:        Path             ///< filesystem path to the file.
        pub var offset:      usize            ///< byte offset within the file.
        pub var size:        usize            ///< segment size in bytes.
        pub var buffer:      MappedFileBuffer ///< mapped region buffer.
        pub var global_base: usize            ///< cumulative offset in the global source space

        /// The mapping this segment views. OWNED   a segment is the lifetime
        /// of its mapping, so evict() and invalidate() can replace or drop one
        /// file's bytes without touching any other.
        ///
        /// Null for virtual segments: register_virtual attaches a caller-owned
        /// buffer, so there is nothing here to free or reload.
        pub var parent: unsafe *MappedFileBuffer = &null

        /// Bytes of global address space held at global_base, >= size.
        ///
        /// Reserved with slack so an edit that changes a file's length can be
        /// re-mapped IN PLACE, keeping the same base. Without slack every save
        /// would have to take a fresh range and abandon the old one, and the
        /// 4GB space would drain at one file-length per keystroke.
        pub var reserved: usize = 0

        /// Bumped on every invalidate. A SourceLocation is a raw offset into
        /// the global space with no room for a tag, so this is what lets a
        /// holder of a location captured before an edit find out that the
        /// bytes under it have been replaced.
        pub var generation: u32 = 0

        ///
        /// \brief default constructor (invalid segment).
        ///
        fn Segment(self) {
            self.fid         = 0
            self.offset      = 0
            self.size        = 0
            self.path        = Path()
            self.global_base = 0
        }

        ///
        /// \brief constructs a new segment with provided metadata.
        ///
        fn Segment(self, fid: u32, const path: Path, offset: usize, size: usize) {
            self.fid         = fid
            self.path        = path
            self.offset      = offset
            self.size        = size
            self.global_base = 0      // will be set by VirtualFileManager after creation
        }

        ///
        /// \brief cleanup hook; ensures mapped region is closed if valid.
        ///
        fn op finally (self) {
            if self.buffer.is_valid() {
                self.buffer.close()
            }

            // Owned since the parent moved into the segment; null for virtual
            // segments, where the bytes belong to the caller.
            if self.parent != &null {
                kairo::std::destroy(self.parent)
                self.parent = &null
            }
        }

        ///
        /// \brief converts segment info to human-readable string.
        ///
        fn op as (self) -> string {
            return f"Segment(fid: {self.fid}, path: {self.path.full_path()}, offset: {self.offset}, size: {self.size}, buffer: {self.buffer})"
        }

        ///
        /// \brief attaches a subregion of a parent buffer to this segment.
        ///
        /// \param parent base mapped file buffer.
        /// \param offset starting offset within parent.
        /// \param length number of bytes to map.
        ///
        fn attach(self, parent: unsafe *MappedFileBuffer, offset: usize, length: usize) {
            self.buffer.attach(parent, offset, length)
        }
    }


    ///
    /// \struct FileHandle
    /// \brief lightweight view representing full file content.
    ///
    /// \details
    /// returned by `get_file_view()`, it exposes a raw pointer and size
    /// covering the entire mapped file.
    ///
    pub struct FileHandle {
        pub const data: unsafe *u8 = &null ///< pointer to file data.
        pub var   size: usize      = 0     ///< size of file data in bytes.
    }

    ///
    /// \struct SegmentResolve
    /// \brief identifies a specific location within a mapped segment.
    ///
    pub struct SegmentResolve {
        pub var fid:    usize = 0 ///< segment file id.
        pub var offset: usize = 0 ///< byte offset within segment.
    }

    ///
    /// \struct SegmentInfo
    /// \brief metadata summary for a registered file segment.
    ///
    struct SegmentInfo {
        pub var path:   Path  = Path() ///< filesystem path of the segment.
        var     offset: usize = 0      ///< byte offset within the file.
        pub var size:   usize = 0      ///< size of the segment in bytes.
    }

    /// \brief a preprocessor walk starts: from here until end_walk(), lex
    ///        workers read _segments unlocked. Debug builds only.
    pub fn begin_walk(self) {
        eval if defined!(DEBUG) {
            self._walks.fetch_add(1, kairo::std::MemoryOrder::acq_rel)
        }
    }

    /// \brief the walk begin_walk() opened is over.
    pub fn end_walk(self) {
        eval if defined!(DEBUG) {
            self._walks.fetch_sub(1, kairo::std::MemoryOrder::acq_rel)
        }
    }

    /// \brief reports \p action, which grows or re-maps _segments, if it runs
    ///        while a walk reads them unlocked. Called only under
    ///        `eval if defined!(DEBUG)`, so a release build never formats
    ///        \p what.
    ///
    /// \details Re-mapping or dropping a file (invalidate, replace_bytes,
    ///          evict, reset) is an ICE: those belong between passes and
    ///          nothing is known to do one mid-walk. A registration is only
    ///          logged (a warning, which a debug build keeps in the log and
    ///          does not stream): the walk DOES register files today, when
    ///          an import resolves to a file the dependency scan did not load
    ///          (FileImportIndex::_resolve_greedy, e.g. the plain import of a
    ///          sibling file that R068E reports), so an ICE would turn that
    ///          diagnostic into a crash. Make it fatal once the walk stops
    ///          registering.
    priv fn _check_not_walking(self, action: string, const what: string, fatal: bool) {
        if self._walks.load(kairo::std::MemoryOrder::acquire) == 0 {
            return
        }

        var msg = f"VirtualFileManager::{action}({what}) during a preprocessor walk: lex workers read _segments unlocked, so nothing may register or re-map a file until the walk ends"
        if fatal {
            kairo::std::ice_fail(msg)
        }

        kairo::Logger::warn(kairo::Logger::Stage::Driver, msg)
    }

    ///
    /// \brief default constructor.
    ///
    fn VirtualFileManager(self, diag_engine: *DiagEngine) {
        self._next_fid      = 0
        self._global_offset = 0
        self._diag          = diag_engine
    }

    // Move-only: the destructor destroys every segment, so a copy would destroy
    // them twice. The source is left with none.
    @move fn VirtualFileManager(self, other: Self) {
        self._segments      = cxx::std::move(other._segments)
        self._page_table    = cxx::std::move(other._page_table)
        self._by_path       = cxx::std::move(other._by_path)
        self._staged        = cxx::std::move(other._staged)
        self._staged_data   = cxx::std::move(other._staged_data)
        self._staged_size   = cxx::std::move(other._staged_size)
        self._diag          = other._diag
        self._global_offset = other._global_offset
        self._next_fid      = other._next_fid
        other._segments.clear()
    }

    ///
    /// \brief destructor; releases all mapped segments and parent buffers.
    ///
    fn op finally (self) {
        // Each segment frees its own mapping; there is no side list.
        for var seg: unsafe *Segment in self._segments {
            if seg != &null {
                kairo::std::destroy(seg)
            }
        }

        self._segments.clear()
    }

    ///
    /// \brief registers a file for virtual management.
    ///
    /// \details
    /// memory-maps a file and splits it into 4 gb-aligned segments. each segment
    /// is assigned a unique file id and added to the manager.
    ///
    /// \param path file to map.
    /// \return base file id assigned to the first segment.
    ///
    /// \warning grows _segments, which may reallocate it. Nothing that can run
    ///          concurrently with this may index _segments; workers receive
    ///          the buffer instead. See the invariant there.
    ///
    pub fn register_file(self, const path: Path) -> u32 {
        var abs      = Path(path.full_path())
        var abs_full = abs.full_path()

        // Idempotent by path. A second register of a file already mapped hands
        // back the SAME fid rather than mapping it twice   see _by_path.
        var hit = self._by_path.find(kairo::sref(abs_full))
        if hit != self._by_path.end() {
            return hit->second
        }

        // Past the cache hit: everything below grows _segments.
        eval if defined!(DEBUG) {
            self._check_not_walking("register_file", abs_full, false)
        }

        // A buffer staged for this path (stage_overlay) is what the path
        // holds: a segment like a mapped file's in every way but its bytes,
        // made HERE so the file gets the fid its place in the load order
        // gives it, as the disk's would.
        var ov = self._staged.find(kairo::sref(abs_full))
        if ov != self._staged.end() {
            var k     = ov->second as usize
            var osize = self._staged_size[k] as usize
            var ores  = self._reserve_for(osize + 1)
            var oal   = self._global_offset + 0xFFF & ~(0xFFF as usize)
            if osize > (U32_MAX as usize) || oal + ores + 1 > (U32_MAX as usize) {
                self._diag->report(
                    DiagID::I102F,
                    f"cannot load '{abs_full}' ({osize}B): total source size would exceed the 4GB address space limit",
                ).emit()
                return u32::MAX
            }

            var ofid = self._next_fid
            self._next_fid += 1
            var unsafe *oseg = kairo::std::create<Self::Segment>(
                ofid,
                abs,
                0,
                osize,
            )

            oseg->reserved = ores
            self._align_global_offset()
            oseg->global_base = self._global_offset
            self._global_offset += ores
            var odata: kairo::std::ConstPtr<u8> = self._staged_data[k]
            oseg->buffer.attach_raw(unsafe (odata as unsafe *u8), osize)
            self._segments.push_back(oseg)
            self._map_pages(
                (self._segments.size() - 1) as u32,
                oseg->global_base,
                ores,
            )

            self._by_path[kairo::sref(abs_full)] = ofid
            return ofid
        }

        var unsafe *parent = kairo::std::create<MappedFileBuffer>()

        parent->load(unsafe &abs_full)

        if !parent->is_valid() {
            kairo::std::destroy(parent)
            kairo::Logger::error(
                kairo::Logger::Stage::Driver,
                f"VirtualFileManager::register_file: failed to map {abs_full}",
            )

            self._diag->report(DiagID::I102F, f"failed to map '{abs_full}'").emit()
            return u32::MAX
        }

        var total    = parent->bytes().size()
        var reserved = self._reserve_for(total)

        // projected end of this file in the global space, after alignment
        var aligned = self._global_offset + 0xFFF & ~(0xFFF as usize)
        if total > (U32_MAX as usize) || aligned + reserved + 1 > (U32_MAX as usize) {
            kairo::std::destroy(parent)
            self._diag->report(
                DiagID::I102F,
                f"cannot load '{abs_full}' ({total}B): total source size would exceed the 4GB address space limit",
            ).emit()
            return u32::MAX
        }

        if total > (U32_MAX as usize) {
            kairo::std::destroy(parent)
            self._diag->report(
                DiagID::I102F,
                f"'{abs_full}' is {total}B; source files are limited to 4GB",
            ).emit()
            return u32::MAX
        }

        var seg_fid = self._next_fid
        self._next_fid += 1

        var unsafe *seg = kairo::std::create<Self::Segment>(
            seg_fid,
            abs,
            0,
            total,
        )

        seg->parent   = parent   // segment owns its mapping from here
        seg->reserved = reserved

        self._align_global_offset()
        seg->global_base = self._global_offset
        self._global_offset += reserved
        seg->attach(parent, 0, total)
        self._segments.push_back(seg)

        // Map the whole RESERVED span, not just the current bytes: an edit that
        // grows the file re-attaches in place, and the pages it grows into have
        // to already resolve to this segment.
        self._map_pages(
            (self._segments.size() - 1) as u32,
            seg->global_base,
            reserved,
        )

        self._by_path[kairo::sref(abs_full)] = seg_fid
        return seg_fid
    }

    /// \brief the bytes register_file gives \p path when it is first
    ///        loaded, instead of mapping the disk: an unsaved buffer that
    ///        does not change the order files get their ids in (bind_path
    ///        over register_virtual mints the id at once, ahead of every
    ///        file loaded after it).
    ///
    /// \note \p data is NOT copied. Import resolution still probes the
    ///       disk for existence.
    pub fn stage_overlay(self, const path: Path, data: kairo::std::ConstPtr<u8>, size: usize) {
        var abs_full = Path(path.full_path()).full_path()
        self._staged[kairo::sref(abs_full)] = (self._staged_data.size() as u32)
        self._staged_data.push_back(data)
        self._staged_size.push_back(size as u64)
    }

    /// Address space to hold for a file of \p total bytes.
    ///
    /// 1.5x plus a 64KB floor, page-aligned. Slack is what makes an in-place
    /// re-map possible on save; the floor covers small files, where a
    /// proportional margin would be a few hundred bytes and every edit would
    /// spill. Cheap: the whole compiler tree is a few MB against a 4GB space.
    priv fn _reserve_for(self, total: usize) -> usize {
        var want = total + (total >> 1) + 64 * 1024
        return want + 0xFFF & ~(0xFFF as usize)
    }

    ///
    /// \brief registers a virtual (in-memory) file segment.
    ///
    /// \details
    /// creates a new segment that maps to the provided raw data buffer.
    /// useful for testing or synthetic source inputs.
    ///
    /// \param fake_path logical path to associate with the segment.
    /// \param data pointer to raw byte data.
    /// \param size size of the data buffer in bytes.
    /// \return file id assigned to the new segment.
    ///
    pub fn register_virtual(self,
                            const fake_path: Path,
                            data:            kairo::std::ConstPtr<u8>,
                            size:            usize) -> u32 {
        eval if defined!(DEBUG) {
            self._check_not_walking(
                "register_virtual",
                fake_path.full_path(),
                false,
            )
        }

        var seg_fid = self._next_fid
        self._next_fid += 1
        var unsafe *seg = kairo::std::create<Self::Segment>(
            seg_fid,
            Path(fake_path.full_path()),
            0,
            size,
        )

        self._align_global_offset()
        seg->global_base = self._global_offset
        self._global_offset += size + 1

        seg->buffer.attach_raw(unsafe (data as unsafe *u8), size)
        self._segments.push_back(seg)
        // size + 1: the END position (off == size) is a legal location, and
        // for a zero-byte segment it is the only one. Mapping `size` left an
        // empty virtual file with no pages at all, so its one location
        // resolved as a gap. The slot is already reserved (+1 above).
        self._map_pages(
            (self._segments.size() - 1) as u32,
            seg->global_base,
            size + 1,
        )

        return seg_fid
    }

    ///
    /// \brief retrieves the mapped buffer for a given file id.
    ///
    /// \return pointer to `MappedFileBuffer`, or `&null` if invalid.
    ///
    pub fn get_buffer(self, fid: u32) -> unsafe *MappedFileBuffer {
        if (fid as usize) >= self._segments.size() {
            return &null
        }

        if self._segments[fid] == &null { // retired by evict()
            return &null
        }

        return unsafe &self._segments[fid]->buffer
    }

    ///
    /// \brief retrieves metadata about a segment.
    ///
    /// \return path, offset, and size if valid; otherwise `<invalid>`.
    ///
    pub fn get_info(self, fid: u32) -> Self::SegmentInfo {
        if (fid as usize) >= self._segments.size() {
            return {
                .path:   Path("<invalid>", false),
                .offset: 0,
                .size:   0
            }
        }

        var unsafe *s = self._segments[fid]
        if s == &null { // retired by evict()
            return {
                .path:   Path("<evicted>", false),
                .offset: 0,
                .size:   0
            }
        }

        return {
            .path:   s->path,
            .offset: s->offset,
            .size:   s->size
        }
    }

    ///
    /// \brief returns a view of the entire file for a given base id.
    ///
    /// \details
    /// reconstructs the total byte span by summing all segments belonging to
    /// the same physical file.
    ///
    pub fn get_file_view(self, base_fid: u32) -> Self::FileHandle {
        if (base_fid as usize) >= self._segments.size() {
            return Self::FileHandle { data: &null, size: 0 }
        }

        var unsafe *seg0 = self._segments[base_fid]
        if seg0 == &null { // retired by evict()
            return Self::FileHandle { data: &null, size: 0 }
        }

        var total: usize = 0
        var path         = seg0->path.full_path()

        for var seg: *Segment? in self._segments {
            if seg == &null {
                continue
            }

            if seg->path.full_path() == path {
                total += seg->size
            }
        }

        return Self::FileHandle {
            data: unsafe (seg0->buffer.bytes().data() as unsafe *u8),
            size: total,
        }
    }

    ///
    /// \brief resolves a raw pointer into a file id and offset.
    ///
    /// \details
    /// finds which mapped segment the pointer belongs to, and computes its
    /// relative offset. aborts if pointer lies outside known regions.
    ///
    pub fn resolve_ptr(self, ptr: kairo::std::restrict_ptr<u8>) -> Self::SegmentResolve {
        for var seg: *Segment? in self._segments {
            if seg == &null { // retired by evict()
                continue
            }

            var unsafe *base = seg->buffer.bytes().data()
            var unsafe *end  = base + seg->size

            if ptr >= base && ptr < end {
                var off: usize = ((ptr - base) as usize)

                return {
                    .fid:    ((seg->fid) as usize),
                    .offset: off
                }
            }
        }

        kairo::Logger::fatal(
            kairo::Logger::Stage::Driver,
            f"VirtualFileManager::resolve_ptr: ptr out of bounds across {self._segments.size()} segments",
        )

        kairo::std::ice_fail( // TODO: This needs to use the diagnostic system instead of crashing
            f"VirtualFileManager: Pointer {unsafe (ptr as unsafe *void)} out of bounds",
        )
    }

    ///
    /// \brief converts a file id and offset into a `SourceLocation`.
    ///
    /// \details
    /// locates the corresponding segment and computes the encoded
    /// `SourceLocation` value.
    ///
    pub fn get_loc(self, fid: u32, off: usize) -> SourceLocation {
        if (fid as usize) >= self._segments.size() {
            kairo::Logger::fatal(
                kairo::Logger::Stage::Driver,
                f"VirtualFileManager::get_loc: invalid fid={fid} off={off} seg_count={self._segments.size()}",
            )

            kairo::std::ice_fail(
                f"VirtualFileManager: Invalid fid/offset pair (fid: {fid}, off: {off})",
            )
        }

        var unsafe *seg = self._segments[fid]
        if seg == &null {
            kairo::Logger::fatal(
                kairo::Logger::Stage::Driver,
                f"VirtualFileManager::get_loc: fid={fid} was evicted",
            )

            kairo::std::ice_fail(
                f"VirtualFileManager: location requested for an evicted fid ({fid})",
            )
        }

        if off > seg->size {
            kairo::Logger::fatal(
                kairo::Logger::Stage::Driver,
                f"VirtualFileManager::get_loc: off={off} exceeds segment size={seg->size} for fid={fid}",
            )

            kairo::std::ice_fail(
                f"VirtualFileManager: Offset out of segment bounds (fid: {fid}, off: {off})",
            )
        }

        var raw = seg->global_base + off + 1

        if raw > (U32_MAX as usize) {
            kairo::Logger::fatal(
                kairo::Logger::Stage::Driver,
                f"VirtualFileManager::get_loc: global source space exceeded 4GB (raw={raw})",
            )

            kairo::std::ice_fail(
                "VirtualFileManager: SourceLocation address space exhausted (4GB u32 cap)",
            )
        }

        return SourceLocation::from_raw(raw as u32)
    }

    /// just a pointer should also return a srouce location
    pub fn get_loc(self, ptr: kairo::std::restrict_ptr<u8>) -> SourceLocation {
        var res = self.resolve_ptr(ptr)
        return self.get_loc(res.fid as u32, res.offset)
    }

    ///
    /// \brief constructs a `SourceRange` covering a byte span.
    ///
    pub fn get_range(self, fid: u32, off: usize, len: usize) -> SourceRange {
        return SourceRange::from_bounds(
            self.get_loc(fid, off),
            self.get_loc(fid, off + len),
        )
    }


    ///
    /// \brief resolves a SourceLocation -> file/offset pair.
    ///
    /// \details
    /// o(1) page-table lookup. segments are 4 kb-aligned in the global
    /// source space, so every page maps to exactly one segment or to a
    /// gap (0xFFFFFFFF). gap hits mean a corrupted/stale location and
    /// resolve as invalid.
    ///
    pub fn resolve_loc(self, loc: SourceLocation) -> Self::SegmentResolve {
        var id = (loc.raw() as usize)
        if id == 0 {
            return { .fid: usize::MAX, .offset: 0 }
        }

        id -= 1 // SourceLocation is 1-based

        var page = id >> 12
        if page >= self._page_table.size() {
            return { .fid: usize::MAX, .offset: 0 }
        }

        var seg_index = self._page_table[page]
        if seg_index == u32::MAX {
            return { .fid: usize::MAX, .offset: 0 }
        }

        var unsafe *seg = self._segments[seg_index]
        if id > seg->global_base + seg->size { // was >=
            // location points into the alignment gap past this segment's end
            return { .fid: usize::MAX, .offset: 0 }
        }

        return {
            .fid:    ((seg->fid) as usize),
            .offset: id - seg->global_base
        }
    }

    ///
    /// \brief returns a human-readable dump of all managed segments.
    ///
    fn op as (self) -> string {
        var result = "VirtualFileManager(\n"
        result += "  _segments:\n"

        for var seg: *Segment? in self._segments {
            if seg == &null {
                result += "    <evicted>\n"
                continue
            }

            result += f"    {*seg}\n"
        }

        result += ")"
        return result
    }

    ///
    /// \brief resets the manager to initial state.
    ///
    /// \details
    /// destroys all segments and parent buffers, resets fid counter.
    /// used for test isolation.
    ///
    pub fn reset(self) {
        eval if defined!(DEBUG) {
            self._check_not_walking("reset", "", true)
        }

        kairo::Logger::debug(
            kairo::Logger::Stage::Driver,
            f"VirtualFileManager::reset: dropping {self._segments.size()} segments",
        )

        for var seg: unsafe *Segment in self._segments {
            if seg != &null {
                kairo::std::destroy(seg)
            }
        }

        self._segments.clear()

        self._next_fid = 0
        self._page_table.clear()
        self._by_path.clear()
        self._global_offset = 0
    }

    /// \brief fid for an already-registered path, or u32(-1).
    ///
    /// \details Lookup only   never maps. For callers that want to know
    ///          whether a file is known without loading it.
    pub fn fid_for_path(self, const path: Path) -> u32 {
        var abs_full = Path(path.full_path()).full_path()
        var hit      = self._by_path.find(kairo::sref(abs_full))
        if hit == self._by_path.end() {
            return u32::MAX
        }

        return hit->second
    }

    /// \brief makes \p path resolve to \p fid from now on.
    ///
    /// \details The unsaved-buffer overlay: a tool registers an editor's
    ///          bytes with register_virtual() under the file's REAL path, then
    ///          binds the path here, so a later register_file() / load_file()
    ///          of that path (the entry, or an import of it) gets the buffer
    ///          instead of mapping the disk. Import resolution still probes
    ///          the disk for existence, so the file must exist there; only its
    ///          contents are replaced.
    ///
    /// \pre Called before anything loads \p path. A path already mapped keeps
    ///      its old fid in every structure that recorded it.
    pub fn bind_path(self, const path: Path, fid: u32) {
        var abs_full = Path(path.full_path()).full_path()
        self._by_path[kairo::sref(abs_full)] = fid
    }

    /// Registered files. Distinct paths mapped, not passes run.
    pub fn file_count(self) -> usize { // StringMap counts in unsigned
        return self._by_path.size() as usize
    }

    /// \brief re-reads \p fid from disk, keeping its identity.
    ///
    /// \details The ONLY operation that legitimately changes a file's bytes.
    ///          The fid, and with it every index keyed on it, survives   this
    ///          is what makes a reparse cheap instead of a full re-registration
    ///          of the import graph.
    ///
    ///          Re-maps IN PLACE while the new contents fit the reserved span,
    ///          so the global base does not move and no address space is
    ///          abandoned. A file that outgrows its reservation takes a fresh
    ///          range at the end and leaves a hole   bounded by how often a
    ///          file grows past 1.5x, not by how often it is saved.
    ///
    /// \warning Every SourceLocation into \p fid taken before this call now
    ///          refers to replaced bytes. Check generation_of() to detect it.
    ///
    /// \return false if \p fid is unknown, virtual (caller owns the bytes), or
    ///         could not be re-mapped   in which case the OLD mapping is left
    ///         intact rather than leaving the segment with nothing.
    pub fn invalidate(self, fid: u32) -> bool {
        eval if defined!(DEBUG) {
            self._check_not_walking("invalidate", f"fid={fid}", true)
        }

        if (fid as usize) >= self._segments.size() {
            return false
        }

        var unsafe *seg = self._segments[fid]
        if seg == &null {
            return false
        }

        if seg->parent == &null { // virtual: not ours to reload
            return false
        }

        var abs_full = seg->path.full_path()

        // Load the replacement BEFORE dropping the old mapping: on a failed
        // re-read (file deleted mid-edit, transient I/O error) the segment
        // keeps working with stale-but-valid bytes.
        var unsafe *fresh = kairo::std::create<MappedFileBuffer>()
        fresh->load(unsafe &abs_full)
        if !fresh->is_valid() {
            kairo::std::destroy(fresh)
            kairo::Logger::warn(
                kairo::Logger::Stage::Driver,
                f"VirtualFileManager::invalidate: re-map failed for {abs_full}; keeping previous contents",
            )

            return false
        }

        var total = fresh->bytes().size()

        if total <= seg->reserved {
            kairo::std::destroy(seg->parent)
            seg->parent = fresh
            seg->size   = total
            seg->attach(fresh, 0, total)
            seg->generation += 1
            kairo::Logger::debug(
                kairo::Logger::Stage::Driver,
                f"VirtualFileManager::invalidate: fid={fid} re-mapped in place ({total}B of {seg->reserved}B reserved)",
            )

            return true
        }

        // Outgrew its reservation. Take a new range; the old one becomes a hole.
        var reserved = self._reserve_for(total)
        var aligned  = self._global_offset + 0xFFF & ~(0xFFF as usize)
        if total > (U32_MAX as usize) || aligned + reserved + 1 > (U32_MAX as usize) {
            kairo::std::destroy(fresh)
            self._diag->report(
                DiagID::I102F,
                f"cannot re-map '{abs_full}' ({total}B): total source size would exceed the 4GB address space limit",
            ).emit()
            return false
        }

        self._unmap_pages(seg->global_base, seg->reserved)

        self._align_global_offset()
        seg->global_base = self._global_offset
        self._global_offset += reserved
        seg->reserved = reserved

        kairo::std::destroy(seg->parent)
        seg->parent = fresh
        seg->size   = total
        seg->attach(fresh, 0, total)
        seg->generation += 1

        self._map_pages(fid, seg->global_base, reserved)
        kairo::Logger::debug(
            kairo::Logger::Stage::Driver,
            f"VirtualFileManager::invalidate: fid={fid} outgrew reservation, rebased to {seg->global_base}",
        )

        return true
    }

    /// \brief \p fid's bytes become a caller-owned buffer, keeping its
    ///        identity: invalidate() for a file whose new text is an
    ///        editor's buffer and not the disk's (Tooling/LiveCheck.k).
    ///
    /// \details A mapped segment gives up its mapping and becomes a virtual
    ///          one; a virtual one changes its view. Either way the segment
    ///          gets (or keeps) a RESERVED range with slack, as a mapped file
    ///          has: a virtual segment is registered with exactly its size,
    ///          and replacing its bytes at every keystroke would otherwise
    ///          take a fresh range each time and drain the 4GB space.
    ///
    /// \note \p data is NOT copied: it must outlive every use of \p fid,
    ///       or the next replace_bytes / invalidate of it.
    ///
    /// \return false if \p fid is unknown or the address space is full (the
    ///         old bytes are then kept).
    pub fn replace_bytes(self, fid: u32, data: kairo::std::ConstPtr<u8>, size: usize) -> bool {
        eval if defined!(DEBUG) {
            self._check_not_walking("replace_bytes", f"fid={fid}", true)
        }

        if (fid as usize) >= self._segments.size() {
            return false
        }

        var unsafe *seg = self._segments[fid]
        if seg == &null {
            return false
        }

        // What the segment holds of the global space today: its
        // reservation, or (a virtual segment never re-mapped) its size and
        // the END position.
        var held = seg->reserved
        if held == 0 {
            held = seg->size + 1
        }

        if seg->reserved == 0 || size + 1 > seg->reserved {
            var reserved = self._reserve_for(size + 1)
            var aligned  = self._global_offset + 0xFFF & ~(0xFFF as usize)
            if size > (U32_MAX as usize) || aligned + reserved + 1 > (U32_MAX as usize) {
                return false
            }

            self._unmap_pages(seg->global_base, held)
            self._align_global_offset()
            seg->global_base = self._global_offset
            self._global_offset += reserved
            seg->reserved = reserved
            self._map_pages(fid, seg->global_base, reserved)
        }

        if seg->buffer.is_valid() && seg->parent != &null {
            seg->buffer.close()
        }

        if seg->parent != &null {
            kairo::std::destroy(seg->parent)
            seg->parent = &null
        }

        seg->size = size
        seg->buffer.attach_raw(unsafe (data as unsafe *u8), size)
        seg->generation += 1
        return true
    }

    /// Is \p fid a caller-owned buffer (register_virtual, replace_bytes)
    /// rather than a mapping of its path?
    pub fn is_virtual(self, fid: u32) -> bool {
        if (fid as usize) >= self._segments.size() || self._segments[fid] == &null {
            return false
        }

        return self._segments[fid]->parent == &null
    }

    /// \brief drops \p fid entirely: mapping, address range, and identity.
    ///
    /// \details The rare path   a deleted file, or reclaiming under memory
    ///          pressure. NOT what a reparse does; a reparse invalidates.
    ///
    ///          The fid is retired, not recycled. _segments is indexed by fid
    ///          so the slot has to stay, and handing the number out again would
    ///          let a SourceLocation captured against the old file resolve
    ///          silently into an unrelated one. Retiring costs a vector slot;
    ///          recycling costs correctness.
    ///
    /// \return false if \p fid was not registered.
    pub fn evict(self, fid: u32) -> bool {
        eval if defined!(DEBUG) {
            self._check_not_walking("evict", f"fid={fid}", true)
        }

        if (fid as usize) >= self._segments.size() {
            return false
        }

        var unsafe *seg = self._segments[fid]
        if seg == &null {
            return false
        }

        self._unmap_pages(seg->global_base, seg->reserved)
        self._by_path.erase(kairo::sref(seg->path.full_path()))

        kairo::std::destroy(seg)
        self._segments[fid] = &null // retired, never reissued
        return true
    }

    /// Times \p fid has been invalidated. See Segment::generation.
    pub fn generation_of(self, fid: u32) -> u32 {
        if (fid as usize) >= self._segments.size() {
            return 0
        }

        if self._segments[fid] == &null {
            return 0
        }

        return self._segments[fid]->generation
    }

    ///
    /// \brief rounds _global_offset up to the next 4 KB page boundary.
    ///
    priv fn _align_global_offset(self) {
        self._global_offset = self._global_offset + 0xFFF & ~(0xFFF as usize)
    }

    ///
    /// \brief maps the pages spanned by [base, base + len) to a segment index.
    ///
    /// \details
    /// grows the page table as needed. pages created by growth but not
    /// covered by any segment (alignment gaps) hold 0xFFFFFFFF and resolve
    /// as invalid.
    ///
    /// \brief marks the pages spanned by [base, base + len) as unmapped.
    ///
    /// \details Inverse of _map_pages. Without this an evicted or rebased
    ///          segment's pages keep resolving to its old index, so a stale
    ///          SourceLocation reads a dead (or reused) segment instead of
    ///          failing cleanly.
    priv fn _unmap_pages(self, base: usize, len: usize) {
        if len == 0 {
            return
        }

        var first_page = base >> 12
        var last_page  = base + len >> 12

        for p in (first_page)..(last_page + 1) {
            if p < self._page_table.size() {
                self._page_table[p] = u32::MAX
            }
        }
    }

    priv fn _map_pages(self, seg_index: u32, base: usize, len: usize) {
        if len == 0 {
            return
        }

        var first_page = base >> 12
        var last_page  = base + len >> 12

        while self._page_table.size() <= last_page {
            self._page_table.push_back(u32::MAX)
        }

        for p in (first_page)..(last_page + 1) {
            self._page_table[p] = seg_index
        }
    }
}
