// A vector is move-only, so every transfer of one moves it: an
// initializer, an assignment, a by-value argument, a returned local, and a
// nested `[[Mv]]` the same. A `const` parameter takes no transfer. Reading
// a vector after it moved is SC052E, reported once at the read; a vector of
// a copyable element moves the same way.

class Mv {
    var v: i32
    fn Mv(self, v: i32) { self.v = v }
    @move fn Mv(self, other: Self) = default
}

fn take(v: [Mv]) -> usize { return v.size() }
fn peek(const v: [Mv]) -> usize { return v.size() }

fn make() -> [Mv] {
    var a: [Mv]
    return a
}

fn main() -> i32 {
    var a: [Mv]
    a.push(Mv(1))
    var b = a
    var w: [Mv]
    w = b
    var n = peek(w)
    var k = take(w)
    var aa: [[Mv]]
    var bb = aa
    var ints: [i32]
    var ints2 = ints
    var again = a
    return (n + k) as i32
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: copy_constrained_container.k:33:17: error [SC052E]: 'a' is used after being moved
// CHECK-NOT: error
