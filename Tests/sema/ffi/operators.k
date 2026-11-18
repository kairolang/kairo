// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// C++ operators on an imported type, three ways:
//   a + a    MEMBER `V::operator+(const V&) const`: a V binds `const V&`.
//   2 * a    FREE `vm::operator*(int, const V&)`. The left operand is a
//            primitive, so only ADL through the RIGHT operand's namespace
//            can find it -- nothing here names `vm`.
//   -a       MEMBER unary.
//   a == b   FREE `vm::operator==`, ADL through either side.
// The typed rows below are in source order: +, *, unary -, ==.

ffi "c++" import "operators.h"

fn use_ops() {
    var a = make_v()
    var b = a + a
    var c = 2 * a
    var n = -a
    var e = a == b
}

// DIAG-NOT: error

// SEMA:      use     make_v  {{.*}} -> fn make_v @ 18:1  [import overlay]
// SEMA:      -- expression types --
// SEMA:      BinaryOperatorExpr  {{.*}} : V
// SEMA:      BinaryOperatorExpr  {{.*}} : V
// SEMA:      UnaryOperatorExpr  {{.*}} : V
// SEMA:      BinaryOperatorExpr  {{.*}} : bool
// SEMA:      0 unknown, 0 errored
