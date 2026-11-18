// The call-site fill of default arguments applies only to parameters that
// declare a default: omitting a parameter without one is SC021E, and the
// call that omits a defaulted one is accepted.

fn free_def(a: i32, b: i32 = 3) -> i32 { return a * b; }
fn nodef(a: i32, b: i32) -> i32 { return a * b; }

fn main() -> i32 {
    return free_def(2) + nodef(2)
}

// --- lit wiring ---
// RUN: { %kairo -fduck-generics %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='I003E'
// CHECK: duck_default_param_call_reject.k:9:26: error [SC021E]: missing argument for parameter 'b'
