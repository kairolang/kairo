// A field of a generic record whose default the instance decides -- a type
// parameter, one bounded by an interface, an associated type, a tuple over
// one (classes.mdx, Fields without a default) -- is initialized by the
// constructor's first whole write when every path makes that write before
// the object is used. Each instance then builds the field from that value,
// so an element type with no default constructor works, COPY and move-only
// alike. `[T]` and `T?` have a default at every instance and need nothing.
// A constructor that leaves the field to its default on some path, or uses
// the object first, is accepted as before and value-initializes the field
// at an instance that has a default.

class Counted {
    var n: i32
    pub fn Counted(self, n: i32) { self.n = n }
    @copy pub fn Counted(self, const other: Self) { self.n = other.n }
}

class Owned {
    var n: i32
    pub fn Owned(self, n: i32) { self.n = n }
    @move pub fn Owned(self, other: Self) = default
}

interface Source {
    type Item
    fn get(self) -> Self::Item
}

class Gauge {
    var n: i32
    pub fn Gauge(self, n: i32) { self.n = n }
    @copy pub fn Gauge(self, const other: Self) { self.n = other.n }
}

extend Gauge impl Source {
    type Item = Counted
    fn get(self) -> Counted { return Counted(self.n) }
}

class <T> Cell {
    pub var v: T
    pub fn Cell(self, v: T) { self.v = v }
}

// Built in a branch: both arms write it, so it is built on every path.
class <T> Either {
    pub var v: T
    pub fn Either(self, a: T, b: T, first: bool) {
        if first {
            self.v = a
        } else {
            self.v = b
        }
    }
}

// An adapter holding its source by value.
class <I impl Source> Adapter {
    pub var src: I
    pub var last: I::Item
    pub fn Adapter(self, src: I) {
        self.last = src.get()
        self.src  = src
    }
}

class <T> Pairs {
    pub var p: (T, i32)
    pub var many: [T]
    pub var maybe: T?
    pub fn Pairs(self, v: T, w: T) {
        self.p = (v, 1)
        self.many.push(w)
    }
}

// Not built on every path, or used first: as before, which an instance
// with a default accepts.
class <T> Later {
    pub var v: T
    pub fn Later(self) { }
    pub fn Later(self, v: T, k: i32) {
        self.touch()
        self.v = v
    }
    fn touch(self) { }
}

fn main() -> i32 {
    var r = 0
    var a = Cell<Counted>(Counted(1))
    r += a.v.n                                                          // 1
    var b = Cell<Owned>(Owned(2))
    r += b.v.n                                                          // 2
    var c = Either<Counted>(Counted(3), Counted(30), true)
    r += c.v.n                                                          // 3
    var d = Either<Owned>(Owned(40), Owned(4), false)
    r += d.v.n                                                          // 4
    var e = Adapter<Gauge>(Gauge(5))
    r += e.last.n                                                       // 5
    r += e.src.n - 5                                                    // 0
    var f = Pairs<Counted>(Counted(6), Counted(7))
    r += f.p.0.n + f.p.1 + f.many[0].n                                  // 14
    r += if (f.maybe == null) => (0) else => 100                        // 0
    var g = Cell<(Owned, i32)?>(null)
    r += if (g.v == null) => (17) else => 0                            // 17
    var h = Cell<i32>(10)
    r += h.v                                                            // 10
    var l = Later<i32>()
    r += l.v                                                            // 0
    var m = Later<i32>(11, 0)
    r += m.v                                                            // 11
    return r                                                            // 67
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 67
