// `T? -> U?` converts only when the inner `T -> U` does: `i32? -> i64?`
// is accepted, `i32? -> bool?` and `string? -> i32?` are SC028E at the
// returned expression.

fn widen(x: i32?) -> i64? { return x }
fn to_bool(x: i32?) -> bool? { return x }
fn to_int(x: string?) -> i32? { return x }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: inner_convert_rejects.k:6:{{[0-9]+}}: error [SC028E]: cannot convert 'i32?' to 'bool?'
// CHECK: inner_convert_rejects.k:7:{{[0-9]+}}: error [SC028E]: cannot convert 'string?' to 'i32?'
