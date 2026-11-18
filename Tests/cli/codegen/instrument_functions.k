// --instrument-functions is -finstrument-functions.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --instrument-functions || true; } | %FileCheck %s --check-prefix=ON
// ON: -finstrument-functions
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEFN
// DEFN-NOT: -finstrument-functions
