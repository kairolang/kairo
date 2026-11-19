// A `.k` file with a non-ASCII name, included from a C++ source, gets the
// clangd bridge's `.clangd` like an ASCII one. Driven by
// inputs/nonascii_k_name.py over a scripted LSP session.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: python3 %S/inputs/nonascii_k_name.py %lsp_dev %kals | %FileCheck %s
// CHECK: .clangd written: yes
// CHECK-NEXT: source in .clangd: yes
// CHECK-NEXT: clean shutdown: yes
