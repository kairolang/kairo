// A failing assert exits 134 and names the assertion on stderr; a passing one
// falls through.

fn check(v: i32) {
    assert v > 0, "v must be positive"
}

fn main() -> i32 {
    check(1)
    check(-1)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s -o %t.exe
// RUN: { %t.exe 2>&1 || true; } | %FileCheck %s
// CHECK: assertion failed at {{.*}}assert_stmt_run.k:5:5: assert v > 0, "v must be positive"
