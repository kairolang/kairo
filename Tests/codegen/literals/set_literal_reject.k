// A set literal and a map literal check each element against the declared
// element type: a string in a `{i32}` and a string value in a
// `{i32: i32}` are SC028E, while the well-typed literals are accepted.

fn main() -> i32 {
    var ok: {i32} = {2, 3}
    var okm: {i32: i32} = {1: 2}
    var p: {i32} = {2, "x", 5}
    var q: {i32: i32} = {1: 2, 3: "z"}
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='I003E'
// CHECK: set_literal_reject.k:8:24: error [SC028E]: cannot convert 'string' to 'i32'
// CHECK: set_literal_reject.k:9:35: error [SC028E]: cannot convert 'string' to 'i32'
