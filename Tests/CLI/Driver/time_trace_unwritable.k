// --time-trace to a path that cannot be written is an error and a nonzero
// exit. It used to print a note and exit 0 with no trace file.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --time-trace=/proc/no_such_dir/t.json 2>&1 || true; } | %FileCheck %s
// RUN: not %kairo %s --type-check-only --time-trace=/proc/no_such_dir/t.json > /dev/null 2>&1
// CHECK: error [U001E]: cannot write time trace
