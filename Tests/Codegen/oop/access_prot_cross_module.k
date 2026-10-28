// `prot` from a subclass in another module (Inputs/access_prot_lib.k): a
// field, a static, a method and a constructor of the base, and a generic
// base's method and constructor, all reached from the derived class's own
// methods. Allowed by AccessCheck, and the C++ compiles and runs.
//
// Each check returns its own code on failure; 0 is a pass.

import Inputs::access_prot_lib::*

class Counter derives Base {
    fn Counter(self) { Base::Base(self, 2) }
    fn hit(self) -> i32 {
        self.bump(Base::scale)
        return self.hits
    }
}

class Grand derives Counter {
    fn twice(self) -> i32 {
        self.bump(1)
        return self.hits * 2
    }
}

class IntSlot derives Slot<i32> {
    fn IntSlot(self) { Slot<i32>::Slot(self, 40) }
    fn plus(const self, n: i32) -> i32 { return self.peek() + n }
}

fn main() -> i32 {
    var c = Counter()
    if c.hit() != 5 { return 1 }
    if c.read() != 5 { return 2 }
    var g = Grand()
    if g.twice() != 6 { return 3 }
    var s = IntSlot()
    if s.plus(2) != 42 { return 4 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
