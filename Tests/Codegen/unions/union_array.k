union Bits {
    var i: i32
    var f: f32
}

fn main() -> i32 {
    var a: [Bits; 3]
    a[0].i = 1
    a[1].f = 2.5
    a[2].i = 3
    if a[0].i == 1 { return 1 }
    if a[1].f != 2.5 { return 2 }
    if a[2].i != 3 { return 3 }
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
// SEMA: ===== SEMA fid {{[0-9]+}}: {{.*}}unions/union_array.k =====
// SEMA: -- scope symbol tables (what each scope declares) --
// SEMA-NEXT:   <tu>   [2 name(s)]
// SEMA-NEXT:     Bits        -> union Bits @ 1:1
// SEMA-NEXT:     main        -> fn main @ 6:1
// SEMA-NEXT:   <tu>::Bits   [2 name(s)]
// SEMA-NEXT:     i           -> field i @ 2:5
// SEMA-NEXT:     f           -> field f @ 3:5
// SEMA-NEXT: -- multi-decl names (overload sets / redecl chains) --
// SEMA: -- name bindings --
// SEMA-NEXT:   <tu>::main
// SEMA-NEXT:     a           @ 8:5      -> var a @ 7:5  [local frame 0]
// SEMA-NEXT:     .i          @ 8:10     -> field i @ 2:5
// SEMA-NEXT:     a           @ 9:5      -> var a @ 7:5  [local frame 0]
// SEMA-NEXT:     .f          @ 9:10     -> field f @ 3:5
// SEMA-NEXT:     a           @ 10:5     -> var a @ 7:5  [local frame 0]
// SEMA-NEXT:     .i          @ 10:10    -> field i @ 2:5
// SEMA-NEXT:     a           @ 11:8     -> var a @ 7:5  [local frame 0]
// SEMA-NEXT:     .i          @ 11:13    -> field i @ 2:5
// SEMA-NEXT:     a           @ 12:8     -> var a @ 7:5  [local frame 0]
// SEMA-NEXT:     .f          @ 12:13    -> field f @ 3:5
// SEMA-NEXT:     a           @ 13:8     -> var a @ 7:5  [local frame 0]
// SEMA-NEXT:     .i          @ 13:13    -> field i @ 2:5
// SEMA-NEXT: -- expression types --
// SEMA-NEXT:   <tu>::main
// SEMA-NEXT:     IntegerLiteralExpr      @ 7:19     : <no type: callable/type/module>
// SEMA-NEXT:     AssignOperatorExpr      @ 8:5      : i32
// SEMA-NEXT:     ChainExpr               @ 8:5      : i32
// SEMA-NEXT:     SubscriptExpr           @ 8:5      : Bits
// SEMA-NEXT:     NamedIdentExpr          @ 8:5      : [Bits; 3]
// SEMA-NEXT:     IntegerLiteralExpr      @ 8:7      : usize
// SEMA-NEXT:     IntegerLiteralExpr      @ 8:14     : i32
// SEMA-NEXT:     AssignOperatorExpr      @ 9:5      : f32
// SEMA-NEXT:     ChainExpr               @ 9:5      : f32
// SEMA-NEXT:     SubscriptExpr           @ 9:5      : Bits
// SEMA-NEXT:     NamedIdentExpr          @ 9:5      : [Bits; 3]
// SEMA-NEXT:     IntegerLiteralExpr      @ 9:7      : usize
// SEMA-NEXT:     FloatingLiteralExpr     @ 9:14     : f32
// SEMA-NEXT:     AssignOperatorExpr      @ 10:5     : i32
// SEMA-NEXT:     ChainExpr               @ 10:5     : i32
// SEMA-NEXT:     SubscriptExpr           @ 10:5     : Bits
// SEMA-NEXT:     NamedIdentExpr          @ 10:5     : [Bits; 3]
// SEMA-NEXT:     IntegerLiteralExpr      @ 10:7     : usize
// SEMA-NEXT:     IntegerLiteralExpr      @ 10:14    : i32
// SEMA-NEXT:     BinaryOperatorExpr      @ 11:8     : bool
// SEMA-NEXT:     ChainExpr               @ 11:8     : i32
// SEMA-NEXT:     SubscriptExpr           @ 11:8     : Bits
// SEMA-NEXT:     NamedIdentExpr          @ 11:8     : [Bits; 3]
// SEMA-NEXT:     IntegerLiteralExpr      @ 11:10    : usize
// SEMA-NEXT:     IntegerLiteralExpr      @ 11:18    : i32
// SEMA-NEXT:     IntegerLiteralExpr      @ 11:29    : i32
// SEMA-NEXT:     BinaryOperatorExpr      @ 12:8     : bool
// SEMA-NEXT:     ChainExpr               @ 12:8     : f32
// SEMA-NEXT:     SubscriptExpr           @ 12:8     : Bits
// SEMA-NEXT:     NamedIdentExpr          @ 12:8     : [Bits; 3]
// SEMA-NEXT:     IntegerLiteralExpr      @ 12:10    : usize
// SEMA-NEXT:     FloatingLiteralExpr     @ 12:18    : f32
// SEMA-NEXT:     IntegerLiteralExpr      @ 12:31    : i32
// SEMA-NEXT:     BinaryOperatorExpr      @ 13:8     : bool
// SEMA-NEXT:     ChainExpr               @ 13:8     : i32
// SEMA-NEXT:     SubscriptExpr           @ 13:8     : Bits
// SEMA-NEXT:     NamedIdentExpr          @ 13:8     : [Bits; 3]
// SEMA-NEXT:     IntegerLiteralExpr      @ 13:10    : usize
// SEMA-NEXT:     IntegerLiteralExpr      @ 13:18    : i32
// SEMA-NEXT:     IntegerLiteralExpr      @ 13:29    : i32
// SEMA-NEXT:     IntegerLiteralExpr      @ 14:12    : i32
// SEMA-NEXT:   40 typed, 0 unknown, 0 errored
// SEMA-NEXT: -- inferred decls --
// SEMA-NEXT:   (none: every declaration wrote its own type)
// SEMA-NEXT: -- interface composition --
// SEMA-NEXT: -- types --
// END-GENERATED-CHECKS(SEMA)

// BEGIN-GENERATED-CHECKS(LOWERED) mode=lowered -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-lowered 2>/dev/null || true; } | %FileCheck %s --check-prefix=LOWERED
// LOWERED: ===== SEMA fid {{[0-9]+}}: {{.*}}unions/union_array.k =====
// LOWERED: -- scope symbol tables (what each scope declares) --
// LOWERED-NEXT:   <tu>   [2 name(s)]
// LOWERED-NEXT:     Bits        -> union Bits @ 1:1
// LOWERED-NEXT:     main        -> fn main @ 6:1
// LOWERED-NEXT:   <tu>::Bits   [2 name(s)]
// LOWERED-NEXT:     i           -> field i @ 2:5
// LOWERED-NEXT:     f           -> field f @ 3:5
// LOWERED-NEXT: -- multi-decl names (overload sets / redecl chains) --
// LOWERED: -- name bindings --
// LOWERED-NEXT:   <tu>::main
// LOWERED-NEXT:     a           @ 8:5      -> var a @ 7:5  [local frame 0]
// LOWERED-NEXT:     .i          @ 8:10     -> field i @ 2:5
// LOWERED-NEXT:     a           @ 9:5      -> var a @ 7:5  [local frame 0]
// LOWERED-NEXT:     .f          @ 9:10     -> field f @ 3:5
// LOWERED-NEXT:     a           @ 10:5     -> var a @ 7:5  [local frame 0]
// LOWERED-NEXT:     .i          @ 10:10    -> field i @ 2:5
// LOWERED-NEXT:     a           @ 11:8     -> var a @ 7:5  [local frame 0]
// LOWERED-NEXT:     .i          @ 11:13    -> field i @ 2:5
// LOWERED-NEXT:     a           @ 12:8     -> var a @ 7:5  [local frame 0]
// LOWERED-NEXT:     .f          @ 12:13    -> field f @ 3:5
// LOWERED-NEXT:     a           @ 13:8     -> var a @ 7:5  [local frame 0]
// LOWERED-NEXT:     .i          @ 13:13    -> field i @ 2:5
// LOWERED-NEXT: -- expression types --
// LOWERED-NEXT:   <tu>::main
// LOWERED-NEXT:     IntegerLiteralExpr      @ 7:19     : <no type: callable/type/module>
// LOWERED-NEXT:     AssignOperatorExpr      @ 8:5      : i32
// LOWERED-NEXT:     ChainExpr               @ 8:5      : i32
// LOWERED-NEXT:     SubscriptExpr           @ 8:5      : Bits
// LOWERED-NEXT:     NamedIdentExpr          @ 8:5      : [Bits; 3]
// LOWERED-NEXT:     IntegerLiteralExpr      @ 8:7      : usize
// LOWERED-NEXT:     IntegerLiteralExpr      @ 8:14     : i32
// LOWERED-NEXT:     AssignOperatorExpr      @ 9:5      : f32
// LOWERED-NEXT:     ChainExpr               @ 9:5      : f32
// LOWERED-NEXT:     SubscriptExpr           @ 9:5      : Bits
// LOWERED-NEXT:     NamedIdentExpr          @ 9:5      : [Bits; 3]
// LOWERED-NEXT:     IntegerLiteralExpr      @ 9:7      : usize
// LOWERED-NEXT:     FloatingLiteralExpr     @ 9:14     : f32
// LOWERED-NEXT:     AssignOperatorExpr      @ 10:5     : i32
// LOWERED-NEXT:     ChainExpr               @ 10:5     : i32
// LOWERED-NEXT:     SubscriptExpr           @ 10:5     : Bits
// LOWERED-NEXT:     NamedIdentExpr          @ 10:5     : [Bits; 3]
// LOWERED-NEXT:     IntegerLiteralExpr      @ 10:7     : usize
// LOWERED-NEXT:     IntegerLiteralExpr      @ 10:14    : i32
// LOWERED-NEXT:     BinaryOperatorExpr      @ 11:8     : bool
// LOWERED-NEXT:     ChainExpr               @ 11:8     : i32
// LOWERED-NEXT:     SubscriptExpr           @ 11:8     : Bits
// LOWERED-NEXT:     NamedIdentExpr          @ 11:8     : [Bits; 3]
// LOWERED-NEXT:     IntegerLiteralExpr      @ 11:10    : usize
// LOWERED-NEXT:     IntegerLiteralExpr      @ 11:18    : i32
// LOWERED-NEXT:     IntegerLiteralExpr      @ 11:29    : i32
// LOWERED-NEXT:     BinaryOperatorExpr      @ 12:8     : bool
// LOWERED-NEXT:     ChainExpr               @ 12:8     : f32
// LOWERED-NEXT:     SubscriptExpr           @ 12:8     : Bits
// LOWERED-NEXT:     NamedIdentExpr          @ 12:8     : [Bits; 3]
// LOWERED-NEXT:     IntegerLiteralExpr      @ 12:10    : usize
// LOWERED-NEXT:     FloatingLiteralExpr     @ 12:18    : f32
// LOWERED-NEXT:     IntegerLiteralExpr      @ 12:31    : i32
// LOWERED-NEXT:     BinaryOperatorExpr      @ 13:8     : bool
// LOWERED-NEXT:     ChainExpr               @ 13:8     : i32
// LOWERED-NEXT:     SubscriptExpr           @ 13:8     : Bits
// LOWERED-NEXT:     NamedIdentExpr          @ 13:8     : [Bits; 3]
// LOWERED-NEXT:     IntegerLiteralExpr      @ 13:10    : usize
// LOWERED-NEXT:     IntegerLiteralExpr      @ 13:18    : i32
// LOWERED-NEXT:     IntegerLiteralExpr      @ 13:29    : i32
// LOWERED-NEXT:     IntegerLiteralExpr      @ 14:12    : i32
// LOWERED-NEXT:   40 typed, 0 unknown, 0 errored
// LOWERED-NEXT: -- inferred decls --
// LOWERED-NEXT:   (none: every declaration wrote its own type)
// LOWERED-NEXT: -- interface composition --
// LOWERED-NEXT: -- types --
// END-GENERATED-CHECKS(LOWERED)

// BEGIN-GENERATED-CHECKS(EXEC) mode=run -- regenerate with Tests/gen_checks.py, do not hand-edit
// REQUIRES: clang
// RUN: rm -rf %t.exec.d
// RUN: %kairo %s -o %t.exec.exe --cache-dir %t.exec.d
// RUN: %t.exec.exe > %t.exec.out; test $? -eq 1
// RUN: test ! -s %t.exec.out
// END-GENERATED-CHECKS(EXEC)
