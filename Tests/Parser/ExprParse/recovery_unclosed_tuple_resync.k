// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// RUN: { %kairo %s --print-ast=tree 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// Recovery resync: an unclosed tuple must not swallow the following statement.
// foo() on the next line still parses as its own ExpressionStmt.
x = (1, 2, 3
foo()
// AST: TupleLiteralExpr (3)
// AST-NEXT: IntegerLiteralExpr 1
// AST-NEXT: IntegerLiteralExpr 2
// AST-NEXT: IntegerLiteralExpr 3
// AST: ExpressionStmt
// AST-NEXT: CallExpr (0 args)
// AST-NEXT: NamedIdentExpr foo
// ERR: error [S019E]: unclosed ')' opened here
// ERR: error [S054E]: expected ')' to close tuple literal
