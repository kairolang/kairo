class Foo {
    var @inout f: i32;                      // expect: error mode-on-binding
}
fn <@move T> g(x: T) { }                    // expect: error mode-on-binding
fn main() {
    var @inout x: i32 = 0;                  // expect: error mode-on-binding
    var (@inout a, b) = (1, 2);             // expect: error mode-on-binding
    for @move y in [1, 2] { }               // expect: error mode-on-binding
    try { } catch @inout e { }              // expect: error mode-on-binding
    match 1 { case var @move n { } }        // expect: error mode-on-binding
}
// expect: no other diagnostics

// --- lit wiring -----------------------------------------------------------
// A passing mode is legal only on a parameter; every other binding site
// rejects it. Wiring sits at the bottom so the line numbers above hold.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// DIAG:     mode_on_binding.k:2:{{[0-9]+}}: error [{{[A-Z0-9]+}}]:
// DIAG:     mode_on_binding.k:4:{{[0-9]+}}: error [{{[A-Z0-9]+}}]:
// DIAG:     mode_on_binding.k:6:{{[0-9]+}}: error [{{[A-Z0-9]+}}]:
// DIAG:     mode_on_binding.k:7:{{[0-9]+}}: error [{{[A-Z0-9]+}}]:
// DIAG:     mode_on_binding.k:8:{{[0-9]+}}: error [{{[A-Z0-9]+}}]:
// DIAG:     mode_on_binding.k:9:{{[0-9]+}}: error [{{[A-Z0-9]+}}]:
// DIAG:     mode_on_binding.k:10:{{[0-9]+}}: error [{{[A-Z0-9]+}}]:
// DIAG-NOT: {{error|warning}} [
