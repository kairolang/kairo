fn apply(f: fn(@inout i32) -> void, @inout v: i32) { f(&v); }
fn main() {
    var n = 0;
    var inc = fn (@inout x: i32) { x = x + 1; };
    apply(inc, &n);                         // expect: clean
    var byval = fn (x: i32) { };
    apply(byval, &n);                       // expect: error cannot convert 'fn(i32) -> void' to 'fn(@inout i32) -> void'
}

// --- lit wiring -----------------------------------------------------------
// A closure's type IS the fn-pointer canonical, so its parameter modes must
// survive into `apply`'s parameter: a by-value closure is a different type.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// DIAG-NOT:  closure_mode.k:5:{{[0-9]+}}: error
// DIAG:      closure_mode.k:7:{{[0-9]+}}: error [SC001E]: no matching overload for call to 'apply'
// DIAG-NEXT: closure_mode.k:1:{{[0-9]+}}: note [{{[A-Z0-9]+}}]: {{.*}}'fn (i32)'{{.*}}'fn (@inout i32)'
// DIAG-NOT:  {{error|warning}} [
