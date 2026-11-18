// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 32
// Without -fimplicit-conv, the cast is the way to a C++ user-defined
// conversion, explicit or not: what the SC063E fix-it inserts compiles and runs.
ffi "c++" import "cxx_user_conversion.h"

fn main() -> i32 {
    var a = A(7)
    var d = D(4)
    var n = len("hello" as View)
    n += len_ref("abc" as View)
    n += take(a as B)
    n += takec(d as C)
    return n + (if (load(0) as bool) => 9 else => 0)
}
