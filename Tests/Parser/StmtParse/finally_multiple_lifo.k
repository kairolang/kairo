// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
fn Test() panic { var a = acquire_a(); finally { release_a(a); } var b = acquire_b(); finally { release_b(b); } }
