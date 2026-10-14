// --print-target-info prints the resolved target description and exits
// before any compile. Pinned for a non-host triple so the output proves
// --target is honoured and not just the host being echoed back.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-target-info --target=aarch64-linux-gnu | %FileCheck %s
// CHECK: Triple:          aarch64-unknown-linux-gnu
// CHECK: Architecture:    aarch64
// CHECK: Environment:     gnu
// CHECK: Pointer width:   64-bit
// CHECK: Endianness:      little
// CHECK: Object format:   ELF
