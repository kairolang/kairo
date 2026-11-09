// A `>>` that closes two generic lists, followed by
// a `,` that belongs to the enclosing parameter list, failed when a later
// parameter had generics: S049E "expected ',' or '>' after type argument".
// The inner list consumed the `>>` and left _pending_close_angle for the
// outer, but the outer asked about the `,` before it asked about the
// pending close, and read `, b: *vec<u8>` as more of its own arguments.
// Two sites in the migrated compiler (PatternCompilation, NullnessFlow).
//
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not=error

fn f(keys: unsafe *vec<vec<u8>>, b: unsafe *vec<u8>) -> i32 { return 0 }
fn g(keys: *vec<vec<u8>>, b: *vec<u8>) -> i32 { return 0 }
fn h(keys: vec<vec<u8>>, b: vec<u8>) -> i32 { return 0 }
fn k(keys: *Map<vec<u8>, vec<vec<i32>>>, b: Map<i32, vec<u8>>, c: *vec<vec<u8>>) -> i32 { return 0 }
