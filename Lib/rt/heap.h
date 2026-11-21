/* --- The Kairo Project ---------------------------------- Lib/rt/heap.h --- */
/*
 *   The runtime heap's out-of-line entry points (rt/heap.c), shared by
 *   System (Lib/builtin/alloc_raw.k, through rt/alloc.h) and the weak
 *   kairo_global_* definitions (rt/global_alloc.c), so a block either one
 *   made is one the other can free, resize and reallocate.
 *
 *   Large blocks. Where KAIRO_RT_HEAP_LARGE is 1 (Linux), a block of at
 *   least KAIRO_RT_HEAP_LARGE_MIN bytes at no more than
 *   KAIRO_RT_HEAP_LARGE_ALIGN alignment may sit in an anonymous mapping of
 *   its own, outside mimalloc, behind a header of 16 bytes (or of its
 *   alignment, when that is more) that records the mapping's length. A
 *   fresh allocation reuses a cached mapping, else maps at or above a
 *   threshold that rises the way glibc's mmap threshold does (rt/heap.c),
 *   else is mimalloc's. A mimalloc block that realloc grows past its usable
 *   size and that threshold moves to a mapping; any other realloc of it
 *   stays in mimalloc. A mapped block:
 *
 *     - grows and shrinks within its mapping's length with no system call;
 *       a shrink to half that length or less gives the tail back;
 *     - realloc past the mapping is mremap, which moves page table entries
 *       rather than bytes (no copy, at any size); resize past it extends
 *       the mapping where the address space after it is free;
 *     - once freed, a mapping of at most KAIRO_RT_HEAP_CACHE_MAX bytes waits
 *       in a process-wide cache of KAIRO_RT_HEAP_CACHE_SLOTS mappings; the
 *       next large allocation (not a zeroed one) takes the shortest that
 *       fits, whole and resident, so an allocate / free or a grow / free
 *       loop maps nothing and faults nothing after its first round. The
 *       cache holds at most KAIRO_RT_HEAP_CACHE_SLOTS *
 *       KAIRO_RT_HEAP_CACHE_MAX bytes, and a block taken from it holds at
 *       most KAIRO_RT_HEAP_CACHE_MAX bytes past its own length.
 *
 *   Nothing outside a mapped block records which heap holds it: every
 *   free, resize and realloc gets the size and alignment the block was last
 *   made with (alloc.k's contract), and mimalloc's page map decides.
 *   A block smaller than KAIRO_RT_HEAP_LARGE_MIN is always mimalloc's: a
 *   mapped block never shrinks below it in place (resize refuses, realloc
 *   moves it). A block of at least that size is mapped unless mimalloc's
 *   page map holds it, which is the case for a fresh one below the
 *   threshold, one realloc kept in mimalloc, one allocated when mmap
 *   failed, and one the C heap made.
 *
 *   Consequence on the targets where mimalloc is also the C heap (ELF): C
 *   or C++ must not free() or realloc() a large block Kairo allocated, since
 *   it is not mimalloc's. The other direction, Kairo freeing a large C-heap
 *   block, works.
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
 *   Copyright (c) 2026 Dhruvan Kartik
 */
#ifndef KAIRO_RT_HEAP_H
#define KAIRO_RT_HEAP_H

#include <stddef.h>

#ifndef KAIRO_RT_NOEXCEPT
#ifdef __cplusplus
#define KAIRO_RT_NOEXCEPT noexcept
#else
#define KAIRO_RT_NOEXCEPT
#endif
#endif

/* mremap is Linux's; no other target has a way to grow a mapping without a
 * copy, so everywhere else every block stays mimalloc's. */
#if defined(__linux__) && !defined(__EMSCRIPTEN__) && !defined(__wasm__)
#define KAIRO_RT_HEAP_LARGE 1
#else
#define KAIRO_RT_HEAP_LARGE 0
#endif

/* glibc's default mmap threshold: below it a block stays in mimalloc's
 * pages, where an allocation costs no system call. */
#define KAIRO_RT_HEAP_LARGE_MIN ((size_t)128 * 1024)
/* The smallest page any supported Linux kernel uses: every mapping starts
 * on one, so this alignment and less come with the mapping. */
#define KAIRO_RT_HEAP_LARGE_ALIGN ((size_t)4096)
#define KAIRO_RT_HEAP_CACHE_SLOTS 4
#define KAIRO_RT_HEAP_CACHE_MAX ((size_t)4 * 1024 * 1024)

/* True when a block of this size and alignment takes the large path. A
 * constant false where there is none, so the branch folds even at -O0.
 * The size is tested first and on its own, as an unlikely branch: a block
 * past mimalloc's small-object paths then pays one compare for it. */
#if KAIRO_RT_HEAP_LARGE
#define KAIRO_RT_HEAP_IS_LARGE(size, align) \
    (__builtin_expect((size) >= KAIRO_RT_HEAP_LARGE_MIN, 0) && (align) <= KAIRO_RT_HEAP_LARGE_ALIGN)
#else
#define KAIRO_RT_HEAP_IS_LARGE(size, align) 0
#endif

#ifdef __cplusplus
#define KAIRO_RT_HEAP_BOOL bool
extern "C" {
#else
#define KAIRO_RT_HEAP_BOOL _Bool
#endif

/* Precondition of the two below: KAIRO_RT_HEAP_IS_LARGE(size, align). */
/* A large block, zeroed when `zeroed` is nonzero; null on failure. */
unsigned char *kairo_rt_heap_large_alloc(size_t size, size_t align, int zeroed) KAIRO_RT_NOEXCEPT;
/* Frees a block made with this large size: unmapped, cached, or (when
 * mimalloc holds it) mimalloc's free. */
void kairo_rt_heap_large_free(unsigned char *ptr, size_t size) KAIRO_RT_NOEXCEPT;

/* The Resizer and Reallocator halves of System, for every size: resize
 * never moves the block (false: nothing changed); realloc may (null:
 * nothing changed). */
KAIRO_RT_HEAP_BOOL kairo_rt_heap_resize(unsigned char *ptr, size_t old_size, size_t new_size, size_t align) KAIRO_RT_NOEXCEPT;
unsigned char *kairo_rt_heap_realloc(unsigned char *ptr, size_t old_size, size_t new_size, size_t align) KAIRO_RT_NOEXCEPT;

#ifdef __cplusplus
}
#endif

#endif /* KAIRO_RT_HEAP_H */
