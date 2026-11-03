fn over_vector(xs: [i32]) -> i32 {
    var n: i32 = 0
    for x in xs { n += x }
    return n
}
fn over_set(xs: {i32}) -> i32 {
    var n: i32 = 0
    for x in xs { n += x }
    return n
}
fn over_map(xs: {i32: i32}) -> i32 {
    var n: i32 = 0
    for kv in xs { n += 1 }
    return n
}
fn over_string(s: string) -> i32 {
    var n: i32 = 0
    for c in s { n += 1 }
    return n
}
fn over_slice(xs: [i32;]) -> i32 {
    var n: i32 = 0
    for x in xs { n += x }
    return n
}

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// Iterating a string type-checks but has no lowering yet, so it is
// reported as an error rather than reaching IterLowering. The vector, set
// and map loops (lines 3, 8, 13) are driven by the `op in (self) -> yield`
// each declares in Lib/builtin, and the slice loop at line 23 is built in:
// those stay quiet.
//
// DIAG:     feature_gate_iter.k:18:{{[0-9]+}}: error [SC116E]: iterating a string is not yet supported
// DIAG-NOT: {{error|warning}} [
// DIAG-NOT: Internal Compiler Error
