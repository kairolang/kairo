// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
@packed struct Header { var magic: u16 var version: u8 }
