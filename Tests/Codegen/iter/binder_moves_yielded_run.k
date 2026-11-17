// `for x in g` over a generator (a call of a `-> yield T` function, a
// `Yield<T>` value) that yields a MOVE type moves each yielded value into
// the binder: the generator gives the value up when it is resumed, and a
// MOVE record has no copy to make. Str has no copy constructor, so every
// transfer below is a move, and `moves` counts them: exactly one per
// iteration, from the generator's value into the binder. `for *x in g` binds
// the value's address and moves nothing.

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

class Sink {
    pub var total: i32 = 0
    pub var held:  i32 = 0

    pub fn Sink(self) { }

    pub fn take(self, s: Str) {
        self.total += s.n
        self.held  += 1
    }
}

fn fresh(n: i32) -> yield Str {
    for var i = 1; i <= n; i++ {
        yield Str(i)
    }
}

fn pairs(n: i32) -> yield (Str, i32) {
    for var i = 1; i <= n; i++ {
        yield (Str(i), i * 10)
    }
}

fn <T> count(g: Yield<T>) -> i32 {
    var n = 0
    for x in g {
        n += 1
    }

    return n
}

fn reset() {
    made  = 0
    moves = 0
    drops = 0
}

/// Every object built, by value or by move, was destroyed.
fn balanced() -> bool {
    return drops == made + moves
}

fn main() -> i32 {
    // A generator function's values.
    reset()
    var sum = 0
    for piece in fresh(3) {
        sum += piece.n
    }

    if sum != 6 || made != 3 || moves != 3 || !balanced() { return 1 }

    // The binder is the loop's own value: it moves onward.
    reset()
    var sink = Sink()
    for piece in fresh(3) {
        sink.take(piece)
    }

    if sink.total != 6 || sink.held != 3 || made != 3 || moves != 6 || !balanced() { return 2 }

    // A generator held in a variable and driven by the loop.
    reset()
    var g = fresh(2)
    sum = 0
    for piece in g {
        sum += piece.n
    }

    if sum != 3 || made != 2 || moves != 2 { return 3 }

    // `*x` is the address of the generator's value: nothing moves.
    reset()
    sum = 0
    for *p in fresh(3) {
        sum += p->n
    }

    if sum != 6 || made != 3 || moves != 0 || !balanced() { return 4 }

    // A yielded tuple, destructured: each MOVE element moves into its binder.
    reset()
    sum = 0
    for (s, k) in pairs(2) {
        sum += s.n + k
    }

    if sum != 33 || made != 2 || !balanced() { return 5 }

    // One generic body serves a MOVE and a COPY instance.
    reset()
    if count(fresh(4)) != 4 || made != 4 || moves != 4 { return 6 }

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
