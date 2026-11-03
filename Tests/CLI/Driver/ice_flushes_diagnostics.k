// RUN: { env KAIRO_DEBUG_FORCE_ICE=1 %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
//
// An internal compiler error aborts the process, past the end-of-run flush,
// so every diagnostic still buffered used to be lost: a crashed run printed
// the ICE banner and nothing else. The abort now flushes them first, in the
// configured format. KAIRO_DEBUG_FORCE_ICE forces an ICE right after Sema,
// before this file's sink is drained -- the worst case.

fn f() -> i32 {
    // CHECK: ice_flushes_diagnostics.k:[[@LINE+1]]:12: error [R020E]: use of undeclared identifier 'missing'
    return missing
}

// CHECK: Kairo Internal Compiler Error: forced by KAIRO_DEBUG_FORCE_ICE
