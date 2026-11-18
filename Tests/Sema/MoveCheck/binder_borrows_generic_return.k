// A generic body that gives away a plain binder of a parameter's type (a
// return, a by-value pass) copies it: fine at an instance that can copy
// it, an error at one where the binder borrows.

class M {
    pub var v: i32 = 0
    fn M(self, v: i32) { self.v = v }
    @move fn M(self, other: Self) { self.v = other.v }
}

fn <T> first(@inout xs: [T; 2]) -> T {
    for x in xs {
        return x
    }

    return xs[0]
}

fn main() -> i32 {
    var ms: [M; 2] = [M(1), M(2)]
    var is: [i32; 2] = [1, 2]
    return first(&is) + first(&ms).v - 2
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK:      binder_borrows_generic_return.k:22:25: error [SC182E]: cannot copy a value of type 'M' in 'first<M>': 'x' is const, so the transfer cannot move it
// CHECK-NEXT: binder_borrows_generic_return.k:13:16: note [I900N]: 'x' is copied here, as a 'M'
