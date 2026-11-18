// Integer coverage is computed: the column is cut into segments at every
// range boundary, so ranges that together cover the type are exhaustive. The
// witness of a gap is the first uncovered segment.

fn u8_split(x: u8) -> i32 {
    return match x {
// SEMA: MatchExpr @ [[@LINE-1]]:12 : i32 [exhaustive=1 covering_arm=1 open_tail=0]
        case 0..=127   => 0
        case 128..=255 => 1
    }
}

fn u8_gap(x: u8) -> i32 {
    return match x {
// DIAG: exhaustive_int.k:[[@LINE-1]]:12: error [SC120E]: match is not exhaustive: '128' is not covered
        case 0..=127   => 0
        case 129..=255 => 1
    }
}

// A pattern cannot start with `-`, so the lowest segment is an open range.
fn i8_whole(x: i8) -> i32 {
    return match x {
// SEMA: MatchExpr @ [[@LINE-1]]:12 : i32 [exhaustive=1 covering_arm=2 open_tail=0]
        case ..=-1     => -1
        case 0         => 0
        case 1..=127   => 1
    }
}

fn i32_values(x: i32) -> i32 {
    return match x {
// DIAG: exhaustive_int.k:[[@LINE-1]]:12: error [SC120E]: match is not exhaustive: '-2147483648..=0' is not covered
        case 1 => 1
        case 2 => 2
        case 3 => 3
    }
}

// Open ranges, and `..` excluding its upper bound: `..0` stops at -1.
fn i32_halves(x: i32) -> i32 {
    return match x {
// SEMA: MatchExpr @ [[@LINE-1]]:12 : i32 [exhaustive=1 covering_arm=1 open_tail=0]
        case ..0 => -1
        case 0.. => 1
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
