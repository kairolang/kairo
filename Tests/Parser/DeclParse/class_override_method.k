// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
class Circle derives Shape { var radius: f64 override fn area(const self) -> f64 { return 0.0; } }
