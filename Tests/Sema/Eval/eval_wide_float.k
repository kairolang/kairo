eval X: f256 = 1.5
eval Y: f512 = f512::MAX

eval fn half(x: f256) -> f256 {
    return x
}

fn main() -> i32 {
    var a: f256 = 1.5 // a run-time f256 is fine
    eval if 1.0f256 < 2.0 {
        a = 2.0
    }

    return 0
}

// --- lit wiring -----------------------------------------------------------
// f256 / f512 are library classes whose every operation is a run-time call
// so an eval context holding one is SC116E at the Kairo source, not
// clang's "constexpr variable cannot have non-literal type" on the emitted
// text.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: eval_wide_float.k:1:16: error [SC116E]: an 'f256' value in an eval context is not yet supported
// CHECK: eval_wide_float.k:2:16: error [SC116E]: an 'f512' value in an eval context is not yet supported
// CHECK: eval_wide_float.k:4:14: error [SC116E]: an 'f256' value in an eval context is not yet supported
// CHECK: eval_wide_float.k:4:26: error [SC116E]: an 'f256' value in an eval context is not yet supported
// CHECK: eval_wide_float.k:5:12: error [SC116E]: an 'f256' value in an eval context is not yet supported
// CHECK-NOT: eval_wide_float.k:9:
// CHECK: eval_wide_float.k:10:13: error [SC192E]: the condition of an 'eval if' must be evaluable at compile time; this is a run-time value
