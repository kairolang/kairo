// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
enum HttpStatus { Ok = 200, NotFound = 404, InternalError = 500 }
