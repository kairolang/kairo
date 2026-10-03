fn not_gen() -> i32 {
    yield 1                                     // expect: error yield-outside-generator
    return 0
}
fn has_value() -> yield i32 {
    return 3                                    // expect: error generator-return-value
}
fn wrong_type() -> yield i32 {
    yield "no"                                  // expect: error conversion
}
fn main() -> yield i32 { }                      // expect: error generator-main
// expect: no other diagnostics

// --- lit wiring -----------------------------------------------------------
// The last NOT asserts ReturnPathCheck skips generators: none of these
// functions falls through to a missing-return error.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:     yield_err.k:2:{{[0-9]+}}: error [{{[A-Z0-9]+}}]:
// DIAG:     yield_err.k:6:{{[0-9]+}}: error [{{[A-Z0-9]+}}]:
// DIAG:     yield_err.k:9:{{[0-9]+}}: error [{{[A-Z0-9]+}}]:
// DIAG:     yield_err.k:11:{{[0-9]+}}: error [{{[A-Z0-9]+}}]:
// DIAG-NOT: {{error|warning}} [
// DIAG-NOT: SC104E
