// In a generic body a plain binder of a parameter's type copies at an
// instance that can copy it and borrows, read-only, at one that cannot. A
// body that changes the binder is an error only at the instances where it
// borrows, reported at the instance's use.

class Mv {
    pub var v: i32 = 0
    fn Mv(self, v: i32) { self.v = v }
    @move fn Mv(self, other: Self) { self.v = other.v }
}

fn <T> poke(p: *T) { }

fn <T> poke_all(@inout xs: [T; 2]) {
    for x in xs {
        poke(&x)
    }
}

fn main() -> i32 {
    var ints: [i32; 2] = [1, 2]
    poke_all(&ints)
    var mvs: [Mv; 2] = [Mv(1), Mv(2)]
    poke_all(&mvs)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK:      binder_borrows_generic.k:24:5: error [SC071E]: cannot change 'x' in 'poke_all<Mv>': it borrows its element, because 'Mv' cannot be copied
// CHECK-NEXT: binder_borrows_generic.k:16:14: note [I900N]: 'x' is changed here
// CHECK-NEXT: binder_borrows_generic.k:15:9: note [I900N]: the binder 'x' copies its element where its type can be copied and borrows it, read-only, where it cannot
