fn main() -> i32 {
    var a = 3..                                 // expect: error open-range
    var b = ..5                                 // expect: error open-range
    for i in 0.. { }                            // expect: error open-range
    return 0
}
// expect: no other diagnostics

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:     range_open_err.k:2:{{[0-9]+}}: error [{{[A-Z0-9]+}}]:
// DIAG:     range_open_err.k:3:{{[0-9]+}}: error [{{[A-Z0-9]+}}]:
// DIAG:     range_open_err.k:4:{{[0-9]+}}: error [{{[A-Z0-9]+}}]:
// DIAG-NOT: {{error|warning}} [
