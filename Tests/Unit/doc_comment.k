// The language server's documentation-comment module (Analyzer/DocComment.k)
// through its own Test(): Kairo Markdown passes through as written; Doxygen
// and HeaderDoc comments taken from LLVM headers and written for HeaderDoc
// become the Markdown convention; the `### Parameters` lookup, the
// plain-text fallback, and the declaration head the documentation stub is
// built from.

// --- lit wiring -----------------------------------------------------------
// RUN: %kunit DocComment | %FileCheck %s
// CHECK-NOT: {{^}}FAIL
// CHECK: ok DocComment
