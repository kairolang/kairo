// `assert cond, msg?` lowers to `if (!(cond)) kairo_rt_crash_exit(...)`: the
// crash text names the location and carries the statement as written, with or
// without a message operand.

fn check(v: i32) {
    assert v > 0
    assert v < 100, "v out of range"
}

fn main() -> i32 {
    check(5)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: if(!((v> 0)))::kairo_rt_crash_exit(
// CXX-SAME: kairo: assertion failed at {{.*}}assert_stmt.k:6:5: assert v > 0
// CXX-SAME: , 134);
// CXX: if(!((v<100)))::kairo_rt_crash_exit(
// CXX-SAME: assert_stmt.k:7:5: assert v < 100, \"v out of range\"
