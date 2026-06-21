// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
struct Color { var r: u8 var g: u8 var b: u8 var a: u8 = 255 }
