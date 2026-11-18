// --Wall forwards -Wall to the cc1 invocation; it is absent by default.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-clang-args --Wall | %FileCheck %s --check-prefix=WALL
// WALL: -Wall
// RUN: %kairo %s --print-clang-args | %FileCheck %s --check-prefix=NOWALL
// NOWALL-NOT: -Wall
