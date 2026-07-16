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
/// \brief O(1) two-way loc translation between the Kairo SourceManager and a
///        single clang::SourceManager shared across all Kairo TUs.
///
/// \details
/// Both location systems are structurally identical: a location is
/// `file_base + byte_offset` into a global address space. The bases are
/// CUMULATIVE on both sides (Kairo: `_total_b`; clang: per-FileID offsets),
/// so no closed-form bit math relates them but a dense per-fid table does,
/// making translation one array index + one add in each direction:
///
///     kairo -> clang:  resolve(loc) -> (kfid, off)
///                      -> csm.getComposedLoc(k2c[kfid], off)
///     clang -> kairo:  csm.getDecomposedExpansionLoc(cloc) -> (cfid, off)
///                      -> ksm.get_loc(c2k[cfid], off)
///
/// clang FileIDs are created FROM the Kairo VFM's mmapped buffers
/// (createFileID over a MemoryBufferRef), never by re-opening paths:
///   - one mmap backs both source managers (no double I/O),
///   - byte offsets are identical by construction,
///   - registration order == Kairo fid order, so the forward map is a
///     dense vector and fully deterministic across runs.
///
/// \par Threading contract
/// By the time the Kairo preprocessor finishes, every fid is known. The
/// driver enqueues preload() on the ThreadPool then; it runs concurrently
/// with Kairo parsing (which never touches the clang SM). The join that
/// ends the parse phase is the happens-before edge: preload() MUST have
/// completed before any to_clang/to_kairo call or any clang parse touches
/// the shared SM. clang::SourceManager::createFileID is not thread-safe —
/// exactly one preloader thread, and a quiescent clang SM while it runs.
///
/// \par Lifetime
/// The Kairo VFM mmaps live for the whole session and must outlive the
/// clang SM (clang stores MemoryBufferRef views, it does not copy).
/// Buffer names are owned here in a deque (stable addresses under growth).
///

ffi "c++" import "Native/Types.hh";
ffi "c++" import "clang/Basic/SourceLocation.h";
ffi "c++" import "clang/Basic/SourceManager.h";
ffi "c++" import "llvm/ADT/StringRef.h";
ffi "c++" import "llvm/Support/MemoryBufferRef.h";

import Location::SourceLocation::*;
import Location::SourceRange::*;
import Location::SourceManager::*;

class ClangLocMap {
    priv var _ksm: obs::<SourceManager>;              ///< owned by the driver, outlives this
    priv var _csm: opt::<clang::SourceManager> = &null; ///< shared clang SM; owned by the bridge

    /// index == kairo fid; invalid clang::FileID for unregistrable files.
    priv var _k2c: vec::<clang::FileID>;

    /// clang FileID hash -> kairo fid (reverse direction).
    priv var _c2k: libcxx::unordered_map::<u32, FileID>;

    /// Narrow buffer names handed to clang; deque so addresses stay stable
    /// as registration grows (clang keeps StringRef views into these).
    priv var _names: libcxx::deque::<libcxx::string>;

    /// Set at the end of preload(); queries before that are a driver bug.
    priv var _ready: bool = false;

    // --- Construction ------------------------------------------------------

    fn ClangLocMap(self, ksm: *SourceManager) {
        if ksm == &null {
            std::crash(std::Error::RuntimeError(
                "ClangLocMap: a valid Kairo SourceManager is required"));
        }
        self._ksm = ksm;
    }

    /// Binds the shared clang SourceManager. Must precede preload().
    fn attach(self, csm: *clang::SourceManager) {
        self._csm = csm;
    }

    fn ready(self) -> bool { return self._ready; }

    // --- Preload (single thread, quiescent clang SM) ------------------------

    /// Registers every Kairo fid not yet mapped into the shared clang SM,
    /// in fid order, straight from the VFM's mmapped bytes. Idempotent:
    /// re-invoking after late load_file calls maps only the tail.
    fn preload(self) {
        std::ICE(self._csm != &null, "ClangLocMap::preload before attach()");

        var n = self._ksm->file_count();
        while self._k2c.size() < n {
            self._register(static_cast::<FileID>(self._k2c.size()));
        }

        self._ready = true;
    }

    priv fn _register(self, fid: FileID) {
        var hview = self._ksm->get_file_view(fid);

        // Own the narrow name for the clang SM's lifetime.
        self._names.push_back(libcxx::string(
            std::string_to_nstring(self._ksm->get_filename(fid)).raw_string()));

        var cfid: clang::FileID;   // default: invalid

        if (hview.data != &null) && (hview.size > 0) {
            var bref = llvm::MemoryBufferRef(
                llvm::StringRef(
                    reinterpret_cast::<std::ConstPtr::<std::Legacy::char>>(hview.data),
                    hview.size),
                llvm::StringRef(self._names.back()));

            cfid = self._csm->createFileID(bref, clang::SrcMgr::C_User);
        }

        self._k2c.push_back(cfid);

        if cfid.isValid() {
            self._c2k[cfid.getHashValue()] = fid;
        }
    }

    // --- Kairo -> clang ------------------------------------------------------

    /// Returns the clang loc for a Kairo loc, or invalid if the loc / file
    /// cannot be mapped. O(1): one resolve, one table index, one compose.
    fn to_clang(self, loc: SourceLocation) -> clang::SourceLocation {
        std::ICE(self._ready, "ClangLocMap::to_clang before preload()");

        if !loc.is_valid() {
            return clang::SourceLocation();
        }

        var res = self._ksm->resolve(loc);

        if res.fid >= self._k2c.size() {
            // fid loaded after the last preload(); driver should re-preload.
            return clang::SourceLocation();
        }

        var cfid = self._k2c[res.fid];
        if !cfid.isValid() {
            return clang::SourceLocation();
        }

        return self._csm->getComposedLoc(cfid, static_cast::<u32>(res.offset));
    }

    /// Kairo range -> clang CharSourceRange. Kairo ranges are half-open
    /// byte ranges; getCharRange preserves that exactly (no token-extent
    /// guessing on the clang side).
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
    /// (macro-blamed locs land on the expansion site, matching how Kairo
    /// renders spans). Invalid if the file is not one we registered —
    /// e.g. a clang-pulled system header; the caller's policy layer
    /// classifies those (typically a loc-less forward).
    fn to_kairo(self, cloc: clang::SourceLocation) -> SourceLocation {
        std::ICE(self._ready, "ClangLocMap::to_kairo before preload()");

        if cloc.isInvalid() {
            return SourceLocation::invalid();
        }

        var dec = self._csm->getDecomposedExpansionLoc(cloc);
        var it  = self._c2k.find(dec.first.getHashValue());

        if it == self._c2k.end() {
            return SourceLocation::invalid();
        }

        return self._ksm->get_loc((*it).second, static_cast::<usize>(dec.second));
    }

    /// clang range -> Kairo range. Token-range ends cover at least the first
    /// byte of the final token (exact extents need Lexer::MeasureTokenLength,
    /// which needs LangOptions caller's concern, not the map's).
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

    /// Direct fid lookup for callers that hold a fid, not a loc
    /// (e.g. ClangDiagAdapter checking "is this diag blamed in my TU?").
    fn clang_fid(self, fid: FileID) -> clang::FileID {
        if fid >= self._k2c.size() {
            return clang::FileID();
        }
        return self._k2c[fid];
    }

    fn kairo_fid(self, cfid: clang::FileID) -> FileID {
        if !cfid.isValid() {
            return static_cast::<FileID>(u32(-1));
        }

        var it = self._c2k.find(cfid.getHashValue());
        if it == self._c2k.end() {
            return static_cast::<FileID>(u32(-1));
        }

        return (*it).second;
    }
}
