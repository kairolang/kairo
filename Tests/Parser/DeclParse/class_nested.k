// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
class Tree { priv class Node { var value: i32 } var root: unsafe *Node }
