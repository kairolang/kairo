// --debug-prefix-map is only the debug-info prefix map.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --debug-prefix-map=/src=/s || true; } | %FileCheck %s --check-prefix=MAP
// MAP: -fdebug-prefix-map=/src=/s
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --debug-prefix-map=/src=/s || true; } | %FileCheck %s --check-prefix=MAPN
// MAPN-NOT: -fmacro-prefix-map
