// --mcpu forwards a target CPU to clang (=, -mcpu= and space spellings).
// The default -target-cpu stays and the user's comes after it, so the last
// one wins. An unknown CPU is rejected.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-clang-args --mcpu=znver3 | %FileCheck %s --check-prefix=EQ
// EQ: -target-cpu x86-64
// EQ: -target-cpu znver3

// RUN: %kairo %s --print-clang-args --mcpu znver3 | %FileCheck %s --check-prefix=SP
// SP: -target-cpu znver3

// RUN: { %kairo %s --type-check-only --mcpu=bogus 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: P006E{{.*}}bogus
