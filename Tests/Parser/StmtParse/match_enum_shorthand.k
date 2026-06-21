// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
fn Test() { match dir { case .North { } case .South { } case .East { } case .West { } } }
