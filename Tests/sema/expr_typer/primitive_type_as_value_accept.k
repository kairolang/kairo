// The primitive type names stay valid as types: as an annotation, a cast
// target and a conversion head, and `==` / `!=` between values of those
// types is an ordinary comparison.

fn main() -> i32 {
    var x: u32 = 3
    var y: u32 = 4
    var z = x as i64
    if x == y {
        return 1
    }
    var b = x != y
    var w: i64 = z
    if w == z { return 0 }
    return 2
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not='error [' --implicit-check-not='warning ['
