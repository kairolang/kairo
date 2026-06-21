// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
enum Opcode derives u8 { Nop = 0x00, Load = 0x01, Halt = 0xFF }
