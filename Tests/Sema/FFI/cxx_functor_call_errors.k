// What stays an error on a function object: a pointer to one is not
// callable (C++ agrees: `p(1)` needs `(*p)(1)`), and arguments no
// operator() takes are the ordinary no-matching-overload error.

ffi "c++" import "cxx_functor_call.h"

fn main() -> i32 {
    var c = Counter()
    var unsafe *p = unsafe &c
    var a = unsafe p(1)
    var b = c(1, 2, 3)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: cxx_functor_call_errors.k:10:20: error [SC062E]: 'unsafe *Counter' is not callable
// CHECK: cxx_functor_call_errors.k:11:13: error [SC063E]: no matching overload for call to 'op ()'
