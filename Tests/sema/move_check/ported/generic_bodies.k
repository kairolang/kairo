// In a generic body, a by-value transfer of a `T` out of storage the body
// does not own (a parameter, `*p`, `p->f`, `self.f`) moves at an instance
// whose type cannot be copied and copies at every other. Reading that
// storage again before assigning it is SC052E at that instance, reported at
// the instantiation; copying out of a const place is SC182E there
// (ownership.mdx, end of Moved-From State). An instance with a COPY type
// or a primitive is accepted.
// Cases from Rust tests/ui/moves/use_of_moved_value_copy_suggestions,
// use_of_moved_value_clone_suggestions, move-nullary-fn.

class Tok {
    pub var id: i32 = 0
    fn Tok(self, id: i32) { self.id = id }
    @move fn Tok(self, other: Self) { self.id = other.id; other.id = 0 }
}

class Cp {
    pub var id: i32 = 0
    fn Cp(self, id: i32) { self.id = id }
    @copy fn Cp(self, const other: Self) { self.id = other.id }
}

class <T> Slot {
    pub var v: T
    fn Slot(self, v: T) { self.v = v }
}

fn <T> dup(x: T) -> (T, T) { return (x, x) }
fn <T> keep(x: T) -> T { var y = x; return x }
fn <T> read_twice(p: *T) -> T { var a = *p; var b = *p; return a }
fn <T> read_once(p: *T) -> T { var a = *p; return a }
fn <T> from_const(const x: T) -> T { var y = x; return y }
fn <T> moved_ok(x: T) -> T { var y = x; return y }
fn <T> reassign_between(p: *T, fresh: T) -> T {
    var a = *p
    *p = fresh
    var b = *p
    return a
}
fn <T> slot_twice(s: *Slot<T>) -> T { var a = s->v; var b = s->v; return a }

fn main() -> i32 {
    var n = 3
    var c = Cp(1)
    var t = Tok(3)
    var s = Slot<Tok>(Tok(4))
    var r1 = keep<i32>(n)
    var r2 = keep<Cp>(c)
    var r3 = keep<Tok>(Tok(1)) //! SC052E
    var r4 = read_twice<i32>(&n)
    var r5 = read_twice<Cp>(&c)
    var r6 = read_twice<Tok>(&t) //! SC052E
    var r7 = read_once<Tok>(&t)
    var r8 = from_const<i32>(n)
    var r9 = from_const<Tok>(Tok(5)) //! SC182E
    var r10 = moved_ok<Tok>(Tok(6))
    var r11 = reassign_between<Tok>(&t, Tok(7))
    var r13 = dup<i32>(n)
    var r14 = dup<Cp>(c)
    var r15 = dup<Tok>(Tok(8)) //! SC052E
    var r12 = slot_twice<Tok>(&s) //! SC052E
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: generic_bodies.k:49:{{[0-9]+}}: error [SC052E]:
// CHECK: generic_bodies.k:52:{{[0-9]+}}: error [SC052E]:
// CHECK: generic_bodies.k:55:{{[0-9]+}}: error [SC182E]:
// CHECK: generic_bodies.k:60:{{[0-9]+}}: error [SC052E]:
// CHECK: generic_bodies.k:61:{{[0-9]+}}: error [SC052E]:
