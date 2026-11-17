// Destructuring a value whose parts are MOVE moves each part into its
// binder: an unwrapped nullable tuple (`var (x, y) = unwrap!(pr)`), a named
// tuple (moved as a whole, as `var w = t` moves it), and a tuple a
// generator yields. Over a tuple yield of pointers, `const *k` binds the
// pointer and builds nothing; `case const v` reads a matched value in
// place. Str has no copy constructor; the counters prove that every object
// built, by value or by move, is destroyed once.

var made:  i32 = 0
var moves: i32 = 0
var drops: i32 = 0

class Str {
    pub var n: i32 = 0

    pub fn Str(self, n: i32) {
        self.n = n
        made   += 1
    }

    @move
    pub fn Str(self, other: Self) {
        self.n  = other.n
        other.n = -1
        moves   += 1
    }

    fn op finally(self) {
        drops += 1
    }
}

class Table {
    pub var k: Str
    pub var v: Str
    pub fn Table(self) { self.k = Str(1); self.v = Str(2) }

    pub fn op in (const self) -> yield (*const Str, *const Str) {
        yield (&self.k, &self.v)
        yield (&self.v, &self.k)
    }
}

fn pair(n: i32) -> (Str, Str)? {
    if n == 0 { return null }
    return (Str(n), Str(n + 1))
}

fn pairs(n: i32) -> yield (Str, Str) {
    for var i = 1; i <= n; i++ {
        yield (Str(i), Str(i * 10))
    }
}

fn reset() {
    made  = 0
    moves = 0
    drops = 0
}

fn balanced() -> bool {
    return drops == made + moves
}

fn unwrapped() -> i32 {
    var pr? = pair(3)
    if pr? {
        var (x, y) = unwrap!(pr)
        return x.n + y.n
    }

    return 0
}

fn named() -> i32 {
    var t = (Str(5), Str(6))
    var (a, b) = t
    return a.n + b.n
}

fn generated() -> i32 {
    var sum = 0
    for (a, b) in pairs(2) {
        sum += a.n + b.n
    }

    return sum
}

fn pointers() -> i32 {
    var t   = Table()
    var sum = 0
    reset()
    for (const *k, const *v) in t {
        sum += k->n * 10 + v->n
    }

    return if (made == 0 && moves == 0) => (sum) else => -1
}

fn matched() -> i32 {
    var pr? = pair(7)
    match pr {
        case null { return 0 }
        case const v { return v.0.n + v.1.n }
    }
}

fn main() -> i32 {
    reset()
    if unwrapped() != 7 || made != 2 || !balanced() { return 1 }

    reset()
    if named() != 11 || made != 2 || !balanced() { return 2 }

    reset()
    if generated() != 33 || made != 4 || !balanced() { return 3 }

    if pointers() != 33 { return 4 }

    reset()
    if matched() != 15 || made != 2 || !balanced() { return 5 }

    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// REQUIRES: clang
// RUN: rm -rf %t.d %t.o2
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.o2
// RUN: %t.o2.exe
