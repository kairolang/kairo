// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
interface Bad { fn method(self) -> i32 { return 0; } }
