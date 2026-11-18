// A script's slice literal binding checks its elements against the
// declared element type: a string element in a `[i32;]` is SC028E, and the
// well-typed slice beside it is accepted.

var a = 5
var good: [i32;] = [a, a + 1]
var s: [i32;] = [a, "x"]

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='I003E'
// CHECK: slice_literal_reject.k:7:21: error [SC028E]: cannot convert 'string' to 'i32'
