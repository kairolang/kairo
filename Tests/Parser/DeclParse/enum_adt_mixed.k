// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
enum ParseResult { Success { value: i32, consumed: i32 }, Error { message: string }, EndOfInput }
