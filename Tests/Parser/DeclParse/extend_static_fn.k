// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
extend Point { static fn origin() -> Point { return Point { x: 0.0, y: 0.0 }; } }
