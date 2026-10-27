// Strings, vectors, sets and maps are eval-able by design (EVAL.md §2) but
// have no compile-time C++ form yet (the builtin string is not a literal
// type; the collections do not compile at run time either): an eval
// context holding one is SC116E, once, at the outermost value or at the
// parameter -- not a clang error on the emitted text.
eval NAME = "Kairo"
eval fn shout(s: string) -> i32 { return 1 }
eval V: [i32] = [1, 2, 3]
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: eval_literal_gaps.k:6:13: error [SC116E]: a string in an eval context is not yet supported
// CHECK: eval_literal_gaps.k:7:15: error [SC116E]: a string in an eval context is not yet supported
// CHECK: eval_literal_gaps.k:8:17: error [SC116E]: a vector in an eval context is not yet supported
