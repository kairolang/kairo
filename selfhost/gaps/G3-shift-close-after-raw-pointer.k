// GAP G3: `>>` closing two generic argument lists after `unsafe *`.
//   kairo --syntax-only --error-format=basic G3-shift-close-after-raw-pointer.k
//   -> S049E "expected ',' or '>' after type argument in generic parameter list"
// `keys: vec<vec<u8>>` (no pointer) parses. Sites:
// Sema/Lower/PatternCompilation.k:988, Sema/Type/NullnessFlow.k:574.
fn f(keys: unsafe *vec<vec<u8>>, b: unsafe *vec<u8>) -> i32 {
    return 0
}
