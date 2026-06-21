// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
interface Serializable { fn serialize(self) const -> [byte] fn byte_size(const self) -> i32 }
