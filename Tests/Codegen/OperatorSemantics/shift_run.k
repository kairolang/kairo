// OperatorSemantics: a shift takes its count modulo the register width
// (32 below 32 bits, else the width) on every target, at every level, and
// in constant evaluation (SHIFT spec §1, §8.1, §8.2, §8.4). Inputs/
// shift_run.py generates the cases, builds them for x86_64, aarch64,
// riscv64, armv7a, thumbv7m and thumbv6m at -O0 -O1 -O2 -Oz, runs each
// (QEMU user mode off the host; the M-profile objects inside an armv7
// program), and requires every run to print its own reference table.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang, qemu-arm, qemu-aarch64, qemu-riscv64
// REQUIRES: sysroot-aarch64-linux-musl, sysroot-riscv64-linux-musl, sysroot-armv7-linux-musl
// RUN: rm -rf %t.d
// RUN: python3 %S/Inputs/shift_run.py %t.d %qemu_arm %qemu_aarch64 %qemu_riscv64 -- %kairo | %FileCheck %s
// CHECK: shift_run: OK (24 builds
