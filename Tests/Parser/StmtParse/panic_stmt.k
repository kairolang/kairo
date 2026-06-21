// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
fn Test() panic -> i32 { panic std::Error::Runtime("oops"); }
