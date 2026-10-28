// A type nested in a generic class, named THROUGH AN INSTANCE (`L<i32>::P`,
// GH#91): it carries the instance's arguments, so its members read through
// them (`q.k` is an i32, not `K`) and C++ spells it `::ns::L<int>::P`. The
// pattern's `P` used to stand for every instance: `q.k` was SC028E "cannot
// convert 'K' to 'i32'", and the local was spelled `typename ::ns::L<K>::P`
// outside any template, which clang rejected.
//
// Shapes: a nested struct (field read, built with a brace list), a nested
// class with a method returning K, a nested plain enum, a nested type alias
// (`L<i32>::Key` is i32), two levels (`L<i32>::Mid::Leaf`), each as a local,
// a parameter, a return type and a field of a non-generic class; values made
// by L's own members and by the caller agree; two instances are two types.

class <K> L {
    pub struct P {
        pub var k: K
    }
    pub class Cell {
        pub var v: K
        pub fn Cell(self, v: K) { self.v = v }
        pub fn get(const self) -> K { return self.v }
    }
    pub enum Color { Red, Green }
    pub type Key = K
    pub class Mid {
        pub struct Leaf {
            pub var x: K
            pub var n: i32
        }
    }

    pub fn L(self) { }
    pub fn make(self, k: K) -> Self::P { return Self::P { k: k } }
    pub fn cell(self, k: K) -> Self::Cell { return Self::Cell(k) }
    pub fn leaf(self, k: K) -> Self::Mid::Leaf { return Self::Mid::Leaf { x: k, n: 2 } }
    pub fn take(self, p: Self::P) -> K { return p.k }
}

class Holder {
    pub var p: L<i32>::P
    pub var key: L<i32>::Key
    pub fn Holder(self, p: L<i32>::P) { self.p = p; self.key = p.k + 1 }
}

fn read(p: L<i32>::P) -> i32 { return p.k }
fn build(k: i32) -> L<i32>::P { return L<i32>::P { k: k } }
fn shade(c: L<i32>::Color) -> i32 {
    if c == L<i32>::Color::Green { return 1 }
    return 0
}

fn main() -> i32 {
    var l = L<i32>()
    var q: L<i32>::P = l.make(7)
    var n: i32 = q.k                            // 7
    var r = 0
    if n == 7 { r += 1 }
    if (read(build(3)) == 3) && (l.take(build(4)) == 4) { r += 2 }

    var c: L<i32>::Cell = l.cell(5)
    var cv: i32 = c.get()
    if cv == 5 { r += 4 }

    var key: L<i32>::Key = 9
    var h = Holder(q)
    if (key == 9) && (h.key == 8) && (h.p.k == 7) { r += 8 }

    var lf: L<i32>::Mid::Leaf = l.leaf(6)
    var lx: i32 = lf.x
    if (lx == 6) && (lf.n == 2) { r += 16 }

    if shade(L<i32>::Color::Green) == 1 { r += 32 }

    var d = L<f64>()
    var dq: L<f64>::P = d.make(1.5)
    var dk: f64 = dq.k
    if dk == 1.5 { r += 64 }
    return r                                    // 127
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// Outside L's template the nested types are spelled through the instance.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: signed int read({{ ?}}::generic_nested_instance::L<signed int>::P p) noexcept
// CXX-NOT: typename{{ ?}}::generic_nested_instance::L<K>::{{(P|Cell|Mid)}} {{[a-z]+}} =

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 127
