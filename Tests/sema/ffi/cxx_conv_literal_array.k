// With -fimplicit-conv a string literal reaching a C++ class through
// a converting constructor TEMPLATE on `const char (&)[N]` (fmt's
// format_string shape) is not SC063E: clang is not asked about the literal as
// `const char*`, from which N cannot be deduced. It is asked with the
// literal's C++ type, an lvalue `const char[N]` (bytes plus terminator),
// at a call argument and at initialisation; the pointer-taking
// constructors still see it through the decay.

ffi "c++" import "cxx_conv_literal_array.h"

fn main() -> i32 {
    var n = flen("hello")       // 5
    var f: fstr = "ab\n"        // 3: escapes count as their bytes
    n += f.n
    return n
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d
// RUN: %kairo %s -fcxx-implicit-conv -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 8
