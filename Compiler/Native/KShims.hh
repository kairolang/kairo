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
#include <atomic>
#include <cstdio>

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
#else
inline const char *version_string() noexcept {
#ifdef VERSION
    return VERSION;
#else
    return "unknown";
#endif
}
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
