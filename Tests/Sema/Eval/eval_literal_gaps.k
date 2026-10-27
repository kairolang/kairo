// Vectors, sets and maps are eval-able by design (EVAL.md §2) but have no
// compile-time C++ form yet (2b: they do not compile at run time either),
// and an f-string formats into a heap buffer: an eval context holding one
// is SC116E, once, at the outermost value or at the parameter -- not a
// clang error on the emitted text. A plain string literal has a
// compile-time form (2a; Tests/Codegen/eval/eval_strings.k) and is no error.
eval NAME = "Kairo"
eval fn shout(s: string) -> i32 { return 1 }
eval V: [i32] = [1, 2, 3]
eval fn label(n: i32) -> string { return f"n={n}" }
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: eval_literal_gaps.k:9:17: error [SC116E]: a vector in an eval context is not yet supported
// CHECK: eval_literal_gaps.k:10:43: error [SC116E]: an f-string in an eval context is not yet supported
