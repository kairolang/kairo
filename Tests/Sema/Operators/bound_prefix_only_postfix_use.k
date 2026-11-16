// A bound that requires only `op l++` does not grant the postfix use:
// `w++` on the bounded value finds no requirement of that fixity.

interface Pre {
    fn op l++(self) -> Self
}

fn <T impl Pre> wrong(v: T) -> T {
    var w = v
    var a = w++
    return a
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error ["
// DIAG: {{.*}}:10:13: error [R025E]: '++' on 'T' needs a bound that declares 'op ++'
