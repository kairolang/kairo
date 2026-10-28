// [over.ics.rank]/3.2.3 as C++ has it: an rvalue argument -- a literal, a
// by-value call result, an xvalue (a `T&&` result, a MOVE value Kairo
// passes by moving) or a converted temporary -- binds `T&&` over `const
// T&`; an lvalue only has `const T&`. And 3.2.6: a non-const lvalue prefers
// `T&` to `const T&`. Every call here is one C++ resolves the same way
// (refs.h), and each check returns its own code on a wrong pick.

ffi "c++" import "refs.h"

fn main() -> i32 {
    var x: i32 = 1
    const cx: i32 = 2
    if bind(1) != 2 { return 10; }              // literal: prvalue
    if bind(x) != 1 { return 11; }              // lvalue
    if bind(cx) != 1 { return 12; }             // const lvalue
    if bind(g()) != 2 { return 13; }            // by-value result
    if bind(gl()) != 1 { return 14; }           // `int&` result: lvalue
    if bind(gx()) != 2 { return 15; }           // `int&&` result: xvalue
    if bind(gcl()) != 1 { return 16; }          // `const int&` result
    if bind(x + 1) != 2 { return 17; }          // arithmetic: prvalue

    if lbind(x) != 3 { return 20; }             // non-const lvalue: T&
    if lbind(cx) != 4 { return 21; }            // const lvalue: const T&
    if lbind(1) != 4 { return 22; }             // rvalue: const T& only
    if lbind(gl()) != 3 { return 23; }

    if wide(x) != 2 { return 30; }              // i32 lvalue -> long long temporary
    if wide(4) != 2 { return 31; }

    var m = Mv()
    if sink(m) != 2 { return 40; }             // a MOVE lvalue is passed by moving
    if sink(Mv()) != 2 { return 41; }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
