// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
spawn worker()
// AST: SpawnExpr
// AST-NEXT: CallExpr (0 args)
// AST-NEXT: NamedIdentExpr worker
