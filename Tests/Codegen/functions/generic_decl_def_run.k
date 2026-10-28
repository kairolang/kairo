// A generic function declared and then defined is ONE function: its two
// declarations name their generic parameters independently, so the
// signatures are compared up to the parameters' names (alpha-equivalence).
// Before, every call was SC064E "call to 'g' is ambiguous", candidates the
// declaration and the definition. Covered: the ticket's shape (a bounded
// parameter, a caller between the two), renamed parameters, a return type
// over the parameter, a value parameter, two type parameters, and a
// generic member function declared in its class and defined out of line.

interface Graph { fn first(const self) -> i32 }
class R {
    fn R(self) { }
    fn first(const self) -> i32 { return 3 }
}

fn <T impl Graph> g(x: T) -> i32
fn <T impl Graph> h(x: T) -> i32 { return g(x) }
fn <T impl Graph> g(x: T) -> i32 { return x.first() }

fn <A> ident(v: A) -> A
fn <B> ident(v: B) -> B { return v }

fn <eval N: usize> len(const a: [i32; N]) -> usize
fn <eval M: usize> len(const a: [i32; M]) -> usize { return M }

fn <K, V> pick(k: K, v: V) -> V
fn <P, Q> pick(k: P, v: Q) -> Q { return v }

class Box {
    pub var n: i32
    fn Box(self, n: i32) { self.n = n }
    fn <U> keep(self, x: U) -> U
}
fn <W> Box::keep(self, x: W) -> W { return x }

fn main() -> i32 {
    var c: i32 = g(R())                 // 3
    var d: i32 = h(R())                 // 3
    var e: i32 = ident(4)               // 4
    var arr: [i32; 5] = [1, 2, 3, 4, 5]
    var f = len(arr) as i32             // 5
    var p = pick(true, 6)               // 6
    var b = Box(2)
    var s = b.keep(12) + b.n            // 14
    return c + d + e + f + p + s        // 35
}

// --- lit wiring ---

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error [
// DIAG-NOT: warning [
// END-GENERATED-CHECKS(DIAG)

// BEGIN-GENERATED-CHECKS(EXEC) mode=run -- regenerate with Tests/gen_checks.py, do not hand-edit
// REQUIRES: clang
// RUN: rm -rf %t.exec.d
// RUN: %kairo %s -o %t.exec.exe --cache-dir %t.exec.d
// RUN: %t.exec.exe > %t.exec.out; test $? -eq 35
// RUN: test ! -s %t.exec.out
// END-GENERATED-CHECKS(EXEC)
