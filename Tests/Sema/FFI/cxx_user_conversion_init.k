// RUN: rm -rf %t.d
// RUN: %kairo %s -fcxx-implicit-conv -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 31
// Under an explicit -fimplicit-conv, initialisation, assignment and
// return of a C++ class take ONE C++ user-defined conversion, as a call
// argument does: a string literal through a converting constructor
// (View(const char*), std::string's defaulted-allocator one), a C++ class
// through a converting constructor (A to B) or a conversion operator (D to C).
ffi "c++" import "cxx_user_conversion.h"
ffi "c++" import "string"

fn mk() -> View {
    return "abcd"
}

fn mks() -> cxx::std::string {
    return "xyz"
}

fn conv() -> B {
    var a = A(5)
    return a
}

fn main() -> i32 {
    var v: View = "hello"
    var n = len(v)
    v = "hi"
    n += len(v)
    n += len(mk())
    var a = A(3)
    var b: B = a
    n += take(b)
    var d = D(4)
    var c: C = d
    n += takec(c)
    var s: cxx::std::string = "abc"
    s = "x"
    n += (s.size() as i32) + (mks().size() as i32)
    n += take(conv())
    return n
}
