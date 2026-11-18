// A script closure's explicit capture list names a variable that exists:
// an undeclared name is R020E, and a closure body that misuses a captured
// global is SC066E, while the plain default-capture closure is accepted.

var x = 10
var ok = fn (n: i32) -> i32 { return n + x }
var named = fn (n: i32)|nope| -> i32 { return n + x }
var bad = fn (n: i32) -> i32 { return n + "s" }

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='I003E'
// CHECK: script_global_copy_reject.k:7:25: error [R020E]: use of undeclared identifier 'nope'
// CHECK: script_global_copy_reject.k:8:39: error [SC066E]: no operator '+' for operands 'i32' and 'string'
