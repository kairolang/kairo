// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
fn <T impl Comparable> max(a: T, b: T) -> T { return a; }
