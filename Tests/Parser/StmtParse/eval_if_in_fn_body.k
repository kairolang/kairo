// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
fn <T> process(x: T) -> T { eval if sizeof T <= 8 { return fast_path(x); } else { return slow_path(x); } }
