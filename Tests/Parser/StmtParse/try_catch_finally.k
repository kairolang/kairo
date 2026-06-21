// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
fn Test() { try { work(); } catch e: std::Error::Runtime { } finally { cleanup(); } }
