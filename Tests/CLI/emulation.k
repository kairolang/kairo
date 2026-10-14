// --emulation is handed to ld as -m, replacing the target's default emulation;
// the cc1 triple is untouched. Pinned on musl so the link line does not
// depend on which crt files the host has.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: bundled-sysroot
// RUN: %kairo %s --target=x86_64-linux-musl --emulation=elf_i386 --print-ld-args | %FileCheck %s
// CHECK:      ld.lld
// CHECK-SAME: -m elf_i386
// CHECK-NOT:  -m elf_x86_64
