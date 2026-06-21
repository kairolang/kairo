// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
class <T impl Comparable> PriorityQueue { var heap: [T] }
