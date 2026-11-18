// At start kals removes the temporaries an interrupted publish left
// (`.clangd.tmp-<pid>-<n>.tmp` in the project root, any `*.tmp-*` / `*.tmp`
// under its `.kairo/clangd` cache) once they are old enough that no writer
// can still own them. Fresh temporaries, other files in the root and
// anything outside those two places stay. Driven by
// inputs/sweep_leftover_temps.py over a scripted LSP session.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: python3 %S/inputs/sweep_leftover_temps.py %lsp_dev %kals | %FileCheck %s
// CHECK: old .clangd temporary removed: yes
// CHECK-NEXT: old cache temporary removed: yes
// CHECK-NEXT: old nested cache temporary removed: yes
// CHECK-NEXT: fresh .clangd temporary kept: yes
// CHECK-NEXT: fresh cache temporary kept: yes
// CHECK-NEXT: old unrelated root file kept: yes
// CHECK-NEXT: old temporary of another root file kept: yes
// CHECK-NEXT: old temporary in a source directory kept: yes
// CHECK-NEXT: clean shutdown: yes
