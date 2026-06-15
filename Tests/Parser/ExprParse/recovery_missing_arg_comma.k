// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// RUN: { %kairo %s --print-ast=tree 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// Missing comma between call arguments: first arg kept, diagnostic emitted.
foo(1 2)
// AST: CallExpr (1 args)
// AST-NEXT: NamedIdentExpr foo
// AST-NEXT: IntegerLiteralExpr 1
// ERR: error [S054E]: expected ',' or ')' after argument in function call
