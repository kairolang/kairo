// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
@align(16) struct SimdData { var data: [u8; 12] }
