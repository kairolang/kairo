// The shape of a lowered script, from --print-lowered: the deferred
// globals keep their names with `T?` storage, and `main` is a synthesized
// function whose first statement is the teardown `finally` (a record
// whose `op delete` nulls the globals, last-declared first), followed by
// each deferred line's assignment and each statement in source order. A
// read in main after its line is the narrowed `__value()` read; the
// constant `K` is no global main touches.

fn load() -> i32 { return 1 }

const K: i32 = 3
var a = load()
var b = load()
b = a + b + K

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --type-check-only --print-lowered | %FileCheck %s --check-prefix=LOW
// LOW:      ===== SEMA fid {{[0-9]+}}: {{.*}}lowered_main.k =====
// LOW:      -- name bindings --
// LOW-NEXT:   <tu>::main::__kairo_Fin0::op delete
// LOW-NEXT:     b           @ 13:1     -> var b @ 13:1  [pre-bound: not resolved by N(b)]
// LOW-NEXT:     a           @ 12:1     -> var a @ 12:1  [pre-bound: not resolved by N(b)]
// LOW-NEXT:   <tu>::main
// LOW-NEXT:     a           @ 12:1     -> var a @ 12:1  [pre-bound: not resolved by N(b)]
// LOW-NEXT:     load        @ 12:9     -> fn load @ 9:1  [scope <tu>]
// LOW-NEXT:     b           @ 13:1     -> var b @ 13:1  [pre-bound: not resolved by N(b)]
// LOW-NEXT:     load        @ 13:9     -> fn load @ 9:1  [scope <tu>]
// LOW-NEXT:     b           @ 14:1     -> var b @ 13:1  [scope <tu>]
// LOW-NEXT:     a           @ 14:5     -> var a @ 12:1  [scope <tu>]
// LOW-NEXT:     .__value    @ 14:5     -> fn __value @ {{[0-9]+:[0-9]+}}
// LOW-NEXT:     b           @ 14:9     -> var b @ 13:1  [scope <tu>]
// LOW-NEXT:     .__value    @ 14:9     -> fn __value @ {{[0-9]+:[0-9]+}}
// LOW-NEXT:     K           @ 14:13    -> var K @ 11:1  [scope <tu>]
// LOW:      -- expression types --
// LOW:        <tu>::main{{$}}
// LOW-NEXT:     NamedInitializerExpr    @ 12:1     : __kairo_Fin0
// LOW-NEXT:     AssignOperatorExpr      @ 12:1     : i32?
// LOW-NEXT:     NamedIdentExpr          @ 12:1     : i32?
// LOW-NEXT:     CallExpr                @ 12:9     : i32
// LOW-NEXT:     NamedIdentExpr          @ 12:9     : <no type: callable/type/module>
// LOW-NEXT:     AssignOperatorExpr      @ 13:1     : i32?
// LOW-NEXT:     NamedIdentExpr          @ 13:1     : i32?
// LOW-NEXT:     CallExpr                @ 13:9     : i32
// LOW-NEXT:     NamedIdentExpr          @ 13:9     : <no type: callable/type/module>
// LOW-NEXT:     AssignOperatorExpr      @ 14:1     : i32?
// LOW-NEXT:     NamedIdentExpr          @ 14:1     : i32?
// LOW-NEXT:     BinaryOperatorExpr      @ 14:5     : i32
// LOW-NEXT:     BinaryOperatorExpr      @ 14:5     : i32
// LOW-NEXT:     CallExpr                @ 14:5     : i32
// LOW-NEXT:     ChainExpr               @ 14:5     : <no type: callable/type/module>
// LOW-NEXT:     NamedIdentExpr          @ 14:5     : i32?
// LOW-NEXT:     CallExpr                @ 14:9     : i32
// LOW-NEXT:     ChainExpr               @ 14:9     : <no type: callable/type/module>
// LOW-NEXT:     NamedIdentExpr          @ 14:9     : i32?
// LOW-NEXT:     NamedIdentExpr          @ 14:13    : const i32
// LOW-NEXT:     IntegerLiteralExpr      @ 12:1     : i32
// LOW:      -- inferred decls --
// LOW-NEXT:   a : i32?
// LOW-NEXT:   b : i32?
// LOW-NEXT:   main() -> i32
// LOW-NEXT:   __kairo_fin0 : __kairo_Fin0
