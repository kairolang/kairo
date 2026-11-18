// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 4
//
// `&x` marking a C++ `T&` argument is the lvalue `x` to clang's deduction,
// as in the emitted call: `T` is the object's type, so a constraint that
// rejects pointers keeps the candidate.

ffi "c++" import "inputs/deduce.h"

fn main() -> i32 {
    var n: i32 = 3
    return touch(&n)
}

// --- lit wiring ---
// CHECK-NOT: error
