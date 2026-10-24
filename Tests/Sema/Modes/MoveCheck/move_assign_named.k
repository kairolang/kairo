class M {
    pub var v: i32
    pub fn M(self, v: i32) { self.v = v }
    @move
    fn M(self, other: Self) { self.v = other.v }
}

fn main() -> i32 {
    var x = M(1)
    var y = M(5)
    x = y
    var z = M(2)
    z = z
    return y.v + z.v                    // expect: error 'y' is used after being moved; z is live
}

// --- lit wiring -----------------------------------------------------------
// Assigning a MOVE-category lvalue moves it: y is dead after `x = y`. A
// self-assignment moves and revives the same binding in one statement, so
// z stays live. The runtime half is Codegen/move_assign_named.k.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:      move_assign_named.k:14:12: error [SC052E]: 'y' is used after being moved
// DIAG-NEXT: move_assign_named.k:11:9: note [{{[A-Z0-9]+}}]: 'y' was moved here, into 'x'
// DIAG-NEXT: move_assign_named.k:14:12: note [{{[A-Z0-9]+}}]: assign a new value to 'y' before using it again
// DIAG-NOT:  {{error|warning}} [
