// A `>>` that closes two generic lists in a parameter list does not excuse
// a missing separator: the parameter list still needs its `,` and its `)`.
//
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="I003E"
// CHECK: shift_close_then_comma_reject.k:[[@LINE+3]]:5: error [S047E]: expected ')' to close the parameter list
// CHECK: shift_close_then_comma_reject.k:[[@LINE+3]]:5: error [S047E]: expected ')' to close the parameter list

fn f(keys: unsafe *vec<vec<u8>> b: unsafe *vec<u8>) -> i32 { return 0 }
fn g(keys: *vec<vec<u8>>, b: *vec<u8> -> i32 { return 0 }
