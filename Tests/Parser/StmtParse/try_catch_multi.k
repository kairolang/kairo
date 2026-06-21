// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
fn Test() { try { risky(); } catch e: std::Error::IO { } catch e: std::Error::Runtime { } }
