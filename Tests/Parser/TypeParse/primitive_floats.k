// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
fn Test() { var a: f16; var b: f32; var c: f64; var d: f128; }
