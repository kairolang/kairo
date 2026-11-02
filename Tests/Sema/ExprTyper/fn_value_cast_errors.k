// A `fn` value never narrows to the raw `unsafe fn`, written as a cast or
// not: it may hold a capturing closure, which has no function pointer. The
// widening cast the other way is accepted (Tests/Codegen/casts/fn_value_cast.k).
fn twice(v: i32) -> i32 { return v * 2 }

fn narrow(f: fn(i32) -> i32) -> i32 {
    var raw = f as unsafe fn(i32) -> i32
    var ok = twice as fn(i32) -> i32
    return ok(1)
}

fn main() -> i32 { return narrow(twice) }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: fn_value_cast_errors.k:7:15: error [SC027E]: no conversion from 'fn (i32) -> i32' to 'unsafe fn (i32) -> i32'
