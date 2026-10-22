// <vector> brings the standard library's <new> into this TU ahead of the
// classes, and lib.k's header is compiled with <vector> on either side of
// it: the derived `op =`'s placement `::new` must agree with the standard
// library's declaration of it whichever comes first.

ffi "c++" import "vector"
import lib::*

fn main() -> i32 {
    var a = C(1)
    var b = C(2)
    a = a
    a = b
    return a.v              // 12: b copied in once, through C's @copy
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang

// The TU: the header set, <new> included, is entered ahead of the stream.
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -c --cache-dir %t.d/k
// RUN: %clangxx %t.d/k/*.o %t.d/k/builtin/*.o %t.d/k/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 12

// The header: <new> first, then a C++ consumer's <vector> after it and
// before it, as C++20 and as C++26 (where the standard library's placement
// new is constexpr).
// RUN: rm -rf %t.h
// RUN: %kairo %s --type-check-only --emit-headers %t.h
// RUN: cat $(find %t.h -name lib.hh) | %FileCheck %s --check-prefix=HDR
// HDR:      #pragma once
// HDR-NEXT: #include <new>
// HDR:      C& operator=(const{{ ?}}::{{.*}}C& o) {
// RUN: %clangxx -std=c++20 -fsyntax-only -include $(find %t.h -name lib.hh) -include vector -x c++ - < /dev/null
// RUN: %clangxx -std=c++20 -fsyntax-only -include vector -include $(find %t.h -name lib.hh) -x c++ - < /dev/null
// RUN: %clangxx -std=c++2c -fsyntax-only -include $(find %t.h -name lib.hh) -include vector -x c++ - < /dev/null
// RUN: %clangxx -std=c++2c -fsyntax-only -include vector -include $(find %t.h -name lib.hh) -x c++ - < /dev/null
