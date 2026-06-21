// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
eval BUFFER_SIZE = 256; fn Test() { var buf: [u8; BUFFER_SIZE]; }
