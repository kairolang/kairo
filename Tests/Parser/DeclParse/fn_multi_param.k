// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
fn add(a: i32, b: i32) -> i32 { return a + b; }
