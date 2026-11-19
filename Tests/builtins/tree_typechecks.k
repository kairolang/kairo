// The two-word library type-checks as a whole, with no error and no
// warning: every file its root imports, compiled as the library's own
// entry and through a user file.

import std
import std::iter

fn main() -> i32 { return 0 }

// --- lit wiring ---
// RUN: %kairo %S/../../Lib/builtin/module.k --type-check-only 2>&1 | %FileCheck %s --allow-empty
// RUN: %kairo %S/../../Lib/std/module.k --type-check-only 2>&1 | %FileCheck %s --allow-empty
// RUN: %kairo %s --type-check-only 2>&1 | %FileCheck %s --allow-empty
// CHECK-NOT: error
// CHECK-NOT: warning
