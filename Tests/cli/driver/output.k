// -o names an output file; a directory is refused and the user is pointed at
// --cache-dir, rather than a confusing link failure later.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s -o %S 2>&1 || true; } | %FileCheck %s
// CHECK: -o {{.*}} is a directory; -o names the output file
