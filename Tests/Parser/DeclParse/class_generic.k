// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
class <T> Stack { var items: [T] fn Stack(self) { self.items = []; } }
