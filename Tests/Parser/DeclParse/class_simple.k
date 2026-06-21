// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
class Counter { var count: i32 fn get(const self) -> i32 { return self.count; } }
