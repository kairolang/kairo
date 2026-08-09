// An expression-form `if` branch holds exactly one expression, but that
// expression may sit on its own line. The closing `}` is then preceded by a
// newline, which must not be mistaken for a second expression.
// RUN: %kairo %s --syntax-only 2>&1 | %FileCheck %s --check-prefix=OK --allow-empty
// OK-NOT: error
fn Test(a: usize) -> i32 {
    var x: i32 = if a <= 8 {
        1
    } else {
        2
    }
    var y: i32 = if a <= 8 { 1 } else { 2 }
    return x + y
}
