// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
x = {"k": 1, "v": 2}
// AST: MapLiteralExpr (2 entries)
// AST-NEXT: Entry
// AST-NEXT: StringLiteralExpr "k"
// AST-NEXT: IntegerLiteralExpr 1
// AST-NEXT: Entry
// AST-NEXT: StringLiteralExpr "v"
// AST-NEXT: IntegerLiteralExpr 2
