// An lvalue passed to a `@move` parameter of a generic function is cast to
// an rvalue of the argument's own type: from a generic caller whose
// parameters have other names (U, K and V, a pack's element), from a
// concrete caller, and through std::move. Each transfer runs the move
// constructor exactly once and never the copy constructor.

import std

var moves: i32 = 0
var copies: i32 = 0

class M {
    pub var k: u64

    pub fn M(self, k: u64) {
        self.k = k
    }

    @move pub fn M(self, other: Self) {
        self.k  = other.k
        other.k = 0
        moves += 1
    }
}

class C {
    pub var k: u64

    pub fn C(self, k: u64) {
        self.k = k
    }

    @copy pub fn C(self, const other: Self) {
        self.k = other.k
        copies += 1
    }
}

pub inline fn <T> mv(@move x: T) -> T = x

fn <U> take_u(p: unsafe *U) -> U {
    unsafe { return mv(*p) }
}

fn <U> take_explicit(p: unsafe *U) -> U {
    unsafe { return mv<U>(*p) }
}

fn <K, V> take_v(p: unsafe *V, k: K) -> V {
    unsafe { return mv(*p) }
}

fn <...Ts> take_pack(p: unsafe *M, ...xs: Ts) -> M {
    unsafe { return mv(*p) }
}

fn <U> take_std(p: unsafe *U) -> U {
    unsafe { return std::move(*p) }
}

fn take_concrete(p: unsafe *M) -> M {
    unsafe { return mv(*p) }
}

fn main() -> i32 {
    var a = M(1)
    var b = M(2)
    var c = M(3)
    var d = M(4)
    var e = M(5)
    var f = M(6)
    var g = C(7)

    var ra = take_u<M>(unsafe &a)
    if moves != 1 || ra.k != 1 || a.k != 0 {
        return 1
    }

    var rb = take_explicit<M>(unsafe &b)
    var rc = take_v<bool, M>(unsafe &c, true)
    var rd = take_pack(unsafe &d, 1, "x")
    if moves != 4 || rb.k + rc.k + rd.k != 9 {
        return 2
    }

    var re = take_std<M>(unsafe &e)
    var rf = take_concrete(unsafe &f)
    if moves != 6 || re.k + rf.k != 11 {
        return 3
    }

    // A COPY class has no move constructor: its "move" is one copy.
    var rg = take_u<C>(unsafe &g)
    if copies != 1 || rg.k != 7 {
        return 4
    }

    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
