// A value arm holds exactly one expression, but that expression may sit on
// the line after its `=>`, and `else` may open the next line. Neither newline
// may be mistaken for the end of the `if`.
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --check-prefix=OK --allow-empty
// OK-NOT: error
fn Test(a: usize) -> i32 {
    var x: i32 = if a <= 8 =>
        1
    else =>
        2
    var y: i32 = if a <= 8 => 1 else => 2
    return x + y
}
