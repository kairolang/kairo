// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
eval if platform == "linux" { fn init() { } } else { fn init() { } }
