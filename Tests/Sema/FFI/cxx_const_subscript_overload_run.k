// An imported class's `operator[]` is chosen by the receiver's const,
// as C++ chooses it. The const overload returns a P921Tag, the non-const one
// an `int&`: Sema does not pick the non-const one for every receiver, which would
// type `const c` subscripted as an i32 and the P921Tag initializers as SC028E.
ffi "c++" import "Inputs/p921_const_subscript.h"

fn read_const(const p: P921Pair) -> i32 {
    var t: P921Tag = p[0]
    return t.v
}

fn main() -> i32 {
    var m = P921Pair()
    const c = P921Pair()
    var t: P921Tag = c[0]
    // 1 (const, through a parameter) + 1 (const local) + 10 (mutable)
    return read_const(m) + t.v + m[0]
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 12
