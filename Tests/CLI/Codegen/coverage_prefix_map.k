// --coverage-prefix-map is only the coverage prefix map.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --coverage-prefix-map=/src=/s || true; } | %FileCheck %s --check-prefix=MAP
// MAP: -fcoverage-prefix-map=/src=/s
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --coverage-prefix-map=/src=/s || true; } | %FileCheck %s --check-prefix=MAPN
// MAPN-NOT: -fdebug-prefix-map
