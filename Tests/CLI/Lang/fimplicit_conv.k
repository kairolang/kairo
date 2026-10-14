// -fno-implicit-conv turns off implicit conversions in Sema. The builtin
// fmt code relies on them, so with the flag on it fails to type-check.
// The test avoids pinning builtin line numbers; it only needs the error code.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --type-check-only -fimplicit-conv
// RUN: { %kairo %s --type-check-only -fno-implicit-conv 2>&1 || true; } | %FileCheck %s
// CHECK: error [SC063E]: no matching overload for call to 'int64_'
