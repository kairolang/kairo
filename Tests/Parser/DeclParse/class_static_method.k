// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
class Math { static fn sqrt(x: f64) -> f64 { return 0.0; } }
