// `x.finally()` runs the destructor of a local where it is written and the
// scope's end does not run it again. Afterwards `x` holds no object: reading
// it, calling a method on it or writing one of its fields is SC303E on every
// path the call can reach, and a second `finally()` where the first already
// ran is SC304E. Assigning the whole local makes it usable again. On a
// parameter, `self`, a field or a global it is SC305E (classes-lifecycle.mdx,
// Running cleanup early).
// Cases from Rust tests/ui/drop/explicit-call-to-dtor,
// explicit-drop-call-error, drop-once-on-move.

class Res {
    pub var id: i32 = 0
    fn Res(self, id: i32) { self.id = id }
    @move fn Res(self, other: Self) { self.id = other.id; other.id = 0 }
    fn op finally(self) { }
    fn ping(self) -> i32 { return self.id }
}

class Owner {
    pub var r: Res
    fn Owner(self) { self.r = Res(1) }
    fn close_own(self) {
        self.r.finally() //! SC305E
    }
}

var global_res: Res = Res(9)

fn read_after_finally() -> i32 {
    var r = Res(1)
    r.finally()
    return r.id //! SC303E
}

fn method_after_finally() -> i32 {
    var r = Res(1)
    r.finally()
    return r.ping() //! SC303E
}

fn write_field_after_finally() {
    var r = Res(1)
    r.finally()
    r.id = 3 //! SC303E
}

fn finally_twice() {
    var r = Res(1)
    r.finally()
    r.finally() //! SC304E
}

fn finally_in_one_branch(c: bool) -> i32 {
    var r = Res(1)
    if c { r.finally() }
    return r.id //! SC303E
}

fn finally_in_both_branches(c: bool) {
    var r = Res(1)
    if c { r.finally() } else { r.finally() }
}

fn finally_in_branch_then_return(c: bool) -> i32 {
    var r = Res(1)
    if c {
        r.finally()
        return 0
    }
    return r.id
}

fn finally_then_reassign() -> i32 {
    var r = Res(1)
    r.finally()
    r = Res(2)
    return r.id
}

fn finally_then_reassign_then_finally() {
    var r = Res(1)
    r.finally()
    r = Res(2)
    r.finally()
}

fn finally_then_write_field_does_not_revive() -> i32 {
    var r = Res(1)
    r.finally()
    r.id = 4 //! SC303E
    return 0
}

fn finally_in_loop_every_iteration() {
    for i in 0..3 {
        var r = Res(i)
        r.finally()
    }
}

fn finally_in_loop_on_outer() {
    var r = Res(1)
    for i in 0..3 {
        r.finally() //! SC304E
    }
}

fn finally_on_parameter(r: Res) {
    r.finally() //! SC305E
}

fn finally_on_global() {
    global_res.finally() //! SC305E
}

fn finally_on_moved_from() -> i32 {
    var r = Res(1)
    var s = r
    r.finally() //! SC052E
    return s.id
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: explicit_finally.k:23:{{[0-9]+}}: error [SC305E]:
// CHECK: explicit_finally.k:32:{{[0-9]+}}: error [SC303E]:
// CHECK: explicit_finally.k:38:{{[0-9]+}}: error [SC303E]:
// CHECK: explicit_finally.k:44:{{[0-9]+}}: error [SC303E]:
// CHECK: explicit_finally.k:50:{{[0-9]+}}: error [SC304E]:
// CHECK: explicit_finally.k:56:{{[0-9]+}}: error [SC303E]:
// CHECK: explicit_finally.k:90:{{[0-9]+}}: error [SC303E]:
// CHECK: explicit_finally.k:104:{{[0-9]+}}: error [SC304E]:
// CHECK: explicit_finally.k:109:{{[0-9]+}}: error [SC305E]:
// CHECK: explicit_finally.k:113:{{[0-9]+}}: error [SC305E]:
// CHECK: explicit_finally.k:119:{{[0-9]+}}: error [SC052E]:
