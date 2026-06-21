// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
fn Test() { var label = match level { case .Debug { "debug" } case .Info { "info" } default { "other" } }; }
