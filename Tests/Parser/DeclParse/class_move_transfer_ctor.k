// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
class UniqueFile { var handle: unsafe *void @move fn UniqueFile(self, other: Self) { self.handle = other.handle; } }
