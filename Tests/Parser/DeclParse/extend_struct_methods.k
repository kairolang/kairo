// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
struct Vec2 { var x: f64 var y: f64 } extend Vec2 { fn length(const self) -> f64 { return 0.0; } }
