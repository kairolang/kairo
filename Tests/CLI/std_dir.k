// --std-dir names the root `import std::...` resolves under. Pointing it at a
// directory that does not exist must make the std import fail to resolve
// (R011E) rather than silently falling back to some other std.

import std::io

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --std-dir=/nonexistent 2>&1 || true; } | %FileCheck %s
// CHECK: R011E
