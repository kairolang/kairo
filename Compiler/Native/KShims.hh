/// --- The Kairo Project ------------------------------ Native/KShims.hh --- ///
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
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

#ifndef __KAIRO_NATIVE_KSHIMS_HH__
#define __KAIRO_NATIVE_KSHIMS_HH__

#include "KPrelude.hh"

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
#include <windows.h>
#endif
// fileno
#include <cstdio>

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

}  // namespace kairo

#endif  // __KAIRO_NATIVE_KSHIMS_HH__
