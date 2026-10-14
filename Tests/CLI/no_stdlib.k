// --no-stdlib leaves std out of the import roots, so `import std::io` must
// fail to resolve instead of silently finding the bundled library. Without
// the flag the same import resolves.

import std::io

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo --type-check-only %s
// RUN: { %kairo --type-check-only --no-stdlib %s 2>&1 || true; } | %FileCheck %s
// CHECK: error [R011E]: failed to resolve import path 'std::io'
