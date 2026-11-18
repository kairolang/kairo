// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// C++ operators the importer and operator lookup have to find the way C++
// does (corpus: op_lookup.h). One line per rule, each typed below:
//   tpl != tpl    a free operator template, bound under its operator name
//   ord == ord    two exact templates, the more specialized one chosen
//   ord != ord    no viable `!=` in scope: C++20's `!(a == b)`
//   fwd <  fwd    the class forward-declared in another header
//   hid == hid    a hidden friend
//   *d / ++d      a member `operator*` / `operator++` on an imported record

ffi "c++" import "op_lookup.h"

fn use_ops() -> i32 {
    var a = ol::tpl(1) != ol::tpl(2)
    var b = ol::ord(1) == ol::ord(2)
    var c = ol::ord(1) != ol::ord(2)
    var e = ol::fwd(1) < ol::fwd(2)
    var f = ol::hid(1) == ol::hid(2)
    var d = ol::deref(3)
    ++d
    var g: i32 = *d
    return g
}

// DIAG-NOT: error

// SEMA:      -- expression types --
// SEMA:      BinaryOperatorExpr  {{.*}} : bool
// SEMA:      BinaryOperatorExpr  {{.*}} : bool
// SEMA:      BinaryOperatorExpr  {{.*}} : bool
// SEMA:      BinaryOperatorExpr  {{.*}} : bool
// SEMA:      BinaryOperatorExpr  {{.*}} : bool
// SEMA:      UnaryOperatorExpr  {{.*}} : Deref&
// SEMA:      UnaryOperatorExpr  {{.*}} : i32&
