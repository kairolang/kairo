fn half(x: f256) -> f256 {
    return x / 2.0
}

fn main() -> i32 {
    var y = 1.5f512
    var c = F256::from_bits(0)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// A file that names f256 (the keyword) or f512 (here only a literal's
// suffix) imports their class files implicitly (P723): the engine is in the
// graph, and the class's name binds with no import written, as it did when
// the builtin root re-exported it.
// RUN: { %kairo %s --type-check-only --print-imports 2>&1 || true; } | %FileCheck %s
// CHECK-DAG: num::softfloat
// CHECK-DAG: num::f256_t
// CHECK-NOT: error [
// RUN: %kairo %s --type-check-only
