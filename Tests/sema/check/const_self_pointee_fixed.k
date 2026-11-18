// const_self_pointee.k with every SC360W fix-it applied: the pointees are
// const, the program compiles and runs, and -Wconst-self has nothing more
// to say about them. A caller passes `const &x`, which SC310W asks for once
// the parameter points to const; `**T` converts to `*const *const T`.

class W {
    pub var n: i32 = 0

    fn get(const self) -> i32 {
        return self.n
    }
}

class H {
    pub var q: *i32
    fn H(self, q: *i32) {
        self.q = q
    }
}

fn reads(p: *const W) -> i32 {
    return p->n
}

fn calls_const(p: *const W) -> i32 {
    return p->get()
}

fn compares(p: *const W, q: *const W) -> bool {
    return p == q
}

fn two(pp: *const *const W) -> i32 {
    return (*pp)->n
}

fn takes_const_addr(p: *const W) -> *const i32 {
    return const &p->n
}

fn through_field(p: *const H) {
    *p->q = 3
}

fn local() -> i32 {
    var w = W()
    var lp: *const W = const &w
    return lp->n
}

fn main() -> i32 {
    var w = W()
    w.n = 4
    var pw: *W = &w
    var x: i32 = 0
    var h = H(&x)
    through_field(const &h)
    var sum = reads(const &w) + calls_const(const &w) + two(const &pw) + *takes_const_addr(const &w)
    if !compares(const &w, const &w) || x != 3 || local() != 0 { return 1 }
    return sum - 16
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only -Wconst-self 2>&1 || true; } | %FileCheck %s --allow-empty
// CHECK-NOT: SC360W
// CHECK-NOT: SC310W
// CHECK-NOT: error
// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe
