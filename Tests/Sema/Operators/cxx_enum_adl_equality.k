// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 3
//
// `==` / `!=` on a C++ enum whose namespace also declares an `operator==`
// template for something else (llvm::sys::fs::file_type next to
// ArrayRef/ErrorOr's): ADL found that template, none of its candidates
// could take the enum, and the comparison failed with SC063E instead of
// falling back to the built-in comparison C++ itself would use, as in
// path comparison.

// DIAG-NOT: error

ffi "c++" import "cxx_enum_adl_equality.h"

type FT = ns::ft

fn main() -> i32 {
    var t: FT = ns::get()
    var r = 0
    if t == FT::b { r += 1 }
    if t != FT::a { r += 1 }
    if ns::get() == ns::ft::b { r += 1 }
    return r
}
