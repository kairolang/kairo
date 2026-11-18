// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// A `typedef` and a `using` alias import as Kairo type aliases whose target
// is the builtin clang's type maps to (`int` -> i32, `double` -> f64), so
// they are usable in any type position and a literal takes the aliased type.

ffi "c++" import "using.h"

fn use_using() -> my_int {
    var r: Real = 1.5
    var a: my_int = 2
    return twice(a)
}

// DIAG-NOT: error

// SEMA:      use     twice  {{.*}} -> fn twice @ 8:1  [import overlay]
// SEMA:      -- expression types --
// SEMA:      FloatingLiteralExpr  {{.*}} : f64
// SEMA:      IntegerLiteralExpr  {{.*}} : i32
// SEMA:      CallExpr  {{.*}} : i32
// SEMA:      0 unknown, 0 errored
