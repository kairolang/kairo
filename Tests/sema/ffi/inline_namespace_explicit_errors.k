// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
//
// `H` is declared in `ns`, not in its inline namespace `v1`, so naming it
// through `v1` is an error, as in C++.

ffi "c++" import "inline_namespace_explicit.h"

fn f() -> i32 {
    // CHECK: inline_namespace_explicit_errors.k:[[@LINE+1]]:{{[0-9]+}}: error [R025E]: no type named 'H'
    var h: ns::v1::H
    return 0
}
