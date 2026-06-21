// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
class Temp { var celsius: f64 fn op as(self) -> string { return "0C"; } }
