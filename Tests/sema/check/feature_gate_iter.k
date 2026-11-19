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
    for (k, v) in xs { n += 1 }
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

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
//
// Every loop type-checks quietly: the vector, set, map and string loops
// (lines 3, 8, 13, 18) are driven by the `op in (self) -> yield` each
// declares in Lib/builtin, and the slice loop at line 23 is built in.
//
//
// DIAG-NOT: {{error|warning}} [
// DIAG-NOT: Internal Compiler Error
