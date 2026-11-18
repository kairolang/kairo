fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// The f256 / f512 classes and the softfloat engine under them are not in the
// builtin root's re-exports: a program that never names the types
// does not reach them. wide_float_user.k is the other half.
// RUN: { %kairo %s --type-check-only --print-imports 2>&1 || true; } | %FileCheck %s
// CHECK: -- imports:
// CHECK-NOT: f256_t
// CHECK-NOT: f512_t
// CHECK-NOT: softfloat
