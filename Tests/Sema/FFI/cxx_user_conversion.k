// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=NOFLAG
// RUN: rm -rf %t.d
// RUN: %kairo %s -fimplicit-conv -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 32
// P813: at a C++ callee, -fimplicit-conv applies ONE C++ implicit user-defined
// conversion (a non-explicit converting constructor or conversion function),
// ranked below every standard conversion and performed by C++. Without the
// flag the call is SC063E, with a note naming the conversion and an `as` fix-it.
// NOFLAG: cxx_user_conversion.k:23:13: error [SC063E]: no matching overload for call to 'len'
// NOFLAG: fix-it:{{.*}}:{23:24-23:24}:" as View"
// NOFLAG: note [I900N]: C++ would convert the argument to 'View' implicitly through 'View(
// NOFLAG: error [SC063E]: no matching overload for call to 'len_ref'
// NOFLAG: error [SC063E]: no matching overload for call to 'take'
// NOFLAG: fix-it:{{.*}}:{25:16-25:16}:" as B"
// NOFLAG: implicitly through 'B(const A&)'
// NOFLAG: error [SC063E]: no matching overload for call to 'takec'
// NOFLAG: implicitly through 'operator C'
ffi "c++" import "cxx_user_conversion.h"

fn main() -> i32 {
    var a = A(7)
    var d = D(4)
    var n = len("hello")
    n += len_ref("abc")
    n += take(a)
    n += takec(d)
    return n + (if (load(0) as bool) => 9 else => 0)
}
