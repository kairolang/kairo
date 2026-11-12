// An import cycle's re-export fixpoint runs once, right after the group's
// phase I, at any thread count. With more than one thread the
// group's front (I through the typed checks) runs on a pool worker and the
// driver resumes the group for Conformance; the resumed lockstep must not run
// the fixpoint again on every TU, past I: a round that found nothing, yet
// took each overlay Frozen -> Refolding -> Frozen while later groups on
// workers read them. --print-stats counts the rounds per TU: the mutual
// `pub import` pair of Inputs/import_cycle/reexport needs two rounds (the
// second finds the re-exports the first TU missed, then nothing grows), so
// 2 TUs x 2 rounds = 4, as one thread does it. A resumed round would add
// to it, and a debug build stops at the assertion in
// ImportResolution::refold_reexports (a refold of a TU past I).

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: cd %S/Inputs/import_cycle/reexport && %kairo main.k --type-check-only --print-stats --threads=1 2>&1 | %FileCheck %s
// RUN: cd %S/Inputs/import_cycle/reexport && %kairo main.k --type-check-only --print-stats --threads=2 2>&1 | %FileCheck %s
// RUN: cd %S/Inputs/import_cycle/reexport && %kairo main.k --type-check-only --print-stats --threads=16 2>&1 | %FileCheck %s
// RUN: cd %S/Inputs/import_cycle/reexport && %kairo main2.k --type-check-only --print-stats --threads=16 2>&1 | %FileCheck %s
// CHECK: [stats] import-cycle refolds: 4
