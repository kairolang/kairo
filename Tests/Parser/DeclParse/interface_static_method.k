// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
interface <T> Parseable { static fn from_string(input: string) -> T }
