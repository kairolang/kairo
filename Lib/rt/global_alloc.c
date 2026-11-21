/* --- The Kairo Project ---------------------- Lib/rt/global_alloc.c --- */
/*
 *   The default global allocator: System, as the weak kairo_global_*
 *   definitions rt/global_alloc.h describes. A file that writes
 *   `@set_global_allocator(A)` defines the same five strongly, and the
 *   link takes those instead; with none, these are the program's.
 *
 *   Bit for bit what alloc.k's System does, so a block either one made is
 *   one the other can take: mimalloc (rt/mimalloc.c), with the small-object
 *   paths for blocks of at most 128 words at no more than 2 * sizeof(void *)
 *   alignment, the aligned entry points past that alignment, and the large
 *   blocks of rt/heap.h, whose resize and realloc both share. See
 *   rt/alloc.h for the invariant the small free relies on.
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
 *   Copyright (c) 2026 Dhruvan Kartik
 */
#include "rt/global_alloc.h"
#include "rt/heap.h"

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
void  mi_free(void *p);
void  mi_free_small_nonnull(void *p);
void *mi_malloc_aligned(size_t size, size_t alignment);
void *mi_zalloc_aligned(size_t size, size_t alignment);

KAIRO_RT_GLOBAL_WEAK unsigned char *kairo_global_alloc(size_t size, size_t align) {
    if (align <= KAIRO_RT_GLOBAL_MAX_ALIGN) {
        if (size <= KAIRO_RT_GLOBAL_SMALL_MAX) { return (unsigned char *)mi_malloc_small(size); }
        if (KAIRO_RT_HEAP_IS_LARGE(size, align)) { return kairo_rt_heap_large_alloc(size, align, 0); }
        return (unsigned char *)mi_malloc(size);
    }
    if (KAIRO_RT_HEAP_IS_LARGE(size, align)) { return kairo_rt_heap_large_alloc(size, align, 0); }
    return (unsigned char *)mi_malloc_aligned(size, align);
}

KAIRO_RT_GLOBAL_WEAK void kairo_global_free(unsigned char *ptr, size_t size, size_t align) {
    if (align <= KAIRO_RT_GLOBAL_MAX_ALIGN) {
        if (size <= KAIRO_RT_GLOBAL_SMALL_MAX) {
            mi_free_small_nonnull(ptr);
            return;
        }
    }
    if (KAIRO_RT_HEAP_IS_LARGE(size, align)) {
        kairo_rt_heap_large_free(ptr, size);
        return;
    }
    mi_free(ptr);
}

KAIRO_RT_GLOBAL_WEAK _Bool kairo_global_resize(unsigned char *ptr, size_t old_size, size_t new_size, size_t align) {
    return kairo_rt_heap_resize(ptr, old_size, new_size, align);
}

KAIRO_RT_GLOBAL_WEAK unsigned char *kairo_global_realloc(unsigned char *ptr, size_t old_size, size_t new_size, size_t align) {
    return kairo_rt_heap_realloc(ptr, old_size, new_size, align);
}

KAIRO_RT_GLOBAL_WEAK unsigned char *kairo_global_alloc_zeroed(size_t size, size_t align) {
    if (align <= KAIRO_RT_GLOBAL_MAX_ALIGN) {
        if (size <= KAIRO_RT_GLOBAL_SMALL_MAX) { return (unsigned char *)mi_zalloc_small(size); }
        if (KAIRO_RT_HEAP_IS_LARGE(size, align)) { return kairo_rt_heap_large_alloc(size, align, 1); }
        return (unsigned char *)mi_zalloc(size);
    }
    if (KAIRO_RT_HEAP_IS_LARGE(size, align)) { return kairo_rt_heap_large_alloc(size, align, 1); }
    return (unsigned char *)mi_zalloc_aligned(size, align);
}
