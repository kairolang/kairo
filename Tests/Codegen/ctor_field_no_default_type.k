// A generic record's constructor that writes a field of type `K` before
// anything else builds the field from that value, so `K` needs no default
// constructor: a class or a struct, one field or several, `K` with only a
// one-argument constructor or move-only.

class NoDef {
    pub var n: i32 = 0
    pub fn NoDef(self, n: i32) { self.n = n }
}

class Mv {
    pub var n: i32 = 0
    pub fn Mv(self, n: i32) { self.n = n }
    @move pub fn Mv(self, o: Self) { self.n = o.n; o.n = -1 }
}

class <K, V> MapEntry {
    pub var key: K
    pub var val: V
    pub fn MapEntry(self, k: K, v: V) { self.key = k; self.val = v }
}

struct <K> S {
    pub var key: K
    pub fn S(self, k: K) { self.key = k }
}

class <T> Box {
    pub var v: T
    fn Box(self, v: T) { self.v = v }
}

fn main() -> i32 {
    var e = MapEntry<NoDef, NoDef>(NoDef(3), NoDef(4))
    var s = S<NoDef>(NoDef(5))
    var m = MapEntry<Mv, Mv>(Mv(10), Mv(20))
    var b = Box<NoDef>(NoDef(1))
    return e.key.n + e.val.n + s.key.n + m.key.n + m.val.n + b.v.n - 43
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.e
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.e
// RUN: %t.o2.exe
