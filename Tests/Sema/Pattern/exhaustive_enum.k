// Exhaustiveness over a closed enum. Listing every variant is exhaustive over
// the DECLARED values (open_tail=1: an undeclared discriminant reaches no arm,
// and MatchLowering applies UnmatchedPolicy to it). A missing variant is
// SC120E naming it; a `default` after a complete list can never match
// (SC121E); some variants plus `default` is exhaustive through the default
// (open_tail=0).

enum Direction { North, East, South, West, Center }

fn missing(d: Direction) -> i32 {
    return match d {
// DIAG:      exhaustive_enum.k:[[@LINE-1]]:12: error [SC120E]: match is not exhaustive: '.West' is not covered
// DIAG-NEXT: exhaustive_enum.k:[[@LINE-2]]:12: note [{{[A-Z0-9]+}}]: add an arm for '.West', or a 'default' arm
        case .North  => 1
        case .East   => 2
        case .South  => 3
        case .Center => 5
    }
}

fn all(d: Direction) -> i32 {
    return match d {
// SEMA: MatchExpr @ [[@LINE-1]]:12 : i32 [exhaustive=1 covering_arm=4 open_tail=1]
        case .North  => 1
        case .East   => 2
        case .South  => 3
        case .West   => 4
        case .Center => 5
    }
}

fn dead_default(d: Direction) -> i32 {
    return match d {
        case .North  => 1
        case .East   => 2
        case .South  => 3
        case .West   => 4
        case .Center => 5
        default      => 0
// DIAG:      exhaustive_enum.k:[[@LINE-1]]:9: error [SC121E]: this arm can never match: the arms before it already cover every value it matches
    }
}

fn some_default(d: Direction) -> i32 {
    return match d {
// SEMA: MatchExpr @ [[@LINE-1]]:12 : i32 [exhaustive=1 covering_arm=2 open_tail=0]
        case .North => 1
        case .East  => 2
        default     => 0
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
