// The library's range parameters are `Range<usize>`: a range of integer
// literals takes that type where it is passed.
fn main() -> i32 {
    var v: [i32] = [1, 2, 3]
    var d = v.drain(0..2)
    var s = "hello".to_owned()
    s.remove_range(1..3)
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
// CHECK-NOT: error
