// A tuple is its arity's record: built as an aggregate, indexed as a field,
// assigned through, destructured once out of an lvalue and moved out of a
// temporary, and bound per element by a ranged for. Cp counts copies and Mv
// moves so an extra transfer anywhere on the way shows in the exit code.

var copies: i32 = 0
var moves: i32 = 0

class Cp {
    pub var id: i32
    pub fn Cp(self, id: i32) { self.id = id; }
    @copy fn Cp(self, const other: Self) { self.id = other.id; copies = copies + 1; }
}

class Mv {
    pub var id: i32
    pub fn Mv(self, id: i32) { self.id = id; }
    @move fn Mv(self, other: Self) { self.id = other.id; moves = moves + 1; }
}

fn pair() -> (i32, f64) { return (3, 2.5) }
fn swap(p: (i32, i32)) -> (i32, i32) { return (p.1, p.0) }
fn mk() -> (Mv, i32) { return (Mv(7), 1) }

fn index() -> i32 {
    var t = (1, 2, 3)
    t.0 = 10
    var p = &t
    return t.0 + t.1 + p->2                    // 15
}

fn nested() -> i32 {
    var t = ((1, 2), 3)
    return t.0.1 + t.1                         // 5
}

fn destructure_lvalue() -> i32 {
    var t = (Cp(4), 5)
    copies = 0
    var (c, n) = t                             // one copy, out of t
    return (c.id + n) * 10 + copies            // 91
}

fn destructure_prvalue() -> i32 {
    moves = 0
    var (m, n) = mk()                          // moved out of the temporary
    return (m.id + n) * 10 + moves             // 81
}

fn discard() -> i32 {
    var (a, _, c) = (1, 2, 3)
    return a + c                               // 4
}

fn matched(t: (bool, i32)) -> i32 = match t {
    case (true, var n)  => n
    case (false, 0)     => -1
    case (false, var n) => -n
}

fn <T> first(p: (T, T)) -> T { return p.0 }   // deduced through the tuple's arguments

fn looped() -> i32 {
    var ps: [(i32, i32); 3] = [(1, 10), (2, 20), (3, 30)]
    var s = 0
    for (a, b) in ps { s += a * b }           // 140
    for (*q, _) in ps { s += *q }              // 146
    return s
}

fn main() -> i32 {
    var r = index() + nested()                 // 20
    var q = swap((1, 2))
    r += q.0 * 10 + q.1                        // 41
    r += pair().0                              // 44
    r += destructure_lvalue()                  // 135
    r += destructure_prvalue()                 // 216
    r += discard()                             // 220
    r += matched((true, 5)) + matched((false, 0)) + matched((false, 3))   // 221
    r += looped() - 146                        // 221
    r += first((1, 2)) - 1                     // 221
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -c --cache-dir %t.d/k
// RUN: %clangxx %t.d/k/*.o %t.d/k/builtin/*.o %t.d/k/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 221
