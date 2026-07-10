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
import Memory::MappedFileBuffer::*;
import Memory::MemoryBuffer::*;
import Location::SourceLocation::*;
import Location::SourceRange::*;
import Threading::ThreadPool::*;

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
    
    priv var _parents:       vec::<own::<MappedFileBuffer>> = vec::<own::<MappedFileBuffer>>();
    priv var _segments:      vec::<own::<Segment>>          = vec::<own::<Segment>>();
    priv var _page_table:    vec::<u32> = vec::<u32>(); ///< page index -> segment index, 0xFFFFFFFF = gap/invalid.
    priv var _next_fid:      u32   = 0;
    priv var _global_offset: usize = 0;

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
    fn VirtualFileManager(self) {
        self._next_fid = 0;
        self._global_offset = 0;
    }

    ///
    /// \brief destructor; releases all mapped segments and parent buffers.
    ///
    fn op delete (self) {
        for seg: *Segment in _segments {
            if seg != &null {
                std::destroy(seg);
            }
        }

        _segments.clear();

        for p: *MappedFileBuffer in _parents {
            if p != &null {
                std::destroy(p);
            }
        }

        _parents.clear();
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
        var parent   = std::create::<MappedFileBuffer>();
        var abs_full = abs.full_path();

        parent->load(&abs_full);

        if !parent->is_valid() {
            std::destroy(parent);
            Logger::error(Logger::Stage::Driver,
                f"VirtualFileManager::register_file: failed to map {abs_full}");
            return u32(-1);
        }

        var total     = parent->bytes().size();
        var nseg: u32 = (static_cast::<u32>((total + 0x100000000 - 1) / 0x100000000)) if (total > 0) else 1;
        var base_fid  = self._next_fid;

        _parents.push_back(parent);

        for i in range::<u32>(0, nseg) {
            var start   = (i as usize) * 0x100000000;
            var remain  = total - start;
            var seg_len = (remain if remain < 0x100000000 else 0x100000000);
            var seg_fid = self._next_fid;
            self._next_fid += 1;
            var seg     = std::create::<Segment>(seg_fid, abs, start, seg_len);

            self._align_global_offset();
            seg->global_base = self._global_offset;
            self._global_offset += (seg_len + 1);

            seg->attach(parent, start, seg_len);
            _segments.push_back(seg);
            self._map_pages(static_cast::<u32>(self._segments.size() - 1), seg->global_base, seg_len);
        }

        Logger::info(Logger::Stage::Driver, f"VirtualFileManager::register_file: fid={base_fid} path={abs_full} total={total}B nseg={nseg}");
        return base_fid;
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
        var total: usize = 0;
        var path = seg0->path.full_path();

        for seg: *Segment in _segments {
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
            std::crash(std::Error::RuntimeError(f"VirtualFileManager: Invalid fid/offset pair (fid: {fid}, off: {off})"));
        }

        var seg = self._segments[fid];

        if off > seg->size {
            Logger::fatal(Logger::Stage::Driver, f"VirtualFileManager::get_loc: off={off} exceeds segment size={seg->size} for fid={fid}");
            std::crash(std::Error::RuntimeError(f"VirtualFileManager: Offset out of segment bounds (fid: {fid}, off: {off})"));
        }

        var raw = seg->global_base + off + 1;

        if raw > 0xFFFFFFFF {
            Logger::fatal(Logger::Stage::Driver, f"VirtualFileManager::get_loc: global source space exceeded 4GB (raw={raw})");
            std::crash(std::Error::RuntimeError("VirtualFileManager: SourceLocation address space exhausted (4GB u32 cap)"));
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

        for p: *MappedFileBuffer in _parents {
            if p != &null {
                std::destroy(p);
            }
        }
        _parents.clear();

        self._next_fid = 0;
        self._page_table.clear();
        self._global_offset = 0;
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
