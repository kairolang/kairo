// A literal's own closer after a trailing comma, followed on
// its line by more of the expression, is the literal's closer. Recovery
// keeps a `}` that a FAILED operand stands on only when it ends its line;
// a list loop never asks that of its own closer. Valid code: no errors.
//
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not=error

fn f() -> i32 {
    var n = {1, 2,}.size()
    for x in {1, 2,} { }
    var m = {
        1: 2,
        3: 4,
    }.size()
    var t = (1, 2,).0
    var l = [1, 2,].size()
    g(1, 2,).h()
    return 0
}
