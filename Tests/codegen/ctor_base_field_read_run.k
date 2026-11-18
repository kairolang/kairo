// A constructor that initializes a field in place builds its bases first, as
// C++ does, so before its last own field is initialized it may read and
// change a field of a base: the base exists. A read through a base method is
// still refused there (ctor_inherited_field.k), since the method could reach
// the fields not built yet. The public constructor is the one a C++ host
// calls (Tests/cli/kcc).

class Q {
    pub var n: i32
    fn Q(self, n: i32) {
        self.n = n
    }
}

class Base {
    pub var ctx: i32 = 7
    pub var arr: [i32; 2] = [1, 2]
    pub var pt: Q = Q(0)

    fn Base(self) { }

    fn Base(self, c: i32) {
        self.ctx = c
    }
}

class Read derives Base {
    pub const k: i32
    pub var q: Q

    fn Read(self, v: i32) {
        Base::Base(self, v)
        var t = self.ctx * 2
        if v > 1 {
            self.ctx += 1
        }

        self.arr[0] = t
        self.pt.n = v
        self.k = t
        self.q = Q(self.ctx + self.arr[1])
    }
}

// With no field built from a slot (`n` is assigned on one path only), the
// pre-function runs first in the body.
class Some derives Base {
    pub const k: i32 = 1
    pub var n: i32 = 0
    pub var q: Q

    fn Some(self, c: bool) {
        var t = self.ctx
        if c {
            self.n = t
        }

        self.q = Q(t)
    }
}

fn main() -> i32 {
    var r = Read(5)
    if r.k != 10 || r.ctx != 6 || r.arr[0] != 10 || r.pt.n != 5 || r.q.n != 8 { return 1 }

    var s = Some(true)
    if s.n != 7 || s.q.n != 7 { return 2 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe
