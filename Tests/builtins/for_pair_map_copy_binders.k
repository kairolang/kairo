// `for (k, v) in m` over a `{string: [i32]}`: neither `string` nor `[i32]`
// can be copied in this library, so each plain binder borrows its part of
// the entry, read-only, and nothing is copied.
fn main() -> i32 {
    var m: {string: [i32]}
    m.insert("a", [1, 2])
    var n: usize = 0
    for (k, v) in m {
        n += k.size() + v.size()
    }

    return (n as i32) - 3
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
// CHECK-NOT:  error [
