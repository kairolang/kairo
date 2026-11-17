// `Bag<Mv>` is first named here, in another module than Bag: this TU's C++
// still gives the instance the move pair only (Kairo says MOVE, C++'s
// traits would say the vector copies), so it is moved into `take`.

import bag::*

pub class Mv {
    pub var n: i32 = 0
    pub fn Mv(self, n: i32) {
        self.n = n
    }

    @move pub fn Mv(self, other: Self) {
        self.n  = other.n
        other.n = 0
    }
}

fn take(b: Bag<Mv>) -> i32 {
    return b.items[0].n
}

fn main() -> i32 {
    var b = Bag<Mv>()
    b.items.push_back(Mv(9))
    return take(b) - 9
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
