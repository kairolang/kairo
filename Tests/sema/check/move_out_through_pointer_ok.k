// What still moves under the rule that refuses a move out of storage
// reached through a pointer: a local, a by-value parameter and a field of
// either, and the explicit hand-off `cxx::std::move(...)`. A copy and a
// borrow of the pointee are the two ways to read it without moving.

ffi "c++" import "vector"
ffi "c++" import "utility"

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

fn from_param(h: H) -> M {
    var x = h.m
    return x
}

fn read(p: *H) -> i32 {
    var a = p->m.copy()
    var *b = &p->m
    return a.n + b->n
}

fn hand_off(p: *H) -> i32 {
    p->v.push_back(cxx::std::move(p->m))
    return p->v[0].n * 10
}

fn main() -> i32 {
    var h = H()
    var l = M(4)
    var k = l
    var r = read(&h)                   // 1 + 1
    var g = hand_off(&h)               // 10
    return from_param(H()).n * 100 + r + g + k.n
}

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 116
// RUN: %kairo --type-check-only %s 2>&1 | %FileCheck %s --allow-empty --check-prefix=NODIAG
// NODIAG-NOT: error
