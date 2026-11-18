// --remap-path-prefix is the debug, macro and coverage prefix maps together.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --remap-path-prefix=/src=/s || true; } | %FileCheck %s --check-prefix=MAP
// MAP: -fdebug-prefix-map=/src=/s -fmacro-prefix-map=/src=/s -fcoverage-prefix-map=/src=/s
