fn f() -> i32 {
    var i: i32 = 0
    label!(top)
// DIAG: label_gate.k:[[@LINE-1]]:5: error [SC116E]: 'label!' is not yet supported
    i += 1
    if i < 3 { jump!(top) }
// DIAG: label_gate.k:[[@LINE-1]]:16: error [SC116E]: 'jump!' is not yet supported
    return i
}

// --- lit wiring -----------------------------------------------------------
// User label!/jump! stay rejected until a crossing-initialization check
// exists; EmitIR renders them only for the lowerings.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
