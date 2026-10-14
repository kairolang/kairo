// --no-default-libs drops the implicit libc++/libc/compiler-rt group from the
// link line. The linker consumes it through LinkerOptions, so the effect is
// only visible in --print-ld-args; the baseline run proves the group exists
// to be removed.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: bundled-sysroot
// RUN: %kairo --target=x86_64-linux-musl --print-ld-args %s | %FileCheck %s --check-prefix=BASE
// BASE: --start-group
// BASE-SAME: -lc++
// RUN: %kairo --target=x86_64-linux-musl --print-ld-args --no-default-libs %s | %FileCheck %s
// CHECK-NOT: --start-group
// CHECK-NOT: -lc++
