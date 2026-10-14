// --pic-level=N sets the PIC relocation model at that level on any target.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --pic-level=1 || true; } | %FileCheck %s --check-prefix=ONE
// ONE: -mrelocation-model pic -pic-level 1
// RUN: { %kairo %s --print-clang-args --target=aarch64-linux-gnu --pic-level=2 || true; } | %FileCheck %s --check-prefix=TWO
// TWO: -mrelocation-model pic -pic-level 2
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEFN
// DEFN-NOT: -pic-level
