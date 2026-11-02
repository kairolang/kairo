/* --- The Kairo Project ---------------------- Lib/rt/global_alloc.c --- */
/*
 *   The default global allocator: System, as the weak kairo_global_*
 *   definitions rt/global_alloc.h describes. A file that writes
 *   `@set_global_allocator(A)` defines the same five strongly, and the
 *   link takes those instead; with none, these are the program's.
 *
 *   Bit for bit what alloc.k's System does, so a program that sets no
 *   allocator behaves as it did before Global became these symbols:
 *   mimalloc (rt/mimalloc.c), with the small-object paths for blocks of at
 *   most 128 words at no more than 2 * sizeof(void *) alignment, and the
 *   aligned entry points past that alignment. See rt/alloc.h for the
 *   invariant the small free relies on.
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
 *   Copyright (c) 2026 Dhruvan Kartik
 */
#include "rt/global_alloc.h"

#include <string.h>

/* Weak, so the one strong set a link may hold replaces all five. ELF,
 * Mach-O, COFF (as a weak external) and wasm all resolve it that way. */
#define KAIRO_RT_GLOBAL_WEAK __attribute__((weak))

#define KAIRO_RT_GLOBAL_MAX_ALIGN (2 * sizeof(void *))
#define KAIRO_RT_GLOBAL_SMALL_MAX (128 * sizeof(void *))

/* mimalloc's entry points (rt/mimalloc.c), declared as rt/alloc.h does. */
void *mi_malloc(size_t size);
void *mi_malloc_small(size_t size);
void *mi_zalloc(size_t size);
void *mi_zalloc_small(size_t size);
void *mi_realloc(void *p, size_t newsize);
void  mi_free(void *p);
void  mi_free_small_nonnull(void *p);
void *mi_malloc_aligned(size_t size, size_t alignment);
void *mi_zalloc_aligned(size_t size, size_t alignment);
void *mi_realloc_aligned(void *p, size_t newsize, size_t alignment);

KAIRO_RT_GLOBAL_WEAK unsigned char *kairo_global_alloc(size_t size, size_t align) {
    if (align <= KAIRO_RT_GLOBAL_MAX_ALIGN) {
        return (unsigned char *)((size <= KAIRO_RT_GLOBAL_SMALL_MAX) ? mi_malloc_small(size) : mi_malloc(size));
    }
    return (unsigned char *)mi_malloc_aligned(size, align);
}

KAIRO_RT_GLOBAL_WEAK void kairo_global_free(unsigned char *ptr, size_t size, size_t align) {
    if (align <= KAIRO_RT_GLOBAL_MAX_ALIGN && size <= KAIRO_RT_GLOBAL_SMALL_MAX) {
        mi_free_small_nonnull(ptr);
        return;
    }
    mi_free(ptr);
}

/* mimalloc's blocks do not grow in place here; a shrink keeps the block,
 * except one from a large page into the small range, which the small free
 * could not release (rt/alloc.h). */
KAIRO_RT_GLOBAL_WEAK _Bool kairo_global_resize(unsigned char *ptr, size_t old_size, size_t new_size, size_t align) {
    (void)ptr;
    if (new_size > old_size) { return 0; }
    if (align <= KAIRO_RT_GLOBAL_MAX_ALIGN && new_size <= KAIRO_RT_GLOBAL_SMALL_MAX && old_size > KAIRO_RT_GLOBAL_SMALL_MAX) {
        return 0;
    }
    return 1;
}

KAIRO_RT_GLOBAL_WEAK unsigned char *kairo_global_realloc(unsigned char *ptr, size_t old_size, size_t new_size, size_t align) {
    if (align > KAIRO_RT_GLOBAL_MAX_ALIGN) { return (unsigned char *)mi_realloc_aligned(ptr, new_size, align); }
    if (new_size <= KAIRO_RT_GLOBAL_SMALL_MAX && old_size > KAIRO_RT_GLOBAL_SMALL_MAX) {
        void *q = mi_malloc_small(new_size);
        if (q == NULL) { return NULL; }
        memcpy(q, ptr, new_size);
        mi_free(ptr);
        return (unsigned char *)q;
    }
    return (unsigned char *)mi_realloc(ptr, new_size);
}

KAIRO_RT_GLOBAL_WEAK unsigned char *kairo_global_alloc_zeroed(size_t size, size_t align) {
    if (align <= KAIRO_RT_GLOBAL_MAX_ALIGN) {
        return (unsigned char *)((size <= KAIRO_RT_GLOBAL_SMALL_MAX) ? mi_zalloc_small(size) : mi_zalloc(size));
    }
    return (unsigned char *)mi_zalloc_aligned(size, align);
}
