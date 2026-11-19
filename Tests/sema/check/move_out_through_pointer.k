// A MOVE value reached through a pointer or a reference cannot be moved
// out: the transfer would empty the object for every other reader. Each
// transfer form is refused with SC182E; a type with a `copy` method gets
// the `.copy()` fix-it, and a `var` initializer gets the borrow fix-it.

ffi "c++" import "vector"

class M {
    pub var n: i32 = 0
    pub fn M(self, n: i32) {
        self.n = n
    }

    @move pub fn M(self, other: Self) {
        self.n = other.n
        other.n = 0
    }

    pub fn copy(const self) -> M {
        return M(self.n)
    }
}

class H {
    pub var m: M = M(1)
    pub var v: cxx::std::vector<M>
}

class O {
    pub var h: unsafe *H = &null

    // CHECK: :[[@LINE+1]]:37: error [SC182E]: cannot move a value of type 'M' out of 'self.h->m': it is reached through a pointer or a reference
    pub fn take(self) -> M { return self.h->m }
}

fn sink(m: M) { }

fn f(p: *H, q: unsafe *H) {
    // CHECK: :[[@LINE+3]]:13: error [SC182E]: cannot move a value of type 'M' out of 'p->m'
    // CHECK: fix-it:{{.*}}:{[[@LINE+2]]:17-[[@LINE+2]]:17}:".copy()"
    // CHECK: fix-it:{{.*}}:{[[@LINE+1]]:9-[[@LINE+1]]:9}:"*"
    var a = p->m
    // CHECK: :[[@LINE+1]]:13: error [SC182E]: cannot move a value of type 'H' out of '*q'
    var b = *q
    var c = M(3)
    // CHECK: :[[@LINE+1]]:9: error [SC182E]: cannot move a value of type 'M' out of 'p->m'
    c = p->m
    // CHECK: :[[@LINE+1]]:10: error [SC182E]: cannot move a value of type 'M' out of 'q->m'
    sink(q->m)
    // CHECK: :[[@LINE+1]]:20: error [SC182E]: cannot move a value of type 'M' out of 'p->m'
    p->v.push_back(p->m)
}

// --- lit wiring ---
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s
