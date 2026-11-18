// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// A function template constrained by a C++20 concept. It imports as a Kairo
// generic whose parameter type is the template's own `T` (a canonical
// parameter found by depth, not an opaque type), so deduction binds T from
// the argument and the call types as i32. The concept itself is a
// constraint-only interface; it is not checked here.

ffi "c++" import "concept.h"

fn use_concept() -> i32 {
    var x: i32 = 2
    return add_twice(x)
}

// DIAG-NOT: error

// SEMA:      use     add_twice  {{.*}} -> fn add_twice @ 8:1  [import overlay]
// SEMA:      -- expression types --
// SEMA:      CallExpr  {{.*}} : i32
// SEMA:      0 unknown, 0 errored
