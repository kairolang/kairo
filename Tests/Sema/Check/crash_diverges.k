// `crash!()` expands to a call to `crash_with`, a `-> !` function
// (PANIC.md §2.4), so the flow checks see it end its path: a `-> T`
// function needs nothing after it (no SC104E), and nothing warns about the
// crash itself (no SC003W). It is not a panic: no `panic` specifier is
// needed, and `main` may use it. (A statement AFTER a `-> !` call is not
// reported as unreachable today, crash or not: TICKETS.)

fn only_crash() -> i32 {
    crash!()
}

fn branch(x: i32) -> i32 {
    if x > 0 { return x }
    crash!("x was not positive")
}

fn in_arm(x: i32) -> i32 {
    if x == 0 { crash!() } else { return x }
}

fn main() -> i32 {
    if branch(1) != 1 { crash!("unreachable") }
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
// CHECK-NOT: error [
// CHECK-NOT: warning [
