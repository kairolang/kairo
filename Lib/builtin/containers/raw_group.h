// Tag comparison for the hash table's buckets (containers/raw_table.k) on
// targets with a 16-byte vector compare. A bucket starts with 16 bytes: 12
// tags and 4 filler bytes. Each function returns one bit per slot, bit i
// for slot i.
#pragma once

#if defined(__SSE2__)
#include <emmintrin.h>

static inline unsigned kairo_group_match(const unsigned char *p, unsigned char tag) {
    __m128i g = _mm_loadu_si128((const __m128i *)p);
    return (unsigned)_mm_movemask_epi8(_mm_cmpeq_epi8(g, _mm_set1_epi8((char)tag)));
}

// Empty is 0xFF; no other tag and no filler byte is.
static inline unsigned kairo_group_empty(const unsigned char *p) {
    __m128i g = _mm_loadu_si128((const __m128i *)p);
    return (unsigned)_mm_movemask_epi8(_mm_cmpeq_epi8(g, _mm_set1_epi8((char)0xFF)));
}

// Empty or tombstone: the high bit of the tag. The filler bytes have it
// too and are masked off.
static inline unsigned kairo_group_free(const unsigned char *p) {
    __m128i g = _mm_loadu_si128((const __m128i *)p);
    return (unsigned)_mm_movemask_epi8(g) & 0x0FFFu;
}
#endif
