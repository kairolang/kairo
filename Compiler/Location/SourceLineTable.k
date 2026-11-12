/// --- The Kairo Project ------------------- Location/SourceLineTable.k --- ///
///
///   SourceLineTable: per-file newline offsets for line and column lookup.
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
ffi "c++" import "Native/KShims.hh"
ffi "c++" import "vector"
ffi "c++" import "thread"
ffi "c++" import "chrono"
ffi "c++" import "bit"

import Location::FullSourceLocation::FullSourceLocation
import Memory::MemoryBuffer::MemoryBuffer
import Support::FileIO::Path::Path
import std::c_char

///
/// \file SourceLineTable.hlx
/// \brief simd-optimized source line index for fast line/column resolution.
///
/// \details
/// `SourceLineTable` maintains a global, atomic table mapping file offsets
/// to line starts. each file gets its own entry (`FileEntry`) containing
/// a vector of newline offsets and metadata.
///
/// the table supports both incremental updates (by the lexer) and full
/// parallel construction (via the thread pool). builds are SIMD-optimized
/// for x86 (AVX512/AVX2/SSE2) and ARM (NEON) architectures with fallback
/// scalar logic.
///
/// key properties:
///   - all accesses are atomic; concurrent readers are safe.
///   - background builds do not block readers.
///   - binary-search lookup provides O(log n) line resolution.
///
/// this table is used by `SourceManager` and `FullSourceLocation` to
/// provide accurate human-readable diagnostics.
///
/// \note
///   - no internal locking; relies on atomic ops and external sync for writes.
///   - cross-architecture simd support with conditional compilation.
///
/// \see SourceManager, FullSourceLocation, VirtualFileManager
///

///
/// \enum LineEntryState
/// \brief where one file's line index is, as a single atomic byte.
///
/// \details The entry records more than "ready or not" so that a file
///          nobody will ever index, one whose build is queued, and a second
///          claim on an in-flight build are distinguishable. Those are
///          exactly the states the loader/pool races live in,
///          so they are named, and the transitions below are the only
///          writers (each one asserts its source state in a debug build):
///
///            Absent/Stale -> Queued     try_claim(Queued)  reserve_build, under _load_mu
///            Absent/Stale -> Building   try_claim(Building) build_index, under _load_mu
///            Queued       -> Building   begin_scan         the pool task
///            Building     -> Ready      publish_lines      the scanner
///            any at rest  -> Stale      withdraw           invalidate, after the drain
///
///          Queued and Building are always counted in _builds, so after
///          _drain_builds() no entry may be in either.
///
pub enum LineEntryState derives u8 {
    Absent,   ///< registered; no build claimed it.
    Queued,   ///< reserve_build claimed it; a pool task will scan it.
    Building, ///< a scan is filling it.
    Ready,    ///< lines and line_count are published.
    Stale,    ///< invalidate withdrew the old index; the rebuild follows under _load_mu.
}

///
/// \class SourceLineTable
/// \brief maintains file-to-line offset mapping with simd acceleration.
///
/// each registered file gets a `FileEntry` with a precomputed vector of
/// line-start offsets. entries are indexed by file ID.
///
/// uses relaxed atomic storage to allow concurrent access and safe teardown.
///
pub class SourceLineTable {
    priv var _file_table: kairo::std::Atomic<unsafe *cxx::std::vector<unsafe *Self::FileEntry>> = kairo::std::Atomic<unsafe *cxx::std::vector<unsafe *Self::FileEntry>>(
        &null,
    )

    //                                  ^ owned     ^ owned if not null
    //                                if not null
    priv var _file_count: kairo::std::Atomic<u64> = kairo::std::Atomic<u64>(0)
    priv var _builds:     kairo::std::Atomic<u64> = kairo::std::Atomic<u64>(0)

    ///
    /// \class FileEntry
    /// \brief represents one file's line index data.
    ///
    /// stores file size, line count, file id, build state,
    /// and pointer to a vector of newline offsets.
    ///
    class FileEntry {
        pub var line_count: kairo::std::Atomic<u32> = kairo::std::Atomic<u32>(0) ///< number of lines.
        pub var file_size:  u32 ///< total size in bytes.
        pub var file_id:    u32 ///< file index in table.
        /// A LineEntryState. Written only by the transitions below; readers on
        /// any thread load it with acquire, which is what makes lines and
        /// line_count (stored before Ready with release) safe to read.
        priv var _state: kairo::std::Atomic<u8> = kairo::std::Atomic<u8>(
            LineEntryState::Absent as u8,
        )

        pub var lines: kairo::std::Atomic<unsafe *cxx::std::vector<u32>> = kairo::std::Atomic<unsafe *cxx::std::vector<u32>>(
            &null,
        )

        ///
        /// \brief default constructor.
        ///
        fn FileEntry(self) = default

        ///
        /// \brief copy constructor deleted to prevent copies.
        ///
        @copy fn FileEntry(self, const other: Self) = delete

        ///
        /// \brief copy assignment operator deleted to prevent copies.
        ///

        ///
        /// \brief constructs a FileEntry with given id and size.
        ///
        fn FileEntry(self, id: u32, size: u32) {
            self.file_id   = id
            self.file_size = size
        }

        ///
        /// \brief checks if the entry is ready (index built).
        ///
        fn is_ready(self) -> bool {
            return self._state.load(
                kairo::std::MemoryOrder::acquire,
            ) == (LineEntryState::Ready as u8)
        }

        /// The raw LineEntryState byte (acquire).
        fn state(self) -> u8 {
            return self._state.load(kairo::std::MemoryOrder::acquire)
        }

        /// Queued or Building: a build counted in _builds owns the entry.
        fn in_flight(self) -> bool {
            var s = self._state.load(kairo::std::MemoryOrder::acquire)
            return s == (LineEntryState::Queued as u8) || s == (LineEntryState::Building as u8)
        }

        ///
        /// \brief claims an entry at rest (Absent or Stale) for a build,
        ///        moving it to \p to (Queued or Building).
        ///
        /// \details A CAS rather than a test-then-store: an is_ready()
        ///          check would let a second claim through while the first build
        ///          is still in flight. Only the lock makes that impossible today,
        ///          so a debug build reports it instead of building twice.
        ///
        /// \return false if the entry is Ready (nothing to build) or in flight.
        fn try_claim(self, to: LineEntryState) -> bool {
            var from = LineEntryState::Absent as u8
            if self._state.compare_exchange_strong(&from, to as u8) {
                return true
            }

            from = LineEntryState::Stale as u8
            if self._state.compare_exchange_strong(&from, to as u8) {
                return true
            }

            eval if defined!(DEBUG) {
                if from != (LineEntryState::Ready as u8) {
                    kairo::std::ice_fail(
                        f"SourceLineTable: fid={self.file_id} claimed while its line index build is in flight (state {from as u32})",
                    )
                }
            }

            return false
        }

        ///
        /// \brief the pool task's start: Queued to Building.
        ///
        /// \return false (and an ICE in a debug build) if the entry is not
        ///         Queued: its reservation did not come from reserve_build, or
        ///         someone touched it while the task waited in the queue.
        fn begin_scan(self) -> bool {
            var from = LineEntryState::Queued as u8
            if self._state.compare_exchange_strong(
                &from,
                LineEntryState::Building as u8,
            ) {
                return true
            }

            eval if defined!(DEBUG) {
                kairo::std::ice_fail(
                    f"SourceLineTable: fid={self.file_id} reserved build ran, but the entry is not queued (state {from as u32})",
                )
            }

            return false
        }

        ///
        /// \brief publishes the computed line offsets: Building to Ready.
        ///
        /// \details lines and line_count are stored first, then the state with
        ///          release, so a reader that sees Ready sees both.
        fn publish_lines(self, lines: unsafe *cxx::std::vector<u32>, count: u32) {
            eval if defined!(DEBUG) {
                var s = self._state.load(kairo::std::MemoryOrder::acquire)
                if s != (LineEntryState::Building as u8) {
                    kairo::std::ice_fail(
                        f"SourceLineTable: fid={self.file_id} published without a claimed build (state {s as u32})",
                    )
                }
            }

            self.lines.store(lines, kairo::std::MemoryOrder::release)
            self.line_count.store(count, kairo::std::MemoryOrder::release)
            self._state.store(
                LineEntryState::Ready as u8,
                kairo::std::MemoryOrder::release,
            )
        }

        ///
        /// \brief withdraws the published index before its vector is freed:
        ///        any state at rest to Stale.
        ///
        /// \details Stored before line_count and lines are cleared, so a
        ///          reader that raced in sees "not ready" rather than a live
        ///          pointer to a vector about to be deleted. The caller has
        ///          drained _builds, so nothing may be in flight.
        fn withdraw(self) {
            eval if defined!(DEBUG) {
                if self.in_flight() {
                    kairo::std::ice_fail(
                        f"SourceLineTable: fid={self.file_id} invalidated while its line index build is in flight (state {self.state() as u32})",
                    )
                }
            }

            self._state.store(
                LineEntryState::Stale as u8,
                kairo::std::MemoryOrder::release,
            )
        }

        fn op as (self) -> string {
            return f"FileEntry(file_id:{self.file_id}, file_size:{self.file_size}, line_count:{self.line_count.load(kairo::std::MemoryOrder::acquire)}, ready:{self.is_ready()})"
        }
    }

    ///
    /// \brief constructs the global table with initial capacity.
    ///
    fn SourceLineTable(self) {
        var unsafe *tbl = unsafe (@create cxx::std::vector<unsafe *Self::FileEntry>() as unsafe *cxx::std::vector<unsafe *Self::FileEntry>)
        tbl->reserve(256)

        self._file_table.store(tbl, kairo::std::MemoryOrder::relaxed)
    }

    ///
    /// \brief destructor, cleans all file entries and buffers.
    ///
    fn op finally (self) {
        self.shutdown()
    }

    ///
    /// \brief releases all memory and resets table state.
    ///
    fn shutdown(self) {
        /// wait for any active builds to finish
        self._drain_builds()

        var unsafe *tbl = self._file_table.load(
            kairo::std::MemoryOrder::acquire,
        )

        if tbl == &null {
            return
        }

        for var f: *FileEntry? in *tbl {
            if f != &null {
                var unsafe *lines = f->lines.load(
                    kairo::std::MemoryOrder::relaxed,
                )

                if lines != &null {
                    @destroy unsafe (lines as *cxx::std::vector<u32>)
                }

                @destroy unsafe (f as *Self::FileEntry)
            }
        }

        @destroy unsafe (tbl as *cxx::std::vector<unsafe *Self::FileEntry>)

        self._file_table.store(&null, kairo::std::MemoryOrder::release)
        self._file_count.store(0, kairo::std::MemoryOrder::release)
    }

    ///
    /// \brief registers a new file entry in the line table.
    ///
    fn register_file(self, fid: u32, size: u32) {
        var unsafe *tbl = self._file_table.load(
            kairo::std::MemoryOrder::acquire,
        )

        if tbl == &null {
            return
        }

        if (fid as usize) >= tbl->size() {
            tbl->resize(fid + 1, &null)
        }

        var unsafe *existing = (*tbl)[fid]
        if existing != &null {
            kairo::Logger::debug(
                kairo::Logger::Stage::Driver,
                f"SourceLineTable::register_file: fid={fid} already registered",
            )

            return
        }

        var unsafe *entry = unsafe (@create Self::FileEntry(fid, size) as unsafe *Self::FileEntry)
        (*tbl)[fid] = entry
        self._file_count.fetch_add(1, kairo::std::MemoryOrder::relaxed)

        kairo::Logger::debug(
            kairo::Logger::Stage::Driver,
            f"SourceLineTable::register_file: fid={fid} size={size}B total_files={self._file_count.load(kairo::std::MemoryOrder::relaxed)}",
        )
    }

    /// Live file entries. One per distinct file; flat once the graph is loaded.
    fn file_count(self) -> usize {
        return self._file_count.load(kairo::std::MemoryOrder::relaxed) as usize
    }

    ///
    /// \brief blocks until no background build is touching the table.
    ///
    /// \details The reclamation protocol, such as it is. Entries are published
    ///          through atomics and read without a lock, so freeing one while a
    ///          build is in flight is a use-after-free.
    ///
    ///          There is deliberately no RCU/hazard-pointer scheme here. Freeing
    ///          a line index is a RARE event   a file actually changed on disk,
    ///          or was deleted   and it happens between passes, when nothing is
    ///          parsing. Draining is free at that point. This is the whole
    ///          reason the line index belongs to file IDENTITY and not to a
    ///          per-parse artifact: at per-pass frequency this would have to be
    ///          a real reclamation protocol, which is exactly the cost that
    ///          keeping line entries for a file's whole lifetime avoids.
    priv fn _drain_builds(self) {
        while self._builds.load(kairo::std::MemoryOrder::acquire) > 0 {
            cxx::std::this_thread::sleep_for(cxx::std::chrono::microseconds(50))
        }
    }

    ///
    /// \brief _drain_builds() for a caller about to unmap file bytes.
    ///
    /// \details SourceManager::invalidate needs the drain BEFORE the
    ///          VirtualFileManager replaces the mapping; invalidate() below
    ///          drains too, but by then the old bytes are already gone.
    ///
    fn drain_builds(self) {
        self._drain_builds()
    }

    ///
    /// \brief rebuilds \p fid's line index after its bytes changed.
    ///
    /// \details Keeps the entry (and therefore the fid) and swaps its contents.
    ///          Takes the size from \p bytes, since an edit changes it.
    ///
    /// \param bytes the NEW contents, resolved by the caller under
    ///        SourceManager::_load_mu.
    ///
    /// \return false if \p fid has no entry.
    ///
    fn invalidate(self, fid: u32, bytes: MemoryBuffer) -> bool {
        self._drain_builds()

        var unsafe *tbl = self._file_table.load(
            kairo::std::MemoryOrder::acquire,
        )

        if tbl == &null {
            return false
        }

        if (fid as usize) >= tbl->size() {
            return false
        }

        var unsafe *entry = (*tbl)[fid]
        if entry == &null {
            return false
        }

        // Unpublish before freeing, so a reader that raced in sees "not ready"
        // rather than a live pointer to a vector about to be deleted.
        entry->withdraw()
        entry->line_count.store(0, kairo::std::MemoryOrder::release)

        var unsafe *old = entry->lines.load(kairo::std::MemoryOrder::acquire)
        entry->lines.store(&null, kairo::std::MemoryOrder::release)
        if old != &null {
            @destroy unsafe (old as *cxx::std::vector<u32>)
        }

        entry->file_size = (bytes.size() as u32)

        self.build_index(fid, bytes)
        return true
    }

    ///
    /// \brief drops \p fid's entry entirely. Pairs with evict().
    ///
    /// \return false if \p fid had no entry.
    ///
    fn drop_file(self, fid: u32) -> bool {
        self._drain_builds()

        var unsafe *tbl = self._file_table.load(
            kairo::std::MemoryOrder::acquire,
        )

        if tbl == &null {
            return false
        }

        if (fid as usize) >= tbl->size() {
            return false
        }

        var unsafe *entry = (*tbl)[fid]
        if entry == &null {
            return false
        }

        eval if defined!(DEBUG) {
            if entry->in_flight() {
                kairo::std::ice_fail(
                    f"SourceLineTable: fid={fid} dropped while its line index build is in flight (state {entry->state() as u32})",
                )
            }
        }

        // Slot is nulled, not erased: the table is indexed by fid.
        (*tbl)[fid] = &null

        var unsafe *lines = entry->lines.load(kairo::std::MemoryOrder::acquire)
        if lines != &null {
            @destroy unsafe (lines as *cxx::std::vector<u32>)
        }

        @destroy unsafe (entry as *Self::FileEntry)

        self._file_count.fetch_sub(1, kairo::std::MemoryOrder::relaxed)
        return true
    }

    ///
    /// \brief builds \p fid's line index from \p bytes, on the calling thread.
    ///
    /// \details For callers holding SourceManager::_load_mu, which is what
    ///          makes looking the entry up by fid safe: register_file resizes
    ///          _file_table under that lock. A pool task must go through
    ///          reserve_build() / run_reserved_build() instead.
    ///
    fn build_index(self, fid: u32, bytes: MemoryBuffer) {
        self._builds.fetch_add(1, kairo::std::MemoryOrder::acq_rel)
        finally {
            self._builds.fetch_sub(1, kairo::std::MemoryOrder::acq_rel)
        }

        var unsafe *tbl = self._file_table.load(
            kairo::std::MemoryOrder::acquire,
        )

        if tbl == &null || (fid as usize) >= tbl->size() {
            return
        }

        // Synchronous, so the claim goes straight to Building. A Ready entry
        // is the legal no-op it always was.
        var unsafe *entry = (*tbl)[fid]
        if entry == &null || !entry->try_claim(LineEntryState::Building) {
            kairo::Logger::debug(
                kairo::Logger::Stage::Driver,
                f"SourceLineTable::build_index: entry missing or already ready, skipping",
            )

            return
        }

        self._scan(entry, bytes)
    }

    ///
    /// \brief claims \p fid's index build for a pool task. Runs on the
    ///        caller's thread, under SourceManager::_load_mu, BEFORE the task
    ///        is enqueued.
    ///
    /// \details Two things are settled here rather than in the task, because
    ///          the task runs without the lock:
    ///
    ///          - The entry is resolved now. The task must not index
    ///            _file_table, which register_file resizes under the lock.
    ///          - _builds is bumped now, not when the task starts. A task that
    ///            is still QUEUED already holds a view into the file's mapping;
    ///            counting it only once it ran would let _drain_builds return
    ///            and evict()/invalidate() unmap those bytes under it.
    ///
    ///          Every non-null return must reach exactly one
    ///          run_reserved_build(), or _drain_builds never returns.
    ///
    /// \return the entry to fill, or null if there is nothing to build.
    ///
    fn reserve_build(self, fid: u32) -> unsafe *Self::FileEntry {
        var unsafe *tbl = self._file_table.load(
            kairo::std::MemoryOrder::acquire,
        )

        if tbl == &null || (fid as usize) >= tbl->size() {
            return &null
        }

        // The claim and the count go together: an entry that reads Queued is
        // always one _drain_builds waits for. Bumped before the CAS so a
        // drain on another thread can never see Queued uncounted.
        var unsafe *entry = (*tbl)[fid]
        if entry == &null {
            return &null
        }

        self._builds.fetch_add(1, kairo::std::MemoryOrder::acq_rel)
        if !entry->try_claim(LineEntryState::Queued) {
            self._builds.fetch_sub(1, kairo::std::MemoryOrder::acq_rel)
            return &null
        }

        return entry
    }

    ///
    /// \brief the pool half of reserve_build(): fills \p entry from \p bytes,
    ///        then releases the reservation.
    ///
    fn run_reserved_build(self, entry: unsafe *Self::FileEntry, bytes: MemoryBuffer) {
        finally {
            self._builds.fetch_sub(1, kairo::std::MemoryOrder::acq_rel)
        }

        if !entry->begin_scan() {
            return
        }

        self._scan(entry, bytes)
    }

    ///
    /// \brief builds the line index for a file using simd or scalar fallback.
    ///
    /// \details
    /// scans for newline bytes (`'\n'`) and records their offsets.
    /// architecture-specific branches use AVX512, AVX2, SSE2, or NEON.
    /// automatically falls back to scalar if no simd is available.
    ///
    /// reads only \p entry and \p buff   never _file_table, never the
    /// VirtualFileManager   so it is safe off the loader's thread. the caller
    /// accounts for _builds and has moved \p entry to Building.
    ///
    priv fn _scan(self, entry: unsafe *Self::FileEntry, buff: MemoryBuffer) {
        var fid = entry->file_id

        if buff.data() == &null || buff.size() == 0 {
            var unsafe *lines = unsafe (@create cxx::std::vector<u32>() as unsafe *cxx::std::vector<u32>)
            lines->push_back(0)
            entry->publish_lines(lines, 1)
            return
        }

        var   data: unsafe *const u8 = buff.data()
        const size: usize            = buff.size()
        var   unsafe *lines = unsafe (@create cxx::std::vector<u32>() as unsafe *cxx::std::vector<u32>)

        lines->reserve(size / 64)
        lines->push_back(0)

        var count: u32   = 1
        var i:     usize = 0

        /// # simd scanning AVX512
        eval if defined!(__AVX512BW__) && defined!(__AVX512VL__) {
            const STRIDE: usize   = 64
            const nl:     __m512i = _mm512_set1_epi8(('\n' as u8) as c_char)

            for ; i + STRIDE <= size; i += STRIDE * 2 {
                kairo::prefetch_t0(
                    unsafe ((data + i + 512) as unsafe *const u8),
                )

                var c0: __m512i = _mm512_loadu_si512(
                    unsafe ((data + i) as unsafe *const __m512i),
                )

                var c1: __m512i = _mm512_loadu_si512(
                    unsafe ((data + i + STRIDE) as unsafe *const __m512i),
                )

                // _mm512_cmpeq_epi8_mask is a function-like macro, which FFI cannot
                // call. testn(x, x) sets a bit where x's byte is zero, so on
                // x = c ^ nl it is exactly the byte-equality mask.
                var x0: __m512i   = _mm512_xor_si512(c0, nl)
                var x1: __m512i   = _mm512_xor_si512(c1, nl)
                var m0: __mmask64 = _mm512_testn_epi8_mask(x0, x0)
                var m1: __mmask64 = _mm512_testn_epi8_mask(x1, x1)

                while m0 != 0 {
                    var offset = cxx::std::countr_zero(m0) as usize
                    lines->push_back((i + offset + 1) as u32)
                    ++count
                    m0 &= m0 - 1
                }

                while m1 != 0 {
                    var offset = cxx::std::countr_zero(m1) as usize
                    lines->push_back((i + STRIDE + offset + 1) as u32)
                    ++count
                    m1 &= m1 - 1
                }
            }
        } /// # simd scanning AVX2
        else if defined!(__AVX2__) {
            const STRIDE: usize   = 32
            const nl:     __m256i = _mm256_set1_epi8(('\n' as u8) as c_char)
            for ; i + STRIDE * 4 <= size; i += STRIDE * 4 {
                kairo::prefetch_t0(
                    unsafe ((data + i + 256) as unsafe *const c_char),
                )

                var c0: __m256i = _mm256_loadu_si256(
                    unsafe ((data + i) as unsafe *const __m256i),
                )

                var c1: __m256i = _mm256_loadu_si256(
                    unsafe ((data + i + 32) as unsafe *const __m256i),
                )

                var c2: __m256i = _mm256_loadu_si256(
                    unsafe ((data + i + 64) as unsafe *const __m256i),
                )

                var c3: __m256i = _mm256_loadu_si256(
                    unsafe ((data + i + 96) as unsafe *const __m256i),
                )

                var m0: u32 = _mm256_movemask_epi8(_mm256_cmpeq_epi8(c0, nl))
                var m1: u32 = _mm256_movemask_epi8(_mm256_cmpeq_epi8(c1, nl))
                var m2: u32 = _mm256_movemask_epi8(_mm256_cmpeq_epi8(c2, nl))
                var m3: u32 = _mm256_movemask_epi8(_mm256_cmpeq_epi8(c3, nl))

                var emit = fn (mask: u32, base: u32) {
                    while mask {
                        var offset: u32 = cxx::std::countr_zero(mask)

                        lines->push_back(base + offset + 1)
                        ++count
                        mask &= mask - 1
                    }
                }

                emit(m0, i)
                emit(m1, i + 32)
                emit(m2, i + 64)
                emit(m3, i + 96)
            }
        } /// # simd scanning SSE2
        else if defined!(__SSE2__) {
            const STRIDE: usize   = 16
            const nl:     __m128i = _mm_set1_epi8(('\n' as u8) as c_char)

            for ; i + STRIDE * 4 <= size; i += STRIDE * 4 {
                kairo::prefetch_t0(
                    unsafe ((data + i + 128) as kairo::std::ConstPtr<c_char>),
                )

                var c0: __m128i = _mm_loadu_si128(
                    unsafe ((data + i) as kairo::std::ConstPtr<__m128i>),
                )

                var c1: __m128i = _mm_loadu_si128(
                    unsafe ((data + i + 16) as kairo::std::ConstPtr<__m128i>),
                )

                var c2: __m128i = _mm_loadu_si128(
                    unsafe ((data + i + 32) as kairo::std::ConstPtr<__m128i>),
                )

                var c3: __m128i = _mm_loadu_si128(
                    unsafe ((data + i + 48) as kairo::std::ConstPtr<__m128i>),
                )

                var m0: u32 = (_mm_movemask_epi8(_mm_cmpeq_epi8(c0, nl))) as u32
                var m1: u32 = (_mm_movemask_epi8(_mm_cmpeq_epi8(c1, nl))) as u32
                var m2: u32 = (_mm_movemask_epi8(_mm_cmpeq_epi8(c2, nl))) as u32
                var m3: u32 = (_mm_movemask_epi8(_mm_cmpeq_epi8(c3, nl))) as u32

                // `count` is the caller's running total: by pointer, so the
                // increments land on it rather than on a copy.
                var emit = fn (mask: u32, base: u32) |lines, *count| {
                    while mask != 0 {
                        var offset: u32 = ((cxx::std::countr_zero(mask)) as u32)
                        lines->push_back(base + offset + 1)
                        ++(*count)
                        mask &= mask - 1
                    }
                }

                emit(m0, (i as u32))
                emit(m1, ((i + 16) as u32))
                emit(m2, ((i + 32) as u32))
                emit(m3, ((i + 48) as u32))
            }
        } /// # simd scanning NEON
        else if defined!(__ARM_NEON) {
            const STRIDE: usize      = 16
            const nl:     uint8x16_t = vdupq_n_u8(('\n' as u8))

            for ; i + STRIDE * 2 <= size; i += STRIDE * 2 {
                var c0:  uint8x16_t = kairo::neon_ld_u8(data + i)
                var c1:  uint8x16_t = kairo::neon_ld_u8(data + i + 16)
                var eq0: uint8x16_t = vceqq_u8(c0, nl)
                var eq1: uint8x16_t = vceqq_u8(c1, nl)
                var tmp: [u8; 32]

                kairo::neon_st_u8(unsafe &tmp[0], eq0)
                kairo::neon_st_u8(unsafe &tmp[16], eq1)

                for var j: usize = 0; j < 32; ++j {
                    if tmp[j] == 0xFF {
                        lines->push_back((i + j + 1) as u32)
                        ++count
                    }
                }
            }
        } /// # scalar fallback scan
        else {
            const STRIDE: usize = 0 // scalar only
        }

        // tail scan
        for ; i < size; ++i {
            if data[i] == ('\n' as u8) {
                lines->push_back((i + 1) as u32)
                ++count
            }
        }

        kairo::Logger::info(
            kairo::Logger::Stage::Driver,
            f"SourceLineTable::build_index: fid={fid} indexed {count} lines size={size}B",
        )

        entry->publish_lines(lines, count)
    }

    ///
    /// \brief checks if the file entry is ready (index built).
    ///
    fn is_ready(self, fid: u32) -> bool {
        var unsafe *tbl = self._file_table.load(
            kairo::std::MemoryOrder::acquire,
        )

        if tbl == &null || (fid as usize) >= tbl->size() {
            return false
        }

        var unsafe *entry = (*tbl)[fid]
        return entry != &null && entry->is_ready()
    }

    ///
    /// \brief busy-waits until the file entry is ready, with backoff.
    ///
    fn wait_until_ready(self, fid: u32) {
        // check if fid is even registered before waiting
        var unsafe *tbl = self._file_table.load(
            kairo::std::MemoryOrder::acquire,
        )

        if tbl == &null || (fid as usize) >= tbl->size() {
            return
        }

        var unsafe *entry = (*tbl)[fid]
        if entry == &null {
            return
        }

        // Absent: no build was ever claimed (load_file's skip_indexing), so
        // nothing will make it Ready, so waiting would spin (up to ~5 s)
        // for nothing. Stale still waits: invalidate rebuilds it under
        // _load_mu right after withdrawing it.
        if entry->state() == (LineEntryState::Absent as u8) {
            return
        }

        var   count:    u32 = 0
        const MAX_WAIT: u32 = 100000 // ~5 seconds max

        while count < MAX_WAIT {
            if self.is_ready(fid) {
                return
            }

            if count >= 10000 {
                cxx::std::this_thread::sleep_for(
                    cxx::std::chrono::microseconds(50),
                )
            } else if count >= 5000 {
                cxx::std::this_thread::sleep_for(
                    cxx::std::chrono::microseconds(25),
                )
            } else if count >= 1000 {
                cxx::std::this_thread::sleep_for(
                    cxx::std::chrono::microseconds(5),
                )
            } else {
                kairo::thread_pause()
            }

            ++count
        }

        kairo::Logger::error(
            kairo::Logger::Stage::Driver,
            f"SourceLineTable::wait_until_ready: fid={fid} timed out after {MAX_WAIT} iterations, proceeding without line table",
        )
    }

    ///
    /// \brief resolves line and column for a given file id and offset.
    ///
    /// \details
    /// performs a binary search on the line offsets to find the
    /// corresponding line number and column within that line.
    ///
    fn get_line_col(self, fid: u32, offset: u32, const file_name: Path) -> FullSourceLocation {
        var unsafe *tbl = self._file_table.load(
            kairo::std::MemoryOrder::acquire,
        )

        if tbl == &null || (fid as usize) >= tbl->size() {
            return FullSourceLocation((fid as usize), 0, 0, file_name)
        }

        var unsafe *entry = (*tbl)[fid]
        if entry == &null || !entry->is_ready() {
            return FullSourceLocation((fid as usize), 0, 0, file_name)
        }

        var unsafe *lines = entry->lines.load(kairo::std::MemoryOrder::acquire)
        if lines == &null {
            return FullSourceLocation((fid as usize), 0, 0, file_name)
        }

        var end: usize = ((entry->line_count.load(
            kairo::std::MemoryOrder::acquire,
        )) as usize)
        if end == 0 {
            return FullSourceLocation((fid as usize), 0, 0, file_name)
        }

        var lo: usize = 0
        var hi: usize = end - 1

        while lo < hi {
            var mid = lo + hi + 1 >> 1
            if (*lines)[mid] <= offset {
                lo = mid
            } else {
                hi = mid - 1
            }
        }

        var line_start = (*lines)[lo]
        var col        = offset - line_start + 1

        return FullSourceLocation(
            (fid as usize),
            (lo + 1),
            col as usize,
            file_name
        )
    }

    ///
    /// \brief dumps the internal state of the source line table.
    ///
    fn op as (self) -> string {
        var out = f"SourceLineTable(\n"
        out += f"  _file_count: {self._file_count}\n"

        var unsafe *tbl = self._file_table.load(
            kairo::std::MemoryOrder::acquire,
        )

        if tbl == &null {
            out += "  _file_table: &null\n)"
            return out
        }

        out += "  _file_table:\n"
        for i in (0 as usize)..tbl->size() {
            var unsafe *entry = (*tbl)[i]
            if entry == &null {
                out += f"    [{i}] &null\n"
                continue
            }

            out += f"    [{i}] {*entry}\n"
        }

        return out + ")"
    }

    ///
    /// \brief gets the starting offset of a line.
    ///
    /// \param fid file id.
    /// \param line_num 1-based line number.
    /// \return byte offset of line start, or 0 if invalid.
    ///
    fn get_line_offset(self, fid: u32, line_num: u32) -> u32 {
        var unsafe *tbl = self._file_table.load(
            kairo::std::MemoryOrder::acquire,
        )

        if tbl == &null || (fid as usize) >= tbl->size() {
            return 0
        }

        var unsafe *entry = (*tbl)[fid]
        if entry == &null || !entry->is_ready() {
            return 0
        }

        var unsafe *lines = entry->lines.load(kairo::std::MemoryOrder::acquire)
        if lines == &null {
            return 0
        }

        var line_count = entry->line_count.load(
            kairo::std::MemoryOrder::acquire,
        )

        // line_num is 1-based, but array is 0-indexed
        if line_num == 0 || line_num > line_count {
            return 0
        }

        return (*lines)[line_num - 1]
    }

    ///
    /// \brief gets the ending offset of a line (start of next line or EOF).
    ///
    /// \param fid file id.
    /// \param line_num 1-based line number.
    /// \return byte offset where line ends (exclusive).
    ///
    fn get_line_end_offset(self, fid: u32, line_num: u32) -> u32 {
        var unsafe *tbl = self._file_table.load(
            kairo::std::MemoryOrder::acquire,
        )

        if tbl == &null || (fid as usize) >= tbl->size() {
            return 0
        }

        var unsafe *entry = (*tbl)[fid]
        if entry == &null || !entry->is_ready() {
            return 0
        }

        var unsafe *lines = entry->lines.load(kairo::std::MemoryOrder::acquire)
        if lines == &null {
            return 0
        }

        var line_count = entry->line_count.load(
            kairo::std::MemoryOrder::acquire,
        )

        if line_num == 0 || line_num > line_count {
            return 0
        }

        // if this is the last line, return file size
        if line_num == line_count {
            return entry->file_size
        }

        // otherwise return start of next line (which is after the newline)
        // we want the position before the newline
        return (*lines)[line_num] - 1
    }

    ///
    /// \brief resets the table to initial state.
    ///
    /// \details
    /// waits for active builds, destroys all entries, reallocates table.
    ///
    fn reset(self) {
        // wait for any active builds
        self._drain_builds()

        var unsafe *tbl = self._file_table.load(
            kairo::std::MemoryOrder::acquire,
        )

        if tbl != &null {
            for var f: *FileEntry? in *tbl {
                if f != &null {
                    var unsafe *lines = f->lines.load(
                        kairo::std::MemoryOrder::relaxed,
                    )

                    if lines != &null {
                        @destroy unsafe (lines as *cxx::std::vector<u32>)
                    }

                    @destroy unsafe (f as *Self::FileEntry)
                }
            }

            @destroy unsafe (tbl as *cxx::std::vector<unsafe *Self::FileEntry>)
        }

        // reallocate fresh table
        var unsafe *new_tbl = unsafe (@create cxx::std::vector<unsafe *Self::FileEntry>() as unsafe *cxx::std::vector<unsafe *Self::FileEntry>)
        new_tbl->reserve(256)

        self._file_table.store(new_tbl, kairo::std::MemoryOrder::release)
        self._file_count.store(0, kairo::std::MemoryOrder::release)
    }
}
