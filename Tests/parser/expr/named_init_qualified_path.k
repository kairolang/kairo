// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// A braced initializer on a '::'-qualified path must consume the full path
// as the type name BEFORE binding the '{'. The init body belongs to
// 'geo::Shape::Circle', not to 'geo' with the rest chained on top.
// AST: `-ExpressionStmt
// AST-NEXT:   `-NamedInitializerExpr
// AST-NEXT:     |-ChainExpr 'geo::Shape::Circle'
// AST-NEXT:     | |-NamedIdentExpr geo
// AST-NEXT:     | |-Step ::Shape
// AST-NEXT:     | `-Step ::Circle
// AST-NEXT:     `-Field radius
// AST-NEXT:       `-FloatingLiteralExpr 2.5
geo::Shape::Circle { radius: 2.5 }