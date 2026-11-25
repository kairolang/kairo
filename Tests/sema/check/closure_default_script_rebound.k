// A script's top-level variable built from a closure literal keeps the
// literal's defaults while nothing in the file writes it. A function of the
// script that assigns it counts as a write, even one written after the call.

var f = fn (a: i32, b: i32 = 5) -> i32 { return a + b }
var g = fn (a: i32, b: i32 = 5) -> i32 { return a + b }

fn k(a: i32, b: i32) -> i32 {
    return a * 10 + b
}

var r = f(1)
var s = g(1)

fn rebind() {
    g = k
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: closure_default_script_rebound.k:13:9: error [SC099E]: 'fn (i32, i32) -> i32' takes 2 argument(s), 1 given
