// The Copyable lang item (builtin/base/copy.k) is met by every COPY type
// with no `copy` of its own: `x.copy()` on one is its copy constructor,
// run exactly once, and a generic `T impl Copyable` takes it. A type that
// declares `copy` meets the interface with that method, which is what
// runs, whether or not the type is also COPY. One generic free `copy`
// serves both kinds.

var copies: i32 = 0
var own: i32    = 0

// COPY, by a declared copy constructor.
class Counted {
    pub var n: i32

    pub fn Counted(self, n: i32) {
        self.n = n
    }

    @copy pub fn Counted(self, const other: Self) {
        self.n = other.n
        copies += 1
    }
}

// COPY, with nothing declared.
struct Pair {
    var a: i32
    var b: i32
}

// Move-only: Copyable through its own `copy`.
class Owner {
    pub var n: i32

    pub fn Owner(self, n: i32) {
        self.n = n
    }

    @move pub fn Owner(self, other: Self) {
        self.n  = other.n
        other.n = 0
    }

    pub fn copy(const self) -> Self {
        own += 1
        return Owner(self.n + 100)
    }
}

// COPY and a `copy` of its own: the method wins.
class Both {
    pub var n: i32

    pub fn Both(self, n: i32) {
        self.n = n
    }

    @copy pub fn Both(self, const other: Self) {
        self.n = other.n
        copies += 1
    }

    pub fn copy(const self) -> Both {
        own += 1
        return Both(self.n + 1000)
    }
}

class <T> Cell {
    pub var v: T

    pub fn Cell(self, v: T) {
        self.v = v
    }

    // A type over a parameter copies through the free `copy`.
    pub fn twin(const self) -> Self {
        return copy(self)
    }
}

struct Holder {
    var c: Counted
}

fn make() -> Counted {
    return Counted(8)
}

fn <T> same(p: *T) -> *T {
    return copy(p)
}

enum Color {
    Red,
    Green,
}

fn <T impl Copyable> dup(const x: T) -> T {
    return x.copy()
}

fn <T impl Copyable> twice(const x: T) -> (T, T) {
    return (x.copy(), copy(x))
}

fn primitives() -> i32 {
    var i = 5
    var a = i.copy()
    var b = 7.copy()
    var c = dup(i)
    var d = copy(i)
    var f = 2.5
    var g = f.copy()
    var t = true
    var u = t.copy()
    var col = Color::Green
    var col2 = col.copy()
    if a != 5 || b != 7 || c != 5 || d != 5 {
        return 1
    }

    if g != 2.5 || !u || col2 != Color::Green || dup(col) != Color::Green {
        return 2
    }

    return 0
}

fn pointers() -> i32 {
    var i = 5
    var *p = &i
    var *q = p.copy()
    var *r = dup(p)
    var *s = copy(p)
    *q = 6
    if *r != 6 || *s != 6 || i != 6 {
        return 3
    }

    return 0
}

fn records() -> i32 {
    var c = Counted(3)
    copies = 0
    var d = c.copy()
    if copies != 1 || d.n != 3 {
        return 4
    }

    var e = dup(c)
    if copies != 2 || e.n != 3 {
        return 5
    }

    var f = copy(c)
    if copies != 3 || f.n != 3 {
        return 6
    }

    var p = Pair { a: 1, b: 2 }
    var q = p.copy()
    var r = dup(p)
    var s = copy(p)
    if q.b != 2 || r.a != 1 || s.b != 2 {
        return 7
    }

    var cell = Cell<i32>(9)
    if cell.copy().v != 9 || dup(cell).v != 9 {
        return 8
    }

    copies = 0
    var two = twice(c)
    if copies != 2 || two.0.n != 3 || two.1.n != 3 {
        return 9
    }

    return 0
}

fn aggregates() -> i32 {
    var c = Counted(3)
    var t = (1, c)
    copies = 0
    var u = t.copy()
    if copies != 1 || u.0 != 1 || u.1.n != 3 {
        return 10
    }

    var w = dup(t)
    if copies != 2 || w.1.n != 3 {
        return 11
    }

    var v: [i32] = [1, 2, 3]
    var v2 = dup(v)
    var v3 = copy(v)
    var v4 = v.copy()
    v[1] = 20
    if v2[1] != 2 || v3[1] != 2 || v4[1] != 2 {
        return 12
    }

    return 0
}

// The receiver is any value: a field, a pointee, a temporary, a slice, and
// a nullable or a type over a parameter through the free `copy`.
fn receivers() -> i32 {
    var c = Counted(3)
    var h = Holder { c: c }
    var *p = &c
    copies = 0
    var a = h.c.copy()
    var b = p->copy()
    var d = make().copy()
    if copies != 3 || a.n != 3 || b.n != 3 || d.n != 8 {
        return 15
    }

    var arr: [i32; 3] = [1, 2, 3]
    var s: [i32;] = arr
    var s2 = s.copy()
    var o: i32? = 4
    var o2? = copy(o)
    var cell = Cell<i32>(5)
    var *q = same(&c)
    if s2[1] != 2 || o2 == null || cell.twin().v != 5 || q->n != 3 {
        return 16
    }

    return 0
}

fn own_copy() -> i32 {
    var o = Owner(1)
    own = 0
    var a = o.copy()
    var b = dup(o)
    var c = copy(o)
    if own != 3 || a.n != 101 || b.n != 101 || c.n != 101 || o.n != 1 {
        return 13
    }

    var x = Both(1)
    own    = 0
    copies = 0
    var y = x.copy()
    var z = dup(x)
    var k = copy(x)
    if own != 3 || copies != 0 || y.n != 1001 || z.n != 1001 || k.n != 1001 {
        return 14
    }

    return 0
}

fn main() -> i32 {
    var r = primitives()
    if r != 0 {
        return r
    }

    r = pointers()
    if r != 0 {
        return r
    }

    r = records()
    if r != 0 {
        return r
    }

    r = aggregates()
    if r != 0 {
        return r
    }

    r = receivers()
    if r != 0 {
        return r
    }

    return own_copy()
}

// --- lit wiring -----------------------------------------------------------
// RUN: %overlay_builtins %t.lib base/copy.k=%S/Inputs/copy.k
// RUN: { %kairo_overlay --builtins-dir=%t.lib/builtin %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo_overlay --builtins-dir=%t.lib/builtin %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
