/// --- The Kairo Project ----------------------------- Native/KShims.hh --- ///
///
///   One-line C/C++ spellings that Kairo has no syntax for, given names so
///   Kairo code can use them.
///
///   WHY C++: each of these used to be an inline C++ expression at its use
///   site. Stage 1 does not emit inline foreign code, and none of them is
///   worth a language feature on its own:
///
///     volatile_i64    `volatile` is not a Kairo qualifier on a local.
///     posix_stat      `struct stat`: in C++ the function stat() hides the
///                     struct's name, so it needs the elaborated specifier.
///     phys_footprint  the mach task_info call behind kwatch's RSS reading.
///
///   It also includes the platform headers behind the POSIX calls Kairo
///   code names (mmap, open, isatty, ...), under the same guards.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

#ifndef __KAIRO_NATIVE_KSHIMS_HH__
#define __KAIRO_NATIVE_KSHIMS_HH__

#include "KPrelude.hh"
#include "AddrRanges.hh"

#if !defined(_WIN32)
#include <sys/stat.h>
// The POSIX calls Stage 0 reached through lib-helix's includes: mmap /
// munmap / PROT_* / MAP_* (MMapRegion.k), open / O_RDONLY (MMapRegion.k),
// close / isatty (MMapRegion.k, PrettyConsumer.k, Config/Diagnostic.k).
// A .k file that names them imports this header (the self-host migration's
// ffi_imports.py), so the platform choice stays in C++.
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#else
// isatty / fileno (the console checks): <io.h> declares the POSIX names.
#include <io.h>
#endif
// fileno
#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif
#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>
#if defined(__GLIBC__)
#include <malloc.h>
#endif

// LLVM_VERSION_MAJOR (kairo::llvm_version_major below); the compiler always
// builds against LLVM, but the guard keeps this header usable without it.
#if __has_include(<llvm/Config/llvm-config.h>)
#include <llvm/Config/llvm-config.h>
#include <llvm/Support/FileSystem.h>
#include <llvm/Support/raw_ostream.h>
#endif

#if defined(__APPLE__)
#include <mach/mach.h>
#include <mach/task_info.h>
#endif

namespace kairo {

/// A local the optimizer must materialize on every store. The timer-overhead
/// probes store into one so the clock reads between the stores are not
/// folded away.
using volatile_i64 = volatile i64;

#if !defined(_WIN32)
/// The POSIX stat record, for fstat(). Value-initialize it: `posix_stat()`.
using posix_stat = struct ::stat;
#endif

/// Current physical footprint of this process in KiB, the number Activity
/// Monitor shows (resident + compressed + IOKit mappings), or 0 when the
/// query fails. macOS only; 0 everywhere else.
inline unsigned long long phys_footprint_kib() {
#if defined(__APPLE__)
    task_vm_info_data_t    info{};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;

    if (task_info(mach_task_self(), TASK_VM_INFO,
                  reinterpret_cast<task_info_t>(&info), &count) != KERN_SUCCESS) {
        return 0ull;
    }

    return (unsigned long long)info.phys_footprint / 1024ull;
#else
    return 0ull;
#endif
}

} // namespace kairo

// The runtime's heap is mimalloc wherever it replaces malloc (Lib/rt/
// mimalloc.c: ELF and wasm). Its headers are on that one file's include
// path only, so the three entry points the census below needs are declared
// here, weakly: a link without mimalloc leaves them null and the census
// says 0.
extern "C" {
struct kairo_mi_heap_area {
    void  *blocks;
    size_t reserved;
    size_t committed;
    size_t used;       ///< blocks in use
    size_t block_size; ///< bytes of one
    size_t full_block_size;
    void  *reserved1;
};
struct mi_heap_s;
#if defined(__ELF__)
__attribute__((weak)) struct mi_heap_s *mi_heap_main(void);
__attribute__((weak)) void mi_collect(bool force);
__attribute__((weak)) bool mi_heap_visit_blocks(struct mi_heap_s *heap,
                                                bool              visit_blocks,
                                                bool (*visitor)(const struct mi_heap_s *,
                                                                const struct kairo_mi_heap_area *,
                                                                void *,
                                                                size_t,
                                                                void *),
                                                void *arg);
#endif
}

namespace kairo {

/// What the heap holds, by block size: every mimalloc page of the process
/// (all threads), blocks in use times their size.
struct HeapCensus {
    static constexpr size_t SLOTS = 512;
    size_t in_use    = 0; ///< bytes in blocks handed out and not freed
    size_t committed = 0; ///< bytes of the pages holding them
    size_t n         = 0;
    size_t size[SLOTS]  = {};
    size_t count[SLOTS] = {};

    void add(size_t block_size, size_t used) {
        in_use += block_size * used;
        for (size_t i = 0; i < n; ++i) {
            if (size[i] == block_size) {
                count[i] += used;
                return;
            }
        }

        // Past the table every block is one of the huge ones, each its own
        // size: they share the last slot (size 0).
        if (n == SLOTS - 1) {
            size[n] = 0;
            ++n;
        }

        size_t at = (n < SLOTS) ? n++ : SLOTS - 1;
        if (at == SLOTS - 1 && size[at] == 0) {
            count[at] += block_size * used;
            return;
        }

        size[at]  = block_size;
        count[at] = used;
    }
};

#if defined(__ELF__)
inline bool heap_census_visit(const struct mi_heap_s *,
                              const struct kairo_mi_heap_area *area,
                              void *,
                              size_t,
                              void *arg) {
    auto *c = static_cast<HeapCensus *>(arg);
    c->committed += area->committed;
    c->add(area->block_size, area->used);
    return true;
}
#endif

/// Fills \p out; false where the heap is not mimalloc. Not a fast call:
/// it walks every page (a debug line's, KAIRO_LIVE_DEBUG).
inline bool heap_census(HeapCensus &out) {
#if defined(__ELF__)
    if (mi_heap_main == nullptr || mi_heap_visit_blocks == nullptr) {
        return false;
    }

    return mi_heap_visit_blocks(mi_heap_main(), false, &heap_census_visit, &out);
#else
    (void)out;
    return false;
#endif
}

/// The block sizes whose bytes in use moved most between \p a and \p b,
/// as text: `+12.3 MB in 4096 B blocks (+3150)`, largest first, \p top of
/// them.
inline ::std::string heap_census_delta(const HeapCensus &a, const HeapCensus &b, size_t top) {
    struct Row {
        size_t    size;
        long long blocks;
        long long bytes;
    };
    ::std::vector<Row> rows;
    for (size_t i = 0; i < b.n; ++i) {
        long long was = 0;
        for (size_t k = 0; k < a.n; ++k) {
            if (a.size[k] == b.size[i]) {
                was = (long long)a.count[k];
            }
        }

        long long d = (long long)b.count[i] - was;
        if (d != 0) {
            rows.push_back({b.size[i], d, b.size[i] == 0 ? d : d * (long long)b.size[i]});
        }
    }

    ::std::sort(rows.begin(), rows.end(), [](const Row &x, const Row &y) {
        return (x.bytes < 0 ? -x.bytes : x.bytes) > (y.bytes < 0 ? -y.bytes : y.bytes);
    });

    ::std::string out;
    char        buf[160];
    for (size_t i = 0; i < rows.size() && i < top; ++i) {
        if (rows[i].size == 0) {
            snprintf(buf, sizeof buf, "  %+.2f MB in huge blocks\n", (double)rows[i].bytes / 1048576.0);
        } else {
            snprintf(buf, sizeof buf, "  %+.2f MB in %zu B blocks (%+lld)\n", (double)rows[i].bytes / 1048576.0, rows[i].size, rows[i].blocks);
        }

        out += buf;
    }

    return out;
}

/// One word of the heap that holds an address inside a dead range.
struct HeapScanHit {
    uintptr_t block;  ///< the heap block holding the word
    size_t    size;   ///< its size
    size_t    offset; ///< the word's offset in it
    uintptr_t value;
};

struct HeapScan {
    const AddrRanges *dead;
    const AddrRanges *own; ///< the dead trees' own heap objects: not holders
    HeapScanHit      *hits;
    size_t            cap;
    size_t            n     = 0; ///< hits kept
    size_t            total = 0; ///< hits met
    size_t            words = 0;
    const void       *skip[4] = {};
};

#if defined(__ELF__)
inline bool heap_scan_visit(const struct mi_heap_s *,
                            const struct kairo_mi_heap_area *,
                            void  *block,
                            size_t block_size,
                            void  *arg) {
    if (block == nullptr) {
        return true;
    }

    auto *s = static_cast<HeapScan *>(arg);
    // A dead tree's own block (kept by the arena recycler, or poisoned) is
    // not a holder; nor are this scan's tables.
    if (s->dead->find((uintptr_t)block) != nullptr || s->own->find((uintptr_t)block) != nullptr) {
        return true;
    }

    for (const void *k : s->skip) {
        if (k == block) {
            return true;
        }
    }

    const uintptr_t *w = static_cast<const uintptr_t *>(block);
    size_t           n = block_size / sizeof(uintptr_t);
    s->words += n;
    for (size_t i = 0; i < n; ++i) {
        uintptr_t v = w[i];
        if (v < s->dead->lo || v >= s->dead->hi) {
            continue;
        }

        // The first byte of a range is not counted: a block that ends
        // where a dead one starts has its one-past-the-end pointers there
        // (a vector's end and capacity).
        const AddrRanges::Range *r = s->dead->find(v);
        if (r == nullptr || r->lo == v) {
            continue;
        }

        ++s->total;
        if (s->n < s->cap) {
            s->hits[s->n++] = {(uintptr_t)block, block_size, i * sizeof(uintptr_t), v};
        }
    }

    return true;
}
#endif

struct HeapHolder {
    uintptr_t lo;
    uintptr_t hi;
    uintptr_t skip;
    uintptr_t block = 0;
    size_t    size  = 0;
    size_t    offset = 0;
};

#if defined(__ELF__)
inline bool heap_holder_visit(const struct mi_heap_s *,
                              const struct kairo_mi_heap_area *,
                              void  *block,
                              size_t block_size,
                              void  *arg) {
    auto *s = static_cast<HeapHolder *>(arg);
    if (block == nullptr || (uintptr_t)block == s->skip) {
        return true;
    }

    const uintptr_t *w = static_cast<const uintptr_t *>(block);
    size_t           n = block_size / sizeof(uintptr_t);
    for (size_t i = 0; i < n; ++i) {
        if (w[i] >= s->lo && w[i] < s->hi) {
            s->block  = (uintptr_t)block;
            s->size   = block_size;
            s->offset = i * sizeof(uintptr_t);
            return false;
        }
    }

    return true;
}
#endif

/// \brief every word of every live heap block that holds an address inside
///        \p dead, as text: how many, and the first \p max of them with
///        the block that holds each (\p where names it when it is a block
///        of a labelled range: a kept tree's arena, a store's) and the
///        range pointed into. `clean` when there is none.
///
/// \details A conservative scan: a word is taken for a pointer by its
///          value. It reads what the allocator has handed out and nothing
///          else, so not the stacks, the globals or thread-locals; and a
///          vector's spare capacity or a dead object in a store's arena
///          still counts, which is why the stores scrub what they drop.
///          \p own is the dead trees' own heap objects (their contexts,
///          their arenas' block records), which are not holders. A
///          live check's self-check after it frees replaced trees
///          (KAIRO_LIVE_DEBUG): anything it reports is a pointer that
///          dangles.
inline ::std::string heap_scan_report(const AddrRanges &dead, const AddrRanges &own, const AddrRanges &where, size_t max, size_t &total) {
    total = 0;
#if defined(__ELF__)
    if (mi_heap_main == nullptr || mi_heap_visit_blocks == nullptr || dead.ranges.empty()) {
        return "not scanned";
    }

    // A block freed and not yet back on its page's free list is visited
    // as live, with whatever it held.
    if (mi_collect != nullptr) {
        mi_collect(true);
    }

    ::std::vector<HeapScanHit> hits(max);
    HeapScan                   scan{&dead, &own, hits.data(), max};
    scan.skip[0] = hits.data();
    scan.skip[1] = dead.ranges.data();
    scan.skip[2] = where.ranges.data();
    scan.skip[3] = own.ranges.data();
    mi_heap_visit_blocks(mi_heap_main(), true, &heap_scan_visit, &scan);
    total = scan.total;
    char          buf[512];
    ::std::string out;
    snprintf(buf, sizeof buf, "%zu MB scanned, %zu words point into a freed tree\n", scan.words * sizeof(uintptr_t) / 1048576, scan.total);
    out += buf;
    for (size_t i = 0; i < scan.n; ++i) {
        const HeapScanHit       &h  = hits[i];
        const AddrRanges::Range *in = where.find(h.block + h.offset);
        const AddrRanges::Range *to = dead.find(h.value);
        snprintf(buf,
                 sizeof buf,
                 "  %s: block %#zx of %zu B, word at +%zu -> %#zx in %s\n",
                 in != nullptr ? where.labels[in->label].c_str() : "the heap",
                 (size_t)h.block,
                 h.size,
                 h.offset,
                 (size_t)h.value,
                 to != nullptr ? dead.labels[to->label].c_str() : "?");
        out += buf;
        // Who holds the holder, a few blocks up: the first block found
        // with a word into it, so one path of possibly several.
        if (i >= 6) {
            continue;
        }

        uintptr_t lo = h.block, hi = h.block + h.size;
        for (int up = 0; up < 5; ++up) {
            HeapHolder hh{lo, hi, lo};
            mi_heap_visit_blocks(mi_heap_main(), true, &heap_holder_visit, &hh);
            if (hh.block == 0) {
                break;
            }

            const AddrRanges::Range *hin = where.find(hh.block + hh.offset);
            snprintf(buf,
                     sizeof buf,
                     "      held by %s: block %#zx of %zu B, word at +%zu\n",
                     hin != nullptr ? where.labels[hin->label].c_str() : "the heap",
                     (size_t)hh.block,
                     hh.size,
                     hh.offset);
            out += buf;
            if (hin != nullptr) {
                break;
            }

            lo = hh.block;
            hi = hh.block + hh.size;
        }
    }

    return out;
#else
    (void)where;
    (void)max;
    return "not scanned";
#endif
}

/// Hands the allocator's free pages back to the system now (mimalloc: a
/// forced collect, which purges them; it does that by itself only as later
/// allocations come by). For the moment after a large free in a process
/// that then sits idle: a live check that has just freed the trees of a
/// core file's re-check, whose host judges it by its resident size.
inline void heap_trim() {
#if defined(__ELF__)
    if (mi_collect != nullptr) {
        mi_collect(true);
    }
#endif
}

/// Bytes the C allocator has handed out and not got back, in KiB (mimalloc:
/// the census; glibc:
/// mallinfo2's in-use arena bytes plus its mmapped blocks), or 0 where the
/// allocator does not say. Against the resident size it tells memory that
/// something still HOLDS from memory the allocator merely has not returned
/// to the system (a live check's debug line, KAIRO_LIVE_DEBUG).
inline unsigned long long heap_in_use_kib() {
    HeapCensus census;
    if (heap_census(census)) {
        return (unsigned long long)census.in_use / 1024ull;
    }

#if defined(__GLIBC__) && defined(__GLIBC_PREREQ)
#if __GLIBC_PREREQ(2, 33)
    struct mallinfo2 mi = mallinfo2();
    return (unsigned long long)(mi.uordblks + mi.hblkhd) / 1024ull;
#else
    return 0ull;
#endif
#else
    return 0ull;
#endif
}

/// The resident size of this process in KiB (Linux: /proc/self/statm), or
/// 0 where that is not read.
inline unsigned long long resident_kib() {
#if defined(__linux__)
    FILE *f = fopen("/proc/self/statm", "r");
    if (f == nullptr) {
        return 0ull;
    }

    unsigned long long size = 0, res = 0;
    int                got  = fscanf(f, "%llu %llu", &size, &res);
    fclose(f);
    return got == 2 ? res * (unsigned long long)sysconf(_SC_PAGESIZE) / 1024ull : 0ull;
#else
    return 0ull;
#endif
}

// C macros have no name a Kairo file can use (an ffi import brings in
// declarations, not the preprocessor), so the ones Kairo code needs are
// spelled here as values and functions, under the same platform guards.
#if !defined(_WIN32)
inline constexpr int o_rdonly    = O_RDONLY;
inline constexpr int prot_read   = PROT_READ;
inline constexpr int map_private = MAP_PRIVATE;
/// MAP_FAILED is `((void *)-1)`: a cast, so not a constant expression.
inline void *map_failed() noexcept { return MAP_FAILED; }
#endif

/// Prefetch for reading into every cache level (`_mm_prefetch(p,
/// _MM_HINT_T0)` on x86, where the scanners used it). The builtin is the
/// same instruction there and the nearest equivalent elsewhere.
inline void prefetch_t0(const void *p) noexcept { __builtin_prefetch(p, 0, 3); }

/// Object-like macros Kairo code reads as values. LLVM_VERSION_MAJOR comes from
/// llvm-config.h (EmitIR's ABI note); VERSION is the build's `-D VERSION="..."`
/// (build.k), absent from builds that do not define it.
#ifdef LLVM_VERSION_MAJOR
inline constexpr int llvm_version_major() noexcept { return LLVM_VERSION_MAJOR; }
#endif
#if defined(KAIRO_VERSION_EXTERN)
/// build.py: the version is defined once, in the tool's meta object
/// (write_meta), not as a define on every TU. A define is a cc1 word, so it is
/// in every incremental object key, and it differs per tool and per day: the
/// tools could not share one object cache (Compiler/Spec/Incremental.md).
extern "C" const char *kairo_version_cstr() noexcept;
inline const char *version_string() noexcept { return kairo_version_cstr(); }
/// The LLVM fork revision the runtimes come from (build.py
/// runtimes_revision(), the same string Scripts/package_release.py writes to
/// share/kairo/runtimes/REVISION). ksys refuses a share tree whose REVISION
/// differs: its runtimes would not match this compiler's headers and ABI.
extern "C" const char *kairo_runtimes_revision_cstr() noexcept;
inline const char *runtimes_revision_string() noexcept { return kairo_runtimes_revision_cstr(); }
#else
inline const char *version_string() noexcept {
#ifdef VERSION
    return VERSION;
#else
    return "unknown";
#endif
}
inline const char *runtimes_revision_string() noexcept { return "unknown"; }
#endif

/// Uses of a header set's clang AST after it was released early
/// (HeaderSet::_note_late). Expected 0; the driver reports a nonzero count.
inline ::std::atomic<unsigned long long> &header_set_late_uses() noexcept {
    static ::std::atomic<unsigned long long> n{0};
    return n;
}

/// -finfer-purity's totals over the build (FnPurityCheck::infer, one add per
/// TU, from the Sema pool); --print-stats reports them.
inline ::std::atomic<unsigned long long> &purity_inferred_const() noexcept {
    static ::std::atomic<unsigned long long> n{0};
    return n;
}
inline ::std::atomic<unsigned long long> &purity_inferred_pure() noexcept {
    static ::std::atomic<unsigned long long> n{0};
    return n;
}

/// Header sets re-parsed after HeaderSet::release_unused.
inline ::std::atomic<unsigned long long> &header_set_revivals() noexcept {
    static ::std::atomic<unsigned long long> n{0};
    return n;
}

#if defined(__ARM_NEON)
/// NEON loads and stores as functions: arm_neon.h defines vld1q_u8 / vst1q_u8 as
/// macros (statement expressions over __builtin_neon_*), which ffi cannot call;
/// vdupq_n_u8 / vceqq_u8 are real inline functions and need nothing.
inline uint8x16_t neon_ld_u8(const uint8_t *p) noexcept { return vld1q_u8(p); }
inline void neon_st_u8(uint8_t *p, uint8x16_t v) noexcept { vst1q_u8(p, v); }
#endif

/// \p text written to \p path byte for byte: no newline translation on any
/// host. llvm::sys::writeFileWithEncoding writes in text mode, so on Windows
/// every '\n' became "\r\n" while LinkFS::read hands bytes back as they are;
/// the Kairo library's manifest read back paths ending in '\r' (2026-11-06).
inline bool write_file_exact(llvm::StringRef path, llvm::StringRef text) noexcept {
    ::std::error_code ec;
    llvm::raw_fd_ostream os(path, ec, llvm::sys::fs::OF_None);
    if (ec) { return false; }
    os << text;
    os.close();
    return !os.has_error();
}

/// The C streams as functions. stdout / stderr are macros on Darwin (__stdoutp) and
/// MinGW (__acrt_iob_func(1)), which ffi cannot name; a function returns what
/// the macro expands to on every libc.
inline FILE *std_out() noexcept { return stdout; }
inline FILE *std_err() noexcept { return stderr; }

}  // namespace kairo

#endif  // __KAIRO_NATIVE_KSHIMS_HH__
