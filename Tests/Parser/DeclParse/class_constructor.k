// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
class Point { var x: f64 var y: f64 fn Point(self, x: f64, y: f64) { self.x = x; self.y = y; } }
