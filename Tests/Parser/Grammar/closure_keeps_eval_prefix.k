// `eval fn (x) { }` is a closure expression, not a decl: `eval` must NOT be
// claimed as a leading modifier when the `fn` is not a declaration head.
// RUN: %kairo %s --syntax-only 2>&1 | %FileCheck %s --check-prefix=OK --allow-empty
// OK-NOT: error
fn Test() {
    var f = eval fn (x: i32) -> i32 { return x }
    var g = fn (x: i32) -> i32 { return x }
}
