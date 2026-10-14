// --working-dir changes the directory every relative path resolves against,
// and a directory that does not exist is an error rather than being ignored.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo --working-dir=%S --type-check-only working_dir.k
// RUN: { %kairo --working-dir=%S/no_such_dir_here --type-check-only %s 2>&1 || true; } | %FileCheck %s
// RUN: not %kairo --working-dir=%S/no_such_dir_here --type-check-only %s > /dev/null 2>&1
// CHECK: error [U001E]: --working-dir: cannot change to
