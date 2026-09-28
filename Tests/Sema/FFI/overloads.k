// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// Overload resolution over imported C++ signatures, through a BARE import.
//
//   pick(i) / pick(f)   two overloads; the argument's type picks, and the
//                       typed rows show which (i32 vs f64 result).
//   with_default(i)     `int b = 2` in the header: the default EXPRESSION is
//                       not imported, but its presence is (has_default), so
//                       one argument is enough.
//   sum_all(3, i, f, 7) C `...`: arguments past the declared one are taken
//                       unchecked, a literal there gets its default type.
//   f as Wrap           converting ctor Wrap(double).
//   i as Wrap           Wrap(int) is `explicit`, so it is NOT a converting
//                       ctor; the i32 reaches Wrap(double) instead.
//   i as Only           Only's one ctor is `explicit`: no conversion at all.
//                       The only error in this file.

ffi "c++" import "overloads.h"

fn use_overloads() -> i32 {
    var i: i32 = 1
    var f: f64 = 1.5
    var a = pick(i)
    var b = pick(f)
    var c = with_default(i)
    var d = sum_all(3, i, f, 7)
    var w = f as Wrap
    var e = i as Wrap
    var o = i as Only
    return a + c + d
}

// DIAG:     error [SC027E]: no conversion from 'i32' to 'Only'
// DIAG-NOT: error

// SEMA:      use     pick  {{.*}} -> 2 candidate(s), deferred to overload resolution  [import overlay]
// SEMA:      use     with_default  {{.*}} -> fn with_default @ 8:1  [import overlay]
// SEMA:      use     sum_all  {{.*}} -> fn sum_all @ 10:1  [import overlay]
// SEMA:      -- expression types --
// SEMA:      CallExpr  {{.*}} : i32
// SEMA:      CallExpr  {{.*}} : f64
// SEMA:      CallExpr  {{.*}} : i32
// SEMA:      CallExpr  {{.*}} : i32
// SEMA:      TypeCastExpr  {{.*}} : Wrap
// SEMA:      TypeCastExpr  {{.*}} : Wrap
// SEMA:      1 errored
