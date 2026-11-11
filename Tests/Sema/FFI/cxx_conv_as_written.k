// RUN: rm -rf %t.d
// RUN: %kairo %s -fimplicit-conv --print-ir 2>&1 | %FileCheck %s --check-prefix=IR
// RUN: %kairo %s -fimplicit-conv -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 12
// P832: an argument C++ converts implicitly at a C++ callee (P825) is
// emitted as written. A cast spelled the parameter's unsubstituted type,
// `static_cast< ::fs<T ...>>`, naming a T that does not exist at the call.
// A literal at a C++ template's `T&&...` or `const T&` goes as a C string,
// not a builtin::string temporary C++ would deduce instead.
// IR: = ::pr("ab{}", 1, "x");
// IR: = ::one("hi");
// IR: = ::takes_dst(s);
ffi "c++" import "cxx_conv_as_written.h"

fn main() -> i32 {
    var a = pr("ab{}", 1, "x")
    var b = one("hi")
    var s = Src(4)
    var c = takes_dst(s)
    return a + b + c
}
