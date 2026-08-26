/// --- The Kairo Project ---------- Support/FileIO/VirtualFileManager.k --- ///
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

ffi "c++" import "Native/Types.hh";

import Support::FileIO::Path::*;
import Support::Limits::*;
import Memory::MappedFileBuffer::*;
import Memory::MemoryBuffer::*;
import Location::SourceLocation::*;
import Location::SourceRange::*;
import Threading::ThreadPool::*;
import Diagnostic::Engine::*;

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
class VirtualFileManager {
    class Segment; ///< forward declaration of Segment class.
    
    priv var _segments:      vec::<own::<Segment>>          = vec::<own::<Segment>>();
    priv var _page_table:    vec::<u32> = vec::<u32>(); ///< page index -> segment index, 0xFFFFFFFF = gap/invalid.

    /// Canonical path -> fid. THE authority on file identity.
    ///
    /// This belongs here, at the layer that owns the mapping, and not in
    /// SourceManager where it used to live as a linear scan over its _files
    /// vector. That vector is indexed by fid and release() nulls entries in
    /// place, so the scan skipped released files and re-registered them under
    /// a BRAND NEW fid   the whole import graph was re-mmap'd and re-indexed
    /// on every reparse, and the fid space, page table and line table grew
    /// without bound.
    ///
    /// Identity outlives artifacts: releasing a file's tokens or AST must not
    /// change what fid its path resolves to. Only evict() removes an entry.
    ///
    /// TODO: key on (dev, inode) rather than the path string, so a symlink and
    ///       its target do not map to two fids over the same bytes. Needs stat
    ///       plumbing through Path; the path key is correct for every case the
    ///       compiler hits today because callers canonicalize first.
    priv var _by_path:       map::<string, u32> = map::<string, u32>();
    priv var _diag:          obs::<DiagEngine>;
    priv var _global_offset: usize = 0;
    priv var _next_fid:      u32   = 0;

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
        pub var fid:    u32;              ///< unique file id for this segment.
        pub var path:   Path;             ///< filesystem path to the file.
        pub var offset: usize;            ///< byte offset within the file.
        pub var size:   usize;            ///< segment size in bytes.
        pub var buffer: MappedFileBuffer; ///< mapped region buffer.
        pub var global_base: usize;  ///< cumulative offset in the global source space

        /// The mapping this segment views. OWNED   a segment is the lifetime
        /// of its mapping, so evict() and invalidate() can replace or drop one
        /// file's bytes without touching any other. (Parents used to live in a
        /// side vector correlated only by insertion order, which no per-file
        /// operation could index into.)
        ///
        /// Null for virtual segments: register_virtual attaches a caller-owned
        /// buffer, so there is nothing here to free or reload.
        pub var parent: own::<MappedFileBuffer> = &null;

        /// Bytes of global address space held at global_base, >= size.
        ///
        /// Reserved with slack so an edit that changes a file's length can be
        /// re-mapped IN PLACE, keeping the same base. Without slack every save
        /// would have to take a fresh range and abandon the old one, and the
        /// 4GB space would drain at one file-length per keystroke.
        pub var reserved: usize = 0;

        /// Bumped on every invalidate. A SourceLocation is a raw offset into
        /// the global space with no room for a tag, so this is what lets a
        /// holder of a location captured before an edit find out that the
        /// bytes under it have been replaced.
        pub var generation: u32 = 0;

        ///
        /// \brief default constructor (invalid segment).
        ///
        fn Segment(self) {
            self.fid    = 0;
            self.offset = 0;
            self.size   = 0;
            self.path   = Path();
            self.global_base = 0;
        }

        ///
        /// \brief constructs a new segment with provided metadata.
        ///
        fn Segment(self, fid: u32, path: Path, offset: usize, size: usize) {
            self.fid    = fid;
            self.path   = path;
            self.offset = offset;
            self.size   = size;
            self.global_base = 0; // will be set by VirtualFileManager after creation
        }

        ///
        /// \brief cleanup hook; ensures mapped region is closed if valid.
        ///
        fn op delete (self) {
            if self.buffer.is_valid() {
                self.buffer.close();
            }
            // Owned since the parent moved into the segment; null for virtual
            // segments, where the bytes belong to the caller.
            if self.parent != &null {
                std::destroy(self.parent);
                self.parent = &null;
            }
        }

        ///
        /// \brief converts segment info to human-readable string.
        ///
        fn op as (self) -> string {
            return f"Segment(fid: {self.fid}, path: {self.path.full_path()}, offset: {self.offset}, size: {self.size}, buffer: {self.buffer})";
        }

        ///
        /// \brief attaches a subregion of a parent buffer to this segment.
        ///
        /// \param parent base mapped file buffer.
        /// \param offset starting offset within parent.
        /// \param length number of bytes to map.
        ///
        fn attach(self, parent: *MappedFileBuffer, offset: usize, length: usize) {
            self.buffer.attach(parent, offset, length);
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
    struct FileHandle {
        const data: *u8    = &null; ///< pointer to file data.
        var   size:  usize = 0;     ///< size of file data in bytes.
    }

    ///
    /// \struct SegmentResolve
    /// \brief identifies a specific location within a mapped segment.
    ///
    struct SegmentResolve {
        var fid:    usize  = 0; ///< segment file id.
        var offset: usize  = 0; ///< byte offset within segment.
    };

    ///
    /// \struct SegmentInfo
    /// \brief metadata summary for a registered file segment.
    ///
    struct SegmentInfo {
        var path:   Path   = Path(); ///< filesystem path of the segment.
        var offset: usize  = 0;      ///< byte offset within the file.
        var size:   usize  = 0;      ///< size of the segment in bytes.
    };

    ///
    /// \brief default constructor.
    ///
    fn VirtualFileManager(self, diag_engine: obs::<DiagEngine>) {
        self._next_fid      = 0;
        self._global_offset = 0;
        self._diag          = diag_engine;
    }

    ///
    /// \brief destructor; releases all mapped segments and parent buffers.
    ///
    fn op delete (self) {
        // Each segment frees its own mapping; there is no side list any more.
        for seg: *Segment in _segments {
            if seg != &null {
                std::destroy(seg);
            }
        }

        _segments.clear();
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
    fn register_file(self, path: Path) -> u32 {
        var abs      = Path(path.full_path());
        var abs_full = abs.full_path();

        // Idempotent by path. A second register of a file already mapped hands
        // back the SAME fid rather than mapping it twice   see _by_path.
        var hit = self._by_path.find(abs_full);
        if hit != self._by_path.end() {
            return hit->second;
        }

        var parent = std::create::<MappedFileBuffer>();

        parent->load(&abs_full);

        if !parent->is_valid() {
            std::destroy(parent);
            Logger::error(Logger::Stage::Driver,
                f"VirtualFileManager::register_file: failed to map {abs_full}");
            self._diag->report(DiagID::I102F,
                f"failed to map '{abs_full}\x27").emit();
            return u32(-1);
        }

        var total    = parent->bytes().size();
        var reserved = self._reserve_for(total);

        // projected end of this file in the global space, after alignment
        var aligned = (self._global_offset + 0xFFF) & (~usize(0xFFF));
        if (total > U32_MAX) || ((aligned + reserved + 1) > U32_MAX) {
            std::destroy(parent);
            self._diag->report(DiagID::I102F,
                f"cannot load '{abs_full}' ({total}B): total source size would exceed the 4GB address space limit"
            ).emit();
            return u32(-1);
        }

        if total > U32_MAX {
            std::destroy(parent);
            self._diag->report(DiagID::I102F,
                f"'{abs_full}' is {total}B; source files are limited to 4GB").emit();
            return u32(-1);
        }

        var seg_fid = self._next_fid;
        self._next_fid += 1;

        var seg = std::create::<Segment>(seg_fid, abs, 0, total);
        seg->parent   = parent;          // segment owns its mapping from here
        seg->reserved = reserved;

        self._align_global_offset();
        seg->global_base = self._global_offset;
        self._global_offset += reserved;
        seg->attach(parent, 0, total);
        _segments.push_back(seg);

        // Map the whole RESERVED span, not just the current bytes: an edit that
        // grows the file re-attaches in place, and the pages it grows into have
        // to already resolve to this segment.
        self._map_pages(static_cast::<u32>(self._segments.size() - 1), seg->global_base, reserved);

        self._by_path[abs_full] = seg_fid;
        return seg_fid;
    }

    /// Address space to hold for a file of \p total bytes.
    ///
    /// 1.5x plus a 64KB floor, page-aligned. Slack is what makes an in-place
    /// re-map possible on save; the floor covers small files, where a
    /// proportional margin would be a few hundred bytes and every edit would
    /// spill. Cheap: the whole compiler tree is a few MB against a 4GB space.
    priv fn _reserve_for(self, total: usize) -> usize {
        var want = total + (total >> 1) + (64 * 1024);
        return (want + 0xFFF) & (~usize(0xFFF));
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
    fn register_virtual(self, fake_path: Path, data: std::ConstPtr::<u8>, size: usize) -> u32 {
        var seg_fid = self._next_fid;
        self._next_fid += 1;
        var seg = std::create::<Segment>(seg_fid, Path(fake_path.full_path()), 0, size);

        self._align_global_offset();
        seg->global_base = self._global_offset;
        self._global_offset += (size + 1);

        seg->buffer.attach_raw(const_cast::<*u8>(data), size);
        self._segments.push_back(seg);
        self._map_pages(static_cast::<u32>(self._segments.size() - 1), seg->global_base, size);

        return seg_fid;
    }

    ///
    /// \brief retrieves the mapped buffer for a given file id.
    ///
    /// \return pointer to `MappedFileBuffer`, or `&null` if invalid.
    ///
    fn get_buffer(self, fid: u32) -> *MappedFileBuffer {
        if fid >= _segments.size() {
            return &null;
        }
        if _segments[fid] == &null {   // retired by evict()
            return &null;
        }

        return &(_segments[fid]->buffer);
    }

    ///
    /// \brief retrieves metadata about a segment.
    ///
    /// \return path, offset, and size if valid; otherwise `<invalid>`.
    ///
    fn get_info(self, fid: u32) -> SegmentInfo {
        if fid >= _segments.size() {
            return {
                .path:   Path("<invalid>", false),
                .offset: 0,
                .size:   0
            };
        }

        var s = _segments[fid];
        if s == &null {   // retired by evict()
            return {
                .path:   Path("<evicted>", false),
                .offset: 0,
                .size:   0
            };
        }

        return {
            .path:   s->path,
            .offset: s->offset,
            .size:   s->size
        };
    }

    ///
    /// \brief returns a view of the entire file for a given base id.
    ///
    /// \details
    /// reconstructs the total byte span by summing all segments belonging to
    /// the same physical file.
    ///
    fn get_file_view(self, base_fid: u32) -> FileHandle {
        if base_fid >= _segments.size() {
            return FileHandle{ data: &null, size: 0 };
        }

        var seg0 = _segments[base_fid];
        if seg0 == &null {   // retired by evict()
            return FileHandle{ data: &null, size: 0 };
        }

        var total: usize = 0;
        var path = seg0->path.full_path();

        for seg: *Segment in _segments {
            if seg == &null { continue; }
            if seg->path.full_path() == path {
                total += seg->size;
            }
        }

        return FileHandle{
            data: seg0->buffer.bytes().data(),
            size: total
        };
    }

    ///
    /// \brief resolves a raw pointer into a file id and offset.
    ///
    /// \details
    /// finds which mapped segment the pointer belongs to, and computes its
    /// relative offset. aborts if pointer lies outside known regions.
    ///
    fn resolve_ptr(self, ptr: std::restrict_ptr::<u8>) -> SegmentResolve {
        for seg: *Segment in _segments {
            if seg == &null { continue; }   // retired by evict()
            var base = seg->buffer.bytes().data();
            var end  = base + seg->size;
            
            if (ptr >= base) && (ptr < end) {
                var off: usize = ptr - base;
                
                return {
                    .fid:    seg->fid,
                    .offset: off
                };
            }
        }

        Logger::fatal(Logger::Stage::Driver, f"VirtualFileManager::resolve_ptr: ptr out of bounds across {self._segments.size()} segments");
        std::crash(std::Error::RuntimeError(f"VirtualFileManager: Pointer {ptr as unsafe *void} out of bounds")); // TODO: This needs to use the diagnostic system instead of crashing
    }

    ///
    /// \brief converts a file id and offset into a `SourceLocation`.
    ///
    /// \details
    /// locates the corresponding segment and computes the encoded
    /// `SourceLocation` value.
    ///
    fn get_loc(self, fid: u32, off: usize) -> SourceLocation {
        if fid >= self._segments.size() {
            Logger::fatal(Logger::Stage::Driver, f"VirtualFileManager::get_loc: invalid fid={fid} off={off} seg_count={self._segments.size()}");
            ICE_FAIL(f"VirtualFileManager: Invalid fid/offset pair (fid: {fid}, off: {off})");
        }

        var seg = self._segments[fid];
        if seg == &null {
            Logger::fatal(Logger::Stage::Driver, f"VirtualFileManager::get_loc: fid={fid} was evicted");
            ICE_FAIL(f"VirtualFileManager: location requested for an evicted fid ({fid})");
        }

        if off > seg->size {
            Logger::fatal(Logger::Stage::Driver, f"VirtualFileManager::get_loc: off={off} exceeds segment size={seg->size} for fid={fid}");
            ICE_FAIL(f"VirtualFileManager: Offset out of segment bounds (fid: {fid}, off: {off})");
        }

        var raw = seg->global_base + off + 1;

        if raw > U32_MAX {
            Logger::fatal(Logger::Stage::Driver, f"VirtualFileManager::get_loc: global source space exceeded 4GB (raw={raw})");
            ICE_FAIL("VirtualFileManager: SourceLocation address space exhausted (4GB u32 cap)");
        }

        return SourceLocation::from_raw(static_cast::<u32>(raw));
    }

    /// just a pointer should also return a srouce location
    fn get_loc(self, ptr: std::restrict_ptr::<u8>) -> SourceLocation {
        var res = self.resolve_ptr(ptr);
        return self.get_loc(static_cast::<u32>(res.fid), res.offset);
    }

    ///
    /// \brief constructs a `SourceRange` covering a byte span.
    ///
    fn get_range(self, fid: u32, off: usize, len: usize) -> SourceRange {
        return SourceRange::from_bounds(
            self.get_loc(fid, off),
            self.get_loc(fid, off + len)
        );
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
    fn resolve_loc(self, loc: SourceLocation) -> SegmentResolve {
        var id = static_cast::<usize>(loc.raw());
        if id == 0 {
            return { .fid: static_cast::<usize>(-1), .offset: 0 };
        }
        id -= 1; // SourceLocation is 1-based

        var page = id >> 12;
        if page >= self._page_table.size() {
            return { .fid: static_cast::<usize>(-1), .offset: 0 };
        }

        var seg_index = self._page_table[page];
        if seg_index == u32(-1) {
            return { .fid: static_cast::<usize>(-1), .offset: 0 };
        }

        var seg = self._segments[seg_index];
        if id > (seg->global_base + seg->size) {   // was >=
            // location points into the alignment gap past this segment's end
            return { .fid: static_cast::<usize>(-1), .offset: 0 };
        }

        return {
            .fid:    seg->fid,
            .offset: id - seg->global_base
        };
    }

    ///
    /// \brief returns a human-readable dump of all managed segments.
    ///
    fn op as (self) -> string {
        var result = "VirtualFileManager(\n";
        result += "  _segments:\n";

        for seg: *Segment in _segments {
            if seg == &null { result += "    <evicted>\n"; continue; }
            result += f"    {*seg}\n";
        }

        result += ")";
        return result;
    }

    ///
    /// \brief resets the manager to initial state.
    ///
    /// \details
    /// destroys all segments and parent buffers, resets fid counter.
    /// used for test isolation.
    ///
    fn reset(self) {
        Logger::debug(Logger::Stage::Driver, f"VirtualFileManager::reset: dropping {self._segments.size()} segments");

        for seg: *Segment in _segments {
            if seg != &null {
                std::destroy(seg);
            }
        }
        _segments.clear();

        self._next_fid = 0;
        self._page_table.clear();
        self._by_path.clear();
        self._global_offset = 0;
    }

    /// \brief fid for an already-registered path, or u32(-1).
    ///
    /// \details Lookup only   never maps. For callers that want to know
    ///          whether a file is known without loading it.
    fn fid_for_path(self, path: Path) -> u32 {
        var abs_full = Path(path.full_path()).full_path();
        var hit = self._by_path.find(abs_full);
        if hit == self._by_path.end() { return u32(-1); }
        return hit->second;
    }

    /// Registered files. Distinct paths mapped, not passes run.
    fn file_count(self) -> usize { return self._by_path.size(); }

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
    fn invalidate(self, fid: u32) -> bool {
        if fid >= self._segments.size() { return false; }

        var seg = self._segments[fid];
        if seg == &null         { return false; }
        if seg->parent == &null { return false; }   // virtual: not ours to reload

        var abs_full = seg->path.full_path();

        // Load the replacement BEFORE dropping the old mapping: on a failed
        // re-read (file deleted mid-edit, transient I/O error) the segment
        // keeps working with stale-but-valid bytes.
        var fresh = std::create::<MappedFileBuffer>();
        fresh->load(&abs_full);
        if !fresh->is_valid() {
            std::destroy(fresh);
            Logger::warn(Logger::Stage::Driver,
                f"VirtualFileManager::invalidate: re-map failed for {abs_full}; keeping previous contents");
            return false;
        }

        var total = fresh->bytes().size();

        if total <= seg->reserved {
            std::destroy(seg->parent);
            seg->parent = fresh;
            seg->size   = total;
            seg->attach(fresh, 0, total);
            seg->generation += 1;
            Logger::debug(Logger::Stage::Driver,
                f"VirtualFileManager::invalidate: fid={fid} re-mapped in place ({total}B of {seg->reserved}B reserved)");
            return true;
        }

        // Outgrew its reservation. Take a new range; the old one becomes a hole.
        var reserved = self._reserve_for(total);
        var aligned  = (self._global_offset + 0xFFF) & (~usize(0xFFF));
        if (total > U32_MAX) || ((aligned + reserved + 1) > U32_MAX) {
            std::destroy(fresh);
            self._diag->report(DiagID::I102F,
                f"cannot re-map '{abs_full}' ({total}B): total source size would exceed the 4GB address space limit"
            ).emit();
            return false;
        }

        self._unmap_pages(seg->global_base, seg->reserved);

        self._align_global_offset();
        seg->global_base = self._global_offset;
        self._global_offset += reserved;
        seg->reserved = reserved;

        std::destroy(seg->parent);
        seg->parent = fresh;
        seg->size   = total;
        seg->attach(fresh, 0, total);
        seg->generation += 1;

        self._map_pages(fid, seg->global_base, reserved);
        Logger::debug(Logger::Stage::Driver,
            f"VirtualFileManager::invalidate: fid={fid} outgrew reservation, rebased to {seg->global_base}");
        return true;
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
    fn evict(self, fid: u32) -> bool {
        if fid >= self._segments.size() { return false; }

        var seg = self._segments[fid];
        if seg == &null { return false; }

        self._unmap_pages(seg->global_base, seg->reserved);
        self._by_path.erase(seg->path.full_path());

        std::destroy(seg);
        self._segments[fid] = &null;   // retired, never reissued
        return true;
    }

    /// Times \p fid has been invalidated. See Segment::generation.
    fn generation_of(self, fid: u32) -> u32 {
        if fid >= self._segments.size() { return 0; }
        if self._segments[fid] == &null { return 0; }
        return self._segments[fid]->generation;
    }

    ///
    /// \brief rounds _global_offset up to the next 4 KB page boundary.
    ///
    priv fn _align_global_offset(self) {
        self._global_offset = (self._global_offset + 0xFFF) & (~usize(0xFFF));
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
        if len == 0 { return; }

        var first_page = base >> 12;
        var last_page  = (base + len) >> 12;

        for p in range::<usize>(first_page, last_page + 1) {
            if p < self._page_table.size() {
                self._page_table[p] = u32(-1);
            }
        }
    }

    priv fn _map_pages(self, seg_index: u32, base: usize, len: usize) {
        if len == 0 {
            return;
        }

        var first_page = base >> 12;
        var last_page = (base + len) >> 12;

        while self._page_table.size() <= last_page {
            self._page_table.push_back(u32(-1));
        }

        for p in range::<usize>(first_page, last_page + 1) {
            self._page_table[p] = seg_index;
        }
    }
}
