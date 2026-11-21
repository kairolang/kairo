/* --- The Kairo Project ------------------------- Lib/rt/alloc.h --- */
/*
 *   The C++ side of the compiler intrinsics Lib/builtin/base/alloc.k
 *   declares: one `kairo_rt_*` helper per intrinsic whose clang builtin is
 *   type-checked per call (no signature Kairo can import), takes a type
 *   operand, or has the same name as the Kairo intrinsic (so the Kairo body
 *   could not reach it). Header-only and always_inline: an argument clang
 *   wants constant (a memory order, a prefetch hint) is constant again once
 *   the call is inlined, so the switches below fold away.
 *
 *   Part of the Kairo Project, under the Apache License v2.0 with the
 *   Kairo Runtime Library Exception.
 *   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
 */

#pragma once

#include <cstddef>
#include <cstdlib>

// The global allocator's symbols (Global calls them) and the heap's
// out-of-line half (System's resize and realloc, the large blocks): declared
// here so the builtin reaches them through the header it already imports.
#include "rt/global_alloc.h"
#include "rt/heap.h"


#define KAIRO_RT_INL __attribute__((always_inline)) inline
#ifndef KAIRO_RT_NOEXCEPT
/* Every Kairo function is noexcept, so a call from one into a runtime
 * function that is not gets a landing pad that calls std::terminate. Under
 * C (the runtime's own .c files) there is nothing to say. */
#ifdef __cplusplus
#define KAIRO_RT_NOEXCEPT noexcept
#else
#define KAIRO_RT_NOEXCEPT
#endif
#endif

/// What every malloc on every supported target guarantees. Not alignof(max_align_t):
/// that is 16 on i686 glibc, whose malloc only promises 8 for small blocks.
consteval std::size_t kairo_rt_malloc_align() KAIRO_RT_NOEXCEPT { return 2 * sizeof(void*); }

/* The runtime's heap is mimalloc (rt/mimalloc.c). Declared here rather than
 * by including mimalloc.h, so every TU that imports this header does not need
 * the submodule on its include path. The signatures are mimalloc's own. */
extern "C" {
void* mi_malloc(std::size_t size) KAIRO_RT_NOEXCEPT;
void* mi_malloc_small(std::size_t size) KAIRO_RT_NOEXCEPT;
void* mi_zalloc(std::size_t size) KAIRO_RT_NOEXCEPT;
void* mi_zalloc_small(std::size_t size) KAIRO_RT_NOEXCEPT;
void  mi_free(void* p) KAIRO_RT_NOEXCEPT;
void  mi_free_small_nonnull(void* p) KAIRO_RT_NOEXCEPT;
void* mi_malloc_aligned(std::size_t size, std::size_t alignment) KAIRO_RT_NOEXCEPT;
void* mi_zalloc_aligned(std::size_t size, std::size_t alignment) KAIRO_RT_NOEXCEPT;
}

/// mimalloc's small-object limit (MI_SMALL_SIZE_MAX): 128 words. A block of
/// at most this many bytes, at no more than kairo_rt_malloc_align(), comes
/// from a small page, and is freed by the small-page path, which skips the
/// page lookup. The size at a call is usually a constant, so the test folds.
consteval std::size_t kairo_rt_small_max() KAIRO_RT_NOEXCEPT { return 128 * sizeof(void*); }

/// The invariant the small free relies on: a block freed with a size at most
/// kairo_rt_small_max() lives in a small page. kairo_rt_heap_realloc keeps it
/// by moving any block that would shrink from a large page into the small
/// range (mimalloc's realloc shrinks in place), and kairo_rt_heap_resize
/// refuses that shrink for the same reason (rt/heap.c).
///
/// A block of at least KAIRO_RT_HEAP_LARGE_MIN bytes at no more than
/// KAIRO_RT_HEAP_LARGE_ALIGN is rt/heap.h's large block; the size test sits
/// past the small one, so the small paths are unchanged.

KAIRO_RT_INL unsigned char* kairo_rt_malloc(std::size_t n) KAIRO_RT_NOEXCEPT {
    if (n <= kairo_rt_small_max()) { return static_cast<unsigned char*>(mi_malloc_small(n)); }
    if (KAIRO_RT_HEAP_IS_LARGE(n, kairo_rt_malloc_align())) { return kairo_rt_heap_large_alloc(n, kairo_rt_malloc_align(), 0); }
    return static_cast<unsigned char*>(mi_malloc(n));
}
KAIRO_RT_INL unsigned char* kairo_rt_calloc(std::size_t n) KAIRO_RT_NOEXCEPT {
    if (n <= kairo_rt_small_max()) { return static_cast<unsigned char*>(mi_zalloc_small(n)); }
    if (KAIRO_RT_HEAP_IS_LARGE(n, kairo_rt_malloc_align())) { return kairo_rt_heap_large_alloc(n, kairo_rt_malloc_align(), 1); }
    return static_cast<unsigned char*>(mi_zalloc(n));
}
KAIRO_RT_INL void kairo_rt_free(unsigned char* p, std::size_t n) KAIRO_RT_NOEXCEPT {
    if (n <= kairo_rt_small_max()) { mi_free_small_nonnull(p); return; }
    if (KAIRO_RT_HEAP_IS_LARGE(n, kairo_rt_malloc_align())) { kairo_rt_heap_large_free(p, n); return; }
    mi_free(p);
}

/// Over-aligned blocks: never the small free, so any size is fine.
KAIRO_RT_INL unsigned char* kairo_rt_aligned_alloc(std::size_t n, std::size_t a) KAIRO_RT_NOEXCEPT {
    if (KAIRO_RT_HEAP_IS_LARGE(n, a)) { return kairo_rt_heap_large_alloc(n, a, 0); }
    return static_cast<unsigned char*>(mi_malloc_aligned(n, a));
}
KAIRO_RT_INL unsigned char* kairo_rt_aligned_calloc(std::size_t n, std::size_t a) KAIRO_RT_NOEXCEPT {
    if (KAIRO_RT_HEAP_IS_LARGE(n, a)) { return kairo_rt_heap_large_alloc(n, a, 1); }
    return static_cast<unsigned char*>(mi_zalloc_aligned(n, a));
}
KAIRO_RT_INL void kairo_rt_aligned_free(unsigned char* p, std::size_t n, std::size_t a) KAIRO_RT_NOEXCEPT {
    if (KAIRO_RT_HEAP_IS_LARGE(n, a)) { kairo_rt_heap_large_free(p, n); return; }
    mi_free(p);
}

/// Storage for the builtin's first scope chunk (alloc.k ScopeChunk), one per
/// thread. Raw zeroed bytes declared here rather than a Kairo `thread`
/// variable of class type: C++ gives a thread_local of class type a TLS init
/// function, whose call is not noexcept and so puts a terminate landing pad
/// (and libc++abi) into every function that opens a scope. A trivial
/// thread_local array is constant-initialized: no init call, no guard.
#define KAIRO_RT_SCOPE_FIRST_BYTES 1536
#if defined(__linux__) || defined(_WIN32) || defined(__APPLE__) || defined(__FreeBSD__) \
 || defined(__NetBSD__) || defined(__OpenBSD__) || defined(__ANDROID__) || defined(__wasi__) \
 || defined(__EMSCRIPTEN__)
  #if defined(__APPLE__) && defined(__has_feature)
    #if __has_feature(cxx_thread_local)
      #define KAIRO_RT_SCOPE_TLS thread_local
    #else
      #define KAIRO_RT_SCOPE_TLS
    #endif
  #else
    #define KAIRO_RT_SCOPE_TLS thread_local
  #endif
#else
  #define KAIRO_RT_SCOPE_TLS
#endif
alignas(64) inline KAIRO_RT_SCOPE_TLS unsigned char kairo_rt_scope_first_buf[KAIRO_RT_SCOPE_FIRST_BYTES];
KAIRO_RT_INL unsigned char* kairo_rt_scope_first() KAIRO_RT_NOEXCEPT { return kairo_rt_scope_first_buf; }
