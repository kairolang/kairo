// A codegen ICE names the Kairo source it was emitting, not only the line of
// the compiler that gave up (Codegen/CodegenICE.k). The located I003E is
// rendered BEFORE the abort: diagnostics are buffered until the end of the
// run, and an abort skips that flush.
//
// The trigger is any construct codegen does not emit yet; a `panic`
// statement is the current one (EmitIR: "panic; PanicLowering owns it").
// It was a closure until lambda emission landed. `apply` is `panic`: a
// `panic` in a function without it is an error (PanicEffectChecking), and
// an error stops the run before codegen. When PanicLowering lands
// this stops ICEing. Swap in the next unemitted construct then and keep
// the checks, rather than deleting the test.

fn apply(x: i32) panic -> i32 {
    if x > 3 { panic "boom" }
    return x
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: { %kairo %s -c --cache-dir %t.d 2>&1 || true; } | %FileCheck %s
// CHECK: ice_location.k:15:16: error [I003E]: internal compiler error: EmitIR: panic; PanicLowering owns it
// CHECK: Kairo Internal Compiler Error: EmitIR: panic; PanicLowering owns it, at {{.*}}ice_location.k:15:16
