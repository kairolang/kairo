// A codegen ICE names the Kairo source it was emitting, not only the line of
// the compiler that gave up (Codegen/CodegenICE.k). The located I003E is
// rendered BEFORE the abort: diagnostics are buffered until the end of the
// run, and an abort skips that flush.
//
// The trigger is any construct codegen does not emit yet; a closure is the
// current one (EmitIR: "lambda emission is not written yet"). When lambdas
// land this stops ICEing. Swap in the next unemitted construct then and keep
// the checks, rather than deleting the test.

fn apply(x: i32) -> i32 {
    var f = fn (y: i32) -> i32 { return y + 1 }
    return f(x)
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: { %kairo %s -c --cache-dir %t.d 2>&1 || true; } | %FileCheck %s
// CHECK: ice_location.k:12:13: error [I003E]: internal compiler error: EmitIR: closure; lambda emission is not written yet
// CHECK: Kairo Internal Compiler Error: EmitIR: closure; lambda emission is not written yet, at {{.*}}ice_location.k:12:13
