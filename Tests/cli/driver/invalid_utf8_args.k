// A command-line word or a directory entry holding bytes that are not UTF-8
// is stored as it is; it must not stop the compiler.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: python3 %S/inputs/invalid_utf8_args.py %kairo --type-check-only | %FileCheck %s
// CHECK: argv: OK
// CHECK: path: OK
