// --check-past-syntax-errors falls back to leaving the broken file and its
// importers unchecked when the errors are not all kept inside bodies that
// can stand as signatures alone:
//
// - swallowed_lib.k: `var x = v +` then the body's `}`. The expression
//   parser takes the `}` as the bad operand, so the body runs on to the end
//   of the file and `second` is parsed inside it. The `}` the parse closed
//   with is not the one the text pairs with the body's `{`.
// - outofline_lib.k: the broken body is an out-of-line member definition,
//   which the class's declaration ring expects to be one.
//
// Either way the importer is not checked: its own type error is not
// reported. This file is the first case; fallback_outofline.k the second.
//
// RUN: { %kairo %s -I %S --type-check-only --check-past-syntax-errors 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
//
// CHECK-DAG: swallowed_lib.k:3:1: error [S052E]: expected expression, found '}'
// CHECK-DAG: swallowed_lib.k:1:29: error [S057E]: expected '}' to close block

import swallowed_lib::second

fn main() -> i32 {
    var z: i32 = "not checked"
    return second(1)
}
