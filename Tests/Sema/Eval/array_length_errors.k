// An array length is type identity, so Sema folds it (EVAL.md 0.1): it must
// be eval-able. A `const` name is not (EVAL.md 3: a fix-it rewrites its
// `const` to `eval`), a variable is not, a call of an eval fn is C++'s to
// compute (EVAL.md 0.2, line 14: accepted), and a negative one has no array.
const C = 3
eval E = 2
eval fn g() -> i32 { return 2 }
module m { pub eval K = 2 }

fn main() -> i32 {
    var n = 3
    var a: [i32; C] = [1, 2, 3]
    var b: [i32; n]
    var c: [i32; g()]
    var d: [i32; E - 5]
    var ok1: [i32; (E * 2) + m::K]              // 6: a qualified eval name folds
    var ok2: [i32; E << 1]
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: array_length_errors.k:12:18: error [SC001E]: an array length must be an 'eval' constant; 'C' is 'const', which is not evaluated at compile time
// CHECK-NEXT: fix-it:{{.*}}:{5:1-5:6}:"eval"
// CHECK-NEXT: array_length_errors.k:5:7: note [SC001N]: 'C' is declared 'const' here
// CHECK: array_length_errors.k:13:18: error [SC001E]: an array length must be an 'eval' constant; 'n' is a variable
// CHECK-NEXT: array_length_errors.k:11:9: note [SC001N]: 'n' is declared here
// CHECK: array_length_errors.k:15:18: error [SC001E]: an array length must be a non-negative constant that fits 64 bits; this one is -3, which is negative
