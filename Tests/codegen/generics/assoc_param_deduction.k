// A parameter read through an associated type of another parameter
// (`v: J::Item`, `v: S::Item?`, `p: *J::Item`) is not deduced from: J
// comes from its own argument, and the argument for `J::Item` is checked
// against J's Item, in either parameter order. Extension members are
// deduced on dependent receivers: a generic member calling a sibling of
// its extension, and a two-parameter class's extension used from generic
// code.

interface Src {
    type Item
    fn get(self) -> Self::Item
}

interface Sink {
    type Item
    fn put(self, v: Self::Item) -> i32
}

class Num {
    pub var v: i32

    pub fn Num(self, v: i32) {
        self.v = v
    }
}

struct Count {
    pub var n: i32
}

extend Count impl Src {
    type Item = Num
    fn get(self) -> Num { return Num(self.n) }
}

struct Tally {
    pub var n: i32
}

extend Tally impl Sink {
    type Item = i32
    fn put(self, v: i32) -> i32 { return v + self.n }
}

fn <J impl Src> first(j: J, v: J::Item) -> i32 {
    return 1
}

fn <J impl Src> second(v: J::Item, j: J) -> i32 {
    return 2
}

fn <J impl Src> through(j: J, p: *J::Item) -> i32 {
    return 3
}

fn <S impl Sink> feed(s: S, v: S::Item?) -> i32 {
    return s.put(v ?? 0)
}

interface Big {
    fn big(const self, const o: Self) -> bool
}

extend i32 impl Big {
    fn big(const self, const o: i32) -> bool { return self > o }
}

class <T> Pair {
    pub var a: T
    pub var b: T

    pub fn Pair(self, a: T, b: T) {
        self.a = a
        self.b = b
    }
}

extend <T impl Big> Pair<T> {
    fn max(const self) -> T {
        return if (self.a.big(self.b)) => (self.a) else => (self.b)
    }

    fn <U> max_with(const self, const u: U) -> T {
        return self.max()
    }
}

class <K, V> Entry {
    pub var k: K
    pub var v: V

    pub fn Entry(self, k: K, v: V) {
        self.k = k
        self.v = v
    }
}

extend <K, V> Entry<K, V> {
    fn value(const self) -> V { return self.v }
}

fn <A, B> value_of(a: A, b: B) -> B {
    var e = Entry<A, B>(a, b)
    return e.value()
}

fn main() -> i32 {
    var n = Num(4)
    var t = Tally { n: 1 }
    if first(Count { n: 0 }, Num(1)) != 1 || second(Num(1), Count { n: 0 }) != 2 {
        return 1
    }

    if through(Count { n: 0 }, &n) != 3 || feed(t, 5) != 6 || feed(t, null) != 1 {
        return 2
    }

    var p = Pair<i32>(3, 7)
    if p.max_with(true) != 7 || value_of(true, 5) != 5 {
        return 3
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
