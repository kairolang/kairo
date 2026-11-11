// `spawn e` and the `thread e` expression type-check but have no lowering
// yet: FeatureGateCheck reports each as SC116E at its keyword, instead of
// an internal error in codegen ("EmitIR: spawn; the async lowering owns
// it"). A `thread` variable (thread-local storage) is a
// declaration, not this expression, and stays compiled.

fn work() -> i32 { return 1 }

thread counter: i32 = 0

fn main() -> i32 {
    spawn work()
    var t = thread work()
    counter += 1
    return counter
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="I003E"
// CHECK: spawn_thread_not_supported.k:12:5: error [SC116E]: a 'spawn' expression is not yet supported
// CHECK: spawn_thread_not_supported.k:13:13: error [SC116E]: a 'thread' expression is not yet supported
// RUN: { %kairo %s -o %t.exe 2>&1 || true; } | %FileCheck %s --check-prefix=BUILD --implicit-check-not="I003E"
// BUILD: error [SC116E]: a 'spawn' expression is not yet supported
