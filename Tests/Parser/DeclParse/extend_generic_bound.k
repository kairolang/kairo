// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
extend <T impl Comparable> Pair<T> { fn max(const self) -> T { return self.first; } }
