// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
class Resource { var handle: unsafe *void fn op delete(self) { } }
