// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
// CHECK-NOT: error
//
// A GNU vector type imports as one opaque keyed by its canonical type,
// so a value round-trips between C++ calls and two typedefs of the same
// vector (`v2di` / the aligned(1) `v2di_u`) are the same type. Each
// typedef spelling is not its own opaque, so `load(*const v2di)` is not SC063E.

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
