// A returned local or by-value parameter of a MOVE type is moved, also when
// the return type is its nullable or a tuple holding it. A value returned
// through its own `@implicit op as` is that operator's receiver and is not
// moved. M has no copy constructor, so each of these compiles only as a
// move.

var made:  i32 = 0
var moves: i32 = 0
var drops: i32 = 0

class M {
    pub var v: i32

    pub fn M(self, v: i32) {
        self.v = v
        made   += 1
    }

    @move pub fn M(self, other: Self) {
        self.v  = other.v
        other.v = -1
        moves   += 1
    }

    @implicit pub fn op as (const self) -> Wide = Wide(self.v)

    fn op finally(self) {
        drops += 1
    }
}

class Wide {
    pub var m: M
    pub var tag: i32 = 7

    pub fn Wide(self, v: i32) {
        self.m = M(v)
    }
}

fn keep(x: M) -> M? {
    if x.v > 0 {
        return x
    }

    return null
}

fn local(v: i32) -> M? {
    var m = M(v)
    return m
}

fn pair(x: M) -> (M, i32) {
    return (x, 2)
}

fn widen(x: M) -> Wide {
    return x
}

fn main() -> i32 {
    var r? = keep(M(3))
    if (r?.v ?? 0) != 3 { return 1 }

    var n? = keep(M(-1))
    if n != null { return 2 }

    var l? = local(5)
    if (l?.v ?? 0) != 5 { return 3 }

    var p = pair(M(4))
    if p.0.v != 4 || p.1 != 2 { return 4 }

    var w = widen(M(6))
    if w.m.v != 6 || w.tag != 7 { return 5 }

    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
