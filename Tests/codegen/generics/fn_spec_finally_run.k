// A function specialization's body is an ordinary body: a local it ends
// with `finally()` is destroyed there and not again. A specialization is
// never a candidate beside constrained overloads of its name: the calls of
// two arguments are ordered by their clauses alone, and the one-argument
// call takes the primary whose specialization runs for `Cat`.

var dtors: i32 = 0

class Res {
    pub var id: i32 = 0
    fn Res(self, id: i32) { self.id = id }
    @move fn Res(self, other: Self) {
        self.id  = other.id
        other.id = 0
    }
    fn op finally(self) {
        if self.id != 0 {
            dtors += 1
        }
    }
}

fn <T> make() -> i32 { return 1 }
fn <> make<i32>() -> i32 {
    var r = Res(5)
    const id = r.id
    r.finally()
    return id
}

interface Loud { fn shout(const self) -> i32 }
class Dog impl Loud { fn shout(const self) -> i32 { return 7 } }
class Cat { }

fn <T> say(const x: T, n: i32) -> i32 requires T impl Loud { return x.shout() + n }
fn <T> say(const x: T, n: i32) -> i32 requires !(T impl Loud) { return n }
fn <T> say(const x: T) -> i32 { return 1 }
fn <> say<Cat>(const x: Cat) -> i32 { return 9 }

fn main() -> i32 {
    if make<i32>() != 5 || make<u8>() != 1 { return 1 }
    if dtors != 1 { return 2 }
    if say(Dog(), 1) != 8 || say(Cat(), 2) != 2 { return 3 }
    if say(Dog()) != 1 || say(Cat()) != 9 { return 4 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
