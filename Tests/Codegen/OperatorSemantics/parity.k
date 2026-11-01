// OperatorSemantics: the wrap and sequencing forms compile to the plain C++
// operator's instructions wherever that one has no UB (Inputs/parity.py:
// x86_64 and aarch64, -O1..-O3; the shift forms also on riscv64, thumbv6m,
// thumbv7m, thumbv8.1m.main and armv7a at -O1 -O2 -Os -Oz, SHIFT spec §8.3;
// the allowlists name the semantic differences, a shift's with its exact
// measured delta). Re-run on a clang upgrade.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: python3 %S/Inputs/parity.py %bundled_clang %S/Inputs/parity.cpp | %FileCheck %s
// CHECK: parity: OK
