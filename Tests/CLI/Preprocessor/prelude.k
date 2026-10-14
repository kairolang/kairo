// --prelude=<file> replaces the builtin prelude with a user file, so the file
// is opened up front: a missing one is a fatal driver error naming the path,
// not a silent fallback to the builtin module.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --prelude=/nonexistent/prelude.k 2>&1 || true; } | %FileCheck %s
// CHECK: fatal [I005F]: no such file: '/nonexistent/prelude.k'
