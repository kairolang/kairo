// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
ffi "c" fn add(a: i32, b: i32) -> i32;
