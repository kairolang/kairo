// Open domains need a `default`: no list of patterns completes a string, a
// flags enum (a discriminant WRITTEN with `|` or `<<`) or an imported C++
// enum. Flags are read off the syntax, never the numbers: a default-numbered
// enum whose West = 3 = East | South is still closed.

ffi "c++" import "open_enum.h"

fn text(s: string) -> i32 {
    return match s {
// DIAG:      exhaustive_open.k:[[@LINE-1]]:12: error [SC120E]: match is not exhaustive: '{{.*}}' values other than the ones listed are not covered
// DIAG-NEXT: exhaustive_open.k:[[@LINE-2]]:12: note [{{[A-Z0-9]+}}]: '{{.*}}' can hold values no list of patterns names; add a 'default' arm
        case "a" => 1
        case "b" => 2
    }
}

enum Perm derives u8 {
    Read  = 1 << 0,
    Write = 1 << 1,
    RW    = (Read | Write),
}

fn flags(p: Perm) -> i32 {
    return match p {
// DIAG:      exhaustive_open.k:[[@LINE-1]]:12: error [SC120E]: match is not exhaustive: 'Perm' values other than the ones listed are not covered
        case .Read  => 1
        case .Write => 2
        case .RW    => 3
    }
}

enum Compass { North, East, South, West }

fn closed(c: Compass) -> i32 {
    return match c {
// SEMA: MatchExpr @ [[@LINE-1]]:12 : i32 [exhaustive=1 covering_arm=3 open_tail=1]
        case .North => 0
        case .East  => 1
        case .South => 2
        case .West  => 3
    }
}

fn cxx(m: Mode) -> i32 {
    return match m {
// DIAG:      exhaustive_open.k:[[@LINE-1]]:12: error [SC120E]: match is not exhaustive: '{{.*}}Mode' values other than the ones listed are not covered
        case .Fast => 0
        case .Slow => 1
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
