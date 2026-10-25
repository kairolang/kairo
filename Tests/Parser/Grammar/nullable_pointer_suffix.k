// G1 (Compiler/Sema/NULLABLE.md 1.4): a `?` after a pointer type applies to
// the POINTER: `*T?` is `(*T)?`, `**T?` is `(**T)?`, `*const T?` is
// `(*const T)?`. Parentheses are the only way to put it on the pointee,
// `*(T?)`, and the printer keeps them, so the tree shows which one parsed.
// `??` after a pointer type is the same S055E as after any type.
var a: *i32?
var b: *(i32?)
var c: **i32?
var d: *const i32?
var e: (*i32)?
var f: [*i32?]
var g: *i32??

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST-LABEL: AST (tree) for fid 0
// AST: VariableDecl var a: *i32?
// AST: VariableDecl var b: *(i32?)
// AST: VariableDecl var c: **i32?
// AST: VariableDecl var d: *const i32?
// The parenthesized nullable pointer is the same tree as `a`.
// AST: VariableDecl var e: *i32?
// AST: VariableDecl var f: [*i32?]

// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: error
// DIAG: nullable_pointer_suffix.k:12:12: error [S055E]: unexpected '??' after type
// DIAG-NOT: error
