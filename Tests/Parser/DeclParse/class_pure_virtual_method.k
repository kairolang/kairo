// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
class Shape { fn area(const self) -> f64 = virtual }
