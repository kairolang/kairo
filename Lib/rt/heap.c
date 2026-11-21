/* --- The Kairo Project ---------------------------------- Lib/rt/heap.c --- */
/*
 *   The runtime heap's out-of-line half: resize and realloc for every size.
 *   System and the weak kairo_global_* both call these, so the two agree on
 *   every block.
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
 *   Copyright (c) 2026 Dhruvan Kartik
 */
#include "rt/heap.h"

#include <string.h>

#define KAIRO_RT_HEAP_MAX_ALIGN (2 * sizeof(void *))
#define KAIRO_RT_HEAP_SMALL_MAX (128 * sizeof(void *))

/* mimalloc's entry points (rt/mimalloc.c), declared as rt/global_alloc.c does. */
void *mi_malloc(size_t size);
void *mi_zalloc(size_t size);
void *mi_realloc(void *p, size_t newsize);
void *mi_expand(void *p, size_t newsize);
void  mi_free(void *p);
void *mi_malloc_aligned(size_t size, size_t alignment);
void *mi_zalloc_aligned(size_t size, size_t alignment);
void *mi_realloc_aligned(void *p, size_t newsize, size_t alignment);

/* A block from mimalloc at any size and alignment. A block of at most
 * KAIRO_RT_HEAP_SMALL_MAX bytes at no more than KAIRO_RT_HEAP_MAX_ALIGN
 * comes from a small page, as rt/alloc.h's small free requires. */
static unsigned char *mi_side_alloc(size_t size, size_t align, int zeroed) {
    if (align <= KAIRO_RT_HEAP_MAX_ALIGN) { return (unsigned char *)(zeroed ? mi_zalloc(size) : mi_malloc(size)); }
    return (unsigned char *)(zeroed ? mi_zalloc_aligned(size, align) : mi_malloc_aligned(size, align));
}

/* mimalloc's resize and realloc: a block shrunk from a large page into the
 * small range moves, since the small free could not release it (rt/alloc.h). */
static _Bool mi_side_resize(unsigned char *ptr, size_t old_size, size_t new_size, size_t align) {
    if (new_size > old_size) { return mi_expand(ptr, new_size) != NULL; }
    return !(align <= KAIRO_RT_HEAP_MAX_ALIGN && new_size <= KAIRO_RT_HEAP_SMALL_MAX && old_size > KAIRO_RT_HEAP_SMALL_MAX);
}

static unsigned char *mi_side_realloc(unsigned char *ptr, size_t old_size, size_t new_size, size_t align) {
    if (align > KAIRO_RT_HEAP_MAX_ALIGN) { return (unsigned char *)mi_realloc_aligned(ptr, new_size, align); }
    if (new_size <= KAIRO_RT_HEAP_SMALL_MAX && old_size > KAIRO_RT_HEAP_SMALL_MAX) {
        unsigned char *q = mi_side_alloc(new_size, align, 0);
        if (q == NULL) { return NULL; }
        memcpy(q, ptr, new_size);
        mi_free(ptr);
        return q;
    }
    return (unsigned char *)mi_realloc(ptr, new_size);
}

_Bool kairo_rt_heap_resize(unsigned char *ptr, size_t old_size, size_t new_size, size_t align) {
    return mi_side_resize(ptr, old_size, new_size, align);
}

unsigned char *kairo_rt_heap_realloc(unsigned char *ptr, size_t old_size, size_t new_size, size_t align) {
    return mi_side_realloc(ptr, old_size, new_size, align);
}
