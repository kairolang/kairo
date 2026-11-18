// XFAIL: *
// In a value-form `match` on `x: i32?`, every arm after `case null` sees `x`
// as non-null and reads it as `i32` (nullables.mdx, Matching a nullable:
// `default => f"port {port}"  // port reads as i32`). Returning the narrowed
// `x` itself from the `default` arm types the match as `i32?` and the
// function's `return` fails with SC028E, where the same read in the arm of
// `if a? => a else => 0` is `i32`.

fn arm_value(x: i32?) -> i32 {
    return match x {
        case null => 0
        case var v where v < 0 => -v
        default => x
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --cmax-errors=0 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='warning ['
