union <T, U> Either {
    var left: T
    var right: U
}

fn set_left(p: *Either<i32, f32>, v: i32) {
    p->left = v
}

fn main() -> i32 {
    var e: Either<i32, f32>
    set_left(&e, 11)
    if e.left != 11 { return 1 }
    return 0
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error [
// DIAG-NOT: warning [
// END-GENERATED-CHECKS(DIAG)

// BEGIN-GENERATED-CHECKS(SEMA) mode=sema -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA: ===== SEMA fid {{[0-9]+}}: {{.*}}unions/union_pointer.k =====
// SEMA: -- scope symbol tables (what each scope declares) --
// SEMA-NEXT:   <tu>   [3 name(s)]
// SEMA-NEXT:     Either      -> union Either @ 1:1
// SEMA-NEXT:     set_left    -> fn set_left @ 6:1
// SEMA-NEXT:     main        -> fn main @ 10:1
// SEMA-NEXT:   <tu>::Either   [2 name(s)]
// SEMA-NEXT:     left        -> field left @ 2:5
// SEMA-NEXT:     right       -> field right @ 3:5
// SEMA-NEXT: -- multi-decl names (overload sets / redecl chains) --
// SEMA: -- name bindings --
// SEMA-NEXT:   <tu>::set_left
// SEMA-NEXT:     p           @ 7:5      -> param p @ 6:13  [local frame 0]
// SEMA-NEXT:     ->left      @ 7:8      -> field left @ 2:5
// SEMA-NEXT:     v           @ 7:15     -> param v @ 6:35  [local frame 0]
// SEMA-NEXT:   <tu>::main
// SEMA-NEXT:     set_left    @ 12:5     -> fn set_left @ 6:1  [scope <tu>]
// SEMA-NEXT:     e           @ 12:15    -> var e @ 11:5  [local frame 0]
// SEMA-NEXT:     e           @ 13:8     -> var e @ 11:5  [local frame 0]
// SEMA-NEXT:     .left       @ 13:10    -> field left @ 2:5
// SEMA-NEXT: -- expression types --
// SEMA-NEXT:   <tu>::set_left
// SEMA-NEXT:     AssignOperatorExpr      @ 7:5      : i32
// SEMA-NEXT:     ChainExpr               @ 7:5      : i32
// SEMA-NEXT:     NamedIdentExpr          @ 7:5      : *Either<i32, f32>
// SEMA-NEXT:     NamedIdentExpr          @ 7:15     : i32
// SEMA-NEXT:   <tu>::main
// SEMA-NEXT:     CallExpr                @ 12:5     : void  [arg_map 0 1]
// SEMA-NEXT:     NamedIdentExpr          @ 12:5     : <no type: callable/type/module>
// SEMA-NEXT:     UnaryOperatorExpr       @ 12:14    : *Either<i32, f32>
// SEMA-NEXT:     NamedIdentExpr          @ 12:15    : Either<i32, f32>
// SEMA-NEXT:     IntegerLiteralExpr      @ 12:18    : i32
// SEMA-NEXT:     BinaryOperatorExpr      @ 13:8     : bool
// SEMA-NEXT:     ChainExpr               @ 13:8     : i32
// SEMA-NEXT:     NamedIdentExpr          @ 13:8     : Either<i32, f32>
// SEMA-NEXT:     IntegerLiteralExpr      @ 13:18    : i32
// SEMA-NEXT:     IntegerLiteralExpr      @ 13:30    : i32
// SEMA-NEXT:     IntegerLiteralExpr      @ 14:12    : i32
// SEMA-NEXT:   14 typed, 0 unknown, 0 errored
// SEMA-NEXT: -- inferred decls --
// SEMA-NEXT:   (none: every declaration wrote its own type)
// SEMA-NEXT: -- interface composition --
// SEMA-NEXT: -- types --
// END-GENERATED-CHECKS(SEMA)

// BEGIN-GENERATED-CHECKS(LOWERED) mode=lowered -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-lowered 2>/dev/null || true; } | %FileCheck %s --check-prefix=LOWERED
// LOWERED: ===== SEMA fid {{[0-9]+}}: {{.*}}unions/union_pointer.k =====
// LOWERED: -- scope symbol tables (what each scope declares) --
// LOWERED-NEXT:   <tu>   [3 name(s)]
// LOWERED-NEXT:     Either      -> union Either @ 1:1
// LOWERED-NEXT:     set_left    -> fn set_left @ 6:1
// LOWERED-NEXT:     main        -> fn main @ 10:1
// LOWERED-NEXT:   <tu>::Either   [2 name(s)]
// LOWERED-NEXT:     left        -> field left @ 2:5
// LOWERED-NEXT:     right       -> field right @ 3:5
// LOWERED-NEXT: -- multi-decl names (overload sets / redecl chains) --
// LOWERED: -- name bindings --
// LOWERED-NEXT:   <tu>::set_left
// LOWERED-NEXT:     p           @ 7:5      -> param p @ 6:13  [local frame 0]
// LOWERED-NEXT:     ->left      @ 7:8      -> field left @ 2:5
// LOWERED-NEXT:     v           @ 7:15     -> param v @ 6:35  [local frame 0]
// LOWERED-NEXT:   <tu>::main
// LOWERED-NEXT:     set_left    @ 12:5     -> fn set_left @ 6:1  [scope <tu>]
// LOWERED-NEXT:     e           @ 12:15    -> var e @ 11:5  [local frame 0]
// LOWERED-NEXT:     e           @ 13:8     -> var e @ 11:5  [local frame 0]
// LOWERED-NEXT:     .left       @ 13:10    -> field left @ 2:5
// LOWERED-NEXT: -- expression types --
// LOWERED-NEXT:   <tu>::set_left
// LOWERED-NEXT:     AssignOperatorExpr      @ 7:5      : i32
// LOWERED-NEXT:     ChainExpr               @ 7:5      : i32
// LOWERED-NEXT:     NamedIdentExpr          @ 7:5      : *Either<i32, f32>
// LOWERED-NEXT:     NamedIdentExpr          @ 7:15     : i32
// LOWERED-NEXT:   <tu>::main
// LOWERED-NEXT:     CallExpr                @ 12:5     : void
// LOWERED-NEXT:     NamedIdentExpr          @ 12:5     : <no type: callable/type/module>
// LOWERED-NEXT:     UnaryOperatorExpr       @ 12:14    : *Either<i32, f32>
// LOWERED-NEXT:     NamedIdentExpr          @ 12:15    : Either<i32, f32>
// LOWERED-NEXT:     IntegerLiteralExpr      @ 12:18    : i32
// LOWERED-NEXT:     BinaryOperatorExpr      @ 13:8     : bool
// LOWERED-NEXT:     ChainExpr               @ 13:8     : i32
// LOWERED-NEXT:     NamedIdentExpr          @ 13:8     : Either<i32, f32>
// LOWERED-NEXT:     IntegerLiteralExpr      @ 13:18    : i32
// LOWERED-NEXT:     IntegerLiteralExpr      @ 13:30    : i32
// LOWERED-NEXT:     IntegerLiteralExpr      @ 14:12    : i32
// LOWERED-NEXT:   14 typed, 0 unknown, 0 errored
// LOWERED-NEXT: -- inferred decls --
// LOWERED-NEXT:   (none: every declaration wrote its own type)
// LOWERED-NEXT: -- interface composition --
// LOWERED-NEXT: -- types --
// END-GENERATED-CHECKS(LOWERED)

// BEGIN-GENERATED-CHECKS(EXEC) mode=run -- regenerate with Tests/gen_checks.py, do not hand-edit
// REQUIRES: clang
// RUN: rm -rf %t.exec.d
// RUN: %kairo %s -o %t.exec.exe --cache-dir %t.exec.d
// RUN: %t.exec.exe > %t.exec.out; test $? -eq 0
// RUN: test ! -s %t.exec.out
// END-GENERATED-CHECKS(EXEC)
