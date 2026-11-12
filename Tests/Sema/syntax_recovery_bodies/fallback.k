// --check-past-syntax-errors falls back to leaving the broken file and its
// importers unchecked when the errors are not all kept inside bodies that
// can stand as signatures alone:
//
// - swallowed_lib.k: `var x = v +` then the body's `}`. The
//   expression parser leaves the `}` for the body rather than taking it as
//   the bad operand, so this case is checked (see below).
//   fallback_unclosed_paren.k is the shape that falls back.
// - outofline_lib.k: the broken body is an out-of-line member definition,
//   which the class's declaration ring expects to be one.
//
// For the second case the importer is not checked (fallback_outofline.k).
// For the first it is: its own type error is reported, below.
//
// RUN: { %kairo %s -I %S --type-check-only --check-past-syntax-errors 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
//
// CHECK-DAG: swallowed_lib.k:3:1: error [S052E]: expected expression, found '}'
// CHECK-DAG: fallback.k:23:18: error [SC028E]: cannot convert 'string' to 'i32'

import swallowed_lib::second

fn main() -> i32 {
    var z: i32 = "not checked"
    return second(1)
}
