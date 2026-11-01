// P127 with VALUE arguments: a call in a generic body that passes the
// enclosing generic's value parameter, or an expression of it, keeps the
// argument in the emitted C++, as a type argument does
// (dependent_explicit_args.k).

fn <eval N: u32> k() -> u32 { return N }
fn <eval N: u32> twice() -> u32 { return k<N>() * 2 }
fn <eval N: u32> plus_one() -> u32 { return k<N + 1>() }
fn <T, eval N: u32> both() -> usize { return sizeof T * (k<N>() as usize) }

class <eval W: u32> Box {
    static fn get() -> u32 { return W }
}
fn <eval N: u32> through_class() -> u32 { return Box<N>::get() }

fn main() -> i32 {
    if twice<21>() != 42 { return 1 }
    if plus_one<9>() != 10 { return 2 }
    if both<i64, 3>() != 24 { return 3 }
    if through_class<7>() != 7 { return 4 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: k<N>()
// CXX: Box<N>::get()

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
