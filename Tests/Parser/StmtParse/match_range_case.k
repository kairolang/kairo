// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
fn Test() { match code { case 200..=299 { } case 400..=499 { } default { } } }
