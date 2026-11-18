// The statement form must be exhaustive too. `default { }` keeps the old
// "fall out silently" behaviour where that is what was meant.

fn no_default(x: i32) {
    match x {
// DIAG: exhaustive_stmt.k:[[@LINE-1]]:5: error [SC120E]: match is not exhaustive: '-2147483648..=0' is not covered
        case 1 { }
        case 2 { }
    }
}

fn with_default(x: i32) {
    match x {
// SEMA: MatchStmt @ [[@LINE-1]]:5 [exhaustive=1 covering_arm=2 open_tail=0]
        case 1 { }
        case 2 { }
        default { }
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
