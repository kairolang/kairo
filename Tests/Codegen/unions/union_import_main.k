import union_import_lib::*;

fn main() -> i32 {
    // Imported non-generic union, built by the lib.
    var b: Bits = make_bits(42)
    if b.i != 42 { return 1 }

    // Imported generic union: same instance the lib's left_of takes, so
    // both TUs reach Either<i32, f32> (extern template here, home there).
    var e: Either<i32, f32>
    e.left = 7
    if left_of(e) == 7 { return 2 }

    // An instance only this TU names.
    var g: Either<u8, i64>
    g.right = 123456789
    if g.right != 123456789 { return 3 }
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
// SEMA: ===== SEMA fid {{[0-9]+}}: {{.*}}unions/union_import_main.k =====
// SEMA: -- scope symbol tables (what each scope declares) --
// SEMA-NEXT:   <tu>   [1 name(s)]
// SEMA-NEXT:     main        -> fn main @ 3:1
// SEMA-NEXT: -- multi-decl names (overload sets / redecl chains) --
// SEMA: -- name bindings --
// SEMA-NEXT:   <tu>::main
// SEMA-NEXT:     make_bits   @ 5:19     -> fn make_bits @ 11:5  [import overlay]
// SEMA-NEXT:     b           @ 6:8      -> var b @ 5:5  [local frame 0]
// SEMA-NEXT:     .i          @ 6:10     -> field i @ 7:5
// SEMA-NEXT:     e           @ 11:5     -> var e @ 10:5  [local frame 0]
// SEMA-NEXT:     .left       @ 11:7     -> field left @ 2:5
// SEMA-NEXT:     left_of     @ 12:8     -> fn left_of @ 17:5  [import overlay]
// SEMA-NEXT:     e           @ 12:16    -> var e @ 10:5  [local frame 0]
// SEMA-NEXT:     g           @ 16:5     -> var g @ 15:5  [local frame 0]
// SEMA-NEXT:     .right      @ 16:7     -> field right @ 3:5
// SEMA-NEXT:     g           @ 17:8     -> var g @ 15:5  [local frame 0]
// SEMA-NEXT:     .right      @ 17:10    -> field right @ 3:5
// SEMA-NEXT: -- expression types --
// SEMA-NEXT:   <tu>::main
// SEMA-NEXT:     CallExpr                @ 5:19     : Bits  [arg_map 0]
// SEMA-NEXT:     NamedIdentExpr          @ 5:19     : <no type: callable/type/module>
// SEMA-NEXT:     IntegerLiteralExpr      @ 5:29     : i32
// SEMA-NEXT:     BinaryOperatorExpr      @ 6:8      : bool
// SEMA-NEXT:     ChainExpr               @ 6:8      : i32
// SEMA-NEXT:     NamedIdentExpr          @ 6:8      : Bits
// SEMA-NEXT:     IntegerLiteralExpr      @ 6:15     : i32
// SEMA-NEXT:     IntegerLiteralExpr      @ 6:27     : i32
// SEMA-NEXT:     AssignOperatorExpr      @ 11:5     : i32
// SEMA-NEXT:     ChainExpr               @ 11:5     : i32
// SEMA-NEXT:     NamedIdentExpr          @ 11:5     : Either<i32, f32>
// SEMA-NEXT:     IntegerLiteralExpr      @ 11:14    : i32
// SEMA-NEXT:     BinaryOperatorExpr      @ 12:8     : bool
// SEMA-NEXT:     CallExpr                @ 12:8     : i32  [arg_map 0]
// SEMA-NEXT:     NamedIdentExpr          @ 12:8     : <no type: callable/type/module>
// SEMA-NEXT:     NamedIdentExpr          @ 12:16    : Either<i32, f32>
// SEMA-NEXT:     IntegerLiteralExpr      @ 12:22    : i32
// SEMA-NEXT:     IntegerLiteralExpr      @ 12:33    : i32
// SEMA-NEXT:     AssignOperatorExpr      @ 16:5     : i64
// SEMA-NEXT:     ChainExpr               @ 16:5     : i64
// SEMA-NEXT:     NamedIdentExpr          @ 16:5     : Either<u8, i64>
// SEMA-NEXT:     IntegerLiteralExpr      @ 16:15    : i64
// SEMA-NEXT:     BinaryOperatorExpr      @ 17:8     : bool
// SEMA-NEXT:     ChainExpr               @ 17:8     : i64
// SEMA-NEXT:     NamedIdentExpr          @ 17:8     : Either<u8, i64>
// SEMA-NEXT:     IntegerLiteralExpr      @ 17:19    : i64
// SEMA-NEXT:     IntegerLiteralExpr      @ 17:38    : i32
// SEMA-NEXT:     IntegerLiteralExpr      @ 18:12    : i32
// SEMA-NEXT:   26 typed, 0 unknown, 0 errored
// SEMA-NEXT: -- inferred decls --
// SEMA-NEXT:   (none: every declaration wrote its own type)
// SEMA-NEXT: -- interface composition --
// SEMA-NEXT: -- types --
// END-GENERATED-CHECKS(SEMA)

// BEGIN-GENERATED-CHECKS(LOWERED) mode=lowered -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-lowered 2>/dev/null || true; } | %FileCheck %s --check-prefix=LOWERED
// LOWERED: ===== SEMA fid {{[0-9]+}}: {{.*}}unions/union_import_main.k =====
// LOWERED: -- scope symbol tables (what each scope declares) --
// LOWERED-NEXT:   <tu>   [1 name(s)]
// LOWERED-NEXT:     main        -> fn main @ 3:1
// LOWERED-NEXT: -- multi-decl names (overload sets / redecl chains) --
// LOWERED: -- name bindings --
// LOWERED-NEXT:   <tu>::main
// LOWERED-NEXT:     make_bits   @ 5:19     -> fn make_bits @ 11:5  [import overlay]
// LOWERED-NEXT:     b           @ 6:8      -> var b @ 5:5  [local frame 0]
// LOWERED-NEXT:     .i          @ 6:10     -> field i @ 7:5
// LOWERED-NEXT:     e           @ 11:5     -> var e @ 10:5  [local frame 0]
// LOWERED-NEXT:     .left       @ 11:7     -> field left @ 2:5
// LOWERED-NEXT:     left_of     @ 12:8     -> fn left_of @ 17:5  [import overlay]
// LOWERED-NEXT:     e           @ 12:16    -> var e @ 10:5  [local frame 0]
// LOWERED-NEXT:     g           @ 16:5     -> var g @ 15:5  [local frame 0]
// LOWERED-NEXT:     .right      @ 16:7     -> field right @ 3:5
// LOWERED-NEXT:     g           @ 17:8     -> var g @ 15:5  [local frame 0]
// LOWERED-NEXT:     .right      @ 17:10    -> field right @ 3:5
// LOWERED-NEXT: -- expression types --
// LOWERED-NEXT:   <tu>::main
// LOWERED-NEXT:     CallExpr                @ 5:19     : Bits
// LOWERED-NEXT:     NamedIdentExpr          @ 5:19     : <no type: callable/type/module>
// LOWERED-NEXT:     IntegerLiteralExpr      @ 5:29     : i32
// LOWERED-NEXT:     BinaryOperatorExpr      @ 6:8      : bool
// LOWERED-NEXT:     ChainExpr               @ 6:8      : i32
// LOWERED-NEXT:     NamedIdentExpr          @ 6:8      : Bits
// LOWERED-NEXT:     IntegerLiteralExpr      @ 6:15     : i32
// LOWERED-NEXT:     IntegerLiteralExpr      @ 6:27     : i32
// LOWERED-NEXT:     AssignOperatorExpr      @ 11:5     : i32
// LOWERED-NEXT:     ChainExpr               @ 11:5     : i32
// LOWERED-NEXT:     NamedIdentExpr          @ 11:5     : Either<i32, f32>
// LOWERED-NEXT:     IntegerLiteralExpr      @ 11:14    : i32
// LOWERED-NEXT:     BinaryOperatorExpr      @ 12:8     : bool
// LOWERED-NEXT:     CallExpr                @ 12:8     : i32
// LOWERED-NEXT:     NamedIdentExpr          @ 12:8     : <no type: callable/type/module>
// LOWERED-NEXT:     NamedIdentExpr          @ 12:16    : Either<i32, f32>
// LOWERED-NEXT:     IntegerLiteralExpr      @ 12:22    : i32
// LOWERED-NEXT:     IntegerLiteralExpr      @ 12:33    : i32
// LOWERED-NEXT:     AssignOperatorExpr      @ 16:5     : i64
// LOWERED-NEXT:     ChainExpr               @ 16:5     : i64
// LOWERED-NEXT:     NamedIdentExpr          @ 16:5     : Either<u8, i64>
// LOWERED-NEXT:     IntegerLiteralExpr      @ 16:15    : i64
// LOWERED-NEXT:     BinaryOperatorExpr      @ 17:8     : bool
// LOWERED-NEXT:     ChainExpr               @ 17:8     : i64
// LOWERED-NEXT:     NamedIdentExpr          @ 17:8     : Either<u8, i64>
// LOWERED-NEXT:     IntegerLiteralExpr      @ 17:19    : i64
// LOWERED-NEXT:     IntegerLiteralExpr      @ 17:38    : i32
// LOWERED-NEXT:     IntegerLiteralExpr      @ 18:12    : i32
// LOWERED-NEXT:   26 typed, 0 unknown, 0 errored
// LOWERED-NEXT: -- inferred decls --
// LOWERED-NEXT:   (none: every declaration wrote its own type)
// LOWERED-NEXT: -- interface composition --
// LOWERED-NEXT: -- types --
// END-GENERATED-CHECKS(LOWERED)

// BEGIN-GENERATED-CHECKS(EXEC) mode=run -- regenerate with Tests/gen_checks.py, do not hand-edit
// REQUIRES: clang
// RUN: rm -rf %t.exec.d
// RUN: %kairo %s -o %t.exec.exe --cache-dir %t.exec.d
// RUN: %t.exec.exe > %t.exec.out; test $? -eq 2
// RUN: test ! -s %t.exec.out
// END-GENERATED-CHECKS(EXEC)
