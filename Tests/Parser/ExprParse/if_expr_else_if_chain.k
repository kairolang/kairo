// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
fn Test() { var x = if a { 1 } else if b { 2 } else { 3 }; }
