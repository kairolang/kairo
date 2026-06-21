// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
class Shape { virtual fn area(const self) -> f64 { return 0.0; } }
