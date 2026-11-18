// A failing call inside an `eval for` reaches a
// `try` around the loop. Each copy is a C++ lambda, which no goto leaves,
// so the site sets the `try`'s flag and stops the copy's fold; after each
// expansion it leaves, a jump on the flag goes on, the outermost one's the
// goto to the dispatch. Covered: one copy level, two with a runtime loop
// inside, what an inner `try` in a copy does not catch going on to an outer
// one, a `panic` statement beside `continue` / `break`, and a `for` over a
// pack, whose copies are lambdas as well.
struct A { var v: i32 }
struct B { var v: i32 }
fn ab(n: i32) panic(A, B) -> i32 {
    if n == 1 { panic A { v: 1 } }
    if n == 2 { panic B { v: 2 } }
    return n
}
// One copy level between the call and its `try`.
fn one(n: i32) -> i32 {
    var sum = 0
    try {
        eval for i in 0..4 { sum += ab(n + i) }
    } catch e: A { return 100 + sum } catch e: B { return 200 + sum }
    return sum
}
// Two levels, and a runtime loop inside the inner copy.
fn two(n: i32) -> i32 {
    var sum = 0
    try {
        eval for i in 0..3 {
            eval for j in 0..3 {
                var k = 0
                while k < 2 { k += 1  sum += ab(n + i + j) }
            }
        }
    } catch e: A { return 1000 + sum } catch e { return 2000 + sum }
    return sum
}
// A `try` inside a copy catches B; what it leaves (A) goes on to the outer
// `try`, outside the copy, from the inner one's dispatch.
fn three(n: i32) -> i32 {
    var sum = 0
    try {
        eval for i in 0..3 {
            try {
                eval for j in 0..3 { sum += ab(n + (i * 3) + j) }
            } catch e: B { sum += 50 }
        }
    } catch e: A { return 700 + sum }
    return sum
}
// A `panic` statement in a copy, and `continue` / `break` beside it.
fn four(n: i32) -> i32 {
    var hits = 0
    try {
        eval for i in 0..5 {
            if i == 0 { continue }
            if i == n { panic A { v: i } }
            hits += 1
            if i == 3 { break }
        }
    } catch e: A { return 10 * e.v + hits }
    return hits
}
// A `for` over a pack is a lambda per element too.
fn <...T> five(...xs: T) -> i32 {
    var s = 0
    try { for x in xs { s += ab(2) } } catch e: B { return 300 + s } catch e { return 400 + s }
    return s
}
fn <...T> six(...xs: T) -> i32 {
    var s = 0
    try { for x in xs { s += ab(5) } } catch e: B { return 300 + s } catch e { return 400 + s }
    return s
}
fn main() -> i32 {
    if one(0) != 100 { return 1 }       // ab(0) = 0, then ab(1) is A
    if one(5) != 26 { return 2 }        // 5 + 6 + 7 + 8
    if one(-1) != 99 { return 3 }       // -1 + 0, then ab(1) is A
    if two(-1) != 998 { return 4 }      // -1 -1 0 0, then ab(1) is A
    if two(10) != 216 { return 5 }      // twice each of 10 + i + j
    if three(-1) != 699 { return 6 }    // i0: -1 0, then ab(1) is A
    if three(2) != 95 { return 7 }      // i0: ab(2) is B, + 50; i1: 5 6 7; i2: 8 9 10
    if three(-7) != 672 { return 8 }    // -7 .. 0, then ab(1) is A
    if four(2) != 21 { return 9 }       // i1 counted, then panic at i2
    if four(9) != 3 { return 10 }       // i1, i2, i3, break
    if five(1, 2) != 300 { return 11 }  // ab(2) is B at the first element
    if six(1, 2, 3) != 15 { return 12 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}eval_for_try.k
// IR:      bool __kairo_efj{{[0-9]+}} = false;
// IR:      (__kairo_efj{{[0-9]+}} = true);
// IR-NEXT: return false;
// IR:      if(__kairo_efj{{[0-9]+}}) {
// IR-NEXT:     goto __kairo_catch{{[0-9]+}};

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
