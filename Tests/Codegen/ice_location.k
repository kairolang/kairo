// A codegen ICE names the Kairo source it was emitting, not only the line of
// the compiler that gave up (Codegen/CodegenICE.k). The located I003E is
// rendered BEFORE the abort: diagnostics are buffered until the end of the
// run, and an abort skips that flush.
//
// The trigger is any construct codegen does not emit yet; an inline foreign
// block in a function body is the current one (EmitIR: "inline foreign
// block; not emitted yet"). It was a closure until lambda emission landed,
// then a `panic` statement until PanicLowering did. When this one is
// emitted, swap in the next unemitted construct and keep the checks, rather
// than deleting the test.

fn apply(x: i32) -> i32 {
    if x > 3 { inline "c++" { int y = 0; } }
    return x
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: { %kairo %s -c --cache-dir %t.d 2>&1 || true; } | %FileCheck %s
// CHECK: ice_location.k:14:16: error [I003E]: internal compiler error: EmitIR: inline foreign block; not emitted yet
// CHECK: Kairo Internal Compiler Error: EmitIR: inline foreign block; not emitted yet, at {{.*}}ice_location.k:14:16
