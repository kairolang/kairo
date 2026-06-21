// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
class Vec2 { var x: f64 var y: f64 fn op +(self, other: Vec2) -> Vec2 { return Vec2 { x: self.x + other.x, y: self.y + other.y }; } }
