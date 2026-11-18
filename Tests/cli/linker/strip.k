// --strip asks the linker to drop all symbols (--strip-all). When --strip-debug
// is given too, the stronger --strip-all wins and no separate --strip-debug is
// passed. Observed through --print-ld-args so no binary is produced.
// REQUIRES: sysroot-x86_64-linux-musl

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args --strip | %FileCheck %s --check-prefix=STRIP
// STRIP: ld.lld
// STRIP-SAME: --strip-all

// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args --strip --strip-debug | %FileCheck %s --check-prefix=BOTH
// BOTH: --strip-all
// BOTH-NOT: --strip-debug
