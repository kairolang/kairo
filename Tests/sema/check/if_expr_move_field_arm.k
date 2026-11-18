// An arm of an if-expression that names a field of a MOVE type, reached
// through a pointer, is refused: moving out of it would leave the field
// moved-from where nothing tracks it, and the type has no copy.

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

class H {
    pub var m: M = M(1)
}

fn pick(c: bool, h: *H) -> M {
    return if (c) => (h->m) else => M(2)
}

fn main() -> i32 {
    var h = H()
    return pick(true, &h).n
}

// --- lit wiring ---
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s
// CHECK: if_expr_move_field_arm.k:22:23: error [SC182E]: cannot copy a value of type 'M'
