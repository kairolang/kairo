/// --- The Kairo Project ------------------------- Driver/ObjectCache.k --- ///
///
///   \brief The incremental object cache, phase 1 (Spec/Incremental.md):
///          per Kairo TU, the object key O(m), the cache record each object
///          carries, and the content-addressed store under --cache-dir.
///
///   Phase 1 still parses and checks every file; what a hit skips is the
///   TU's codegen and clang. The key is computed from the stream the TU's
///   fill would hand clang (HashSink, CodegenJob::hash_stream), so it is
///   computed from the tree codegen renders, after every lowering and
///   inference, never from the source text.
///
///     O(m) = H(F, stream(m), headers(m), clang diagnostic words, PCH shape)
///
///   F, the toolchain fingerprint, is every part that comes from the
///   compiler and the options rather than the source: CACHE_SCHEMA, the
///   version core, the compiler build (a development build only, see
///   _fingerprint), clang's version, the target and the cc1 words that can
///   change an object. One F per run; its hash names the store directory,
///   so a different F never sees another's objects.
///
///   Every part is the TU's own, never the graph's (Compiler/Spec/
///   Incremental.md#shared-across-graphs): headers(m) is only the header
///   files m's stream can reach (tu_headers), F holds no tool-specific word,
///   and the stream itself is ordered and homed independently of the entry
///   (EmitPlan::set_file_ranks, assign_homes). So kairo, kcc, kfmt and kld,
///   built from one tree into one --cache-dir, reuse each other's objects.
///
///   An object is self-validating: its record (an SHF_EXCLUDE / no-load /
///   LNK_REMOVE section the linker drops) holds the key it was built
///   under, and a lookup accepts a file only when that key equals the one
///   it wants. The file name is a hint; a file with no record, another
///   schema's or a damaged one is a miss, never trusted.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "llvm/ADT/StringMap.h"
ffi "c++" import "llvm/ADT/StringSet.h"
ffi "c++" import "llvm/Support/FileSystem.h"
ffi "c++" import "llvm/Support/Process.h"
ffi "c++" import "llvm/TargetParser/Triple.h"
ffi "c++" import "Native/KObjCache.hh"
ffi "c++" import "Native/KShims.hh"
ffi "c++" import "Native/KLog.hh"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"
ffi "c++" import "chrono"

import API::FS::*
import Driver::CacheFormat::{
    CACHE_SCHEMA,
    cache_dir_name,
    fingerprint_prefix,
    fingerprint_schema_key,
    fingerprint_version_key,
}
import Interop::Clang::ClangBackend::ClangBackend
import Interop::Clang::HeaderSet::HeaderSet
import Interop::Clang::HeaderSetCache::HeaderSetCache
import Support::Tuning::{
    CACHE_ENTRY_MAX_AGE_NS,
    CACHE_OBJECTS_MAX_BYTES,
    CACHE_PARTIAL_MAX_AGE_NS,
    CACHE_RECENT_STORE_NS,
}
import std::env

/// The first line of every record: what objcache_record finds must start
/// with it, or the section is not ours.
fn cache_record_magic() -> string {
    return "kairo-cache-record"
}

/// One stored object, for ObjectCache::gc's size bound.
struct CacheEntryStat {
    pub var path:  string
    pub var at:    u64 = 0 ///< mtime: when it was stored.
    pub var bytes: u64 = 0
}

pub class ObjectCache {
    pub var on: bool = false
    /// <cache-dir>/kairo-cache-v<CACHE_SCHEMA>/<F>: the store for this F.
    pub var dir:    string = ""
    pub var f_hash: string = ""
    /// The run-wide part of every key: the clang diagnostic words (set by
    /// begin_run). The headers are per TU (tu_headers).
    pub var run_part: string = ""
    /// Debug info is on: line tables put token positions in objects
    /// (HashSink's with_locs), and the cc1 words keep their paths.
    pub var with_locs: bool  = false
    pub var reused:    usize = 0
    pub var compiled:  usize = 0
    pub var stored:    usize = 0

    priv var _f_lines:   string                   = "" ///< F's parts, one per line, for the record
    priv var _diag_part: string                   = "" ///< clang -W words: what clang reports, not what it emits
    priv var _includes:  cxx::std::vector<string> ///< -include files, hashed with the headers
    priv var _fmt:       u8                       = 0 ///< 0 ELF, 1 Mach-O, 2 COFF
    priv var _seq:       u64                      = 0
    /// begin_run's view of the graph for tu_headers: every header file once
    /// (index = rank in path order) with its content hash (filled on first
    /// use) and whether it is imported as C; header kfid -> index; Kairo
    /// module fid -> index into _edges, its import edge targets.
    priv var _hdr_path: cxx::std::vector<string>
    priv var _hdr_hash: cxx::std::vector<string>
    priv var _hdr_c:    cxx::std::vector<u8>
    priv var _hdr_of:   llvm::DenseMap<u64, u32>
    priv var _mod_of:   llvm::DenseMap<u64, u32>
    /// -g only: each header's place in the merged PCH's file order, and the
    /// hash of that order's every prefix (paths and contents).
    priv var _hdr_pos:    cxx::std::vector<u32>
    priv var _prefix:     cxx::std::vector<string>
    priv var _edges:      cxx::std::vector<cxx::std::vector<u32>>
    priv var _hdr_global: string                                  = "" ///< in every TU's headers: the merged-PCH verdict and -include files
    priv var _tu_part:    string                                  = "" ///< the "headers" line of the TU key() was last asked for
    /// The entries this run fetched or stored: gc's size bound never
    /// evicts one, so the generation in use survives however old its
    /// store time is (mtime is when an entry was stored, not used).
    priv var _used: llvm::StringSet<llvm::MallocAllocator>

    fn ObjectCache(self) = default

    /// \brief F for this backend and options, under \p cache_dir; false
    ///        (nothing is cached) without a cache dir or a ready backend.
    pub fn setup(self, be: unsafe *ClangBackend, const cache_dir: string) -> bool {
        self.on = false
        if cache_dir.empty() || be == &null || !be->ready() {
            return false
        }

        var args = be->invocation_args()
        for var a: string in args {
            if a.starts_with("-debug-info-kind=") || a == "-fcoverage-mapping" {
                self.with_locs = true
            }
        }

        self._f_lines = self._fingerprint(be, &args)
        self.f_hash   = ObjectCache::hash(self._f_lines)
        self.dir      = cache_dir + "/" + cache_dir_name() + "/" + self.f_hash
        if !LinkFS::make_dirs(self.dir + "/objects") {
            return false
        }

        var norm = llvm::Triple::normalize(kairo::sref(be->triple()))
        var tt   = llvm::Triple(llvm::Twine(norm))
        if tt.isOSBinFormatMachO() {
            self._fmt = 1
        } else if tt.isOSBinFormatCOFF() {
            self._fmt = 2
        }

        self.on = true
        return true
    }

    /// xxh3-128 of \p s, 32 hex digits.
    pub static fn hash(const s: string) -> string {
        return kairo::std::from_std_string<string>(kairo::objcache_hash128(kairo::sref(s)))
    }

    /// \brief what the run's TUs share: the header files of the graph (by
    ///        content, not yet hashed), the import edges that say which a TU
    ///        can reach, and the clang words that decide what clang reports.
    ///
    /// \param mods   every Kairo TU of the graph.
    /// \param edges  parallel: each one's import edge targets (Kairo modules
    ///               and the header files of its ffi closures alike,
    ///               TranslationUnit::import_edges).
    ///
    /// \details Every TU compiles against the whole graph's headers (one
    ///          merged PCH), but its key holds only the headers its stream can
    ///          reach (tu_headers): a header kcc's graph adds, or one only an
    ///          unrelated module imports, is no input of this TU's C++.
    ///          By content and spelling, never by mtime: a copied checkout
    ///          hashes the same, a touched header does not invalidate.
    pub fn begin_run(self,
                     @inout sets: cxx::std::vector<unsafe *HeaderSet>,
                     merged_ok:   bool,
                     const mods:  cxx::std::vector<u32>,
                     const edges: cxx::std::vector<cxx::std::vector<u32>>) {
        // Each header file once, by path, in path order: the key's lines
        // must not follow which set or which graph listed a file first.
        var paths = cxx::std::vector<string>()
        var kfids = cxx::std::vector<u32>()
        var seen  = llvm::StringMap<u32>()
        for var hs: *HeaderSet in sets {
            for var i: usize = 0; i < hs->files.size(); ++i {
                if hs->files[i].kfid == 0 {
                    continue
                }

                paths.push_back(hs->files[i].path)
                kfids.push_back(hs->files[i].kfid)
            }
        }

        var ix = cxx::std::vector<usize>()
        for var i: usize = 0; i < paths.size(); ++i {
            ix.push_back(i)
        }

        var *pp = &paths
        llvm::sort(ix.begin(), ix.end(), fn (a: usize, b: usize) |pp| -> bool = (*pp)[a] < (*pp)[b])
        for var r: usize = 0; r < ix.size(); ++r {
            var p      = paths[ix[r]]
            var at     = seen.find(kairo::sref(p))
            var h: u32 = 0
            if at == seen.end() {
                h = (self._hdr_path.size() as u32)
                seen.try_emplace(kairo::sref(p), h)
                self._hdr_path.push_back(p)
                self._hdr_hash.push_back("")
                self._hdr_c.push_back(0 as u8)
            } else {
                h = at->second
            }

            self._hdr_of.try_emplace(kfids[ix[r]] as u64, h)
        }

        // A direct import written `ffi "c"` is wrapped in extern "C": the
        // header's line says so (its root file is the closure's first).
        for var hs: *HeaderSet in sets {
            for var i: usize = 0; i < hs->headers.size() && i < hs->c_linkage.size(); ++i {
                if hs->c_linkage[i] == (0 as u8) {
                    continue
                }

                var unsafe *ks = hs->closure_kfids(
                    HeaderSetCache::resolve_spelling(hs, hs->headers[i]),
                )

                if ks->size() == 0 {
                    continue
                }

                var it = self._hdr_of.find((*ks)[0] as u64)
                if it != self._hdr_of.end() {
                    self._hdr_c[it->second as usize] = (1 as u8)
                }
            }
        }

        // -g: the merged PCH's file order, each file once, as clang meets
        // it (the sets in the order the PCH takes them, each set's files
        // in first-touch order), and the running hash of its prefixes
        // (tu_headers says why).
        if self.with_locs {
            var placed = cxx::std::vector<u8>()
            placed.resize(self._hdr_path.size(), 0 as u8)
            self._hdr_pos.resize(self._hdr_path.size(), u32::MAX)
            var run = ""
            for var hs: *HeaderSet in sets {
                for var i: usize = 0; i < hs->files.size(); ++i {
                    var it = self._hdr_of.find(hs->files[i].kfid as u64)
                    if it == self._hdr_of.end() {
                        continue
                    }

                    var h = (it->second as usize)
                    // System headers only (tu_headers says why).
                    if !hs->files[i].is_system {
                        continue
                    }

                    if placed[h] != (0 as u8) {
                        continue
                    }

                    placed[h]        = (1 as u8)
                    self._hdr_pos[h] = (self._prefix.size() as u32)
                    run = ObjectCache::hash(
                        run + "\n" + self._hdr_path[h] + " " + self._content_of(h),
                    )

                    self._prefix.push_back(run)
                }
            }
        }

        for var i: usize = 0; i < mods.size(); ++i {
            self._mod_of.try_emplace(mods[i] as u64, (i as u32))
        }

        self._edges = edges

        var g = f"merged {merged_ok}\n"
        for var p: string in self._includes {
            g += "include " + (if (self.with_locs) => (p)
                               else => LinkFS::filename(
                                   p,
                               )) + " " + kairo::std::from_std_string<string>(
                kairo::objcache_file_hash(kairo::sref(p)),
            ) + "\n"
        }

        self._hdr_global = g
        self.run_part    = "diag " + ObjectCache::hash(self._diag_part) + "\n"
    }

    /// \brief the hash of the headers TU \p fid's key holds: every header
    ///        file reachable from a module its stream draws on.
    ///
    /// \param files  the files its stream's anchored tokens came from
    ///               (HashSink::files).
    ///
    /// \details The modules are the TU and every module a token came from
    ///          (an imported signature, an inline body, a witness row of
    ///          a module the TU does not import); from each, its imports,
    ///          transitively, and the header files of every ffi closure on
    ///          the way, plus any header a token came from directly. That is
    ///          everything the stream can name a header declaration through.
    ///          Each line: the file's name (its whole path under -g, where
    ///          debug info records it), its content hash, and `c` when it is
    ///          imported as C. A header no such module reaches is not in the
    ///          key even though the merged PCH holds it
    ///          (Compiler/Spec/Incremental.md, deviation 3).
    pub fn tu_headers(self, fid: u32, const files: cxx::std::vector<u32>) -> string {
        var hmark = cxx::std::vector<u8>()
        hmark.resize(self._hdr_path.size(), 0 as u8)
        var mmark = cxx::std::vector<u8>()
        mmark.resize(self._edges.size(), 0 as u8)
        var work  = cxx::std::vector<usize>()
        var start = files
        start.push_back(fid)
        for var f: u32 in start {
            var mi = self._mod_of.find(f as u64)
            if mi != self._mod_of.end() {
                if mmark[mi->second as usize] == (0 as u8) {
                    mmark[mi->second as usize] = (1 as u8)
                    work.push_back(mi->second as usize)
                }

                continue
            }

            var hi = self._hdr_of.find(f as u64)
            if hi != self._hdr_of.end() {
                hmark[hi->second as usize] = (1 as u8)
            }
        }

        while !work.empty() {
            var m = work[work.size() - 1]
            work.pop_back()
            for var t: u32 in self._edges[m] {
                var mi = self._mod_of.find(t as u64)
                if mi != self._mod_of.end() {
                    if mmark[mi->second as usize] == (0 as u8) {
                        mmark[mi->second as usize] = (1 as u8)
                        work.push_back(mi->second as usize)
                    }

                    continue
                }

                var hi = self._hdr_of.find(t as u64)
                if hi != self._hdr_of.end() {
                    hmark[hi->second as usize] = (1 as u8)
                }
            }
        }

        var h         = self._hdr_global
        var last: u32 = u32::MAX
        for var i: usize = 0; i < hmark.size(); ++i {
            if hmark[i] == (0 as u8) {
                continue
            }

            var name = if (self.with_locs) => (self._hdr_path[i])
                       else => LinkFS::filename(self._hdr_path[i])
            h += name + " " + self._content_of(i)
            if self._hdr_c[i] != (0 as u8) {
                h += " c"
            }

            h += "\n"
            if self.with_locs && i < self._hdr_pos.size() && self._hdr_pos[i] != u32::MAX {
                if last == u32::MAX || self._hdr_pos[i] > last {
                    last = self._hdr_pos[i]
                }
            }
        }

        // -g: debug info names the FIRST declaration of a header entity
        // the object uses, and with every set in one PCH that can be in a
        // file this TU does not reach: C library headers repeat typedefs
        // behind guards (glibc's ssize_t in <stdio.h>, <unistd.h> and
        // <sys/types.h>), so whichever another module's import put first
        // declares it. Such a file is met before the last one this TU
        // reaches (the entity is declared there too), so every system file
        // up to it, in the PCH's order, with its content, is in the key; the
        // ones after it cannot declare first what this TU uses. Project and
        // LLVM headers (not system) define each entity once, behind one
        // guard, so their order does not move a declaration (Incremental.md,
        // deviation 3). Without -g a declaration's place never reaches the
        // object.
        if last != u32::MAX {
            h += "prefix " + self._prefix[last as usize] + "\n"
        }

        return ObjectCache::hash(h)
    }

    /// The content hash of header \p i, computed once.
    priv fn _content_of(self, i: usize) -> string {
        if self._hdr_hash[i].empty() {
            self._hdr_hash[i] = kairo::std::from_std_string<string>(
                kairo::objcache_file_hash(kairo::sref(self._hdr_path[i])),
            )
        }

        return self._hdr_hash[i]
    }

    /// O(m) for a TU whose stream hashed to \p stream and whose reachable
    /// headers to \p headers (tu_headers); \p iface is whether it compiles
    /// under an interface PCH (what clang loads differs), and \p writer
    /// the module of the PCH's first TU, which writes the stream helpers
    /// every TU of the PCH shares: anchored at that TU's file, they put its
    /// name in a -g object's debug info, so with -g it is in the key (and
    /// ignored without: nothing else of the writer reaches an object).
    ///
    /// Remembers \p headers for the record and fetch of the same TU, which
    /// the driver asks for next.
    pub fn key(self,
               const stream:  string,
               iface:         bool,
               const headers: string,
               const writer:  string) -> string {
        self._tu_part = "headers " + headers + "\n"
        var w = if (iface && self.with_locs) => ("iface-writer " + writer + "\n") else => ""
        return ObjectCache::hash(
            f"F {self.f_hash}\nstream {stream}\n{self._tu_part}{self.run_part}iface {iface}\n{w}emit obj\n",
        )
    }

    /// The record \p key's object carries (Compiler/Spec/Incremental.md#keys-in-the-object).
    pub fn record(self,
                  const key:      string,
                  const modname:  string,
                  const src_hash: string,
                  const stream:   string) -> string {
        var r = cache_record_magic() + "\n"
        r += f"schema {CACHE_SCHEMA}\n"
        r += "F " + self.f_hash + "\n"
        r += "O " + key + "\n"
        r += "module " + modname + "\n"
        r += "src " + src_hash + "\n"
        r += "stream " + stream + "\n"
        r += self._tu_part
        r += self.run_part
        r += self._f_lines
        r += "end\n"
        return r
    }

    /// \brief the record as one top-level `asm(...)` string for the TU's
    ///        stream: a section of its own, kept out of every link by its
    ///        flags, then back to .text.
    ///
    /// \details In the stream rather than added to the object after: the
    ///          object is written once, by clang, and an object cut short
    ///          by a crash has no complete record to match. The record holds
    ///          only [A-Za-z0-9 ._:/+=,()-] (_clean), so it needs no quoting
    ///          beyond the C++ literal's own.
    pub fn record_asm(self, const record: string) -> string {
        var open = ""
        if self._fmt == (1 as u8) {
            open = ".section __KAIRO,__cache,regular,debug"
        } else if self._fmt == (2 as u8) {
            open = ".section .kcache,\x22dn\x22"
        } else {
            open = ".pushsection .kairo.cache,\x22e\x22,%progbits"
        }

        var close        = if (self._fmt == (0 as u8)) => (".popsection") else => ".text"
        var body         = ""
        var start: usize = 0
        for var i: usize = 0; i <= record.size(); ++i {
            if i < record.size() && record[i] != ('\n' as u8) {
                continue
            }

            if i > start {
                body += ".ascii \x22" + record.subslice(start, i - start) + "\\n\x22\n"
            }

            start = i + 1
        }

        var text = open + "\n" + body + close + "\n"
        // As a C++ string literal: the asm text's quotes and newlines escaped.
        var lit = "\x22"
        for var i: usize = 0; i < text.size(); ++i {
            var c = text[i]
            if c == ('\n' as u8) {
                lit += "\\n"
            } else if c == ('\x22' as u8) {
                lit += "\\\x22"
            } else if c == ('\\' as u8) {
                lit += "\\\\"
            } else {
                lit += text.subslice(i, 1)
            }
        }

        lit += "\x22"
        return lit
    }

    /// \brief makes \p out hold \p key's object: true when it already does
    ///        (its own record says so) or when the store has one, copied in.
    ///        False is a miss: compile it.
    ///
    /// \param why  on a miss of an \p out that holds an older record, the
    ///             record lines that differ, for -v.
    pub fn fetch(self, const key: string, const out: string, @inout why: string) -> bool {
        if !self.on {
            return false
        }

        // The store decides, never \p out alone: \p out carries the record of
        // every object compiled with the cache on, stored or not, and one
        // clang reported on is never stored (its diagnostics are not in
        // the record), so trusting \p out would drop them on the next run.
        // \p out matching too only saves the copy.
        var have  = ObjectCache::_record_of(out)
        var entry = self._entry(key)
        if ObjectCache::_record_key(ObjectCache::_record_of(entry)) != key {
            if ObjectCache::_record_key(have) == key {
                why = " nothing, but clang reported on it, so it was not stored"
            } else if !have.empty() {
                why = self._diff(have)
            }

            return false
        }

        if ObjectCache::_record_key(have) == key {
            self._used.insert(kairo::sref(entry))
            return true
        }

        if self._copy_into(entry, out) {
            self._used.insert(kairo::sref(entry))
            return true
        }

        if !have.empty() {
            why = self._diff(have)
        }

        return false
    }

    /// \brief stores \p out (just compiled under \p key, with no
    ///        diagnostics) as the store's entry for \p key; true when stored.
    ///        Only an object whose own record names \p key is stored, so a
    ///        compile that wrote something else can never be served.
    pub fn store(self, const key: string, const out: string) -> bool {
        if !self.on {
            return false
        }

        if ObjectCache::_record_key(ObjectCache::_record_of(out)) != key {
            return false
        }

        var entry = self._entry(key)
        // Content addressed: an entry whose record names this key is these
        // bytes already. One that does not (cut short, edited, foreign) is
        // replaced, or it would be a miss on every run.
        if ObjectCache::_record_key(ObjectCache::_record_of(entry)) == key {
            self._used.insert(kairo::sref(entry))
            return true
        }

        if !self._copy_into(out, entry) {
            return false
        }

        self._used.insert(kairo::sref(entry))
        self.stored += 1
        return true
    }

    /// \brief removes what no store has refreshed for 30 days, and private
    ///        copies a crashed store left (a day old); then, while the
    ///        entries left hold more than CACHE_OBJECTS_MAX_BYTES, the
    ///        oldest-stored ones this run did not use, down to three
    ///        quarters of it (P908: a
    ///        worktree's debug cache grew to 2.8 GB in an afternoon, every
    ///        build of a changed tree storing a full new generation). Run
    ///        once per run that stored, which a fully reused run never is.
    ///
    /// \details mtime is when an entry was stored, not last used: an old
    ///          entry still in use is removed and rebuilt on the next miss,
    ///          which costs one compile and is never wrong. Removing one
    ///          cannot break a parallel build that shares the store: fetch
    ///          copies an entry out, and a copy that finds it gone is a miss.
    ///          An entry this run fetched or stored is kept (_used), and so
    ///          is one stored in the last CACHE_RECENT_STORE_NS, a parallel
    ///          run's fresh generation.
    pub fn gc(self) {
        if !self.on || self.stored == 0 {
            return
        }

        var now = (cxx::std::chrono::duration_cast<cxx::std::chrono::nanoseconds>(
            cxx::std::chrono::system_clock::now().time_since_epoch(),
        ).count() as u64)
        var objs  = self.dir + "/objects"
        var kept  = cxx::std::vector<CacheEntryStat>()
        var total: u64 = 0
        for var name: string in LinkFS::list_dir(objs) {
            var p       = objs + "/" + name
            var partial = name.ends_with(".tmp")
            var last    = LinkFS::mtime(p)
            var limit   = if (partial) => (CACHE_PARTIAL_MAX_AGE_NS) else => CACHE_ENTRY_MAX_AGE_NS
            if last != 0 && now > last && now - last > limit {
                LinkFS::remove(p)
                continue
            }

            if !partial {
                var bytes = LinkFS::size(p)
                kept.push_back(CacheEntryStat { path: p, at: last, bytes: bytes })
                total += bytes
            }
        }

        if total <= CACHE_OBJECTS_MAX_BYTES {
            return
        }

        llvm::sort(
            kept.begin(),
            kept.end(),
            fn (const a: CacheEntryStat, const b: CacheEntryStat) || -> bool = a.at < b.at,
        )

        var target = CACHE_OBJECTS_MAX_BYTES / 4 * 3
        for var i: usize = 0; i < kept.size() && total > target; ++i {
            if kept[i].at != 0 && (kept[i].at >= now || now - kept[i].at < CACHE_RECENT_STORE_NS) {
                break // sorted: everything after it is as recent
            }

            if self._used.contains(kairo::sref(kept[i].path)) {
                continue
            }

            LinkFS::remove(kept[i].path)
            total -= kept[i].bytes
        }
    }

    priv fn _entry(self, const key: string) -> string {
        return self.dir + "/objects/" + key + ".o"
    }

    /// Through a private name and a rename, so a parallel build (two
    /// builds may share a cache) reads the whole object or none.
    priv fn _copy_into(self, const from: string, const to: string) -> bool {
        self._seq += 1
        var tmp = f"{to}.{llvm::sys::Process::getProcessId()}-{self._seq}.tmp"
        var ec = llvm::sys::fs::copy_file(
            llvm::Twine(kairo::sref(from)),
            llvm::Twine(kairo::sref(tmp)),
        )

        if ec.value() != 0 {
            LinkFS::remove(tmp)
            return false
        }

        if !LinkFS::rename(tmp, to) {
            LinkFS::remove(tmp)
            return false
        }

        return true
    }

    /// The record section of \p path, "" when there is none or it is not
    /// ours.
    priv static fn _record_of(const path: string) -> string {
        if !LinkFS::is_file(path) {
            return ""
        }

        var r = kairo::std::from_std_string<string>(kairo::objcache_record(kairo::sref(path)))
        if !r.starts_with(cache_record_magic() + "\n") {
            return ""
        }

        return r
    }

    /// The O line of a record of this schema that ends whole; "" otherwise.
    priv static fn _record_key(const r: string) -> string {
        if r.empty() || !r.ends_with("end\n") {
            return ""
        }

        if ObjectCache::_find(r, f"\nschema {CACHE_SCHEMA}\n") == usize::MAX {
            return ""
        }

        var at = ObjectCache::_find(r, "\nO ")
        if at == usize::MAX {
            return ""
        }

        var start = at + 3
        var stop  = start
        while stop < r.size() && r[stop] != ('\n' as u8) {
            stop += 1
        }

        return r.subslice(start, stop - start)
    }

    /// The lines of \p have that a record built now would not hold: the
    /// parts that changed (stream, headers, an F part), for -v.
    priv fn _diff(self, const have: string) -> string {
        var out          = ""
        var start: usize = 0
        for var i: usize = 0; i <= have.size(); ++i {
            if i < have.size() && have[i] != ('\n' as u8) {
                continue
            }

            var line = have.subslice(start, i - start)
            start = i + 1
            var sp = ObjectCache::_find(line, " ")
            if sp == usize::MAX {
                continue
            }

            if line.starts_with("headers ") {
                if self._tu_part != line + "\n" {
                    out += " " + line.subslice(0, sp)
                }
            } else if line.starts_with("diag ") {
                if ObjectCache::_find(self.run_part, line + "\n") == usize::MAX {
                    out += " " + line.subslice(0, sp)
                }
            } else if line.starts_with(fingerprint_prefix()) {
                if ObjectCache::_find(self._f_lines, line + "\n") == usize::MAX {
                    out += " " + line.subslice(0, sp)
                }
            }
        }

        if out.empty() {
            out = " stream"
        }

        return out
    }

    /// \brief F's parts, one per line.
    ///
    /// \details The version counts by its core, MAJOR.MINOR.PATCH: release
    ///          metadata after it does not (Incremental.md#global-invalidation).
    ///          A development build ("+dev", "+rc", "unknown") adds its own
    ///          executable's content hash: two development compilers of one
    ///          core emit different objects, and this tree's lit suite and
    ///          build.py re-run against caches a previous compiler filled, so
    ///          trusting the core there would serve stale objects as fresh
    ///          (Incremental.md#development-builds records the deviation).
    ///
    ///          The cc1 words go in whole but for the diagnostic ones (-W:
    ///          they change what clang reports, which keys separately as
    ///          run_part's diag, not what it emits), and, without debug
    ///          info, the ones that only name a path: include roots, the
    ///          resource dir, the sysroot and the compilation dir reach an
    ///          object only through the headers they find (hashed by
    ///          content) or through debug info. With -g they stay, since the
    ///          object records them.
    priv fn _fingerprint(self,
                         be:   unsafe *ClangBackend,
                         args: *cxx::std::vector<string>) -> string {
        var ver  = string(unsafe ((kairo::version_string() as unsafe *const u8) as *const u8))
        var core = ObjectCache::_version_core(ver)
        var out  = fingerprint_schema_key() + f" {CACHE_SCHEMA}\n"
        out += fingerprint_version_key() + " " + core + "\n"
        var dev = core.empty()
            || ObjectCache::_find(ver, "+dev") != usize::MAX
            || ObjectCache::_find(ver, "+rc") != usize::MAX
            || ver == "unknown"
        if dev {
            var exe = env::exe_path()
            out += "f.build " + kairo::std::from_std_string<string>(
                kairo::objcache_file_hash(kairo::sref(exe)),
            ) + "\n"
        }

        out += "f.clang " + ObjectCache::_clean(
            kairo::std::from_std_string<string>(kairo::objcache_clang_version()),
        ) + "\n"
        out += "f.triple " + ObjectCache::_clean(be->triple()) + "\n"

        var opts      = ""
        var skip_next = false
        var n         = args->size()
        for var i: usize = 0; i < n; ++i {
            var a = (*args)[i]
            if skip_next {
                skip_next = false
                continue
            }

            if a == "-include" && i + 1 < n {
                self._includes.push_back((*args)[i + 1])
                skip_next = true
                continue
            }

            if a.starts_with("-W") {
                self._diag_part += a + "\n"
                continue
            }

            // The header search roots, with or without -g: what they find is
            // in each TU's headers by content (and, with -g, by the path the
            // debug info records), so a root that finds nothing a TU reaches
            // (kfmt's own -I) does not split the store from kairo's.
            if a == "-I" || a == "-iquote" || a == "-isystem" || a == "-idirafter" {
                skip_next = true
                continue
            }

            if a.starts_with("-I")
                || a.starts_with("-isystem")
                || a.starts_with("-iquote")
                || a.starts_with("-idirafter") {
                continue
            }

            if !self.with_locs {
                if a == "-resource-dir"
                    || a == "-isysroot"
                    || a == "-internal-isystem"
                    || a == "-internal-externc-isystem"
                    || a == "-main-file-name" {
                    skip_next = true
                    continue
                }

                if a.starts_with("-fdebug-compilation-dir")
                    || a.starts_with("-fcoverage-compilation-dir") {
                    continue
                }
            }

            opts += a + "\n"
        }

        out += "f.options " + ObjectCache::hash(opts) + "\n"
        return out
    }

    /// `0.2.0` of `kairo-0.2.0+dev.20261108`: the first MAJOR.MINOR.PATCH
    /// run of digits and dots; "" when there is none.
    priv static fn _version_core(const v: string) -> string {
        var n = v.size()
        for var i: usize = 0; i < n; ++i {
            if v[i] < ('0' as u8) || v[i] > ('9' as u8) {
                continue
            }

            if i > 0 && v[i - 1] >= ('0' as u8) && v[i - 1] <= ('9' as u8) {
                continue
            }

            var j    = i
            var dots = 0
            while j < n && (v[j] >= ('0' as u8) && v[j] <= ('9' as u8) || v[j] == ('.' as u8)) {
                if v[j] == ('.' as u8) {
                    dots += 1
                }

                j += 1
            }

            if dots == 2 && v[j - 1] != ('.' as u8) {
                return v.subslice(i, j - i)
            }

            i = j
        }

        return ""
    }

    /// \p s with every byte outside [A-Za-z0-9 ._:/+=,()-] as `_`: what a
    /// record line may hold (record_asm writes it into an .ascii string).
    priv static fn _clean(const s: string) -> string {
        var out = ""
        for var i: usize = 0; i < s.size(); ++i {
            var c = s[i]
            var ok = c >= ('a' as u8) && c <= ('z' as u8)
                || c >= ('A' as u8) && c <= ('Z' as u8)
                || c >= ('0' as u8) && c <= ('9' as u8)
                || c == (' ' as u8)
                || c == ('.' as u8)
                || c == ('_' as u8)
                || c == (':' as u8)
                || c == ('/' as u8)
                || c == ('+' as u8)
                || c == ('=' as u8)
                || c == (',' as u8)
                || c == ('(' as u8)
                || c == (')' as u8)
                || c == ('-' as u8)
            if ok {
                out += s.subslice(i, 1)
            } else {
                out += "_"
            }
        }

        return out
    }

    /// Byte offset of the first \p needle in \p hay, usize::MAX when absent.
    priv static fn _find(const hay: string, const needle: string) -> usize {
        var n = hay.size()
        var m = needle.size()
        if m > n {
            return usize::MAX
        }

        for var i: usize = 0; i + m <= n; ++i {
            var j: usize = 0
            while j < m && hay[i + j] == needle[j] {
                j += 1
            }

            if j == m {
                return i
            }
        }

        return usize::MAX
    }

    /// A module path for the record: its own characters cleaned the same way.
    pub static fn clean(const s: string) -> string {
        return ObjectCache::_clean(s)
    }
}
