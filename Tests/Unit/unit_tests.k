// kunit runs every in-module Test() function in a fixed order and prints
// `ok <name>` or `FAIL <name>` after each one's own output; it exits nonzero
// when any test fails, which fails this run (lit runs with pipefail).

// --- lit wiring -----------------------------------------------------------
// RUN: %kunit | %FileCheck %s
// CHECK: ok ThreadPool
// CHECK: ok MappedFileBuffer
// CHECK: ok SourceManager
// CHECK: ok Lexer
// CHECK: ok FlagRegistry
// CHECK: ok TermRenderer
// CHECK-NOT: {{^}}FAIL

// A name runs that test alone; a name no test has is an error.
// RUN: %kunit TermRenderer | %FileCheck %s --check-prefix=ONE
// ONE-NOT: ok ThreadPool
// ONE: ok TermRenderer
// RUN: not %kunit NoSuchTest 2>&1 | %FileCheck %s --check-prefix=UNKNOWN
// UNKNOWN: kunit: no test named 'NoSuchTest'
