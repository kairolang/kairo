// The newline tolerance above must not weaken the one-expression rule: two
// expressions in a branch is still an error, as is an empty branch.
// RUN: { %kairo %s --syntax-only 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// ERR: error [S054E]: expression-form branch allows exactly one expression
fn Test(a: usize) -> i32 {
    var x: i32 = if a <= 8 {
        g()
        h()
    } else { 2 }
    return x
}
