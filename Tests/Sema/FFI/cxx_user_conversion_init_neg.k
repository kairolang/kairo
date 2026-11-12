// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// Without -fimplicit-conv, no C++ implicit conversion: the SC028E at
// an initialisation, assignment or return says which conversion C++ would
// use and the fix-it writes the cast. An `explicit` constructor is no
// implicit route, flag or not: no note claims one.
// CHECK: cxx_user_conversion_init_neg.k:22:12: error [SC028E]: cannot convert 'string' to 'View'
// CHECK: fix-it:{{.*}}:{22:18-22:18}:" as View"
// CHECK: note [{{[A-Z0-9]+}}]: C++ would convert the value to 'View' implicitly through 'View(unsafe *const c_char)'; Kairo applies no C++ implicit conversion unless -fcxx-implicit-conv is given
// CHECK: cxx_user_conversion_init_neg.k:27:16: error [SC028E]: cannot convert 'A' to 'B'
// CHECK: fix-it:{{.*}}:{27:17-27:17}:" as B"
// CHECK: cxx_user_conversion_init_neg.k:28:19: error [SC028E]: cannot convert 'string' to 'View'
// CHECK: fix-it:{{.*}}:{28:26-28:26}:" as View"
// CHECK: cxx_user_conversion_init_neg.k:29:9: error [SC028E]: cannot convert 'string' to 'View'
// CHECK: fix-it:{{.*}}:{29:13-29:13}:" as View"
// CHECK: cxx_user_conversion_init_neg.k:31:16: error [SC028E]: cannot convert 'D' to 'C'
// CHECK: note [{{[A-Z0-9]+}}]: C++ would convert the value to 'C' implicitly through 'operator C'
// CHECK: cxx_user_conversion_init_neg.k:32:16: error [SC028E]: cannot convert 'A' to 'E'
// CHECK-NOT: C++ would convert
ffi "c++" import "cxx_user_conversion.h"

fn mk() -> View {
    return "abcd"
}

fn main() -> i32 {
    var a = A(3)
    var b: B = a
    var v: View = "hello"
    v = "hi"
    var d = D(4)
    var c: C = d
    var e: E = a
    return 0
}
