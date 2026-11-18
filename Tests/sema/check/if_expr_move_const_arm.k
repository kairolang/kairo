// An arm of an if-expression that names a const place of a MOVE type is
// refused: the arm is transferred into the expression's value, a const
// place cannot be moved from, and the type has no copy.

class M {
    pub var n: i32 = 0
    pub fn M(self, n: i32) {
        self.n = n
    }

    @move pub fn M(self, other: Self) {
        self.n = other.n
        other.n = 0
    }
}

fn pick(c: bool, const p: M) -> M {
    return if (c) => (p) else => M(2)
}

fn main() -> i32 {
    return pick(true, M(1)).n
}

// --- lit wiring ---
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s
// CHECK: if_expr_move_const_arm.k:18:23: error [SC182E]: cannot copy a value of type 'M'
