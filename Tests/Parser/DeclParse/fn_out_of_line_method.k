// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
class Parser { fn advance(self) -> Token } fn Parser::advance(self) -> Token { return tok; }
