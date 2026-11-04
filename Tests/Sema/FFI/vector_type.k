// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
// CHECK-NOT: error
//
// G84: a GNU vector type imports as one opaque keyed by its canonical type,
// so a value round-trips between C++ calls and two typedefs of the same
// vector (`v2di` / the aligned(1) `v2di_u`) are the same type. Before, each
// typedef spelling was its own opaque and `load(*const v2di)` was SC063E.

ffi "c++" import "vector_type.h"
ffi "c++" import "emmintrin.h"

fn round_trip(p: unsafe *const v2di) -> i32 {
    var a = mk()
    var b = both(a, a)
    var c = load(p)
    return use(both(b, c))
}

fn ext() -> i32 {
    var f = mkf()
    return usef(f)
}

fn sse(p: unsafe *const __m128i) -> i32 {
    var v = _mm_loadu_si128(p)
    var w = _mm_set1_epi8(65)
    return _mm_movemask_epi8(_mm_cmpeq_epi8(v, w))
}
