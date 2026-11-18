// A nullable of a type the body knows only by its bounds (`T?`, `J::Item?`)
// narrows as a concrete `T?` does. Proven non-null (`if x?`, an early return
// on `x == null`, a `while x?`), the place is read as its value where a `T`
// is wanted: an argument to a parameter that is that `T` in every instance,
// a declared local, a result. `J::Item` and `T` are one type where a
// `requires __builtin_is_same` of the declaration says so.

interface Source {
    type Item
    fn next(self) -> Self::Item?
}

class <T> Bag {
    pub var n:    i64
    pub var last: T

    pub fn Bag(self, z: T) {
        self.n    = 0
        self.last = z
    }

    pub fn put(self, v: T) {
        self.n    += 1
        self.last = v
    }
}

class Ticks {
    var left: i32

    pub fn Ticks(self, n: i32) {
        self.left = n
    }
}

extend Ticks impl Source {
    type Item = i64
    fn next(self) -> i64? {
        if self.left == 0 {
            return null
        }

        self.left -= 1
        return 5
    }
}

fn <T> keep(v: T) -> T = v

// `T?` handed to a member whose parameter is the receiver's `T`.
fn <T> plain(z: T, x: T?) -> T {
    var b = Bag<T>(z)
    if x? {
        b.put(x)
    }

    return b.last
}

// The associated type, equated with `T` by the clause.
fn <T, J impl Source> tested(it: J, z: T) -> T requires __builtin_is_same<J::Item, T>() {
    var b = Bag<T>(z)
    var x = it.next()
    if x? {
        b.put(x)
    }

    return b.last
}

fn <T, J impl Source> early(it: J, z: T) -> T requires __builtin_is_same<J::Item, T>() {
    var b = Bag<T>(z)
    var x = it.next()
    if x == null {
        return z
    }

    b.put(x)
    return b.last
}

// A declared local and a result take the value.
fn <T, J impl Source> local(it: J) -> T? requires __builtin_is_same<J::Item, T>() {
    var x = it.next()
    if x == null {
        return null
    }

    var y: T = x
    return keep(y)
}

fn <J impl Source> drained(it: J) -> i64 {
    var n: i64 = 0
    var x      = it.next()
    while x? {
        n += 1
        x = it.next()
    }

    return n
}

// In a static of a generic extension, over the extension's parameter.
extend <T> Bag<T> {
    pub static fn <J impl Source> fill(it: J, z: T) -> i64 requires __builtin_is_same<J::Item, T>() {
        var b = Bag<T>(z)
        var x = it.next()
        if x? {
            b.put(x)
        }

        return b.n
    }
}

fn main() -> i32 {
    var q: i64? = 5
    if plain(0 as i64, q) != 5 { return 1 }
    if tested(Ticks(1), 0 as i64) != 5 { return 2 }
    if tested(Ticks(0), 9 as i64) != 9 { return 3 }
    if early(Ticks(1), 0 as i64) != 5 { return 4 }
    if early(Ticks(0), 9 as i64) != 9 { return 5 }
    var got? = local<i64, Ticks>(Ticks(1))
    if got == null { return 6 }
    var none? = local<i64, Ticks>(Ticks(0))
    if none != null { return 7 }
    if drained(Ticks(3)) != 3 { return 8 }
    if Bag<i64>::fill(Ticks(1), 0) != 1 { return 9 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// The narrowed place is read through `__value()`, never passed whole.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: inline T plain(T z,
// CXX:       b.put({{.*}}x.__value()
// CXX-LABEL: inline T tested(J it, T z)
// CXX:       b.put({{.*}}x.__value()

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
