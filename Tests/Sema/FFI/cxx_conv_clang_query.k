// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=NOFLAG
// RUN: rm -rf %t.d
// RUN: %kairo %s -fimplicit-conv -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 24
// P825: with -fimplicit-conv the C++ user-defined conversion at a C++ call
// is clang's verdict, so it finds a converting constructor with a
// defaulted trailing parameter (std::string's from a literal) and a
// constructor template (fmt::string_view's from std::string_view).
// P827: a C++ function declared `auto` is typed by what clang deduces.
// Without the flag the conversions stay SC063E.
// NOFLAG: error [SC063E]: no matching overload for call to 'slen'
// NOFLAG: error [SC063E]: no matching overload for call to 'vlen'
ffi "c++" import "cxx_conv_clang_query.h"

fn main() -> i32 {
    var n = slen("hello")
    var v = view("abcd")
    n += vlen(v)
    n += make_node(3).get()
    var h = make_holder(5)
    n += h.value()
    n += twice(3)
    return n
}
