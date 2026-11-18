// A catch arm is one `=> expr`; a `{ stmts; value }` after the arrow
// must not parse as a set literal and report "expected '}' to close set
// literal"; it names the arm rule and offers the `({ ... })` wrapping.
struct Bad { var code: i32 }
fn risky() panic(Bad) -> i64 { panic Bad { code: 1 } }

fn main() -> i32 {
    var code = 0
    var r = try risky() catch e: Bad => { code = e.code; 10 }
    return (r as i32) + code
}

// --- lit wiring ---
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s
// CHECK: error [S073E]: an arm is a single expression, not a block; use a statement expression '({ ... })'
// CHECK-NOT: set literal
