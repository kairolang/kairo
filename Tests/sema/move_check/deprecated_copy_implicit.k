// A `@copy` constructor marked `@deprecated` is reported at every place
// that copies a value without naming it (SC354W): the plain deprecation
// warning (SC146W) is raised at a use of the name, which an implicit copy
// has none of. A copy of a struct, tuple, nullable or vector that holds
// such a value is reported with the part named. Where `.copy()` after the
// source is the rewrite, the note carries it as a fix-it.
// Not reported: an explicit `.copy()`, a `const` parameter, a temporary,
// a returned local (it is moved), and a type whose copy is not deprecated.

// RUN: { %kairo --type-check-only %s || true; } 2>&1 | %FileCheck %s
// RUN: { %kairo --type-check-only %s || true; } 2>&1 | %FileCheck %s --check-prefix=COUNT

class Box {
    pub var n: i32

    pub fn Box(self, n: i32) {
        self.n = n
    }

    @deprecated("copy with .copy()")
    @copy pub fn Box(self, const other: Self) {
        self.n = other.n
    }

    pub fn copy(const self) -> Box {
        return Box(self.n)
    }
}

class Plain {
    pub var n: i32

    pub fn Plain(self, n: i32) {
        self.n = n
    }
}

struct Holder {
    var b: Box
}

fn take(b: Box) -> i32 {
    return b.n
}

fn peek(const b: Box) -> i32 {
    return b.n
}

fn made() -> Box {
    var x = Box(3)
    return x
}

fn give(const b: Box) -> Box {
    return b
}

// CHECK: [[@LINE-3]]:12: warning [SC354W]: implicit copy of a 'Box', whose copy constructor is deprecated
// CHECK: note [I900N]: the transfer out of the function copies 'b'
// CHECK: fix-it:{{.*}}:{[[@LINE-5]]:13-[[@LINE-5]]:13}:".copy()"
// CHECK: note [I900N]: the copy constructor is marked deprecated here

fn pick(const h: Holder) -> Box {
    return h.b
}

// CHECK: [[@LINE-3]]:12: warning [SC354W]: implicit copy of a 'Box'
// CHECK: fix-it:{{.*}}:{[[@LINE-4]]:15-[[@LINE-4]]:15}:".copy()"

fn sites(a: Box, h: Holder) -> i32 {
    var b = a
    // CHECK: [[@LINE-1]]:13: warning [SC354W]: implicit copy of a 'Box'
    // CHECK: note [I900N]: the transfer into 'b' copies 'a'
    var t = take(a)
    // CHECK: [[@LINE-1]]:18: warning [SC354W]: implicit copy of a 'Box'
    // CHECK: note [I900N]: the transfer into a by-value parameter copies 'a'
    var h1 = Holder { b: a }
    // CHECK: [[@LINE-1]]:26: warning [SC354W]: implicit copy of a 'Box'
    b = a
    // CHECK: [[@LINE-1]]:9: warning [SC354W]: implicit copy of a 'Box'
    var v: [Box] = [a]
    // CHECK: [[@LINE-1]]:20: warning [SC354W]: implicit copy of a 'Box'
    // CHECK: note [I900N]: the vector copies each element out of the literal
    var h2 = h
    // CHECK: [[@LINE-1]]:14: warning [SC354W]: implicit copy of a 'Holder'
    // CHECK: note [I900N]: a copy of a 'Holder' copies its field 'b'
    var tup = (a, 1)
    // CHECK: [[@LINE-1]]:16: warning [SC354W]: implicit copy of a 'Box'
    var tup2 = tup
    // CHECK: [[@LINE-1]]:16: warning [SC354W]: implicit copy of a '(Box, i32)'
    // CHECK: note [I900N]: a copy of a '(Box, i32)' copies element 0
    var o: Box? = a
    // CHECK: [[@LINE-1]]:19: warning [SC354W]: implicit copy of a 'Box'
    var o2? = o
    // CHECK: [[@LINE-1]]:15: warning [SC354W]: implicit copy of a 'Box?'
    // CHECK: note [I900N]: a copy of a 'Box?' copies its value
    var v2 = v
    // CHECK: [[@LINE-1]]:14: warning [SC354W]: implicit copy of a '[Box]'
    // CHECK: note [I900N]: a copy of a '[Box]' copies its element type 'Box'
    var sum = 0
    for x in v {
        // CHECK: [[@LINE-1]]:9: warning [SC354W]: implicit copy of a 'Box'
        // CHECK: note [I900N]: the loop binder 'x' is a copy of each element
        sum += x.n
    }

    var f = fn () -> i32 {
        return a.n
    }

    // CHECK: [[@LINE-3]]:16: warning [SC354W]: implicit copy of a 'Box'
    // CHECK: note [I900N]: the closure captures 'a' by copy
    return t + h1.b.n + h2.b.n + tup2.0.n + v2[0].n + sum + f() + b.n
}

fn quiet(a: Box, p: Plain) -> i32 {
    var c = a.copy()
    var k = peek(a)
    var m = made()
    var q = p
    var r = Box(5)
    return c.n + k + m.n + q.n + r.n
}

// An explicit call of the constructor is the plain deprecation warning.
fn named(a: Box) -> i32 {
    var e = Box(a)
    return e.n
}

// CHECK: [[@LINE-4]]:13: warning [SC146W]: 'Box' is deprecated: copy with .copy()

// Fifteen implicit copies above, and none in `quiet` or `named`.
// COUNT-COUNT-15: warning [SC354W]
// COUNT-NOT: warning [SC354W]
