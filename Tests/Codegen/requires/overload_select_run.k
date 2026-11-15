// Overloads selected by their `requires` clauses: a candidate whose clause
// is false for the deduced arguments is not viable, so overloads with
// complementary clauses never tie, and the emitted C++ picks the same one
// (each clause is in its template head). Inline bounds are clause
// conjuncts, so `<T impl I>` beside `requires !(T impl I)` selects too.

interface Shout {
    fn shout(const self) -> i32
}

class Loud {
    pub var n: i32
    pub fn Loud(self, n: i32) {
        self.n = n
    }

    pub fn shout(const self) -> i32 {
        return self.n
    }
}

class Quiet {
    pub var n: i32
    pub fn Quiet(self, n: i32) {
        self.n = n
    }
}

fn <T> pick(const x: T) -> i32 requires T impl Shout {
    return x.shout()
}

fn <T> pick(const x: T) -> i32 requires !(T impl Shout) {
    return 1
}

fn <T impl Shout> bounded(const x: T) -> i32 {
    return 100
}

fn <T> bounded(const x: T) -> i32 requires !(T impl Shout) {
    return 200
}

fn <T> width(const x: T) -> i32 requires sizeof T <= 4 {
    return 10
}

fn <T> width(const x: T) -> i32 requires sizeof T > 4 {
    return 20
}

fn main() -> i32 {
    var l     = Loud(40)
    var q     = Quiet(7)
    var n     = 3
    var *p    = &n
    var total = pick(l) + pick(q) + pick(n) + pick(p) // 40 + 1 + 1 + 1
    total += bounded(l) + bounded(q)               // 100 + 200
    total += width(n) + width(3 as i64) + width(p) // 10 + 20 + 20
    return total - 393                             // 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR: template<class T> requires( {{.*}}Shout_c<T>) signed int pick(T const & x) noexcept;
// IR: template<class T> requires((!( {{.*}}Shout_c<T>))) signed int pick(T const & x) noexcept;

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
