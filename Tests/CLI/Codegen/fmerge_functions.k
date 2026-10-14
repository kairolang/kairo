// -fmerge-functions is forwarded; the default line has none.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl -fmerge-functions || true; } | %FileCheck %s --check-prefix=ON
// ON: -fmerge-functions
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEFN
// DEFN-NOT: -fmerge-functions
