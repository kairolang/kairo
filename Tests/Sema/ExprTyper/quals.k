// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// Qualifiers on values (ExprTyper). An lvalue keeps its cv: `*p` through a
// `*const i32` is a `const i32`, and its address is a `*const i32` again.
// A prvalue has none: the inferred slot of `var y = *p`, an arithmetic
// result and a branch join are all plain `i32`. An alias carries the cv it
// was written with, at the level it was written.
//
// NOT YET AN ERROR: `*p = 2` through a `*const i32`. Assignment through a
// const lvalue is ConstChecking's, which is still a stub; this change makes
// the qualifier visible, it does not start enforcing it.

type T = const *i32

fn quals(c: bool) {
    var x: i32 = 1
    var p: *const i32 = &x
    var y = *p
    var a = &(*p)
    var s = *p + 1
    var j = if c => *p else => x
    var t: T = &x
    *p = 2
    const k: i32 = 1
    var pc = &k
    var sc = k + 1
}

// DIAG-NOT: error

// An lvalue keeps its cv, and so does its address.
// SEMA:      UnaryOperatorExpr @ 19:13 : const i32
// SEMA:      UnaryOperatorExpr @ 20:13 : *const i32
// SEMA-NEXT: UnaryOperatorExpr @ 20:15 : const i32
// A prvalue has none.
// SEMA:      BinaryOperatorExpr @ 21:13 : i32
// SEMA:      IfExpr @ 22:13 : i32
// SEMA:      0 unknown, 0 errored
// SEMA:      -- inferred decls --
// SEMA-NEXT: y : i32
// SEMA-NEXT: a : *const i32
// SEMA-NEXT: s : i32
// SEMA-NEXT: j : i32
// A `const` binding is a const object: its address is `*const i32`, and a
// value read from it is plain `i32`.
// SEMA-NEXT: pc : *const i32
// SEMA-NEXT: sc : i32
