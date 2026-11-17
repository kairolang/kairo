// -Wconst-self's pointee half: a pointer parameter or local whose pointee
// the function never writes is told to point to const, with a fix-it
// inserting `const` before each pointee level it can take, from the first
// level down. A write through a level, a non-const method on what it points
// at, a mutable address of it, or a copy of the pointer kept as a pointer
// to non-const ends the levels there.

class W {
    pub var n: i32 = 0

    fn bump(self) {
        self.n += 1
    }

    fn get(const self) -> i32 {
        return self.n
    }
}

fn reads(p: *W) -> i32 {
    return p->n
}

fn calls_const(p: *W) -> i32 {
    return p->get()
}

fn writes(p: *W) {
    p->n = 1
}

fn mutates(p: *W) {
    p->bump()
}

fn assigns(p: *W) {
    *p = W()
}

fn passes_on(p: *W) -> i32 {
    return reads(p)
}

fn compares(p: *W, q: *W) -> bool {
    return p == q
}

fn two(pp: **W) -> i32 {
    return (*pp)->n
}

fn two_inner(pp: **W) {
    (*pp)->bump()
}

fn two_outer(pp: **W, p: *W) {
    *pp = p
}

fn already(p: *const W) -> i32 {
    return p->n
}

fn copies(p: *W, o: *W) -> i32 {
    var r: *W = p
    r = o
    return r->n
}

fn takes_addr(p: *W) -> *i32 {
    return &p->n
}

fn takes_const_addr(p: *W) -> *const i32 {
    return const &p->n
}

fn in_closure(p: *W) -> i32 {
    var f = fn () -> i32 = p->n
    return f()
}

class H {
    pub var q: *i32
    fn H(self, q: *i32) {
        self.q = q
    }
}

fn through_field(p: *H) {
    *p->q = 3
}

fn local() -> i32 {
    var w = W()
    var lp: *W = &w
    w.n = lp->n
    return w.n
}

// Not warned: a non-const extension method on the pointee, a pointer a
// closure returns, and a copy kept in an inferred local.
extend W {
    fn ext_bump(self) {
        self.n += 1
    }
}

fn through_extension(p: *W) {
    p->ext_bump()
}

fn closure_returns(p: *W) -> i32 {
    var f = fn () -> *W { return p }
    f()->n = 1
    return 0
}

fn inferred_copy(p: *W) {
    var q = p
    q->bump()
}

fn main() -> i32 {
    var w = W()
    var mp: *W = &w
    return mp->n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only -Wconst-self 2>&1 || true; } | %FileCheck %s
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=OFF --allow-empty
// OFF-NOT: SC360W
//
// CHECK-DAG: const_self_pointee.k:20:13: warning [SC360W]: parameter 'p' is never written through; declare it '*const W'
// CHECK-DAG: fix-it:{{.*}}:{20:14-20:14}:"const "
// CHECK-DAG: const_self_pointee.k:24:19: warning [SC360W]: parameter 'p' is never written through; declare it '*const W'
// CHECK-DAG: const_self_pointee.k:44:16: warning [SC360W]: parameter 'p' is never written through; declare it '*const W'
// CHECK-DAG: const_self_pointee.k:44:23: warning [SC360W]: parameter 'q' is never written through; declare it '*const W'
// CHECK-DAG: const_self_pointee.k:48:12: warning [SC360W]: parameter 'pp' is never written through; declare it '*const *const W'
// CHECK-DAG: fix-it:{{.*}}:{48:13-48:13}:"const "
// CHECK-DAG: fix-it:{{.*}}:{48:14-48:14}:"const "
// CHECK-DAG: const_self_pointee.k:52:18: warning [SC360W]: parameter 'pp' is never written through; declare it '*const *W'
// CHECK-DAG: fix-it:{{.*}}:{52:19-52:19}:"const "
// CHECK-DAG: const_self_pointee.k:65:12: warning [SC360W]: variable 'r' is never written through; declare it '*const W'
// CHECK-DAG: const_self_pointee.k:74:24: warning [SC360W]: parameter 'p' is never written through; declare it '*const W'
// CHECK-DAG: const_self_pointee.k:78:18: warning [SC360W]: parameter 'p' is never written through; declare it '*const W'
// CHECK-DAG: const_self_pointee.k:90:21: warning [SC360W]: parameter 'p' is never written through; declare it '*const H'
// CHECK-DAG: const_self_pointee.k:96:13: warning [SC360W]: variable 'lp' is never written through; declare it '*const W'
// CHECK-NOT: SC360W
