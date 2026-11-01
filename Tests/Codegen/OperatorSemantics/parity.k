// OperatorSemantics: the wrap and sequencing forms compile to the plain C++
// operator's instructions wherever that one has no UB (Inputs/parity.py:
// x86_64 and aarch64, -O1..-O3; the allowlist names the semantic
// differences). Re-run on a clang upgrade.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: python3 %S/Inputs/parity.py %bundled_clang %S/Inputs/parity.cpp | %FileCheck %s
// CHECK: parity: OK
