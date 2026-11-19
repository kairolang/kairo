// In this library `string` declares copy() in an `extend string` block and
// Vector<T> in `extend <T impl Copyable> Vector<T>`: a use after a move of
// either, and a copy of a const one, offer `.copy()`. A vector of a type
// that cannot be copied does not meet the bound and offers nothing.

class Mv {
    pub var n: i32 = 0
    pub fn Mv(self, n: i32) { self.n = n }
    @move pub fn Mv(self, other: Self) { self.n = other.n }
}

fn take(s: string) -> usize = s.size()
fn take_v(v: [i32]) -> usize = v.size()
fn take_m(v: [Mv]) -> usize = v.size()

fn main() -> i32 {
    var s: string = "abc"
    take(s)
    var n = s.size()

    var v: [i32] = [1, 2]
    take_v(v)
    n += v.size()

    var m: [Mv] = []
    take_m(m)
    n += m.size()

    const c: string = "x"
    n += take(c)
    return n as i32
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK:      :19:13: error [SC052E]: 's' is used after being moved
// CHECK:      fix-it:"{{.*}}":{18:11-18:11}:".copy()"
// CHECK:      :23:10: error [SC052E]: 'v' is used after being moved
// CHECK:      fix-it:"{{.*}}":{22:13-22:13}:".copy()"
// CHECK:      :27:10: error [SC052E]: 'm' is used after being moved
// CHECK-NOT:  fix-it
// CHECK:      :30:15: error [SC182E]: cannot copy a value of type 'string'
// CHECK:      fix-it:"{{.*}}":{30:16-30:16}:".copy()"
// CHECK-NOT:  error [
