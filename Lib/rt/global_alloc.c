/* --- The Kairo Project ---------------------- Lib/rt/global_alloc.c --- */
/*
 *   The default global allocator: System, as the weak kairo_global_*
 *   definitions rt/global_alloc.h describes. A file that writes
 *   `@set_global_allocator(A)` defines the same five strongly, and the
 *   link takes those instead; with none, these are the program's.
 *
 *   Bit for bit what alloc.k's System does, so a program that sets no
 *   allocator behaves as it did before Global became these symbols:
 *   malloc and friends up to 2 * sizeof(void *) (what every supported
 *   malloc aligns to; alloc.h's kairo_rt_malloc_align), the aligned entry
 *   points past it, whose blocks the matching aligned free releases.
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
 *   Copyright (c) 2026 Dhruvan Kartik
 */
/* The runtime builds as strict ISO C, which hides posix_memalign; ask for
 * POSIX before any header. */
#if !defined(_WIN32) && !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 200809L
#endif

#include "rt/global_alloc.h"

#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <malloc.h>
#endif

/* Weak, so the one strong set a link may hold replaces all five. ELF,
 * Mach-O, COFF (as a weak external) and wasm all resolve it that way. */
#define KAIRO_RT_GLOBAL_WEAK __attribute__((weak))

#define KAIRO_RT_GLOBAL_MAX_ALIGN (2 * sizeof(void *))

static unsigned char *kairo_rt_global_aligned_alloc_(size_t size, size_t align) {
#if defined(_WIN32)
    return (unsigned char *)_aligned_malloc(size, align);
#else
    void *p = NULL;
    return (posix_memalign(&p, align, size) == 0) ? (unsigned char *)p : NULL;
#endif
}

static void kairo_rt_global_aligned_free_(unsigned char *p) {
#if defined(_WIN32)
    _aligned_free(p);
#else
    free(p);
#endif
}

KAIRO_RT_GLOBAL_WEAK unsigned char *kairo_global_alloc(size_t size, size_t align) {
    if (align <= KAIRO_RT_GLOBAL_MAX_ALIGN) { return (unsigned char *)malloc(size); }
    return kairo_rt_global_aligned_alloc_(size, align);
}

KAIRO_RT_GLOBAL_WEAK void kairo_global_free(unsigned char *ptr, size_t size, size_t align) {
    (void)size;
    if (align <= KAIRO_RT_GLOBAL_MAX_ALIGN) { free(ptr); return; }
    kairo_rt_global_aligned_free_(ptr);
}

/* malloc cannot grow in place; a shrink keeps the block, and free ignores
 * the size, so it is always valid. */
KAIRO_RT_GLOBAL_WEAK _Bool kairo_global_resize(unsigned char *ptr, size_t old_size, size_t new_size, size_t align) {
    (void)ptr;
    (void)align;
    return new_size <= old_size;
}

KAIRO_RT_GLOBAL_WEAK unsigned char *kairo_global_realloc(unsigned char *ptr, size_t old_size, size_t new_size, size_t align) {
    if (align <= KAIRO_RT_GLOBAL_MAX_ALIGN) { return (unsigned char *)realloc(ptr, new_size); }
    /* No aligned realloc everywhere: alloc, copy, free (realloc_by_copy). */
    unsigned char *n = kairo_rt_global_aligned_alloc_(new_size, align);
    if (n == NULL) { return NULL; }
    memcpy(n, ptr, (old_size < new_size) ? old_size : new_size);
    kairo_rt_global_aligned_free_(ptr);
    return n;
}

KAIRO_RT_GLOBAL_WEAK unsigned char *kairo_global_alloc_zeroed(size_t size, size_t align) {
    if (align <= KAIRO_RT_GLOBAL_MAX_ALIGN) { return (unsigned char *)calloc(1, size); }
    unsigned char *p = kairo_rt_global_aligned_alloc_(size, align);
    if (p != NULL) { memset(p, 0, size); }
    return p;
}
