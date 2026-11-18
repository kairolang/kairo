// The `=> {` block detection must leave a real set literal arm alone.
fn risky() panic(i32) -> i64 { panic 1 }

fn main() -> i32 {
    var s = try risky() catch e: i32 => { 1, 2, 3 }
    return 0
}

// --- lit wiring ---
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: S073E
// CHECK: SC039E
// CHECK-NOT: S054E
