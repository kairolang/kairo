// --icf passes --icf=safe to the ELF linker. Above -O0 safe ICF is the
// default (the objects carry -faddrsig); --no-icf turns it off. At -O0, with
// no flag, it is absent.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-linux-musl
// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args | %FileCheck %s --check-prefix=OFF
// OFF-NOT: --icf
// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args --icf | %FileCheck %s --check-prefix=ON
// ON: --icf=safe
// RUN: %kairo %s --target=x86_64-linux-musl -O2 --print-ld-args | %FileCheck %s --check-prefix=O2
// O2: --icf=safe
// RUN: %kairo %s --target=x86_64-linux-musl -O2 --no-icf --print-ld-args | %FileCheck %s --check-prefix=O2OFF
// O2OFF-NOT: --icf
// RUN: %kairo %s --target=x86_64-linux-musl -O2 --print-clang-args | %FileCheck %s --check-prefix=ADDRSIG
// ADDRSIG: -faddrsig
// RUN: %kairo %s --target=aarch64-apple-macosx14.0 -O2 --print-clang-args | %FileCheck %s --check-prefix=NOADDRSIG
// NOADDRSIG-NOT: -faddrsig
