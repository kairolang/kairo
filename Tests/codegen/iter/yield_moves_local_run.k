// `yield x` of a MOVE local or by-value parameter moves it: the loop's
// binder takes the value with exactly one move per yielded value (`mark`
// holds the move count at each yield), nothing is copied, the generator never reads a moved-from object (a moved-from
// Str has n == -1, which the generator would add to `seen`), and every
// object built is destroyed.

var made:   i32 = 0
var moves:  i32 = 0
var copies: i32 = 0
var drops:  i32 = 0
var seen:   i32 = 0
var mark:   i32 = 0
var extra:  i32 = 0

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

    pub fn copy(const self) -> Str {
        copies += 1
        return Str(self.n)
    }

    fn op finally(self) {
        drops += 1
    }
}

/// A local reassigned before each yield.
fn local(n: i32) -> yield Str {
    var s = Str(0)
    for var i = 1; i <= n; i++ {
        s = Str(i)
        if s.n < 0 { seen += 100 }
        mark = moves
        yield s
    }
}

/// A local declared in the loop body, read before the yield.
fn fresh_local(n: i32) -> yield Str {
    for var i = 1; i <= n; i++ {
        var s = Str(i * 10)
        seen += s.n
        mark = moves
        yield s
    }
}

/// A by-value parameter, yielded once.
fn param(s: Str) -> yield Str {
    mark = moves
    yield s
}

fn reset() {
    made   = 0
    moves  = 0
    copies = 0
    drops  = 0
    seen   = 0
    extra  = 0
}

fn main() -> i32 {
    reset()
    var sum = 0
    for x in local(3) {
        sum += x.n
        if moves != mark + 1 { extra += 1 }
    }

    if sum != 6 || seen != 0 || copies != 0 { return 1 }
    if made != 4 || extra != 0 { return 2 }
    if drops != made + moves { return 3 }

    reset()
    sum = 0
    for x in fresh_local(2) {
        sum += x.n
        if moves != mark + 1 { extra += 1 }
    }

    if sum != 30 || seen != 30 || made != 2 || moves != 2 || copies != 0 || extra != 0 { return 4 }
    if drops != made + moves { return 5 }

    reset()
    sum = 0
    for x in param(Str(7)) {
        sum += x.n
        if moves != mark + 1 { extra += 1 }
    }

    if sum != 7 || copies != 0 || extra != 0 { return 6 }
    if drops != made + moves { return 7 }

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
