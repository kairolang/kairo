// --print-tokens dumps the lexer's token stream before the pipeline runs.
// The first tokens of a file starting with a comment are fixed, so they are
// checked in order.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --type-check-only --print-tokens | %FileCheck %s
// CHECK: token stream:
// CHECK: fn 'fn'
// CHECK: identifier 'main'
