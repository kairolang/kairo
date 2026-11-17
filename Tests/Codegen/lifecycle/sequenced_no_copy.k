// A store through a pointer in a generic body, `p->val = pass(v)`, ends
// its statement with no value, so the statement expression its operands
// are bound in copies nothing: a move-only element type compiles and runs
// with moves only, and a COPY one is copied only where the code copies it.

import std::io

var moves: i32 = 0
var copies: i32 = 0

class MO {
    pub var v: u64

    pub fn MO(self, v: u64) {
        self.v = v
    }

    @move pub fn MO(self, other: Self) {
        self.v  = other.v
        other.v = 0
        moves += 1
    }
}

class S {
    pub var n: i32

    pub fn S(self, n: i32) {
        self.n = n
    }

    @copy pub fn S(self, const other: Self) {
        self.n = other.n
        copies += 1
    }
}

class <V> Node {
    pub var val: V

    pub fn Node(self, val: V) {
        self.val = val
    }
}

fn <V> pass(v: V) -> V {
    return v
}

class <V> Cell {
    pub var p: unsafe *Node<V>

    pub fn Cell(self, p: unsafe *Node<V>) {
        self.p = p
    }

    pub fn op []= (self, i: i32, v: V) {
        unsafe { self.p->val = pass(v) }
    }

    pub fn set(self, v: V) {
        unsafe { self.p->val = pass(v) }
    }
}

fn main() -> i32 {
    var n = Node<MO>(MO(1))
    var c = Cell<MO>(unsafe &n)
    var m0 = moves
    c[0] = MO(5)
    c.set(MO(6))
    // Per store: into pass's parameter, out of it, and the assignment.
    if moves - m0 != 6 || n.val.v != 6 {
        return 1
    }

    var sn = Node<S>(S(1))
    var sc = Cell<S>(unsafe &sn)
    var c0 = copies
    sc[0] = S(5)
    sc.set(S(6))
    // A COPY class has no move constructor: pass copies in and out, and
    // the assignment copies once.
    if copies - c0 != 6 || sn.val.n != 6 {
        return 2
    }

    io::println("ok")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// OUT: ok
