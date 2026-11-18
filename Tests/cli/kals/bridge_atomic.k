// kals' clangd bridge publishes `.clangd` and each `.k` file's header whole,
// through a temporary in the same directory and a rename: clangd, which
// reloads its config and re-reads a header on every change, never reads an
// empty or partly written file, and no temporary is left behind. Driven by
// inputs/bridge_atomic.py over a scripted LSP session.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: python3 %S/inputs/bridge_atomic.py %lsp_dev %kals | %FileCheck %s
// CHECK: .clangd rewritten: yes
// CHECK-NEXT: old .clangd link kept: yes
// CHECK-NEXT: header rewritten: yes
// CHECK-NEXT: old header link kept: yes
// CHECK-NEXT: temporaries left: none
// CHECK-NEXT: clean shutdown: yes
