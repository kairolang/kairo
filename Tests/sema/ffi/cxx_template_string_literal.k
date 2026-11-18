// RUN: %kairo %s --type-check-only
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 3
// A string literal passed to a by-value parameter of a C++ function
// template deduced T as Kairo's builtin string; C++ deduces `const char *`
// from the decayed `const char[N]`. An int literal deduces int.
ffi "c++" import "cxx_template_string_literal.h"

fn main() -> i32 {
    return kind("abc") + ikind(42)
}
