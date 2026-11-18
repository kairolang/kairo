// A `const` rebound in one scope, or shadowed in a nested block, is a
// local of its own C++ name (`__kairo_rebind<n>_x`), and so is the union
// storage a `finally()` gives it: the declaration, every use, a capture,
// the cleanup hook and the `__end()` call all name the same object. Each
// object below is destroyed exactly once, which the counting destructor
// checks.

var dtors: i32 = 0
var sum: i32 = 0

class Res {
    pub var id: i32 = 0
    fn Res(self, id: i32) { self.id = id }
    @move fn Res(self, other: Self) {
        self.id  = other.id
        other.id = 0
    }
    fn op finally(self) {
        if self.id != 0 {
            dtors += 1
            sum += self.id
        }
    }
}

// The second `x` is ended; the first lives to the scope's end.
fn same_scope() -> i32 {
    const x = Res(1)
    const x = Res(x.id + 10)
    const seen = x.id
    x.finally()
    return seen
}

// The inner `x` is ended in its block, the outer one on one path only.
fn nested(c: bool) -> i32 {
    const x = Res(2)
    var r = 0
    if c {
        const x = Res(x.id + 20)
        r = x.id
        x.finally()
    }
    if c {
        x.finally()
    }
    return r
}

// A rebound, ended local read by a closure first, through its pointer.
fn captured() -> i32 {
    const x = Res(3)
    const x = Res(x.id + 30)
    const f = fn ()|*| -> i32 { return x->id }
    const got = f()
    x.finally()
    return got
}

fn main() -> i32 {
    if same_scope() != 11 { return 1 }
    if nested(true) != 22 || nested(false) != 0 { return 2 }
    if captured() != 33 { return 3 }
    // 1, 11, 2, 22, 2 (nested(false)), 3, 33
    if dtors != 7 || sum != 74 { return 4 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
