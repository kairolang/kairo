// An arm that can never match is SC121E; a single alternative that can never
// match is SC122E at that alternative. A guarded arm covers nothing, so it
// never makes a later arm dead, but it can be dead itself.

enum Direction { North, East, South, West }

fn after_default(x: i32) -> i32 {
    return match x {
        case 1  => 1
        default => 0
        case 2  => 2
// DIAG: dead_arms.k:[[@LINE-1]]:9: error [SC121E]: this arm can never match: the arms before it already cover every value it matches
    }
}

fn twice(d: Direction) -> i32 {
    return match d {
        case .North => 1
        case .North => 2
// DIAG: dead_arms.k:[[@LINE-1]]:9: error [SC121E]: this arm can never match: the arms before it already cover every value it matches
        default     => 0
    }
}

fn inside_range(x: i32) -> i32 {
    return match x {
        case 1..=10 => 1
        case 5      => 5
// DIAG: dead_arms.k:[[@LINE-1]]:9: error [SC121E]: this arm can never match: the arms before it already cover every value it matches
        default     => 0
    }
}

fn dead_alternative(x: i32) -> i32 {
    return match x {
        case 1, 1 => 1
// DIAG: dead_arms.k:[[@LINE-1]]:17: error [SC122E]: this alternative can never match: earlier patterns already cover every value it matches
        default   => 0
    }
}

// Not dead: the guard may decline, and the unguarded `1` takes it.
fn guard_then_same(x: i32, c: bool) -> i32 {
    return match x {
        case 1 where c => 1
        case 1         => 2
        default        => 0
    }
}

fn guarded_after_all(b: bool, c: bool) -> i32 {
    return match b {
        case true         => 1
        case false        => 0
        case true where c => 2
// DIAG: dead_arms.k:[[@LINE-1]]:9: error [SC121E]: this arm can never match: the arms before it already cover every value it matches
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
