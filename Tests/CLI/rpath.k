// --rpath is repeatable and accepts both spellings; on an ELF target each
// becomes an `-rpath` pair on the linker line, in command-line order.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: bundled-sysroot
// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args --rpath /r1 --rpath=/r2 | %FileCheck %s
// CHECK: -rpath /r1 -rpath /r2
