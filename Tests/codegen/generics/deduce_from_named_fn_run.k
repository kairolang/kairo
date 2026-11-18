// A callback's result type deduces from a named function, a `fn` value or
// a closure, also through an associated type of an extension's receiver,
// and the deduced instance runs.

interface Source {
    type Item
    fn get(const self) -> Self::Item
}

class Ints {
    pub var n: i32 = 4
}

extend Ints impl Source {
    type Item = i32
    fn get(const self) -> i32 = self.n
}

class <S> Pipe {
    pub var s: S
}

extend <S impl Source> Pipe<S> {
    pub fn <U> map(const self, f: fn(S::Item) -> U) -> U = f(self.s.get())
}

fn <I impl Source, U> via(const s: I, f: fn(I::Item) -> U) -> U = f(s.get())

fn triple(x: i32) -> i32 = x * 3
fn half(x: i32) -> f64 = x as f64 / 2.0

fn main() -> i32 {
    var p = Pipe<Ints> { s: Ints() }
    var r = p.map(triple) - 12
    r += (p.map(half) * 2.0) as i32 - 4
    r += via(Ints(), triple) - 12
    var g: fn(i32) -> f64 = half
    r += (via(Ints(), g) * 2.0) as i32 - 4
    var k = 2
    r += via(Ints(), fn (x: i32) -> i32 { return x * k }) - 8
    r += p.map(fn (x: i32) -> i64 { return x }) as i32 - 4
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
