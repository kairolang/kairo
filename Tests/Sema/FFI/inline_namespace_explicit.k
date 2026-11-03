// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 14
//
// A C++ inline namespace may be named explicitly: `ns::v1::F` is the same
// entity as `ns::F` (libc++'s `std::__1::`). Its members were bound only
// in the parent's table, so the explicit step was R025E "no member named
// 'F' in module 'v1'". inline_namespace_explicit_errors.k: a name the
// inline namespace does not declare is still not found through it.

ffi "c++" import "inline_namespace_explicit.h"

fn main() -> i32 {
    var a: ns::v1::F
    var b: ns::F
    var h: ns::H
    // 4 + 4 + 3 + 3 = 14
    return a.x + b.x + ns::v1::g() + ns::g() + h.y - 1
}

// DIAG-NOT: error
