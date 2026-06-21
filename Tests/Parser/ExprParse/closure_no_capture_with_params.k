// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
fn Test() { var f = fn (x: i32, y: i32) -> i32 { return x + y; }; }
