// --time-trace to a path that cannot be written is an error and a nonzero
// exit, not a note with exit 0 and no trace file.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.notadir && echo > %t.notadir
// RUN: { %kairo %s --type-check-only --time-trace=%t.notadir/no_such_dir/t.json 2>&1 || true; } | %FileCheck %s
// RUN: not %kairo %s --type-check-only --time-trace=%t.notadir/no_such_dir/t.json > /dev/null 2>&1
// CHECK: error [U023E]: cannot write time trace
