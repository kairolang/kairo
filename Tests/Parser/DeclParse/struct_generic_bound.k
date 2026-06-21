// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
struct <T impl Comparable> Range { var start: T var end: T }
