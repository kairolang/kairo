// --icf passes --icf=safe to the ELF linker; without it the flag is absent.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: bundled-sysroot
// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args | %FileCheck %s --check-prefix=OFF
// OFF-NOT: --icf
// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args --icf | %FileCheck %s --check-prefix=ON
// ON: --icf=safe
