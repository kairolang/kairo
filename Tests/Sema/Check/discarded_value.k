// An expression statement that only computes a value is a warning, as C++'s
// -Wunused-value: a newline ends a statement, so `a` NEWLINE `+ b` is two,
// and the second is thrown away (G44). Calls, assignments, `++`/`--` and the
// short-circuit operators act, and are not.

fn g() -> i32 { return 1; }

fn f(a: i32, b: i32) -> i32 {
    var x = a
        + b;
    var y = a
        - b;
    a == b;
    x;
    g();
    x = y;
    ++x;
    x++;
    (a > 0) && (g() > 0);
    return x + y;
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not=SC268W
// CHECK: discarded_value.k:10:9: warning [SC268W]: expression result unused; the statement has no effect
// CHECK: discarded_value.k:10:9: note [I900N]: a newline ends a statement
// CHECK: discarded_value.k:12:9: warning [SC268W]
// CHECK: discarded_value.k:13:5: warning [SC268W]
// CHECK: discarded_value.k:14:5: warning [SC268W]
