// -fno-unsafe is the feature spelling of --no-unsafe: the same `unsafe { }`
// block is rejected, and -funsafe (or neither) accepts it.

fn f() -> i32 {
    unsafe { }
    return 0
}

fn main() -> i32 { return f() }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo --type-check-only -funsafe %s
// RUN: { %kairo --type-check-only -fno-unsafe %s 2>&1 || true; } | %FileCheck %s
// CHECK: fno_unsafe.k:5:{{[0-9]+}}: error [SC001E]: an unsafe block is not allowed when unsafe code is disabled
