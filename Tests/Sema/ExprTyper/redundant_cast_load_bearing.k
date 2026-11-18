// A cast that gives a literal its type, selects an overload or fixes a
// deduced parameter is load-bearing and is not linted as redundant (SC031W).
// A widening into a slot that already takes the source type is still linted.

fn f(x: u32) -> i32 { return 1 }
fn f(x: u64) -> i32 { return 2 }

fn <T> max2(a: T, b: T) -> T { if a > b { return a } return b }

fn take_i64(x: i64) { }

fn load_bearing(x: u32, a: u64, b: u32) -> u64 {
    var lit = 0 as usize;
    var shifted = (1 as u64) << 63;
    var neg = -6 as i32 as u32;
    var o = f(x as u64);
    var m = max2(a, b as u64);
    return shifted + (lit as u64) + (neg as u64) + (o as u64) + m;
}

fn linted(s: i16) {
    take_i64(s as i64);
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='SC031W'
// CHECK: redundant_cast_load_bearing.k:{{[0-9]+}}:{{[0-9]+}}: warning [SC031W]: redundant cast
