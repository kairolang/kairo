// `const &x` is the address-of `&x` with `const` in front, a pointer to
// const. It parses wherever `&x` does: a return value, a yield, an
// initializer, a tuple element, a positional and a named argument, an
// if-expression arm, a match arm, under `unsafe`. A statement that starts
// with `const` is still a declaration.

fn g(p: *const i32, q: *const i32) -> *const i32 {
    return const &*p
}

fn gen(a: *i32) -> yield *const i32 {
    yield const &*a
}

fn main() -> i32 {
    var a = 1
    const k = 2
    var t = (const &a, &a)
    var u = unsafe const &a
    var m = if (a == 1) => (const &a) else => const &k
    var r = g(p: const &a, q: const &k)
    var s = match a {
        case 1 => const &a
        default => const &k
    }

    return *r + *m + *s + *g(const &a, &k) + *t.0
}

// --- lit wiring ---
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST --implicit-check-not="error ["
// AST: FunctionDecl  g(
// AST: ReturnStmt
// AST-NEXT: `-UnaryOperatorExpr prefix const &
// AST-NEXT: `-UnaryOperatorExpr prefix *
// AST: FunctionDecl  gen(
// AST: UnaryOperatorExpr prefix const &
// AST: VariableDecl const k
// AST: VariableDecl var t
// AST: TupleLiteralExpr
// AST-NEXT: UnaryOperatorExpr prefix const &
// AST: UnaryOperatorExpr prefix &
// AST: VariableDecl var u
// AST: UnsafeExpr
// AST-NEXT: UnaryOperatorExpr prefix const &
// AST: VariableDecl var m
// AST: UnaryOperatorExpr prefix const &
// AST: UnaryOperatorExpr prefix const &
// AST: VariableDecl var r
// AST: UnaryOperatorExpr prefix const &
// AST: UnaryOperatorExpr prefix const &
// AST: VariableDecl var s
// AST: UnaryOperatorExpr prefix const &
// AST: UnaryOperatorExpr prefix const &
//
// The tree prints it back as written.
// RUN: { %kairo %s --syntax-only --print-ast=flat 2>&1 || true; } | %FileCheck %s --check-prefix=SRC
// SRC: return const &*p
// SRC: var t = (const &a, &a)
// SRC: var u = unsafe const &a
// SRC: g(p: const &a, q: const &k)
//
// It runs: 1 + 1 + 1 + 1 + 1.
// RUN: rm -rf %t.d
// RUN: %kairo %s -w -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 5
