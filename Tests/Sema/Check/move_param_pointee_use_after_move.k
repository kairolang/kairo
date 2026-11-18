// A pointee passed to a `@move` parameter (`eat(*p)`) is moved-from: reading
// it afterwards is SC052E, and assigning a new value first makes the read
// legal.

class Res {
    pub var id: i32 = 0
    fn Res(self, id: i32) { self.id = id }
    @move fn Res(self, other: Self) { self.id = other.id; other.id = 0 }
}

fn eat(@move r: Res) { }

fn bad(p: *Res) -> i32 {
    eat(*p)
    return p->id
}

fn good(p: *Res) -> i32 {
    eat(*p)
    *p = Res(2)
    return p->id
}

fn main() -> i32 {
    var a = Res(1)
    var b = Res(1)
    return bad(&a) + good(&b)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error ['
// CHECK: move_param_pointee_use_after_move.k:15:12: error [SC052E]: '*p' is used after being moved
