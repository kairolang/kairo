// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
class Config { const MAX_RETRIES: i32 fn Config(self, n: i32) { self.MAX_RETRIES = n; } }
