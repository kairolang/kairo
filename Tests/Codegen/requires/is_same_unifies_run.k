// Inside a declaration guarded by `requires __builtin_is_same<A, B>()`
// the two types are one type: a `B` value converts to `A` in a return, an
// initializer, an assignment and a call argument. The clause may stand on
// a function, on a generic class (its methods and the extensions of the
// class rely on it), and beside other requirements; the types may be
// associated types of bounded parameters.

import std::io::println

interface Source {
    type Item
    fn next(self) -> Self::Item
}

class Count {
    var n: i32 = 0
}

extend Count impl Source {
    type Item = i32
    fn next(self) -> i32 {
        self.n += 1
        return self.n
    }
}

// Two parameters.
fn <A, B> same(b: B) -> A requires __builtin_is_same<A, B>() {
    return b
}

// An associated type and a parameter, with another requirement beside it.
fn <T, J impl Source> second(it: J, seed: T) -> T
  requires __builtin_is_same<J::Item, T>() && sizeof T >= 4 {
    var x: T = it.next()
    x = it.next()
    return x
}

fn <X> pick(a: X, b: X, first: bool) -> X { return if first => a else => b }

fn take_i32(x: i32) -> i32 { return x }

// One parameter of a callee deduced from both types, and an `if`
// expression whose arms are the two.
fn <T, J impl Source> deduced(it: J, seed: T, first: bool) -> T
  requires __builtin_is_same<J::Item, T>() {
    var a = pick(seed, it.next(), false)
    return if first => a else => it.next()
}

// A chain of equalities ends at one type: T is J::Item is i32.
fn <T, J impl Source> chained(it: J, seed: T) -> i32
  requires __builtin_is_same<J::Item, i32>() && __builtin_is_same<T, J::Item>() {
    return take_i32(it.next()) + take_i32(seed)
}

class <T> Box {
    var v: T

    fn put(self, x: T) { self.v = x }

    // The clause is the method's own; `put` takes a T.
    fn <J impl Source> fill(self, it: J) requires __builtin_is_same<J::Item, T>() {
        self.put(it.next())
    }
}

// The clause is the class's: its methods and its extension rely on it.
class <I impl Source, J impl Source> Chain requires __builtin_is_same<J::Item, I::Item>() {
    var a:     I
    var b:     J
    var first: bool = true

    fn peek_b(self) -> I::Item { return self.b.next() }
}

extend <I impl Source, J impl Source> Chain<I, J> impl Source {
    type Item = I::Item
    fn next(self) -> I::Item {
        if self.first {
            self.first = false
            return self.a.next()
        }

        return self.b.next()
    }
}

fn main() -> i32 {
    var s: i32 = same<i32, i32>(7)
    var t = second(Count{}, 0)
    var b = Box<i32>{v: 0}
    b.fill(Count{})
    var c = Chain<Count, Count>{a: Count{}, b: Count{n: 40}}
    var p = c.peek_b()
    var q = c.next()
    var r = c.next()
    var d = deduced(Count{}, 9, true)
    var e = chained(Count{}, 10)
    println(f"{s} {t} {b.v} {p} {q} {r} {d} {e}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// OUT: 7 2 1 41 1 42 1 11
