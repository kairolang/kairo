// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
class Buffer { var data: [i32] @copy fn Buffer(self, other: Self) = default }
