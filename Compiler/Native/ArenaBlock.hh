/// --- The Kairo Project ------------------------- Native/ArenaBlock.hh --- ///
///
///   The zeroing behind ArenaBlock::reset (Native/ArenaBlock.k): the
///   allocated prefix of a block, cleared with AVX-512 streaming stores on
///   x86 or NEON `stnp` on AArch64.
///
///   WHY C++: the x86 path is compiled for AVX-512 whatever the build's
///   floor (`[[gnu::target("avx512f")]]`) and chosen at run time
///   (`__builtin_cpu_supports`, or sysctlbyname on macOS), and the AArch64
///   path is inline assembly. Kairo has no spelling for a per-function
///   target attribute, inline assembly, or that builtin.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

#pragma once
#include "Prelude.hh"

#include "Types.hh"
#if defined(__APPLE__)
#include <sys/sysctl.h>  // sysctlbyname: AVX-512 detection without compiler-rt
#endif

namespace kairo {

#if defined(_x86_64_simd)
[[gnu::target("avx512f")]]
inline void arena_reset_avx512(std::Byte *ptr, size_t len) noexcept {
    const __m512i zero = _mm512_setzero_si512();
    size_t        i    = 0;
    for (; i + 64 <= len; i += 64) {
        _mm512_stream_si512(reinterpret_cast<__m512i *>(ptr + i), zero);
    }
    if (i < len) {
        libcxx::memset(ptr + i, 0, len - i);
    }
    _mm_sfence();
}
#endif

#if defined(_aarch64_simd)
inline void arena_reset_neon(std::Byte *ptr, size_t len) noexcept {
    size_t i = 0;

#if defined(__aarch64__)
    // Non-temporal store pair via inline asm - stnp q0, q1, [addr]
    // Zeroes 32 bytes per iteration without polluting the cache.
    const uint8x16_t zero = vdupq_n_u8(0);
    for (; i + 32 <= len; i += 32) {
        __asm__ volatile("stnp %q1, %q2, [%0]"
                         :
                         : "r"(ptr + i), "w"(zero), "w"(zero)
                         : "memory");
    }
#else
    // Fallback: temporal NEON stores (still vectorized, no stnp)
    const uint8x16_t zero = vdupq_n_u8(0);
    for (; i + 16 <= len; i += 16) {
        vst1q_u8(ptr + i, zero);
    }
#endif

    if (i < len) {
        libcxx::memset(ptr + i, 0, len - i);
    }
}
#endif

/// Zeroes [ptr, ptr + len): the bytes of a block up to its high-water mark.
inline void arena_reset_zero(std::Byte *ptr, size_t len) noexcept {
#if _simd_available()
    if (len < 4096) {
        libcxx::memset(ptr, 0, len);
        return;
    }
#if defined(_x86_64_simd)
    // arena_reset_avx512 is compiled for AVX-512 (gnu::target) whatever the build's
    // floor, so it needs this CPU to have it: on a CPU without AVX-512 (most
    // Intel desktop parts) an x86-64-v2 build would raise SIGILL on the first
    // large arena reset. Checked once.
#if defined(__AVX512F__)
    arena_reset_avx512(ptr, len);
#else
#if defined(__APPLE__)
    // __builtin_cpu_supports reads __cpu_model from compiler-rt, which the
    // macOS link does not pull in (undefined symbol); ask the kernel instead.
    static const bool has_avx512f = [] {
        int v = 0;
        size_t n = sizeof v;
        return sysctlbyname("hw.optional.avx512f", &v, &n, nullptr, 0) == 0 && v != 0;
    }();
#else
    static const bool has_avx512f = __builtin_cpu_supports("avx512f");
#endif
    if (has_avx512f) {
        arena_reset_avx512(ptr, len);
    } else {
        libcxx::memset(ptr, 0, len);
    }
#endif
#elif defined(_aarch64_simd)
    arena_reset_neon(ptr, len);
#else
    libcxx::memset(ptr, 0, len);
#endif
#else
    libcxx::memset(ptr, 0, len);
#endif
}

}  // namespace kairo
