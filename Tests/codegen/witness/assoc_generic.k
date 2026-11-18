// witness/assoc_generic.k -- exit 77
// A generic associated type (interfaces.md, Associated Types): `type <K>
// Map` is supplied by a generic alias of the same arity, named with its
// arguments (`Self::Map<K>` in the interface, `T::Map<i32>` in a body), and
// is one canonical per argument list. It was SC116E.
//
// The witness declares it as a member alias template, `template <class K>
// using Map = Bag<K>;`, and a body spells `typename
// Store_witness<T>::template Map<int>`. A conformer's `fn <K> wrap(...) ->
// Bag<K>` meets `fn <K> wrap(...) -> Self::Map<K>` (the alias read at K),
// and `s.unwrap(m)` deduces K := i32 from `T::Map<i32>`.
//
// Shapes: two non-generic conformers, a generic one whose alias reads its
// own parameter too (`Pair<N, K>`), a default taken by an explicit
// conformer, and a GAT whose own bound gives its values members.

interface Show {
    fn show(const self) -> i32
}

class <K> Bag {
    pub var k: K
    fn Bag(self, k: K) { self.k = k }
    fn show(const self) -> i32 { return 1 }
}

class <K> Two {
    pub var a: K
    pub var b: K
    fn Two(self, a: K, b: K) { self.a = a; self.b = b }
    fn show(const self) -> i32 { return 2 }
}

class <N, K> Pair {
    pub var n: N
    pub var k: K
    fn Pair(self, n: N, k: K) { self.n = n; self.k = k }
    fn show(const self) -> i32 { return 3 }
}

interface Store {
    type <K> Map impl Show
    fn <K> wrap(const self, k: K) -> Self::Map<K>
    fn <K> unwrap(const self, m: Self::Map<K>) -> K
}

interface Dflt {
    type <K> Cell = Bag<K>
    fn <K> cell(const self, k: K) -> Self::Cell<K>
    fn <K> peel(const self, c: Self::Cell<K>) -> K
}

class One impl Store {
    type <K> Map = Bag<K>
    fn One(self) { }
    fn <K> wrap(const self, k: K) -> Bag<K> { return Bag<K>(k) }
    fn <K> unwrap(const self, m: Bag<K>) -> K { return m.k }
}

class Dbl impl Store {
    type <K> Map = Two<K>
    fn Dbl(self) { }
    fn <K> wrap(const self, k: K) -> Two<K> { return Two<K>(k, k) }
    fn <K> unwrap(const self, m: Two<K>) -> K { return m.b }
}

class <N> Tag impl Store {
    type <K> Map = Pair<N, K>
    pub var n: N
    fn Tag(self, n: N) { self.n = n }
    fn <K> wrap(const self, k: K) -> Pair<N, K> { return Pair<N, K>(self.n, k) }
    fn <K> unwrap(const self, m: Pair<N, K>) -> K { return m.k }
}

class Def impl Dflt {
    fn Def(self) { }
    fn <K> cell(const self, k: K) -> Bag<K> { return Bag<K>(k) }
    fn <K> peel(const self, c: Bag<K>) -> K { return c.k }
}

fn <T impl Store> roundtrip(s: T, v: i32) -> i32 {
    var m: T::Map<i32> = s.wrap(v)
    return s.unwrap(m) + m.show()
}

fn <D impl Dflt> celled(d: D) -> i64 {
    var forty: i64 = 40
    var c: D::Cell<i64> = d.cell(forty)
    return d.peel(c)
}

fn main() -> i32 {
    // One: 3 + 1; Dbl: 10 + 2; Tag<bool>: 20 + 3; Def: 40 -> 79 - 2
    return roundtrip(One(), 3) + roundtrip(Dbl(), 10) + roundtrip(Tag<bool>(true), 20) + (celled(Def()) as i32) - 2
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: struct Store_witness<{{ ?}}::{{.*}}One> {
// CXX-NEXT: template<class K> using Map ={{ ?}}::{{.*}}Bag<K>;
// CXX: struct Store_witness<{{ ?}}::{{.*}}Tag<N>> {
// CXX-NEXT: template<class K> using Map ={{ ?}}::{{.*}}Pair<N, K>;
// CXX-NEXT: template<class K> static Map<K> wrap(
// CXX-NEXT: return self->template wrap<K>(
// CXX: struct Dflt_witness<{{ ?}}::{{.*}}Def> {
// CXX-NEXT: template<class K> using Cell ={{ ?}}::{{.*}}Bag<K>;
// CXX: typename{{ ?}}::{{.*}}Store_witness<T>::template Map<signed int> m =

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 77
