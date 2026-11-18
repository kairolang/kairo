// A function whose `return` can come out of an expansion copy (`eval for`,
// a `for` over a pack) keeps the returned value in a slot until the code
// after the expansion returns it. The slot was a default-constructed
// `R slot{}`, so a panicking function (R is its Panic result, which has no
// default constructor) and a function returning a record with none failed
// in clang ("no matching constructor"), whether or not a copy returned. The
// slot is empty storage a returning copy builds the value in.
struct A { var v: i32 }
// No default constructor: built only from an i32.
class Cell {
    var v: i32
    fn Cell(self, v: i32) { self.v = v }
}

fn pick(n: i32) panic(A) -> i32 {
    if n < 0 { panic A { v: n } }
    eval for i in 0..4 {
        if i == n { return i * 10 }
    }
    return -1
}
// The panic leaves from inside a copy as well.
fn pick_in(n: i32) panic(A) -> i32 {
    eval for i in 0..3 {
        if i == n { panic A { v: i } }
    }
    return 7
}
// A `for` over a pack: its copies are lambdas under the same protocol.
fn <...T> nth(n: i32, ...xs: T) panic(A) -> i32 {
    var k = 0
    for x in xs {
        k += 1
        if k == n { return k * 10 }
    }
    return 0
}
// No copy returns: the slot is still declared, and still needs no default.
fn quiet(n: i32) panic(A) -> i32 {
    var s = 0
    eval for i in 0..3 { s += i }
    return s + n
}

fn main() -> i32 {
    var r = 0
    try {
        if pick(2) != 20 { return 1 }
        if pick(9) != -1 { return 2 }
        if pick_in(5) != 7 { return 3 }
        if nth(2, 1, 8, 9) != 20 { return 4 }
        if nth(5, 1, 2) != 0 { return 5 }
        if quiet(1) != 4 { return 8 }
        r = pick_in(1)
        return 6
    } catch e: A { r = e.v }
    if r != 1 { return 7 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}eval_for_return_slot.k
// IR:      ::__kairo_slot<{{.*}}Panic<{{.*}}> __kairo_efv;
// IR:      __kairo_efv.init(
// IR:      return __kairo_efv.take();

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=CC --allow-empty
// CC-NOT: {{error|warning}}
// RUN: %t.exe
