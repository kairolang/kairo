// A using-declaration at namespace scope binds its target under the
// namespace too: a function from the global namespace, one from another
// namespace (overloading the namespace's own `f`), a typedef and a struct.
// None of these is R025E "no member named ... in module 'dst'".
// libc++'s <cmath> brings `std::sqrt` in the same way (`using ::sqrt;` and
// `using __math::sqrt;`); the arguments are typed because an untyped float
// literal ranks f32 and f64 alike, the rule for any such overload set.

ffi "c++" import "using_decl.h"
ffi "c++" import "cmath"

fn use_using() -> i32 {
    var w: dst::wide = 4
    var p: dst::Pt = dst::mk()
    return dst::glob(1) + dst::f(3) + dst::f(1, 2) + (w as i32) + p.x
}

fn sqrt_of(x: f64) -> f64 {
    return cxx::std::sqrt(x)
}

fn sqrt_of_f32(x: f32) -> f32 {
    return cxx::std::sqrt(x)
}

fn main() -> i32 {
    // 2 + 6 + 3 + 4 + 1, and sqrt(16) == 4
    if sqrt_of(16.0) != 4.0 { return 1 }
    if sqrt_of_f32(9.0) != 3.0 { return 2 }
    return use_using() - 16
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// DIAG-NOT: error
// SEMA:      member  ::mk  {{.*}} -> fn mk @ 11:5
// SEMA:      member  ::glob  {{.*}} -> fn glob @ 5:1
// SEMA:      member  ::f  {{.*}} -> 2 candidate(s), awaiting overload resolution  [member of dst]
// SEMA:      member  ::sqrt  {{.*}} -> {{[0-9]+}} candidate(s), awaiting overload resolution  [member of std]
// SEMA:      0 unknown, 0 errored
//
// REQUIRES: clang
// RUN: rm -rf %t.exec.d
// RUN: %kairo %s -o %t.exec.exe --cache-dir %t.exec.d
// RUN: %t.exec.exe
