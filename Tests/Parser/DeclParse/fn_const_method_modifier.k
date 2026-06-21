// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
class Foo { fn value(const self) -> i32 { return 0; } }
