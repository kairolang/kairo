// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
class UserId impl Hashable { var id: u64 fn hash(const self) -> u64 { return self.id; } }
