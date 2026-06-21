// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
struct Packet { var header: Header struct Header { var version: u8 var length: u16 } var payload: [byte] }
