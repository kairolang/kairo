// --print-stats prints the per-phase timing report (the --time-passes
// report) to stderr; --stats-file sends it to a file instead and an
// unwritable path is an error.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --type-check-only --print-stats 2>&1 | %FileCheck %s
// CHECK: Kairo Compilation Timing Report
// RUN: %kairo %s --type-check-only --stats-file=%t.stats
// RUN: %FileCheck %s --input-file=%t.stats
// RUN: rm -rf %t.notadir && echo > %t.notadir
// RUN: not %kairo %s --type-check-only --stats-file=%t.notadir/no_such_dir/s > /dev/null 2>&1
