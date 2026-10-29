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
 *   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
 */

#pragma once

#include <cstddef>
#include <cstdlib>

#if defined(_WIN32)
  #ifndef WIN32_LEAN_AND_MEAN
    #define WIN32_LEAN_AND_MEAN
  #endif
  #ifndef NOMINMAX
    #define NOMINMAX
  #endif
  #include <malloc.h>
  #include <windows.h>
#elif defined(__wasi__)
  // no address-space reservation; see kairo_rt_reserve
#else
  #include <sys/mman.h>
  #if !defined(MAP_ANONYMOUS) && defined(MAP_ANON)
    #define MAP_ANONYMOUS MAP_ANON
  #endif
#endif

#define KAIRO_RT_INL __attribute__((always_inline)) inline

/// What every malloc on every supported target guarantees. Not alignof(max_align_t):
/// that overstates msvcrt on i686 and understates MSVC on x64.
consteval std::size_t kairo_rt_malloc_align() { return 2 * sizeof(void*); }

KAIRO_RT_INL unsigned char* kairo_rt_malloc(std::size_t n) {
    return static_cast<unsigned char*>(std::malloc(n));
}
KAIRO_RT_INL unsigned char* kairo_rt_calloc(std::size_t n) {
    return static_cast<unsigned char*>(std::calloc(1, n));
}
KAIRO_RT_INL unsigned char* kairo_rt_realloc(unsigned char* p, std::size_t n) {
    return static_cast<unsigned char*>(std::realloc(p, n));
}
KAIRO_RT_INL void kairo_rt_free(unsigned char* p, std::size_t) { std::free(p); }

KAIRO_RT_INL unsigned char* kairo_rt_aligned_alloc(std::size_t n, std::size_t a) {
#if defined(_WIN32)
    return static_cast<unsigned char*>(_aligned_malloc(n, a));
#else
    void* p = nullptr;
    return posix_memalign(&p, a, n) == 0 ? static_cast<unsigned char*>(p) : nullptr;
#endif
}
KAIRO_RT_INL void kairo_rt_aligned_free(unsigned char* p, std::size_t, std::size_t) {
#if defined(_WIN32)
    _aligned_free(p);
#else
    std::free(p);
#endif
}

/// Address space for an arena. Committed lazily where the target can do it.
KAIRO_RT_INL unsigned char* kairo_rt_reserve(std::size_t n) {
#if defined(_WIN32)
    return static_cast<unsigned char*>(VirtualAlloc(nullptr, n, MEM_RESERVE, PAGE_NOACCESS));
#elif defined(__wasi__)
    return static_cast<unsigned char*>(std::malloc(n));          // fresh wasm memory is zeroed
#else
    int flags = MAP_PRIVATE | MAP_ANONYMOUS;
  #ifdef MAP_NORESERVE
    flags |= MAP_NORESERVE;
  #endif
    void* p = mmap(nullptr, n, PROT_NONE, flags, -1, 0);
    return p == MAP_FAILED ? nullptr : static_cast<unsigned char*>(p);
#endif
}

KAIRO_RT_INL bool kairo_rt_commit(unsigned char* p, std::size_t n) {
#if defined(_WIN32)
    return VirtualAlloc(p, n, MEM_COMMIT, PAGE_READWRITE) != nullptr;
#elif defined(__wasi__)
    (void)p; (void)n;
    return true;
#else
    return mprotect(p, n, PROT_READ | PROT_WRITE) == 0;
#endif
}

KAIRO_RT_INL void kairo_rt_unreserve(unsigned char* p, std::size_t n) {
#if defined(_WIN32)
    (void)n;
    VirtualFree(p, 0, MEM_RELEASE);
#elif defined(__wasi__)
    (void)n;
    std::free(p);
#else
    munmap(p, n);
#endif
}