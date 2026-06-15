// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST --implicit-check-not=ChainExpr
// A braced initializer on a '::'-qualified path must consume the full path
// as the type name BEFORE binding the '{'. The init body belongs to
// 'geo::Shape::Circle', not to 'geo' with the rest chained on top.
geo::Shape::Circle { radius: 2.5 }
// AST: NamedInitializerExpr
// AST: Field radius
// AST-NEXT: FloatingLiteralExpr 2.5
