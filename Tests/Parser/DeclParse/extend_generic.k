// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
extend <T> Pair<T> { fn swap(self) -> Pair<T> { return self; } }
