// --cmax-match-arms errors on a match with more arms than the limit; 0 is
// unlimited. Three arms: a limit of 3 accepts, 2 rejects.

fn pick(x: i32) -> i32 {
    match x {
        case 1 { return 10; }
        case 2 { return 20; }
        default { return 0; }
    }
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo --type-check-only --cmax-match-arms=3 %s
// RUN: %kairo --type-check-only --cmax-match-arms=0 %s
// RUN: { %kairo --type-check-only --cmax-match-arms=2 %s 2>&1 || true; } | %FileCheck %s
// CHECK: cmax_match_arms.k:5:{{[0-9]+}}: error [SC001E]: match has too many arms (3, limit 2)
