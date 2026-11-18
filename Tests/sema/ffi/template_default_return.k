// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 21
//
// A C++ function template's defaulted type parameter that no argument
// deduces takes its default, as in C++ ([temp.deduct]/5). Kairo's deduction
// binds it: the return type is not left dependent, the call is not typed as
// unknown without a diagnostic, and the callee does not reach codegen unbound
// (I011W, then the I003E error "unbound callee reached codegen").

ffi "c++" import "template_default_return.h"

fn main() -> i32 {
    var x: i32 = 4
    var a = wrap(x)            // wrap<int, Box>: 5
    var b = wrap_first(x)      // wrap_first<Box, int>: 3
    var c: i32 = same(x)       // same<int, int>: 8
    return a.get() + b.get() + c + wrap(x).get() - 0
}

// DIAG-NOT: error
