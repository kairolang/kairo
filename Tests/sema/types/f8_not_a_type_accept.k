// The 8-bit float formats are spelled `f8e4m3` and `f8e5m2`; declaring a
// variable of either and casting to either type-checks cleanly.

fn main() -> i32 {
    var a: f8e4m3 = 3
    var b = 1 as f8e5m2
    var c: f16 = 1
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not='error [' --implicit-check-not='I003E'
