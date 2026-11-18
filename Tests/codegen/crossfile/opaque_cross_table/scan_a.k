import std::c_char
ffi "c++" import "vector"
ffi "c++" import "cstdio"
ffi "c++" import "emmintrin.h"

// Newlines in 16 bytes. __m128i is an opaque vector type: its spelling is
// interned once for the build, so this file's and scan_b's header contexts
// agree on it.
pub fn count_a(p: *const u8) -> u32 {
    const nl: __m128i = _mm_set1_epi8(('\n' as u8) as c_char)
    const c: __m128i = _mm_loadu_si128(unsafe (p as unsafe *const __m128i))
    return _mm_movemask_epi8(_mm_cmpeq_epi8(c, nl)) as u32
}
