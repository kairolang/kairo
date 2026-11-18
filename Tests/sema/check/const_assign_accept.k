// Writes to a `var` binding (assignment, op=, ++) and reads of a `const`
// binding are accepted; only a write to a const is SC071E.

fn main() -> i32 {
    var x: i32? = 42
    x = null
    var y: i32 = 1
    y = 2
    y += 3
    y++
    const z: i32 = y
    var w: i32 = z
    w = w - z
    return w
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not="error [" --implicit-check-not="I003E"
