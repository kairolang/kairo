union <T, U> Either {
    var left: T
    var right: U
}


fn main() -> i32 {
    var e: Either<i32, f32>
    e.left = 42
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
// SEMA: ===== SEMA fid {{[0-9]+}}: {{.*}}unions/generic_union.k =====
// SEMA: -- scope symbol tables (what each scope declares) --
// SEMA-NEXT:   <tu>   [2 name(s)]
// SEMA-NEXT:     Either      -> union Either @ 1:1
// SEMA-NEXT:     main        -> fn main @ 7:1
// SEMA-NEXT:   <tu>::Either   [2 name(s)]
// SEMA-NEXT:     left        -> field left @ 2:5
// SEMA-NEXT:     right       -> field right @ 3:5
// SEMA-NEXT: -- multi-decl names (overload sets / redecl chains) --
// SEMA: -- name bindings --
// SEMA-NEXT:   <tu>::main
// SEMA-NEXT:     e           @ 9:5      -> var e @ 8:5  [local frame 0]
// SEMA-NEXT:     .left       @ 9:7      -> field left @ 2:5
// SEMA-NEXT: -- expression types --
// SEMA-NEXT:   <tu>::main
// SEMA-NEXT:     AssignOperatorExpr      @ 9:5      : i32
// SEMA-NEXT:     ChainExpr               @ 9:5      : i32
// SEMA-NEXT:     NamedIdentExpr          @ 9:5      : Either<i32, f32>
// SEMA-NEXT:     IntegerLiteralExpr      @ 9:14     : i32
// SEMA-NEXT:     IntegerLiteralExpr      @ 10:12    : i32
// SEMA-NEXT:   5 typed, 0 unknown, 0 errored
// SEMA-NEXT: -- inferred decls --
// SEMA-NEXT:   (none: every declaration wrote its own type)
// SEMA-NEXT: -- types --
// END-GENERATED-CHECKS(SEMA)

// BEGIN-GENERATED-CHECKS(LOWERED) mode=lowered -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-lowered 2>/dev/null || true; } | %FileCheck %s --check-prefix=LOWERED
// LOWERED: ===== SEMA fid {{[0-9]+}}: {{.*}}unions/generic_union.k =====
// LOWERED: -- scope symbol tables (what each scope declares) --
// LOWERED-NEXT:   <tu>   [2 name(s)]
// LOWERED-NEXT:     Either      -> union Either @ 1:1
// LOWERED-NEXT:     main        -> fn main @ 7:1
// LOWERED-NEXT:   <tu>::Either   [2 name(s)]
// LOWERED-NEXT:     left        -> field left @ 2:5
// LOWERED-NEXT:     right       -> field right @ 3:5
// LOWERED-NEXT: -- multi-decl names (overload sets / redecl chains) --
// LOWERED: -- name bindings --
// LOWERED-NEXT:   <tu>::main
// LOWERED-NEXT:     e           @ 9:5      -> var e @ 8:5  [local frame 0]
// LOWERED-NEXT:     .left       @ 9:7      -> field left @ 2:5
// LOWERED-NEXT: -- expression types --
// LOWERED-NEXT:   <tu>::main
// LOWERED-NEXT:     AssignOperatorExpr      @ 9:5      : i32
// LOWERED-NEXT:     ChainExpr               @ 9:5      : i32
// LOWERED-NEXT:     NamedIdentExpr          @ 9:5      : Either<i32, f32>
// LOWERED-NEXT:     IntegerLiteralExpr      @ 9:14     : i32
// LOWERED-NEXT:     IntegerLiteralExpr      @ 10:12    : i32
// LOWERED-NEXT:   5 typed, 0 unknown, 0 errored
// LOWERED-NEXT: -- inferred decls --
// LOWERED-NEXT:   (none: every declaration wrote its own type)
// LOWERED-NEXT: -- types --
// END-GENERATED-CHECKS(LOWERED)

// BEGIN-GENERATED-CHECKS(EXEC) mode=run -- regenerate with Tests/gen_checks.py, do not hand-edit
// REQUIRES: clang
// RUN: rm -rf %t.exec.d
// RUN: %kairo %s -o %t.exec.exe --cache-dir %t.exec.d
// RUN: %t.exec.exe > %t.exec.out; test $? -eq 0
// RUN: test ! -s %t.exec.out
// END-GENERATED-CHECKS(EXEC)
