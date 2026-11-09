#include <emmintrin.h>

inline __m128i vt_make() { return _mm_set1_epi8(65); }
inline int vt_take(__m128i v) { return _mm_movemask_epi8(v); }
inline int vt_take_rr(__m128i &&v) { return _mm_movemask_epi8(v); }
inline int vt_use(const __m128i &v) { return _mm_movemask_epi8(v) & 1; }
