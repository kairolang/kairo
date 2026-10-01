// Argument order with named arguments and defaults. Explicit arguments run
// left to right as written, whatever parameter they name; defaults run after
// every explicit argument, in parameter order. `stamp` appends a digit to a
// log, so the log IS the evaluation order.

fn trace() -> *i32 { static n: i32 = 0; return &n }
fn stamp(d: i32) -> i32 { var c = trace(); *c = *c * 10 + d; return d }
fn chk(c: bool) -> i32 { if c { return 1 } return 0 }

fn f(a: i32, b: i32) -> i32 { return a * 10 + b }
fn g(a: i32 = stamp(1), b: i32) -> i32 { return a * 10 + b }
fn h(a: i32 = stamp(5), b: i32 = stamp(6)) -> i32 { return a * 10 + b }

fn main() -> i32 {
    var r1 = f(b: stamp(2), a: stamp(3))   // log 23       r1 = 32
    var r2 = g(b: stamp(4))                // log 2341     the default runs AFTER b, though a precedes b
    var r3 = h()                           // log 234156   two defaults, parameter order
    var n = chk(*trace() == 234156)
    n += chk(r1 == 32)
    n += chk(r2 == 14)
    n += chk(r3 == 56)
    return n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// r1 and r2 bind their explicit arguments (CallLowering's `carg` locals); the
// thunk calls are named in the tree. Anchored on this file's dump, the last.
// RUN: { %kairo %s --print-lowered 2>&1 || true; } | %FileCheck %s --check-prefix=LOW
// LOW: SEMA fid {{[0-9]+}}: {{.*}}order.k
// LOW: __kairo_carg0
// LOW: __kairo_default_g_a
// LOW: __kairo_default_h_a
// LOW: __kairo_default_h_b
// RUN: { %kairo %s --print-lowered 2>&1 || true; } | %FileCheck %s --check-prefix=NONAMED
// NONAMED: SEMA fid {{[0-9]+}}: {{.*}}order.k
// NONAMED-NOT: NamedArgExpr

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 4
