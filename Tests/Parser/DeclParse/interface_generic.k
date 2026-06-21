// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
interface <T> Container { fn add(self, item: T) fn get(self, index: i32) const -> T fn size(const self) -> i32 }
