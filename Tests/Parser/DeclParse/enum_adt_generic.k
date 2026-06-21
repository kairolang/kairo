// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
enum <K, V> LookupResult { Found { key: K, value: V }, NotFound { key: K }, Error { message: string } }
