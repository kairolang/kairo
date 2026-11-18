// --no-entry drops the startup objects (crt1/crtn) from the link line, for
// outputs with no program entry point. Unlike --no-crt it sets no `-e`.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-linux-musl
// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args | %FileCheck %s --check-prefix=BASE
// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args --no-entry | %FileCheck %s --check-prefix=NOENTRY
// BASE: crt1.o
// NOENTRY-NOT: crt1.o
// NOENTRY-NOT: crtn.o
// NOENTRY-NOT: -e main
