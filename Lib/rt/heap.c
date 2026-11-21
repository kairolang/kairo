/* --- The Kairo Project ---------------------------------- Lib/rt/heap.c --- */
/*
 *   The runtime heap's out-of-line half: resize and realloc for every size,
 *   and the large-block path (anonymous mappings grown with mremap, and the
 *   cache of freed ones) rt/heap.h describes. System and the weak
 *   kairo_global_* both call these, so the two agree on every block.
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
 *   Copyright (c) 2026 Dhruvan Kartik
 */
/* musl and glibc declare mremap and MREMAP_MAYMOVE only under _GNU_SOURCE,
 * which has to come before the first system header. */
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE 1
#endif

#include "rt/heap.h"

#include <stdint.h>
#include <string.h>

#if KAIRO_RT_HEAP_LARGE
#include <sys/mman.h>
#endif

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
_Bool mi_is_in_heap_region(const void *p);

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

#if KAIRO_RT_HEAP_LARGE

/* A mapped block's layout: the mapping starts on a page, the block starts
 * hdr_len(align) bytes into it (at least 16, and a multiple of the
 * alignment, which the mapping's page start then gives), and the two words
 * just below the block hold that offset and the mapping's length. The
 * length is the mapping's own, which may be up to twice what the block's
 * size needs: a block that takes a longer cached mapping keeps all of it,
 * so growing into it costs neither a system call nor a page fault. */
#define KAIRO_RT_HEAP_HDR_MIN ((size_t)16)

static size_t hdr_len(size_t align) { return align > KAIRO_RT_HEAP_HDR_MIN ? align : KAIRO_RT_HEAP_HDR_MIN; }

/* The mapping length a block of `size` bytes behind a `hdr`-byte header
 * needs: rounded up to KAIRO_RT_HEAP_LARGE_ALIGN, as the kernel rounds every
 * length up to its own page, so a size maps to one length on every page
 * size. 0 when the sum wraps. */
static size_t map_len(size_t size, size_t hdr) {
    if (size > SIZE_MAX - hdr - (KAIRO_RT_HEAP_LARGE_ALIGN - 1)) { return 0; }
    return (size + hdr + (KAIRO_RT_HEAP_LARGE_ALIGN - 1)) & ~(KAIRO_RT_HEAP_LARGE_ALIGN - 1);
}

static unsigned char *hdr_set(unsigned char *base, size_t hdr, size_t len) {
    unsigned char *ptr = base + hdr;
    memcpy(ptr - 16, &hdr, sizeof hdr);
    memcpy(ptr - 8, &len, sizeof len);
    return ptr;
}
static size_t hdr_of(const unsigned char *ptr) {
    size_t hdr;
    memcpy(&hdr, ptr - 16, sizeof hdr);
    return hdr;
}
static size_t len_of(const unsigned char *ptr) {
    size_t len;
    memcpy(&len, ptr - 8, sizeof len);
    return len;
}

/* A large-sized block is a mapping of ours unless mimalloc's page map holds
 * it (kept there by realloc, a fallback when mmap failed, or a C-heap block). */
static int is_mapped(const unsigned char *ptr) { return !mi_is_in_heap_region(ptr); }

/* The cache: freed mappings, each with its length in its first word (the
 * mapping is free, so the word is ours), and that length again in
 * large_cache_len as a hint for choosing a slot. A slot is taken by
 * exchanging it with null, so a mapping is never read after another thread
 * may have claimed it; the length read from the mapping itself decides. A
 * mapping goes back by a compare-and-swap from null. */
static unsigned char *large_cache[KAIRO_RT_HEAP_CACHE_SLOTS];
static size_t         large_cache_len[KAIRO_RT_HEAP_CACHE_SLOTS];

/* A block of KAIRO_RT_HEAP_CACHE_MAX bytes maps one page more for its
 * header; the cache takes that mapping too. */
static int cacheable(size_t len) { return len <= KAIRO_RT_HEAP_CACHE_MAX + KAIRO_RT_HEAP_LARGE_ALIGN; }

static int cache_put(unsigned char *base, size_t len) {
    if (!cacheable(len)) { return 0; }
    memcpy(base, &len, sizeof len);
    for (int i = 0; i < KAIRO_RT_HEAP_CACHE_SLOTS; ++i) {
        unsigned char *expected = NULL;
        if (__atomic_load_n(&large_cache[i], __ATOMIC_RELAXED) == NULL
            && __atomic_compare_exchange_n(&large_cache[i], &expected, base, 0, __ATOMIC_RELEASE, __ATOMIC_RELAXED)) {
            __atomic_store_n(&large_cache_len[i], len, __ATOMIC_RELAXED);
            return 1;
        }
    }
    return 0;
}

/* The length of the shortest cached mapping of `len` to `max` bytes, or 0,
 * and its slot; a hint, since another thread may take it first. */
static size_t cache_shortest(size_t len, size_t max, int *slot) {
    int    best     = -1;
    size_t best_len = 0;
    for (int i = 0; i < KAIRO_RT_HEAP_CACHE_SLOTS; ++i) {
        if (__atomic_load_n(&large_cache[i], __ATOMIC_RELAXED) == NULL) { continue; }
        size_t hint = __atomic_load_n(&large_cache_len[i], __ATOMIC_RELAXED);
        if (hint >= len && hint <= max && (best < 0 || hint < best_len)) {
            best     = i;
            best_len = hint;
        }
    }
    *slot = best;
    return best_len;
}

/* The shortest cached mapping of `len` to twice `len` bytes, whole, its
 * length in *have. Its pages stay resident, so neither the caller's first
 * writes nor a growth within it fault. A longer one stays cached for a
 * block it fits: a mapped block never holds more than twice the length its
 * size needs, so a short block kept alive cannot pin a long freed mapping,
 * and cutting the mapping instead would fault its tail back in for the
 * next block that needs it. */
static unsigned char *cache_take(size_t len, size_t *have) {
    int slot;
    if (cache_shortest(len, len > SIZE_MAX / 2 ? SIZE_MAX : 2 * len, &slot) == 0) { return NULL; }
    unsigned char *base = __atomic_exchange_n(&large_cache[slot], (unsigned char *)NULL, __ATOMIC_ACQUIRE);
    if (base == NULL) { return NULL; }
    memcpy(have, base, sizeof *have);
    if (*have >= len && *have / 2 <= len) { return base; }
    if (!cache_put(base, *have)) { munmap(base, *have); }
    return NULL;
}

/* Where a block of large size goes when no cached mapping serves it: a
 * fresh mapping at or above the threshold, mimalloc below it, whose freed
 * memory stays resident and so costs no page faults when it is reused.
 * Every mapping the cache has no room for raises the threshold past its
 * length (glibc's mmap threshold rule), so a program that keeps freeing
 * blocks of a size, or growing blocks to it, stops paying a fresh mapping's
 * faults for each one.
 *
 * Two thresholds, because the cache serves only lengths up to
 * KAIRO_RT_HEAP_CACHE_MAX (and a header page): fresh_min_cacheable gates a fresh allocation of
 * such a length and rises only when one of those finds the cache full;
 * fresh_min gates every other fresh allocation and every growth by realloc
 * out of mimalloc, and rises with every unmapped block. So a block too long
 * for the cache, once freed, keeps longer blocks and growing ones in
 * mimalloc without sending cacheable allocations there too. Neither has a
 * cap: mimalloc reuses a block of any size. The page map tells every free
 * which heap a block is in. */
static size_t fresh_min           = KAIRO_RT_HEAP_LARGE_MIN;
static size_t fresh_min_cacheable = KAIRO_RT_HEAP_LARGE_MIN;

static void raise_threshold(size_t *threshold, size_t len) {
    if (len >= __atomic_load_n(threshold, __ATOMIC_RELAXED)) { __atomic_store_n(threshold, len + 1, __ATOMIC_RELAXED); }
}

/* A mapped block for `size` bytes: a cached mapping (not for a zeroed
 * block: a cached one holds old bytes), else a fresh one, which is zero.
 * Out of mappings (vm.max_map_count) is not out of memory: mimalloc's arenas
 * may still have room, and its page map tells the free. */
static unsigned char *map_block(size_t size, size_t align, int zeroed, int fresh_ok) {
    size_t hdr = hdr_len(align), len = map_len(size, hdr);
    if (len == 0) { return NULL; }
    if (!zeroed) {
        size_t         have;
        unsigned char *c = cache_take(len, &have);
        if (c != NULL) { return hdr_set(c, hdr, have); }
    }
    if (fresh_ok) {
        void *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p != MAP_FAILED) { return hdr_set((unsigned char *)p, hdr, len); }
    }
    return mi_side_alloc(size, align, zeroed);
}

unsigned char *kairo_rt_heap_large_alloc(size_t size, size_t align, int zeroed) {
    size_t *threshold = cacheable(map_len(size, hdr_len(align))) ? &fresh_min_cacheable : &fresh_min;
    return map_block(size, align, zeroed, size >= __atomic_load_n(threshold, __ATOMIC_RELAXED));
}

void kairo_rt_heap_large_free(unsigned char *ptr, size_t size) {
    (void)size;
    if (!is_mapped(ptr)) {
        mi_free(ptr);
        return;
    }
    size_t         len  = len_of(ptr);
    unsigned char *base = ptr - hdr_of(ptr);
    if (cache_put(base, len)) { return; }
    munmap(base, len);
    raise_threshold(&fresh_min, len);
    if (cacheable(len)) { raise_threshold(&fresh_min_cacheable, len); }
}

/* A mapped block resized from `old_size` to `new_size` (at least
 * KAIRO_RT_HEAP_LARGE_MIN) without moving: within its mapping's length
 * nothing changes, except that a shrink to half that length or less gives
 * the tail back; a growth past it extends the mapping where the address
 * space after it is free. */
static _Bool mapped_resize(unsigned char *ptr, size_t old_size, size_t new_size) {
    size_t hdr = hdr_of(ptr), len = len_of(ptr), need = map_len(new_size, hdr);
    if (need == 0) { return 0; }
    if (need <= len && (new_size >= old_size || need > len / 2)) { return 1; }
    if (mremap(ptr - hdr, len, need, 0) == MAP_FAILED) { return need < len; }
    hdr_set(ptr - hdr, hdr, need);
    return 1;
}

#endif /* KAIRO_RT_HEAP_LARGE */

_Bool kairo_rt_heap_resize(unsigned char *ptr, size_t old_size, size_t new_size, size_t align) {
#if KAIRO_RT_HEAP_LARGE
    if (KAIRO_RT_HEAP_IS_LARGE(old_size, align) && is_mapped(ptr)) {
        /* A mapped block below the threshold would get mimalloc's free. */
        if (new_size < KAIRO_RT_HEAP_LARGE_MIN) { return 0; }
        return mapped_resize(ptr, old_size, new_size);
    }
#endif
    return mi_side_resize(ptr, old_size, new_size, align);
}

unsigned char *kairo_rt_heap_realloc(unsigned char *ptr, size_t old_size, size_t new_size, size_t align) {
#if KAIRO_RT_HEAP_LARGE
    int old_mapped = KAIRO_RT_HEAP_IS_LARGE(old_size, align) && is_mapped(ptr);
    int new_large  = KAIRO_RT_HEAP_IS_LARGE(new_size, align);
    if (old_mapped && new_large) {
        if (mapped_resize(ptr, old_size, new_size)) { return ptr; }
        /* mremap moves page table entries rather than bytes: no copy. */
        size_t hdr = hdr_of(ptr), len = len_of(ptr), need = map_len(new_size, hdr);
        if (need == 0) { return NULL; }
        void *q = mremap(ptr - hdr, len, need, MREMAP_MAYMOVE);
        return q == MAP_FAILED ? NULL : hdr_set((unsigned char *)q, hdr, need);
    }
    if (!old_mapped && new_large) {
        /* mimalloc's block stays mimalloc's unless it grows past both its
         * usable size and the threshold: a shrink, a growth mi_expand
         * serves, and a growth below the threshold are mimalloc's realloc,
         * in place where it can be. So is a growth that only a cached
         * mapping more than twice its length could serve: cut to length,
         * the mapping's resident tail would be lost to the block's next
         * growths, which reach it whole once they need half of it. */
        if (new_size <= old_size || new_size < __atomic_load_n(&fresh_min, __ATOMIC_RELAXED)) {
            return mi_side_realloc(ptr, old_size, new_size, align);
        }
        size_t need = map_len(new_size, hdr_len(align));
        int    slot;
        if (cache_shortest(need, SIZE_MAX, &slot) / 2 > need) { return mi_side_realloc(ptr, old_size, new_size, align); }
        if (mi_expand(ptr, new_size) != NULL) { return ptr; }
        unsigned char *q = map_block(new_size, align, 0, 1);
        if (q == NULL) { return NULL; }
        memcpy(q, ptr, old_size);
        mi_free(ptr);
        return q;
    }
    if (old_mapped) {
        /* Below the large range: the block becomes mimalloc's, so it moves. */
        unsigned char *q = mi_side_alloc(new_size, align, 0);
        if (q == NULL) { return NULL; }
        memcpy(q, ptr, new_size);
        kairo_rt_heap_large_free(ptr, old_size);
        return q;
    }
#endif
    return mi_side_realloc(ptr, old_size, new_size, align);
}
