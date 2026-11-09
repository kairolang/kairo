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
 *   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
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

/* NetBSD is not overridden either: its static libc.a keeps malloc in jemalloc.o
 * beside symbols the link needs, so that member is always pulled and its malloc
 * collides with ours ("duplicate symbol: malloc", 2026-11-06). NetBSD's own heap
 * is jemalloc, a fast allocator already. */
#if !defined(_WIN32) && !defined(__APPLE__) && !defined(__NetBSD__) && !defined(MI_MALLOC_OVERRIDE)
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

/* mimalloc's MIT notice, embedded so a program Kairo links needs no separate
 * attribution: the license asks that the notice accompany "all copies or
 * substantial portions of the Software", and this file puts mimalloc in every
 * program. Here and not in a file of its own, because the runtime can be
 * linked lazily (--kairo-lib): an object only pulled in by a reference would
 * need one from always-linked code, while this one is in the link exactly
 * when mimalloc is.
 *
 * Byte for byte Lib/rt/mimalloc/LICENSE, sized to it so the section holds the
 * text and no NUL; regenerate it from that file on a submodule bump that
 * changes it (Tests/Codegen/runtime_notices.k checks the linked text).
 *
 * It must survive dead-stripping on every format, with nothing referencing it:
 *   ELF   `retain` (SHF_GNU_RETAIN) keeps the section from --gc-sections;
 *         `used` alone only keeps it from the compiler.
 *   Mach-O `used` is no_dead_strip, which -dead_strip honours; segment and
 *         section names are at most 16 characters each.
 *   COFF  a named section is not a COMDAT, and -opt:ref (and MinGW's
 *         --gc-sections) removes only COMDATs; on MSVC `used` also writes
 *         an /INCLUDE: directive. lld-link names an output section by the
 *         input's name up to its second period, so the image's reads `.kairo`.
 *   wasm  `used` marks the symbol NO_STRIP, which wasm-ld's gc keeps. */
#if defined(__APPLE__)
#define KAIRO_RT_NOTICE __attribute__((used, section("__TEXT,__kairo_notices")))
#elif defined(__ELF__)
#define KAIRO_RT_NOTICE __attribute__((used, retain, section(".kairo.notices")))
#else
#define KAIRO_RT_NOTICE __attribute__((used, section(".kairo.notices")))
#endif
KAIRO_RT_NOTICE const char kairo_rt_notice_mimalloc[1096] =
    "MIT License\n"
    "\n"
    "Copyright (c) 2018-2025 Microsoft Corporation, Daan Leijen\n"
    "\n"
    "Permission is hereby granted, free of charge, to any person obtaining a copy\n"
    "of this software and associated documentation files (the \"Software\"), to deal\n"
    "in the Software without restriction, including without limitation the rights\n"
    "to use, copy, modify, merge, publish, distribute, sublicense, and/or sell\n"
    "copies of the Software, and to permit persons to whom the Software is\n"
    "furnished to do so, subject to the following conditions:\n"
    "\n"
    "The above copyright notice and this permission notice shall be included in all\n"
    "copies or substantial portions of the Software.\n"
    "\n"
    "THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR\n"
    "IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,\n"
    "FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE\n"
    "AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER\n"
    "LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,\n"
    "OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE\n"
    "SOFTWARE.\n";
#undef KAIRO_RT_NOTICE

/* MinGW: the C heap stays the CRT's (a static exe cannot replace malloc for the
 * CRT DLL, which allocates internally: strdup, fopen, getenv, _wfullpath), but C++
 * operator new / delete are ours. Every new pairs with a delete in this statically
 * linked program, so no block ever crosses heaps, and it is most of what LLVM and
 * clang allocate. Strong definitions win over libc++abi's weak ones. Itanium names
 * with size_t spelled as on the target: `y` (unsigned long long) on 64-bit Windows,
 * `j` (unsigned int) on 32-bit. alloc-override.c has the same list for ELF (`m`),
 * compiled only under MI_MALLOC_OVERRIDE. Apple stays on the system heap until
 * mimalloc's zone override is verified on a Mac. */
#if defined(_WIN32) && defined(__GNUC__) && !defined(_MSC_VER)
typedef struct kairo_rt_nothrow_s { int _tag; } kairo_rt_nothrow_t;
#define KRT_DEL(name, ...) void name(__VA_ARGS__)
KRT_DEL(_ZdlPv, void *p) { mi_free(p); }
KRT_DEL(_ZdaPv, void *p) { mi_free(p); }
KRT_DEL(_ZdlPvSt11align_val_t, void *p, size_t al) { mi_free_aligned(p, al); }
KRT_DEL(_ZdaPvSt11align_val_t, void *p, size_t al) { mi_free_aligned(p, al); }
KRT_DEL(_ZdlPvRKSt9nothrow_t, void *p, kairo_rt_nothrow_t t) { (void)t; mi_free(p); }
KRT_DEL(_ZdaPvRKSt9nothrow_t, void *p, kairo_rt_nothrow_t t) { (void)t; mi_free(p); }
KRT_DEL(_ZdlPvSt11align_val_tRKSt9nothrow_t, void *p, size_t al, kairo_rt_nothrow_t t) { (void)t; mi_free_aligned(p, al); }
KRT_DEL(_ZdaPvSt11align_val_tRKSt9nothrow_t, void *p, size_t al, kairo_rt_nothrow_t t) { (void)t; mi_free_aligned(p, al); }
#if defined(_WIN64)
#define KRT_SZ(a, b) a##y##b
#else
#define KRT_SZ(a, b) a##j##b
#endif
KRT_DEL(KRT_SZ(_ZdlPv, ), void *p, size_t n) { mi_free_size(p, n); }
KRT_DEL(KRT_SZ(_ZdaPv, ), void *p, size_t n) { mi_free_size(p, n); }
KRT_DEL(KRT_SZ(_ZdlPv, St11align_val_t), void *p, size_t n, size_t al) { mi_free_size_aligned(p, n, al); }
KRT_DEL(KRT_SZ(_ZdaPv, St11align_val_t), void *p, size_t n, size_t al) { mi_free_size_aligned(p, n, al); }
void *KRT_SZ(_Znw, )(size_t n) { return mi_new(n); }
void *KRT_SZ(_Zna, )(size_t n) { return mi_new(n); }
void *KRT_SZ(_Znw, RKSt9nothrow_t)(size_t n, kairo_rt_nothrow_t t) { (void)t; return mi_new_nothrow(n); }
void *KRT_SZ(_Zna, RKSt9nothrow_t)(size_t n, kairo_rt_nothrow_t t) { (void)t; return mi_new_nothrow(n); }
void *KRT_SZ(_Znw, St11align_val_t)(size_t n, size_t al) { return mi_new_aligned(n, al); }
void *KRT_SZ(_Zna, St11align_val_t)(size_t n, size_t al) { return mi_new_aligned(n, al); }
void *KRT_SZ(_Znw, St11align_val_tRKSt9nothrow_t)(size_t n, size_t al, kairo_rt_nothrow_t t) { (void)t; return mi_new_aligned_nothrow(n, al); }
void *KRT_SZ(_Zna, St11align_val_tRKSt9nothrow_t)(size_t n, size_t al, kairo_rt_nothrow_t t) { (void)t; return mi_new_aligned_nothrow(n, al); }
#undef KRT_SZ
#undef KRT_DEL
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
