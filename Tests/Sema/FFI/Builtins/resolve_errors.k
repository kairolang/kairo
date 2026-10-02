// The N half of the builtin errors: one diagnostic per marked line, nothing
// else. Split from typing_errors.k because an N error stops the TU before X,
// so the two halves cannot share a file.

fn main() -> i32 {
    var r: i32 = 0;
    var a: i32 = 1;
    var b: i32 = 2;

    __builtin_add_overflow(a, b, r);              // R057E: clang type-checks it per call.
    printf("x");                                  // R020E: library builtin, no header -> plain miss.
    __builtin_memcpy(&r, &a, 4);                  // binds: the `__builtin_` form of a library builtin.
    return 0;
}

// --- lit wiring (below the code: nothing above shifts a line) -------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:     resolve_errors.k:10:5: error [R057E]: '__builtin_add_overflow' is type-checked by clang per call; Kairo cannot call it yet
// DIAG-NEXT: resolve_errors.k:11:5: error [R020E]: use of undeclared identifier 'printf'
// DIAG-NOT: error
