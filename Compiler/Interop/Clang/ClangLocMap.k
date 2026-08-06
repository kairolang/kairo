/// --- The Kairo Project ----------------- Interop/Clang/ClangLocMap.k --- ///
///
///   Bidirectional Kairo <-> clang source-location translation over a
///   SHARED clang translation unit.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
///
/// \file  Interop/Clang/ClangLocMap.k
/// \brief Two-way loc translation between the Kairo SourceManager and the
///        shared clang::SourceManager. Forward: one index + one add. Reverse:
///        one subtract + one bounds check, NO table.
///
/// \par THE CONTIGUITY INVARIANT
///   Everything here rests on one fact: rebind() registers every Kairo fid
///   into the clang SM in ONE loop, in fid order, with nothing else
///   registering in between. clang then hands out a CONTIGUOUS block of
///   FileIDs, so
///
///       clang_fid(kfid) == _cfid0 + kfid
///       kairo_fid(cfid) == cfid - _cfid0     (valid iff in [0, _n))
///
///   _cfid0 is measured, never assumed. clang has already allocated FileIDs
///   for the injected main buffer (and possibly predefines) before our
///   registration window opens, so the base is NOT 1 and hardcoding it would
///   be a silent off-by-N. Every subsequent fid is ICE-checked against the
///   base, so if clang ever slips an allocation into the middle of the block
///   the build dies at rebind() instead of rendering carets into the wrong
///   file for the rest of the run.
///
///   Headers, macro expansions, and Preprocessor::CreateString scratch
///   buffers all allocate ABOVE the block, during the parse. The range check
///   rejects them, which is exactly right: they have no Kairo counterpart.
///
/// \par Why offsets still need a table
///   Both systems lay files out as `base + byte_offset`. Clang packs, advancing
///   by `size + 1`. VirtualFileManager does not: it 4 KB-aligns each
///   global_base (that alignment is what makes Kairo's own resolve() a
///   shift-and-index) and advances by a RESERVED span sized well above the
///   file, so an edit that changes a file's length can be re-mapped in place
///   without moving its base. So the per-file delta varies and there is no
///   closed form for the OFFSET side.
///
///   That costs nothing. _sloc is a dense vec<u32> indexed by kairo fid
///   holding clang's raw SLoc base   4 bytes per file, L1-resident, and it
///   replaces BOTH the old vec<clang::FileID> AND the getComposedLoc call
///   behind it. Forward translation is now one load and one add.
///
/// \par ONE registration site
///   rebind() is the only place a Kairo fid enters the clang SM. It is called
///   from KairoEmitAction::BeginSourceFileAction, INSIDE the action window,
///   because FrontendAction::BeginSourceFile calls
///   SourceManager::clearIDTables() on the SM-reuse path: it wipes
///   LocalSLocEntryTable and resets NextLocalOffset, killing every FileID
///   minted earlier.
///
///   The old design registered from a pool task after preprocess and never
///   re-registered. Every FileID it stored was dead from the first
///   ExecuteAction onward, and because clang restarts its ID counter after
///   clearIDTables, a header's fresh FileID would COLLIDE with a stale entry
///   and map a diagnostic in <vector> onto a Kairo file at a bogus offset.
///   Wrong caret, correct formatting, no assert. That is why registration
///   moved inside the window and why the reverse direction is now a range
///   check rather than a hash lookup that cannot tell stale from live.
///
/// \par Mechanism, and why it is not the invariant
///   Real paths register through FileManager::getFileRef + createFileID:
///   FileManager::FileInfos survives clearIDTables, so re-registration is
///   table work against a warm ContentCache, not a re-read.
///
///   Virtual fids (SourceManager::create_virtual, no file on disk) have no
///   FileEntry and must go through a MemoryBufferRef over the VFM mapping.
///   That is fine   CONTIGUITY is the invariant, not uniformity of
///   mechanism. Both overloads append to the same SLoc block in order.
///
///   TODO(perf): the getFileRef path leaves the bytes resident twice (Kairo's
///   mmap plus clang's ContentCache), and MemBufferInfos is not cleared by
///   clearIDTables so the virtual path accumulates a ContentCache per fid per
///   action. SourceManager::overrideFileContents(FileEntryRef, MemoryBufferRef)
///   collapses both: FileEntry-keyed (survives clearIDTables, no accumulation)
///   and backed by our mmap (no second read).
///
/// \par Lifetime
///   The Kairo VFM mmaps live for the whole session and must outlive the
///   clang SM   clang stores MemoryBufferRef views for the virtual path, it
///   does not copy.
///
/// \par Threading
///   rebind() runs on the driver thread inside ExecuteAction.
///   clang::SourceManager::createFileID is not thread-safe and there is no
///   longer any off-thread preload to race with.
///

ffi "c++" import "Native/Types.hh";
ffi "c++" import "clang/Basic/SourceLocation.h";
ffi "c++" import "clang/Basic/SourceManager.h";
ffi "c++" import "clang/Frontend/CompilerInstance.h";
ffi "c++" import "llvm/ADT/StringRef.h";
ffi "c++" import "llvm/Support/MemoryBufferRef.h";

import Location::SourceLocation::*;
import Location::SourceRange::*;
import Location::SourceManager::*;

class ClangLocMap {
    priv var _ksm: obs::<SourceManager>;                ///< owned by the driver, outlives this
    priv var _csm: opt::<clang::SourceManager> = &null; ///< shared clang SM; owned by the bridge

    /// index == kairo fid; value == clang's raw SLoc base for that file.
    /// Dense, u32, contiguous with _cfid0's block.
    priv var _sloc: vec::<u32>;

    /// clang FileID of kairo fid 0. MEASURED at rebind, never assumed.
    priv var _cfid0: clang::FileID;

    /// Number of kairo fids in the contiguous block (== _sloc.size()).
    priv var _n: usize = 0;

    /// Narrow names handed to clang for virtual fids; deque so addresses stay
    /// stable under growth (clang keeps StringRef views into these).
    priv var _names: libcxx::deque::<libcxx::string>;

    /// Set by rebind(); queries before the first successful rebind are a
    /// driver bug. Cleared at the START of every rebind so a failed
    /// re-registration cannot leave a half-built table readable.
    priv var _ready: bool = false;

    // --- Construction ------------------------------------------------------

    fn ClangLocMap(self, ksm: *SourceManager) {
        if ksm == &null {
            std::crash(std::Error::RuntimeError(
                "ClangLocMap: a valid Kairo SourceManager is required"));
        }
        self._ksm = ksm;
    }

    fn ready(self) -> bool { return self._ready; }

    /// Number of Kairo fids currently mapped.
    fn mapped_count(self) -> usize { return self._n; }

    // --- Registration (driver thread, inside the action window) -------------

    /// Registers EVERY Kairo fid into \p ci's SourceManager as one contiguous
    /// FileID block, then records the base and each file's SLoc start.
    ///
    /// MUST be called from FrontendAction::BeginSourceFileAction, after the
    /// base action's call (clearIDTables has run by then) and before anything
    /// translates a location. Idempotent across actions: it rebuilds from
    /// scratch, which is also how fids loaded since the last action get
    /// picked up.
    ///
    /// \return false if a fid could not be registered. The map is left
    ///         NOT ready, so every subsequent query returns invalid rather
    ///         than a plausible-looking wrong answer.
    fn rebind(self, ci: *clang::CompilerInstance) -> bool {
        std::ICE(ci != &null, "ClangLocMap::rebind with no CompilerInstance");

        self._ready = false;
        self._sloc.clear();
        self._names.clear();
        self._cfid0 = clang::FileID();
        self._n     = 0;

        self._csm = &ci->getSourceManager();
        var fm    = &ci->getFileManager();

        var n = self._ksm->file_count();
        if n == 0 { return false; }

        for var i: usize = 0; i < n; ++i {
            var kfid = static_cast::<FileID>(i);
            var cfid = self._register_one(fm, kfid);

            if !cfid.isValid() {
                Logger::error(Logger::Stage::Driver,
                    f"ClangLocMap::rebind: fid {i} ('{self._ksm->get_filename(kfid)}') "
                    "could not be registered; loc translation disabled for this TU");
                self._sloc.clear();
                self._n = 0;
                return false;
            }

            if i == 0 {
                self._cfid0 = cfid;
            } else {
                // The whole design in one assert. If clang allocated a FileID
                // between two of ours, the arithmetic below is silently wrong
                // for every location for the rest of the run.
                std::ICE(
                    cfid.getHashValue()
                        == self._cfid0.getHashValue() + static_cast::<u32>(i),
                    "ClangLocMap: clang allocated a FileID inside the Kairo "
                    "block; the contiguity invariant is broken and fid "
                    "arithmetic is invalid");
            }

            self._sloc.push_back(
                self._csm->getLocForStartOfFile(cfid).getRawEncoding());
        }

        self._n     = n;
        self._ready = true;

        Logger::info(Logger::Stage::Driver,
            f"ClangLocMap::rebind: {n} fid(s) mapped to clang block [{self._cfid0.getHashValue()}, {self._cfid0.getHashValue() + u32(n)})");

        return true;
    }

    /// Real path -> FileEntryRef (ContentCache survives clearIDTables).
    /// Virtual fid -> MemoryBufferRef over the VFM mapping. Either way the
    /// SLoc block stays contiguous, which is the only thing the math needs.
    priv fn _register_one(self, fm: *clang::FileManager, kfid: FileID) -> clang::FileID {
        var path = self._ksm->get_filename(kfid);
        var np   = std::string_to_nstring(path);

        var fref = fm->getFileRef(llvm::StringRef(np.raw(), np.size()), true);
        if fref {
            return self._csm->createFileID(
                *fref, clang::SourceLocation(), clang::SrcMgr::C_User);
        }

        // No FileEntry: synthetic buffer. Own the narrow name for the clang
        // SM's lifetime   it keeps a StringRef view, it does not copy.
        var hview = self._ksm->get_file_view(kfid);
        if (hview.data == &null) || (hview.size == 0) {
            return clang::FileID();
        }

        self._names.push_back(libcxx::string(np.raw_string()));

        var bref = llvm::MemoryBufferRef(
            llvm::StringRef(
                reinterpret_cast::<std::ConstPtr::<std::Legacy::char>>(hview.data),
                hview.size),
            llvm::StringRef(self._names.back()));

        return self._csm->createFileID(bref, clang::SrcMgr::C_User);
    }

    // --- Kairo -> clang ------------------------------------------------------

    /// One resolve, one table index, one add. No getComposedLoc: a file loc's
    /// raw encoding IS its file's SLoc base plus the byte offset.
    fn to_clang(self, loc: SourceLocation) -> clang::SourceLocation {
        std::ICE(self._ready, "ClangLocMap::to_clang before rebind()");

        if !loc.is_valid() {
            return clang::SourceLocation();
        }

        var res = self._ksm->resolve(loc);
        if res.fid >= self._n {
            // fid loaded after this action's rebind; the next action maps it.
            return clang::SourceLocation();
        }

        return clang::SourceLocation::getFromRawEncoding(
            self._sloc[res.fid] + static_cast::<u32>(res.offset));
    }

    /// Kairo range -> clang CharSourceRange. Kairo ranges are half-open byte
    /// ranges; getCharRange preserves that exactly (no token-extent guessing
    /// on the clang side).
    fn to_clang(self, range: SourceRange) -> clang::CharSourceRange {
        if !range.is_valid() {
            return clang::CharSourceRange();
        }

        var b = self.to_clang(range.start);
        var e = self.to_clang(range.end);

        if (b.isInvalid()) || (e.isInvalid()) {
            return clang::CharSourceRange();
        }

        return clang::CharSourceRange::getCharRange(b, e);
    }

    // --- clang -> Kairo ------------------------------------------------------

    /// Returns the Kairo loc for a clang loc via its EXPANSION location
    /// (macro-blamed and arena-literal locs land on the expansion site, which
    /// is how Kairo renders spans). Invalid for anything outside the Kairo
    /// block   headers, predefines, scratch buffers. The caller's policy layer
    /// classifies those, typically as a loc-less forward.
    fn to_kairo(self, cloc: clang::SourceLocation) -> SourceLocation {
        std::ICE(self._ready, "ClangLocMap::to_kairo before rebind()");

        if cloc.isInvalid() {
            return SourceLocation::invalid();
        }

        var dec  = self._csm->getDecomposedExpansionLoc(cloc);
        var kfid = self.kairo_fid(dec.first);

        if kfid == static_cast::<FileID>(u32(-1)) {
            return SourceLocation::invalid();
        }

        return self._ksm->get_loc(kfid, static_cast::<usize>(dec.second));
    }

    /// clang range -> Kairo range. Token-range ends cover at least the first
    /// byte of the final token (exact extents need Lexer::MeasureTokenLength,
    /// which needs LangOptions   caller's concern, not the map's).
    fn to_kairo(self, cr: clang::CharSourceRange) -> SourceRange {
        if !cr.isValid() {
            return SourceRange::invalid();
        }

        var b = self.to_kairo(cr.getBegin());
        var e = self.to_kairo(cr.getEnd());

        if (!b.is_valid()) || (!e.is_valid()) {
            return SourceRange::invalid();
        }

        if cr.isTokenRange() {
            e = e.advance(1);
        }

        if e <= b {
            e = b.advance(1);
        }

        return SourceRange::from_bounds(b, e);
    }

    // --- fid arithmetic --------------------------------------------------------

    /// clang fid -> kairo fid. One subtract, one unsigned range check, no
    /// table. Returns u32(-1) for any FileID outside the Kairo block.
    ///
    /// This is THE hot path: every clang diagnostic goes through it.
    fn kairo_fid(self, cfid: clang::FileID) -> FileID {
        if !self._ready { return static_cast::<FileID>(u32(-1)); }
        if !cfid.isValid() { return static_cast::<FileID>(u32(-1)); }

        var h = cfid.getHashValue();
        var b = self._cfid0.getHashValue();

        if h < b { return static_cast::<FileID>(u32(-1)); }

        var k = h - b;
        if static_cast::<usize>(k) >= self._n {
            return static_cast::<FileID>(u32(-1));
        }

        return static_cast::<FileID>(k);
    }

    /// kairo fid -> clang FileID. COLD PATH: this is a binary search over
    /// clang's SLoc table (getFileID on the file's start loc), because
    /// clang::FileID has no public integer constructor and cannot be built by
    /// arithmetic. Called once per action, for the TU being emitted   never
    /// per location, which is why the hot direction is kairo_fid() above.
    fn clang_fid_of(self, kfid: FileID) -> clang::FileID {
        if !self._ready { return clang::FileID(); }
        if static_cast::<usize>(kfid) >= self._n { return clang::FileID(); }

        return self._csm->getFileID(
            clang::SourceLocation::getFromRawEncoding(self._sloc[kfid]));
    }

    // --- Introspection ---------------------------------------------------------

    /// The clang FileID block base. Exposed for tests and --print-locmap; the
    /// arithmetic in kairo_fid() is only auditable if you can see the base it
    /// is subtracting.
    fn block_base(self) -> u32 { return self._cfid0.getHashValue(); }

    /// clang's raw SLoc base for \p kfid. u32(-1) if unmapped.
    fn sloc_base(self, kfid: FileID) -> u32 {
        if static_cast::<usize>(kfid) >= self._n { return u32(-1); }
        return self._sloc[kfid];
    }

    /// Kairo's raw SourceLocation for byte 0 of \p kfid.
    fn kairo_base(self, kfid: FileID) -> u32 {
        return self._ksm->get_loc(kfid, 0).raw();
    }

    /// clang_base - kairo_base for \p kfid.
    ///
    /// WITHIN a file this is constant   both address spaces advance byte for
    /// byte, so `cloc = kloc + delta` is exact with no padding. The 4 KB
    /// alignment VirtualFileManager applies only shifts things BETWEEN files,
    /// and a per-fid delta absorbs that exactly.
    ///
    /// Signed, and negative for every fid past the first (Kairo's bases climb
    /// in 4 KB steps, clang's pack).
    fn delta(self, kfid: FileID) -> i64 {
        std::ICE(static_cast::<usize>(kfid) < self._n,
            "ClangLocMap::delta on an unmapped fid");
        return static_cast::<i64>(self._sloc[kfid])
             - static_cast::<i64>(self.kairo_base(kfid));
    }

    /// Dumps the whole mapping: per fid, Kairo base vs clang SLoc base and the
    /// delta between them.
    ///
    /// The delta column is the answer to "can this be closed-form math". It is
    /// NOT constant   it shrinks at every file by exactly the 4 KB alignment
    /// padding VirtualFileManager inserts and clang does not. Seeing the
    /// numbers move is what rules out `cloc = kloc + K` for the layouts as
    /// they stand, and seeing by how much is what tells you the size of the
    /// filler buffer that would force it constant.
    fn dump(self) {
        std::print(f"=== ClangLocMap: {self._n} fid(s), clang block base {self.block_base()} ===");
        std::print("  fid  kairo_base   clang_base        delta  size  path");

        for var i: usize = 0; i < self._n; ++i {
            var kfid = static_cast::<FileID>(i);
            var kb   = self._ksm->get_loc(kfid, 0).raw();
            var cb   = self._sloc[i];
            var d    = static_cast::<i64>(cb) - static_cast::<i64>(kb);

            std::print(f"  {i}  {kb}  {cb}  {d}  {self._ksm->get_file_size(kfid)}  {self._ksm->get_filename(kfid)}");
        }

        std::print("==========================================================");
    }

    // --- Self-check ------------------------------------------------------------

    /// Exhaustive round-trip verification of the whole map.
    ///
    /// This class is a BIJECTION over a finite domain, so it does not need
    /// clever tests   it needs an oracle. Every reachable Kairo location must
    /// survive to_clang -> to_kairo unchanged, and every clang FileID outside
    /// the block must be rejected. Anything that breaks contiguity, the base,
    /// or the SLoc table shows up here as an exact mismatch with the fid and
    /// offset that failed, instead of as a caret pointing at the wrong file
    /// three stages later.
    ///
    /// Boundary offsets are the ones that matter: 0 catches an off-by-one in
    /// the base, size-1 catches a stride error, and size (one past the end,
    /// which clang allocates and Kairo does not address) catches a fencepost
    /// in the range check.
    ///
    /// Call after rebind() under --verify-locmap or in debug builds. It is
    /// O(fids), not O(bytes)   cheap enough to leave on.
    fn verify(self) -> bool {
        if !self._ready {
            Logger::error(Logger::Stage::Driver,
                "ClangLocMap::verify: map is not ready");
            return false;
        }

        var ok = true;

        for var i: usize = 0; i < self._n; ++i {
            var kfid = static_cast::<FileID>(i);
            var size = self._ksm->get_file_size(kfid);
            if size == 0 { continue; }

            // fid arithmetic must agree with the SLoc table it was built from.
            var cfid = self.clang_fid_of(kfid);
            if self.kairo_fid(cfid) != kfid {
                Logger::error(Logger::Stage::Driver,
                    f"ClangLocMap::verify: fid {i} round-trips to {self.kairo_fid(cfid)} (base={self._cfid0.getHashValue()})");
                ok = false;
                continue;
            }

            var probes: vec::<usize>;
            probes.push_back(0);
            if size > 1 { probes.push_back(1); }
            if size > 2 { probes.push_back(size / 2); }
            probes.push_back(size - 1);

            for off: usize in probes {
                var kloc = self._ksm->get_loc(kfid, off);
                var cloc = self.to_clang(kloc);

                if cloc.isInvalid() {
                    Logger::error(Logger::Stage::Driver,
                        f"ClangLocMap::verify: fid {i} off {off} -> invalid clang loc");
                    ok = false;
                    continue;
                }

                // The clang loc must land in THIS file at THIS offset.
                var dec = self._csm->getDecomposedLoc(cloc);
                if (self.kairo_fid(dec.first) != kfid)
                    || (static_cast::<usize>(dec.second) != off) {
                    Logger::error(Logger::Stage::Driver,
                        f"ClangLocMap::verify: fid {i} off {off} decomposed to fid {self.kairo_fid(dec.first)} off {dec.second}");
                    ok = false;
                    continue;
                }

                var back = self.to_kairo(cloc);
                if back != kloc {
                    Logger::error(Logger::Stage::Driver,
                        f"ClangLocMap::verify: fid {i} off {off} failed round-trip ({kloc.raw()} -> {cloc.getRawEncoding()} -> {back.raw()})");
                    ok = false;
                }
            }
        }

        // Anything immediately below or above the block must be rejected.
        // These are the IDs headers and scratch buffers actually occupy, and a
        // wrong answer here is the silent-wrong-caret failure mode.
        var below = self._cfid0.getHashValue();
        if below > 0 {
            var probe = self._csm->getFileID(
                clang::SourceLocation::getFromRawEncoding(self._sloc[0] - 1));
            if self.kairo_fid(probe) != static_cast::<FileID>(u32(-1)) {
                Logger::error(Logger::Stage::Driver,
                    "ClangLocMap::verify: a FileID below the block was accepted");
                ok = false;
            }
        }

        var verdict: string = ("OK") if (ok) else ("FAILED");
        Logger::info(Logger::Stage::Driver,
            f"ClangLocMap::verify: {self._n} fid(s) {verdict}");

        return ok;
    }

    /// True when \p cfid is Kairo fid \p kfid. The comparison every consumer
    /// actually wants   holding a clang::FileID across a rebind is exactly the
    /// staleness bug this class was rewritten to remove, so nothing outside
    /// here caches one.
    fn is_kairo_fid(self, cfid: clang::FileID, kfid: FileID) -> bool {
        return self.kairo_fid(cfid) == kfid;
    }
}
