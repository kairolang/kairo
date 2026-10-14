// --mfeatures is split on commas into one -target-feature pair each, in order. An
// item with no sign means enable.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --mfeatures=+avx2,-sse4.1,bmi2 || true; } | %FileCheck %s --check-prefix=FEAT
// FEAT: -target-feature +avx2 -target-feature -sse4.1 -target-feature +bmi2
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEFN
// DEFN-NOT: +avx2
