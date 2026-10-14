// --input-encoding accepts utf-8 only. Any other value would be silently
// ignored and the source mis-decoded, so it is an error instead.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --type-check-only --input-encoding=utf-8
// RUN: { %kairo %s --type-check-only --input-encoding=latin-1 2>&1 || true; } | %FileCheck %s
// RUN: not %kairo %s --type-check-only --input-encoding=latin-1 > /dev/null 2>&1
// CHECK: error [U001E]: --input-encoding=latin-1: only utf-8 input is supported
