// An f-string at script top level (no enclosing function) interpolating a
// C++ `std::string` variable, a plain integer passed on to an imported
// `const char*` parameter through `.c_str()`, and the result of a C++ member
// call type-checks without SC080E ("interpolation in a generic body needs a
// concrete type") and runs: the integer string has two bytes, the C++ call
// result prints as its value.

import std
import std::io
ffi "c++" import "<string>"
ffi "c++" import "<cstring>"

var s: cxx::std::string = cxx::std::string("hello")
var n: i32 = 42
var len: usize = strlen(f"{n}".c_str())
io::println(f"{len}")
var sz = f"{s.size()}"
io::println(sz)

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: SC080E
// DIAG-NOT: error
// RUN: rm -rf %t.d
// RUN: %kairo %s -O0 -o %t.exe --cache-dir %t.d/o0
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// RUN: rm -f %t.exe
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.d/o2
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// OUT: 2
// OUT-NEXT: 5
