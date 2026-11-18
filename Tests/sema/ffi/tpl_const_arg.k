// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// A const template argument is part of the instance's identity: `W<i32>`
// and `W<const i32>` are two RecordType canonicals and two registry
// instances, as in C++. Before qualifiers entered the canonical they were
// one. Both fill, and each `.tag()` types from its own instance.

ffi "c++" import "tpl_const.h"

fn use_w() -> i32 {
    var a: W<i32>
    var b: W<const i32>
    return a.tag() + b.tag()
}

// DIAG-NOT: error

// SEMA:      member  .tag {{.*}} [member of W]  [filled by clang, 4 bytes, align 4]
// SEMA:      member  .tag {{.*}} [member of W]  [filled by clang, 4 bytes, align 4]
// SEMA:      NamedIdentExpr @ 14:12 : W<i32>
// SEMA:      NamedIdentExpr @ 14:22 : W<const i32>
// SEMA:      0 unknown, 0 errored
