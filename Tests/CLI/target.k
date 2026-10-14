// --target selects the ABI as well as the triple: an aarch64 compile carries
// the AAPCS ABI in its cc1 line. print_clang_args.k pins the -triple word;
// this pins the target-derived ABI, which comes from the target machinery
// rather than from the flag text.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: bundled-sysroot
// RUN: %kairo %s --print-clang-args --target=aarch64-linux-gnu | %FileCheck %s
// CHECK:      clang -cc1 -triple aarch64-linux-gnu
// CHECK-SAME: -target-abi aapcs
