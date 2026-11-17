// A type written on a loop binder, or on a destructuring binder, is the
// binder's declared type, as in `var y: T = elem`: the value the binder
// takes converts to it implicitly. `for y: T` and `for var y: T` are the same
// binder. Covered: a range, a fixed array, a vector, a C++ vector, a map's
// binder list, a const binder, a nullable written type, a generator, a
// member's and an extension's `@implicit op as`, and a tuple destructure.

ffi "c++" import "vector"

class Big {
    pub var v: i64 = 0
    fn Big(self, v: i64) {
        self.v = v
    }
}

class Small {
    pub var v: i32 = 0
    fn Small(self, v: i32) {
        self.v = v
    }

    @implicit fn op as (const self) -> Big {
        return Big(self.v as i64 * 2)
    }
}

class Path {
    pub var n: i32 = 0
    fn Path(self, n: i32) {
        self.n = n
    }
}

// C++ would reach Path from an i32 through Path's constructor; Kairo's
// conversion is this operator.
extend i32 {
    @implicit fn op as (const self) -> Path {
        return Path(self + 100)
    }
}

fn gen() -> yield i32 {
    yield 4
    yield 5
}

fn main() -> i32 {
    var s: i64 = 0
    for y: i64 in [2147483647, 1] {
        s += y
    }
    if s != 2147483648 { return 1 }

    var xs = [1, 2, 3]
    s = 0
    for var y: i64 in xs {
        y *= 4294967296
        s += y
    }
    if s != 6 * 4294967296 { return 2 }

    s = 0
    for y: i64 in 0..3 {
        s += y * 4294967296
    }
    if s != 3 * 4294967296 { return 3 }

    var arr: [i32; 3] = [5, 6, 7]
    s = 0
    for const y: i64 in arr {
        s += y
    }
    if s != 18 { return 4 }

    var m = {"a": 1, "b": 2}
    s = 0
    for (k: string, v: i64) in m {
        s += v * 4294967296
    }
    if s != 3 * 4294967296 { return 5 }

    var t = 0

    var ss = [Small(1), Small(2)]
    s = 0
    for b: Big in ss {
        s += b.v
    }
    if s != 6 { return 7 }

    t = 0
    for p: Path in xs {
        t += p.n
    }
    if t != 306 { return 8 }

    var v: cxx::std::vector<i32>
    v.push_back(7)
    s = 0
    for y: i64 in v {
        s += y * 4294967296
    }
    if s != 7 * 4294967296 { return 9 }

    t = 0
    for y: i32? in xs {
        if y != null { t += 1 }
    }
    if t != 3 { return 10 }

    s = 0
    for g: i64 in gen() {
        s += g * 4294967296
    }
    if s != 9 * 4294967296 { return 11 }

    var tup = (1, 2)
    var (a: i64, q: Path) = tup
    if a * 4294967296 != 4294967296 || q.n != 102 { return 12 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe
