// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
enum FileMode derives u8 { Read = 1 << 0, Write = 1 << 1, Execute = 1 << 2, All = (Read | Write | Execute) }
