// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
fn Test() { var a: i8; var b: i16; var c: i32; var d: i64; var e: u8; var f: u16; var g: u32; var h: u64; var i: usize; var j: isize; }
