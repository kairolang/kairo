// G10 (Compiler/Sema/NULLABLE.md 2.6): `unwrap!(expr)` is a parser
// intrinsic, like `label!` / `jump!`: the preprocessor passes `unwrap` `!`
// through raw (it used to be R013E "unknown macro 'unwrap!'"), and the
// expression parser builds an UnwrapExpr whose operand is an ordinary
// expression: a name, a field path, an operator, a call, another unwrap!,
// a macro expanded inside it. It is a primary expression, so a postfix
// step applies to its result (`unwrap!(f).v`). Refused (S060E, the
// intrinsic's code): `unwrap!` without `(`, and an unclosed one.

macro twice!(e) { e + e }

fn f(a: i32?, o: Foo?) -> i32 {
    var x = unwrap!(a)
    var y = unwrap!(o.n + 1)
    var z = unwrap!(unwrap!(g(a)))
    var w = unwrap!(o).v
    var m = unwrap!(twice!(a))
    return x
}

fn bad1(a: i32?) -> i32 { return unwrap! a }
fn bad2(a: i32?) -> i32 { return unwrap!(a }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST-LABEL: AST (tree) for fid 0
// AST: VariableDecl var x
// AST-NEXT: `-UnwrapExpr
// AST-NEXT:   `-NamedIdentExpr a
// AST: VariableDecl var y
// AST-NEXT: `-UnwrapExpr
// AST-NEXT:   `-BinaryOperatorExpr +
// AST: VariableDecl var z
// AST-NEXT: `-UnwrapExpr
// AST-NEXT:   `-UnwrapExpr
// AST-NEXT:     `-CallExpr
// AST: VariableDecl var w
// AST-NEXT: `-ChainExpr
// AST-NEXT:   |-UnwrapExpr
// AST: VariableDecl var m
// AST-NEXT: `-UnwrapExpr
// AST-NEXT:   `-BinaryOperatorExpr +

// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: error
// DIAG: unwrap_intrinsic.k:21:34: error [S060E]: expected '(' after 'unwrap!': write 'unwrap!(expr)'
// DIAG-NOT: error
// DIAG: unwrap_intrinsic.k:22:34: error [S060E]: expected ')' to close 'unwrap!(...)'
// DIAG-NOT: error
