// RUN: { %kairo %s -fimplicit-conv --type-check-only 2>&1 || true; } | %FileCheck %s
// P813: even under -fimplicit-conv, an `explicit` constructor converts only
// through `as`, and no note claims C++ would convert. A Kairo `if` condition
// must be bool with or without the flag (control-flow); a class with
// operator bool gets the `as bool` fix-it.
// CHECK: cxx_user_conversion_neg.k:16:12: error [SC063E]: no matching overload for call to 'takee'
// CHECK-NOT: C++ would convert
// CHECK: cxx_user_conversion_neg.k:17:13: error [SC084E]: the 'if' condition must be 'bool', not 'Result'
// CHECK: fix-it:{{.*}}:{17:14-17:14}:" as bool"
// CHECK-NOT: error
ffi "c++" import "cxx_user_conversion.h"

fn main() -> i32 {
    var a = A(7)
    var r = load(0)
    return takee(a) +
        (if r => 1 else => 0)
}
