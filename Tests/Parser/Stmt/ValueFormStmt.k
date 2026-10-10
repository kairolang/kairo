// A value-form `if`, `match` or `try` in statement position is still an
// expression: an ExpressionStmt holding the IfExpr / MatchExpr / TryCatchExpr,
// not a ConditionalStmt / MatchStmt / TryCatchStmt. The `=>` after the
// condition, the arms of the match, and the token after `try` decide it.

fn value_if() {
    if c => f() else => g()
}

fn value_match() {
    match x { case 1 => f() default => g() }
}

fn value_try() {
    try f() catch => g()
}

// The statement forms are untouched.
fn statement_forms() {
    if c { }
    match x { case 1 { } default { } }
    try { } catch e { }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: TranslationUnit '{{.*}}ValueFormStmt.k'(fid=0)
// AST-NEXT: |-FunctionDecl  value_if()
// AST-NEXT: | `-CompoundStmt (1)
// AST-NEXT: |   `-ExpressionStmt
// AST-NEXT: |     `-IfExpr
// AST-NEXT: |       |-cond
// AST-NEXT: |       | `-NamedIdentExpr c
// AST-NEXT: |       |-then
// AST-NEXT: |       | `-CallExpr (0 args)
// AST-NEXT: |       |   `-NamedIdentExpr f
// AST-NEXT: |       `-else
// AST-NEXT: |         `-CallExpr (0 args)
// AST-NEXT: |           `-NamedIdentExpr g
// AST-NEXT: |-FunctionDecl  value_match()
// AST-NEXT: | `-CompoundStmt (1)
// AST-NEXT: |   `-ExpressionStmt
// AST-NEXT: |     `-MatchExpr (2 cases)
// AST-NEXT: |       |-NamedIdentExpr x
// AST-NEXT: |       |-case 1
// AST-NEXT: |       | `-CallExpr (0 args)
// AST-NEXT: |       |   `-NamedIdentExpr f
// AST-NEXT: |       `-default
// AST-NEXT: |         `-CallExpr (0 args)
// AST-NEXT: |           `-NamedIdentExpr g
// AST-NEXT: |-FunctionDecl  value_try()
// AST-NEXT: | `-CompoundStmt (1)
// AST-NEXT: |   `-ExpressionStmt
// AST-NEXT: |     `-TryCatchExpr (1 arms)
// AST-NEXT: |       |-CallExpr (0 args)
// AST-NEXT: |       | `-NamedIdentExpr f
// AST-NEXT: |       `-catch
// AST-NEXT: |         `-CallExpr (0 args)
// AST-NEXT: |           `-NamedIdentExpr g
// AST-NEXT: `-FunctionDecl  statement_forms()
// AST-NEXT:   `-CompoundStmt (3)
// AST-NEXT:     |-ConditionalStmt
// AST-NEXT:     | |-cond
// AST-NEXT:     | | `-NamedIdentExpr c
// AST-NEXT:     | `-then
// AST-NEXT:     |   `-CompoundStmt (0)
// AST-NEXT:     |-MatchStmt (2 cases)
// AST-NEXT:     | |-NamedIdentExpr x
// AST-NEXT:     | |-case 1
// AST-NEXT:     | | `-CompoundStmt (0)
// AST-NEXT:     | `-default
// AST-NEXT:     |   `-CompoundStmt (0)
// AST-NEXT:     `-TryCatchStmt (1 arms)
// AST-NEXT:       |-CompoundStmt (0)
// AST-NEXT:       `-catch e
// AST-NEXT:         `-CompoundStmt (0)
// AST-NEXT: -- 0 error(s), 0 warning(s) --
