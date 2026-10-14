// --no-modules rejects an import of a Kairo module in the program's own
// files. Without the flag the file is accepted.

import std

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo --type-check-only %s
// RUN: { %kairo --type-check-only --no-modules %s 2>&1 || true; } | %FileCheck %s
// CHECK: no_modules.k:4:{{[0-9]+}}: error [SC001E]: an import is not allowed when the module system is disabled
