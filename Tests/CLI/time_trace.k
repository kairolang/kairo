// --time-trace=<file> prints the timing report and writes a Chrome trace to
// the file. Pinned: the report, the "written" notice, and that the file is a
// trace-event document.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --type-check-only --time-trace=%t.json 2>&1 | %FileCheck %s
// RUN: %FileCheck %s --check-prefix=JSON --input-file=%t.json
// CHECK: Kairo Compilation Timing Report
// CHECK: time trace written to
// JSON: "traceEvents"
