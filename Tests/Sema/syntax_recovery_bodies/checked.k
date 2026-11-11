// --check-past-syntax-errors, a file whose every syntax error is inside a
// function body that kept it (the body ends at the brace the text pairs
// with its opener): the file is checked with those bodies dropped, each
// such function its signature alone, and so is every file importing it.
//
// The errors are reported once, by the parser, in both modes. With the mode
// on Sema runs: this file's own type error is reported (with the mode off
// the parse error stops the action first), and nothing is reported about
// the broken bodies or because of them -- not the parameter the dropped
// body used, not the constructor that no longer sets its field, not the
// interface method whose body is gone. Uses of the broken functions resolve
// to them; healthy code in the broken file resolves as it would.
//
// RUN: { %kairo %s -I %S --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=OFF --implicit-check-not=error
// RUN: { %kairo %s -I %S --type-check-only --check-past-syntax-errors 2>&1 || true; } | %FileCheck %s --check-prefix=ON --implicit-check-not=error
// RUN: { %kairo %s -I %S --type-check-only --check-past-syntax-errors --print-sema 2>&1 || true; } | %FileCheck %s --check-prefix=SEMA
// RUN: not %kairo %s -I %S --type-check-only --check-past-syntax-errors
//
// OFF: broken_lib.k:9:18: error [S052E]: expected expression, found ';'
// OFF: broken_lib.k:13:26: error [S052E]: expected expression, found ';'
// OFF: broken_lib.k:30:17: error [S054E]: expected ')' or ',' after expression
// OFF: broken_lib.k:30:21: error [S052E]: expected expression, found ')'
// OFF: broken_lib.k:39:19: error [S054E]
// OFF: broken_lib.k:39:23: error [S052E]
// OFF: broken_lib.k:39:26: error [S052E]
//
// ON-DAG: broken_lib.k:9:18: error [S052E]: expected expression, found ';'
// ON-DAG: broken_lib.k:13:26: error [S052E]: expected expression, found ';'
// ON-DAG: broken_lib.k:30:17: error [S054E]: expected ')' or ',' after expression
// ON-DAG: broken_lib.k:30:21: error [S052E]: expected expression, found ')'
// ON-DAG: broken_lib.k:39:19: error [S054E]
// ON-DAG: broken_lib.k:39:23: error [S052E]
// ON-DAG: broken_lib.k:39:26: error [S052E]
// ON-DAG: checked.k:48:18: error [SC028E]: cannot convert 'string' to 'i32'
//
// SEMA-DAG: use     above       @ 44:12    -> fn above @ 34:5  [scope <tu>]
// SEMA-DAG: use     helper      @ 35:12    -> fn helper @ 1:5  [scope <tu>]
// SEMA-DAG: use     Shape       @ 45:13    -> class Shape @ 5:5  [import overlay]
// SEMA-DAG: use     bad         @ 47:13    -> fn bad @ 38:5  [import overlay]
// SEMA-DAG: use     below       @ 49:16    -> fn below @ 43:5  [import overlay]

import broken_lib::*

fn main() -> i32 {
    var s = Shape(2)
    var d = Dog()
    var t = bad(1, "x") + s.area() + s.grow(1) + d.name()
    var z: i32 = "a genuine error"
    return t + below(3)
}
