// witness/assoc_generic_derived_default.k -- exit 77
// A derived GENERIC interface giving an inherited associated type a default
// over its own parameter (interfaces.md, "Associated types and
// inheritance"): `interface <U> Wrapped derives Source<U> { type Item = U }`.
// The default is written over Wrapped's U, which the requirement's own
// instance (`Source<i32>`) never binds, so `S::Item` read for a conformer
// that took the default stayed `U` ("cannot convert 'U' to 'i32'"). It is
// read through the instance the conformer declares: `Wrapped<i32>`
// directly, `Wrapped<N>` of a generic conformer read at its arguments, and
// `Wrapped<V>` one interface further down (`W2<i16>`). A default naming
// `Self::Key` in a generic interface still reads Self as the conformer.

class <K> Bag {
    pub var k: K
    fn Bag(self, k: K) { self.k = k }
}

interface <T> Source {
    type Item
    fn get(const self) -> Self::Item
}

interface <U> Wrapped derives Source<U> {
    type Item = U
}

interface <V> W2 derives Wrapped<V> {
    fn two(const self) -> i32
}

interface <T> Keyed {
    type Key
    type Item
    fn item(const self) -> Self::Item
}

interface <U> BagOf derives Keyed<U> {
    type Item = Bag<Self::Key>
}

class Plain impl Wrapped<i32> {
    fn Plain(self) { }
    fn get(const self) -> i32 { return 30 }
}

class <N> Gen impl Wrapped<N> {
    pub var n: N
    fn Gen(self, n: N) { self.n = n }
    fn get(const self) -> N { return self.n }
}

class Deep impl W2<i16> {
    fn Deep(self) { }
    fn get(const self) -> i16 { return 20 }
    fn two(const self) -> i32 { return 2 }
}

class Keys impl BagOf<i8> {
    type Key = i32
    fn Keys(self) { }
    fn item(const self) -> Bag<i32> { return Bag<i32>(15) }
}

fn <S impl Wrapped<i32>> take(s: S) -> S::Item { return s.get() }
fn <S impl W2<i16>> deep(s: S) -> S::Item { var x: S::Item = s.get(); return x }
fn <S impl BagOf<i8>> bag(s: S) -> S::Item { return s.item() }

fn main() -> i32 {
    var a: i32 = take(Plain())          // 30
    var b: i32 = take(Gen<i32>(8))      // 8
    var c: i16 = deep(Deep())           // 20
    var d: Bag<i32> = bag(Keys())       // 15
    return a + b + (c as i32) + d.k + Deep().two() + 2   // 77
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 77
