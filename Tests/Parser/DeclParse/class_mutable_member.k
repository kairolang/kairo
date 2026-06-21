// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
class Cache { var data: [i32] mutable var hit_count: i32 }
