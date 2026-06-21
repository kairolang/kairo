// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
fn Test() { outer: for i in 0..10 { inner: for j in 0..10 { continue outer; } } }
