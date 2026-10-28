// Tests/Codegen/unions/generic_reinterpret.k
// build: kairo generic_reinterpret.k   (expect exit 0)
// Generic head, `template <class A, class B> union Reinterpret`.

union <A, B> Reinterpret {
    var a: A
    var b: B
}

fn main() -> i32 {
    var r: Reinterpret<f32, u32>
    r.a = 1.0
    if r.b == 0x3F800000 { return 0 }
    return 1
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error [
// DIAG-NOT: warning [
// END-GENERATED-CHECKS(DIAG)

// BEGIN-GENERATED-CHECKS(SEMA) mode=sema -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA: ===== SEMA fid {{[0-9]+}}: {{.*}}unions/generic_reinterpret.k =====
// SEMA: -- scope symbol tables (what each scope declares) --
// SEMA-NEXT:   <tu>   [2 name(s)]
// SEMA-NEXT:     Reinterpret -> union Reinterpret @ 5:1
// SEMA-NEXT:     main        -> fn main @ 10:1
// SEMA-NEXT:   <tu>::Reinterpret   [2 name(s)]
// SEMA-NEXT:     a           -> field a @ 6:5
// SEMA-NEXT:     b           -> field b @ 7:5
// SEMA-NEXT: -- multi-decl names (overload sets / redecl chains) --
// SEMA: -- name bindings --
// SEMA-NEXT:   <tu>::main
// SEMA-NEXT:     r           @ 12:5     -> var r @ 11:5  [local frame 0]
// SEMA-NEXT:     .a          @ 12:7     -> field a @ 6:5
// SEMA-NEXT:     r           @ 13:8     -> var r @ 11:5  [local frame 0]
// SEMA-NEXT:     .b          @ 13:10    -> field b @ 7:5
// SEMA-NEXT: -- expression types --
// SEMA-NEXT:   <tu>::main
// SEMA-NEXT:     AssignOperatorExpr      @ 12:5     : f32
// SEMA-NEXT:     ChainExpr               @ 12:5     : f32
// SEMA-NEXT:     NamedIdentExpr          @ 12:5     : Reinterpret<f32, u32>
// SEMA-NEXT:     FloatingLiteralExpr     @ 12:11    : f32
// SEMA-NEXT:     BinaryOperatorExpr      @ 13:8     : bool
// SEMA-NEXT:     ChainExpr               @ 13:8     : u32
// SEMA-NEXT:     NamedIdentExpr          @ 13:8     : Reinterpret<f32, u32>
// SEMA-NEXT:     IntegerLiteralExpr      @ 13:15    : u32
// SEMA-NEXT:     IntegerLiteralExpr      @ 13:35    : i32
// SEMA-NEXT:     IntegerLiteralExpr      @ 14:12    : i32
// SEMA-NEXT:   10 typed, 0 unknown, 0 errored
// SEMA-NEXT: -- inferred decls --
// SEMA-NEXT:   (none: every declaration wrote its own type)
// SEMA-NEXT: -- types --
// END-GENERATED-CHECKS(SEMA)

// BEGIN-GENERATED-CHECKS(LOWERED) mode=lowered -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-lowered 2>/dev/null || true; } | %FileCheck %s --check-prefix=LOWERED
// LOWERED: ===== SEMA fid {{[0-9]+}}: {{.*}}unions/generic_reinterpret.k =====
// LOWERED: -- scope symbol tables (what each scope declares) --
// LOWERED-NEXT:   <tu>   [2 name(s)]
// LOWERED-NEXT:     Reinterpret -> union Reinterpret @ 5:1
// LOWERED-NEXT:     main        -> fn main @ 10:1
// LOWERED-NEXT:   <tu>::Reinterpret   [2 name(s)]
// LOWERED-NEXT:     a           -> field a @ 6:5
// LOWERED-NEXT:     b           -> field b @ 7:5
// LOWERED-NEXT: -- multi-decl names (overload sets / redecl chains) --
// LOWERED: -- name bindings --
// LOWERED-NEXT:   <tu>::main
// LOWERED-NEXT:     r           @ 12:5     -> var r @ 11:5  [local frame 0]
// LOWERED-NEXT:     .a          @ 12:7     -> field a @ 6:5
// LOWERED-NEXT:     r           @ 13:8     -> var r @ 11:5  [local frame 0]
// LOWERED-NEXT:     .b          @ 13:10    -> field b @ 7:5
// LOWERED-NEXT: -- expression types --
// LOWERED-NEXT:   <tu>::main
// LOWERED-NEXT:     AssignOperatorExpr      @ 12:5     : f32
// LOWERED-NEXT:     ChainExpr               @ 12:5     : f32
// LOWERED-NEXT:     NamedIdentExpr          @ 12:5     : Reinterpret<f32, u32>
// LOWERED-NEXT:     FloatingLiteralExpr     @ 12:11    : f32
// LOWERED-NEXT:     BinaryOperatorExpr      @ 13:8     : bool
// LOWERED-NEXT:     ChainExpr               @ 13:8     : u32
// LOWERED-NEXT:     NamedIdentExpr          @ 13:8     : Reinterpret<f32, u32>
// LOWERED-NEXT:     IntegerLiteralExpr      @ 13:15    : u32
// LOWERED-NEXT:     IntegerLiteralExpr      @ 13:35    : i32
// LOWERED-NEXT:     IntegerLiteralExpr      @ 14:12    : i32
// LOWERED-NEXT:   10 typed, 0 unknown, 0 errored
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
