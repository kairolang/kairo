// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
interface Equatable { fn op ==(self, other: Self) const -> bool }
