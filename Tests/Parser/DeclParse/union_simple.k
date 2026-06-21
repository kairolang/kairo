// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
union Register { var as_u32: u32 var as_bytes: [u8; 4] var as_f32: f32 }
