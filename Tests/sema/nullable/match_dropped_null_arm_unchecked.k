// A match on a place proven non-null drops a lone first `case null`: no
// path reaches its body, which is typed from an unreachable state, so a read
// there that would need a check reports nothing. The same body in the null
// arm of a match on an unproven place is reached and is checked.

fn ok_dropped(x: i32?, y: i32?) -> i32 {
    if !x? { return 0 }
    match x {
        case null { return y + 1 }
        default { return 1 }
    }
}

fn bad_reached(x: i32?, y: i32?) -> i32 {
    match x {
        case null { return y + 1 }
        default { return 1 }
    }
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG: {{.*}}:16:28: error [SC265E]: 'y' may be null here; check it with 'if y?' first
// DIAG-NEXT: {{.*}}:14:25: note [I900N]: 'y' is a nullable parameter; it may be null on entry
// DIAG-NOT: {{error|warning}}
