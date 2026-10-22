// -fgc-sections / -fno-gc-sections reach the ELF linker line as
// --gc-sections / --no-gc-sections, so dead-section stripping can be forced
// either way. Checked via --print-ld-args, which links nothing.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-linux-musl
// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args -fgc-sections | %FileCheck %s --check-prefix=GC
// GC: --gc-sections
// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args -fno-gc-sections | %FileCheck %s --check-prefix=NOGC
// NOGC: --no-gc-sections
