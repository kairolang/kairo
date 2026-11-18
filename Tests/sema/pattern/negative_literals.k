// Negative literal patterns: `-` directly before a numeric literal is part of
// the literal, as a value and as either bound of a range.

fn ones(x: i32) -> i32 {
    return match x {
// SEMA:      MatchExpr @ [[@LINE-1]]:12 : i32 [exhaustive=1 covering_arm=2 open_tail=0]
// SEMA-NEXT: decision [nodes=4 rows=3]
// SEMA-NEXT: n3: switch $ { -2147483648 => n0, -1 => n1, _ => n2 }
        case -1          => 1
        case -2147483648 => 2
        default          => 0
    }
}

fn band(x: i32) -> i32 {
    return match x {
// SEMA:      MatchExpr @ [[@LINE-1]]:12 : i32 [exhaustive=1 covering_arm=1 open_tail=0]
// SEMA-NEXT: decision [nodes=3 rows=2]
// SEMA-NEXT: n2: switch $ { -10..=-1 => n0, _ => n1 }
        case -10..=-1 => 1
        default       => 0
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG-NOT: error
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
