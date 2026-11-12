// Several inputs in one run, in either order: every file of the batch is
// parsed and serialized before Sema runs on any of them, so each tree the
// round trip writes is still a parsed one (TranslationUnit's stage is
// Parsing, which the writer requires), whichever input imports it first.
// A tree reloaded under --ast-roundtrip then goes through Sema as the parsed
// one would.

// RUN: cd %S/Inputs/macros && %kairo main.k lib.k --type-check-only --verify-ast-roundtrip --print-stats 2>&1 | %FileCheck %s
// RUN: cd %S/Inputs/macros && %kairo lib.k main.k --type-check-only --verify-ast-roundtrip --print-stats 2>&1 | %FileCheck %s
// RUN: cd %S/Inputs/macros && %kairo lib.k main.k --type-check-only --ast-roundtrip

// CHECK-NOT: AST round trip of
// CHECK: [stats] ast-serialize: {{[0-9]+}} files,
// CHECK-NOT: AST round trip of
