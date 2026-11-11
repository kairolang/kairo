// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// RUN: { %kairo %s --print-ast=tree 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// Trailing dot with no member name at EOF: clean diagnostic, base ident survives.
// The message names the SEPARATOR it is complaining after. It must not
// interpolate the current token instead: that would read "after 'END OF FILE'" here.
// AST: `-ExpressionStmt
// AST-NEXT:   `-NamedIdentExpr a
// ERR: error [S054E]: expected identifier or tuple index after '.' in access expression
a.
