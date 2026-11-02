/* --- The Kairo Project ---------------------------- Lib/rt/mimalloc.c --- */
/*
 *   The runtime's heap: mimalloc, vendored as the git submodule
 *   Lib/rt/mimalloc (pinned to a release tag) and compiled here as one
 *   translation unit. The driver compiles every C file directly in Lib/rt
 *   and adds Lib/rt/mimalloc/include to this one's include path; the
 *   submodule's own sources are reached only through this file.
 *
 *   System (Lib/builtin/base/alloc.k) and the weak kairo_global_* symbols
 *   (rt/global_alloc.c) call mimalloc directly, through rt/alloc.h.
 *
 *   Where a static link can do it -- ELF and wasm -- mimalloc also replaces
 *   malloc, free and the rest of the C heap, so C, C++ and Kairo share one
 *   heap and a block may cross between them. Windows and Apple targets are
 *   not overridden statically (the CRT heap on Windows; malloc zones on
 *   Apple): there, a block Kairo allocates is freed by Kairo, and a block C
 *   or C++ allocates is freed by C or C++.
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
 *   Copyright (c) 2026 Dhruvan Kartik
 */

/* Release build unless asked otherwise: without NDEBUG mimalloc defaults to
 * MI_DEBUG 2, internal assertions on every call. */
#if !defined(MI_DEBUG)
#define MI_DEBUG 0
#endif

/* WASI's PAGE_SIZE is not a preprocessor constant, which types.h tests; and
 * its clock() (process time, for mimalloc's statistics) is declared only
 * under _WASI_EMULATED_PROCESS_CLOCKS and defined only in an extra library,
 * so the runtime defines it below. */
#if defined(__wasi__)
  #if !defined(MI_ARENA_SLICE_SHIFT)
    #define MI_ARENA_SLICE_SHIFT 15
  #endif
  #if !defined(_WASI_EMULATED_PROCESS_CLOCKS)
    #define _WASI_EMULATED_PROCESS_CLOCKS
  #endif
#endif

#if !defined(_WIN32) && !defined(__APPLE__) && !defined(MI_MALLOC_OVERRIDE)
#define MI_MALLOC_OVERRIDE 1
#endif

/* i686: the misaligned 64-bit statistics atomics (see __atomic_load below)
 * are expected; their warning is not actionable here. */
#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Watomic-alignment"
#endif
#include "mimalloc/src/static.c"
#if defined(__clang__)
#pragma clang diagnostic pop
#endif

#if defined(__wasi__)
#include <time.h>
/* Wall time stands in for process time: WASI has no process clock. Weak, so
 * -lwasi-emulated-process-clocks wins when a program links it. */
__attribute__((weak)) clock_t clock(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (clock_t)((long long)ts.tv_sec * CLOCKS_PER_SEC + ts.tv_nsec / (1000000000 / CLOCKS_PER_SEC));
}
#endif

#if defined(__i386__)
#include <stdint.h>
/* i686 aligns int64_t struct members to 4, so the 64-bit atomics on
 * mimalloc's statistics counters are misaligned and clang lowers them to the
 * generic __atomic_load libcall, which compiler-rt's builtins do not provide.
 * Only 8-byte loads reach it: lock cmpxchg8b is atomic at any alignment on
 * x86. Weak, so a linked libatomic wins. */
void kairo_rt_atomic_load_(size_t size, void *src, void *dst, int order) __asm__("__atomic_load");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsync-alignment"
__attribute__((weak)) void kairo_rt_atomic_load_(size_t size, void *src, void *dst, int order) {
    (void)order;
    if (size == 8) {
        uint64_t v = __sync_val_compare_and_swap((volatile uint64_t *)src, 0, 0);
        __builtin_memcpy(dst, &v, 8);
        return;
    }
    __builtin_memcpy(dst, src, size);
}
#pragma clang diagnostic pop
#endif
