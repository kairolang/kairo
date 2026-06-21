// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
struct Metrics { var total: i32 mutable var cache_hits: i32 }
