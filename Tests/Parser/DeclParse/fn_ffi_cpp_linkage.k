// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
ffi "c++" fn compute(x: i32) -> i32;
