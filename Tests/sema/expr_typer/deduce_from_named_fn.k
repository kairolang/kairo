// A type parameter that appears in a `fn(...) -> U` parameter deduces from
// the argument's function type: a named function or a `fn` value. An
// associated type in the parameter list (`fn(I::Item) -> U`) binds nothing
// itself; once its head is bound (by an earlier argument, or by the receiver
// of an extension member) it is that type, and the argument's parameter has
// to match it.

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

class <T> Bag {
    pub var v: T
    pub fn <U> map(const self, f: fn(T) -> U) -> U = f(self.v)
}

fn <U> apply(x: i32, f: fn(i32) -> U) -> U = f(x)

fn triple(x: i32) -> i32 = x * 3
fn half(x: i32) -> f64 = x as f64 / 2.0
fn wide(x: i64) -> i64 = x

fn main() -> i32 {
    var b = Bag<i32> { v: 2 }
    var r = b.map(triple) - 6
    r += apply(3, triple) - 9
    var p = Pipe<Ints> { s: Ints() }
    r += p.map(triple) - 12
    r += via(Ints(), triple) - 12
    return r
}

fn mismatch() -> i64 {
    return via(Ints(), wide)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT:  error
// CHECK:      error [SC063E]: no matching overload for call to 'via'
// CHECK-NOT:  error [
