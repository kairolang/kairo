// A C++ `T&` parameter is `@inout x: T` (c-cpp-calling.mdx,
// functions-parameter-modes.mdx): the argument is marked `&x` and binds by
// reference, a derived object binds a base `T&`, and nothing is moved.
// `pick(&x)` takes `int&` over `int*` (a safe `&x` is the marker),
// `pick(unsafe &x)` the pointer. std::getline's `istream&` overload takes
// a move-only istringstream by reference; its `istream&&` overload is not
// viable for a marked argument. None of these is SC063E ("cannot
// convert '*i32' to 'i32&'") or SC064E (getline ambiguous); a bare
// argument does not bind silently.

ffi "c++" import "cxx_lref_inout.h"
ffi "c++" import "sstream"
ffi "c++" import "string"

fn main() -> i32 {
    var x = 4
    inc(&x)                                   // x = 5, through int&
    var d = D()
    bump(&d)                                  // derived-to-base by reference: d.n = 10
    var r = pick(&x) * 10 + pick(unsafe &x)   // int&, then int*: 12
    var f = cxx::std::istringstream(cxx::std::string("ab\ncd\n"))
    var line = cxx::std::string()
    var lines = 0
    while cxx::std::getline(&f, &line) as bool { lines += 1 }   // f is borrowed, never moved
    // 5 + 10 + 12 + 2 = 29
    return x + d.n + r + lines
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// RUN: { %kairo %s --print-ir -o /dev/null 2>/dev/null || true; } | %FileCheck %s --check-prefix=IR
// IR: inc(x);
// IR: bump(d);
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 29
