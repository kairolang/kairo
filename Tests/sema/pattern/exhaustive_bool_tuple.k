// `bool` is covered by `true` and `false`; a tuple column by column, so the
// witness of a tuple names every column.

fn only_true(b: bool) -> i32 {
    return match b {
// DIAG: exhaustive_bool_tuple.k:[[@LINE-1]]:12: error [SC120E]: match is not exhaustive: 'false' is not covered
        case true => 1
    }
}

fn both(b: bool) -> i32 {
    return match b {
// SEMA: MatchExpr @ [[@LINE-1]]:12 : i32 [exhaustive=1 covering_arm=1 open_tail=0]
        case true  => 1
        case false => 0
    }
}

fn pair_gap(t: (bool, bool)) -> i32 {
    return match t {
// DIAG: exhaustive_bool_tuple.k:[[@LINE-1]]:12: error [SC120E]: match is not exhaustive: '(false, false)' is not covered
        case (true, var b) => 1
        case (false, true) => 2
    }
}

fn pair_full(t: (bool, bool)) -> i32 {
    return match t {
// SEMA: MatchExpr @ [[@LINE-1]]:12 : i32 [exhaustive=1 covering_arm=2 open_tail=0]
        case (true, var b)  => 1
        case (false, true)  => 2
        case (false, false) => 3
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
