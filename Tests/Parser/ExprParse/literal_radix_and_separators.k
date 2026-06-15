// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// Radix prefixes and digit separators are resolved by the lexer to their
// decimal value: 0xFF -> 255, 0b1010 -> 10, 1_000_000 -> 1000000.
x = 0xFF
x = 0b1010
x = 1_000_000
// AST: IntegerLiteralExpr 255
// AST: IntegerLiteralExpr 10
// AST: IntegerLiteralExpr 1000000
