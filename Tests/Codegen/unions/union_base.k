union Register {
    var as_u32: u32
    var as_bytes: [u8; 4]
    var as_f32: f32
}

fn main() -> i32 {
    var r: Register
    r.as_u32 = 0x3F800000
    return r.as_bytes[0] + r.as_bytes[3]
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error [
// DIAG-NOT: warning [
// END-GENERATED-CHECKS(DIAG)

// BEGIN-GENERATED-CHECKS(SEMA) mode=sema -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA: ===== SEMA fid {{[0-9]+}}: {{.*}}unions/union_base.k =====
// SEMA: -- scope symbol tables (what each scope declares) --
// SEMA-NEXT:   <tu>   [2 name(s)]
// SEMA-NEXT:     Register    -> union Register @ 1:1
// SEMA-NEXT:     main        -> fn main @ 7:1
// SEMA-NEXT:   <tu>::Register   [3 name(s)]
// SEMA-NEXT:     as_u32      -> field as_u32 @ 2:5
// SEMA-NEXT:     as_bytes    -> field as_bytes @ 3:5
// SEMA-NEXT:     as_f32      -> field as_f32 @ 4:5
// SEMA-NEXT: -- multi-decl names (overload sets / redecl chains) --
// SEMA: -- name bindings --
// SEMA-NEXT:   <tu>::main
// SEMA-NEXT:     r           @ 9:5      -> var r @ 8:5  [local frame 0]
// SEMA-NEXT:     .as_u32     @ 9:7      -> field as_u32 @ 2:5
// SEMA-NEXT:     r           @ 10:12    -> var r @ 8:5  [local frame 0]
// SEMA-NEXT:     .as_bytes   @ 10:14    -> field as_bytes @ 3:5
// SEMA-NEXT:     r           @ 10:28    -> var r @ 8:5  [local frame 0]
// SEMA-NEXT:     .as_bytes   @ 10:30    -> field as_bytes @ 3:5
// SEMA-NEXT: -- expression types --
// SEMA-NEXT:   <tu>::Register
// SEMA-NEXT:     IntegerLiteralExpr      @ 3:24     : <no type: callable/type/module>
// SEMA-NEXT:   <tu>::main
// SEMA-NEXT:     AssignOperatorExpr      @ 9:5      : u32
// SEMA-NEXT:     ChainExpr               @ 9:5      : u32
// SEMA-NEXT:     NamedIdentExpr          @ 9:5      : Register
// SEMA-NEXT:     IntegerLiteralExpr      @ 9:16     : u32
// SEMA-NEXT:     BinaryOperatorExpr      @ 10:12    : u8
// SEMA-NEXT:     SubscriptExpr           @ 10:12    : u8
// SEMA-NEXT:     ChainExpr               @ 10:12    : [u8; 4]
// SEMA-NEXT:     NamedIdentExpr          @ 10:12    : Register
// SEMA-NEXT:     IntegerLiteralExpr      @ 10:23    : usize
// SEMA-NEXT:     SubscriptExpr           @ 10:28    : u8
// SEMA-NEXT:     ChainExpr               @ 10:28    : [u8; 4]
// SEMA-NEXT:     NamedIdentExpr          @ 10:28    : Register
// SEMA-NEXT:     IntegerLiteralExpr      @ 10:39    : usize
// SEMA-NEXT:   13 typed, 0 unknown, 0 errored
// SEMA-NEXT: -- inferred decls --
// SEMA-NEXT:   (none: every declaration wrote its own type)
// SEMA-NEXT: -- interface composition --
// SEMA-NEXT: -- types --
// END-GENERATED-CHECKS(SEMA)

// BEGIN-GENERATED-CHECKS(LOWERED) mode=lowered -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-lowered 2>/dev/null || true; } | %FileCheck %s --check-prefix=LOWERED
// LOWERED: ===== SEMA fid {{[0-9]+}}: {{.*}}unions/union_base.k =====
// LOWERED: -- scope symbol tables (what each scope declares) --
// LOWERED-NEXT:   <tu>   [2 name(s)]
// LOWERED-NEXT:     Register    -> union Register @ 1:1
// LOWERED-NEXT:     main        -> fn main @ 7:1
// LOWERED-NEXT:   <tu>::Register   [3 name(s)]
// LOWERED-NEXT:     as_u32      -> field as_u32 @ 2:5
// LOWERED-NEXT:     as_bytes    -> field as_bytes @ 3:5
// LOWERED-NEXT:     as_f32      -> field as_f32 @ 4:5
// LOWERED-NEXT: -- multi-decl names (overload sets / redecl chains) --
// LOWERED: -- name bindings --
// LOWERED-NEXT:   <tu>::main
// LOWERED-NEXT:     r           @ 9:5      -> var r @ 8:5  [local frame 0]
// LOWERED-NEXT:     .as_u32     @ 9:7      -> field as_u32 @ 2:5
// LOWERED-NEXT:     r           @ 10:12    -> var r @ 8:5  [local frame 0]
// LOWERED-NEXT:     .as_bytes   @ 10:14    -> field as_bytes @ 3:5
// LOWERED-NEXT:     r           @ 10:28    -> var r @ 8:5  [local frame 0]
// LOWERED-NEXT:     .as_bytes   @ 10:30    -> field as_bytes @ 3:5
// LOWERED-NEXT: -- expression types --
// LOWERED-NEXT:   <tu>::Register
// LOWERED-NEXT:     IntegerLiteralExpr      @ 3:24     : <no type: callable/type/module>
// LOWERED-NEXT:   <tu>::main
// LOWERED-NEXT:     AssignOperatorExpr      @ 9:5      : u32
// LOWERED-NEXT:     ChainExpr               @ 9:5      : u32
// LOWERED-NEXT:     NamedIdentExpr          @ 9:5      : Register
// LOWERED-NEXT:     IntegerLiteralExpr      @ 9:16     : u32
// LOWERED-NEXT:     BinaryOperatorExpr      @ 10:12    : u8
// LOWERED-NEXT:     SubscriptExpr           @ 10:12    : u8
// LOWERED-NEXT:     ChainExpr               @ 10:12    : [u8; 4]
// LOWERED-NEXT:     NamedIdentExpr          @ 10:12    : Register
// LOWERED-NEXT:     IntegerLiteralExpr      @ 10:23    : usize
// LOWERED-NEXT:     SubscriptExpr           @ 10:28    : u8
// LOWERED-NEXT:     ChainExpr               @ 10:28    : [u8; 4]
// LOWERED-NEXT:     NamedIdentExpr          @ 10:28    : Register
// LOWERED-NEXT:     IntegerLiteralExpr      @ 10:39    : usize
// LOWERED-NEXT:   13 typed, 0 unknown, 0 errored
// LOWERED-NEXT: -- inferred decls --
// LOWERED-NEXT:   (none: every declaration wrote its own type)
// LOWERED-NEXT: -- interface composition --
// LOWERED-NEXT: -- types --
// END-GENERATED-CHECKS(LOWERED)

// BEGIN-GENERATED-CHECKS(EXEC) mode=run -- regenerate with Tests/gen_checks.py, do not hand-edit
// REQUIRES: clang
// RUN: rm -rf %t.exec.d
// RUN: %kairo %s -o %t.exec.exe --cache-dir %t.exec.d
// RUN: %t.exec.exe > %t.exec.out; test $? -eq 63
// RUN: test ! -s %t.exec.out
// END-GENERATED-CHECKS(EXEC)
