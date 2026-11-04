import std::c_char
ffi "c++" import "string"
ffi "c++" import "map"
ffi "c++" import "set"
ffi "c++" import "emmintrin.h"

pub fn count_b(p: *const u8) -> u32 {
    const nl: __m128i = _mm_set1_epi8(('\n' as u8) as c_char)
    const c: __m128i = _mm_loadu_si128(unsafe (p as unsafe *const __m128i))
    return _mm_movemask_epi8(_mm_cmpeq_epi8(c, nl)) as u32
}
