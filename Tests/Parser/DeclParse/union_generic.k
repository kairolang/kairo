// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
union <A, B> Reinterpret { var a: A var b: B }
