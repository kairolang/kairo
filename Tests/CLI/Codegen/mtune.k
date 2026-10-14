// --mtune becomes -tune-cpu after the driver probe's own (generic) one, so it wins
// as the last -tune-cpu.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --mtune=znver3 || true; } | %FileCheck %s --check-prefix=TUNE
// TUNE: -tune-cpu generic
// TUNE: -tune-cpu znver3
