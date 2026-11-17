// A generic body's by-value transfer of a `T` out of storage it does not
// own -- a pointee (`*p`, `p->v`, `*f()`), a part of `self` -- is decided
// per instance, as the same transfer of a MOVE value is in a body that is
// not generic: it moves at an instance whose type cannot be copied and
// copies at every other, so the source keeps its value there; an optional
// and a tuple of a move-only type move as it does. A named `T`
// in a tuple literal is a transfer too. One C++ template serves both.

class Owned {
    pub var n: i32
    pub fn Owned(self, n: i32) { self.n = n }
    @move pub fn Owned(self, other: Self) = default
}

class Counted {
    pub var n: i32
    pub fn Counted(self, n: i32) { self.n = n }
    @copy pub fn Counted(self, const other: Self) { self.n = other.n }
}

class <T> Box {
    pub var v: T
    pub fn Box(self, v: T) { self.v = v }
    pub fn take(self) -> T { return self.v }
    pub fn swap_in(self, v: T) -> T {
        var old: T = self.v
        self.v = v
        return old
    }
}

class <T> Slot {
    pub var v: T
    pub fn Slot(self, v: T) { self.v = v }
    pub fn at(self) -> unsafe *T { return unsafe &self.v }
}

fn <T> swap(a: unsafe *T, b: unsafe *T) {
    unsafe {
        var t: T = *a
        *a = *b
        *b = t
    }
}

fn <T> out_of(b: unsafe *Box<T>) -> T {
    unsafe {
        return b->v
    }
}

fn <T> through_call(s: unsafe *Slot<T>) -> T {
    unsafe {
        return *s->at()
    }
}

fn <T> pair(v: T) -> (T, i32) {
    return (v, 1)
}

fn main() -> i32 {
    var r = 0

    // Move-only: each transfer moves.
    var a = Owned(1)
    var b = Owned(2)
    swap<Owned>(unsafe &a, unsafe &b)
    r += a.n * 10 + b.n                                         // 21
    var bx = Box<Owned>(Owned(3))
    r += bx.take().n                                            // 3
    var by = Box<Owned>(Owned(4))
    r += by.swap_in(Owned(5)).n + by.v.n                        // 9
    var bz = Box<Owned>(Owned(6))
    r += out_of<Owned>(unsafe &bz).n                            // 6
    var sl = Slot<Owned>(Owned(7))
    r += through_call<Owned>(unsafe &sl).n                      // 7
    r += pair<Owned>(Owned(8)).0.n                              // 8
    var oa: Owned? = Owned(9)
    var oq: Owned? = null
    swap<Owned?>(unsafe &oa, unsafe &oq)
    r += if (oa == null && oq != null) => (1) else => 50       // 1
    var ts = (Owned(5), 1)
    var tu = (Owned(6), 2)
    swap<(Owned, i32)>(unsafe &ts, unsafe &tu)
    r += ts.1                                                   // 2

    // COPY: each transfer copies, and the source keeps its value.
    var c = Counted(1)
    var d = Counted(2)
    swap<Counted>(unsafe &c, unsafe &d)
    r += c.n * 10 + d.n                                         // 21
    var cx = Box<Counted>(Counted(3))
    r += cx.take().n + cx.v.n                                   // 6
    var cz = Box<Counted>(Counted(6))
    r += out_of<Counted>(unsafe &cz).n + cz.v.n                 // 12
    var cs = Slot<Counted>(Counted(7))
    r += through_call<Counted>(unsafe &cs).n + cs.v.n           // 14
    var i = 4
    var j = 5
    swap<i32>(unsafe &i, unsafe &j)
    r += i - j                                                  // 1
    return r - 100                                              // 11
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 11
