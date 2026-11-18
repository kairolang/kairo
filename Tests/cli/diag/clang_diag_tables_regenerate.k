// Scripts/gen_clang_diag_table.py, run over the manifest's active groups,
// reproduces the checked-in Clang diagnostic table and lookup byte for byte
// and leaves the manifest unchanged.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: python3 %S/inputs/regen_clang_diag_lookup.py %S/../../.. | %FileCheck %s --implicit-check-not=DIFFERS
// CHECK: lookup identical
// CHECK: diag-table identical
// CHECK: manifest identical
