// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
fn Test() { match result { case .Found(var key, var value) { } case .NotFound(var key) { } default { } } }
