// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: `-ExpressionStmt
// AST-NEXT:   `-AssignOperatorExpr =
// AST-NEXT:     |-NamedIdentExpr x
// AST-NEXT:     `-MatchExpr (4 cases)
// AST-NEXT:       |-NamedIdentExpr named
// AST-NEXT:       |-case .Point
// AST-NEXT:       | `-IntegerLiteralExpr 0
// AST-NEXT:       |-case .Circle(var r) where r > 1.0
// AST-NEXT:       | `-IntegerLiteralExpr 1
// AST-NEXT:       |-case .Rect(var w, var h)
// AST-NEXT:       | `-IntegerLiteralExpr 2
// AST-NEXT:       `-default
// AST-NEXT:         `-UnaryOperatorExpr prefix -
// AST-NEXT:           `-IntegerLiteralExpr 1
x = match named {
    case .Point { 0 }
    case .Circle(var r) where r > 1.0 { 1 }
    case .Rect(var w, var h) { 2 }
    default { -1 }
}
