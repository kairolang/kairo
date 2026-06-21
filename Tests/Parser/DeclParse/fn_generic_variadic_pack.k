// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
fn <...T> print_all(...args: T) { }
