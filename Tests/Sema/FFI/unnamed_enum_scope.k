// An UNNAMED C++ enum's enumerators are found in its enclosing scope, as
// C++ finds them (`clang::diag::err_incomplete_type` is one of an unnamed
// enum in namespace clang::diag). They were "no member named ... in
// module 'diag'" because an unnamed enum got no Kairo decl at all.

ffi "c++" import "unnamed_enum_scope.h"

fn main() -> i32 {
    var a = ue::diag::err_b
    var b = ue::diag::Sub::s_x
    var c = UC::k_b
    // Unnamed enums inside templates must not collide on one USR.
    var t: UT<3>
    var u: UP<i32>
    return (a as i32) + (c as i32)
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
// CHECK-NOT: R025E
// CHECK-NOT: no member named
