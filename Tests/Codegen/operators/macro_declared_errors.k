// Operators from a macro keep the declaration rules: the same
// operator twice through one macro is still a redeclaration (R041E), and
// a different one through the same macro is not. Only the operator's
// identity changed: it is read through the expansion.

macro bin!(t) { fn op t (const self, o: Self) -> i32 { return 1 } }

class Dup {
    var v: i32 = 0
    bin!(+)
    bin!(+)
// DIAG: macro_declared_errors.k:11:5: error [R041E]: class member 'op +' cannot be redeclared
    bin!(-)
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error ["
