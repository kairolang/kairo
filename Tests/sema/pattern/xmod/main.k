// A Kairo enum from another module is closed like a local one: it is not an
// imported C++ enum, so listing every variant is exhaustive. Variant names are
// compared by spelling through each decl's own file (identifier indices are
// per file), which both the dotted lookup and the witness depend on.

import compass;

fn all(c: compass::Compass) -> i32 {
    return match c {
// SEMA: MatchExpr @ [[@LINE-1]]:12 : i32 [exhaustive=1 covering_arm=3 open_tail=1]
        case .North => 0
        case .East  => 1
        case .South => 2
        case .West  => 3
    }
}

fn some(c: compass::Compass) -> i32 {
    return match c {
// DIAG: main.k:[[@LINE-1]]:12: error [SC120E]: match is not exhaustive: '.South' is not covered
        case .North => 0
        case .East  => 1
        case .West  => 3
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
