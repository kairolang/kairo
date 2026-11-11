// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// With no `int` overload an int literal converts to `unsigned` and to
// `double` alike, ambiguous in C++ and in Kairo.
// CHECK: error [SC064E]: call to 'g' is ambiguous
ffi "c++" import "cxx_int_literal_overload.h"

fn main() -> i32 {
    return g(7)
}
